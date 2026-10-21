function tests = testBonePoseOptimizationExperiment
%TESTBONEPOSEOPTIMIZATIONEXPERIMENT Test active configuration and planning.
% This suite checks schema and model identity, candidate parsing,
% Cartesian-product planning, repeat seeds, and failure recording.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

% Let MATLAB discover every local function whose name starts with test.
tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Load the active configurations once for this suite.
% testCase receives the project root, configuration paths, and parsed
% configurations in TestData. This function has no output.

% Walk from this test file through tests/, bonePoseOptimization/, and functions/.
testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Parse the active multi-sweep and one-sweep configurations used by the main scripts.
sweepConfigPath = fullfile(projectRoot, 'config', ...
    'optconfig_hyperparamSweep_intensityLine.json');
oneSweepConfigPath = fullfile(projectRoot, 'config', ...
    'optconfig_oneSweep_intensityLine.json');
ICPLikeOneSweepConfigPath = fullfile(projectRoot, 'config', ...
    'optconfig_oneSweep_ICPLike.json');
combinedOneSweepConfigPath = fullfile(projectRoot, 'config', ...
    'optconfig_oneSweep_intensityICP.json');
combinedSweepConfigPath = fullfile(projectRoot, 'config', ...
    'optconfig_hyperparamSweep_intensityICP.json');
testCase.TestData.projectRoot = projectRoot;
testCase.TestData.sweepConfigPath = sweepConfigPath;
testCase.TestData.combinedSweepConfigPath = combinedSweepConfigPath;
testCase.TestData.oneSweepConfigPath = oneSweepConfigPath;
testCase.TestData.ICPLikeOneSweepConfigPath = ICPLikeOneSweepConfigPath;
testCase.TestData.combinedOneSweepConfigPath = combinedOneSweepConfigPath;
testCase.TestData.sweepSpec = ...
    createBonePoseOptimizationExperimentConfig(sweepConfigPath);
testCase.TestData.oneSweepSpec = ...
    createBonePoseOptimizationExperimentConfig(oneSweepConfigPath);
testCase.TestData.ICPLikeOneSweepSpec = ...
    createBonePoseOptimizationExperimentConfig(ICPLikeOneSweepConfigPath);
testCase.TestData.combinedOneSweepSpec = ...
    createBonePoseOptimizationExperimentConfig(combinedOneSweepConfigPath);
end


function testActiveConfigurationKeepsModelCandidatesAndSeeds(testCase)
%TESTACTIVECONFIGURATIONKEEPSMODELCANDIDATESANDSEEDS Check the active schema.
% testCase supplies the parsed sweep specification. This function has no output.

% Validate the experiment schema without depending on the user's current sweep values.
spec = testCase.TestData.sweepSpec;
verifyEqual(testCase, spec.schemaVersion, 4);
verifyEqual(testCase, spec.cost.model, 'intensityLine');
verifyTrue(testCase, all(spec.intersection.normalFacingToleranceDeg > 0));
verifyTrue(testCase, all(spec.cost.hyperparameters.intensitySmoothingSigmaMm >= 0));
verifyTrue(testCase, isscalar(spec.cost.fixedParameters.intensityMax));
verifyTrue(testCase, isscalar(spec.cost.fixedParameters.sampleSpacingMm));
verifyTrue(testCase, all(spec.experiment.seeds > 0));
verifyEqual(testCase, numel(unique(spec.experiment.seeds)), ...
    numel(spec.experiment.seeds));
verifyTrue(testCase, isfolder(fileparts(spec.experiment.outputFolder)));

% The model validator returns the parameter groups in their canonical order.
verifyEqual(testCase, fieldnames(spec.cost.fixedParameters).', ...
    {'intensityMax', 'sampleSpacingMm'});
verifyEqual(testCase, fieldnames(spec.cost.hyperparameters).', ...
    {'intensitySmoothingSigmaMm'});
end


function testICPLikeOneSweepConfigurationDefinesOneReproducibleRun(testCase)
%TESTICPLIKEONESWEEPCONFIGURATIONDEFINESONEREPRODUCIBLERUN Check the ICP-like setup.
% testCase supplies the parsed point-cloud specification and verification
% methods. This test keeps fixed settings separate from sweep parameters.

spec = testCase.TestData.ICPLikeOneSweepSpec;
plan = createBonePoseOptimizationExperimentPlan(spec);
runConfig = createBonePoseOptimizationRunConfig( ...
    spec, plan.combinations(1, :), plan.runs.seed(1));

% The one-sweep file must select the 3D model and provide its required surface input.
verifyEqual(testCase, spec.cost.model, 'ICPLike');
verifyTrue(testCase, isfile(spec.input.boneSurfaceMatFile));
verifyEqual(testCase, spec.experiment.name, 'oneSweep_ICPLike');

