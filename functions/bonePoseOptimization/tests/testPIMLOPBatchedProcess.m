function tests = testPIMLOPBatchedProcess
%TESTPIMLOPBATCHEDPROCESS Check the batched P-IMLOP functions against the scalar ones.
% Every reusable function in functions/PIMLOP/ has a readable scalar
% version (one query at a time) and a fast *_batchedProcess version (many
% queries at once). The cost model uses the batched versions, so this suite
% checks that they give the same answers as the scalar references:
% closest point on a triangle, the match error, the ellipsoid/box pruning
% test, and the full PD-tree search on synthetic and real data.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

% Let MATLAB discover every local function whose name starts with test.
tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Add the project functions once for this suite.
% testCase stores the project root. This function has no output.

% Walk from this test file through tests/, bonePoseOptimization/, and functions/.
testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));
testCase.TestData.projectRoot = projectRoot;
end


function testClosestTrianglePointKnownCases(testCase)
%TESTCLOSESTTRIANGLEPOINTKNOWNCASES Check interior, edge, and vertex answers.
% Analytically known cases come first, so an accidental boundary-only
% solver is caught before comparing two implementations with each other.
% testCase supplies verification methods. This function has no output.

triangle = [0 0 0; 4 0 0; 0 4 0];
queries  = [1 1 2; 3 3 2; -1 -1 1];   % above the interior, beyond an edge, beyond a vertex
[positions, weights] = findMostLikelyPointOnTriangle_batchedProcess(queries, triangle, eye(3));

verifyEqual(testCase, reshape(positions, 3, 3), [1 1 0; 2 2 0; 0 0 0], 'AbsTol', 1e-12);
verifyEqual(testCase, reshape(weights, 3, 3), [0.5 0.25 0.25; 0 0.5 0.5; 1 0 0], 'AbsTol', 1e-12);
end


function testClosestTrianglePointMatchesScalar(testCase)
%TESTCLOSESTTRIANGLEPOINTMATCHESSCALAR Compare every query/triangle pair.
% Random triangles and an off-axis anisotropic covariance cover the general
% case. testCase supplies verification methods. This function has no output.

synthetic = makeSyntheticCase();
[positions, weights, squaredDistances] = findMostLikelyPointOnTriangle_batchedProcess( ...
    synthetic.queries, synthetic.triangles, synthetic.Sigma);

