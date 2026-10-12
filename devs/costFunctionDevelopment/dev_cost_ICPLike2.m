function [cost, details] = dev_cost_ICPLike2(poseVector, data, config)
%DEV_COST_ICPLIKE2 Faster ICP-like cost: precomputed CT KD-tree + batched point-to-triangle distances.
% Development version of cost_ICPLike. It computes the SAME cost: the RMSE
% of the distances from every measured 3D bone-surface point to its closest
% location on the candidate bone mesh, searched among the faces attached to
% the K nearest mesh vertices. Only the way the work is organised changes:
%
%   1. KD-tree reuse. cost_ICPLike calls knnsearch(vertices, points), which
%      builds a brand-new KD-tree on every call. Here the tree is built once,
%      outside this function, over the CT-frame vertices. A rigid transform
%      keeps every distance unchanged, so moving the measured points from ref
%      into CT and searching the CT tree finds the same K nearest vertices
%      as searching the moved mesh in ref.
%   2. Batch processing. cost_ICPLike calls distancePointMesh once per
%      measured point. Here all (point, candidate face) pairs of a batch go
%      through one array computation in closestPointsOnTriangles.
%   3. The vertex-to-face lookup is also prepared once outside this function,
%      because mesh connectivity does not depend on the pose.
%
% Inputs:
%   poseVector - Six-value perturbation [tx; ty; tz; rx; ry; rz] around
%                data.T_CT_ref_initial (see stateVectorToTMatrix).
%   data       - Prepared optimization data (optimization_setup.mat layout).
%                Besides the fields used by cost_ICPLike, it needs the
%                pose-independent search data built by demo_cost_ICPLike2:
%                  data.extra.icpLike.vertexTreeCT        - KDTreeSearcher over
%                      data.boneMeshCT.Points (CT frame).
%                  data.extra.icpLike.faceIndicesByVertex - V-by-M face indices
%                      attached to each vertex, padded by repeating the
%                      vertex's first face (M = most faces at one vertex).
%   config     - Optional runtime configuration; data.config when omitted.
%                config.cost.parameters.nearestVertexCount - K (default 20).
%                config.cost.parameters.pointBatchSize     - measured points
%                    per batch (default: all points in one batch). It only
%                    bounds memory/time and does not change the result.
%
% Outputs:
%   cost       - RMSE point-to-surface distance in mm, as in cost_ICPLike.
%   details    - The same fields as cost_ICPLike's details, plus
%                nearestVertexIndicesByPoint, closestFaceIndexByPoint, and a
%                timing split of the correspondence stage.

%% READ THE SETTINGS

% The optimizer usually passes only the pose and the data, so the config
% saved with the data is used when none is given. The pose is forced into
% a column so the transform helpers always get the same shape.
if nargin < 3 || isempty(config)
    config = data.config;
end
poseVector = poseVector(:);

% Same default K as cost_ICPLike, so both functions agree when the config
% does not mention it (the saved fixture config belongs to P-IMLOP).
nearestVertexCount = 20;
if isfield(config.cost.parameters, 'nearestVertexCount')
    nearestVertexCount = config.cost.parameters.nearestVertexCount;
end

% The slow, pose-independent search data was prepared once by the demo, so
% here it is only picked up. K cannot exceed the number of mesh vertices,
% otherwise the nearest-vertex search would have nothing left to return.
vertexTreeCT        = data.extra.icpLike.vertexTreeCT;
faceIndicesByVertex = data.extra.icpLike.faceIndicesByVertex;
numberOfVertices    = size(data.boneMeshCT.Points, 1);
nearestVertexCount  = min(double(nearestVertexCount), numberOfVertices);

%% BUILD THE CANDIDATE TRANSFORMS AND MESH

% The candidate pose moves CT into ref. Its inverse (ref -> CT) is needed to
% move the measured points into the frame of the KD-tree. The inverse of a
% rigid [R t] is [R' -R'*t]; deriving it like this keeps it exactly rigid.
T_CT_ref_candidate   = stateVectorToTMatrix(poseVector, data.T_CT_ref_initial);
T_bone_ref_candidate = T_CT_ref_candidate * data.T_bone_CT;

