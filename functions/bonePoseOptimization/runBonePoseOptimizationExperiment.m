function experimentResult = runBonePoseOptimizationExperiment(experimentSpec)
%RUNBONEPOSEOPTIMIZATIONEXPERIMENT Run all v03 combinations and repeat seeds.
% This function creates a new timestamped experiment, prepares each scalar
% hyperparameter combination once, runs CMA-ES for every configured seed,
% and saves each result immediately. It intentionally does not resume old
% experiments or cache prepared inputs across different combinations.
%
% Input:
%   experimentSpec - Validated configuration returned by
%                    createBonePoseOptimizationExperimentConfig.
%
% Output:
%   experimentResult - Struct containing the new experiment folder, the
%                      complete plan, and the final summary table.

%% CREATE AND SAVE THE EXPERIMENT PLAN

% Expand all candidate values before running so the total workload is visible.
experimentPlan   = createBonePoseOptimizationExperimentPlan(experimentSpec);
% Create a fresh folder on every invocation.
experimentFolder = createExperimentFolder(experimentSpec.experiment.outputFolder, experimentSpec.experiment.name);

% Record the original JSON beside the resolved MATLAB structures.
configSnapshotPath          = fullfile(experimentFolder, 'experiment_config_snapshot.json');
[configCopied, copyMessage] = copyfile(experimentSpec.source.configFilePath, configSnapshotPath);
if ~configCopied
    error('runBonePoseOptimizationExperiment:ConfigCopyFailed', ...
          'Could not copy the v03 configuration: %s', copyMessage);
end

% Record the software context that may affect stochastic parallel execution.
environment.matlabVersion       = version;
environment.parallelToolbox     = ver('parallel');
environment.useParfor           = experimentSpec.optimizer.useParfor;
environment.parforWorkers       = experimentSpec.optimizer.parforWorkers;
environment.seedReproducibility = 'best_effort_when_internal_parfor_is_enabled';

% Save the authoritative plan before the first optimization begins.
planFilePath = fullfile(experimentFolder, 'experiment_plan.mat');
save(planFilePath, 'experimentSpec', 'experimentPlan', 'environment');

% Build an analysis-friendly table and save its initial pending state.
summaryTable = createSummaryTable(experimentPlan.runs);
saveExperimentSummary(experimentFolder, summaryTable);

% Explain the complete workload before starting the unattended loop.
maximumEvaluations = experimentPlan.numberOfRuns * experimentSpec.optimizer.maxFunctionEvaluations;
fprintf('Created experiment: %s\n', experimentFolder);
fprintf('%d combinations x %d seeds = %d optimization runs.\n', ...
        experimentPlan.numberOfCombinations, experimentPlan.numberOfSeeds, experimentPlan.numberOfRuns);
fprintf('Maximum planned function evaluations: %d\n', maximumEvaluations);

%% RUN EACH COMBINATION

% A zero state keeps the coarse CT-to-reference pose unchanged.
initialPoseVector      = zeros(6, 1);
% Save shared validation data after the first successful preparation only.
validationContextSaved = false;

