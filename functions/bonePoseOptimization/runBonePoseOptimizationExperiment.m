function experimentResult = runBonePoseOptimizationExperiment(experimentSpec)
%RUNBONEPOSEOPTIMIZATIONEXPERIMENT Run all combinations and repeat seeds.
% This function creates a new timestamped experiment, prepares each scalar
% hyperparameter combination once, runs CMA-ES for every configured seed,
% and saves each result immediately. It intentionally does not resume old
% experiments or cache prepared inputs across different combinations.
%
% Where it fits in the framework:
%   A hyperparameter sweep asks "which cost settings let the optimizer find
%   the bone pose best, and how reliably?". To answer it we must run the
%   whole bone-pose optimization many times: once for every combination of
%   settings, and several times per combination with different random seeds.
%
%   main_bonePoseOptimization_hyperparamSweep.m reads the JSON with
%   createBonePoseOptimizationExperimentConfig and then hands the checked
%   experimentSpec to this function, which does everything else. It is the
%   conductor that strings together the pieces built elsewhere:
%     1. createBonePoseOptimizationExperimentPlan turns the spec into a
%        to-do list of combinations and runs;
%     2. for each combination, createBonePoseOptimizationRunConfig makes a
%        one-run config and prepareBonePoseOptimizationInputs builds the
%        fixed data (mesh, image planes, PD-tree, ...);
%     3. for each seed of that combination, runBonePoseOptimization runs
%        CMA-ES on that prepared data;
%     4. every result is saved and added to one summary table.
%
% Why it is built this way:
%   A sweep can run unattended for hours. Three ideas shape the code:
%     - Prepare once per combination. Input preparation is slow and the
%       same for every seed, so it is done once and reused by all seeds.
%     - Never lose finished work. Each run is saved the moment it ends, and
%       the summary table on disk is updated after every run, so a crash or
%       a manual stop late in the sweep still leaves all earlier results.
%     - One failure must not stop the sweep. A failing combination or seed
%       is recorded as "failed" (with its error message) and the loop moves
%       on, so one bad setting does not waste the rest of the night.
%   Every call starts a NEW experiment folder; there is no resume, which
%   keeps the code simple and guarantees one folder = one complete,
%   self-consistent experiment.
%
% Input:
%   experimentSpec - Validated configuration returned by
%                    createBonePoseOptimizationExperimentConfig.
%
% Output:
%   experimentResult - Struct containing the new experiment folder, the
%                      complete plan, and the final summary table.

%% CREATE AND SAVE THE EXPERIMENT PLAN

% Before running anything, turn the candidate lists into the concrete list
% of combinations and runs. Knowing the full workload up front lets us tell
% the user how big the sweep is, and gives every run a fixed ID that the
% folders, the summary table, and the progress messages all share.
experimentPlan   = createBonePoseOptimizationExperimentPlan(experimentSpec);
% Every sweep gets its own new, timestamped folder. Results of different
% sweeps (or of a rerun of the same JSON) can then never overwrite or mix
% with each other.
experimentFolder = createExperimentFolder(experimentSpec.experiment.outputFolder, experimentSpec.experiment.name);

% The JSON file on disk may be edited later for the next sweep. A copy of
% it inside the experiment folder records exactly which settings produced
% these results, so the experiment can be understood or repeated months
% from now. If the copy fails we stop, because results without their
% settings would be hard to interpret.
configSnapshotPath          = fullfile(experimentFolder, 'experiment_config_snapshot.json');
[configCopied, copyMessage] = copyfile(experimentSpec.source.configFilePath, configSnapshotPath);
if ~configCopied
    error('runBonePoseOptimizationExperiment:ConfigCopyFailed', ...
          'Could not copy the experiment configuration: %s', copyMessage);
end

% Results can depend on more than the JSON: the MATLAB version and whether
% CMA-ES evaluates candidates in parallel. With parfor, the order in which
% workers finish can vary, so the same seed may not give bit-identical
% results. We note this context so a later reader knows how far results
% are expected to be reproducible.
environment.matlabVersion       = version;
environment.parallelToolbox     = ver('parallel');
environment.useParfor           = experimentSpec.optimizer.useParfor;
environment.parforWorkers       = experimentSpec.optimizer.parforWorkers;
environment.seedReproducibility = 'best_effort_when_internal_parfor_is_enabled';