% K and the batch size stay fixed, while the retained intersection
% tolerance creates only one plan row.
verifyEqual(testCase, spec.cost.fixedParameters.nearestVertexCount, 20);
verifyEqual(testCase, spec.cost.fixedParameters.pointBatchSize, 200);
verifyEmpty(testCase, fieldnames(spec.cost.hyperparameters));
verifyEqual(testCase, plan.parameterNames, {'normalFacingToleranceDeg'});
verifyEqual(testCase, plan.numberOfCombinations, 1);
verifyEqual(testCase, plan.numberOfSeeds, 1);
verifyEqual(testCase, plan.numberOfRuns, 1);
verifyEqual(testCase, runConfig.cost.parameters.nearestVertexCount, 20);
verifyEqual(testCase, runConfig.cost.parameters.pointBatchSize, 200);
verifyEqual(testCase, runConfig.optimizer.seed, 1001);
end


function testCombinedOneSweepConfigurationDefinesOneReproducibleRun(testCase)
%TESTCOMBINEDONESWEEPCONFIGURATIONDEFINESONEREPRODUCIBLERUN Check the blend setup.
% testCase supplies the parsed combined-model specification and verification
% methods. This test confirms that every component and blend setting reaches
% the one scalar runtime configuration used by the one-sweep workflow.

spec = testCase.TestData.combinedOneSweepSpec;
plan = createBonePoseOptimizationExperimentPlan(spec);
runConfig = createBonePoseOptimizationRunConfig( ...
    spec, plan.combinations(1, :), plan.runs.seed(1));

% The model needs both ultrasound images and the aligned 3D surface artifact.
verifyEqual(testCase, spec.cost.model, 'intensityICP');
verifyTrue(testCase, isfile(spec.input.boneSurfaceMatFile));
verifyEqual(testCase, spec.experiment.name, 'oneSweep_intensityICP');

% Fixed settings define the two component models and point-cloud normalization.
verifyEqual(testCase, fieldnames(spec.cost.fixedParameters).', ...
    {'intensityMax', 'sampleSpacingMm', 'nearestVertexCount', 'pointBatchSize', 'distanceReferenceMm'});
verifyEqual(testCase, spec.cost.fixedParameters.intensityMax, 255);
verifyEqual(testCase, spec.cost.fixedParameters.sampleSpacingMm, 0.1);
verifyEqual(testCase, spec.cost.fixedParameters.nearestVertexCount, 20);
verifyEqual(testCase, spec.cost.fixedParameters.pointBatchSize, 200);
verifyEqual(testCase, spec.cost.fixedParameters.distanceReferenceMm, 5);

% The generic planner must retain the component parameters followed by weight.
expectedParameterNames = {'normalFacingToleranceDeg', ...
    'intensitySmoothingSigmaMm', 'weight'};
verifyEqual(testCase, fieldnames(spec.cost.hyperparameters).', ...
    {'intensitySmoothingSigmaMm', 'weight'});
verifyEqual(testCase, plan.parameterNames, expectedParameterNames);
verifyEqual(testCase, plan.numberOfCombinations, 1);
verifyEqual(testCase, plan.numberOfSeeds, 1);
verifyEqual(testCase, plan.numberOfRuns, 1);

% One combined run uses the agreed point-cloud emphasis and no parfor.
verifyEqual(testCase, runConfig.cost.parameters.weight, 0.25);
verifyEqual(testCase, runConfig.cost.parameters.distanceReferenceMm, 5);
verifyEqual(testCase, runConfig.optimizer.seed, 1001);
verifyFalse(testCase, runConfig.optimizer.useParfor);
end


function testPlanBuildsCartesianProductAndRepeatsSeeds(testCase)
%TESTPLANBUILDSCARTESIANPRODUCTANDREPEATSSEEDS Check expansion and run order.
% testCase supplies a valid specification that is copied and expanded. This
% function has no output.

% Use a small mixed-size grid so the expected combination count is easy to verify.
spec = testCase.TestData.sweepSpec;
spec.intersection.normalFacingToleranceDeg = [20 30];
spec.cost.hyperparameters.intensitySmoothingSigmaMm = [0.5 1 2];
spec.experiment.seeds = [7 8 9];
plan = createBonePoseOptimizationExperimentPlan(spec);

% Two-by-three candidates produce six scalar combinations.
verifyEqual(testCase, plan.numberOfCombinations, 6);
verifyEqual(testCase, plan.numberOfSeeds, 3);
verifyEqual(testCase, plan.numberOfRuns, 18);

