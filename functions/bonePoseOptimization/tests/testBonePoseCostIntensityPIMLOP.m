function tests = testBonePoseCostIntensityPIMLOP
%TESTBONEPOSECOSTINTENSITYPIMLOP Test the combined intensity and P-IMLOP model.
% This suite checks that intensityPIMLOP is registered, that its
% configuration is validated, and that the returned cost is exactly the
% documented blend of the two component models. One P-IMLOP evaluation
% takes several seconds, so the suite reuses one prepared dataset.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Prepare the combined one-sweep inputs once for this suite.
% testCase stores the resolved scalar configuration and prepared data for
% all tests in this suite. This function has no output.

testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Use the same selectable configuration a user would choose for this model.
configPath = fullfile(projectRoot, 'config', ...
    'optconfig_oneSweep_intensityPIMLOP.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :), ...
    experimentPlan.runs.seed(1));
data = prepareBonePoseOptimizationInputs(config);

testCase.TestData.config = config;
testCase.TestData.data = data;
end


function testCombinedModelIsRegistered(testCase)
%TESTCOMBINEDMODELISREGISTERED Check the registry connection.
% testCase provides MATLAB verification methods. This function has no output.

definition = getBonePoseCostDefinition('intensityPIMLOP');

% Check every registry field because each one serves a different pipeline stage.
verifyEqual(testCase, definition.modelName, 'intensityPIMLOP');
verifyEqual(testCase, definition.evaluateFcn, @cost_intensityPIMLOP);
verifyEqual(testCase, definition.validateExperimentConfigFcn, ...
    @validate_cost_intensityPIMLOP);
verifyTrue(testCase, definition.requiresBoneSurface);
end


function testValidatorReturnsCanonicalSettings(testCase)
%TESTVALIDATORRETURNSCANONICALSETTINGS Check one accepted configuration.
% testCase provides MATLAB verification methods. This function has no output.

% Use single precision, column lists, and a shuffled field order to show
% the validator normalizes them.
fixedParameters = struct( ...
    'positionZStandardDeviationImage', single(1.5), ...
    'sampleSpacingMm', 0.1, ...
    'intensityMax', 255, ...
    'measurementSubsampleFraction', 0.5, ...
    'positionXStandardDeviationImage', 1, ...
    'positionYStandardDeviationImage', 1);
hyperparameters = struct( ...
    'weight', single([0.25; 0.75]), ...
    'kappa', [10; 50], ...
    'intensitySmoothingSigmaMm', 1);
[fixedParameters, hyperparameters] = ...
    validate_cost_intensityPIMLOP(fixedParameters, hyperparameters);

verifyEqual(testCase, fieldnames(fixedParameters).', ...
    {'intensityMax', 'sampleSpacingMm', 'measurementSubsampleFraction', ...
    'positionXStandardDeviationImage', 'positionYStandardDeviationImage', ...
    'positionZStandardDeviationImage'});
verifyEqual(testCase, fixedParameters.positionZStandardDeviationImage, 1.5);
verifyClass(testCase, fixedParameters.positionZStandardDeviationImage, 'double');

verifyEqual(testCase, fieldnames(hyperparameters).', ...
    {'intensitySmoothingSigmaMm', 'kappa', 'weight'});
verifyEqual(testCase, hyperparameters.kappa, [10 50]);
verifyEqual(testCase, hyperparameters.weight, [0.25 0.75]);
verifyClass(testCase, hyperparameters.weight, 'double');
end


function testValidatorRejectsInvalidSettings(testCase)
%TESTVALIDATORREJECTSINVALIDSETTINGS Check field names and value ranges.
% testCase provides MATLAB verification methods. This function has no output.

validFixed = struct('intensityMax', 255, ...
    'sampleSpacingMm', 0.1, ...
    'measurementSubsampleFraction', 0.5, ...
    'positionXStandardDeviationImage', 1, ...
    'positionYStandardDeviationImage', 1, ...
    'positionZStandardDeviationImage', 1.5);
validHyper = struct('intensitySmoothingSigmaMm', 1, 'kappa', 50, 'weight', 0.5);

