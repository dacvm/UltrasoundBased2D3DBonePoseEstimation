function [cost, details] = cost_ICPLike_v01(poseVector, data, config)
%COST_ICPLIKE_V01 Measure how well one candidate bone pose matches 3D ultrasound points.
% The optimizer calls this function with one possible six-parameter pose. The
% function moves the CT bone mesh to that pose, finds the closest location on
% the mesh surface for every measured ultrasound point, and combines those
% distances into one scalar cost. A smaller cost means that the candidate mesh
% lies closer to the measured bone surface.
%
% The correspondence search has two stages. First, KNNSEARCH finds nearby
% mesh vertices as a fast way to locate the relevant region of the mesh.
% Second, DISTANCEPOINTMESH searches the real triangles attached to those
% vertices. Therefore, the final correspondence may lie inside a triangle or
% on an edge; it is not restricted to one of the mesh vertices.
%
% This is a one-way measured-point-to-mesh cost. It answers, "How far is each
% ultrasound point from the candidate mesh?" It does not require every part
% of the CT mesh to have a matching ultrasound measurement.
%
% Inputs:
%   poseVector - Six-value candidate-pose perturbation written as
%                  \(\mathbf{x}=[t_x,t_y,t_z,r_x,r_y,r_z]^T\).
%                The first three values describe translation. The last three
%                form the rotation vector expected by STATEVECTORTOTMATRIX.
%                The perturbation is applied around data.T_CT_ref_initial.
%   data       - Prepared optimization data. This function uses the CT-frame
%                mesh, the initial CT-to-reference transform, the bone-to-CT
%                transform, and the measured surface points already expressed
%                in the reference frame. File loading must happen before this
%                function is called because a cost function is called often.
%   config     - Optional runtime configuration structure. The field
%                config.cost.parameters.nearestVertexCount sets the number
%                \(K\) of nearby vertices used to build each local face patch.
%                If the field is absent, the function uses \(K=20\).
%
% Outputs:
%   cost       - Root-mean-square (RMSE) point-to-surface distance in mm:
%                  \(J=\sqrt{\frac{1}{N}\sum_{i=1}^{N}d_i^2}\).
%                Here, \(d_i\) is the distance from measured point \(i\) to
%                its closest location on the candidate mesh. Lower is better.
%   details    - Structure containing the candidate transforms and mesh, all
%                point correspondences, global and per-measurement statistics,
%                the resolved search settings, runtime, and completion status.

%% READ AND CHECK THE INPUTS

% A caller may omit CONFIG during interactive development. In that case, use
% the configuration saved with DATA so the evaluation is still reproducible.
if nargin < 3 || isempty(config)
    config = data.config;
end

% Reject an invalid optimizer state early. Reshape a valid row or column input
% into the column-vector convention used by the pose-conversion function.
validateattributes(poseVector, {'numeric'}, {'vector', 'numel', 6, 'real', 'finite'}, mfilename, 'poseVector');
poseVector = poseVector(:);

% List the prepared-data fields used below. Checking them here gives a clear
% setup error instead of a less helpful missing-field error later in the code.
requiredDataFields = {'boneMeshCT', 'T_CT_ref_initial', 'T_bone_CT', 'hasBoneSurface', 'boneSurfaceMeasurements'};
if ~isstruct(data) || ~all(isfield(data, requiredDataFields))
    error('cost_ICPLike_v01:MissingPreparedData', ...
          'The prepared data is missing fields required by the 3D point-cloud cost.');
end

% The mesh must retain both its vertices and triangle connectivity, which is
% why this function requires a triangulation rather than a plain point cloud.
if ~isa(data.boneMeshCT, 'triangulation')
    error('cost_ICPLike_v01:InvalidBoneMesh', ...
          'data.boneMeshCT must be a triangulation.');
end