% The explicit intersection setting stays first, followed by validator order.
expectedParameterNames = {'normalFacingToleranceDeg', ...
    'intensitySmoothingSigmaMm'};
verifyEqual(testCase, plan.parameterNames, expectedParameterNames);
verifyEqual(testCase, plan.combinations.Properties.VariableNames, ...
    [{'combinationNumber', 'combinationId', 'costModel'}, ...
     expectedParameterNames]);
verifyEqual(testCase, plan.runs.Properties.VariableNames, ...
    [{'runNumber', 'runId', 'combinationNumber', 'combinationId', ...
      'costModel', 'seed'}, expectedParameterNames]);

% Preserve the established NDGRID ordering so existing combination IDs keep their meaning.
expectedCombinationValues = [ ...
    20, 0.5; ...
    30, 0.5; ...
    20, 1.0; ...
    30, 1.0; ...
    20, 2.0; ...
    30, 2.0];
verifyEqual(testCase, plan.combinations{:, expectedParameterNames}, ...
    expectedCombinationValues);

% Every combination must receive the same ordered seed list.
for combinationNumber = 1:plan.numberOfCombinations
    selectedRows = plan.runs.combinationNumber == combinationNumber;
    verifyEqual(testCase, plan.runs.seed(selectedRows), [7; 8; 9]);
    verifyEqual(testCase, unique(plan.runs.costModel(selectedRows)), ...
        "intensityLine");
end

% Every plan row stores scalar values that can be copied into a runtime config.
verifyTrue(testCase, all(cellfun(@isscalar, ...
    num2cell(plan.runs.normalFacingToleranceDeg))));
verifyTrue(testCase, all(cellfun(@isscalar, ...
    num2cell(plan.runs.intensitySmoothingSigmaMm))));
end


function testOneSweepConfigurationCreatesOneSeededRun(testCase)
%TESTONESWEEPCONFIGURATIONCREATESONESEEDEDRUN Check the interactive workflow contract.
% testCase supplies the parsed one-sweep specification. This function has
% no output.

% The one-sweep script requires one combination and one repeat seed.
spec = testCase.TestData.oneSweepSpec;
plan = createBonePoseOptimizationExperimentPlan(spec);
verifyEqual(testCase, plan.numberOfCombinations, 1);
verifyEqual(testCase, plan.numberOfSeeds, 1);
verifyEqual(testCase, plan.numberOfRuns, 1);

% Both workflows use this helper to turn a plan row into one executable config.
runConfig = createBonePoseOptimizationRunConfig( ...
    spec, plan.combinations(1, :), plan.runs.seed(1));
verifyTrue(testCase, isscalar(runConfig.intersection.normalFacingToleranceDeg));
verifyEqual(testCase, runConfig.cost.model, 'intensityLine');
verifyTrue(testCase, isscalar(runConfig.cost.parameters.intensityMax));
verifyTrue(testCase, isscalar(runConfig.cost.parameters.sampleSpacingMm));
verifyTrue(testCase, isscalar(runConfig.cost.parameters.intensitySmoothingSigmaMm));
verifyFalse(testCase, isfield(runConfig.cost, 'fixedParameters'));
verifyFalse(testCase, isfield(runConfig.cost, 'hyperparameters'));
verifyEqual(testCase, runConfig.optimizer.seed, spec.experiment.seeds(1));
end


function testDuplicateSeedsAreRejected(testCase)
%TESTDUPLICATESEEDSAREREJECTED Check that repeated stochastic runs stay distinct.
% testCase supplies the checked-in sweep JSON path. This function has no output.

% Copy the JSON data and introduce one duplicate seed for this focused validation test.
rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.experiment.seeds = [1001 1001];
[temporaryConfigPath, temporaryConfigCleanup] = writeTemporaryJson(rawConfig); %#ok<ASGLU>

% The experiment reader should stop before building duplicate run rows.
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'createBonePoseOptimizationExperimentConfig:DuplicateSeed');
clear temporaryConfigCleanup;
end


function testDuplicateCandidatesAreRejected(testCase)
%TESTDUPLICATECANDIDATESAREREJECTED Avoid duplicate hyperparameter combinations.
% testCase supplies the checked-in sweep JSON path. This function has no output.

% Duplicate sigma values would otherwise create two identical optimization groups.
rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.cost.hyperparameters.intensitySmoothingSigmaMm = [1 1];
[temporaryConfigPath, temporaryConfigCleanup] = writeTemporaryJson(rawConfig); %#ok<ASGLU>

% Reject the duplicate while reporting that the candidate list is the problem.
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'validate_cost_intensityLine:DuplicateCandidate');
clear temporaryConfigCleanup;
end


