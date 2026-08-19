clear; clc; close all;

% Add reusable metric and display functions before loading the experiment.
addpath(genpath('functions'));

%% SELECT THE COMPLETED EXPERIMENT

% Edit only this folder name when evaluating a different sweep experiment.
experimentFolderName = 'costFunction_v01_20260819_120610_647';
experimentFolder = fullfile(pwd, 'output', 'bonePoseOptimization', 'experiments', experimentFolderName);

% Keep the detailed seed-distribution plot readable when a sweep is large.
topCombinationCount = 20;

% Choose how the hyperparameter heatmaps are arranged. The x- and y-parameters
% form each heatmap. The panel parameters create rows and columns of heatmaps,
% so every swept value remains visible without adding more plot axes.
heatmapSettings.xParameter           = 'minReferencePixels';
heatmapSettings.yParameter           = 'nMinPixels';
heatmapSettings.panelRowParameter    = 'normalFacingToleranceDeg';
heatmapSettings.panelColumnParameter = 'lambdaMissing';

% Put parameters here when this heatmap should hold them at chosen values.
% This affects only the figure; it does not change the optimization settings.
heatmapSettings.parametersToHold = struct();

%% LOAD THE EXPERIMENT PLAN, SUMMARY, AND GROUND TRUTH

% The experiment plan tells the evaluator which cost model was used and which
% summary-table columns are swept parameters. Stop before loading when this
% file is missing because those details should not be guessed from the table.
planFilePath = fullfile(experimentFolder, 'experiment_plan.mat');
if ~isfile(planFilePath)
    error('main_bonePoseOptimization_evaluation:MissingExperimentPlan', ...
          'Could not find the experiment plan: %s', planFilePath);
end
planData = load(planFilePath, 'experimentSpec', 'experimentPlan');

% Check that the MAT-file contains both saved plan variables, uses the current
% schema, and provides the ordered parameter-name list. These fields are needed
% to build generic evaluation tables with the correct parameter columns.
hasSupportedExperimentMetadata = isfield(planData, 'experimentSpec') && ...
    isfield(planData, 'experimentPlan') && ...
    isfield(planData.experimentSpec, 'schemaVersion') && ...
    planData.experimentSpec.schemaVersion == 4 && ...
    isfield(planData.experimentPlan, 'parameterNames');
if ~hasSupportedExperimentMetadata
    error('main_bonePoseOptimization_evaluation:UnsupportedExperimentPlan', ...
          'Evaluation requires a schema-version-4 experiment plan with parameter metadata.');
end
parameterNames = planData.experimentPlan.parameterNames;

% The summary contains one row for every optimizer run and points to each saved
% result. Stop when it is missing because there would be no run results to score.
summaryFilePath = fullfile(experimentFolder, 'summary.mat');
if ~isfile(summaryFilePath)
    error('main_bonePoseOptimization_evaluation:MissingSummary', ...
          'Could not find the experiment summary: %s', summaryFilePath);
end
summaryData = load(summaryFilePath, 'summaryTable');
perRunTable = summaryData.summaryTable;

% Confirm that all summary rows use one cost model and that it matches the
% experiment plan. This prevents parameter names from one model being applied
% to result rows produced by a different model.
expectedCostModel = string(planData.experimentSpec.cost.model);
summaryCostModels = unique(string(perRunTable.costModel));
if numel(summaryCostModels) ~= 1 || summaryCostModels ~= expectedCostModel
    error('main_bonePoseOptimization_evaluation:CostModelMismatch', ...
          'The summary cost model does not match the saved experiment specification.');
end

% Load one shared ground-truth pose and mesh for comparison with every seed.
validationFilePath = fullfile(experimentFolder, 'validation_context.mat');
if ~isfile(validationFilePath)
    error('main_bonePoseOptimization_evaluation:MissingValidationContext', ...
          'Could not find the validation context: %s', validationFilePath);
end
validationData = load(validationFilePath, 'validationContext');

% Grab the important data for evaluation
groundTruthBonePose    = validationData.validationContext.validationData.groundTruthBonePose;
T_bone_ref_groundTruth = groundTruthBonePose.T_bone_ref;
boneMeshRefGroundTruth = groundTruthBonePose.boneMeshRef;

%% PREPARE THE PER-RUN EVALUATION TABLE

% Add empty evaluation columns while preserving all original sweep columns.
numberOfRuns = height(perRunTable);
perRunTable.evaluationStatus   = repmat("pending", numberOfRuns, 1);
perRunTable.evaluationMessage  = repmat("", numberOfRuns, 1);
perRunTable.translationErrorMm = nan(numberOfRuns, 1);
perRunTable.rotationErrorDeg   = nan(numberOfRuns, 1);
perRunTable.surfaceRmseMm      = nan(numberOfRuns, 1);

%% CALCULATE THE ERROR METRICS FOR EVERY COMPLETED RUN

