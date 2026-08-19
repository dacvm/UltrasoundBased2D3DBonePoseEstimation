function tests = testBonePoseOptimizationEvaluation
%TESTBONEPOSEOPTIMIZATIONEVALUATION Test evaluation metrics and displays.
% This suite checks the three geometric metrics, seed aggregation, ranking,
% and basic creation of every evaluation figure.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Add project functions before running the evaluation tests.
% testCase receives the project root through TestData. This function has no output.

testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));
testCase.TestData.projectRoot = projectRoot;
end


function testTranslationAndRotationMetrics(testCase)
%TESTTRANSLATIONANDROTATIONMETRICS Check known rigid-pose differences.
% testCase provides MATLAB verification methods. This function has no output.

T_bone_ref_groundTruth = eye(4);
T_bone_ref_estimate = eye(4);
T_bone_ref_estimate(1:3, 4) = [3; 4; 0];

% A three-four-five translation should produce exactly five millimetres.
verifyEqual(testCase, calculateTranslationErrorMm( ...
    T_bone_ref_groundTruth, T_bone_ref_estimate), 5, 'AbsTol', 1e-12);

% Add a known thirty-degree rotation around the reference Z axis.
rotationAngleDeg = 30;
rotationAngleRad = deg2rad(rotationAngleDeg);
T_bone_ref_estimate(1:3, 1:3) = ...
    [cos(rotationAngleRad), -sin(rotationAngleRad), 0; ...
     sin(rotationAngleRad),  cos(rotationAngleRad), 0; ...
     0,                      0,                     1];
verifyEqual(testCase, calculateRotationErrorDeg( ...
    T_bone_ref_groundTruth, T_bone_ref_estimate), ...
    rotationAngleDeg, 'AbsTol', 1e-10);
end


function testSurfaceRmseUsesCorrespondingVertices(testCase)
%TESTSURFACERMSEUSESCORRESPONDINGVERTICES Check direct mesh displacement.
% testCase provides MATLAB verification methods. This function has no output.

connectivity = [1 2 3];
groundTruthPoints = [0 0 0; 1 0 0; 0 1 0];
estimatedPoints = groundTruthPoints + [3 4 0];
boneMeshRefGroundTruth = triangulation(connectivity, groundTruthPoints);
boneMeshRefEstimate = triangulation(connectivity, estimatedPoints);

% Every vertex moves five millimetres, so their RMS distance is also five.
verifyEqual(testCase, calculateSurfaceRmseMm( ...
    boneMeshRefGroundTruth, boneMeshRefEstimate), 5, 'AbsTol', 1e-12);
end


function testSurfaceRmseRejectsMismatchedMeshes(testCase)
%TESTSURFACERMSEJECTSMISMATCHEDMESHES Check the correspondence requirement.
% testCase provides MATLAB verification methods. This function has no output.

groundTruthMesh = triangulation([1 2 3], ...
    [0 0 0; 1 0 0; 0 1 0]);
estimateMesh = triangulation([1 3 2], ...
    [0 0 0; 1 0 0; 0 1 0]);

verifyError(testCase, ...
    @() calculateSurfaceRmseMm(groundTruthMesh, estimateMesh), ...
    'calculateSurfaceRmseMm:MeshCorrespondenceMismatch');
end


function testCombinationAggregationAndRanking(testCase)
%TESTCOMBINATIONAGGREGATIONANDRANKING Check counts and robust summaries.
% testCase provides MATLAB verification methods. This function has no output.

[perRunTable, parameterNames] = createSyntheticPerRunTable();
perCombinationTable = createCombinationEvaluationTable(perRunTable, parameterNames);

% Combination one has lower median RMSE and must therefore rank first.
verifyEqual(testCase, perCombinationTable.combinationNumber, [1; 2]);
verifyEqual(testCase, perCombinationTable.combinationRank, [1; 2]);
verifyEqual(testCase, perCombinationTable.medianSurfaceRmseMm, [3; 6]);

% Failed optimizer rows remain counted but do not enter the metric statistics.
verifyEqual(testCase, perCombinationTable.numberPlanned, [3; 2]);
verifyEqual(testCase, perCombinationTable.numberEvaluated, [2; 2]);
verifyEqual(testCase, perCombinationTable.numberOptimizerFailed, [1; 0]);
verifyEqual(testCase, perCombinationTable.evaluationRate, [2/3; 1], ...
    'AbsTol', 1e-12);
verifyEqual(testCase, perCombinationTable.iqrSurfaceRmseMm, ...
    perCombinationTable.q75SurfaceRmseMm - ...
    perCombinationTable.q25SurfaceRmseMm, 'AbsTol', 1e-12);

% The generic identity and parameter columns must keep the saved plan order.
expectedLeadingColumns = [{'combinationRank', 'combinationNumber', ...
    'combinationId', 'costModel'}, parameterNames];
verifyEqual(testCase, ...
    perCombinationTable.Properties.VariableNames(1:numel(expectedLeadingColumns)), ...
    expectedLeadingColumns);
verifyEqual(testCase, perCombinationTable.costModel, ...
    repmat("intensityCoverage_v1", 2, 1));
end


function testFutureParameterPropagatesInRequestedOrder(testCase)
%TESTFUTUREPARAMETERPROPAGATESINREQUESTEDORDER Check model-independent columns.
% testCase provides MATLAB verification methods. This function has no output.

[perRunTable, parameterNames] = createSyntheticPerRunTable();