function testValidatorSetsOrderIndependentlyOfJsonFieldOrder(testCase)
%TESTVALIDATORSETSORDERINDEPENDENTLYOFJSONFIELDORDER Check stable columns.
% testCase supplies the checked-in combined sweep JSON path, which has more
% than one hyperparameter to reorder. This function has no output.

% Write equivalent JSON settings with the cost fields in a different order.
rawConfig = jsondecode(fileread(testCase.TestData.combinedSweepConfigPath));
rawConfig.cost.hyperparameters = orderfields( ...
    rawConfig.cost.hyperparameters, ...
    {'weight', 'intensitySmoothingSigmaMm'});
[temporaryConfigPath, temporaryConfigCleanup] = ...
    writeTemporaryJson(rawConfig); %#ok<ASGLU>

% Parsing must restore the model's canonical order before planning starts.
spec = createBonePoseOptimizationExperimentConfig(temporaryConfigPath);
plan = createBonePoseOptimizationExperimentPlan(spec);
verifyEqual(testCase, fieldnames(spec.cost.hyperparameters).', ...
    {'intensitySmoothingSigmaMm', 'weight'});
verifyEqual(testCase, plan.parameterNames, ...
    {'normalFacingToleranceDeg', 'intensitySmoothingSigmaMm', 'weight'});
clear temporaryConfigCleanup;
end


function testPlanRejectsReservedParameterNames(testCase)
%TESTPLANREJECTSRESERVEDPARAMETERNAMES Protect experiment table columns.
% testCase supplies a valid experiment specification. This function has no output.

% A cost parameter must not reuse the seed column owned by the run table.
spec = testCase.TestData.sweepSpec;
spec.cost.hyperparameters.seed = 1;
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentPlan(spec), ...
    'createBonePoseOptimizationExperimentPlan:ReservedParameterName');
end


function testRunConfigCopiesAllDeclaredParameters(testCase)
%TESTRUNCONFIGCOPIESALLDECLAREDPARAMETERS Check generic scalarization.
% testCase supplies a valid sweep specification. This function has no output.

spec = testCase.TestData.sweepSpec;
plan = createBonePoseOptimizationExperimentPlan(spec);
fixedParameterNames = fieldnames(spec.cost.fixedParameters).';
hyperparameterNames = fieldnames(spec.cost.hyperparameters).';
expectedCostNames = [fixedParameterNames, hyperparameterNames];

% Check every combination because each selected value must reach its runtime config.
for combinationIndex = 1:plan.numberOfCombinations
    combinationRow = plan.combinations(combinationIndex, :);
    runConfig = createBonePoseOptimizationRunConfig(spec, combinationRow);

    verifyEqual(testCase, fieldnames(runConfig.cost.parameters).', ...
        expectedCostNames);
    verifyFalse(testCase, isfield(runConfig.cost, 'fixedParameters'));
    verifyFalse(testCase, isfield(runConfig.cost, 'hyperparameters'));
    verifyFalse(testCase, isfield(runConfig.optimizer, 'seed'));

    for parameterIndex = 1:numel(fixedParameterNames)
        parameterName = fixedParameterNames{parameterIndex};
        verifyEqual(testCase, runConfig.cost.parameters.(parameterName), ...
            spec.cost.fixedParameters.(parameterName));
    end

    for parameterIndex = 1:numel(hyperparameterNames)
        parameterName = hyperparameterNames{parameterIndex};
        verifyEqual(testCase, runConfig.cost.parameters.(parameterName), ...
            combinationRow.(parameterName));
        verifyTrue(testCase, isscalar( ...
            runConfig.cost.parameters.(parameterName)));
    end
end
end


function testRunConfigRejectsInvalidCombinationRows(testCase)
%TESTRUNCONFIGREJECTSINVALIDCOMBINATIONROWS Check readable row errors.
% testCase supplies a valid experiment specification and plan. This function has no output.

spec = testCase.TestData.sweepSpec;
plan = createBonePoseOptimizationExperimentPlan(spec);

% A runtime configuration represents one combination, never a table slice.
verifyError(testCase, ...
    @() createBonePoseOptimizationRunConfig(spec, plan.combinations(1:2, :)), ...
    'createBonePoseOptimizationRunConfig:ExpectedOneCombinationRow');

% Prevent a row from a different model being used with this experiment specification.
mismatchedRow = plan.combinations(1, :);
mismatchedRow.costModel = "another_model";
verifyError(testCase, ...
    @() createBonePoseOptimizationRunConfig(spec, mismatchedRow), ...
    'createBonePoseOptimizationRunConfig:CostModelMismatch');