for runIndex = 1:numberOfRuns
    % Failed optimizer runs have no estimated transform or surface to evaluate.
    if string(perRunTable.status(runIndex)) ~= "completed"
        perRunTable.evaluationStatus(runIndex)  = "skipped";
        perRunTable.evaluationMessage(runIndex) = "The optimizer run did not complete.";
        continue;
    end

    try
        % Load the estimated transform and candidate mesh saved for this seed.
        runFilePath = char(perRunTable.resultFilePath(runIndex));
        runData     = load(runFilePath, 'runResult');

        % Get the necessary data
        T_bone_ref_estimate = runData.runResult.optimizationResult.result.T_bone_ref_best;
        boneMeshRefEstimate = runData.runResult.final.costDetails.boneMeshRefCandidate;

        % Calculate each geometric metric in its small dedicated function.
        perRunTable.translationErrorMm(runIndex) = calculateTranslationErrorMm(T_bone_ref_groundTruth, T_bone_ref_estimate);
        perRunTable.rotationErrorDeg(runIndex)   = calculateRotationErrorDeg(T_bone_ref_groundTruth, T_bone_ref_estimate);
        perRunTable.surfaceRmseMm(runIndex)      = calculateSurfaceRmseMm(boneMeshRefGroundTruth, boneMeshRefEstimate);
        perRunTable.evaluationStatus(runIndex)   = "evaluated";

    catch evaluationError
        % Keep later runs usable when one saved result is missing or incomplete.
        perRunTable.evaluationStatus(runIndex)   = "failed";
        perRunTable.evaluationMessage(runIndex)  = string(evaluationError.message);
    end
end

%% RANK INDIVIDUAL RUNS BY SURFACE RMSE

% This section does two separate jobs:
% - First, assign rank 1 to the run with the smallest surface RMSE, rank 2 
%   to the next smallest, and so on. 
% - Second, reorder the table by that rank so the most accurate runs are 
%   easy to find, while failed or skipped runs remain visible at the end of 
%   the table.

% ---

% Start every run as unranked because failed or skipped runs have no valid RMSE.
perRunTable.surfaceRmseRank = nan(numberOfRuns, 1);

% Select the table rows that contain a completed and finite RMSE evaluation.
evaluatedRows = perRunTable.evaluationStatus == "evaluated" & isfinite(perRunTable.surfaceRmseMm);

% Sort only the valid RMSE values from smallest to largest. evaluatedOrder
% contains positions inside this smaller, filtered list rather than table row numbers.
[~, evaluatedOrder] = sort(perRunTable.surfaceRmseMm(evaluatedRows));

% Convert the logical selection to the original table row numbers, then use
% evaluatedOrder to assign rank 1 to the smallest RMSE, rank 2 to the next, and so on.
evaluatedIndexes = find(evaluatedRows);
perRunTable.surfaceRmseRank(evaluatedIndexes(evaluatedOrder)) = (1:numel(evaluatedIndexes)).';

% ---

% Use a temporary sorting key so unranked NaN rows behave like an infinite
% rank and therefore appear after every successfully evaluated run.
runSortRank = perRunTable.surfaceRmseRank;
runSortRank(~isfinite(runSortRank)) = inf;

% Sort first by accuracy rank and then by the original run number. The run
% number gives failed or skipped rows a stable and predictable order.
[~, runTableOrder] = sortrows([runSortRank, perRunTable.runNumber], [1 2]);
perRunTable = perRunTable(runTableOrder, :);

% Move the rank beside the run identity so the saved table is easier to scan.
perRunTable = movevars(perRunTable, 'surfaceRmseRank', 'Before', 'runNumber');

%% CREATE THE RANKED PER-COMBINATION TABLE

% Aggregate the seed rows using the parameter order saved by the experiment plan.
perCombinationTable = createCombinationEvaluationTable(perRunTable, parameterNames);

%% SAVE THE EVALUATION TABLES

% Keep evaluation results beside the experiment that produced them.
evaluationFolder = fullfile(experimentFolder, 'evaluation');
if ~isfolder(evaluationFolder)
    mkdir(evaluationFolder);
end

writetable(perRunTable, fullfile(evaluationFolder, 'per_run_evaluation.csv'));
writetable(perCombinationTable, fullfile(evaluationFolder, 'per_combination_evaluation.csv'));

% Save the small metadata needed to interpret generic parameter columns later.
evaluationMetadata.schemaVersion  = planData.experimentSpec.schemaVersion;
evaluationMetadata.costModel      = char(expectedCostModel);
evaluationMetadata.parameterNames = parameterNames;
save(fullfile(evaluationFolder, 'evaluation_tables.mat'), 'perRunTable', 'perCombinationTable', 'evaluationMetadata');

% Show the main hyperparameter-selection table after saving exact values.
disp(perCombinationTable);

%% DISPLAY THE EVALUATION PLOTS

% Keep one figure handle per display so users can adjust figures interactively.
figureSurfaceRmseBoxplot            = plotSurfaceRmseBoxplot(perRunTable, perCombinationTable, topCombinationCount);
figureRankedSurfaceRmse             = plotRankedSurfaceRmse(perCombinationTable);
figureTranslationRotationErrors     = plotTranslationRotationErrors(perCombinationTable);
figureHyperparameterPaneledHeatmaps = plotHyperparameterPaneledHeatmaps(perCombinationTable, parameterNames, heatmapSettings);
figureOptimizerDiagnostic           = plotOptimizerCostVsSurfaceRmse(perCombinationTable);