% Loop for every hyperparameter combination
for combinationIndex = 1:experimentPlan.numberOfCombinations

    % Read one scalar combination and find its consecutive seed rows.
    combinationRow        = experimentPlan.combinations(combinationIndex, :);
    combinationRunIndexes = find(experimentPlan.runs.combinationNumber == combinationRow.combinationNumber);

    % Copy the candidate values into the scalar configuration used by existing functions.
    combinationConfig     = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow);

    fprintf('\nPreparing %s (%d of %d).\n', ...
            char(combinationRow.combinationId), combinationIndex, experimentPlan.numberOfCombinations);

    try

        % Prepare once for this combination, then reuse the data for all of its seeds.
        [combinationData, validationData] = prepareBonePoseOptimizationInputs(combinationConfig);
        combinationData.config            = combinationConfig;

        % The initial cost depends on the scalar cost settings but not on the random seed.
        initialCost = bonePoseCostFunction(initialPoseVector, combinationData, combinationConfig);

        % Ground truth is shared by the experiment, so one saved copy is sufficient.
        if ~validationContextSaved
            saveValidationContext(experimentFolder, validationData, combinationData, experimentSpec);
            validationContextSaved = true;
        end

    catch preparationError
        
        % Record every affected seed as failed because no optimizer can use this combination.
        for runIndex = combinationRunIndexes(:).'
            
            runRow      = experimentPlan.runs(runIndex, :);
            seedConfig  = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow, runRow.seed);
            seedConfig  = addRunOutputFolder(seedConfig, runRow, experimentFolder);
            
            [runResult, summaryRecord] = createFailedRunResult(runRow, seedConfig, preparationError, 'preparation', NaN, struct());
            saveRunResult(runResult);
            
            summaryTable = updateSummaryRow(summaryTable, runIndex, summaryRecord);
            saveExperimentSummary(experimentFolder, summaryTable);
        
        end
        continue;
    end

    %% RUN EVERY SEED FOR THIS COMBINATION

    % Use the same ordered seed list for this and every other combination.
    validationReference = createValidationReference(validationData);

    % Loop and run the optimization for every predefined seeds
    for runIndex = combinationRunIndexes(:).'

        runRow          = experimentPlan.runs(runIndex, :);
        seedConfig      = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow, runRow.seed);
        seedConfig      = addRunOutputFolder(seedConfig, runRow, experimentFolder);
        
        % Keep the prepared struct consistent with the exact seed-specific runtime config.
        seedData        = combinationData;
        seedData.config = seedConfig;

        fprintf('Running %s with seed %d.\n', char(runRow.runId), runRow.seed);
        [runResult, summaryRecord] = runOneSeed(runRow, seedConfig, seedData, validationReference, initialPoseVector, initialCost);

        % Save immediately so completed work survives even though v03 has no resume feature.
        saveRunResult(runResult);
        summaryTable = updateSummaryRow(summaryTable, runIndex, summaryRecord);
        saveExperimentSummary(experimentFolder, summaryTable);
    end
end

%% RETURN A COMPACT EXPERIMENT RESULT

% Report both outcomes so unattended runs end with one clear status line.
numberCompleted = sum(summaryTable.status == "completed");
numberFailed    = sum(summaryTable.status == "failed");
fprintf('\nExperiment finished: %d completed, %d failed.\n', numberCompleted, numberFailed);

% Keep the most useful experiment-level values available to the calling script.
experimentResult.experimentFolder = experimentFolder;
experimentResult.experimentPlan   = experimentPlan;
experimentResult.summaryTable     = summaryTable;
end






function runConfig = addRunOutputFolder(runConfig, runRow, experimentFolder)
%ADDRUNOUTPUTFOLDER Add the deterministic output folder for one experiment run.
% runConfig is the scalar combination configuration, runRow identifies one
% repetition, experimentFolder owns all outputs, and the returned config has
% the CMA-ES base output folder for this run.

% Build a readable folder hierarchy from the stable combination and seed values.
seedFolder = fullfile(experimentFolder, 'runs', char(runRow.combinationId), sprintf('seed_%d', runRow.seed));
if ~isfolder(seedFolder)
    mkdir(seedFolder);
end

% Keep raw CMA-ES logs below the folder that will also contain runResult.mat.
runConfig.optimizer.outputFolder = fullfile(seedFolder, 'cmaes');
end


function [runResult, summaryRecord] = runOneSeed(runRow, runConfig, data, validationReference, initialPoseVector, initialCost)
%RUNONESEED Execute and package one combination-seed optimization run.
% runRow and runConfig identify the run, data contains prepared estimation
% inputs, validationReference stores ground-truth transforms, and the initial
% inputs define the common starting pose. The outputs are the saved result
% structure and its flat summary values.

% Record wall-clock and elapsed time separately for readable reporting.
startTime = currentTimestamp();
runTimer = tic;

try
    % Run CMA-ES using the prepared data and seed-specific scalar configuration.
    optimizationResult = runBonePoseOptimization(initialPoseVector, data, runConfig, initialCost);

    % Reevaluate the best pose once because the optimizer normally keeps only scalar costs.
    [finalCost, finalCostDetails] = bonePoseCostFunction(optimizationResult.result.bestPoseVector, data, runConfig);

    runStatus = "completed";
    runError  = createEmptyError();

