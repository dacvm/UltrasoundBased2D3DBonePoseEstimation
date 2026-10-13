% DEVDEMO_COST_ICPLIKE2 Validate and time cost_ICPLike against dev_cost_ICPLike.
%
% A NOTE ON THE NAMES
%   This script was written while the faster ICP-like cost was still a
%   development function called dev_cost_ICPLike2. That function has since
%   become the pipeline cost model cost_ICPLike, in
%   functions/bonePoseOptimization/costModels/. The previous pipeline
%   version moved here as dev_cost_ICPLike, a study case kept only for this
%   comparison. The "2" in this script's name refers to the old name of the
%   faster version.
%
% cost_ICPLike is a faster version of dev_cost_ICPLike. Instead of moving
% the mesh and rebuilding a KD-tree and a vertex-to-face list on every call,
% it builds both ONCE in the CT frame, moves the measured points into CT,
% and finds all closest points on triangles in a few large batched array
% computations. This script checks that the faster version gives the same
% answers as the original, and measures how much time it saves.
%
% HOW TO READ THIS SCRIPT
%   The top part is a short "table of contents": each section calls ONE
%   local function that does one job and prints its own report. The local
%   functions below are grouped in the same order, so you can jump from a
%   section to the function with the same name.
%
%   Step  What it does                                      Local function           Figure
%   ----  ------------------------------------------------  -----------------------  ------
%   1     Load optimization_setup.mat, make an ICPLike       loadIcpLikeSetup           -
%         config
%   2     Build the pose-independent search data ONCE       buildIcpLikeSearchData     -
%         (CT KD-tree + vertex-to-face table) and store
%         it in data.extra.icpLike
%   3     TEST A: batched triangle function vs geom3d on    testTriangleCases          5
%         hand-made points
%   4     TEST B: new cost vs dev_cost_ICPLike at several   compareWithOriginalCost    1, 2, 3
%         poses (same costs, distances, KNN?)
%   5     TEST C: speed over many evaluations, and the     timeRepeatedEvaluations    4 (line)
%         work the old version repeats on every call
%   6     TEST D: effect of batch size                      testBatchSizes             4
%   7     TEST E: effect of the candidate-face layout       compareCandidateLayouts    -
%   8     Draw all figures                                  plot* functions          1-5

% Start from an empty workspace and no open figures, so the figure numbers
% in the table above match the figures this run creates.
clear; clc; close all;

% The new cost function lives in the project's functions folder, while the
% old dev_cost_ICPLike and the setup file live next to this script, so both
% folders must be on the path before anything else runs.
developmentFolder = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(developmentFolder));
addpath(genpath(fullfile(projectRoot, 'functions')));
addpath(developmentFolder);

%% STEP 1. LOAD THE SETUP AND MAKE AN ICPLIKE CONFIG
% Both cost functions must see exactly the same prepared data, so one saved
% setup is loaded and switched to the ICPLike cost model.
[data, config] = loadIcpLikeSetup(developmentFolder);

%% STEP 2. BUILD THE POSE-INDEPENDENT SEARCH DATA ONCE (outside the cost function)
% The new cost function expects its KD-tree and vertex-to-face table to be
% ready in data, just as the optimizer would prepare them before the first
% call. searchData also keeps the build times and the per-vertex face
% cells, which later tests reuse.
[data, searchData] = buildIcpLikeSearchData(data);

%% STEP 3. TEST A -- BATCHED TRIANGLE FUNCTION VS GEOM3D ON HAND-MADE CASES
% Before trusting the whole cost, its core building block (closest point on
% a triangle) is checked on simple cases where the right answer is clear.
triangleTest = testTriangleCases();

%% STEP 4. TEST B -- COMPARE WITH dev_cost_ICPLike AT SEVERAL POSES
% With the building block trusted, the full new cost is compared with the
% original at several poses. The results at the start pose (pose 1) are
% kept for the figures and the batch-size test.
poseComparison = compareWithOriginalCost(data, config, searchData);

%% STEP 5. TEST C -- TIME REPEATED EVALUATIONS
% Once the answers match, the speed is measured the way an optimizer uses
% the cost: many calls on the same data.
repeatedTiming = timeRepeatedEvaluations(data, config, searchData, poseComparison);

%% STEP 6. TEST D -- EFFECT OF BATCH SIZE
% The new version splits the points into batches, so the next question is
% which batch size is fastest without changing the result.
batchSizeTest = testBatchSizes(data, config, poseComparison);

%% STEP 7. TEST E -- EFFECT OF THE CANDIDATE-FACE LAYOUT
% Finally, the choice to remove repeated candidate faces is checked: it must
% give the same distances as the simpler padded layout, but faster.
compareCandidateLayouts(poseComparison.newDetailsAtStart, searchData.faceIndicesByVertex, data.boneMeshCT.ConnectivityList);

%% STEP 8. FIGURES
% All figures are drawn at the end from the stored results, so the tests
% above stay free of plotting code.
plotCorrespondenceScene(data, poseComparison.newDetailsAtStart);
plotOldVersusNew(poseComparison.originalDetailsAtStart, poseComparison.newDetailsAtStart, poseComparison.originalCosts, poseComparison.newCosts);
plotSinglePointSearch(poseComparison.newDetailsAtStart, poseComparison.originalDetailsAtStart, searchData.faceIndicesByVertex);
plotBatchSizeEffect(batchSizeTest.batchSizes, batchSizeTest.medianSeconds, batchSizeTest.inputMegabytes, repeatedTiming.originalMedianSeconds);
plotTriangleTestCases(triangleTest.cornerA, triangleTest.cornerB, triangleTest.cornerC, triangleTest.testPoints, triangleTest.newClosestPoints, triangleTest.geom3dVectorizedPoints);


%% ===================================================================
% STEP 1 -- SETUP
% ===================================================================

function [data, config] = loadIcpLikeSetup(developmentFolder)
%LOADICPLIKESETUP Load optimization_setup.mat and switch its config to ICPLike.
% The fixture holds data, config and initialCost. Its config was made for
% the P-IMLOP model, so the cost block is replaced with ICPLike settings.
% Both cost functions read nearestVertexCount; pointBatchSize is only read
% by cost_ICPLike.
%
% Input:   developmentFolder - folder that contains optimization_setup.mat.
% Outputs: data, config      - prepared data and the ICPLike runtime config
%                              (data.config is set to the same config).

% The saved setup already holds fully prepared data, so no slow
% preparation has to be repeated here.
setup  = load(fullfile(developmentFolder, 'optimization_setup.mat'), 'data', 'config');
data   = setup.data;
config = setup.config;