% Stop when no measured surface is available: without measured points there
% is no geometric evidence from which this cost can be calculated.
if ~data.hasBoneSurface || isempty(data.boneSurfaceMeasurements)
    error('cost_ICPLike_v01:MissingBoneSurface', ...
          'The prepared data does not contain aligned 3D bone-surface measurements.');
end

% Report missing dependencies before doing any costly geometry work.
% KNNSEARCH performs the coarse local search; DISTANCEPOINTMESH performs the
% final point-to-triangle calculation inside that local mesh region.
if exist('knnsearch', 'file') ~= 2
    error('cost_ICPLike_v01:MissingKnnsearch', ...
          'knnsearch is required for the KNN candidate-face search.');
end
if exist('distancePointMesh', 'file') ~= 2
    error('cost_ICPLike_v01:MissingDistancePointMesh', ...
          'distancePointMesh from GEOM3D is required for point-to-mesh distances.');
end

% Start with a conservative default neighborhood. A larger K searches more
% faces and is safer for irregular triangles, but it also takes more time.
nearestVertexCount = 20;
if isstruct(config) && isfield(config, 'cost') && ...
        isstruct(config.cost) && isfield(config.cost, 'parameters') && ...
        isfield(config.cost.parameters, 'nearestVertexCount')
    nearestVertexCount = config.cost.parameters.nearestVertexCount;
end

% K must be a positive whole number because it counts mesh vertices.
validateattributes(nearestVertexCount, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'positive', 'integer'}, ...
    mfilename, 'config.cost.parameters.nearestVertexCount');

%% BUILD THE CANDIDATE BONE MESH IN THE REFERENCE FRAME

% Convert the six optimizer values into the candidate CT-to-reference rigid
% transform. With the project's column-vector convention, a CT point moves as
% \(\tilde{\mathbf{p}}_{ref}=\mathbf{T}_{CT\rightarrow ref}\tilde{\mathbf{p}}_{CT}\).
T_CT_ref_candidate   = stateVectorToTMatrix(poseVector, data.T_CT_ref_initial);

% Compose the bone-to-CT and CT-to-reference transforms from right to left:
% \(\mathbf{T}_{bone\rightarrow ref}=\mathbf{T}_{CT\rightarrow ref} \mathbf{T}_{bone\rightarrow CT}\). 
% This transform is stored for diagnostics.
T_bone_ref_candidate = T_CT_ref_candidate * data.T_bone_CT;

% Always transform the original CT vertices. Starting from the original mesh
% on every call prevents candidate transforms from accumulating across the
% many evaluations performed by an optimizer.
bonePointsRefCandidate = applyRigidTransform(data.boneMeshCT.Points, T_CT_ref_candidate);

% Rebuild the triangulation with the transformed vertices and unchanged face
% connectivity. A rigid transform moves the mesh but does not change which
% three vertices form each triangle.
boneMeshRefCandidate = triangulation(data.boneMeshCT.ConnectivityList, bonePointsRefCandidate);

% Give the vertex coordinates and triangle indices short, frame-explicit
% names because the correspondence functions consume these arrays directly.
boneMeshVerticesRef = boneMeshRefCandidate.Points;
boneMeshFaces       = boneMeshRefCandidate.ConnectivityList;

% A request larger than the mesh cannot be passed to KNNSEARCH. Clamp K to
% the available number of vertices while preserving the validated integer.
nearestVertexCount  = min(double(nearestVertexCount), size(boneMeshVerticesRef, 1));

%% COLLECT THE MEASURED 3D SURFACE POINTS

% DATA keeps the extracted surface points grouped by ultrasound measurement.
% Retain that grouping so an unusually large distance can later be traced to
% its source image, while also preparing one pooled point cloud for the cost.
numberOfMeasurements = numel(data.boneSurfaceMeasurements);
surfacePointCells    = cell(numberOfMeasurements, 1);
numberOfSurfacePointsByMeasurement = zeros(numberOfMeasurements, 1);

