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
    'optconfig_hyperparamSweep_intensityCov.json');
oneSweepConfigPath = fullfile(projectRoot, 'config', ...
    'optconfig_oneSweep_intensityCov.json');
ICPLikeOneSweepConfigPath = fullfile(projectRoot, 'config', ...
    'optconfig_oneSweep_ICPLike.json');
combinedOneSweepConfigPath = fullfile(projectRoot, 'config', ...
    'optconfig_oneSweep_intensityICP.json');
testCase.TestData.projectRoot = projectRoot;
testCase.TestData.sweepConfigPath = sweepConfigPath;
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
verifyEqual(testCase, spec.cost.model, 'intensityCov_v1');
verifyTrue(testCase, all(spec.intersection.normalFacingToleranceDeg > 0));
verifyTrue(testCase, all(spec.cost.hyperparameters.minReferencePixels > 0));
verifyTrue(testCase, all(spec.cost.hyperparameters.nMinPixels > 0));
verifyTrue(testCase, all(spec.cost.hyperparameters.lambdaMissing >= 0));
verifyTrue(testCase, isscalar(spec.cost.fixedParameters.intensityMax));
verifyTrue(testCase, all(spec.experiment.seeds > 0));
verifyEqual(testCase, numel(unique(spec.experiment.seeds)), ...
    numel(spec.experiment.seeds));
verifyTrue(testCase, isfolder(fileparts(spec.experiment.outputFolder)));

% The model validator returns the parameter groups in their canonical order.
verifyEqual(testCase, fieldnames(spec.cost.fixedParameters).', ...
    {'intensityMax'});
verifyEqual(testCase, fieldnames(spec.cost.hyperparameters).', ...
    {'minReferencePixels', 'nMinPixels', 'lambdaMissing'});
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
verifyEqual(testCase, spec.cost.model, 'ICPLike_v1');
verifyTrue(testCase, isfile(spec.input.boneSurfaceMatFile));
verifyEqual(testCase, spec.experiment.name, 'oneSweep_ICPLike_v01');

% K stays fixed, while the retained intersection tolerance creates only one plan row.
verifyEqual(testCase, spec.cost.fixedParameters.nearestVertexCount, 20);
verifyEmpty(testCase, fieldnames(spec.cost.hyperparameters));
verifyEqual(testCase, plan.parameterNames, {'normalFacingToleranceDeg'});
verifyEqual(testCase, plan.numberOfCombinations, 1);
verifyEqual(testCase, plan.numberOfSeeds, 1);
verifyEqual(testCase, plan.numberOfRuns, 1);
verifyEqual(testCase, runConfig.cost.parameters.nearestVertexCount, 20);
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
verifyEqual(testCase, spec.cost.model, 'intensityICP_v1');
verifyTrue(testCase, isfile(spec.input.boneSurfaceMatFile));
verifyEqual(testCase, spec.experiment.name, 'oneSweep_intensityICP_v01');

% Fixed settings define the two component models and point-cloud normalization.
verifyEqual(testCase, fieldnames(spec.cost.fixedParameters).', ...
    {'intensityMax', 'nearestVertexCount', 'distanceReferenceMm'});
verifyEqual(testCase, spec.cost.fixedParameters.intensityMax, 255);
verifyEqual(testCase, spec.cost.fixedParameters.nearestVertexCount, 20);
verifyEqual(testCase, spec.cost.fixedParameters.distanceReferenceMm, 5);

% The generic planner must retain the component parameters followed by weight.
expectedParameterNames = {'normalFacingToleranceDeg', ...
    'minReferencePixels', 'nMinPixels', 'lambdaMissing', 'weight'};
verifyEqual(testCase, fieldnames(spec.cost.hyperparameters).', ...
    {'minReferencePixels', 'nMinPixels', 'lambdaMissing', 'weight'});
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
spec.cost.hyperparameters.minReferencePixels = 50;
spec.cost.hyperparameters.nMinPixels = [50 100];
spec.cost.hyperparameters.lambdaMissing = [0.5 1.0];
spec.experiment.seeds = [7 8 9];
plan = createBonePoseOptimizationExperimentPlan(spec);