% Report an omitted parameter column directly instead of failing inside a cost evaluation.
missingColumnRow = removevars(plan.combinations(1, :), 'intensitySmoothingSigmaMm');
verifyError(testCase, ...
    @() createBonePoseOptimizationRunConfig(spec, missingColumnRow), ...
    'createBonePoseOptimizationRunConfig:MissingParameterColumn');
end


function testUnsupportedSchemaAndModelAreRejected(testCase)
%TESTUNSUPPORTEDSCHEMAANDMODELAREREJECTED Check the two version boundaries.
% testCase supplies the active sweep JSON and MATLAB verification methods.

rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.schemaVersion = 3;
[temporaryConfigPath, temporaryConfigCleanup] = ...
    writeTemporaryJson(rawConfig); %#ok<ASGLU>
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'createBonePoseOptimizationConfig:UnsupportedSchemaVersion');
clear temporaryConfigCleanup;

rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.cost.model = 'unknown_model';
[temporaryConfigPath, temporaryConfigCleanup] = ...
    writeTemporaryJson(rawConfig); %#ok<ASGLU>
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'getBonePoseCostDefinition:UnsupportedModel');
clear temporaryConfigCleanup;
end


function testCostParameterSpellingIsValidated(testCase)
%TESTCOSTPARAMETERSPELLINGISVALIDATED Check missing and unexpected model fields.
% testCase supplies the active sweep JSON and MATLAB verification methods.

rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.cost.fixedParameters = rmfield( ...
    rawConfig.cost.fixedParameters, 'sampleSpacingMm');
[temporaryConfigPath, temporaryConfigCleanup] = ...
    writeTemporaryJson(rawConfig); %#ok<ASGLU>
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'validate_cost_intensityLine:MissingParameter');
clear temporaryConfigCleanup;

rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.cost.hyperparameters.misspelledParameter = 1;
[temporaryConfigPath, temporaryConfigCleanup] = ...
    writeTemporaryJson(rawConfig); %#ok<ASGLU>
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'validate_cost_intensityLine:UnexpectedParameter');
clear temporaryConfigCleanup;
end


function testPreparationFailuresAreSavedAndDoNotStopSeeds(testCase)
%TESTPREPARATIONFAILURESARESAVEDANDDONOTSTOPSEEDS Check simple unattended failure handling.
% testCase supplies a valid active spec that is redirected to temporary output.
% This function has no output.

% Use a missing input so this test exercises output handling without running CMA-ES.
temporaryOutputRoot = tempname;
temporaryOutputCleanup = onCleanup(@() removeTemporaryFolder(temporaryOutputRoot));
spec = createPreparationFailureSpec(testCase.TestData.sweepSpec, temporaryOutputRoot);

% One preparation failure should create one failed result for each planned seed.
experimentResult = runBonePoseOptimizationExperiment(spec);
verifyEqual(testCase, experimentResult.summaryTable.status, ...
    ["failed"; "failed"]);
verifyEqual(testCase, experimentResult.summaryTable.costModel, ...
    repmat("intensityLine", 2, 1));
verifyTrue(testCase, all(isfile(experimentResult.summaryTable.resultFilePath)));
verifyTrue(testCase, isfile(fullfile( ...
    experimentResult.experimentFolder, 'summary.csv')));
verifyFalse(testCase, isfile(fullfile( ...
    experimentResult.experimentFolder, 'validation_context.mat')));

% The log file must hold the printed progress, including the closing line.
logText = fileread(fullfile(experimentResult.experimentFolder, 'experiment_log.txt'));
verifySubstring(testCase, logText, 'Created experiment');
verifySubstring(testCase, logText, 'Experiment finished: 0 completed, 2 failed');

% Summary rows must preserve every planned identity and parameter column unchanged.
plannedColumnNames = experimentResult.experimentPlan.runs.Properties.VariableNames;
verifyEqual(testCase, ...
    experimentResult.summaryTable(:, plannedColumnNames), ...
    experimentResult.experimentPlan.runs);

% Failed runs still record the exact scalar cost configuration that was attempted.
savedRun = load(char(experimentResult.summaryTable.resultFilePath(1)), 'runResult');
verifyEqual(testCase, savedRun.runResult.configuration.cost.model, ...
    'intensityLine');
verifyTrue(testCase, isscalar( ...
    savedRun.runResult.configuration.cost.parameters.intensitySmoothingSigmaMm));

% A second invocation creates a separate experiment instead of resuming the first.
secondResult = runBonePoseOptimizationExperiment(spec);
verifyNotEqual(testCase, secondResult.experimentFolder, ...
    experimentResult.experimentFolder);
clear temporaryOutputCleanup;
end