% Read and validate each measurement separately before joining the points.
for measurementIndex = 1:numberOfMeasurements

    % These points were transformed into REF during input preparation. Both
    % the measurements and candidate mesh must share REF before comparison.
    currentSurfacePointsRef = data.boneSurfaceMeasurements(measurementIndex).surfaceCoordinatesXYZRef;

    % Accept an empty N-by-3 array, but reject a wrong shape, nonnumeric data,
    % NaN, or Inf because any of those would invalidate the distance result.
    if ~isnumeric(currentSurfacePointsRef) || size(currentSurfacePointsRef, 2) ~= 3 || ~all(isfinite(currentSurfacePointsRef), 'all')
        error('cost_ICPLike_v01:InvalidBoneSurface', ...
              'Measurement %d must contain finite N-by-3 points in ref.', measurementIndex);
    end

    % Convert the points to double for the geometry functions and remember
    % how many belong to this measurement so they can be separated again.
    surfacePointCells{measurementIndex} = double(currentSurfacePointsRef);
    numberOfSurfacePointsByMeasurement(measurementIndex) = size(currentSurfacePointsRef, 1);
end

% Vertically concatenate the cells without changing their order. Thus, all
% points from measurement 1 come first, followed by measurement 2, and so on.
boneSurfacePointsRef = vertcat(surfacePointCells{:});

% Individual measurements may be empty, but the pooled dataset must contain
% at least one point or the cost would be undefined.
if isempty(boneSurfacePointsRef)
    error('cost_ICPLike_v01:EmptyBoneSurface', ...
          'The aligned measurements contain no 3D bone-surface points.');
end

%% FIND KNN CANDIDATE FACES AND CLOSEST SURFACE POINTS

% Time only the correspondence stage. This helps us assess the acceleration
% method without mixing in input validation or result packaging time.
correspondenceTimer = tic;

% STEP 1 -- Locate a small mesh neighborhood around every measured point.
% For measured point \(\mathbf{p}_i\), KNNSEARCH returns the indices of its K
% nearest mesh vertices. These vertices are search seeds only: the K vertices
% need not belong to one triangle, and they are not the final correspondences.
nearestVertexIndicesByPoint = knnsearch(boneMeshVerticesRef, boneSurfacePointsRef, 'K', nearestVertexCount);

% STEP 2 -- Build a lookup from every vertex to its attached triangles.
% Mesh connectivity does not change under a rigid transformation. Therefore,
% each candidate vertex has the same neighboring face indices throughout this
% evaluation, and the lookup needs to be built only once.
meshVertexIndices           = (1:size(boneMeshVerticesRef, 1)).';
faceIndicesAttachedToVertex = vertexAttachments(boneMeshRefCandidate, meshVertexIndices);

% Allocate one output row for every measured point before entering the loop.
% Preallocation also makes the intended point-to-result alignment explicit.
numberOfSurfacePoints       = size(boneSurfacePointsRef, 1);
closestBonePointsRef        = zeros(numberOfSurfacePoints, 3);
pointToSurfaceDistancesMm   = zeros(numberOfSurfacePoints, 1);
candidateFaceCountByPoint   = zeros(numberOfSurfacePoints, 1);

