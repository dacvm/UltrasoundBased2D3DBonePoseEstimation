function tests = testBonePoseCostICPLike
%TESTBONEPOSECOSTICPLIKE Test the ICP-like model inside the optimization framework.
% This suite checks that the ICPLike configuration is validated, that the
% cost finds the true closest mesh location for the measured points, that
% the batch size never changes the result, and that the generic dispatcher
% and CMA-ES workflow run it like any other cost model.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

% Let MATLAB discover every local function whose name starts with test.
tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Prepare the ICPLike one-sweep inputs once for this suite.
% testCase stores the configuration, prepared data, and the initial cost
% shared by all tests. This function has no output.

% Walk from this test file through tests/, bonePoseOptimization/, and functions/.
testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Use the same selectable configuration a user would choose for ICPLike.
configPath = fullfile(projectRoot, 'config', 'optconfig_oneSweep_ICPLike.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :), ...
    experimentPlan.runs.seed(1));
data = prepareBonePoseOptimizationInputs(config);

testCase.TestData.config = config;
testCase.TestData.data = data;
testCase.TestData.initialCost = bonePoseCostFunction(zeros(6, 1), data, config);
end


function testValidatorReturnsCanonicalSettings(testCase)
%TESTVALIDATORRETURNSCANONICALSETTINGS Check one accepted configuration.
% testCase provides MATLAB verification methods. This function has no output.

% Use single precision and a shuffled field order to show the validator
% normalizes them.
fixedParameters = struct('pointBatchSize', single(200), 'nearestVertexCount', single(20));
[fixedParameters, hyperparameters] = validate_cost_ICPLike(fixedParameters, struct());