R_CT_ref = T_CT_ref_candidate(1:3, 1:3);
t_CT_ref = T_CT_ref_candidate(1:3, 4);
T_ref_CT_candidate = [R_CT_ref.', -R_CT_ref.' * t_CT_ref; 0 0 0 1];

% The distances themselves are still computed in ref, exactly like
% cost_ICPLike, so the returned closest points and mesh are directly
% comparable with the original diagnostics.
bonePointsRefCandidate = applyRigidTransform(data.boneMeshCT.Points, T_CT_ref_candidate);
boneMeshRefCandidate   = triangulation(data.boneMeshCT.ConnectivityList, bonePointsRefCandidate);
boneMeshFaces          = data.boneMeshCT.ConnectivityList;

%% COLLECT THE MEASURED 3D SURFACE POINTS

% Keep the per-measurement point counts so results can be split again by
% ultrasound image at the end (same order as cost_ICPLike).
numberOfMeasurements = numel(data.boneSurfaceMeasurements);
numberOfSurfacePointsByMeasurement = zeros(numberOfMeasurements, 1);
for measurementIndex = 1:numberOfMeasurements
    numberOfSurfacePointsByMeasurement(measurementIndex) = ...
        size(data.boneSurfaceMeasurements(measurementIndex).surfaceCoordinatesXYZRef, 1);
end
boneSurfacePointsRef  = double(vertcat(data.boneSurfaceMeasurements.surfaceCoordinatesXYZRef));
numberOfSurfacePoints = size(boneSurfacePointsRef, 1);

% With the point count known, the batch size can be chosen. By default all
% points go in one batch; a smaller batch only bounds memory and run time
% and never changes the result (200 was fastest in the demo).
pointBatchSize = numberOfSurfacePoints;
if isfield(config.cost.parameters, 'pointBatchSize')
    pointBatchSize = config.cost.parameters.pointBatchSize;
end

%% STEP 1 -- K NEAREST VERTICES WITH THE PRECOMPUTED CT KD-TREE

% The correspondence search is timed as a whole so it can be compared
% directly with the correspondence time reported by cost_ICPLike.
correspondenceTimer = tic;

% Move the measured points into CT, the frame the tree was built in. Only
% the ~3400 query points move; the tree is reused unchanged. Because the
% move is rigid, the K vertices found are the same as when searching the
% moved mesh in ref. The KNN time is recorded on its own for the timing split.
boneSurfacePointsCT         = applyRigidTransform(boneSurfacePointsRef, T_ref_CT_candidate);
nearestVertexIndicesByPoint = knnsearch(vertexTreeCT, boneSurfacePointsCT, 'K', nearestVertexCount);
knnRuntimeSeconds           = toc(correspondenceTimer);

%% STEP 2 -- CANDIDATE FACES OF EVERY POINT, AS ONE MATRIX

