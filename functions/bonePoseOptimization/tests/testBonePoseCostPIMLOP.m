function tests = testBonePoseCostPIMLOP
%TESTBONEPOSECOSTPIMLOP Test the P-IMLOP model inside the optimization framework.
% This suite checks that PIMLOP_v1 is registered, that its configuration is
% validated, and that the generic preparation, dispatcher, and CMA-ES
% workflow run it like any other cost model. One P-IMLOP evaluation takes
% several seconds, so the suite reuses one prepared dataset.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

% Let MATLAB discover every local function whose name starts with test.
tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Prepare the P-IMLOP one-sweep inputs once for this suite.
% testCase stores the project root, configuration, prepared data, and the
% initial cost shared by all tests. This function has no output.

% Walk from this test file through tests/, bonePoseOptimization/, and functions/.
testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Use the same selectable configuration a user would choose for P-IMLOP.
configPath = fullfile(projectRoot, 'config', 'optconfig_oneSweep_PIMLOP.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :), ...
    experimentPlan.runs.seed(1));
data = prepareBonePoseOptimizationInputs(config);

testCase.TestData.projectRoot = projectRoot;
testCase.TestData.configPath = configPath;
testCase.TestData.experimentSpec = experimentSpec;
testCase.TestData.experimentPlan = experimentPlan;
testCase.TestData.config = config;
testCase.TestData.data = data;
testCase.TestData.initialCost = bonePoseCostFunction(zeros(6, 1), data, config);
end


function testPIMLOPModelIsRegistered(testCase)
%TESTPIMLOPMODELISREGISTERED Check the registry connection.
% testCase provides MATLAB verification methods. This function has no output.

definition = getBonePoseCostDefinition('PIMLOP_v1');

% Check every registry field because each one serves a different pipeline stage.
verifyEqual(testCase, definition.modelName, 'PIMLOP_v1');
verifyEqual(testCase, definition.evaluateFcn, @cost_PIMLOP_v01);
verifyEqual(testCase, definition.validateExperimentConfigFcn, ...
    @validate_cost_PIMLOP_v01);
verifyTrue(testCase, definition.requiresBoneSurface);
end


function testValidatorReturnsCanonicalSettings(testCase)
%TESTVALIDATORRETURNSCANONICALSETTINGS Check one accepted configuration.
% testCase provides MATLAB verification methods. This function has no output.

% Use a column vector and single precision to show the validator normalizes them.
fixedParameters = struct( ...
    'measurementSubsampleFraction', single(0.5), ...
    'positionStandardDeviationImage', [1; 1; 1.5], ...
    'kappa', 50);
[fixedParameters, hyperparameters] = ...
    validate_cost_PIMLOP_v01(fixedParameters, struct());

verifyEqual(testCase, fieldnames(fixedParameters).', ...
    {'measurementSubsampleFraction', 'positionStandardDeviationImage', 'kappa'});
verifyEqual(testCase, fixedParameters.measurementSubsampleFraction, 0.5);
verifyEqual(testCase, fixedParameters.positionStandardDeviationImage, [1 1 1.5]);
verifyEqual(testCase, fixedParameters.kappa, 50);
verifyClass(testCase, fixedParameters.measurementSubsampleFraction, 'double');
verifyEmpty(testCase, fieldnames(hyperparameters));

% The edge values of the documented ranges must be accepted.
edgeParameters = struct('measurementSubsampleFraction', 1, ...
    'positionStandardDeviationImage', [0.1 0.1 0.1], 'kappa', 0);
validate_cost_PIMLOP_v01(edgeParameters, struct());
end


function testValidatorRejectsInvalidSettings(testCase)
%TESTVALIDATORREJECTSINVALIDSETTINGS Check field names and value ranges.
% testCase provides MATLAB verification methods. This function has no output.

validParameters = struct('measurementSubsampleFraction', 0.5, ...
    'positionStandardDeviationImage', [1 1 1.5], 'kappa', 50);

% Field names must match exactly, and no setting may be swept yet.
verifyError(testCase, @() validate_cost_PIMLOP_v01( ...
    rmfield(validParameters, 'kappa'), struct()), ...
    'validate_cost_PIMLOP_v01:MissingParameter');
extraParameters = validParameters;
extraParameters.misspelledKappa = 1;
verifyError(testCase, @() validate_cost_PIMLOP_v01(extraParameters, struct()), ...
    'validate_cost_PIMLOP_v01:UnexpectedParameter');
verifyError(testCase, @() validate_cost_PIMLOP_v01( ...
    validParameters, struct('kappa', [10 50])), ...
    'validate_cost_PIMLOP_v01:UnexpectedParameter');
verifyError(testCase, @() validate_cost_PIMLOP_v01(validParameters, []), ...
    'validate_cost_PIMLOP_v01:InvalidParameterGroup');