catch optimizationError
    % Keep one failed run from stopping later seeds or combinations.
    optimizationResult  = struct();
    finalCost           = NaN;
    finalCostDetails    = struct();
    runStatus           = "failed";
    runError            = exceptionToStruct(optimizationError, 'optimization');
end

% Finish the timing after either the successful or failed optimizer path.
runtimeSeconds  = toc(runTimer);
endTime         = currentTimestamp();

% Package the complete run in named groups for later MATLAB analysis.
runResult = createRunResultBase(runRow, runConfig, runStatus, startTime, endTime, runtimeSeconds);
runResult.initial.poseVector    = initialPoseVector;
runResult.initial.cost          = initialCost;
runResult.optimizationResult    = optimizationResult;
runResult.final.cost            = finalCost;
runResult.final.costDetails     = finalCostDetails;
runResult.validationReference   = validationReference;
runResult.error                 = runError;
runResult.run.resultFilePath    = getRunResultFilePath(runConfig);

% Flatten the small comparison fields into one summary record.
summaryRecord = createSummaryRecord(runResult);
end


function [runResult, summaryRecord] = createFailedRunResult(runRow, runConfig, caughtError, failureStage, initialCost, validationReference)
%CREATEFAILEDRUNRESULT Package a run that could not reach or finish CMA-ES.
% runRow and runConfig identify the planned run, caughtError explains the
% failure, failureStage identifies preparation or optimization, initialCost
% may be unavailable, and validationReference may be empty. Outputs match a
% normal run result and summary record so later analysis uses one format.

% Preparation failures have no meaningful optimizer duration, so use a zero duration.
eventTime = currentTimestamp();
runResult = createRunResultBase(runRow, runConfig, "failed", eventTime, eventTime, 0);
runResult.initial.poseVector    = zeros(6, 1);
runResult.initial.cost          = initialCost;
runResult.optimizationResult    = struct();
runResult.final.cost            = NaN;
runResult.final.costDetails     = struct();
runResult.validationReference   = validationReference;
runResult.error                 = exceptionToStruct(caughtError, failureStage);
runResult.run.resultFilePath    = getRunResultFilePath(runConfig);

summaryRecord = createSummaryRecord(runResult);
end


function runResult = createRunResultBase(runRow, runConfig, status, startTime, endTime, runtimeSeconds)
%CREATERUNRESULTBASE Create fields shared by successful and failed run results.
% runRow and runConfig identify the run, status and timestamps describe its
% outcome, runtimeSeconds stores elapsed time, and runResult is the common struct.

% Store bookkeeping separately from the full scalar configuration.
runResult.run.runNumber         = runRow.runNumber;
runResult.run.runId             = char(runRow.runId);
runResult.run.combinationNumber = runRow.combinationNumber;
runResult.run.combinationId     = char(runRow.combinationId);
runResult.run.seed              = runRow.seed;
runResult.run.status            = char(status);
runResult.run.startTime         = char(startTime);
runResult.run.endTime           = char(endTime);
runResult.run.runtimeSeconds    = runtimeSeconds;
runResult.configuration         = runConfig;
end


function validationReference = createValidationReference(validationData)
%CREATEVALIDATIONREFERENCE Select compact ground-truth transforms for each run.
% validationData contains the full held-out validation packet and
% validationReference contains only the bone identity and frame-explicit poses.

% Small transform copies make every run independently usable during later analysis.
validationReference.bone                   = validationData.bone;
validationReference.T_CT_ref_groundTruth   = validationData.groundTruthBonePose.T_CT_ref;
validationReference.T_bone_ref_groundTruth = validationData.groundTruthBonePose.T_bone_ref;
end


function saveValidationContext(experimentFolder, validationData, data, experimentSpec)
%SAVEVALIDATIONCONTEXT Save the full held-out validation packet once.
% experimentFolder selects the experiment, validationData is the held-out
% packet, data supplies shared initial transforms, and experimentSpec records
% source paths. This helper has no output.

% Keep shared validation and initial transforms out of repeated run files.
validationContext.validationData     = validationData;
validationContext.input              = experimentSpec.input;
validationContext.T_CT_ref_initial   = data.T_CT_ref_initial;
validationContext.T_bone_ref_initial = data.T_bone_ref_initial;