function testResumeRerunsOnlyMissingAndCorruptResults(testCase)
%TESTRESUMERERUNSONLYMISSINGANDCORRUPTRESULTS Check which runs a resume redoes.
% testCase supplies a valid active spec that is redirected to temporary output.
% This function has no output.
%
% The spec fails during preparation, so every run ends "failed" within
% milliseconds and no CMA-ES is needed. That is enough to test the resume
% bookkeeping: which runs are skipped and which are run again.

temporaryOutputRoot = tempname;
temporaryOutputCleanup = onCleanup(@() removeTemporaryFolder(temporaryOutputRoot));
spec = createPreparationFailureSpec(testCase.TestData.sweepSpec, temporaryOutputRoot);

% Run the experiment once; it creates one result file per seed.
firstResult      = runBonePoseOptimizationExperiment(spec);
experimentFolder = firstResult.experimentFolder;
seed31FilePath   = char(firstResult.summaryTable.resultFilePath(1));
seed32FilePath   = char(firstResult.summaryTable.resultFilePath(2));
seed31StartTime  = loadRunStartTime(seed31FilePath);

% Simulate a crash before seed 32 was saved: its result file is missing.
delete(seed32FilePath);
spec.experiment.resumeFolder = experimentFolder;
resumedResult = runBonePoseOptimizationExperiment(spec);

% The same folder is reused, and no second experiment folder appears.
verifyEqual(testCase, resumedResult.experimentFolder, experimentFolder);
verifyEqual(testCase, numel(listSubfolders(temporaryOutputRoot)), 1);
% Seed 32 was run again; seed 31 ("failed") was kept as it was, not rerun.
verifyEqual(testCase, resumedResult.summaryTable.status, ["failed"; "failed"]);
verifyTrue(testCase, isfile(seed32FilePath));
verifyEqual(testCase, loadRunStartTime(seed31FilePath), seed31StartTime);

% Simulate a file that was half-written when MATLAB stopped: junk bytes.
fileId = fopen(seed31FilePath, 'w');
fwrite(fileId, 'not a MAT file', 'char');
fclose(fileId);
resumedAgainResult = runBonePoseOptimizationExperiment(spec);

% The corrupt file was replaced by a new, loadable result.
verifyEqual(testCase, resumedAgainResult.summaryTable.status, ["failed"; "failed"]);
verifyNotEqual(testCase, loadRunStartTime(seed31FilePath), seed31StartTime);

% Both resumes are recorded in the same log file as the first session.
logText = fileread(fullfile(experimentFolder, 'experiment_log.txt'));
verifySubstring(testCase, logText, 'Created experiment');
verifySubstring(testCase, logText, '1 of 2 runs already finished, 1 runs still to do.');
clear temporaryOutputCleanup;
end


function testSaveFailureIsMarkedAndRerunOnResume(testCase)
%TESTSAVEFAILUREISMARKEDANDRERUNONRESUME Check save_failed inside the sweep.
% testCase supplies a valid active spec that is redirected to temporary output.
% This function has no output.
%
% A real Windows lock cannot be created on demand. A FOLDER named like the
% temporary save file ("runResult_partial.mat") blocks every save attempt
% instead. The experiment folder name contains a timestamp, so the folder
% is created by a first run, and the blocked save happens during a resume.
% Note: this test waits for the runner's real save retries (about 10 s).

temporaryOutputRoot = tempname;
temporaryOutputCleanup = onCleanup(@() removeTemporaryFolder(temporaryOutputRoot));
spec = createPreparationFailureSpec(testCase.TestData.sweepSpec, temporaryOutputRoot);

firstResult    = runBonePoseOptimizationExperiment(spec);
seed32FilePath = char(firstResult.summaryTable.resultFilePath(2));

% Remove seed 32's result so the resume runs it again, and block its save.
delete(seed32FilePath);
blockingFolder = fullfile(fileparts(seed32FilePath), 'runResult_partial.mat');
mkdir(blockingFolder);
spec.experiment.resumeFolder = firstResult.experimentFolder;
blockedResult = runBonePoseOptimizationExperiment(spec);

% The sweep did not stop: seed 32 is marked save_failed and the summary
% files were still written.
verifyEqual(testCase, blockedResult.summaryTable.status, ["failed"; "save_failed"]);
verifyEqual(testCase, blockedResult.summaryTable.errorStage(2), "save");
% The identifier of the save error is kept, like for any other error.
verifyNotEqual(testCase, blockedResult.summaryTable.errorIdentifier(2), "");
verifyFalse(testCase, isfile(seed32FilePath));
verifyTrue(testCase, isfile(fullfile(firstResult.experimentFolder, 'summary.csv')));

