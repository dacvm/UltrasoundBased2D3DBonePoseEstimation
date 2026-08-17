clear; clc; close all;

% Add reusable metric and display functions before loading the experiment.
addpath(genpath('functions'));

%% SELECT THE COMPLETED EXPERIMENT

% Edit only this folder name when evaluating a different sweep experiment.
experimentFolderName = 'costFunction_v01_20260813_191441_237';
experimentFolder = fullfile(pwd, 'output', 'bonePoseOptimization', ...
    'experiments', experimentFolderName);

% Keep the detailed seed-distribution plot readable when a sweep is large.
topCombinationCount = 20;

%% LOAD THE EXPERIMENT SUMMARY AND GROUND TRUTH

% The summary identifies every planned run and the path to its saved result.
summaryFilePath = fullfile(experimentFolder, 'summary.mat');
if ~isfile(summaryFilePath)
    error('main_bonePoseOptimization_evaluation:MissingSummary', ...
        'Could not find the experiment summary: %s', summaryFilePath);
end
summaryData = load(summaryFilePath, 'summaryTable');
perRunTable = summaryData.summaryTable;

% Load one shared ground-truth pose and mesh for comparison with every seed.
validationFilePath = fullfile(experimentFolder, 'validation_context.mat');
if ~isfile(validationFilePath)
    error('main_bonePoseOptimization_evaluation:MissingValidationContext', ...
        'Could not find the validation context: %s', validationFilePath);
end
validationData = load(validationFilePath, 'validationContext');
groundTruthBonePose = ...
    validationData.validationContext.validationData.groundTruthBonePose;
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
        perRunTable.evaluationStatus(runIndex) = "skipped";
        perRunTable.evaluationMessage(runIndex) = ...
            "The optimizer run did not complete.";
        continue;
    end

    try
        % Load the estimated transform and candidate mesh saved for this seed.
        runFilePath = char(perRunTable.resultFilePath(runIndex));
        runData = load(runFilePath, 'runResult');
        T_bone_ref_estimate = ...
            runData.runResult.optimizationResult.result.T_bone_ref_best;
        boneMeshRefEstimate = ...
            runData.runResult.final.costDetails.boneMeshRefCandidate;

        % Calculate each geometric metric in its small dedicated function.
        perRunTable.translationErrorMm(runIndex) = ...
            calculateTranslationErrorMm( ...
                T_bone_ref_groundTruth, T_bone_ref_estimate);
        perRunTable.rotationErrorDeg(runIndex) = ...
            calculateRotationErrorDeg( ...
                T_bone_ref_groundTruth, T_bone_ref_estimate);
        perRunTable.surfaceRmseMm(runIndex) = ...
            calculateSurfaceRmseMm( ...
                boneMeshRefGroundTruth, boneMeshRefEstimate);

        perRunTable.evaluationStatus(runIndex) = "evaluated";

    catch evaluationError
        % Keep later runs usable when one saved result is missing or incomplete.
        perRunTable.evaluationStatus(runIndex) = "failed";
        perRunTable.evaluationMessage(runIndex) = ...
            string(evaluationError.message);
    end
end

%% RANK INDIVIDUAL RUNS BY SURFACE RMSE

% Give ranks only to runs with a complete geometric evaluation.
perRunTable.surfaceRmseRank = nan(numberOfRuns, 1);
evaluatedRows = perRunTable.evaluationStatus == "evaluated" & ...
                isfinite(perRunTable.surfaceRmseMm);
[~, evaluatedOrder] = sort(perRunTable.surfaceRmseMm(evaluatedRows));
evaluatedIndexes = find(evaluatedRows);
perRunTable.surfaceRmseRank(evaluatedIndexes(evaluatedOrder)) = ...
    (1:numel(evaluatedIndexes)).';

% Put the most accurate runs first and unavailable runs at the end.
runSortRank = perRunTable.surfaceRmseRank;
runSortRank(~isfinite(runSortRank)) = inf;
[~, runTableOrder] = sortrows([runSortRank, perRunTable.runNumber], [1 2]);
perRunTable = perRunTable(runTableOrder, :);
perRunTable = movevars(perRunTable, 'surfaceRmseRank', ...
    'Before', 'runNumber');

%% CREATE THE RANKED PER-COMBINATION TABLE

% Aggregate the seed rows only after every individual run has been evaluated.
perCombinationTable = createCombinationEvaluationTable(perRunTable);

%% SAVE THE EVALUATION TABLES

% Keep evaluation results beside the experiment that produced them.
evaluationFolder = fullfile(experimentFolder, 'evaluation');
if ~isfolder(evaluationFolder)
    mkdir(evaluationFolder);
end

writetable(perRunTable, ...
    fullfile(evaluationFolder, 'per_run_evaluation.csv'));
writetable(perCombinationTable, ...
    fullfile(evaluationFolder, 'per_combination_evaluation.csv'));
save(fullfile(evaluationFolder, 'evaluation_tables.mat'), ...
    'perRunTable', 'perCombinationTable');

% Show the main hyperparameter-selection table after saving exact values.
disp(perCombinationTable);

%% DISPLAY THE EVALUATION PLOTS

% Keep one figure handle per display so users can adjust figures interactively.
figureSurfaceRmseBoxplot = plotSurfaceRmseBoxplot( ...
    perRunTable, perCombinationTable, topCombinationCount);
figureRankedSurfaceRmse = plotRankedSurfaceRmse(perCombinationTable);
figureTranslationRotationErrors = ...
    plotTranslationRotationErrors(perCombinationTable);
figureHyperparameterHeatmaps = ...
    plotHyperparameterFacetedHeatmaps(perCombinationTable);
figureOptimizerDiagnostic = ...
    plotOptimizerCostVsSurfaceRmse(perCombinationTable);