% Look up the faces of all K seed vertices for all points at once. Row i of
% candidateFaceMatrix lists every face touching one of point i's seeds:
% faceIndicesByVertex(seeds, :) gives a K-by-M block per point, and the
% transposes/reshape lay those blocks out as one row of K*M per point.
facesPerVertex      = size(faceIndicesByVertex, 2);
seedFaceBlocks      = faceIndicesByVertex(nearestVertexIndicesByPoint.', :);
candidateFaceMatrix = reshape(seedFaceBlocks.', nearestVertexCount * facesPerVertex, numberOfSurfacePoints).';

% Neighbouring seeds share faces, and padding repeats faces too. Sorting each
% row puts repeats side by side, so a face is "new" when it differs from its
% left neighbour. This is the batched form of cost_ICPLike's per-point
% UNIQUE, and it also gives the same ascending face order, so ties between
% faces are resolved the same way (the lowest face index wins).
candidateFaceMatrix = sort(candidateFaceMatrix, 2);
isUniqueCandidate   = [true(numberOfSurfacePoints, 1), diff(candidateFaceMatrix, 1, 2) ~= 0];
candidateFaceCountByPoint = sum(isUniqueCandidate, 2);

%% STEP 3 -- BATCHED CLOSEST POINTS ON THE CANDIDATE FACES

% Now that every point has its list of candidate faces, the exact closest
% point is found on them. This stage is timed separately, and the outputs
% are allocated at full size because each batch fills its own rows.
distanceTimer = tic;
closestBonePointsRef      = zeros(numberOfSurfacePoints, 3);
squaredDistancesByPoint   = zeros(numberOfSurfacePoints, 1);
closestFaceIndexByPoint   = zeros(numberOfSurfacePoints, 1);

% Points are handled a batch at a time, so the (point, face) pair arrays
% stay small enough to fit in memory. Each batch takes its slice of the
% sorted face matrix and of the "keep" mask built above.
for firstPoint = 1:pointBatchSize:numberOfSurfacePoints
    batchPoints     = (firstPoint:min(firstPoint + pointBatchSize - 1, numberOfSurfacePoints)).';
    batchFaces      = candidateFaceMatrix(batchPoints, :);
    batchUniqueMask = isUniqueCandidate(batchPoints, :);

    % Turn the kept matrix entries into a flat list of (point, face) pairs.
    % FIND walks the mask column by column, and returns for each pair its
    % row (= which point of the batch) and column (= where to put the result).
    [pairRowInBatch, pairColumn] = find(batchUniqueMask);
    pairPointIndex = batchPoints(pairRowInBatch);
    pairFaceIndex  = batchFaces(sub2ind(size(batchFaces), pairRowInBatch, pairColumn));

    % One array call computes every pair of the batch at once, instead of
    % one call per point. Corners come from the ref-frame mesh, so the
    % distances are in ref and match cost_ICPLike's outputs.
    [pairClosestPointsRef, pairSquaredDistances] = closestPointsOnTriangles( ...
        boneSurfacePointsRef(pairPointIndex, :), ...
        bonePointsRefCandidate(boneMeshFaces(pairFaceIndex, 1), :), ...
        bonePointsRefCandidate(boneMeshFaces(pairFaceIndex, 2), :), ...
        bonePointsRefCandidate(boneMeshFaces(pairFaceIndex, 3), :));

    % Put the pair distances back into the batch's matrix layout. Removed
    % repeats stay at Inf so they can never be chosen. MIN along each row
    % then gives every point's closest face; on an exact tie it returns the
    % first column, i.e. the lowest face index, like distancePointMesh.
    batchSquaredDistances = inf(size(batchFaces));
    batchSquaredDistances(batchUniqueMask) = pairSquaredDistances;
    [batchMinimumSquaredDistance, bestColumn] = min(batchSquaredDistances, [], 2);

    % Remember which pair produced each minimum, to fetch its closest point.
    pairNumberMatrix = zeros(size(batchFaces));
    pairNumberMatrix(batchUniqueMask) = 1:numel(pairSquaredDistances);
    bestPairNumber = pairNumberMatrix(sub2ind(size(batchFaces), (1:numel(batchPoints)).', bestColumn));

    % Store the winning distance, closest point and face in the batch's rows.
    squaredDistancesByPoint(batchPoints)  = batchMinimumSquaredDistance;
    closestBonePointsRef(batchPoints, :)  = pairClosestPointsRef(bestPairNumber, :);
    closestFaceIndexByPoint(batchPoints)  = pairFaceIndex(bestPairNumber);
end

% With all batches done, squared distances become real distances in mm,
% and both timers are stopped.
pointToSurfaceDistancesMm    = sqrt(squaredDistancesByPoint);
distanceRuntimeSeconds       = toc(distanceTimer);
correspondenceRuntimeSeconds = toc(correspondenceTimer);

%% CALCULATE THE COST AND PER-MEASUREMENT STATISTICS (as in cost_ICPLike)

% The cost is the RMSE over all points, so a few large misfits weigh more
% than many small ones, exactly as in cost_ICPLike.
cost = sqrt(mean(pointToSurfaceDistancesMm .^ 2));

% For diagnostics the results are also split per ultrasound image. The
% outputs are allocated first; NaN marks images that had no points.
closestBonePointsRefCells      = cell(numberOfMeasurements, 1);
pointToSurfaceDistanceMmCells  = cell(numberOfMeasurements, 1);
meanDistanceMmByMeasurement    = nan(numberOfMeasurements, 1);
rmseDistanceMmByMeasurement    = nan(numberOfMeasurements, 1);
maximumDistanceMmByMeasurement = nan(numberOfMeasurements, 1);

% The points were stacked image by image, so walking the saved counts in
% order cuts each image's points back out. Statistics are skipped for an
% image with no points, leaving its NaN in place.
firstPointIndex = 1;
for measurementIndex = 1:numberOfMeasurements
    currentPointIndices = firstPointIndex:(firstPointIndex + numberOfSurfacePointsByMeasurement(measurementIndex) - 1);
    currentDistancesMm  = pointToSurfaceDistancesMm(currentPointIndices);

    closestBonePointsRefCells{measurementIndex}     = closestBonePointsRef(currentPointIndices, :);
    pointToSurfaceDistanceMmCells{measurementIndex} = currentDistancesMm;
    if ~isempty(currentDistancesMm)
        meanDistanceMmByMeasurement(measurementIndex)    = mean(currentDistancesMm);
        rmseDistanceMmByMeasurement(measurementIndex)    = sqrt(mean(currentDistancesMm .^ 2));
        maximumDistanceMmByMeasurement(measurementIndex) = max(currentDistancesMm);
    end
    firstPointIndex = firstPointIndex + numel(currentPointIndices);
end

%% PACKAGE DETAILS (cost_ICPLike fields first, then the new diagnostics)

% Finally, everything is returned in the same layout as cost_ICPLike, so
% existing plots and comparisons work unchanged: first the candidate pose
% and mesh, then the point-level results, then the summary statistics.
details.T_CT_ref_candidate   = T_CT_ref_candidate;
details.T_bone_ref_candidate = T_bone_ref_candidate;
details.boneMeshRefCandidate = boneMeshRefCandidate;

details.boneSurfacePointsRef               = boneSurfacePointsRef;
details.closestBonePointsRef               = closestBonePointsRef;
details.pointToSurfaceDistancesMm          = pointToSurfaceDistancesMm;
details.closestBonePointsRefCells          = closestBonePointsRefCells;
details.pointToSurfaceDistanceMmCells      = pointToSurfaceDistanceMmCells;
details.numberOfSurfacePointsByMeasurement = numberOfSurfacePointsByMeasurement;

details.meanDistanceMmByMeasurement    = meanDistanceMmByMeasurement;
details.rmseDistanceMmByMeasurement    = rmseDistanceMmByMeasurement;
details.maximumDistanceMmByMeasurement = maximumDistanceMmByMeasurement;

details.meanPointToSurfaceDistanceMm    = mean(pointToSurfaceDistancesMm);
details.rmsePointToSurfaceDistanceMm    = cost;
details.medianPointToSurfaceDistanceMm  = median(pointToSurfaceDistancesMm);
details.maximumPointToSurfaceDistanceMm = max(pointToSurfaceDistancesMm);

details.candidateFaceCountByPoint    = candidateFaceCountByPoint;
details.correspondenceRuntimeSeconds = correspondenceRuntimeSeconds;

% New in this version: the search results themselves and a timing split.
details.T_ref_CT_candidate          = T_ref_CT_candidate;
details.nearestVertexIndicesByPoint = nearestVertexIndicesByPoint;
details.closestFaceIndexByPoint     = closestFaceIndexByPoint;
details.knnRuntimeSeconds           = knnRuntimeSeconds;
details.distanceRuntimeSeconds      = distanceRuntimeSeconds;

% The settings actually used are recorded so a result can be traced back
% to how it was computed.
details.costSettings.correspondenceMethod = 'ct_kdtree_batched_candidate_faces';
details.costSettings.nearestVertexCount   = nearestVertexCount;
details.costSettings.pointBatchSize       = pointBatchSize;
details.status = '3d_point_cloud_rmse_computed';
end