% Each value outside its documented range must be rejected.
invalidValues = { ...
    'measurementSubsampleFraction', 0; ...
    'measurementSubsampleFraction', 1.5; ...
    'measurementSubsampleFraction', [0.5 0.5]; ...
    'positionStandardDeviationImage', [1 0 1.5]; ...
    'positionStandardDeviationImage', [1 -1 1.5]; ...
    'positionStandardDeviationImage', [1 Inf 1.5]; ...
    'positionStandardDeviationImage', [1 1]; ...
    'kappa', -1; ...
    'kappa', NaN; ...
    'kappa', [10 50]};
for valueIndex = 1:size(invalidValues, 1)
    invalidParameters = validParameters;
    invalidParameters.(invalidValues{valueIndex, 1}) = invalidValues{valueIndex, 2};
    verifyError(testCase, ...
        @() validate_cost_PIMLOP_v01(invalidParameters, struct()), ...
        ?MException, sprintf('%s = %s should be rejected.', ...
        invalidValues{valueIndex, 1}, mat2str(invalidValues{valueIndex, 2})));
end
end


function testOneSweepConfigurationDefinesOneReproducibleRun(testCase)
%TESTONESWEEPCONFIGURATIONDEFINESONEREPRODUCIBLERUN Check the selectable JSON.
% testCase supplies the parsed P-IMLOP specification. This function has no output.

spec = testCase.TestData.experimentSpec;
plan = testCase.TestData.experimentPlan;
config = testCase.TestData.config;

% The JSON selects P-IMLOP with the settings of the validated demonstration.
verifyEqual(testCase, spec.cost.model, 'PIMLOP_v1');
verifyTrue(testCase, isfile(spec.input.boneSurfaceMatFile));
verifyEqual(testCase, spec.experiment.name, 'oneSweep_PIMLOP_v01');
verifyEmpty(testCase, fieldnames(spec.cost.hyperparameters));
verifyEqual(testCase, plan.parameterNames, {'normalFacingToleranceDeg'});
verifyEqual(testCase, plan.numberOfRuns, 1);

% Every runtime value reaches config.cost.parameters, where the cost reads it.
verifyEqual(testCase, config.cost.model, 'PIMLOP_v1');
verifyEqual(testCase, config.cost.parameters.measurementSubsampleFraction, 0.5);
verifyEqual(testCase, config.cost.parameters.positionStandardDeviationImage, [1 1 1.5]);
verifyEqual(testCase, config.cost.parameters.kappa, 50);
verifyEqual(testCase, config.optimizer.seed, 1001);
end


function testMissingBoneSurfaceInputIsRejected(testCase)
%TESTMISSINGBONESURFACEINPUTISREJECTED Check both missing-surface boundaries.
% testCase supplies the P-IMLOP JSON and prepared data. This function has no output.

% Configuration loading must stop when no bone-surface file is configured.
rawConfig = jsondecode(fileread(testCase.TestData.configPath));
rawConfig.project.root = testCase.TestData.projectRoot;
rawConfig.input.boneSurfaceMatFile = '';
temporaryConfigPath = [tempname '.json'];
temporaryConfigCleanup = onCleanup(@() delete(temporaryConfigPath));
fileId = fopen(temporaryConfigPath, 'w');
fwrite(fileId, jsonencode(rawConfig, 'PrettyPrint', true), 'char');
fclose(fileId);
verifyError(testCase, ...
    @() createBonePoseOptimizationExperimentConfig(temporaryConfigPath), ...
    'createBonePoseOptimizationConfig:MissingBoneSurfaceInput');
clear temporaryConfigCleanup;

% The cost must also stop when the prepared data has no surface measurements.
dataWithoutSurface = testCase.TestData.data;
dataWithoutSurface.boneSurfaceMeasurements = struct([]);
verifyError(testCase, @() bonePoseCostFunction( ...
    zeros(6, 1), dataWithoutSurface, testCase.TestData.config), ...
    'cost_PIMLOP_v01:ImageCountMismatch');
end


function testMissingPreparedModelIsReported(testCase)
%TESTMISSINGPREPAREDMODELISREPORTED Check the PD-tree requirement.
% testCase supplies prepared data. This function has no output.

% Without data.extra.pimlop.PsiCT the cost must not build a tree on its own.
dataWithoutModel = rmfield(testCase.TestData.data, 'extra');
verifyError(testCase, @() bonePoseCostFunction( ...
    zeros(6, 1), dataWithoutModel, testCase.TestData.config), ...
    'cost_PIMLOP_v01:MissingPreparedModel');
end


function testInitialPoseCostIsFiniteScalar(testCase)
%TESTINITIALPOSECOSTISFINITESCALAR Check the cost at the coarse pose.
% testCase supplies the cost computed in setupOnce. This function has no output.

initialCost = testCase.TestData.initialCost;
verifyTrue(testCase, isscalar(initialCost) && isfinite(initialCost));
verifyGreaterThanOrEqual(testCase, initialCost, 0);
end