% STEP 3 -- Find an accurate correspondence within each local face patch.
for pointIndex = 1:numberOfSurfacePoints
    
    % Read the K seed vertices associated with the current measured point.
    currentNearestVertexIndices = nearestVertexIndicesByPoint(pointIndex, :);

    % Join the faces attached to all seed vertices. Neighboring vertices often
    % share triangles, so UNIQUE removes repeated face indices from the patch:
    % \(\mathcal{F}_i=\bigcup_{v\in\mathrm{KNN}(\mathbf{p}_i)}
    % \mathrm{faces}(v)\).
    currentAttachmentCells      = faceIndicesAttachedToVertex(currentNearestVertexIndices);
    currentCandidateFaceIndices = unique([currentAttachmentCells{:}]);

    % Every valid triangulation vertex should have an attached face. Treat an
    % empty patch as a mesh/setup error instead of returning a misleading cost.
    if isempty(currentCandidateFaceIndices)
        error('cost_ICPLike_v01:EmptyCandidateFaces', ...
              'Measured point %d has no candidate mesh faces.', pointIndex);
    end

    % Extract only the original mesh triangles belonging to this local patch
    % and retain the patch size as a useful performance diagnostic.
    currentCandidateFaces                 = boneMeshFaces(currentCandidateFaceIndices, :);
    candidateFaceCountByPoint(pointIndex) = numel(currentCandidateFaceIndices);

    % Find the closest point \(\mathbf{q}_i^*\) on the candidate triangles:
    % \(\mathbf{q}_i^*=\arg\min_{\mathbf{q}\in\mathcal{F}_i}
    % \|\mathbf{p}_i-\mathbf{q}\|_2\), and store
    % \(d_i=\|\mathbf{p}_i-\mathbf{q}_i^*\|_2\). The returned point may lie
    % inside a triangle, on an edge, or at a vertex.
    [pointToSurfaceDistancesMm(pointIndex), ...
     closestBonePointsRef(pointIndex, :)] = distancePointMesh( ...
        boneSurfacePointsRef(pointIndex, :), ...
        boneMeshVerticesRef, ...
        currentCandidateFaces, ...
        'algorithm', 'vectorized');
end

% Stop the timer after every measured point has received a correspondence.
correspondenceRuntimeSeconds = toc(correspondenceTimer);

% Reject NaN, Inf, and negative distances. Such output indicates a geometry
% or dependency failure and must not silently enter the optimizer objective.
if any(~isfinite(pointToSurfaceDistancesMm)) || ...
        any(pointToSurfaceDistancesMm < 0) || ...
        any(~isfinite(closestBonePointsRef), 'all')
    error('cost_ICPLike_v01:InvalidCorrespondence', ...
          'The KNN candidate-face search produced an invalid correspondence.');
end

% Independently reconstruct each Euclidean distance from the returned point
% pair. This confirms that DISTANCEPOINTMESH's two outputs still correspond:
% \(d_i\stackrel{?}{=}\|\mathbf{p}_i-\mathbf{q}_i^*\|_2\).
reconstructedDistancesMm = vecnorm(boneSurfacePointsRef - closestBonePointsRef, 2, 2);

% Allow only a tiny numerical rounding difference in millimetres.
distanceAgreementToleranceMm = 1e-9;
if any(abs(reconstructedDistancesMm - pointToSurfaceDistancesMm) > distanceAgreementToleranceMm)
    error('cost_ICPLike_v01:DistanceMismatch', ...
          'A reported distance does not match its point correspondence.');
end

%% CALCULATE THE COST AND PER-MEASUREMENT STATISTICS

% Convert all correspondence distances into the one scalar required by the
% optimizer. Every measured point has equal weight in this first version:
% \(J=\sqrt{\frac{1}{N}\sum_{i=1}^{N}d_i^2}\).
% Squaring makes large mismatches influence the result more strongly, while
% the square root keeps COST in the original unit of millimetres.
cost = sqrt(mean(pointToSurfaceDistancesMm .^ 2));

% Prepare containers that restore the original ultrasound-measurement groups.
% Empty measurements keep NaN statistics because no distance was observed.
closestBonePointsRefCells      = cell(numberOfMeasurements, 1);
pointToSurfaceDistanceMmCells  = cell(numberOfMeasurements, 1);
meanDistanceMmByMeasurement    = nan(numberOfMeasurements, 1);
rmseDistanceMmByMeasurement    = nan(numberOfMeasurements, 1);
maximumDistanceMmByMeasurement = nan(numberOfMeasurements, 1);