validationContextFilePath = fullfile(experimentFolder, 'validation_context.mat');
save(validationContextFilePath, 'validationContext', '-v7.3');
end


function summaryTable = createSummaryTable(runTable)
%CREATESUMMARYTABLE Add outcome columns to the immutable planned run rows.
% runTable contains identifiers and parameter values, and summaryTable adds
% status, timing, optimizer diagnostics, result paths, and error text.

% Preallocate one result slot per planned run so the CSV keeps the plan order.
numberOfRuns = height(runTable);
summaryTable = runTable;
summaryTable.status              = repmat("pending", numberOfRuns, 1);
summaryTable.startTime           = repmat("", numberOfRuns, 1);
summaryTable.endTime             = repmat("", numberOfRuns, 1);
summaryTable.runtimeSeconds      = NaN(numberOfRuns, 1);
summaryTable.initialCost         = NaN(numberOfRuns, 1);
summaryTable.bestCost            = NaN(numberOfRuns, 1);
summaryTable.functionEvaluations = NaN(numberOfRuns, 1);
summaryTable.stopFlag            = repmat("", numberOfRuns, 1);
summaryTable.resultFilePath      = repmat("", numberOfRuns, 1);
summaryTable.errorStage          = repmat("", numberOfRuns, 1);
summaryTable.errorIdentifier     = repmat("", numberOfRuns, 1);
summaryTable.errorMessage        = repmat("", numberOfRuns, 1);
end


function summaryRecord = createSummaryRecord(runResult)
%CREATESUMMARYRECORD Extract flat values from one saved run result.
% runResult is the complete nested run output and summaryRecord contains the
% scalar and text values written into one summary-table row.

% Copy bookkeeping and costs that exist for both successful and failed runs.
summaryRecord.status            = string(runResult.run.status);
summaryRecord.startTime         = string(runResult.run.startTime);
summaryRecord.endTime           = string(runResult.run.endTime);
summaryRecord.runtimeSeconds    = runResult.run.runtimeSeconds;
summaryRecord.initialCost       = runResult.initial.cost;
summaryRecord.resultFilePath    = string(runResult.run.resultFilePath);
summaryRecord.errorStage        = string(runResult.error.stage);
summaryRecord.errorIdentifier   = string(runResult.error.identifier);
summaryRecord.errorMessage      = string(runResult.error.message);

% Optimizer diagnostics are available only after CMA-ES returns successfully.
if strcmp(runResult.run.status, 'completed')
    summaryRecord.bestCost            = runResult.optimizationResult.result.bestCost;
    summaryRecord.functionEvaluations = runResult.optimizationResult.cmaes.counteval;
    summaryRecord.stopFlag            = joinStopFlags(runResult.optimizationResult.cmaes.stopflag);
else
    summaryRecord.bestCost            = NaN;
    summaryRecord.functionEvaluations = NaN;
    summaryRecord.stopFlag            = "";
end
end


function summaryTable = updateSummaryRow(summaryTable, runIndex, summaryRecord)
%UPDATESUMMARYROW Copy one flat run record into the experiment summary table.
% summaryTable is the current table, runIndex selects its row, summaryRecord
% supplies outcome values, and the output is the updated table.

% Update only result columns; planned identifiers and parameters never change.
summaryTable.status(runIndex)               = summaryRecord.status;
summaryTable.startTime(runIndex)            = summaryRecord.startTime;
summaryTable.endTime(runIndex)              = summaryRecord.endTime;
summaryTable.runtimeSeconds(runIndex)       = summaryRecord.runtimeSeconds;
summaryTable.initialCost(runIndex)          = summaryRecord.initialCost;
summaryTable.bestCost(runIndex)             = summaryRecord.bestCost;
summaryTable.functionEvaluations(runIndex)  = summaryRecord.functionEvaluations;
summaryTable.stopFlag(runIndex)             = summaryRecord.stopFlag;
summaryTable.resultFilePath(runIndex)       = summaryRecord.resultFilePath;
summaryTable.errorStage(runIndex)           = summaryRecord.errorStage;
summaryTable.errorIdentifier(runIndex)      = summaryRecord.errorIdentifier;
summaryTable.errorMessage(runIndex)         = summaryRecord.errorMessage;
end