% Save the spec, the plan and the environment before the first run starts.
% This file is the reference description of the experiment: analysis code
% reads it to know what was planned, even if the sweep is stopped halfway.
planFilePath = fullfile(experimentFolder, 'experiment_plan.mat');
save(planFilePath, 'experimentSpec', 'experimentPlan', 'environment');

% Create the summary table: one row per planned run, all marked "pending".
% It is saved now and then rewritten after every run, so at any moment the
% file on disk shows which runs are done, which failed, and which are still
% waiting. It is the first thing to open when looking at the results.
summaryTable = createSummaryTable(experimentPlan.runs);
saveExperimentSummary(experimentFolder, summaryTable);

% Tell the user where the results will go and how much work is ahead
% (number of runs and the maximum number of cost evaluations), so they can
% judge the run time and stop early if the sweep is larger than intended.
maximumEvaluations = experimentPlan.numberOfRuns * experimentSpec.optimizer.maxFunctionEvaluations;
fprintf('Created experiment: %s\n', experimentFolder);
fprintf('%d combinations x %d seeds = %d optimization runs.\n', ...
        experimentPlan.numberOfCombinations, experimentPlan.numberOfSeeds, experimentPlan.numberOfRuns);
fprintf('Maximum planned function evaluations: %d\n', maximumEvaluations);

%% RUN EACH COMBINATION

% The optimizer does not search for the pose directly; it searches for a
% small 6D correction [vx vy vz wx wy wz] on top of the coarse start pose.
% A zero vector means "no correction yet", i.e. exactly the coarse pose.
% Every run starts from here, so only the settings and the seed differ.
initialPoseVector      = zeros(6, 1);
% The ground truth is the same for every combination (same data, same
% bone), so it only needs to be saved once. This flag remembers whether
% that already happened.
validationContextSaved = false;