% The pooled vector follows measurement order. FIRSTPOINTINDEX marks where
% the current measurement begins within that vector.
firstPointIndex = 1;
for measurementIndex = 1:numberOfMeasurements
    % Recreate the row range belonging to this measurement from its saved
    % point count. For a zero count, MATLAB produces an empty index range.
    currentPointCount   = numberOfSurfacePointsByMeasurement(measurementIndex);
    currentPointIndices = firstPointIndex:(firstPointIndex + currentPointCount - 1);

    % Store the current measurement's correspondences and distances together
    % so downstream inspection can relate them back to one ultrasound image.
    currentDistancesMm                              = pointToSurfaceDistancesMm(currentPointIndices);
    closestBonePointsRefCells{measurementIndex}     = closestBonePointsRef(currentPointIndices, :);
    pointToSurfaceDistanceMmCells{measurementIndex} = currentDistancesMm;

    % Summarize only nonempty measurements. Mean describes typical separation,
    % RMSE emphasizes larger errors, and maximum highlights the worst point.
    if ~isempty(currentDistancesMm)
        meanDistanceMmByMeasurement(measurementIndex)    = mean(currentDistancesMm);
        rmseDistanceMmByMeasurement(measurementIndex)    = sqrt(mean(currentDistancesMm .^ 2));
        maximumDistanceMmByMeasurement(measurementIndex) = max(currentDistancesMm);
    end

    % Move the start marker past the points assigned to this measurement.
    firstPointIndex = firstPointIndex + currentPointCount;
end

%% PACKAGE DETAILS FOR THE DEMO AND FUTURE OPTIMIZER RESULTS

% Begin DETAILS with the candidate pose and geometry. Frame-explicit names
% prevent CT, bone-anatomical, and reference coordinates from being confused.
details.T_CT_ref_candidate   = T_CT_ref_candidate;
details.T_bone_ref_candidate = T_bone_ref_candidate;
details.boneMeshRefCandidate = boneMeshRefCandidate;

% Store the pooled measured points, their closest mesh points, and distances.
% Row i in each pooled array refers to the same correspondence pair.
details.boneSurfacePointsRef                     = boneSurfacePointsRef;
details.closestBonePointsRef                     = closestBonePointsRef;
details.pointToSurfaceDistancesMm                = pointToSurfaceDistancesMm;

% Also store the same results split by measurement. These cells allow a poor
% cost contribution to be traced back to the responsible ultrasound image.
details.closestBonePointsRefCells                = closestBonePointsRefCells;
details.pointToSurfaceDistanceMmCells            = pointToSurfaceDistanceMmCells;
details.numberOfSurfacePointsByMeasurement       = numberOfSurfacePointsByMeasurement;

% Store per-measurement summaries for compact tables and diagnostic plots.
details.meanDistanceMmByMeasurement              = meanDistanceMmByMeasurement;
details.rmseDistanceMmByMeasurement              = rmseDistanceMmByMeasurement;
details.maximumDistanceMmByMeasurement           = maximumDistanceMmByMeasurement;

% Store global summaries so callers do not need to recalculate them. The
% global RMSE is exactly the scalar COST returned to the optimizer.
details.meanPointToSurfaceDistanceMm             = mean(pointToSurfaceDistancesMm);
details.rmsePointToSurfaceDistanceMm             = cost;
details.medianPointToSurfaceDistanceMm           = median(pointToSurfaceDistancesMm);
details.maximumPointToSurfaceDistanceMm          = max(pointToSurfaceDistancesMm);

% Record how much geometry each local search examined and how long all
% correspondence calculations took. These values help tune K later.
details.candidateFaceCountByPoint                = candidateFaceCountByPoint;
details.correspondenceRuntimeSeconds             = correspondenceRuntimeSeconds;

% Record the resolved method and K value with the result. This keeps an
% optimization result understandable even when configuration defaults change.
details.costSettings.correspondenceMethod        = 'knn_candidate_faces';
details.costSettings.requestedNearestVertexCount = double(nearestVertexCount);
details.costSettings.nearestVertexCount          = nearestVertexCount;

% A clear status value lets development scripts confirm that this cost path
% completed normally before they inspect the other fields.
details.status = '3d_point_cloud_rmse_computed';
end