% Swap in the ICPLike cost settings. data.config gets the same copy so that
% code reading the config from data sees the same settings.
config.cost.model      = 'ICPLike';
config.cost.parameters = struct('nearestVertexCount', 20, 'pointBatchSize', 200);
data.config = config;

% A one-line summary of the problem size helps to read the timings later:
% the run time grows with the number of points and mesh faces.
numberOfVertices     = size(data.boneMeshCT.Points, 1);
numberOfFaces        = size(data.boneMeshCT.ConnectivityList, 1);
numberOfPoints       = size(vertcat(data.boneSurfaceMeasurements.surfaceCoordinatesXYZRef), 1);
fprintf('=== cost_ICPLike demonstration ===\n');
fprintf('Bone %s: %d vertices, %d faces, %d measured points in %d images, K = %d\n\n', ...
    data.boneName, numberOfVertices, numberOfFaces, numberOfPoints, ...
    numel(data.boneSurfaceMeasurements), config.cost.parameters.nearestVertexCount);
end


%% ===================================================================
% STEP 2 -- POSE-INDEPENDENT SEARCH DATA
% ===================================================================

function [data, searchData] = buildIcpLikeSearchData(data)
%BUILDICPLIKESEARCHDATA Build the CT KD-tree and vertex-to-face table once.
% The CT mesh never changes during the optimization, so both structures are
% valid for every candidate pose. They are stored in data.extra.icpLike,
% which is where cost_ICPLike reads them.
%
% Input:   data       - prepared data with data.boneMeshCT.
% Outputs: data       - the same data with data.extra.icpLike filled in.
%          searchData - struct with the two structures, the per-vertex face
%                       cells (used by test B), and the build times.

% Everything below is built from the CT mesh, which stays fixed during
% the optimization.
boneMeshCT       = data.boneMeshCT;
numberOfVertices = size(boneMeshCT.Points, 1);

% closestPointsOnTriangles divides by each triangle's (doubled) area
% squared, so it assumes there are no zero-area faces. A quick check of
% this mesh confirms that assumption before any distance is trusted.
faceCornerA  = boneMeshCT.Points(boneMeshCT.ConnectivityList(:, 1), :);
faceCornerB  = boneMeshCT.Points(boneMeshCT.ConnectivityList(:, 2), :);
faceCornerC  = boneMeshCT.Points(boneMeshCT.ConnectivityList(:, 3), :);
faceAreasMm2 = 0.5 * vecnorm(cross(faceCornerB - faceCornerA, faceCornerC - faceCornerA, 2), 2, 2);
fprintf('Smallest face area: %.4f mm^2 (zero-area faces: %d)\n', min(faceAreasMm2), nnz(faceAreasMm2 == 0));

% With the mesh checked, the KD-tree is built over the CT-frame vertices.
% The cost function moves the measured points into CT instead of moving
% the mesh, so this one tree is valid for every pose. The build is timed
% to show what the old version pays again on each call.
treeTimer        = tic;
vertexTreeCT     = KDTreeSearcher(boneMeshCT.Points);
treeBuildSeconds = toc(treeTimer);