function saveRunResult(runResult)
%SAVERUNRESULT Save one complete result immediately after its attempt.
% runResult contains the output and its destination path. This function has
% no output and uses v7.3 because detailed intersection data can be large.

% The seed folder already exists because addRunOutputFolder created it.
resultFilePath = runResult.run.resultFilePath;
save(resultFilePath, 'runResult', '-v7.3');
end


function resultFilePath = getRunResultFilePath(runConfig)
%GETRUNRESULTFILEPATH Locate runResult.mat beside the run's CMA-ES folder.
% runConfig contains the CMA-ES base output path and resultFilePath is the
% neighboring MAT-file used by the experiment runner.

% The CMA-ES base is <seed folder>/cmaes, so its parent owns runResult.mat.
seedFolder      = fileparts(runConfig.optimizer.outputFolder);
resultFilePath  = fullfile(seedFolder, 'runResult.mat');
end


function saveExperimentSummary(experimentFolder, summaryTable)
%SAVEEXPERIMENTSUMMARY Save the current summary as MAT and CSV files.
% experimentFolder owns the experiment, summaryTable contains one row per
% planned run, and this helper has no output.

% MAT preserves MATLAB types while CSV supports later inspection in other tools.
save(fullfile(experimentFolder, 'summary.mat'), 'summaryTable');
writetable(summaryTable, fullfile(experimentFolder, 'summary.csv'));
end


function experimentFolder = createExperimentFolder(outputFolder, experimentName)
%CREATEEXPERIMENTFOLDER Create one new timestamped v03 experiment folder.
% outputFolder is the configured base, experimentName is the readable prefix,
% and experimentFolder is the unique directory created for this invocation.

% Create the shared experiment base when this is its first run.
if ~isfolder(outputFolder)
    mkdir(outputFolder);
end

% Milliseconds make accidental name collisions unlikely during quick repeated tests.
folderStamp      = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS'));
baseName         = sprintf('%s_%s', experimentName, folderStamp);
experimentFolder = fullfile(outputFolder, baseName);
collisionIndex   = 1;

% Add a short suffix only if two invocations still choose the same folder name.
while isfolder(experimentFolder)
    collisionIndex = collisionIndex + 1;
    experimentFolder = fullfile(outputFolder, sprintf('%s_%02d', baseName, collisionIndex));
end
mkdir(experimentFolder);
end


function errorInfo = exceptionToStruct(caughtError, failureStage)
%EXCEPTIONTOSTRUCT Convert a MATLAB exception into fields safe to save and export.
% caughtError is the MException, failureStage names the failed workflow step,
% and errorInfo is a plain struct used by MAT and CSV outputs.

% Keep the stack in MAT output while the summary uses the shorter text fields.
errorInfo.stage      = char(failureStage);
errorInfo.identifier = caughtError.identifier;
errorInfo.message    = caughtError.message;
errorInfo.stack      = caughtError.stack;
end


function errorInfo = createEmptyError()
%CREATEEMPTYERROR Create the shared no-error result shape.
% The output is an error-info struct with empty stage, identifier, message,
% and stack fields so successful and failed run results share one schema.

% Empty named fields avoid repeated isfield checks during summary creation.
errorInfo.stage      = '';
errorInfo.identifier = '';
errorInfo.message    = '';
errorInfo.stack      = struct([]);
end


function stopFlagText = joinStopFlags(stopFlag)
%JOINSTOPFLAGS Convert CMA-ES stop reasons into one CSV-safe string.
% stopFlag contains one or more CMA-ES reasons and stopFlagText joins them
% with semicolons for the flat summary table.

% CMA-ES versions may return a character vector, string, or cell array.
stopFlagText = strjoin(string(stopFlag), "; ");
end


function timestamp = currentTimestamp()
%CURRENTTIMESTAMP Return a readable timestamp for saved run metadata.
% The output is a string containing local date, time, and milliseconds.

% Use one consistent format in run MAT files and the CSV summary.
timestamp = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS'));
end