% Add one possible future parameter without changing the production aggregator.
perRunTable.futureWeight = [2; 2; 2; 1; 1];
parameterNames = [{'futureWeight'}, parameterNames];
perCombinationTable = createCombinationEvaluationTable(perRunTable, parameterNames);

% Combination ranking remains unchanged while the new column follows the requested order.
verifyEqual(testCase, perCombinationTable.futureWeight, [2; 1]);
verifyEqual(testCase, ...
    perCombinationTable.Properties.VariableNames(5:(4 + numel(parameterNames))), ...
    parameterNames);
end


function testInvalidParameterListsAreRejected(testCase)
%TESTINVALIDPARAMETERLISTSAREREJECTED Check readable generic-column errors.
% testCase provides MATLAB verification methods. This function has no output.

[perRunTable, parameterNames] = createSyntheticPerRunTable();

% A missing column should identify the configuration-to-table mismatch directly.
verifyError(testCase, ...
    @() createCombinationEvaluationTable(perRunTable, [{'futureWeight'}, parameterNames]), ...
    'createCombinationEvaluationTable:MissingColumn');

% Repeated names would otherwise try to create the same output column twice.
verifyError(testCase, ...
    @() createCombinationEvaluationTable(perRunTable, [parameterNames, parameterNames(1)]), ...
    'createCombinationEvaluationTable:DuplicateParameterName');
end


function testInconsistentCombinationMetadataIsRejected(testCase)
%TESTINCONSISTENTCOMBINATIONMETADATAISREJECTED Check seed-row agreement.
% testCase provides MATLAB verification methods. This function has no output.

[perRunTable, parameterNames] = createSyntheticPerRunTable();

% All seeds of one combination must use the same scalar parameter values.
inconsistentParameters = perRunTable;
inconsistentParameters.minReferencePixels(2) = 75;
verifyError(testCase, ...
    @() createCombinationEvaluationTable(inconsistentParameters, parameterNames), ...
    'createCombinationEvaluationTable:InconsistentCombinationMetadata');

% One experiment combination must also keep one cost-model identity across seeds.
inconsistentModels = perRunTable;
inconsistentModels.costModel(2) = "another_model";
verifyError(testCase, ...
    @() createCombinationEvaluationTable(inconsistentModels, parameterNames), ...
    'createCombinationEvaluationTable:InconsistentCombinationMetadata');
end


function testEvaluationPlotsReturnFigures(testCase)
%TESTEVALUATIONPLOTSRETURNFIGURES Smoke-test all dedicated plot functions.
% testCase provides MATLAB verification methods. This function has no output.

% Hide test figures so automated runs do not interrupt the user.
originalVisibility = get(groot, 'defaultFigureVisible');
set(groot, 'defaultFigureVisible', 'off');
visibilityCleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', originalVisibility));
figureCleanup = onCleanup(@() close(findall(groot, 'Type', 'figure')));

[perRunTable, parameterNames] = createSyntheticPerRunTable();
perCombinationTable = createCombinationEvaluationTable(perRunTable, parameterNames);

figureHandles = [ ...
    plotSurfaceRmseBoxplot(perRunTable, perCombinationTable, 20), ...
    plotRankedSurfaceRmse(perCombinationTable), ...
    plotTranslationRotationErrors(perCombinationTable), ...
    plotHyperparameterFacetedHeatmaps(perCombinationTable), ...
    plotOptimizerCostVsSurfaceRmse(perCombinationTable)];

verifyTrue(testCase, all(isgraphics(figureHandles, 'figure')));
end


function [perRunTable, parameterNames] = createSyntheticPerRunTable()
%CREATESYNTHETICPERRUNTABLE Build small deterministic evaluation results.
% This function has no input. perRunTable contains two combinations with
% evaluated and failed seed rows, while parameterNames declares the columns
% used by aggregation and plot tests.

runNumber = (1:5).';
runId = compose("run_%06d", runNumber);
combinationNumber = [1; 1; 1; 2; 2];
combinationId = compose("combination_%04d", combinationNumber);
costModel = repmat("intensityCoverage_v1", 5, 1);
seed = [1001; 1002; 1003; 1001; 1002];
normalFacingToleranceDeg = 30 * ones(5, 1);
minReferencePixels = [50; 50; 50; 100; 100];
nMinPixels = 100 * ones(5, 1);
lambdaMissing = ones(5, 1);
status = ["completed"; "completed"; "failed"; "completed"; "completed"];
runtimeSeconds = [10; 12; 0; 14; 16];
bestCost = [-0.8; -0.7; NaN; -0.6; -0.5];
evaluationStatus = ["evaluated"; "evaluated"; "skipped"; "evaluated"; "evaluated"];
translationErrorMm = [1; 3; NaN; 5; 7];
rotationErrorDeg = [2; 4; NaN; 6; 8];
surfaceRmseMm = [2; 4; NaN; 5; 7];

perRunTable = table(runNumber, runId, combinationNumber, combinationId, ...
    costModel, seed, normalFacingToleranceDeg, minReferencePixels, nMinPixels, ...
    lambdaMissing, status, runtimeSeconds, bestCost, evaluationStatus, ...
    translationErrorMm, rotationErrorDeg, surfaceRmseMm);

% Match the canonical parameter order returned by the V1 validator and planner.
parameterNames = {'normalFacingToleranceDeg', 'minReferencePixels', ...
    'nMinPixels', 'lambdaMissing'};
end