% Once the lock is gone, the next resume reruns the save_failed run.
rmdir(blockingFolder);
unblockedResult = runBonePoseOptimizationExperiment(spec);
verifyEqual(testCase, unblockedResult.summaryTable.status, ["failed"; "failed"]);
verifyTrue(testCase, isfile(seed32FilePath));
clear temporaryOutputCleanup;
end


function testRunsStoppedBySaveErrorAreRerunOnResume(testCase)
%TESTRUNSSTOPPEDBYSAVEERRORARERERUNONRESUME Check resume after a save error.
% testCase supplies a valid active spec that is redirected to temporary output.
% This function has no output.
%
% CMA-ES saves its own files, so an optimization can stop with a
% MATLAB:save error on a full or locked disk. Such a run is saved as
% "save_failed" (older sweeps saved it as "failed") and must be rerun on
% resume, because the problem was the machine and not the settings.

temporaryOutputRoot = tempname;
temporaryOutputCleanup = onCleanup(@() removeTemporaryFolder(temporaryOutputRoot));
spec = createPreparationFailureSpec(testCase.TestData.sweepSpec, temporaryOutputRoot);

firstResult    = runBonePoseOptimizationExperiment(spec);
seed31FilePath = char(firstResult.summaryTable.resultFilePath(1));
seed32FilePath = char(firstResult.summaryTable.resultFilePath(2));

% Turn both saved runs into runs stopped by a save error: seed 31 as a
% current sweep stores it, seed 32 as an older sweep stored it.
storeSaveError(seed31FilePath, 'save_failed');
storeSaveError(seed32FilePath, 'failed');
seed31StartTime = loadRunStartTime(seed31FilePath);
seed32StartTime = loadRunStartTime(seed32FilePath);

% The resume reruns both runs, so both get a new start time.
spec.experiment.resumeFolder = firstResult.experimentFolder;
resumedResult = runBonePoseOptimizationExperiment(spec);
verifyEqual(testCase, resumedResult.summaryTable.status, ["failed"; "failed"]);
verifyNotEqual(testCase, loadRunStartTime(seed31FilePath), seed31StartTime);
verifyNotEqual(testCase, loadRunStartTime(seed32FilePath), seed32StartTime);
clear temporaryOutputCleanup;
end


function testResumeFolderIsEmptyByDefault(testCase)
%TESTRESUMEFOLDERISEMPTYBYDEFAULT A template starts a new experiment.
% testCase supplies the parsed template spec. This function has no output.

verifyEqual(testCase, testCase.TestData.sweepSpec.experiment.resumeFolder, '');
end


function testResumeAcceptsUnchangedSettings(testCase)
%TESTRESUMEACCEPTSUNCHANGEDSETTINGS Resuming with the original JSON is allowed.
% testCase supplies the checked-in sweep JSON path. This function has no output.

% A fake experiment folder whose snapshot is the template JSON itself.
experimentFolder = tempname;
mkdir(experimentFolder);
folderCleanup = onCleanup(@() removeTemporaryFolder(experimentFolder));
copyfile(testCase.TestData.sweepConfigPath, fullfile(experimentFolder, 'experiment_config_snapshot.json'));

% The same JSON, now pointing at that folder.
rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.experiment.resumeFolder = experimentFolder;
[temporaryConfigPath, temporaryConfigCleanup] = writeTemporaryJson(rawConfig); %#ok<ASGLU>

spec = createBonePoseOptimizationExperimentConfig(temporaryConfigPath);
verifyTrue(testCase, isfile(fullfile(spec.experiment.resumeFolder, 'experiment_config_snapshot.json')));
clear temporaryConfigCleanup folderCleanup;
end


function testResumeRejectsChangedSettings(testCase)
%TESTRESUMEREJECTSCHANGEDSETTINGS Edited settings must not be silently ignored.
% testCase supplies the checked-in sweep JSON path. This function has no output.

experimentFolder = tempname;
mkdir(experimentFolder);
folderCleanup = onCleanup(@() removeTemporaryFolder(experimentFolder));
copyfile(testCase.TestData.sweepConfigPath, fullfile(experimentFolder, 'experiment_config_snapshot.json'));

% Change one setting compared to the snapshot.
rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.experiment.resumeFolder = experimentFolder;
rawConfig.experiment.seeds = [7 8];
[temporaryConfigPath, temporaryConfigCleanup] = writeTemporaryJson(rawConfig); %#ok<ASGLU>

% The error must name the changed field, so the user knows what to restore.
resumeError = [];
try
    createBonePoseOptimizationExperimentConfig(temporaryConfigPath);
catch resumeError
end
verifyNotEmpty(testCase, resumeError);
verifyEqual(testCase, resumeError.identifier, ...
    'createBonePoseOptimizationExperimentConfig:ResumeSettingsChanged');
