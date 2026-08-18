function tests = testBonePoseCostDispatcher
%TESTBONEPOSECOSTDISPATCHER Test the stable cost-function entry point.
% This suite compares the public dispatcher with the version 1 intensity
% implementation. It ensures model selection does not change costs,
% diagnostics, optional configuration, or established errors.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Prepare one active sanity-check dataset for dispatcher tests.
% testCase stores the resolved scalar configuration and prepared data for
% all tests in this suite. This function has no output.

testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Use the maintained sanity-check configuration rather than legacy inputs.
configPath = fullfile(projectRoot, 'config', ...
    'bonePoseOptimizationSanityCheckConfig.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :));
data = prepareBonePoseOptimizationInputs(config);

testCase.TestData.config = config;
testCase.TestData.data = data;
end


function testPublicCostMatchesVersion1Implementation(testCase)
%TESTPUBLICCOSTMATCHESVERSION1IMPLEMENTATION Check dispatcher equivalence.
% testCase supplies prepared real inputs and verification methods. This
% function has no output.

data = testCase.TestData.data;
config = testCase.TestData.config;

% Exercise zero, translation, rotation, and combined perturbations because
% each path should pass through the dispatcher without changing the model.
poseVectors = [ ...
    zeros(6, 1), ...
    [1; -0.5; 0.25; 0; 0; 0], ...
    [0; 0; 0; deg2rad(1); deg2rad(-0.5); deg2rad(0.25)], ...
    [-0.75; 0.5; 1; deg2rad(-0.5); deg2rad(0.25); deg2rad(0.75)]];

for poseIndex = 1:size(poseVectors, 2)
    poseVector = poseVectors(:, poseIndex);
    [publicCost, publicDetails] = bonePoseCostFunction(poseVector, data, config);
    [versionedCost, versionedDetails] = ...
        bonePoseCostIntensityCoverageV1(poseVector, data, config);

    verifyCostEvaluationEqual(testCase, publicCost, publicDetails, ...
        versionedCost, versionedDetails);
end
end


function testPublicCostPreservesOptionalConfigAndEdgeCases(testCase)
%TESTPUBLICCOSTPRESERVESOPTIONALCONFIGANDEDGECASES Check established behavior.
% testCase supplies prepared real inputs and verification methods. This
% function has no output.

data = testCase.TestData.data;

% Omitting config must continue to use the configuration stored with data.
[publicCost, publicDetails] = bonePoseCostFunction(zeros(6, 1), data);
[versionedCost, versionedDetails] = ...
    bonePoseCostIntensityCoverageV1(zeros(6, 1), data);
verifyCostEvaluationEqual(testCase, publicCost, publicDetails, ...
    versionedCost, versionedDetails);

% The no-active-plane fallback must also pass through the dispatcher unchanged.
noActiveData = data;
noActiveData.nInitialIntersectionPixels(:) = 0;
[publicCost, publicDetails] = bonePoseCostFunction(zeros(6, 1), noActiveData);
[versionedCost, versionedDetails] = ...
    bonePoseCostIntensityCoverageV1(zeros(6, 1), noActiveData);
verifyCostEvaluationEqual(testCase, publicCost, publicDetails, ...
    versionedCost, versionedDetails);

% Keep the existing public error identifier when prepared counts are misaligned.
invalidData = data;
invalidData.nInitialIntersectionPixels = ...
    invalidData.nInitialIntersectionPixels(1:end - 1);
verifyError(testCase, ...
    @() bonePoseCostFunction(zeros(6, 1), invalidData), ...
    'bonePoseCostFunction:InitialCountSizeMismatch');
verifyError(testCase, ...
    @() bonePoseCostIntensityCoverageV1(zeros(6, 1), invalidData), ...
    'bonePoseCostFunction:InitialCountSizeMismatch');

% A runtime configuration must identify the model before geometry is evaluated.
missingModelConfig = testCase.TestData.config;
missingModelConfig.cost = rmfield(missingModelConfig.cost, 'model');
verifyError(testCase, ...
    @() bonePoseCostFunction(zeros(6, 1), data, missingModelConfig), ...
    'bonePoseCostFunction:MissingCostModel');
end


function verifyCostEvaluationEqual(testCase, actualCost, actualDetails, expectedCost, expectedDetails)
%VERIFYCOSTEVALUATIONEQUAL Compare public and versioned cost outputs.
% testCase provides MATLAB verification methods. actualCost and
% expectedCost are scalar objective values. actualDetails and
% expectedDetails are diagnostic structs. This function has no output.

% The dispatcher performs no calculation, so both scalar values should be identical.
verifyEqual(testCase, actualCost, expectedCost);
verifyEqual(testCase, actualDetails.costModel, 'intensityCoverage_v1');

% Compare the triangulation explicitly so mesh geometry remains easy to diagnose.
verifyEqual(testCase, actualDetails.boneMeshRefCandidate.ConnectivityList, ...
    expectedDetails.boneMeshRefCandidate.ConnectivityList);
verifyEqual(testCase, actualDetails.boneMeshRefCandidate.Points, ...
    expectedDetails.boneMeshRefCandidate.Points);

% Compare every V1 diagnostic after removing dispatcher-owned model identity and the mesh.
actualDetails = rmfield(actualDetails, {'boneMeshRefCandidate', 'costModel'});
expectedDetails = rmfield(expectedDetails, 'boneMeshRefCandidate');
verifyEqual(testCase, actualDetails, expectedDetails);
end