function testDispatcherMatchesDirectCallAtNonzeroPose(testCase)
%TESTDISPATCHERMATCHESDIRECTCALLATNONZEROPOSE Check dispatch and a moved pose.
% testCase supplies prepared data. This function has no output.

data = testCase.TestData.data;
config = testCase.TestData.config;
poseVector = [1; -0.5; 0.25; deg2rad(1); deg2rad(-0.5); deg2rad(0.25)];

% The dispatcher performs no calculation, so both calls must agree exactly.
% The details also hold search timings, which differ between any two calls,
% so compare only the values that define the result.
[publicCost, publicDetails] = bonePoseCostFunction(poseVector, data, config);
[directCost, directDetails] = cost_PIMLOP_v01(poseVector, data, config);
verifyEqual(testCase, publicCost, directCost);
verifyEqual(testCase, publicDetails.costModel, 'PIMLOP_v1');
verifyEqual(testCase, publicDetails.T_CT_ref_candidate, directDetails.T_CT_ref_candidate);
verifyEqual(testCase, publicDetails.X, directDetails.X);
verifyEqual(testCase, publicDetails.YmatchesCT, directDetails.YmatchesCT);
verifyEqual(testCase, publicDetails.EMatchValues, directDetails.EMatchValues);
verifyEqual(testCase, publicDetails.costSettings, directDetails.costSettings);

% A moved pose must still give one finite cost that differs from the start.
verifyTrue(testCase, isscalar(publicCost) && isfinite(publicCost));
verifyNotEqual(testCase, publicCost, testCase.TestData.initialCost);
verifyEqual(testCase, publicDetails.status, 'pimlop_cost_computed');
end


function testSerialCMAESSmokeRun(testCase)
%TESTSERIALCMAESSMOKERUN Run one short serial CMA-ES search.
% testCase supplies prepared data. This function has no output.

config = testCase.TestData.config;
config.optimizer.useParfor = false;
optimizationResult = runShortOptimization(testCase, config);
verifyOptimizationResult(testCase, optimizationResult, config);
end


function testParallelCMAESSmokeRun(testCase)
%TESTPARALLELCMAESSMOKERUN Run one short parallel CMA-ES search.
% testCase supplies prepared data. This function has no output.

% Without the toolbox the runner falls back to serial, so there is nothing to test.
assumeTrue(testCase, ~isempty(ver('parallel')) && ...
    license('test', 'Distrib_Computing_Toolbox'), ...
    'Parallel Computing Toolbox is not available.');

config = testCase.TestData.config;
config.optimizer.useParfor = true;
config.optimizer.parforWorkers = 2;
optimizationResult = runShortOptimization(testCase, config);
verifyOptimizationResult(testCase, optimizationResult, config);
verifyEqual(testCase, optimizationResult.cmaes.cmaesOptions.ParforRun, 1);
end


function optimizationResult = runShortOptimization(testCase, config)
%RUNSHORTOPTIMIZATION Run a one-generation CMA-ES search in a temporary folder.
% testCase supplies prepared data and config is the runtime configuration
% to use. optimizationResult is the struct returned by runBonePoseOptimization.

% One generation is enough to show that the workflow runs end to end.
temporaryOutputRoot = tempname;
temporaryOutputCleanup = onCleanup(@() removeTemporaryFolder(temporaryOutputRoot));
config.optimizer.outputFolder = temporaryOutputRoot;
config.optimizer.populationSize = 4;
config.optimizer.maxFunctionEvaluations = 4;

optimizationResult = runBonePoseOptimization( ...
    zeros(6, 1), testCase.TestData.data, config, testCase.TestData.initialCost);
clear temporaryOutputCleanup;
end


function verifyOptimizationResult(testCase, optimizationResult, config)
%VERIFYOPTIMIZATIONRESULT Check the fields every CMA-ES run must return.
% testCase provides verification methods, optimizationResult is the result
% to check, and config supplies the search bounds. This function has no output.

verifyEqual(testCase, optimizationResult.run.status, 'cmaes_completed');
verifyEqual(testCase, optimizationResult.run.seed, config.optimizer.seed);
verifyTrue(testCase, isfinite(optimizationResult.result.bestCost));

% The best pose must respect the configured translation and rotation bounds.
bestPoseVector = optimizationResult.result.bestPoseVector;
verifyLessThanOrEqual(testCase, abs(bestPoseVector(1:3)), ...
    config.optimizer.translationBoundMm + 1e-12);
verifyLessThanOrEqual(testCase, abs(bestPoseVector(4:6)), ...
    deg2rad(config.optimizer.rotationBoundDeg) + 1e-12);
end


function removeTemporaryFolder(folderPath)
%REMOVETEMPORARYFOLDER Delete the temporary CMA-ES output after a test.
% folderPath identifies the test-owned folder. This function has no output.

% Recursive removal is limited to the unique tempname path created by the test.
if isfolder(folderPath)
    rmdir(folderPath, 's');
end
end