% Field names must match exactly in both groups.
verifyError(testCase, @() validate_cost_intensityPIMLOP( ...
    rmfield(validFixed, 'intensityMax'), validHyper), ...
    'validate_cost_intensityPIMLOP:MissingParameter');
extraFixed = validFixed;
extraFixed.matchErrorReference = 10;
verifyError(testCase, @() validate_cost_intensityPIMLOP(extraFixed, validHyper), ...
    'validate_cost_intensityPIMLOP:UnexpectedParameter');

% The blend weight must be a valid convex coefficient without repeats.
badWeight = validHyper;
badWeight.weight = [0.5 1.5];
verifyError(testCase, @() validate_cost_intensityPIMLOP(validFixed, badWeight), ...
    'MATLAB:validate_cost_intensityPIMLOP:notLessEqual');
duplicateWeight = validHyper;
duplicateWeight.weight = [0.5 0.5];
verifyError(testCase, @() validate_cost_intensityPIMLOP(validFixed, duplicateWeight), ...
    'validate_cost_intensityPIMLOP:DuplicateWeight');

% Component rules are still enforced through the reused validators.
badSigma = validHyper;
badSigma.intensitySmoothingSigmaMm = -1;
verifyError(testCase, @() validate_cost_intensityPIMLOP(validFixed, badSigma), ...
    'MATLAB:validate_cost_intensityLine:expectedNonnegative');
badKappa = validHyper;
badKappa.kappa = -1;
verifyError(testCase, @() validate_cost_intensityPIMLOP(validFixed, badKappa), ...
    'MATLAB:validate_cost_PIMLOP:expectedNonnegative');
end


function testCombinedCostUsesAveragedWeightedComponents(testCase)
%TESTCOMBINEDCOSTUSESAVERAGEDWEIGHTEDCOMPONENTS Check the blend equation.
% testCase supplies prepared real measurements and scalar settings. This
% test compares the combined diagnostics with direct calls to both component
% models at one fixed pose, then checks both endpoints of the weight range.

data       = testCase.TestData.data;
config     = testCase.TestData.config;
poseVector = [1; -0.5; 0.25; deg2rad(0.5); 0; deg2rad(-0.25)];

% Calculate each established term independently before evaluating the blend.
intensityCost = cost_intensityLine(poseVector, data, config);
[pimlopTotal, pimlopDetails] = cost_PIMLOP(poseVector, data, config);
[combinedCost, combinedDetails] = ...
    bonePoseCostFunction(poseVector, data, config);

expectedPimlopMean = pimlopTotal / pimlopDetails.numberOfMeasurements;
expectedCombinedCost = 0.5 * intensityCost + 0.5 * expectedPimlopMean;

% The saved terms must show the complete calculation without hidden scaling.
terms = combinedDetails.costTerms;
verifyEqual(testCase, terms.intensityRaw, intensityCost);
verifyEqual(testCase, terms.pimlopTotalMatchError, pimlopTotal);
verifyEqual(testCase, terms.pimlopMeanMatchError, expectedPimlopMean, 'RelTol', 1e-12);
verifyEqual(testCase, terms.pimlopMeanMatchError, pimlopDetails.meanMatchError, 'RelTol', 1e-12);
verifyEqual(testCase, combinedCost, expectedCombinedCost, 'RelTol', 1e-12);
verifyEqual(testCase, terms.combined, combinedCost);
verifyEqual(testCase, combinedDetails.costModel, 'intensityPIMLOP');

% Both component functions must describe exactly the same candidate pose.
verifyEqual(testCase, combinedDetails.T_CT_ref_candidate, ...
    pimlopDetails.T_CT_ref_candidate);

% Weight endpoints retain their simple mathematical meaning.
firstOnlyConfig = config;
firstOnlyConfig.cost.parameters.weight = 1;
verifyEqual(testCase, cost_intensityPIMLOP(poseVector, data, firstOnlyConfig), ...
    intensityCost);

secondOnlyConfig = config;
secondOnlyConfig.cost.parameters.weight = 0;
verifyEqual(testCase, cost_intensityPIMLOP(poseVector, data, secondOnlyConfig), ...
    expectedPimlopMean, 'RelTol', 1e-12);
end