% Two-by-one-by-two-by-two candidates produce eight scalar combinations.
verifyEqual(testCase, plan.numberOfCombinations, 8);
verifyEqual(testCase, plan.numberOfSeeds, 3);
verifyEqual(testCase, plan.numberOfRuns, 24);

% The explicit intersection setting stays first, followed by validator order.
expectedParameterNames = {'normalFacingToleranceDeg', ...
    'minReferencePixels', 'nMinPixels', 'lambdaMissing'};
verifyEqual(testCase, plan.parameterNames, expectedParameterNames);
verifyEqual(testCase, plan.combinations.Properties.VariableNames, ...
    [{'combinationNumber', 'combinationId', 'costModel'}, ...
     expectedParameterNames]);
verifyEqual(testCase, plan.runs.Properties.VariableNames, ...
    [{'runNumber', 'runId', 'combinationNumber', 'combinationId', ...
      'costModel', 'seed'}, expectedParameterNames]);

% Preserve the established NDGRID ordering so existing combination IDs keep their meaning.
expectedCombinationValues = [ ...
    20, 50,  50, 0.5; ...
    30, 50,  50, 0.5; ...
    20, 50, 100, 0.5; ...
    30, 50, 100, 0.5; ...
    20, 50,  50, 1.0; ...
    30, 50,  50, 1.0; ...
    20, 50, 100, 1.0; ...
    30, 50, 100, 1.0];
verifyEqual(testCase, plan.combinations{:, expectedParameterNames}, ...
    expectedCombinationValues);

% Every combination must receive the same ordered seed list.
for combinationNumber = 1:plan.numberOfCombinations
    selectedRows = plan.runs.combinationNumber == combinationNumber;
    verifyEqual(testCase, plan.runs.seed(selectedRows), [7; 8; 9]);
    verifyEqual(testCase, unique(plan.runs.costModel(selectedRows)), ...
        "intensityCov_v1");
end

% Every plan row stores scalar values that can be copied into a runtime config.
verifyTrue(testCase, all(cellfun(@isscalar, ...
    num2cell(plan.runs.normalFacingToleranceDeg))));
verifyTrue(testCase, all(cellfun(@isscalar, ...
    num2cell(plan.runs.lambdaMissing))));
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
verifyEqual(testCase, runConfig.cost.model, 'intensityCov_v1');
verifyTrue(testCase, isscalar(runConfig.cost.parameters.intensityMax));
verifyTrue(testCase, isscalar(runConfig.cost.parameters.minReferencePixels));
verifyTrue(testCase, isscalar(runConfig.cost.parameters.nMinPixels));
verifyTrue(testCase, isscalar(runConfig.cost.parameters.lambdaMissing));
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

% Duplicate lambda values would otherwise create two identical optimization groups.
rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.cost.hyperparameters.lambdaMissing = [1 1];
[temporaryConfigPath, temporaryConfigCleanup] = writeTemporaryJson(rawConfig); %#ok<ASGLU>

% Reject the duplicate while reporting that the candidate list is the problem.
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'validate_cost_intensityCov_v01:DuplicateCandidate');
clear temporaryConfigCleanup;
end


function testValidatorSetsOrderIndependentlyOfJsonFieldOrder(testCase)
%TESTVALIDATORSETSORDERINDEPENDENTLYOFJSONFIELDORDER Check stable columns.
% testCase supplies the checked-in sweep JSON path. This function has no output.

% Write equivalent JSON settings with the cost fields in a different order.
rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.cost.hyperparameters = orderfields( ...
    rawConfig.cost.hyperparameters, ...
    {'lambdaMissing', 'nMinPixels', 'minReferencePixels'});
[temporaryConfigPath, temporaryConfigCleanup] = ...
    writeTemporaryJson(rawConfig); %#ok<ASGLU>

% Parsing must restore the model's canonical order before planning starts.
spec = createBonePoseOptimizationExperimentConfig(temporaryConfigPath);
plan = createBonePoseOptimizationExperimentPlan(spec);
verifyEqual(testCase, fieldnames(spec.cost.hyperparameters).', ...
    {'minReferencePixels', 'nMinPixels', 'lambdaMissing'});
