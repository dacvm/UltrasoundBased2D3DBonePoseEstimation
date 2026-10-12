% DEMO_COST_ICPLIKE2 Validate and time dev_cost_ICPLike2 against cost_ICPLike.
% This script:
%   1. loads optimization_setup.mat and turns its config into an ICPLike config;
%   2. builds the pose-independent search data ONCE (CT KD-tree and the
%      vertex-to-face table) and stores it in data.extra.icpLike;
%   3. checks the batched point-to-triangle function on hand-made cases;
%   4. compares the new cost with cost_ICPLike at several poses;
%   5. times repeated evaluations, batch sizes and data layouts;
%   6. draws figures to inspect the correspondences and any differences.
clear; clc; close all;

developmentFolder = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(developmentFolder));
addpath(genpath(fullfile(projectRoot, 'functions')));
addpath(developmentFolder);

%% 1. LOAD THE PREPARED OPTIMIZATION SETUP

% The fixture holds data, config and initialCost. Its config was made for
% the P-IMLOP model, so replace the cost block with ICPLike settings. Both
% cost functions read nearestVertexCount; pointBatchSize is only read by
% the new one.
setup  = load(fullfile(developmentFolder, 'optimization_setup.mat'), 'data', 'config');
data   = setup.data;
config = setup.config;

config.cost.model = 'ICPLike';
config.cost.parameters = struct('nearestVertexCount', 20, 'pointBatchSize', 200);
data.config = config;

boneMeshCT           = data.boneMeshCT;
numberOfVertices     = size(boneMeshCT.Points, 1);
numberOfFaces        = size(boneMeshCT.ConnectivityList, 1);
boneSurfacePointsRef = vertcat(data.boneSurfaceMeasurements.surfaceCoordinatesXYZRef);
nearestVertexCount   = config.cost.parameters.nearestVertexCount;

fprintf('=== dev_cost_ICPLike2 demonstration ===\n');
fprintf('Bone %s: %d vertices, %d faces, %d measured points in %d images, K = %d\n\n', ...
    data.boneName, numberOfVertices, numberOfFaces, size(boneSurfacePointsRef, 1), ...
    numel(data.boneSurfaceMeasurements), nearestVertexCount);

%% 2. BUILD THE POSE-INDEPENDENT SEARCH DATA ONCE

% The batched triangle function divides by each triangle's (doubled) area
% squared, so it assumes no zero-area faces. Check that on this mesh.
faceCornerA = boneMeshCT.Points(boneMeshCT.ConnectivityList(:, 1), :);
faceCornerB = boneMeshCT.Points(boneMeshCT.ConnectivityList(:, 2), :);
faceCornerC = boneMeshCT.Points(boneMeshCT.ConnectivityList(:, 3), :);
faceAreasMm2 = 0.5 * vecnorm(cross(faceCornerB - faceCornerA, faceCornerC - faceCornerA, 2), 2, 2);
fprintf('Smallest face area: %.4f mm^2 (zero-area faces: %d)\n', min(faceAreasMm2), nnz(faceAreasMm2 == 0));

% KD-tree over the CT-frame vertices. The CT mesh never changes during the
% optimization, so this tree is valid for every candidate pose; the cost
% function moves the measured points into CT instead.
treeTimer = tic;
vertexTreeCT = KDTreeSearcher(boneMeshCT.Points);
treeBuildSeconds = toc(treeTimer);

