function tests = testBonePoseCostPIMLOP
%TESTBONEPOSECOSTPIMLOP Test the P-IMLOP model inside the optimization framework.
% This suite checks that PIMLOP is registered, that its configuration is
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

definition = getBonePoseCostDefinition('PIMLOP');

% Check every registry field because each one serves a different pipeline stage.
verifyEqual(testCase, definition.modelName, 'PIMLOP');
verifyEqual(testCase, definition.evaluateFcn, @cost_PIMLOP);
verifyEqual(testCase, definition.validateExperimentConfigFcn, ...
    @validate_cost_PIMLOP);
verifyTrue(testCase, definition.requiresBoneSurface);
end


function testValidatorReturnsCanonicalSettings(testCase)
%TESTVALIDATORRETURNSCANONICALSETTINGS Check one accepted configuration.
% testCase provides MATLAB verification methods. This function has no output.

% Use single precision, a column kappa list, and a shuffled field order to
% show the validator normalizes them.
fixedParameters = struct( ...
    'positionZStandardDeviationImage', single(1.5), ...
    'measurementSubsampleFraction', single(0.5), ...
    'positionXStandardDeviationImage', 1, ...
    'positionYStandardDeviationImage', 1);
hyperparameters = struct('kappa', single([10; 50; 200]));
[fixedParameters, hyperparameters] = ...
    validate_cost_PIMLOP(fixedParameters, hyperparameters);

verifyEqual(testCase, fieldnames(fixedParameters).', ...
    {'measurementSubsampleFraction', 'positionXStandardDeviationImage', ...
    'positionYStandardDeviationImage', 'positionZStandardDeviationImage'});
verifyEqual(testCase, fixedParameters.measurementSubsampleFraction, 0.5);
verifyEqual(testCase, fixedParameters.positionXStandardDeviationImage, 1);
verifyEqual(testCase, fixedParameters.positionYStandardDeviationImage, 1);
verifyEqual(testCase, fixedParameters.positionZStandardDeviationImage, 1.5);
verifyClass(testCase, fixedParameters.measurementSubsampleFraction, 'double');
verifyClass(testCase, fixedParameters.positionZStandardDeviationImage, 'double');

