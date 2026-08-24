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
    'bonePoseOptimization_sanityCheckConfig_intensityCoverageCost.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :));
data = prepareBonePoseOptimizationInputs(config);

% Resolve the combined scalar settings separately while reusing the same
% prepared measurements, because both sanity files select identical inputs.
combinedConfigPath = fullfile(projectRoot, 'config', ...
    'bonePoseOptimization_sanityCheckConfig_intensityPointCloudCost.json');
combinedSpec = createBonePoseOptimizationExperimentConfig(combinedConfigPath);
combinedPlan = createBonePoseOptimizationExperimentPlan(combinedSpec);
combinedConfig = createBonePoseOptimizationRunConfig( ...
    combinedSpec, combinedPlan.combinations(1, :));
combinedData = data;
combinedData.config = combinedConfig;

testCase.TestData.config = config;
testCase.TestData.data = data;
testCase.TestData.combinedConfig = combinedConfig;
testCase.TestData.combinedData = combinedData;
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


function testPointCloud3DModelIsRegistered(testCase)
%TESTPOINTCLOUD3DMODELISREGISTERED Check the new registry connection.
% testCase provides MATLAB verification methods. This test confirms that
% configuration loading and cost dispatch resolve the intended functions.

definition = getBonePoseCostDefinition('pointCloud3D_v1');

% Check every registry field because each one serves a different pipeline stage.
verifyEqual(testCase, definition.modelName, 'pointCloud3D_v1');
verifyEqual(testCase, definition.evaluateFcn, @bonePoseCost3DPointCloudV1);
verifyEqual(testCase, definition.validateExperimentConfigFcn, ...
    @validateBonePoseCost3DPointCloudV1Config);
verifyTrue(testCase, definition.requiresBoneSurface);
end


function testCombinedModelIsRegistered(testCase)
%TESTCOMBINEDMODELISREGISTERED Check the combined registry connection.
% testCase provides MATLAB verification methods. This test ensures config
% loading and the public dispatcher resolve the same combined implementation.

definition = getBonePoseCostDefinition('intensityPointCloud_v1');

verifyEqual(testCase, definition.modelName, 'intensityPointCloud_v1');
verifyEqual(testCase, definition.evaluateFcn, ...
    @bonePoseCostIntensityPointCloudV1);
verifyEqual(testCase, definition.validateExperimentConfigFcn, ...
    @validateBonePoseCostIntensityPointCloudV1Config);
verifyTrue(testCase, definition.requiresBoneSurface);
end


function testCombinedCostUsesNormalizedWeightedComponents(testCase)
%TESTCOMBINEDCOSTUSESNORMALIZEDWEIGHTEDCOMPONENTS Check the blend equation.
% testCase supplies prepared real measurements and scalar settings. This
% test compares the combined diagnostics with direct calls to both component
% models at one fixed pose, then checks both endpoints of the weight range.

data       = testCase.TestData.combinedData;
config     = testCase.TestData.combinedConfig;
poseVector = zeros(6, 1);

% Calculate each established term independently before evaluating the blend.
[intensityCost, intensityDetails] = ...
    bonePoseCostIntensityCoverageV1(poseVector, data, config);
[pointCloudCostMm, pointCloudDetails] = ...
    bonePoseCost3DPointCloudV1(poseVector, data, config);
[combinedCost, combinedDetails] = ...
    bonePoseCostFunction(poseVector, data, config);

expectedPointCloudNormalized = pointCloudCostMm / 5;
expectedCombinedCost = 0.25 * intensityCost + ...
    0.75 * expectedPointCloudNormalized;

% The saved terms must show the complete calculation without hidden scaling.
verifyEqual(testCase, combinedDetails.costTerms.intensityCoverageRaw, intensityCost);
verifyEqual(testCase, combinedDetails.costTerms.pointCloud3DRawMm, pointCloudCostMm);
verifyEqual(testCase, combinedDetails.costTerms.pointCloud3DNormalized, ...
    expectedPointCloudNormalized);
verifyEqual(testCase, combinedDetails.costTerms.combined, expectedCombinedCost);
verifyEqual(testCase, combinedCost, expectedCombinedCost);
verifyEqual(testCase, combinedDetails.costModel, 'intensityPointCloud_v1');

% Both component functions must describe exactly the same candidate geometry.
verifyEqual(testCase, intensityDetails.T_CT_ref_candidate, ...
    pointCloudDetails.T_CT_ref_candidate);
verifyEqual(testCase, intensityDetails.boneMeshRefCandidate.ConnectivityList, ...
    pointCloudDetails.boneMeshRefCandidate.ConnectivityList);
verifyEqual(testCase, intensityDetails.boneMeshRefCandidate.Points, ...
    pointCloudDetails.boneMeshRefCandidate.Points);

% Weight endpoints retain their simple mathematical meaning.
firstOnlyConfig = config;
firstOnlyConfig.cost.parameters.weight = 1;
firstOnlyCost = bonePoseCostIntensityPointCloudV1( ...
    poseVector, data, firstOnlyConfig);
verifyEqual(testCase, firstOnlyCost, intensityCost);

secondOnlyConfig = config;
secondOnlyConfig.cost.parameters.weight = 0;
secondOnlyCost = bonePoseCostIntensityPointCloudV1( ...
    poseVector, data, secondOnlyConfig);
verifyEqual(testCase, secondOnlyCost, expectedPointCloudNormalized);
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