% The outer loop walks through the combinations one by one. For each, we
% first prepare the inputs and then (in the inner loop below) run all its
% seeds on those inputs.
for combinationIndex = 1:experimentPlan.numberOfCombinations

    % Take this combination's row from the plan and find its runs (one per
    % seed). The plan stores all seeds of a combination next to each other,
    % so these are the runs the inner loop will execute.
    combinationRow        = experimentPlan.combinations(combinationIndex, :);
    combinationRunIndexes = find(experimentPlan.runs.combinationNumber == combinationRow.combinationNumber);

    % Turn the plan row into a plain one-run config (one value per setting,
    % no seed yet). Preparation and the cost function only understand this
    % plain shape, not the candidate lists of the experiment spec.
    combinationConfig     = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow);

    fprintf('\nPreparing %s (%d of %d).\n', ...
            char(combinationRow.combinationId), combinationIndex, experimentPlan.numberOfCombinations);

    % Preparation is wrapped in try/catch: some settings (for example an
    % extreme intersection tolerance) can make preparation fail. Such a
    % failure should be recorded and skipped, not end the whole sweep.
    try

        % Load and check all inputs and build the slow structures (PD-tree,
        % start-pose intersections) once. Every seed below reuses this data,
        % which is the main reason the loop is organised per combination.
        [combinationData, validationData] = prepareBonePoseOptimizationInputs(combinationConfig);
        combinationData.config            = combinationConfig;

        % Evaluate the cost at the start pose. This is the "before" value we
        % compare each run's final cost to, showing how much the optimizer
        % improved. It depends on the cost settings but not on the seed, so
        % computing it once per combination is enough.
        initialCost = bonePoseCostFunction(initialPoseVector, combinationData, combinationConfig);

        % Save the full ground truth and start transforms once, in a shared
        % file. Run files then only need a small reference to it, which
        % keeps them small and avoids storing the same data many times.
        if ~validationContextSaved
            saveValidationContext(experimentFolder, validationData, combinationData, experimentSpec);
            validationContextSaved = true;
        end

    catch preparationError

        % Without prepared inputs no seed of this combination can run. We
        % still write a "failed" result file and summary row for each of its
        % seeds, so the summary shows exactly what happened (and why) for
        % every planned run, instead of rows that stay "pending" forever.
        for runIndex = combinationRunIndexes(:).'

            % Build the same seed config and output folder a normal run
            % would get. The failed result then sits in the exact place
            % where analysis code expects this run's file, and it records
            % the settings that were being tried when preparation broke.
            runRow      = experimentPlan.runs(runIndex, :);
            seedConfig  = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow, runRow.seed);
            seedConfig  = addRunOutputFolder(seedConfig, runRow, experimentFolder);

            % Package the error as a run result with the same fields as a
            % successful one (stage "preparation", NaN costs, no ground
            % truth), so later analysis can load every run the same way and
            % simply filter on its status. Save it right away, like any run.
            [runResult, summaryRecord] = createFailedRunResult(runRow, seedConfig, preparationError, 'preparation', NaN, struct());
            saveRunResult(runResult);

            % Mark this run as "failed" in the summary, with the error
            % message, and rewrite the summary file, so the on-disk table
            % is up to date even if the sweep stops before the next run.
            summaryTable = updateSummaryRow(summaryTable, runIndex, summaryRecord);
            saveExperimentSummary(experimentFolder, summaryTable);

        end
        % Move on to the next combination; the remaining sweep is unaffected.
        continue;
    end

    %% RUN EVERY SEED FOR THIS COMBINATION

    % The inputs are ready, so now CMA-ES is run once per seed. Different
    % seeds give different random search paths; comparing their results
    % shows whether this combination finds the pose reliably or only by luck.

    % Each run result keeps a small copy of the true pose. That way a single
    % run file is enough to compute its pose error later, without also
    % loading the shared validation file.
    validationReference = createValidationReference(validationData);

    for runIndex = combinationRunIndexes(:).'

        % Build the config for this exact run: the combination's settings
        % plus this seed, and its own output folder so CMA-ES logs and the
        % result file of different runs never overwrite each other.
        runRow          = experimentPlan.runs(runIndex, :);
        seedConfig      = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow, runRow.seed);
        seedConfig      = addRunOutputFolder(seedConfig, runRow, experimentFolder);

        % Reuse the prepared data, but swap in the seed-specific config. The
        % cost function reads settings from data.config, so this keeps the
        % data and the config used by the optimizer exactly in agreement.
        seedData        = combinationData;
        seedData.config = seedConfig;

        % Run CMA-ES. runOneSeed catches its own errors and returns a
        % "failed" result instead, so one crashing seed does not stop the
        % others.
        fprintf('Running %s with seed %d.\n', char(runRow.runId), runRow.seed);
        [runResult, summaryRecord] = runOneSeed(runRow, seedConfig, seedData, validationReference, initialPoseVector, initialCost);

        % Save the result and the updated summary right away. Since there
        % is no resume feature, this is what protects finished runs if the
        % sweep is interrupted later.
        saveRunResult(runResult);
        summaryTable = updateSummaryRow(summaryTable, runIndex, summaryRecord);
        saveExperimentSummary(experimentFolder, summaryTable);
    end
end

%% RETURN A COMPACT EXPERIMENT RESULT

% All planned runs have now been attempted. Print one closing line with how
% many succeeded and failed, so after an unattended sweep the user sees at
% a glance whether it is worth opening the summary for failures.
numberCompleted = sum(summaryTable.status == "completed");
numberFailed    = sum(summaryTable.status == "failed");
fprintf('\nExperiment finished: %d completed, %d failed.\n', numberCompleted, numberFailed);

% Everything is already saved on disk. The returned struct is only a
% convenience for the calling script: where the results are, what was
% planned, and the final summary, ready for a quick look or a next
% analysis step without reloading files.
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
%CREATEEXPERIMENTFOLDER Create one new timestamped experiment folder.
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