% Vertex-to-face table. vertexAttachments returns a cell per vertex with a
% different number of faces each. A plain matrix is easier to index for
% all points at once, so pad every row to the same width by repeating the
% vertex's first face. The repeats are removed again inside the cost
% function, so they never change the result.
tableTimer = tic;
attachedFaceCells = vertexAttachments(boneMeshCT, (1:numberOfVertices).');
facesPerVertex    = max(cellfun(@numel, attachedFaceCells));
faceIndicesByVertex = zeros(numberOfVertices, facesPerVertex);
for vertexIndex = 1:numberOfVertices
    attachedFaces = attachedFaceCells{vertexIndex};
    faceIndicesByVertex(vertexIndex, :) = [attachedFaces, repmat(attachedFaces(1), 1, facesPerVertex - numel(attachedFaces))];
end
tableBuildSeconds = toc(tableTimer);

data.extra.icpLike.vertexTreeCT        = vertexTreeCT;
data.extra.icpLike.faceIndicesByVertex = faceIndicesByVertex;

fprintf('Built CT KD-tree in %.1f ms and vertex-to-face table (%d x %d) in %.1f ms (once).\n\n', ...
    1e3 * treeBuildSeconds, numberOfVertices, facesPerVertex, 1e3 * tableBuildSeconds);

%% 3. CHECK THE BATCHED TRIANGLE FUNCTION ON HAND-MADE CASES

% One triangle whose FIRST corner has an obtuse angle, and one test point in
% each of the 7 regions around it (inside, beyond each edge, beyond each
% corner), plus a far point behind the obtuse corner. All points go through
% closestPointsOnTriangles in ONE call; geom3d is called once per point.
triangleA = [0 0 0];
triangleB = [10 0 0];
triangleC = [-30 5 0];
[testPoints, testLabels] = makeTriangleRegionTestPoints(triangleA, triangleB, triangleC);

% Extra point far out, past A, roughly in the direction of C. Its projection
% onto the line AC falls beyond C. This is the case where geom3d's vectorized
% branch goes wrong (point found by a random search for this triangle).
testPoints(end + 1, :) = [-196.7, -10, 2];
testLabels{end + 1}    = 'far past A (bug case)';
numberOfTestPoints = size(testPoints, 1);

[newClosestPoints, newSquaredDistances] = closestPointsOnTriangles(testPoints, ...
    repmat(triangleA, numberOfTestPoints, 1), repmat(triangleB, numberOfTestPoints, 1), repmat(triangleC, numberOfTestPoints, 1));
newDistances = sqrt(newSquaredDistances);

geom3dVectorizedDistances = zeros(numberOfTestPoints, 1);
geom3dVectorizedPoints    = zeros(numberOfTestPoints, 3);
geom3dSequentialDistances = zeros(numberOfTestPoints, 1);
for testIndex = 1:numberOfTestPoints
    [geom3dVectorizedDistances(testIndex), geom3dVectorizedPoints(testIndex, :)] = distancePointMesh( ...
        testPoints(testIndex, :), [triangleA; triangleB; triangleC], [1 2 3], 'algorithm', 'vectorized');
    geom3dSequentialDistances(testIndex) = distancePointMesh( ...
        testPoints(testIndex, :), [triangleA; triangleB; triangleC], [1 2 3], 'algorithm', 'sequential');
end

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

%% 4. COMPARE WITH cost_ICPLike AT SEVERAL POSES

% Zero = the coarse-registration pose. The others combine translation (mm)
% and rotation (rad), up to the optimizer's 10 mm / 10 deg search bounds.
posesToCompare = [ ...
    zeros(6, 1), ...
    [2; -1; 0.5; 0; 0; 0], ...
    [0; 0; 0; deg2rad(2); deg2rad(-1); deg2rad(1)], ...
    [-3; 2; 4; deg2rad(-2); deg2rad(1); deg2rad(3)], ...
    [8; -6; 5; deg2rad(6); deg2rad(-5); deg2rad(7)]];
numberOfPoses = size(posesToCompare, 2);

originalCosts = zeros(numberOfPoses, 1);
newCosts      = zeros(numberOfPoses, 1);
originalSeconds = zeros(numberOfPoses, 1);
newSeconds      = zeros(numberOfPoses, 1);

fprintf('--- cost_ICPLike vs dev_cost_ICPLike2 ---\n');
fprintf('%4s %12s %12s %10s %10s %8s %8s %9s %9s %7s\n', 'pose', 'old cost', 'new cost', ...
    'max|dd|', 'max|dp|', 'd>1e-9', 'KNN diff', 'old [ms]', 'new [ms]', 'speedup');

for poseIndex = 1:numberOfPoses
    poseVector = posesToCompare(:, poseIndex);

    timer = tic;
    [originalCosts(poseIndex), originalDetails] = cost_ICPLike(poseVector, data, config);
    originalSeconds(poseIndex) = toc(timer);

    timer = tic;
    [newCosts(poseIndex), newDetails] = dev_cost_ICPLike2(poseVector, data, config);
    newSeconds(poseIndex) = toc(timer);

    % KNN check: the reference search is exactly what cost_ICPLike does,
    % knnsearch over the moved mesh in ref. Compare the index matrices.
    referenceNearestVertices = knnsearch(originalDetails.boneMeshRefCandidate.Points, ...
        originalDetails.boneSurfacePointsRef, 'K', nearestVertexCount);
    knnDifferentRows = nnz(any(referenceNearestVertices ~= newDetails.nearestVertexIndicesByPoint, 2));

    distanceDifferences    = abs(newDetails.pointToSurfaceDistancesMm - originalDetails.pointToSurfaceDistancesMm);
    closestPointDifferences = vecnorm(newDetails.closestBonePointsRef - originalDetails.closestBonePointsRef, 2, 2);
    differingPoints = find(distanceDifferences > 1e-9);

    fprintf('%4d %12.6f %12.6f %10.2e %10.2e %8d %8d %9.1f %9.1f %6.1fx\n', poseIndex, ...
        originalCosts(poseIndex), newCosts(poseIndex), max(distanceDifferences), max(closestPointDifferences), ...
        numel(differingPoints), knnDifferentRows, 1e3 * originalSeconds(poseIndex), ...
        1e3 * newSeconds(poseIndex), originalSeconds(poseIndex) / newSeconds(poseIndex));

    % If any distance differs by more than rounding, find out who is right:
    % recompute that point with geom3d's sequential (per-triangle) algorithm
    % on the same candidate faces and report all three values.
    for pointIndex = differingPoints(:).'
        candidateFaces = unique([attachedFaceCells{referenceNearestVertices(pointIndex, :)}]);
        sequentialDistance = distancePointMesh(originalDetails.boneSurfacePointsRef(pointIndex, :), ...
            originalDetails.boneMeshRefCandidate.Points, boneMeshCT.ConnectivityList(candidateFaces, :), ...
            'algorithm', 'sequential');
        fprintf('      point %d: old %.6f, new %.6f, geom3d sequential %.6f mm\n', pointIndex, ...
            originalDetails.pointToSurfaceDistancesMm(pointIndex), newDetails.pointToSurfaceDistancesMm(pointIndex), sequentialDistance);
    end

    % Keep the zero-pose results for the figures.
    if poseIndex == 1
        originalDetailsAtStart = originalDetails;
        newDetailsAtStart      = newDetails;
    end
end
fprintf('max|dd| = largest distance difference (mm), max|dp| = largest closest-point difference (mm),\n');
fprintf('d>1e-9 = points whose distance differs by more than 1e-9 mm, KNN diff = points with different K nearest vertices.\n\n');

%% 5. TIME REPEATED EVALUATIONS AND THE WORK THAT IS NO LONGER REPEATED

% Typical optimizer use: many evaluations on the same data. Use random poses
% within the search bounds and the median time, which ignores warm-up noise.
rng(1);
numberOfTimedPoses = 15;
timedPoses = [4 * randn(3, numberOfTimedPoses); deg2rad(4 * randn(3, numberOfTimedPoses))];
originalTimes = zeros(numberOfTimedPoses, 1);
newTimes      = zeros(numberOfTimedPoses, 1);
newKnnTimes   = zeros(numberOfTimedPoses, 1);
newDistanceTimes = zeros(numberOfTimedPoses, 1);
for poseIndex = 1:numberOfTimedPoses
    timer = tic;
    cost_ICPLike(timedPoses(:, poseIndex), data, config);
    originalTimes(poseIndex) = toc(timer);

    timer = tic;
    [~, timedDetails] = dev_cost_ICPLike2(timedPoses(:, poseIndex), data, config);
    newTimes(poseIndex)         = toc(timer);
    newKnnTimes(poseIndex)      = timedDetails.knnRuntimeSeconds;
    newDistanceTimes(poseIndex) = timedDetails.distanceRuntimeSeconds;
end

% What the old version pays on EVERY call and the new one pays once.
movedVerticesRef = originalDetailsAtStart.boneMeshRefCandidate.Points;
timer = tic;
knnsearch(movedVerticesRef, boneSurfacePointsRef, 'K', nearestVertexCount);
knnWithTreeBuildSeconds = toc(timer);
timer = tic;
vertexAttachments(originalDetailsAtStart.boneMeshRefCandidate, (1:numberOfVertices).');
attachmentsSeconds = toc(timer);

fprintf('--- Timing over %d random poses (median) ---\n', numberOfTimedPoses);
fprintf('cost_ICPLike        : %7.1f ms per evaluation\n', 1e3 * median(originalTimes));
fprintf('dev_cost_ICPLike2   : %7.1f ms per evaluation  (%.1fx faster)\n', 1e3 * median(newTimes), median(originalTimes) / median(newTimes));
fprintf('  of which KNN (CT tree query incl. moving points) : %6.1f ms\n', 1e3 * median(newKnnTimes));
fprintf('  of which batched closest-point stage             : %6.1f ms\n', 1e3 * median(newDistanceTimes));
fprintf('Work the old version repeats on every call:\n');
fprintf('  knnsearch incl. building a new KD-tree : %6.1f ms (tree build alone, done once here: %.1f ms)\n', ...
    1e3 * knnWithTreeBuildSeconds, 1e3 * treeBuildSeconds);
fprintf('  vertexAttachments over all vertices    : %6.1f ms (table built once here: %.1f ms)\n\n', ...
    1e3 * attachmentsSeconds, 1e3 * tableBuildSeconds);

%% 6. EFFECT OF BATCH SIZE AND DATA LAYOUT

% The batch size only decides how many points share one array computation.
% Small batches bring back the per-call overhead; one huge batch needs the
% most memory. The memory column counts the four N-by-3 input arrays of the
% largest batch; the temporaries inside the function are a few times that.
numberOfSurfacePoints = size(boneSurfacePointsRef, 1);
batchSizesToTry = [1 10 50 200 1000 numberOfSurfacePoints];
batchMedianSeconds = zeros(numel(batchSizesToTry), 1);
batchInputMegabytes = zeros(numel(batchSizesToTry), 1);
uniquePairsPerPoint = newDetailsAtStart.candidateFaceCountByPoint;

fprintf('--- Batch size (pose 0, median of 3 runs) ---\n');
fprintf('%10s %12s %14s %12s %14s\n', 'batch', 'time [ms]', 'pairs/batch', 'inputs [MB]', '|cost - ref|');
for batchIndex = 1:numel(batchSizesToTry)
    batchConfig = config;
    batchConfig.cost.parameters.pointBatchSize = batchSizesToTry(batchIndex);

    runSeconds = zeros(3, 1);
    for runIndex = 1:3
        timer = tic;
        batchCost = dev_cost_ICPLike2(zeros(6, 1), data, batchConfig);
        runSeconds(runIndex) = toc(timer);
    end
    batchMedianSeconds(batchIndex) = median(runSeconds);

    % Largest number of pairs in any batch of this size.
    pairsPerBatch = movsum(uniquePairsPerPoint, [0, batchSizesToTry(batchIndex) - 1]);
    largestBatchPairs = max(pairsPerBatch(1:batchSizesToTry(batchIndex):end));
    batchInputMegabytes(batchIndex) = largestBatchPairs * 4 * 3 * 8 / 1e6;

    fprintf('%10d %12.1f %14d %12.1f %14.2e\n', batchSizesToTry(batchIndex), 1e3 * batchMedianSeconds(batchIndex), ...
        largestBatchPairs, batchInputMegabytes(batchIndex), abs(batchCost - newCosts(1)));
end

% Data layout: each point's K seeds touch K*M faces in the padded table,
% but many are the same face. Computing every padded pair (duplicates
% included) is the simplest layout; removing repeats first is what
% dev_cost_ICPLike2 does. Time the closest-point computation for both.
[paddedSeconds, uniqueSeconds, paddedPairs, uniquePairs] = compareCandidateLayouts( ...
    newDetailsAtStart, faceIndicesByVertex, boneMeshCT.ConnectivityList);
fprintf('\n--- Candidate layout (pose 0, closest-point computation only) ---\n');
fprintf('padded, with repeats : %7d pairs, %6.1f ms\n', paddedPairs, 1e3 * paddedSeconds);
fprintf('repeats removed      : %7d pairs, %6.1f ms  (used by dev_cost_ICPLike2)\n', uniquePairs, 1e3 * uniqueSeconds);
fprintf('Candidate faces per point: mean %.1f, min %d, max %d\n\n', ...
    mean(uniquePairsPerPoint), min(uniquePairsPerPoint), max(uniquePairsPerPoint));

%% 7. FIGURES

plotCorrespondenceScene(data, newDetailsAtStart);
plotOldVersusNew(originalDetailsAtStart, newDetailsAtStart, originalCosts, newCosts);
plotSinglePointSearch(newDetailsAtStart, originalDetailsAtStart, faceIndicesByVertex);
plotBatchSizeEffect(batchSizesToTry, batchMedianSeconds, batchInputMegabytes, median(originalTimes));
plotTriangleTestCases(triangleA, triangleB, triangleC, testPoints, newClosestPoints, geom3dVectorizedPoints);


%% ========================= LOCAL FUNCTIONS =========================

function [testPoints, testLabels] = makeTriangleRegionTestPoints(cornerA, cornerB, cornerC)
%MAKETRIANGLEREGIONTESTPOINTS One test point in each region around a triangle.
% Points are placed in the triangle's plane plus a small height, so the
% closest location is inside the triangle, on one edge, or at one corner.
% Outputs: testPoints (P-by-3) and a matching cell array of labels.

corners  = [cornerA; cornerB; cornerC];
centroid = mean(corners, 1);
normal   = cross(cornerB - cornerA, cornerC - cornerA);
normal   = normal / norm(normal);
height   = 2 * normal;

% Inside: just above the centroid.
testPoints = centroid + height;
testLabels = {'inside (above centroid)'};

% Beyond each edge: start at the edge midpoint and step outwards, i.e.
% perpendicular to the edge, in the plane, away from the opposite corner.
cornerNames = 'ABC';
for edgeIndex = 1:3
    edgeStart = corners(edgeIndex, :);
    edgeEnd   = corners(mod(edgeIndex, 3) + 1, :);
    outward   = cross(edgeEnd - edgeStart, normal);
    outward   = outward / norm(outward);
    testPoints(end + 1, :) = (edgeStart + edgeEnd) / 2 + 3 * outward + height; %#ok<AGROW>
    testLabels{end + 1} = sprintf('beyond edge %s%s', cornerNames(edgeIndex), cornerNames(mod(edgeIndex, 3) + 1)); %#ok<AGROW>
end

% Beyond each corner: step away from the centroid through the corner.
for cornerIndex = 1:3
    awayFromCentroid = corners(cornerIndex, :) - centroid;
    awayFromCentroid = awayFromCentroid / norm(awayFromCentroid);
    testPoints(end + 1, :) = corners(cornerIndex, :) + 3 * awayFromCentroid + height; %#ok<AGROW>
    testLabels{end + 1} = sprintf('beyond corner %s', cornerNames(cornerIndex)); %#ok<AGROW>
end
end


function [paddedSeconds, uniqueSeconds, paddedPairs, uniquePairs] = compareCandidateLayouts(details, faceIndicesByVertex, faces)
%COMPARECANDIDATELAYOUTS Time the closest-point step for two pair layouts.
% details comes from dev_cost_ICPLike2 at one pose; faceIndicesByVertex and
% faces are the padded vertex-to-face table and the mesh connectivity.
% Both layouts must give the same minimum distance per point.

points   = details.boneSurfacePointsRef;
vertices = details.boneMeshRefCandidate.Points;
seeds    = details.nearestVertexIndicesByPoint;
[numberOfPoints, K] = size(seeds);
facesPerVertex = size(faceIndicesByVertex, 2);

candidateFaceMatrix = reshape(faceIndicesByVertex(seeds.', :).', K * facesPerVertex, numberOfPoints).';
candidateFaceMatrix = sort(candidateFaceMatrix, 2);

% Padded: every entry is a pair, repeats included.
timer = tic;
paddedPointIndex = repelem((1:numberOfPoints).', size(candidateFaceMatrix, 2));
paddedFaceIndex  = reshape(candidateFaceMatrix.', [], 1);
[~, paddedSquared] = closestPointsOnTriangles(points(paddedPointIndex, :), ...
    vertices(faces(paddedFaceIndex, 1), :), vertices(faces(paddedFaceIndex, 2), :), vertices(faces(paddedFaceIndex, 3), :));
paddedMinimum = min(reshape(paddedSquared, size(candidateFaceMatrix, 2), numberOfPoints), [], 1).';
paddedSeconds = toc(timer);

% Repeats removed, as in dev_cost_ICPLike2.
timer = tic;
isUnique = [true(numberOfPoints, 1), diff(candidateFaceMatrix, 1, 2) ~= 0];
[pointIndex, columnIndex] = find(isUnique);
faceIndex = candidateFaceMatrix(sub2ind(size(candidateFaceMatrix), pointIndex, columnIndex));
[~, uniqueSquared] = closestPointsOnTriangles(points(pointIndex, :), ...
    vertices(faces(faceIndex, 1), :), vertices(faces(faceIndex, 2), :), vertices(faces(faceIndex, 3), :));
squaredMatrix = inf(size(candidateFaceMatrix));
squaredMatrix(isUnique) = uniqueSquared;
uniqueMinimum = min(squaredMatrix, [], 2);
uniqueSeconds = toc(timer);

paddedPairs = numel(paddedFaceIndex);
uniquePairs = numel(faceIndex);
fprintf('\nLayout check: max |padded - unique| minimum distance = %.2e mm\n', ...
    max(abs(sqrt(paddedMinimum) - sqrt(uniqueMinimum))));
end


function plotCorrespondenceScene(data, details)
%PLOTCORRESPONDENCESCENE Mesh, ultrasound images, measured points and their correspondences.
% Points are coloured by their point-to-surface distance; every 5th point
% also gets a line to its closest mesh point so the matches can be checked.

figureHandle = figure('Name', 'dev_cost_ICPLike2: correspondences at the start pose');
axesHandle = axes(figureHandle);
hold(axesHandle, 'on'); grid(axesHandle, 'on'); axis(axesHandle, 'equal'); view(axesHandle, 35, 40);
xlabel(axesHandle, 'X_{ref} (mm)'); ylabel(axesHandle, 'Y_{ref} (mm)'); zlabel(axesHandle, 'Z_{ref} (mm)');

mesh = details.boneMeshRefCandidate;
patch(axesHandle, 'Faces', mesh.ConnectivityList, 'Vertices', mesh.Points, ...
    'FaceColor', [0.92 0.83 0.74], 'EdgeColor', 'none', 'FaceAlpha', 0.45, 'DisplayName', 'Candidate bone mesh');

% The ultrasound images are left out on purpose: they would share the
% axes' colour scale with the distance colouring (demo_cost_ICPLike shows
% them). The view is zoomed to the measured region so the lines are visible.
points  = details.boneSurfacePointsRef;
closest = details.closestBonePointsRef;
scatter3(axesHandle, points(:, 1), points(:, 2), points(:, 3), 12, details.pointToSurfaceDistancesMm, 'filled', ...
    'DisplayName', 'Measured points (colour = distance)');
scatter3(axesHandle, closest(:, 1), closest(:, 2), closest(:, 3), 6, 'k', 'filled', 'DisplayName', 'Closest mesh points');

shown = 1:5:size(points, 1);
lineX = [points(shown, 1), closest(shown, 1), nan(numel(shown), 1)].';
lineY = [points(shown, 2), closest(shown, 2), nan(numel(shown), 1)].';
lineZ = [points(shown, 3), closest(shown, 3), nan(numel(shown), 1)].';
plot3(axesHandle, lineX(:), lineY(:), lineZ(:), '-', 'Color', [0.85 0.1 0.1], 'DisplayName', 'Correspondence (every 5th)');

margin = 10;
xlim(axesHandle, [min(points(:, 1)) - margin, max(points(:, 1)) + margin]);
ylim(axesHandle, [min(points(:, 2)) - margin, max(points(:, 2)) + margin]);
zlim(axesHandle, [min(points(:, 3)) - margin, max(points(:, 3)) + margin]);
clim(axesHandle, [0, max(details.pointToSurfaceDistancesMm)]);
colorbarHandle = colorbar(axesHandle);
colorbarHandle.Label.String = 'point-to-surface distance (mm)';
legend(axesHandle, 'Location', 'best');
camlight(axesHandle, 'headlight'); lighting(axesHandle, 'gouraud');
title(axesHandle, sprintf('%s start pose: RMSE %.3f mm (%d points)', data.boneName, ...
    details.rmsePointToSurfaceDistanceMm, size(points, 1)), 'Interpreter', 'none');
rotate3d(figureHandle, 'on');
end


function plotOldVersusNew(originalDetails, newDetails, originalCosts, newCosts)
%PLOTOLDVERSUSNEW Point-by-point and pose-by-pose comparison of both cost functions.

figureHandle = figure('Name', 'cost_ICPLike vs dev_cost_ICPLike2');
tiledlayout(figureHandle, 2, 2, 'TileSpacing', 'compact');

% Every point on the diagonal means identical distances.
nexttile; hold on; grid on;
scatter(originalDetails.pointToSurfaceDistancesMm, newDetails.pointToSurfaceDistancesMm, 8, 'filled');
limits = [0, max(originalDetails.pointToSurfaceDistancesMm)];
plot(limits, limits, 'k--');
xlabel('cost\_ICPLike distance (mm)'); ylabel('dev\_cost\_ICPLike2 distance (mm)');
title('Distances at the start pose'); axis equal tight;

% Size of the differences on a log scale (zero differences shown at 1e-17).
nexttile; grid on;
differences = abs(newDetails.pointToSurfaceDistancesMm - originalDetails.pointToSurfaceDistancesMm);
histogram(log10(max(differences, 1e-17)), 40);
xlabel('log_{10} |distance difference| (mm)'); ylabel('points');
title('Distance differences (rounding level < -9)');

nexttile; grid on;
bar([originalCosts, newCosts]);
xlabel('pose'); ylabel('RMSE cost (mm)'); legend('cost\_ICPLike', 'dev\_cost\_ICPLike2', 'Location', 'northwest');
title('Cost at each compared pose');

nexttile; grid on;
bar([originalDetails.rmseDistanceMmByMeasurement, newDetails.rmseDistanceMmByMeasurement]);
xlabel('ultrasound image'); ylabel('RMSE (mm)'); legend('cost\_ICPLike', 'dev\_cost\_ICPLike2', 'Location', 'northwest');
title('Per-image RMSE at the start pose');
end


function plotSinglePointSearch(newDetails, originalDetails, faceIndicesByVertex)
%PLOTSINGLEPOINTSEARCH Show the whole search for the point with the largest distance.
% Draws its K seed vertices (found in the CT tree, drawn in ref), its
% candidate faces, the chosen face, and both closest points (old and new).

[~, pointIndex] = max(newDetails.pointToSurfaceDistancesMm);
mesh  = newDetails.boneMeshRefCandidate;
point = newDetails.boneSurfacePointsRef(pointIndex, :);
seeds = newDetails.nearestVertexIndicesByPoint(pointIndex, :);
candidateFaces = unique(faceIndicesByVertex(seeds, :));
chosenFace = newDetails.closestFaceIndexByPoint(pointIndex);

figureHandle = figure('Name', 'One point: KNN seeds, candidate faces, closest point');
axesHandle = axes(figureHandle);
hold(axesHandle, 'on'); grid(axesHandle, 'on'); axis(axesHandle, 'equal'); view(axesHandle, 3);
xlabel(axesHandle, 'X_{ref} (mm)'); ylabel(axesHandle, 'Y_{ref} (mm)'); zlabel(axesHandle, 'Z_{ref} (mm)');

patch(axesHandle, 'Faces', mesh.ConnectivityList(candidateFaces, :), 'Vertices', mesh.Points, ...
    'FaceColor', [0.6 0.8 1.0], 'EdgeColor', [0.3 0.3 0.3], 'FaceAlpha', 0.6, 'DisplayName', 'Candidate faces');
patch(axesHandle, 'Faces', mesh.ConnectivityList(chosenFace, :), 'Vertices', mesh.Points, ...
    'FaceColor', [1.0 0.6 0.1], 'EdgeColor', 'k', 'DisplayName', 'Chosen face');
scatter3(axesHandle, mesh.Points(seeds, 1), mesh.Points(seeds, 2), mesh.Points(seeds, 3), 30, 'b', 'filled', ...
    'DisplayName', sprintf('K = %d nearest vertices (CT tree)', numel(seeds)));
scatter3(axesHandle, point(1), point(2), point(3), 60, 'r', 'filled', 'DisplayName', 'Measured point');

newClosest = newDetails.closestBonePointsRef(pointIndex, :);
oldClosest = originalDetails.closestBonePointsRef(pointIndex, :);
scatter3(axesHandle, newClosest(1), newClosest(2), newClosest(3), 80, 'k', 'x', 'LineWidth', 2, 'DisplayName', 'Closest point (new)');
scatter3(axesHandle, oldClosest(1), oldClosest(2), oldClosest(3), 80, 'm', 'o', 'LineWidth', 1.5, 'DisplayName', 'Closest point (cost\_ICPLike)');
plot3(axesHandle, [point(1) newClosest(1)], [point(2) newClosest(2)], [point(3) newClosest(3)], 'r-', 'HandleVisibility', 'off');

legend(axesHandle, 'Location', 'best');
title(axesHandle, sprintf('Point %d: new %.4f mm, old %.4f mm, %d candidate faces', pointIndex, ...
    newDetails.pointToSurfaceDistancesMm(pointIndex), originalDetails.pointToSurfaceDistancesMm(pointIndex), numel(candidateFaces)));
rotate3d(figureHandle, 'on');
end


function plotBatchSizeEffect(batchSizes, medianSeconds, inputMegabytes, originalSeconds)
%PLOTBATCHSIZEEFFECT Evaluation time and batch input memory versus batch size.

figureHandle = figure('Name', 'dev_cost_ICPLike2: batch size');
tiledlayout(figureHandle, 1, 2, 'TileSpacing', 'compact');

nexttile; hold on; grid on;
semilogx(batchSizes, 1e3 * medianSeconds, 'o-', 'LineWidth', 1.5, 'DisplayName', 'dev\_cost\_ICPLike2');
yline(1e3 * originalSeconds, 'r--', 'cost\_ICPLike', 'DisplayName', 'cost\_ICPLike');
set(gca, 'XScale', 'log');
xlabel('points per batch'); ylabel('time per evaluation (ms)'); title('Evaluation time');

nexttile; grid on;
semilogx(batchSizes, inputMegabytes, 's-', 'LineWidth', 1.5);
xlabel('points per batch'); ylabel('MB'); title('Input arrays of the largest batch');
end


function plotTriangleTestCases(cornerA, cornerB, cornerC, testPoints, newClosestPoints, geom3dVectorizedPoints)
%PLOTTRIANGLETESTCASES Hand-made test points with the closest points from both methods.

figureHandle = figure('Name', 'Hand-made triangle test cases');
axesHandle = axes(figureHandle);
hold(axesHandle, 'on'); grid(axesHandle, 'on'); axis(axesHandle, 'equal'); view(axesHandle, 2);
xlabel(axesHandle, 'x'); ylabel(axesHandle, 'y');

patch(axesHandle, 'Faces', [1 2 3], 'Vertices', [cornerA; cornerB; cornerC], 'FaceColor', [0.85 0.85 0.85], ...
    'DisplayName', 'Triangle (obtuse corner A first)');
text(axesHandle, cornerA(1), cornerA(2), '  A'); text(axesHandle, cornerB(1), cornerB(2), '  B'); text(axesHandle, cornerC(1), cornerC(2), '  C');
scatter(axesHandle, testPoints(:, 1), testPoints(:, 2), 40, 'b', 'filled', 'DisplayName', 'Test points');
scatter(axesHandle, newClosestPoints(:, 1), newClosestPoints(:, 2), 70, 'k', 'x', 'LineWidth', 2, 'DisplayName', 'closestPointsOnTriangles');
scatter(axesHandle, geom3dVectorizedPoints(:, 1), geom3dVectorizedPoints(:, 2), 70, 'm', 'o', 'LineWidth', 1.5, 'DisplayName', 'geom3d vectorized');
for testIndex = 1:size(testPoints, 1)
    plot(axesHandle, [testPoints(testIndex, 1) newClosestPoints(testIndex, 1)], ...
        [testPoints(testIndex, 2) newClosestPoints(testIndex, 2)], 'k:', 'HandleVisibility', 'off');
end
legend(axesHandle, 'Location', 'best');
title(axesHandle, 'Closest points per test case (top view)');
end
