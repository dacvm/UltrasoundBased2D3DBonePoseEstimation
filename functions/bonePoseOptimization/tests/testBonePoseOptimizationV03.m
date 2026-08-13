function tests = testBonePoseOptimizationV03
%TESTBONEPOSEOPTIMIZATIONV03 Test v03 configuration and experiment planning.
% This suite checks candidate parsing, Cartesian-product planning, shared
% repeat seeds, failure recording, and preservation of the v02 scalar flow.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

% Let MATLAB discover every local function whose name starts with test.
tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Load the real v02 and v03 configurations once for this suite.
% testCase receives the project root, configuration paths, and parsed
% configurations in TestData. This function has no output.

% Walk from this test file through tests/, bonePoseOptimization/, and functions/.
testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Parse both versions so later tests can stay focused on one behavior.
v02ConfigPath = fullfile(projectRoot, 'config', ...
    'bonePoseOptimizationConfig_v02.json');
v03ConfigPath = fullfile(projectRoot, 'config', ...
    'bonePoseOptimizationConfig_v03.json');
testCase.TestData.projectRoot = projectRoot;
testCase.TestData.v02ConfigPath = v02ConfigPath;
testCase.TestData.v03ConfigPath = v03ConfigPath;
testCase.TestData.v02Config = createBonePoseOptimizationConfig(v02ConfigPath);
testCase.TestData.v03Spec = ...
    createBonePoseOptimizationExperimentConfig(v03ConfigPath);
end


function testV03ConfigurationKeepsCandidatesAndSeeds(testCase)
%TESTV03CONFIGURATIONKEEPSCANDIDATESANDSEEDS Check the checked-in v03 defaults.
% testCase supplies the parsed v03 specification. This function has no output.

% The initial checked-in configuration is intentionally a small one-combination sweep.
spec = testCase.TestData.v03Spec;
verifyEqual(testCase, spec.intersection.normalFacingToleranceDeg, 30);
verifyEqual(testCase, spec.cost.minReferencePixels, 50);
verifyEqual(testCase, spec.cost.nMinPixels, 100);
verifyEqual(testCase, spec.cost.lambdaMissing, 1);
verifyEqual(testCase, spec.experiment.seeds, 1001:1005);
verifyTrue(testCase, isfolder(fileparts(spec.experiment.outputFolder)));
end


function testPlanBuildsCartesianProductAndRepeatsSeeds(testCase)
%TESTPLANBUILDSCARTESIANPRODUCTANDREPEATSSEEDS Check expansion and run order.
% testCase supplies a valid specification that is copied and expanded. This
% function has no output.

% Use a small mixed-size grid so the expected combination count is easy to verify.
spec = testCase.TestData.v03Spec;
spec.intersection.normalFacingToleranceDeg = [20 30];
spec.cost.minReferencePixels = 50;
spec.cost.nMinPixels = [50 100];
spec.cost.lambdaMissing = [0.5 1.0];
spec.experiment.seeds = [7 8 9];
plan = createBonePoseOptimizationExperimentPlan(spec);

% Two-by-one-by-two-by-two candidates produce eight scalar combinations.
verifyEqual(testCase, plan.numberOfCombinations, 8);
verifyEqual(testCase, plan.numberOfSeeds, 3);
verifyEqual(testCase, plan.numberOfRuns, 24);

% Every combination must receive the same ordered seed list.
for combinationNumber = 1:plan.numberOfCombinations
    selectedRows = plan.runs.combinationNumber == combinationNumber;
    verifyEqual(testCase, plan.runs.seed(selectedRows), [7; 8; 9]);
end

% Every plan row stores scalar values that can be copied into a runtime config.
verifyTrue(testCase, all(cellfun(@isscalar, ...
    num2cell(plan.runs.normalFacingToleranceDeg))));
verifyTrue(testCase, all(cellfun(@isscalar, ...
    num2cell(plan.runs.lambdaMissing))));
end


function testDuplicateSeedsAreRejected(testCase)
%TESTDUPLICATESEEDSAREREJECTED Check that repeated stochastic runs stay distinct.
% testCase supplies the checked-in v03 JSON path. This function has no output.

% Copy the JSON data and introduce one duplicate seed for this focused validation test.
rawConfig = jsondecode(fileread(testCase.TestData.v03ConfigPath));
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
% testCase supplies the checked-in v03 JSON path. This function has no output.

% Duplicate lambda values would otherwise create two identical optimization groups.
rawConfig = jsondecode(fileread(testCase.TestData.v03ConfigPath));
rawConfig.cost.lambdaMissing = [1 1];
[temporaryConfigPath, temporaryConfigCleanup] = writeTemporaryJson(rawConfig); %#ok<ASGLU>

% Reject the duplicate while reporting that the candidate list is the problem.
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'createBonePoseOptimizationExperimentConfig:DuplicateCandidate');
clear temporaryConfigCleanup;
end


function testV02ConfigurationRemainsScalar(testCase)
%TESTV02CONFIGURATIONREMAINSSCALAR Check backward compatibility of the old reader.
% testCase supplies the parsed v02 configuration. This function has no output.

% The v02 script must still receive one immediately executable scalar configuration.
config = testCase.TestData.v02Config;
verifyTrue(testCase, isscalar(config.intersection.normalFacingToleranceDeg));
verifyTrue(testCase, isscalar(config.cost.minReferencePixels));
verifyTrue(testCase, isscalar(config.cost.nMinPixels));
verifyTrue(testCase, isscalar(config.cost.lambdaMissing));
verifyFalse(testCase, isfield(config.optimizer, 'seed'));
end


function testPreparationFailuresAreSavedAndDoNotStopSeeds(testCase)
%TESTPREPARATIONFAILURESARESAVEDANDDONOTSTOPSEEDS Check simple unattended failure handling.
% testCase supplies a valid v03 spec that is redirected to temporary output.
% This function has no output.

% Use a missing input so this test exercises output handling without running CMA-ES.
spec = testCase.TestData.v03Spec;
temporaryOutputRoot = tempname;
temporaryOutputCleanup = onCleanup(@() removeTemporaryFolder(temporaryOutputRoot));
spec.experiment.name = 'v03_failure_test';
spec.experiment.outputFolder = temporaryOutputRoot;
spec.experiment.seeds = [31 32];
spec.input.validSnapshotsMatFile = fullfile(temporaryOutputRoot, 'missing.mat');

% One preparation failure should create one failed result for each planned seed.
experimentResult = runBonePoseOptimizationExperiment(spec);
verifyEqual(testCase, experimentResult.summaryTable.status, ...
    ["failed"; "failed"]);
verifyTrue(testCase, all(isfile(experimentResult.summaryTable.resultFilePath)));
verifyTrue(testCase, isfile(fullfile( ...
    experimentResult.experimentFolder, 'summary.csv')));
verifyFalse(testCase, isfile(fullfile( ...
    experimentResult.experimentFolder, 'validation_context.mat')));

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
    error('testBonePoseOptimizationV03:TemporaryFileOpenFailed', ...
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
