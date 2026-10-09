function tests = testBonePoseCostDispatcher
%TESTBONEPOSECOSTDISPATCHER Test the stable cost-function entry point.
% This suite compares the public dispatcher with the direct intensity
% implementation. It ensures model selection does not change costs,
% diagnostics, optional configuration, or established errors.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Prepare one active one-sweep dataset for dispatcher tests.
% testCase stores the resolved scalar configuration and prepared data for
% all tests in this suite. This function has no output.

testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Use the maintained one-sweep configuration rather than legacy inputs.
configPath = fullfile(projectRoot, 'config', ...
    'optconfig_oneSweep_intensityLine.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :));
data = prepareBonePoseOptimizationInputs(config);

% Resolve the combined scalar settings separately while reusing the same
% prepared measurements, because both one-sweep files select identical inputs.
combinedConfigPath = fullfile(projectRoot, 'config', ...
    'optconfig_oneSweep_intensityICP.json');
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


function testPublicCostMatchesDirectImplementation(testCase)
%TESTPUBLICCOSTMATCHESDIRECTIMPLEMENTATION Check dispatcher equivalence.
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
    [directCost, directDetails] = ...
        cost_intensityLine(poseVector, data, config);

    verifyCostEvaluationEqual(testCase, publicCost, publicDetails, ...
        directCost, directDetails);
end
end


function testPointCloud3DModelIsRegistered(testCase)
%TESTPOINTCLOUD3DMODELISREGISTERED Check the new registry connection.
% testCase provides MATLAB verification methods. This test confirms that
% configuration loading and cost dispatch resolve the intended functions.

definition = getBonePoseCostDefinition('ICPLike');

% Check every registry field because each one serves a different pipeline stage.
verifyEqual(testCase, definition.modelName, 'ICPLike');
verifyEqual(testCase, definition.evaluateFcn, @cost_ICPLike);
verifyEqual(testCase, definition.validateExperimentConfigFcn, ...
    @validate_cost_ICPLike);
verifyTrue(testCase, definition.requiresBoneSurface);
end


function testCombinedModelIsRegistered(testCase)
%TESTCOMBINEDMODELISREGISTERED Check the combined registry connection.
% testCase provides MATLAB verification methods. This test ensures config
% loading and the public dispatcher resolve the same combined implementation.

definition = getBonePoseCostDefinition('intensityICP');

verifyEqual(testCase, definition.modelName, 'intensityICP');
verifyEqual(testCase, definition.evaluateFcn, ...
    @cost_intensityICP);
verifyEqual(testCase, definition.validateExperimentConfigFcn, ...
    @validate_cost_intensityICP);
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
    cost_intensityLine(poseVector, data, config);
[pointCloudCostMm, pointCloudDetails] = ...
    cost_ICPLike(poseVector, data, config);
[combinedCost, combinedDetails] = ...
    bonePoseCostFunction(poseVector, data, config);

expectedPointCloudNormalized = pointCloudCostMm / 5;
expectedCombinedCost = 0.25 * intensityCost + ...
    0.75 * expectedPointCloudNormalized;

% The saved terms must show the complete calculation without hidden scaling.
verifyEqual(testCase, combinedDetails.costTerms.intensityRaw, intensityCost);
verifyEqual(testCase, combinedDetails.costTerms.pointCloud3DRawMm, pointCloudCostMm);
verifyEqual(testCase, combinedDetails.costTerms.pointCloud3DNormalized, ...
    expectedPointCloudNormalized);
verifyEqual(testCase, combinedDetails.costTerms.combined, expectedCombinedCost);
verifyEqual(testCase, combinedCost, expectedCombinedCost);
verifyEqual(testCase, combinedDetails.costModel, 'intensityICP');

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
firstOnlyCost = cost_intensityICP( ...
    poseVector, data, firstOnlyConfig);
verifyEqual(testCase, firstOnlyCost, intensityCost);

secondOnlyConfig = config;
secondOnlyConfig.cost.parameters.weight = 0;
secondOnlyCost = cost_intensityICP( ...
    poseVector, data, secondOnlyConfig);
verifyEqual(testCase, secondOnlyCost, expectedPointCloudNormalized);
end


function testPublicCostPreservesOptionalConfigAndEdgeCases(testCase)
%TESTPUBLICCOSTPRESERVESOPTIONALCONFIGANDEDGECASES Check established behavior.
% testCase supplies prepared real inputs and verification methods. This
% function has no output.

data = testCase.TestData.data;

% Omitting config must use the configuration stored with data.
[publicCost, publicDetails] = bonePoseCostFunction(zeros(6, 1), data);
[directCost, directDetails] = ...
    cost_intensityLine(zeros(6, 1), data, data.config);
verifyCostEvaluationEqual(testCase, publicCost, publicDetails, ...
    directCost, directDetails);

% A pose without any visible bone must also pass through the dispatcher unchanged.
farAwayPose = [500; 500; 500; 0; 0; 0];
[publicCost, publicDetails] = bonePoseCostFunction(farAwayPose, data);
[directCost, directDetails] = ...
    cost_intensityLine(farAwayPose, data, data.config);
verifyCostEvaluationEqual(testCase, publicCost, publicDetails, ...
    directCost, directDetails);

% A runtime configuration must identify the model before geometry is evaluated.
missingModelConfig = testCase.TestData.config;
missingModelConfig.cost = rmfield(missingModelConfig.cost, 'model');
verifyError(testCase, ...
    @() bonePoseCostFunction(zeros(6, 1), data, missingModelConfig), ...
    'bonePoseCostFunction:MissingCostModel');
end


function verifyCostEvaluationEqual(testCase, actualCost, actualDetails, expectedCost, expectedDetails)
%VERIFYCOSTEVALUATIONEQUAL Compare public and direct cost outputs.
% testCase provides MATLAB verification methods. actualCost and
% expectedCost are scalar objective values. actualDetails and
% expectedDetails are diagnostic structs. This function has no output.

% The dispatcher performs no calculation, so both scalar values should be identical.
verifyEqual(testCase, actualCost, expectedCost);
verifyEqual(testCase, actualDetails.costModel, 'intensityLine');

% Compare the triangulation explicitly so mesh geometry remains easy to diagnose.
verifyEqual(testCase, actualDetails.boneMeshRefCandidate.ConnectivityList, ...
    expectedDetails.boneMeshRefCandidate.ConnectivityList);
verifyEqual(testCase, actualDetails.boneMeshRefCandidate.Points, ...
    expectedDetails.boneMeshRefCandidate.Points);

% Compare every diagnostic after removing dispatcher-owned model identity and the mesh.
actualDetails = rmfield(actualDetails, {'boneMeshRefCandidate', 'costModel'});
expectedDetails = rmfield(expectedDetails, 'boneMeshRefCandidate');
verifyEqual(testCase, actualDetails, expectedDetails);
end