% Next comes the vertex-to-face table, which turns each nearest vertex into
% the faces around it. vertexAttachments returns one cell per vertex, each
% with a different number of faces. A plain matrix is easier to index for
% all points at once, so every row is padded to the same width by repeating
% the vertex's first face. The cost function removes repeats again, so the
% padding never changes the result.
tableTimer        = tic;
attachedFaceCells = vertexAttachments(boneMeshCT, (1:numberOfVertices).');
facesPerVertex    = max(cellfun(@numel, attachedFaceCells));
faceIndicesByVertex = zeros(numberOfVertices, facesPerVertex);
for vertexIndex = 1:numberOfVertices
    attachedFaces  = attachedFaceCells{vertexIndex};
    numberOfRepeats = facesPerVertex - numel(attachedFaces);
    faceIndicesByVertex(vertexIndex, :) = [attachedFaces, repmat(attachedFaces(1), 1, numberOfRepeats)];
end
tableBuildSeconds = toc(tableTimer);

% Hand both structures to the cost function through data.extra, which is
% where cost_ICPLike looks for them.
data.extra.icpLike.vertexTreeCT        = vertexTreeCT;
data.extra.icpLike.faceIndicesByVertex = faceIndicesByVertex;

% Keep a second copy, plus the unpadded face cells and the build times,
% for the tests that follow.
searchData.vertexTreeCT        = vertexTreeCT;
searchData.faceIndicesByVertex = faceIndicesByVertex;
searchData.attachedFaceCells   = attachedFaceCells;
searchData.treeBuildSeconds    = treeBuildSeconds;
searchData.tableBuildSeconds   = tableBuildSeconds;

% Report the one-time build cost, to compare later with the per-call cost
% of the old version.
fprintf('Built CT KD-tree in %.1f ms and vertex-to-face table (%d x %d) in %.1f ms (once).\n\n', ...
    1e3 * treeBuildSeconds, numberOfVertices, facesPerVertex, 1e3 * tableBuildSeconds);
end


%% ===================================================================
% STEP 3 -- TEST A: HAND-MADE TRIANGLE CASES
% ===================================================================

function triangleTest = testTriangleCases()
%TESTTRIANGLECASES Compare closestPointsOnTriangles with geom3d on one triangle.
% The triangle's FIRST corner has an obtuse angle. There is one test point
% in each of the 7 regions around it (inside, beyond each edge, beyond each
% corner), plus a far point that triggers geom3d's vectorized bug. All points
% go through closestPointsOnTriangles in ONE call; geom3d is called once per
% point, with both of its algorithms.
%
% Output: triangleTest - struct with the triangle corners, the test points,
%         and the closest points from the new function and geom3d vectorized
%         (used by the triangle figure).

% A flat triangle with an obtuse angle at A is the hardest simple case:
% points behind A can have their closest point on an edge, not at A. One
% test point is placed in each region around it.
cornerA = [0 0 0];
cornerB = [10 0 0];
cornerC = [-30 5 0];
[testPoints, testLabels] = makeTriangleRegionTestPoints(cornerA, cornerB, cornerC);

% The regular regions are joined by one extra point far out, past A,
% roughly in the direction of C. Its projection onto the line AC falls
% beyond C. This is the case where geom3d's vectorized branch goes wrong
% (point found by a random search for this triangle).
testPoints(end + 1, :) = [-196.7, -10, 2];
testLabels{end + 1}    = 'far past A (bug case)';
numberOfTestPoints = size(testPoints, 1);

% The new function takes one triangle per point, so every test point is
% paired with a copy of the same triangle and all are solved in one call.
[newClosestPoints, newSquaredDistances] = closestPointsOnTriangles(testPoints, ...
    repmat(cornerA, numberOfTestPoints, 1), ...
    repmat(cornerB, numberOfTestPoints, 1), ...
    repmat(cornerC, numberOfTestPoints, 1));
newDistances = sqrt(newSquaredDistances);

% geom3d serves as the independent reference. It is called one point at a
% time with both of its algorithms, because they do not always agree.
triangleVertices = [cornerA; cornerB; cornerC];
geom3dVectorizedDistances = zeros(numberOfTestPoints, 1);
geom3dVectorizedPoints    = zeros(numberOfTestPoints, 3);
geom3dSequentialDistances = zeros(numberOfTestPoints, 1);
for testIndex = 1:numberOfTestPoints
    [geom3dVectorizedDistances(testIndex), geom3dVectorizedPoints(testIndex, :)] = distancePointMesh( ...
        testPoints(testIndex, :), triangleVertices, [1 2 3], 'algorithm', 'vectorized');
    geom3dSequentialDistances(testIndex) = distancePointMesh( ...
        testPoints(testIndex, :), triangleVertices, [1 2 3], 'algorithm', 'sequential');
end

% With all three answers ready, report one row per test point and flag
% where geom3d vectorized disagrees, then explain the cause of that bug.
fprintf('--- Hand-made triangle (obtuse first corner) ---\n');
fprintf('%-26s %12s %12s %12s\n', 'test point', 'new', 'geom3d seq', 'geom3d vec');
for testIndex = 1:numberOfTestPoints
    flag = '';
    if abs(geom3dVectorizedDistances(testIndex) - newDistances(testIndex)) > 1e-9
        flag = '  <-- geom3d vectorized differs';
    end
    fprintf('%-26s %12.6f %12.6f %12.6f%s\n', testLabels{testIndex}, newDistances(testIndex), ...
        geom3dSequentialDistances(testIndex), geom3dVectorizedDistances(testIndex), flag);
end
fprintf('max |new - geom3d sequential| = %.2e mm\n', max(abs(newDistances - geom3dSequentialDistances)));
fprintf(['Note: geom3d''s vectorized region-3 branch tests "c <= e" where Eberly''s method\n' ...
         'needs "c <= -e". It can never be true there, so for a point behind an obtuse\n' ...
         'first corner it projects onto the extended edge line beyond the triangle and\n' ...
         'reports a too-small distance. The sequential algorithm and the new function agree.\n\n']);

% Keep the triangle and both sets of closest points for figure 5.
triangleTest.cornerA                = cornerA;
triangleTest.cornerB                = cornerB;
triangleTest.cornerC                = cornerC;
triangleTest.testPoints             = testPoints;
triangleTest.newClosestPoints       = newClosestPoints;
triangleTest.geom3dVectorizedPoints = geom3dVectorizedPoints;
end


function [testPoints, testLabels] = makeTriangleRegionTestPoints(cornerA, cornerB, cornerC)
%MAKETRIANGLEREGIONTESTPOINTS One test point in each region around a triangle.
% Points are placed in the triangle's plane plus a small height, so the
% closest location is inside the triangle, on one edge, or at one corner.
%
% Inputs:  cornerA, cornerB, cornerC - triangle corners (1-by-3 each).
% Outputs: testPoints - P-by-3 test points (P = 7).
%          testLabels - 1-by-P cell array with a label for each point.

% The centroid and the unit normal are the reference directions for
% placing every point. A small height above the plane makes the test 3D
% without changing which region a point falls in.
corners  = [cornerA; cornerB; cornerC];
centroid = mean(corners, 1);
normal   = cross(cornerB - cornerA, cornerC - cornerA);
normal   = normal / norm(normal);
height   = 2 * normal;

% The centroid is always inside the triangle, so the point just above it
% must have its closest point inside too.
testPoints = centroid + height;
testLabels = {'inside (above centroid)'};

% Beyond each edge: start at the edge midpoint and step outwards, i.e.
% perpendicular to the edge, in the plane, away from the opposite corner.
cornerNames = 'ABC';
for edgeIndex = 1:3
    nextCornerIndex = mod(edgeIndex, 3) + 1;
    edgeStart = corners(edgeIndex, :);
    edgeEnd   = corners(nextCornerIndex, :);
    outward   = cross(edgeEnd - edgeStart, normal);
    outward   = outward / norm(outward);
    testPoints(end + 1, :) = (edgeStart + edgeEnd) / 2 + 3 * outward + height; %#ok<AGROW>
    testLabels{end + 1} = sprintf('beyond edge %s%s', cornerNames(edgeIndex), cornerNames(nextCornerIndex)); %#ok<AGROW>
end

% Beyond each corner: step away from the centroid through the corner, so
% the closest location is at or near that corner.
for cornerIndex = 1:3
    awayFromCentroid = corners(cornerIndex, :) - centroid;
    awayFromCentroid = awayFromCentroid / norm(awayFromCentroid);
    testPoints(end + 1, :) = corners(cornerIndex, :) + 3 * awayFromCentroid + height; %#ok<AGROW>
    testLabels{end + 1} = sprintf('beyond corner %s', cornerNames(cornerIndex)); %#ok<AGROW>
end
end


%% ===================================================================
% STEP 4 -- TEST B: NEW COST VS dev_cost_ICPLike
% ===================================================================

function poseComparison = compareWithOriginalCost(data, config, searchData)
%COMPAREWITHORIGINALCOST Run both cost functions at several poses and compare.
% For every pose it checks: the cost, every point's distance and closest
% point, and whether the CT-tree search found the same K nearest vertices
% as the original search over the moved mesh in ref. If any distance differs
% by more than rounding (1e-9 mm), it recomputes that point with geom3d's
% sequential algorithm to see which version is right.
%
% Inputs:  data, config - from steps 1 and 2.
%          searchData   - from step 2 (per-vertex face cells for the check).
% Output:  poseComparison - struct with both costs per pose and both
%          details structs at the start pose (pose 1).

% K is needed to repeat the original KNN search for the check below.
nearestVertexCount = config.cost.parameters.nearestVertexCount;

% Several poses are compared because a match at one pose could be luck.
% Pose 1 (zero) is the coarse-registration pose. The others combine
% translation (mm) and rotation (rad), up to the optimizer's 10 mm / 10 deg
% search bounds.
posesToCompare = [ ...
    zeros(6, 1), ...
    [2; -1; 0.5; 0; 0; 0], ...
    [0; 0; 0; deg2rad(2); deg2rad(-1); deg2rad(1)], ...
    [-3; 2; 4; deg2rad(-2); deg2rad(1); deg2rad(3)], ...
    [8; -6; 5; deg2rad(6); deg2rad(-5); deg2rad(7)]];
numberOfPoses = size(posesToCompare, 2);

% One cost and one run time per pose and per version are collected, so
% the arrays are made at their final size.
originalCosts   = zeros(numberOfPoses, 1);
newCosts        = zeros(numberOfPoses, 1);
originalSeconds = zeros(numberOfPoses, 1);
newSeconds      = zeros(numberOfPoses, 1);

% The table header is printed first so each pose can add its row as soon
% as it is done.
fprintf('--- dev_cost_ICPLike vs cost_ICPLike ---\n');
fprintf('%4s %12s %12s %10s %10s %8s %8s %9s %9s %7s\n', 'pose', 'old cost', 'new cost', ...
    'max|dd|', 'max|dp|', 'd>1e-9', 'KNN diff', 'old [ms]', 'new [ms]', 'speedup');

% Each pose is handled the same way: evaluate, check, report, and
% investigate any difference.
for poseIndex = 1:numberOfPoses
    poseVector = posesToCompare(:, poseIndex);

    % Evaluate both versions at the same pose and time each one.
    timer = tic;
    [originalCosts(poseIndex), originalDetails] = dev_cost_ICPLike(poseVector, data, config);
    originalSeconds(poseIndex) = toc(timer);

    timer = tic;
    [newCosts(poseIndex), newDetails] = cost_ICPLike(poseVector, data, config);
    newSeconds(poseIndex) = toc(timer);

    % The first thing that could differ is the KNN search, because the new
    % version searches in CT instead of ref. The reference search is
    % exactly what dev_cost_ICPLike does, knnsearch over the moved mesh in ref.
    % Count points whose K nearest vertices differ from the CT-tree result.
    referenceNearestVertices = knnsearch(originalDetails.boneMeshRefCandidate.Points, originalDetails.boneSurfacePointsRef, 'K', nearestVertexCount);
    knnDifferentRows = nnz(any(referenceNearestVertices ~= newDetails.nearestVertexIndicesByPoint, 2));

    % Even with the same seeds, the closest points could differ, so the
    % distances and closest points are compared point by point. Anything
    % above 1e-9 mm is more than rounding and is listed.
    distanceDifferences     = abs(newDetails.pointToSurfaceDistancesMm - originalDetails.pointToSurfaceDistancesMm);
    closestPointDifferences = vecnorm(newDetails.closestBonePointsRef - originalDetails.closestBonePointsRef, 2, 2);
    differingPoints         = find(distanceDifferences > 1e-9);

    % Print this pose's row: both costs, the largest differences, the
    % counts from both checks, and the speedup.
    fprintf('%4d %12.6f %12.6f %10.2e %10.2e %8d %8d %9.1f %9.1f %6.1fx\n', poseIndex, ...
        originalCosts(poseIndex), newCosts(poseIndex), max(distanceDifferences), max(closestPointDifferences), ...
        numel(differingPoints), knnDifferentRows, 1e3 * originalSeconds(poseIndex), ...
        1e3 * newSeconds(poseIndex), originalSeconds(poseIndex) / newSeconds(poseIndex));

    % If any distance differs by more than rounding, find out who is right:
    % recompute that point with geom3d's sequential (per-triangle) algorithm
    % on the same candidate faces and report all three values.
    for pointIndex = differingPoints(:).'
        candidateFaces = unique([searchData.attachedFaceCells{referenceNearestVertices(pointIndex, :)}]);
        sequentialDistance = distancePointMesh(originalDetails.boneSurfacePointsRef(pointIndex, :), ...
            originalDetails.boneMeshRefCandidate.Points, ...
            data.boneMeshCT.ConnectivityList(candidateFaces, :), ...
            'algorithm', 'sequential');
        fprintf('      point %d: old %.6f, new %.6f, geom3d sequential %.6f mm\n', pointIndex, ...
            originalDetails.pointToSurfaceDistancesMm(pointIndex), newDetails.pointToSurfaceDistancesMm(pointIndex), sequentialDistance);
    end

    % Keep the start-pose results for the figures and later tests.
    if poseIndex == 1
        poseComparison.originalDetailsAtStart = originalDetails;
        poseComparison.newDetailsAtStart      = newDetails;
    end
end

% The short column names in the table need a legend underneath.
fprintf('max|dd| = largest distance difference (mm), max|dp| = largest closest-point difference (mm),\n');
fprintf('d>1e-9 = points whose distance differs by more than 1e-9 mm, KNN diff = points with different K nearest vertices.\n\n');

% The costs of all poses are kept for the cost bar chart in figure 2.
poseComparison.originalCosts = originalCosts;
poseComparison.newCosts      = newCosts;
end


%% ===================================================================
% STEP 5 -- TEST C: REPEATED-EVALUATION TIMING
% ===================================================================

function repeatedTiming = timeRepeatedEvaluations(data, config, searchData, poseComparison)
%TIMEREPEATEDEVALUATIONS Time both cost functions the way an optimizer uses them.
% An optimizer evaluates many poses on the same data. This uses random
% poses within the search bounds and reports the median time, which ignores
% warm-up noise. It also times the two steps the old version repeats on
% every call but the new version does once (step 2).
%
% Inputs:  data, config   - from steps 1 and 2.
%          searchData     - build times from step 2.
%          poseComparison - start-pose details from test B.
% Output:  repeatedTiming - struct with the old version's median time
%                           (drawn as a reference line in the batch figure).

% These sizes are needed to repeat the old version's per-call work below.
nearestVertexCount   = config.cost.parameters.nearestVertexCount;
boneSurfacePointsRef = vertcat(data.boneSurfaceMeasurements.surfaceCoordinatesXYZRef);
numberOfVertices     = size(data.boneMeshCT.Points, 1);

% Random poses: about 4 mm and 4 deg spread. The fixed seed makes the run
% repeatable.
rng(1);
numberOfTimedPoses = 15;
timedPoses = [4 * randn(3, numberOfTimedPoses); deg2rad(4 * randn(3, numberOfTimedPoses))];

% One time per pose is stored for each version, plus the new version's own
% split into its KNN stage and its closest-point stage.
originalTimes    = zeros(numberOfTimedPoses, 1);
newTimes         = zeros(numberOfTimedPoses, 1);
newKnnTimes      = zeros(numberOfTimedPoses, 1);
newDistanceTimes = zeros(numberOfTimedPoses, 1);

% Both versions are timed at the same pose, one after the other, so they
% see the same conditions. The new version reports its stage times itself.
for poseIndex = 1:numberOfTimedPoses
    timer = tic;
    dev_cost_ICPLike(timedPoses(:, poseIndex), data, config);
    originalTimes(poseIndex) = toc(timer);

    timer = tic;
    [~, timedDetails] = cost_ICPLike(timedPoses(:, poseIndex), data, config);
    newTimes(poseIndex)         = toc(timer);
    newKnnTimes(poseIndex)      = timedDetails.knnRuntimeSeconds;
    newDistanceTimes(poseIndex) = timedDetails.distanceRuntimeSeconds;
end

% To see where the old version loses its time, the two steps it pays on
% EVERY call are timed on their own: knnsearch (which builds a new KD-tree
% inside) and vertexAttachments over all vertices.
startMeshRef = poseComparison.originalDetailsAtStart.boneMeshRefCandidate;
timer = tic;
knnsearch(startMeshRef.Points, boneSurfacePointsRef, 'K', nearestVertexCount);
knnWithTreeBuildSeconds = toc(timer);

timer = tic;
vertexAttachments(startMeshRef, (1:numberOfVertices).');
attachmentsSeconds = toc(timer);

% Report medians, which ignore the slow first (warm-up) calls, and put the
% repeated work next to the one-time build cost from step 2.
fprintf('--- Timing over %d random poses (median) ---\n', numberOfTimedPoses);
fprintf('dev_cost_ICPLike (old) : %7.1f ms per evaluation\n', 1e3 * median(originalTimes));
fprintf('cost_ICPLike     (new) : %7.1f ms per evaluation  (%.1fx faster)\n', 1e3 * median(newTimes), median(originalTimes) / median(newTimes));
fprintf('  of which KNN (CT tree query incl. moving points) : %6.1f ms\n', 1e3 * median(newKnnTimes));
fprintf('  of which batched closest-point stage             : %6.1f ms\n', 1e3 * median(newDistanceTimes));
fprintf('Work the old version repeats on every call:\n');
fprintf('  knnsearch incl. building a new KD-tree : %6.1f ms (tree build alone, done once here: %.1f ms)\n', ...
    1e3 * knnWithTreeBuildSeconds, 1e3 * searchData.treeBuildSeconds);
fprintf('  vertexAttachments over all vertices    : %6.1f ms (table built once here: %.1f ms)\n\n', ...
    1e3 * attachmentsSeconds, 1e3 * searchData.tableBuildSeconds);

% Keep the old version's median time as a reference line for figure 4.
repeatedTiming.originalMedianSeconds = median(originalTimes);
end


%% ===================================================================
% STEP 6 -- TEST D: BATCH SIZE
% ===================================================================

function batchSizeTest = testBatchSizes(data, config, poseComparison)
%TESTBATCHSIZES Time cost_ICPLike for several batch sizes at the start pose.
% The batch size only decides how many points share one array computation.
% Small batches bring back the per-call overhead; one huge batch needs the
% most memory. The cost must be the same for every batch size. The memory
% column counts the four N-by-3 input arrays of the largest batch; the
% temporaries inside the function are a few times that.
%
% Inputs:  data, config   - from steps 1 and 2.
%          poseComparison - start-pose cost and candidate counts from test B.
% Output:  batchSizeTest  - struct with the batch sizes, median times and
%                           input memory (used by the batch figure).

% The sizes range from one point per batch up to all points in a single
% batch. The start-pose cost from test B is the reference every batch
% size must reproduce, and its per-point face counts give the memory use.
numberOfSurfacePoints = size(vertcat(data.boneSurfaceMeasurements.surfaceCoordinatesXYZRef), 1);
batchSizes            = [1 10 50 200 1000 numberOfSurfacePoints];
referenceCost         = poseComparison.newCosts(1);
uniquePairsPerPoint   = poseComparison.newDetailsAtStart.candidateFaceCountByPoint;

% One time and one memory value per batch size, made at their final size.
medianSeconds  = zeros(numel(batchSizes), 1);
inputMegabytes = zeros(numel(batchSizes), 1);

% Print the table header so each batch size can add its row when done.
fprintf('--- Batch size (pose 0, median of 3 runs) ---\n');
fprintf('%10s %12s %14s %12s %14s\n', 'batch', 'time [ms]', 'pairs/batch', 'inputs [MB]', '|cost - ref|');

% For each batch size, only pointBatchSize changes in a copy of the
% config, so any change in time or cost comes from the batch size alone.
for batchIndex = 1:numel(batchSizes)
    batchSize = batchSizes(batchIndex);
    batchConfig = config;
    batchConfig.cost.parameters.pointBatchSize = batchSize;

    % A single run can be disturbed by other work on the computer, so the
    % median of 3 runs at the start pose is used.
    runSeconds = zeros(3, 1);
    for runIndex = 1:3
        timer = tic;
        batchCost = cost_ICPLike(zeros(6, 1), data, batchConfig);
        runSeconds(runIndex) = toc(timer);
    end
    medianSeconds(batchIndex) = median(runSeconds);

    % Largest number of (point, face) pairs in any batch of this size:
    % sum the pair counts over each block of batchSize consecutive points.
    % Each pair needs four N-by-3 double inputs (point + three corners).
    pairsPerBatch     = movsum(uniquePairsPerPoint, [0, batchSize - 1]);
    largestBatchPairs = max(pairsPerBatch(1:batchSize:end));
    inputMegabytes(batchIndex) = largestBatchPairs * 4 * 3 * 8 / 1e6;

    % The last column is the key check: it must be 0 for every batch size.
    fprintf('%10d %12.1f %14d %12.1f %14.2e\n', batchSize, 1e3 * medianSeconds(batchIndex), ...
        largestBatchPairs, inputMegabytes(batchIndex), abs(batchCost - referenceCost));
end

% Keep the sizes, times and memory values for figure 4.
batchSizeTest.batchSizes     = batchSizes;
batchSizeTest.medianSeconds  = medianSeconds;
batchSizeTest.inputMegabytes = inputMegabytes;
end


%% ===================================================================
% STEP 7 -- TEST E: CANDIDATE-FACE LAYOUT
% ===================================================================

function compareCandidateLayouts(details, faceIndicesByVertex, faces)
%COMPARECANDIDATELAYOUTS Time the closest-point step for two pair layouts.
% Each point's K seed vertices touch K*M entries in the padded table, but
% many are the same face. Two ways to feed them to closestPointsOnTriangles:
%   - padded: every entry is a pair, repeats included (simplest);
%   - repeats removed: what cost_ICPLike does.
% Both must give the same minimum distance per point; this prints that
% check, then the pair counts and times of both layouts.
%
% Inputs: details             - cost_ICPLike details at one pose.
%         faceIndicesByVertex - padded vertex-to-face table from step 2.
%         faces               - mesh connectivity (F-by-3).
% Output: none; the results are printed.

% Reuse the points, moved mesh and K seed vertices from one evaluation,
% so both layouts work on exactly the same search problem.
points   = details.boneSurfacePointsRef;
vertices = details.boneMeshRefCandidate.Points;
seeds    = details.nearestVertexIndicesByPoint;
[numberOfPoints, K] = size(seeds);
facesPerVertex = size(faceIndicesByVertex, 2);

% One row of candidate faces per point, sorted so repeats sit side by side
% (the same layout cost_ICPLike builds).
candidateFaceMatrix = reshape(faceIndicesByVertex(seeds.', :).', K * facesPerVertex, numberOfPoints).';
candidateFaceMatrix = sort(candidateFaceMatrix, 2);
candidatesPerPoint  = size(candidateFaceMatrix, 2);

% Layout 1 -- padded: every matrix entry is a pair, repeats included. The
% fixed number of pairs per point lets the minimum be taken with a reshape.
timer = tic;
paddedPointIndex = repelem((1:numberOfPoints).', candidatesPerPoint);
paddedFaceIndex  = reshape(candidateFaceMatrix.', [], 1);
[~, paddedSquared] = closestPointsOnTriangles(points(paddedPointIndex, :), ...
    vertices(faces(paddedFaceIndex, 1), :), ...
    vertices(faces(paddedFaceIndex, 2), :), ...
    vertices(faces(paddedFaceIndex, 3), :));
paddedMinimum = min(reshape(paddedSquared, candidatesPerPoint, numberOfPoints), [], 1).';
paddedSeconds = toc(timer);

% Layout 2 -- repeats removed, as in cost_ICPLike. Since the rows are
% sorted, a face is a repeat when it equals its left neighbour. Removed
% entries are filled with inf afterwards, so they never win the minimum.
timer = tic;
isUnique = [true(numberOfPoints, 1), diff(candidateFaceMatrix, 1, 2) ~= 0];
[pointIndex, columnIndex] = find(isUnique);
faceIndex = candidateFaceMatrix(sub2ind(size(candidateFaceMatrix), pointIndex, columnIndex));
[~, uniqueSquared] = closestPointsOnTriangles(points(pointIndex, :), ...
    vertices(faces(faceIndex, 1), :), ...
    vertices(faces(faceIndex, 2), :), ...
    vertices(faces(faceIndex, 3), :));
squaredMatrix = inf(size(candidateFaceMatrix));
squaredMatrix(isUnique) = uniqueSquared;
uniqueMinimum = min(squaredMatrix, [], 2);
uniqueSeconds = toc(timer);

% Report the equality check first, since a faster layout is only useful if
% it gives the same answer, then the size and time of both layouts.
paddedPairs = numel(paddedFaceIndex);
uniquePairs = numel(faceIndex);
uniquePairsPerPoint = details.candidateFaceCountByPoint;
fprintf('\nLayout check: max |padded - unique| minimum distance = %.2e mm\n', ...
    max(abs(sqrt(paddedMinimum) - sqrt(uniqueMinimum))));
fprintf('\n--- Candidate layout (pose 0, closest-point computation only) ---\n');
fprintf('padded, with repeats : %7d pairs, %6.1f ms\n', paddedPairs, 1e3 * paddedSeconds);
fprintf('repeats removed      : %7d pairs, %6.1f ms  (used by cost_ICPLike)\n', uniquePairs, 1e3 * uniqueSeconds);
fprintf('Candidate faces per point: mean %.1f, min %d, max %d\n\n', ...
    mean(uniquePairsPerPoint), min(uniquePairsPerPoint), max(uniquePairsPerPoint));
end


%% ===================================================================
% STEP 8 -- FIGURES
% ===================================================================

function plotCorrespondenceScene(data, details)
%PLOTCORRESPONDENCESCENE Figure 1: mesh, ultrasound images, measured points and their correspondences.
% Points are coloured by their point-to-surface distance; every 5th point
% also gets a line to its closest mesh point so the matches can be checked.
% Every measured bone surface is shown together with the ultrasound image
% it was extracted from, placed at its tracked pose in ref, so you can check
% that the points lie on the bright bone echo. The images are transparent
% so the points and lines behind them stay visible. The view is zoomed to
% the measured region so the lines are visible.
%
% Inputs: data    - prepared data: the bone name (title), the image planes
%                   and the surface measurements (plane k belongs to
%                   measurement k, aligned during input preparation).
%         details - cost_ICPLike details at the start pose.

% Set up one 3D axes in the ref frame with equal scaling, so distances on
% screen are not distorted.
figureHandle = figure('Name', 'cost_ICPLike: correspondences at the start pose');
axesHandle = axes(figureHandle);
hold(axesHandle, 'on');
grid(axesHandle, 'on');
axis(axesHandle, 'equal');
view(axesHandle, 35, 40);
xlabel(axesHandle, 'X_{ref} (mm)');
ylabel(axesHandle, 'Y_{ref} (mm)');
zlabel(axesHandle, 'Z_{ref} (mm)');

% The candidate bone mesh is drawn half-transparent, so the points behind
% or inside it stay visible.
mesh = details.boneMeshRefCandidate;
patch(axesHandle, 'Faces', mesh.ConnectivityList, 'Vertices', mesh.Points, ...
    'FaceColor', [0.92 0.83 0.74], 'EdgeColor', 'none', 'FaceAlpha', 0.45, 'DisplayName', 'Candidate bone mesh');

% Draw the ultrasound image of every measurement that has surface points.
% Each grey image is turned into an RGB (true-colour) image first. An RGB
% texture does not use the axes colormap, so the images keep their grey
% look while the points below are still coloured by distance.
ultrasoundImageHandle = gobjects(0);
for measurementIndex = 1:numel(data.boneSurfaceMeasurements)
    if isempty(data.boneSurfaceMeasurements(measurementIndex).surfaceCoordinatesXYZRef)
        continue
    end

    plane = data.imagePlanesRef(measurementIndex);
    grayImage = double(plane.image) / 255;
    rgbImage  = repmat(grayImage, 1, 1, 3);

    % Same pixel spacing and axis swap as demo_cost_ICPLike uses for these images.
    pixelSpacing = [plane.W / max(plane.nCols - 1, 1), plane.H / max(plane.nRows - 1, 1)];
    imageHandle = display_image3D(axesHandle, rgbImage, plane.T_image_ref, ...
        'SwapXY', true, ...
        'PixelSpacing', pixelSpacing, ...
        'Tag', 'demo2_ultrasound_image', ...
        'FaceAlpha', 0.35);

    % Give only the first image a legend entry; the rest would repeat it.
    if isempty(ultrasoundImageHandle)
        imageHandle.DisplayName = 'Ultrasound images';
        ultrasoundImageHandle = imageHandle;
    else
        imageHandle.HandleVisibility = 'off';
    end
end

% On top of the mesh come the measured points, coloured by distance so
% badly matched areas stand out, and their closest mesh points.
points  = details.boneSurfacePointsRef;
closest = details.closestBonePointsRef;
scatter3(axesHandle, points(:, 1), points(:, 2), points(:, 3), 12, details.pointToSurfaceDistancesMm, 'filled', ...
    'DisplayName', 'Measured points (colour = distance)');
scatter3(axesHandle, closest(:, 1), closest(:, 2), closest(:, 3), 6, 'k', 'filled', 'DisplayName', 'Closest mesh points');

% Correspondence lines link each point to its match. Only every 5th point
% gets one, to avoid clutter. NaN rows split the single line object into
% separate segments, so one graphics object is enough instead of one per
% point.
shown = 1:5:size(points, 1);
lineX = [points(shown, 1), closest(shown, 1), nan(numel(shown), 1)].';
lineY = [points(shown, 2), closest(shown, 2), nan(numel(shown), 1)].';
lineZ = [points(shown, 3), closest(shown, 3), nan(numel(shown), 1)].';
plot3(axesHandle, lineX(:), lineY(:), lineZ(:), '-', 'Color', [0.85 0.1 0.1], 'DisplayName', 'Correspondence (every 5th)');

% Zoom to the measured points and scale the colours to the distances.
margin = 10;
xlim(axesHandle, [min(points(:, 1)) - margin, max(points(:, 1)) + margin]);
ylim(axesHandle, [min(points(:, 2)) - margin, max(points(:, 2)) + margin]);
zlim(axesHandle, [min(points(:, 3)) - margin, max(points(:, 3)) + margin]);
clim(axesHandle, [0, max(details.pointToSurfaceDistancesMm)]);
colorbarHandle = colorbar(axesHandle);
colorbarHandle.Label.String = 'point-to-surface distance (mm)';

% Finish with a legend, lighting that shows the mesh shape, a title with
% the overall RMSE, and mouse rotation for inspecting the scene.
legend(axesHandle, 'Location', 'best');
camlight(axesHandle, 'headlight');
lighting(axesHandle, 'gouraud');
title(axesHandle, sprintf('%s start pose: RMSE %.3f mm (%d points)', data.boneName, ...
    details.rmsePointToSurfaceDistanceMm, size(points, 1)), 'Interpreter', 'none');
rotate3d(figureHandle, 'on');
end


function plotOldVersusNew(originalDetails, newDetails, originalCosts, newCosts)
%PLOTOLDVERSUSNEW Figure 2: point-by-point and pose-by-pose comparison of both cost functions.
% Shows the results of test B as pictures: if both versions agree, all
% points lie on the diagonal and the paired bars have equal height.
%
% Inputs: originalDetails, newDetails - details of both versions at the start pose.
%         originalCosts, newCosts     - cost of both versions at each compared pose.

% Four views of the same comparison share one figure in a 2-by-2 grid.
figureHandle = figure('Name', 'dev_cost_ICPLike vs cost_ICPLike');
tiledlayout(figureHandle, 2, 2, 'TileSpacing', 'compact');

% Tile 1: every point on the diagonal means identical distances.
nexttile;
hold on;
grid on;
scatter(originalDetails.pointToSurfaceDistancesMm, newDetails.pointToSurfaceDistancesMm, 8, 'filled');
limits = [0, max(originalDetails.pointToSurfaceDistancesMm)];
plot(limits, limits, 'k--');
xlabel('cost\_ICPLike distance (mm)');
ylabel('dev\_cost\_ICPLike2 distance (mm)');
title('Distances at the start pose');
axis equal tight;

% Tile 2: the diagonal hides tiny differences, so their size is shown on a
% log scale (zero differences are shown at 1e-17, since log10(0) is -inf).
nexttile;
grid on;
differences = abs(newDetails.pointToSurfaceDistancesMm - originalDetails.pointToSurfaceDistancesMm);
histogram(log10(max(differences, 1e-17)), 40);
xlabel('log_{10} |distance difference| (mm)');
ylabel('points');
title('Distance differences (rounding level < -9)');

% Tile 3: from single points to whole poses, the cost at each compared pose.
nexttile;
grid on;
bar([originalCosts, newCosts]);
xlabel('pose');
ylabel('RMSE cost (mm)');
legend('cost\_ICPLike', 'dev\_cost\_ICPLike2', 'Location', 'northwest');
title('Cost at each compared pose');

% Tile 4: RMSE per ultrasound image at the start pose, which would reveal
% a difference limited to a few images.
nexttile;
grid on;
bar([originalDetails.rmseDistanceMmByMeasurement, newDetails.rmseDistanceMmByMeasurement]);
xlabel('ultrasound image');
ylabel('RMSE (mm)');
legend('cost\_ICPLike', 'dev\_cost\_ICPLike2', 'Location', 'northwest');
title('Per-image RMSE at the start pose');
end


function plotSinglePointSearch(newDetails, originalDetails, faceIndicesByVertex)
%PLOTSINGLEPOINTSEARCH Figure 3: the whole search for the point with the largest distance.
% Draws its K seed vertices (found in the CT tree, drawn in ref), its
% candidate faces, the chosen face, and both closest points (old and new).
% The worst point is the most likely place for a search error to show.
%
% Inputs: newDetails, originalDetails - details of both versions at the start pose.
%         faceIndicesByVertex         - padded vertex-to-face table from step 2.

% Pick the worst point and collect what the search used for it.
[~, pointIndex] = max(newDetails.pointToSurfaceDistancesMm);
mesh           = newDetails.boneMeshRefCandidate;
point          = newDetails.boneSurfacePointsRef(pointIndex, :);
seeds          = newDetails.nearestVertexIndicesByPoint(pointIndex, :);
candidateFaces = unique(faceIndicesByVertex(seeds, :));
chosenFace     = newDetails.closestFaceIndexByPoint(pointIndex);
newClosest     = newDetails.closestBonePointsRef(pointIndex, :);
oldClosest     = originalDetails.closestBonePointsRef(pointIndex, :);

% Set up a 3D axes in the ref frame with equal scaling, so the distances
% between the point and the faces look right.
figureHandle = figure('Name', 'One point: KNN seeds, candidate faces, closest point');
axesHandle = axes(figureHandle);
hold(axesHandle, 'on');
grid(axesHandle, 'on');
axis(axesHandle, 'equal');
view(axesHandle, 3);
xlabel(axesHandle, 'X_{ref} (mm)');
ylabel(axesHandle, 'Y_{ref} (mm)');
zlabel(axesHandle, 'Z_{ref} (mm)');

% Only the candidate faces are drawn, not the whole mesh, so the search
% area is clear. The chosen face is drawn on top in a stronger colour.
patch(axesHandle, 'Faces', mesh.ConnectivityList(candidateFaces, :), 'Vertices', mesh.Points, ...
    'FaceColor', [0.6 0.8 1.0], 'EdgeColor', [0.3 0.3 0.3], 'FaceAlpha', 0.6, 'DisplayName', 'Candidate faces');
patch(axesHandle, 'Faces', mesh.ConnectivityList(chosenFace, :), 'Vertices', mesh.Points, ...
    'FaceColor', [1.0 0.6 0.1], 'EdgeColor', 'k', 'DisplayName', 'Chosen face');

% The seed vertices show where the candidate faces came from, next to the
% measured point they were found for.
scatter3(axesHandle, mesh.Points(seeds, 1), mesh.Points(seeds, 2), mesh.Points(seeds, 3), 30, 'b', 'filled', ...
    'DisplayName', sprintf('K = %d nearest vertices (CT tree)', numel(seeds)));
scatter3(axesHandle, point(1), point(2), point(3), 60, 'r', 'filled', 'DisplayName', 'Measured point');

% The closest points from both versions use different markers, so it is
% easy to see that they coincide. A line marks the measured distance.
scatter3(axesHandle, newClosest(1), newClosest(2), newClosest(3), 80, 'k', 'x', 'LineWidth', 2, 'DisplayName', 'Closest point (new)');
scatter3(axesHandle, oldClosest(1), oldClosest(2), oldClosest(3), 80, 'm', 'o', 'LineWidth', 1.5, 'DisplayName', 'Closest point (cost\_ICPLike)');
plot3(axesHandle, [point(1) newClosest(1)], [point(2) newClosest(2)], [point(3) newClosest(3)], 'r-', 'HandleVisibility', 'off');

% The title repeats both distances and the candidate count, so the figure
% can be read without the console output.
legend(axesHandle, 'Location', 'best');
title(axesHandle, sprintf('Point %d: new %.4f mm, old %.4f mm, %d candidate faces', pointIndex, ...
    newDetails.pointToSurfaceDistancesMm(pointIndex), originalDetails.pointToSurfaceDistancesMm(pointIndex), numel(candidateFaces)));
rotate3d(figureHandle, 'on');
end


function plotBatchSizeEffect(batchSizes, medianSeconds, inputMegabytes, originalSeconds)
%PLOTBATCHSIZEEFFECT Figure 4: evaluation time and batch input memory versus batch size.
% Shows the trade-off from test D side by side: larger batches are faster
% up to a point, but need more memory.
%
% Inputs: batchSizes      - tested points per batch.
%         medianSeconds   - median time per evaluation for each batch size.
%         inputMegabytes  - input memory of the largest batch for each size.
%         originalSeconds - median time of dev_cost_ICPLike (reference line).

% Time and memory get one tile each, next to each other.
figureHandle = figure('Name', 'cost_ICPLike: batch size');
tiledlayout(figureHandle, 1, 2, 'TileSpacing', 'compact');

% Left: time per evaluation, with the old version as a reference line.
% The batch sizes span several orders of magnitude, so the x-axis is log.
nexttile;
hold on;
grid on;
semilogx(batchSizes, 1e3 * medianSeconds, 'o-', 'LineWidth', 1.5, 'DisplayName', 'dev\_cost\_ICPLike2');
yline(1e3 * originalSeconds, 'r--', 'cost\_ICPLike', 'DisplayName', 'cost\_ICPLike');
set(gca, 'XScale', 'log');
xlabel('points per batch');
ylabel('time per evaluation (ms)');
title('Evaluation time');

% Right: memory of the input arrays of the largest batch.
nexttile;
grid on;
semilogx(batchSizes, inputMegabytes, 's-', 'LineWidth', 1.5);
xlabel('points per batch');
ylabel('MB');
title('Input arrays of the largest batch');
end


function plotTriangleTestCases(cornerA, cornerB, cornerC, testPoints, newClosestPoints, geom3dVectorizedPoints)
%PLOTTRIANGLETESTCASES Figure 5: hand-made test points with the closest points from both methods.
% Makes the geom3d vectorized bug from test A visible: for the bug case its
% marker lands outside the triangle, away from the correct closest point.
%
% Inputs: cornerA, cornerB, cornerC - triangle corners (1-by-3 each).
%         testPoints                - P-by-3 test points.
%         newClosestPoints          - P-by-3 closest points from closestPointsOnTriangles.
%         geom3dVectorizedPoints    - P-by-3 closest points from geom3d vectorized.

% The triangle lies in the z = 0 plane, so a top view shows everything.
figureHandle = figure('Name', 'Hand-made triangle test cases');
axesHandle = axes(figureHandle);
hold(axesHandle, 'on');
grid(axesHandle, 'on');
axis(axesHandle, 'equal');
view(axesHandle, 2);
xlabel(axesHandle, 'x');
ylabel(axesHandle, 'y');

% The triangle with its corner names, so the labels in the console table
% can be matched to the picture.
patch(axesHandle, 'Faces', [1 2 3], 'Vertices', [cornerA; cornerB; cornerC], 'FaceColor', [0.85 0.85 0.85], ...
    'DisplayName', 'Triangle (obtuse corner A first)');
text(axesHandle, cornerA(1), cornerA(2), '  A');
text(axesHandle, cornerB(1), cornerB(2), '  B');
text(axesHandle, cornerC(1), cornerC(2), '  C');

% Test points and the closest points found by each method.
scatter(axesHandle, testPoints(:, 1), testPoints(:, 2), 40, 'b', 'filled', 'DisplayName', 'Test points');
scatter(axesHandle, newClosestPoints(:, 1), newClosestPoints(:, 2), 70, 'k', 'x', 'LineWidth', 2, 'DisplayName', 'closestPointsOnTriangles');
scatter(axesHandle, geom3dVectorizedPoints(:, 1), geom3dVectorizedPoints(:, 2), 70, 'm', 'o', 'LineWidth', 1.5, 'DisplayName', 'geom3d vectorized');

% Dotted line from each test point to its (correct) closest point.
for testIndex = 1:size(testPoints, 1)
    plot(axesHandle, [testPoints(testIndex, 1) newClosestPoints(testIndex, 1)], ...
        [testPoints(testIndex, 2) newClosestPoints(testIndex, 2)], 'k:', 'HandleVisibility', 'off');
end

% A legend and title finish the figure.
legend(axesHandle, 'Location', 'best');
title(axesHandle, 'Closest points per test case (top view)');
end