verifySubstring(testCase, resumeError.message, 'experiment.seeds');
clear temporaryConfigCleanup folderCleanup;
end


function testResumeRejectsMissingFolder(testCase)
%TESTRESUMEREJECTSMISSINGFOLDER A wrong resume path stops with a clear error.
% testCase supplies the checked-in sweep JSON path. This function has no output.

rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.experiment.resumeFolder = tempname;
[temporaryConfigPath, temporaryConfigCleanup] = writeTemporaryJson(rawConfig); %#ok<ASGLU>

verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'createBonePoseOptimizationExperimentConfig:ResumeFolderNotFound');
clear temporaryConfigCleanup;
end


function spec = createPreparationFailureSpec(sweepSpec, outputRoot)
%CREATEPREPARATIONFAILURESPEC Build a tiny spec whose preparation always fails.
% sweepSpec is the parsed template spec and outputRoot the temporary output
% folder. spec has one combination and two seeds (31, 32), and points at a
% missing input file, so every run fails at once without running CMA-ES.

spec = sweepSpec;
spec.experiment.name = 'schemaVersion04_failure_test';
spec.experiment.outputFolder = outputRoot;
spec.experiment.seeds = [31 32];
spec.intersection.normalFacingToleranceDeg = ...
    spec.intersection.normalFacingToleranceDeg(1);
spec.cost.hyperparameters.intensitySmoothingSigmaMm = ...
    spec.cost.hyperparameters.intensitySmoothingSigmaMm(1);
spec.input.validSnapshotsMatFile = fullfile(outputRoot, 'missing.mat');
end


function startTime = loadRunStartTime(resultFilePath)
%LOADRUNSTARTTIME Read the start time stored in one runResult.mat.
% resultFilePath is the run file and startTime its run.startTime text. A
% changed start time shows that the run was executed again.

savedFile = load(resultFilePath, 'runResult');
startTime = savedFile.runResult.run.startTime;
end


function storeSaveError(resultFilePath, status)
%STORESAVEERROR Rewrite one runResult.mat as a run stopped by a save error.
% resultFilePath is the run file and status the run status to store. The
% start time is also changed, so a later rerun is visible even when it
% happens within the same millisecond as the first run.

savedFile = load(resultFilePath, 'runResult');
runResult = savedFile.runResult;
runResult.run.status         = status;
runResult.run.startTime      = '2000-01-01 00:00:00.000';
runResult.error.stage        = 'optimization';
runResult.error.identifier   = 'MATLAB:save:cantWriteFile';
runResult.error.message      = 'Unable to write file variablescmaes.mat.';
save(resultFilePath, 'runResult');
end


function folderNames = listSubfolders(parentFolder)
%LISTSUBFOLDERS Return the names of the folders directly inside a folder.
% parentFolder is the folder to list and folderNames a cell array of names,
% without "." and "..".

folderEntries = dir(parentFolder);
folderEntries = folderEntries([folderEntries.isdir]);
folderNames   = setdiff({folderEntries.name}, {'.', '..'});
end


function [temporaryConfigPath, cleanupObject] = writeTemporaryJson(rawConfig)
%WRITETEMPORARYJSON Save a JSON-derived struct for one reader validation test.
% rawConfig is the MATLAB struct to encode, temporaryConfigPath is the new
% JSON path, and cleanupObject deletes the file when the test finishes.

% Use a unique system-temporary path so parallel test sessions do not collide.
temporaryConfigPath = [tempname '.json'];
fileId = fopen(temporaryConfigPath, 'w');
if fileId < 0
    error('testBonePoseOptimizationExperiment:TemporaryFileOpenFailed', ...
        'Could not open a temporary JSON file for writing.');
end
fileCleanup = onCleanup(@() fclose(fileId));
fwrite(fileId, jsonencode(rawConfig, 'PrettyPrint', true), 'char');
clear fileCleanup;

% Return cleanup ownership to the calling test.
cleanupObject = onCleanup(@() deleteTemporaryFile(temporaryConfigPath));
end


function deleteTemporaryFile(filePath)
%DELETETEMPORARYFILE Delete one temporary JSON file when it still exists.
% filePath identifies the temporary file. This function has no output.

% The existence check keeps cleanup harmless if a failed test already removed the file.
if isfile(filePath)
    delete(filePath);
end
end


function removeTemporaryFolder(folderPath)
%REMOVETEMPORARYFOLDER Delete the temporary experiment tree after a test.
% folderPath identifies the test-owned folder. This function has no output.

% Recursive removal is limited to the unique tempname path created by this test.
if isfolder(folderPath)
    rmdir(folderPath, 's');
end
end