for queryIndex = 1:size(synthetic.queries, 1)
    for triangleIndex = 1:size(synthetic.triangles, 3)
        query = synthetic.queries(queryIndex, :).';
        [scalarPosition, scalarWeights] = findMostLikelyPointOnTriangle( ...
            query, synthetic.triangles(:, :, triangleIndex), synthetic.Sigma);
        batchPosition = reshape(positions(queryIndex, triangleIndex, :), 3, 1);
        batchWeights  = reshape(weights(queryIndex, triangleIndex, :), 3, 1);
        residual = scalarPosition - query;

        verifyEqual(testCase, batchPosition, scalarPosition, 'AbsTol', 1e-8);
        verifyEqual(testCase, batchWeights, scalarWeights, 'AbsTol', 1e-8);
        verifyEqual(testCase, squaredDistances(queryIndex, triangleIndex), ...
            residual.' * (synthetic.Sigma \ residual), 'AbsTol', 1e-8);

        % Barycentric weights of a point on the triangle are >= 0 and sum to 1.
        verifyGreaterThanOrEqual(testCase, min(batchWeights), -1e-12);
        verifyEqual(testCase, sum(batchWeights), 1, 'AbsTol', 1e-12);
    end
end
end


function testMatchErrorMatchesScalar(testCase)
%TESTMATCHERRORMATCHESSCALAR Compare the paired match errors.
% The first model normal points straight out of the image plane, so its
% projection is undefined and must follow the "zero agreement" rule in
% both versions. testCase supplies verification methods. This function has
% no output.

synthetic = makeSyntheticCase();
[batchErrors, batchDetails] = calculatePIMLOPMatchError_batchedProcess( ...
    synthetic.X, synthetic.Y, eye(3), synthetic.Sigma, 50);
verifyFalse(testCase, batchDetails.projectionIsDefined(1));

for pointIndex = 1:size(synthetic.X.position3D, 1)
    xScalar = struct('position3D', synthetic.X.position3D(pointIndex, :).', ...
                     'normal2DImage', synthetic.X.normal2DImage(pointIndex, :).');
    yScalar = struct('position3D', synthetic.Y.position3D(pointIndex, :).', ...
                     'normal3D', synthetic.Y.normal3D(pointIndex, :).');
    [scalarError, scalarDetails] = calculatePIMLOPMatchError(xScalar, yScalar, eye(3), synthetic.Sigma, 50);

    verifyEqual(testCase, batchErrors(pointIndex), scalarError, 'AbsTol', 1e-9);
    verifyEqual(testCase, batchDetails.orientationAngleDeg(pointIndex), ...
        scalarDetails.orientationAngleDeg, 'AbsTol', 1e-10);
end
end


function testEllipsoidBoxTestMatchesScalar(testCase)
%TESTELLIPSOIDBOXTESTMATCHESSCALAR Compare the pruning test per query.
% Different ellipsoid sizes per query let the same box survive for only
% some queries. testCase supplies verification methods. This function has
% no output.

synthetic = makeSyntheticCase();
node.T_node_CT     = [synthetic.rotation, [1; 2; 3]; 0 0 0 1];
node.boundsMinNode = [-2 -1 -0.5];
node.boundsMaxNode = [1 3 2];
errorLimits = linspace(0, 20, 11).';

[batchKeep, batchDistances] = ellipsoidIntersectsOBB_batchedProcess( ...
    synthetic.queries, inv(synthetic.Sigma), errorLimits, node);
for queryIndex = 1:size(synthetic.queries, 1)
    [scalarKeep, scalarDistance] = ellipsoidIntersectsOBB( ...
        synthetic.queries(queryIndex, :).', inv(synthetic.Sigma), errorLimits(queryIndex), node);
    verifyEqual(testCase, batchKeep(queryIndex), scalarKeep);
    verifyEqual(testCase, batchDistances(queryIndex), scalarDistance, 'AbsTol', 1e-9);
end

% A point inside the box with zero radius, and a sphere that just touches
% the box, must both be kept; a slightly smaller sphere must not.
unitBox.T_node_CT     = eye(4);
unitBox.boundsMinNode = [0 0 0];
unitBox.boundsMaxNode = [1 1 1];
keep = ellipsoidIntersectsOBB_batchedProcess( ...
    [0.5 0.5 0.5; 2 0.5 0.5; 2 0.5 0.5], eye(3), [0; 0.5; 0.49], unitBox);
verifyEqual(testCase, keep, [true; true; false]);
end


function testPrunedSearchMatchesExhaustiveSearch(testCase)
%TESTPRUNEDSEARCHMATCHESEXHAUSTIVESEARCH Check pruning never drops a winner.
% A tiny mesh with a deep tree is searched once with pruning and once
% exhaustively with one query and one pair per batch; kappa = 0 tests the
% position-only case. testCase supplies verification methods. This
% function has no output.

synthetic = makeSyntheticCase();
vertices = reshape(permute(synthetic.triangles, [1 3 2]), [], 3);
faces    = reshape(1:size(vertices, 1), 3, []).';
model = preparePIMLOPModel_batchedProcess(triangulation(faces, vertices));
model.pdTree = buildPIMLOPPDTree_batchedProcess(model.mesh, model.validFaceMask, ...
    struct('faceCountThreshold', 2, 'minimumNodeDiagonalMm', 0));

[prunedMatches, prunedErrors] = searchPDTree_batchedProcess( ...
    synthetic.X, model, synthetic.rotation, synthetic.Sigma, 0);
[exhaustiveMatches, exhaustiveErrors] = searchPDTree_batchedProcess( ...
    synthetic.X, model, synthetic.rotation, synthetic.Sigma, 0, ...
    struct('UsePruning', false, 'QueryBatchSize', 1, 'MaxPairsPerBatch', 1));

verifyEqual(testCase, prunedErrors, exhaustiveErrors, 'AbsTol', 1e-8);
verifyEqual(testCase, prunedMatches.position3D, exhaustiveMatches.position3D, 'AbsTol', 1e-8);
end


function testRealQueriesMatchScalarSearch(testCase)
%TESTREALQUERIESMATCHSCALARSEARCH Compare both searches on real tibia data.
% The first five and last five valid measurements of image 11 are searched
% with the scalar search (the independent reference), the batched search,
% an exhaustive batched search, and a batched search with tiny batches.
% All four must agree. testCase supplies the project root. This function
% has no output.

% Prepare the real data the same way an optimization does.
configPath = fullfile(testCase.TestData.projectRoot, 'config', 'optconfig_oneSweep_PIMLOP.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :), experimentPlan.runs.seed(1));
data  = prepareBonePoseOptimizationInputs(config);
model = data.extra.pimlop.PsiCT;

% Pick the ten endpoint measurements of image 11.
imageIndex  = 11;
measurement = data.boneSurfaceMeasurements(imageIndex);
validRows   = find(measurement.surfaceNormalMask);
selectedRows = validRows([1:5, end-4:end]);

% The tree lives in CT, so move the points ref -> CT with the inverse of
% the start pose, and rotate the image axes into CT the same way.
R_CT_ref = data.T_CT_ref_initial(1:3, 1:3);
t_CT_ref = data.T_CT_ref_initial(1:3, 4);
T_ref_CT = [R_CT_ref.', -R_CT_ref.' * t_CT_ref; 0 0 0 1];
R_image_CT = T_ref_CT(1:3, 1:3) * data.imagePlanesRef(imageIndex).T_image_ref(1:3, 1:3);
queriesCT.position3D    = applyRigidTransform(measurement.surfaceCoordinatesXYZRef(selectedRows, :), T_ref_CT);
queriesCT.normal2DImage = measurement.surfaceNormalXY(selectedRows, :);
SigmaImage = diag([1 1 1.5] .^ 2);
kappa = 50;

% Batched search, then the scalar search one query at a time.
[batchMatches, batchErrors] = searchPDTree_batchedProcess(queriesCT, model, R_image_CT, SigmaImage, kappa);
scalarPositions = zeros(10, 3);
scalarErrors    = zeros(10, 1);
scalarFaces     = zeros(10, 1);
for queryIndex = 1:10
    query.position3D    = queriesCT.position3D(queryIndex, :).';
    query.normal2DImage = queriesCT.normal2DImage(queryIndex, :).';
    [match, scalarErrors(queryIndex)] = searchPDTree(query, model, R_image_CT, SigmaImage, kappa);
    scalarPositions(queryIndex, :) = match.position3D.';
    scalarFaces(queryIndex) = match.faceIndex;
end
verifyEqual(testCase, batchMatches.position3D, scalarPositions, 'AbsTol', 1e-7);
verifyEqual(testCase, batchErrors, scalarErrors, 'AbsTol', 1e-8);
verifyEqual(testCase, batchMatches.faceIndex, scalarFaces);

% Turning pruning off, or using tiny batches, must not change the answer.
[exhaustiveMatches, exhaustiveErrors] = searchPDTree_batchedProcess( ...
    queriesCT, model, R_image_CT, SigmaImage, kappa, struct('UsePruning', false));
verifyEqual(testCase, exhaustiveErrors, batchErrors, 'AbsTol', 1e-8);
verifyEqual(testCase, exhaustiveMatches.position3D, batchMatches.position3D, 'AbsTol', 1e-7);

[smallBatchMatches, smallBatchErrors] = searchPDTree_batchedProcess( ...
    queriesCT, model, R_image_CT, SigmaImage, kappa, struct('QueryBatchSize', 3, 'MaxPairsPerBatch', 32));
verifyEqual(testCase, smallBatchErrors, batchErrors, 'AbsTol', 1e-8);
verifyEqual(testCase, smallBatchMatches.position3D, batchMatches.position3D, 'AbsTol', 1e-7);
end


function synthetic = makeSyntheticCase()
%MAKESYNTHETICCASE Build the same random synthetic inputs for every test.
% A fixed random stream makes every test repeatable and independent of the
% global random state.
%
% Output:
%   synthetic - Structure with 17 random triangles (3x3x17), 11 query
%               points, an off-axis anisotropic covariance Sigma, paired
%               oriented points X and Y, and a random proper rotation.

randomStream = RandStream('mt19937ar', 'Seed', 47);

synthetic.triangles = randn(randomStream, 3, 3, 17) * 3;
synthetic.queries   = randn(randomStream, 11, 3) * 4;

% A = some invertible matrix, so A*A' is a valid covariance whose axes are
% neither aligned with x, y, z nor equal in size.
A = [1 0.3 -0.1; 0.2 2 0.4; 0.1 -0.2 0.7];
synthetic.Sigma = A * A.';

synthetic.X = struct('position3D', synthetic.queries, 'normal2DImage', randn(randomStream, 11, 2));
synthetic.Y = struct('position3D', randn(randomStream, 11, 3), 'normal3D', randn(randomStream, 11, 3));
synthetic.Y.normal3D(1, :) = [0 0 1];   % normal along image z: projection undefined

% QR of a random matrix gives an orthogonal matrix; flip one column if
% needed so it is a proper rotation (det = +1), not a reflection.
[rotation, ~] = qr(randn(randomStream, 3));
if det(rotation) < 0
    rotation(:, 3) = -rotation(:, 3);
end
synthetic.rotation = rotation;
end