% Kappa is the only hyperparameter and comes back as a double row vector.
verifyEqual(testCase, fieldnames(hyperparameters).', {'kappa'});
verifyEqual(testCase, hyperparameters.kappa, [10 50 200]);
verifyClass(testCase, hyperparameters.kappa, 'double');

% The edge values of the documented ranges must be accepted, including
% kappa = 0 (orientation term off) and a single-value kappa list.
edgeParameters = struct('measurementSubsampleFraction', 1, ...
    'positionXStandardDeviationImage', 0.1, ...
    'positionYStandardDeviationImage', 0.1, ...
    'positionZStandardDeviationImage', 0.1);
validate_cost_PIMLOP(edgeParameters, struct('kappa', 0));
end


function testValidatorRejectsInvalidSettings(testCase)
%TESTVALIDATORREJECTSINVALIDSETTINGS Check field names and value ranges.
% testCase provides MATLAB verification methods. This function has no output.

validParameters = struct('measurementSubsampleFraction', 0.5, ...
    'positionXStandardDeviationImage', 1, ...
    'positionYStandardDeviationImage', 1, ...
    'positionZStandardDeviationImage', 1.5);
validHyperparameters = struct('kappa', [10 50]);

% Field names must match exactly in both groups.
verifyError(testCase, @() validate_cost_PIMLOP( ...
    rmfield(validParameters, 'positionZStandardDeviationImage'), validHyperparameters), ...
    'validate_cost_PIMLOP:MissingParameter');
% The old three-value field was split per axis, so it is no longer accepted.
oldVectorParameters = rmfield(validParameters, {'positionXStandardDeviationImage', ...
    'positionYStandardDeviationImage', 'positionZStandardDeviationImage'});
oldVectorParameters.positionStandardDeviationImage = [1 1 1.5];
verifyError(testCase, @() validate_cost_PIMLOP(oldVectorParameters, validHyperparameters), ...
    'validate_cost_PIMLOP:MissingParameter');
verifyError(testCase, @() validate_cost_PIMLOP(validParameters, struct()), ...
    'validate_cost_PIMLOP:MissingParameter');
extraParameters = validParameters;
extraParameters.misspelledFraction = 1;
verifyError(testCase, @() validate_cost_PIMLOP(extraParameters, validHyperparameters), ...
    'validate_cost_PIMLOP:UnexpectedParameter');
extraHyperparameters = validHyperparameters;
extraHyperparameters.misspelledKappa = 1;
verifyError(testCase, @() validate_cost_PIMLOP(validParameters, extraHyperparameters), ...
    'validate_cost_PIMLOP:UnexpectedParameter');
% Kappa now belongs to the hyperparameters, so it is refused as a fixed setting.
fixedWithKappa = validParameters;
fixedWithKappa.kappa = 50;
verifyError(testCase, @() validate_cost_PIMLOP(fixedWithKappa, validHyperparameters), ...
    'validate_cost_PIMLOP:UnexpectedParameter');
verifyError(testCase, @() validate_cost_PIMLOP(validParameters, []), ...
    'validate_cost_PIMLOP:InvalidParameterGroup');

% Each fixed value outside its documented range must be rejected.
invalidValues = { ...
    'measurementSubsampleFraction', 0; ...
    'measurementSubsampleFraction', 1.5; ...
    'measurementSubsampleFraction', [0.5 0.5]; ...
    'positionXStandardDeviationImage', 0; ...
    'positionYStandardDeviationImage', -1; ...
    'positionZStandardDeviationImage', Inf; ...
    'positionZStandardDeviationImage', [1 1.5]};
for valueIndex = 1:size(invalidValues, 1)
    invalidParameters = validParameters;
    invalidParameters.(invalidValues{valueIndex, 1}) = invalidValues{valueIndex, 2};
    verifyError(testCase, ...
        @() validate_cost_PIMLOP(invalidParameters, validHyperparameters), ...
        ?MException, sprintf('%s = %s should be rejected.', ...
        invalidValues{valueIndex, 1}, mat2str(invalidValues{valueIndex, 2})));
end

% Each invalid kappa candidate list must be rejected. Duplicates are
% checked separately below because they have their own error identifier.
invalidKappaLists = {-1, [10 -1], NaN, [10 Inf], []};
for listIndex = 1:numel(invalidKappaLists)
    invalidKappa = invalidKappaLists{listIndex};
    verifyError(testCase, ...
        @() validate_cost_PIMLOP(validParameters, struct('kappa', invalidKappa)), ...
        ?MException, sprintf('kappa = %s should be rejected.', mat2str(invalidKappa)));
end
verifyError(testCase, ...
    @() validate_cost_PIMLOP(validParameters, struct('kappa', [10 10])), ...
    'validate_cost_PIMLOP:DuplicateCandidate');
end


function testOneSweepConfigurationDefinesOneReproducibleRun(testCase)
%TESTONESWEEPCONFIGURATIONDEFINESONEREPRODUCIBLERUN Check the selectable JSON.
% testCase supplies the parsed P-IMLOP specification. This function has no output.

spec = testCase.TestData.experimentSpec;
plan = testCase.TestData.experimentPlan;
config = testCase.TestData.config;

% The JSON selects P-IMLOP with the settings of the validated demonstration.
verifyEqual(testCase, spec.cost.model, 'PIMLOP');
verifyTrue(testCase, isfile(spec.input.boneSurfaceMatFile));
verifyEqual(testCase, spec.experiment.name, 'oneSweep_PIMLOP');
verifyEqual(testCase, spec.cost.hyperparameters.kappa, 50);
verifyEqual(testCase, plan.parameterNames, {'normalFacingToleranceDeg', 'kappa'});
verifyEqual(testCase, plan.numberOfRuns, 1);

% Every runtime value reaches config.cost.parameters, where the cost reads it.
verifyEqual(testCase, config.cost.model, 'PIMLOP');
verifyEqual(testCase, config.cost.parameters.measurementSubsampleFraction, 0.5);
verifyEqual(testCase, config.cost.parameters.positionXStandardDeviationImage, 1);
verifyEqual(testCase, config.cost.parameters.positionYStandardDeviationImage, 1);
verifyEqual(testCase, config.cost.parameters.positionZStandardDeviationImage, 1.5);
verifyEqual(testCase, config.cost.parameters.kappa, 50);
verifyEqual(testCase, config.optimizer.seed, 1001);
end


function testKappaSweepConfigurationPlansOneCombinationPerKappa(testCase)
%TESTKAPPASWEEPCONFIGURATIONPLANSONECOMBINATIONPERKAPPA Check the sweep JSON.
% testCase supplies the project root. This function has no output.

% Only the configuration and planning steps are run here; they are fast,
% while preparing inputs and running CMA-ES for every kappa would take long.
configPath = fullfile(testCase.TestData.projectRoot, 'config', ...
    'optconfig_hyperparamSweep_PIMLOP.json');
spec = createBonePoseOptimizationExperimentConfig(configPath);
plan = createBonePoseOptimizationExperimentPlan(spec);

% With one tolerance value, each kappa candidate becomes one combination,
% and every combination is repeated once per seed.
kappaCandidates = spec.cost.hyperparameters.kappa;
verifyEqual(testCase, kappaCandidates, [10 50 200]);
verifyEqual(testCase, plan.parameterNames, {'normalFacingToleranceDeg', 'kappa'});
verifyEqual(testCase, plan.numberOfCombinations, numel(kappaCandidates));
verifyEqual(testCase, plan.combinations.kappa.', kappaCandidates);
verifyEqual(testCase, plan.numberOfRuns, ...
    numel(kappaCandidates) * numel(spec.experiment.seeds));

% Each run config must carry its own scalar kappa next to the fixed
% settings, because that is where cost_PIMLOP reads it.
for combinationIndex = 1:plan.numberOfCombinations
    combinationRow = plan.combinations(combinationIndex, :);
    runConfig = createBonePoseOptimizationRunConfig( ...
        spec, combinationRow, spec.experiment.seeds(1));
    verifyEqual(testCase, runConfig.cost.parameters.kappa, kappaCandidates(combinationIndex));
    verifyEqual(testCase, runConfig.cost.parameters.measurementSubsampleFraction, 0.5);
    verifyEqual(testCase, runConfig.cost.parameters.positionXStandardDeviationImage, 1);
    verifyEqual(testCase, runConfig.cost.parameters.positionYStandardDeviationImage, 1);
    verifyEqual(testCase, runConfig.cost.parameters.positionZStandardDeviationImage, 1.5);
end
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
    'cost_PIMLOP:ImageCountMismatch');
end


function testMissingPreparedModelIsReported(testCase)
%TESTMISSINGPREPAREDMODELISREPORTED Check the PD-tree requirement.
% testCase supplies prepared data. This function has no output.

% Without data.extra.pimlop.PsiCT the cost must not build a tree on its own.
dataWithoutModel = rmfield(testCase.TestData.data, 'extra');
verifyError(testCase, @() bonePoseCostFunction( ...
    zeros(6, 1), dataWithoutModel, testCase.TestData.config), ...
    'cost_PIMLOP:MissingPreparedModel');
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
[directCost, directDetails] = cost_PIMLOP(poseVector, data, config);
verifyEqual(testCase, publicCost, directCost);
verifyEqual(testCase, publicDetails.costModel, 'PIMLOP');
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