verifyEqual(testCase, fieldnames(fixedParameters).', {'nearestVertexCount', 'pointBatchSize'});
verifyEqual(testCase, fixedParameters.nearestVertexCount, 20);
verifyEqual(testCase, fixedParameters.pointBatchSize, 200);
verifyClass(testCase, fixedParameters.nearestVertexCount, 'double');
verifyClass(testCase, fixedParameters.pointBatchSize, 'double');
verifyEmpty(testCase, fieldnames(hyperparameters));
end


function testValidatorRejectsInvalidSettings(testCase)
%TESTVALIDATORREJECTSINVALIDSETTINGS Check field names and value ranges.
% testCase provides MATLAB verification methods. This function has no output.

validParameters = struct('nearestVertexCount', 20, 'pointBatchSize', 200);

% Field names must match exactly: both settings are required, and an
% unknown or misspelled setting is refused.
verifyError(testCase, @() validate_cost_ICPLike( ...
    rmfield(validParameters, 'pointBatchSize'), struct()), ...
    'validate_cost_ICPLike:MissingParameter');
verifyError(testCase, @() validate_cost_ICPLike( ...
    rmfield(validParameters, 'nearestVertexCount'), struct()), ...
    'validate_cost_ICPLike:MissingParameter');
extraParameters = validParameters;
extraParameters.misspelledBatchSize = 100;
verifyError(testCase, @() validate_cost_ICPLike(extraParameters, struct()), ...
    'validate_cost_ICPLike:UnexpectedParameter');
verifyError(testCase, @() validate_cost_ICPLike(validParameters, struct('kappa', 1)), ...
    'validate_cost_ICPLike:UnexpectedParameter');

% Both settings count something, so each must be one positive whole number.
invalidValues = { ...
    'nearestVertexCount', 0; ...
    'nearestVertexCount', 2.5; ...
    'nearestVertexCount', [20 20]; ...
    'pointBatchSize', -1; ...
    'pointBatchSize', Inf; ...
    'pointBatchSize', 0.5};
for valueIndex = 1:size(invalidValues, 1)
    invalidParameters = validParameters;
    invalidParameters.(invalidValues{valueIndex, 1}) = invalidValues{valueIndex, 2};
    verifyError(testCase, ...
        @() validate_cost_ICPLike(invalidParameters, struct()), ...
        ?MException, sprintf('%s = %s should be rejected.', ...
        invalidValues{valueIndex, 1}, mat2str(invalidValues{valueIndex, 2})));
end
end


function testDistancesMatchExhaustiveSearch(testCase)
%TESTDISTANCESMATCHEXHAUSTIVESEARCH Check the K-nearest-vertex shortcut.
% testCase supplies prepared data. This function has no output.

% The cost only searches the faces around the K nearest vertices. For the
% project mesh that must still find the true closest location, so a sample
% of points is compared with a search over every face of the moved mesh.
poseVector = [1; -0.5; 0.25; deg2rad(1); deg2rad(-0.5); deg2rad(0.25)];
[~, details] = cost_ICPLike(poseVector, testCase.TestData.data, testCase.TestData.config);

boneMeshRef = details.boneMeshRefCandidate;
faces       = boneMeshRef.ConnectivityList;
vertices    = boneMeshRef.Points;
sampledPointIndices = 1:25:size(details.boneSurfacePointsRef, 1);
for pointIndex = sampledPointIndices
    queryPoint = repmat(details.boneSurfacePointsRef(pointIndex, :), size(faces, 1), 1);
    [~, squaredDistances] = closestPointsOnTriangles(queryPoint, ...
        vertices(faces(:, 1), :), vertices(faces(:, 2), :), vertices(faces(:, 3), :));
    verifyEqual(testCase, details.pointToSurfaceDistancesMm(pointIndex), ...
        sqrt(min(squaredDistances)), 'AbsTol', 1e-9);
end
end


function testBatchSizeDoesNotChangeResult(testCase)
%TESTBATCHSIZEDOESNOTCHANGERESULT Check that batching is only a speed setting.
% testCase supplies prepared data. This function has no output.

data = testCase.TestData.data;
config = testCase.TestData.config;
poseVector = [-0.75; 0.5; 1; deg2rad(-0.5); deg2rad(0.25); deg2rad(0.75)];
[referenceCost, referenceDetails] = cost_ICPLike(poseVector, data, config);

% An odd small batch leaves a short last batch, and a batch larger than the
% point cloud puts everything in one batch. Both must give the same answer.
numberOfPoints = numel(referenceDetails.pointToSurfaceDistancesMm);
for pointBatchSize = [37, numberOfPoints + 1]
    batchConfig = config;
    batchConfig.cost.parameters.pointBatchSize = pointBatchSize;
    [batchCost, batchDetails] = cost_ICPLike(poseVector, data, batchConfig);
    verifyEqual(testCase, batchCost, referenceCost);
    verifyEqual(testCase, batchDetails.closestBonePointsRef, referenceDetails.closestBonePointsRef);
    verifyEqual(testCase, batchDetails.closestFaceIndexByPoint, referenceDetails.closestFaceIndexByPoint);
end
end


function testDispatcherMatchesDirectCall(testCase)
%TESTDISPATCHERMATCHESDIRECTCALL Check dispatch and the returned details.
% testCase supplies prepared data. This function has no output.

data = testCase.TestData.data;
config = testCase.TestData.config;
poseVector = [1; -0.5; 0.25; deg2rad(1); deg2rad(-0.5); deg2rad(0.25)];

% The dispatcher performs no calculation, so both calls must agree exactly.
% The details also hold search timings, which differ between any two calls,
% so compare only the values that define the result.
[publicCost, publicDetails] = bonePoseCostFunction(poseVector, data, config);
[directCost, directDetails] = cost_ICPLike(poseVector, data, config);
verifyEqual(testCase, publicCost, directCost);
verifyEqual(testCase, publicDetails.costModel, 'ICPLike');
verifyEqual(testCase, publicDetails.T_CT_ref_candidate, directDetails.T_CT_ref_candidate);
verifyEqual(testCase, publicDetails.closestBonePointsRef, directDetails.closestBonePointsRef);
verifyEqual(testCase, publicDetails.costSettings, directDetails.costSettings);

% A moved pose must still give one finite cost that differs from the start,
% and the per-image split must account for every measured point.
verifyTrue(testCase, isscalar(publicCost) && isfinite(publicCost));
verifyNotEqual(testCase, publicCost, testCase.TestData.initialCost);
verifyEqual(testCase, sum(publicDetails.numberOfSurfacePointsByMeasurement), ...
    numel(publicDetails.pointToSurfaceDistancesMm));
verifyEqual(testCase, publicDetails.costSettings.nearestVertexCount, 20);
verifyEqual(testCase, publicDetails.costSettings.pointBatchSize, 200);
verifyEqual(testCase, publicDetails.status, '3d_point_cloud_rmse_computed');
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

% The prepared data now carries a KD-tree object, and the parallel run must
% still be able to send it to every worker. Without the toolbox the runner
% falls back to serial, so there is nothing to test.
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