verifyEqual(testCase, plan.parameterNames, ...
    {'normalFacingToleranceDeg', 'minReferencePixels', ...
     'nMinPixels', 'lambdaMissing'});
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
missingColumnRow = removevars(plan.combinations(1, :), 'lambdaMissing');
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
%TESTCOSTPARAMETERSPELLINGISVALIDATED Check missing and unexpected V1 fields.
% testCase supplies the active sweep JSON and MATLAB verification methods.

rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.cost.hyperparameters = rmfield( ...
    rawConfig.cost.hyperparameters, 'nMinPixels');
[temporaryConfigPath, temporaryConfigCleanup] = ...
    writeTemporaryJson(rawConfig); %#ok<ASGLU>
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'validate_cost_intensityCov_v01:MissingParameter');
clear temporaryConfigCleanup;

rawConfig = jsondecode(fileread(testCase.TestData.sweepConfigPath));
rawConfig.cost.hyperparameters.misspelledParameter = 1;
[temporaryConfigPath, temporaryConfigCleanup] = ...
    writeTemporaryJson(rawConfig); %#ok<ASGLU>
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'validate_cost_intensityCov_v01:UnexpectedParameter');
clear temporaryConfigCleanup;
end


function testPreparationFailuresAreSavedAndDoNotStopSeeds(testCase)
%TESTPREPARATIONFAILURESARESAVEDANDDONOTSTOPSEEDS Check simple unattended failure handling.
% testCase supplies a valid active spec that is redirected to temporary output.
% This function has no output.

% Use a missing input so this test exercises output handling without running CMA-ES.
spec = testCase.TestData.sweepSpec;
temporaryOutputRoot = tempname;
temporaryOutputCleanup = onCleanup(@() removeTemporaryFolder(temporaryOutputRoot));
spec.experiment.name = 'schemaVersion04_failure_test';
spec.experiment.outputFolder = temporaryOutputRoot;
spec.experiment.seeds = [31 32];
spec.intersection.normalFacingToleranceDeg = ...
    spec.intersection.normalFacingToleranceDeg(1);
spec.cost.hyperparameters.minReferencePixels = ...
    spec.cost.hyperparameters.minReferencePixels(1);
spec.cost.hyperparameters.nMinPixels = ...
    spec.cost.hyperparameters.nMinPixels(1);
spec.cost.hyperparameters.lambdaMissing = ...
    spec.cost.hyperparameters.lambdaMissing(1);
spec.input.validSnapshotsMatFile = fullfile(temporaryOutputRoot, 'missing.mat');

% One preparation failure should create one failed result for each planned seed.
experimentResult = runBonePoseOptimizationExperiment(spec);
verifyEqual(testCase, experimentResult.summaryTable.status, ...
    ["failed"; "failed"]);
verifyEqual(testCase, experimentResult.summaryTable.costModel, ...
    repmat("intensityCov_v1", 2, 1));
verifyTrue(testCase, all(isfile(experimentResult.summaryTable.resultFilePath)));
verifyTrue(testCase, isfile(fullfile( ...
    experimentResult.experimentFolder, 'summary.csv')));
verifyFalse(testCase, isfile(fullfile( ...
    experimentResult.experimentFolder, 'validation_context.mat')));

% Summary rows must preserve every planned identity and parameter column unchanged.
plannedColumnNames = experimentResult.experimentPlan.runs.Properties.VariableNames;
verifyEqual(testCase, ...
    experimentResult.summaryTable(:, plannedColumnNames), ...
    experimentResult.experimentPlan.runs);

% Failed runs still record the exact scalar cost configuration that was attempted.
savedRun = load(char(experimentResult.summaryTable.resultFilePath(1)), 'runResult');
verifyEqual(testCase, savedRun.runResult.configuration.cost.model, ...
    'intensityCov_v1');
verifyTrue(testCase, isscalar( ...
    savedRun.runResult.configuration.cost.parameters.lambdaMissing));

% A second invocation creates a separate experiment instead of resuming the first.
secondResult = runBonePoseOptimizationExperiment(spec);
verifyNotEqual(testCase, secondResult.experimentFolder, ...
    experimentResult.experimentFolder);
clear temporaryOutputCleanup;
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
