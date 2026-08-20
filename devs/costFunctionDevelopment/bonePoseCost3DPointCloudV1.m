function [cost, details] = bonePoseCost3DPointCloudV1(poseVector, data, config)
%BONEPOSECOST3DPOINTCLOUDV1 Evaluate 3D surface agreement for one bone pose.
% This development cost transforms the CT bone mesh to a candidate pose and
% measures the root-mean-square distance from the ultrasound bone-surface points to the
% candidate mesh. A K-nearest-vertex search selects a small patch of real
% mesh faces before distancePointMesh finds the closest point on that patch.
% The function has the same input and output style as the production cost
% models so it can later be connected to the optimizer without changing its
% scientific calculation.
%
% Inputs:
%   poseVector - Six-value perturbation around data.T_CT_ref_initial. The
%                first three values are translation and the final three are
%                the rotation vector used by stateVectorToTMatrix.
%   data       - Prepared optimization data containing boneMeshCT,
%                T_CT_ref_initial, T_bone_CT, and aligned
%                boneSurfaceMeasurements in the reference frame.
%   config     - Optional scalar runtime configuration. When provided,
%                config.cost.parameters.nearestVertexCount can select the
%                KNN neighborhood size. The default value is 20.
%
% Outputs:
%   cost       - Root-mean-square measured-point-to-candidate-mesh distance
%                in mm.
%                Lower values indicate better 3D surface agreement.
%   details    - Candidate transforms and mesh, point correspondences,
%                distance statistics, resolved settings, runtime, and status.

%% READ AND CHECK THE INPUTS

% Use the configuration stored with the prepared data when none is supplied.
if nargin < 3 || isempty(config)
    config = data.config;
end

% The optimizer always supplies one finite six-value pose perturbation.
validateattributes(poseVector, {'numeric'}, {'vector', 'numel', 6, 'real', 'finite'}, mfilename, 'poseVector');
poseVector = poseVector(:);

% Check only the prepared fields that this cost function directly consumes.
requiredDataFields = {'boneMeshCT', 'T_CT_ref_initial', 'T_bone_CT', 'hasBoneSurface', 'boneSurfaceMeasurements'};
if ~isstruct(data) || ~all(isfield(data, requiredDataFields))
    error('bonePoseCost3DPointCloudV1:MissingPreparedData', ...
          'The prepared data is missing fields required by the 3D point-cloud cost.');
end
if ~isa(data.boneMeshCT, 'triangulation')
    error('bonePoseCost3DPointCloudV1:InvalidBoneMesh', ...
          'data.boneMeshCT must be a triangulation.');
end
if ~data.hasBoneSurface || isempty(data.boneSurfaceMeasurements)
    error('bonePoseCost3DPointCloudV1:MissingBoneSurface', ...
          'The prepared data does not contain aligned 3D bone-surface measurements.');
end

% Report missing toolboxes before starting the correspondence calculation.
if exist('knnsearch', 'file') ~= 2
    error('bonePoseCost3DPointCloudV1:MissingKnnsearch', ...
          'knnsearch is required for the KNN candidate-face search.');
end
if exist('distancePointMesh', 'file') ~= 2
    error('bonePoseCost3DPointCloudV1:MissingDistancePointMesh', ...
          'distancePointMesh from GEOM3D is required for point-to-mesh distances.');
end

% Keep K as a simple fixed development setting unless a future runtime
% configuration explicitly supplies it.
nearestVertexCount = 20;
if isstruct(config) && isfield(config, 'cost') && ...
        isstruct(config.cost) && isfield(config.cost, 'parameters') && ...
        isfield(config.cost.parameters, 'nearestVertexCount')
    nearestVertexCount = config.cost.parameters.nearestVertexCount;
end
validateattributes(nearestVertexCount, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'positive', 'integer'}, ...
    mfilename, 'config.cost.parameters.nearestVertexCount');

%% BUILD THE CANDIDATE MESH IN THE REFERENCE FRAME

% Convert the optimizer state into the project-format candidate transform.
T_CT_ref_candidate   = stateVectorToTMatrix(poseVector, data.T_CT_ref_initial);
T_bone_ref_candidate = T_CT_ref_candidate * data.T_bone_CT;

% Always transform the original CT mesh so repeated calls cannot accumulate
% transformations from earlier optimizer evaluations.
bonePointsRefCandidate = applyRigidTransform(data.boneMeshCT.Points, T_CT_ref_candidate);
boneMeshRefCandidate = triangulation(data.boneMeshCT.ConnectivityList, bonePointsRefCandidate);

boneMeshVerticesRef = boneMeshRefCandidate.Points;
boneMeshFaces       = boneMeshRefCandidate.ConnectivityList;
nearestVertexCount  = min(double(nearestVertexCount), size(boneMeshVerticesRef, 1));

%% COLLECT THE MEASURED 3D SURFACE POINTS

% Preserve the measurement grouping for later diagnostics while using one
% pooled point cloud for the scalar cost.
numberOfMeasurements = numel(data.boneSurfaceMeasurements);
surfacePointCells    = cell(numberOfMeasurements, 1);
numberOfSurfacePointsByMeasurement = zeros(numberOfMeasurements, 1);

for measurementIndex = 1:numberOfMeasurements
    currentSurfacePointsRef = data.boneSurfaceMeasurements(measurementIndex).surfaceCoordinatesXYZRef;

    if ~isnumeric(currentSurfacePointsRef) || size(currentSurfacePointsRef, 2) ~= 3 || ~all(isfinite(currentSurfacePointsRef), 'all')
        error('bonePoseCost3DPointCloudV1:InvalidBoneSurface', ...
              'Measurement %d must contain finite N-by-3 points in ref.', measurementIndex);
    end

    surfacePointCells{measurementIndex} = double(currentSurfacePointsRef);
    numberOfSurfacePointsByMeasurement(measurementIndex) = size(currentSurfacePointsRef, 1);
end

boneSurfacePointsRef = vertcat(surfacePointCells{:});
if isempty(boneSurfacePointsRef)
    error('bonePoseCost3DPointCloudV1:EmptyBoneSurface', ...
          'The aligned measurements contain no 3D bone-surface points.');
end

%% FIND KNN CANDIDATE FACES AND CLOSEST SURFACE POINTS

correspondenceTimer = tic;

% Nearby vertices are used only to locate a small set of genuine mesh faces.
% The final correspondence is still a point on a triangle, not a mesh vertex.
nearestVertexIndicesByPoint = knnsearch(boneMeshVerticesRef, boneSurfacePointsRef, 'K', nearestVertexCount);

% Mesh connectivity does not change under a rigid transformation, so each
% vertex has the same attached face indexes for the complete evaluation.
meshVertexIndices           = (1:size(boneMeshVerticesRef, 1)).';
faceIndicesAttachedToVertex = vertexAttachments(boneMeshRefCandidate, meshVertexIndices);

numberOfSurfacePoints       = size(boneSurfacePointsRef, 1);
closestBonePointsRef        = zeros(numberOfSurfacePoints, 3);
pointToSurfaceDistancesMm   = zeros(numberOfSurfacePoints, 1);
candidateFaceCountByPoint   = zeros(numberOfSurfacePoints, 1);

for pointIndex = 1:numberOfSurfacePoints
    % Join all faces attached to the nearby vertices and remove duplicates
    % shared by neighboring vertices.
    currentNearestVertexIndices = nearestVertexIndicesByPoint(pointIndex, :);
    currentAttachmentCells      = faceIndicesAttachedToVertex(currentNearestVertexIndices);
    currentCandidateFaceIndices = unique([currentAttachmentCells{:}]);

    if isempty(currentCandidateFaceIndices)
        error('bonePoseCost3DPointCloudV1:EmptyCandidateFaces', ...
              'Measured point %d has no candidate mesh faces.', pointIndex);
    end

    currentCandidateFaces                 = boneMeshFaces(currentCandidateFaceIndices, :);
    candidateFaceCountByPoint(pointIndex) = numel(currentCandidateFaceIndices);

    [pointToSurfaceDistancesMm(pointIndex), ...
     closestBonePointsRef(pointIndex, :)] = distancePointMesh( ...
        boneSurfacePointsRef(pointIndex, :), ...
        boneMeshVerticesRef, ...
        currentCandidateFaces, ...
        'algorithm', 'vectorized');
end

correspondenceRuntimeSeconds = toc(correspondenceTimer);

% Invalid correspondence output indicates a geometry or dependency problem,
% so it should stop the development run instead of hiding the problem.
if any(~isfinite(pointToSurfaceDistancesMm)) || ...
        any(pointToSurfaceDistancesMm < 0) || ...
        any(~isfinite(closestBonePointsRef), 'all')
    error('bonePoseCost3DPointCloudV1:InvalidCorrespondence', ...
          'The KNN candidate-face search produced an invalid correspondence.');
end

% Confirm that the external helper's distance agrees with its returned point.
reconstructedDistancesMm = vecnorm(boneSurfacePointsRef - closestBonePointsRef, 2, 2);
distanceAgreementToleranceMm = 1e-9;
if any(abs(reconstructedDistancesMm - pointToSurfaceDistancesMm) > distanceAgreementToleranceMm)
    error('bonePoseCost3DPointCloudV1:DistanceMismatch', ...
          'A reported distance does not match its point correspondence.');
end

%% CALCULATE THE COST AND PER-MEASUREMENT STATISTICS

% Pool every measured point with equal weight and use RMSE as the scalar
% objective. Squaring makes larger surface mismatches contribute more strongly.
cost = sqrt(mean(pointToSurfaceDistancesMm .^ 2));

closestBonePointsRefCells      = cell(numberOfMeasurements, 1);
pointToSurfaceDistanceMmCells  = cell(numberOfMeasurements, 1);
meanDistanceMmByMeasurement    = nan(numberOfMeasurements, 1);
rmseDistanceMmByMeasurement    = nan(numberOfMeasurements, 1);
maximumDistanceMmByMeasurement = nan(numberOfMeasurements, 1);

firstPointIndex = 1;
for measurementIndex = 1:numberOfMeasurements
    currentPointCount   = numberOfSurfacePointsByMeasurement(measurementIndex);
    currentPointIndices = firstPointIndex:(firstPointIndex + currentPointCount - 1);

    currentDistancesMm                              = pointToSurfaceDistancesMm(currentPointIndices);
    closestBonePointsRefCells{measurementIndex}     = closestBonePointsRef(currentPointIndices, :);
    pointToSurfaceDistanceMmCells{measurementIndex} = currentDistancesMm;

    if ~isempty(currentDistancesMm)
        meanDistanceMmByMeasurement(measurementIndex)    = mean(currentDistancesMm);
        rmseDistanceMmByMeasurement(measurementIndex)    = sqrt(mean(currentDistancesMm .^ 2));
        maximumDistanceMmByMeasurement(measurementIndex) = max(currentDistancesMm);
    end

    firstPointIndex = firstPointIndex + currentPointCount;
end

%% PACKAGE DETAILS FOR THE DEMO AND FUTURE OPTIMIZER RESULTS

% Store the same frame-explicit candidate geometry pattern used by the
% production intensity cost model.
details.T_CT_ref_candidate   = T_CT_ref_candidate;
details.T_bone_ref_candidate = T_bone_ref_candidate;
details.boneMeshRefCandidate = boneMeshRefCandidate;

% Store flattened correspondences for global inspection and grouped values
% for tracing an unusual result back to one ultrasound measurement.
details.boneSurfacePointsRef                     = boneSurfacePointsRef;
details.closestBonePointsRef                     = closestBonePointsRef;
details.pointToSurfaceDistancesMm                = pointToSurfaceDistancesMm;
details.closestBonePointsRefCells                = closestBonePointsRefCells;
details.pointToSurfaceDistanceMmCells            = pointToSurfaceDistanceMmCells;
details.numberOfSurfacePointsByMeasurement       = numberOfSurfacePointsByMeasurement;
details.meanDistanceMmByMeasurement              = meanDistanceMmByMeasurement;
details.rmseDistanceMmByMeasurement              = rmseDistanceMmByMeasurement;
details.maximumDistanceMmByMeasurement           = maximumDistanceMmByMeasurement;

% Store simple global statistics so users can understand the point-cloud
% agreement without recalculating values from the full distance vector.
details.meanPointToSurfaceDistanceMm             = mean(pointToSurfaceDistancesMm);
details.rmsePointToSurfaceDistanceMm             = cost;
details.medianPointToSurfaceDistanceMm           = median(pointToSurfaceDistancesMm);
details.maximumPointToSurfaceDistanceMm          = max(pointToSurfaceDistancesMm);

details.candidateFaceCountByPoint                = candidateFaceCountByPoint;
details.correspondenceRuntimeSeconds             = correspondenceRuntimeSeconds;
details.costSettings.correspondenceMethod        = 'knn_candidate_faces';
details.costSettings.requestedNearestVertexCount = double(nearestVertexCount);
details.costSettings.nearestVertexCount          = nearestVertexCount;
details.status = '3d_point_cloud_rmse_computed';
end
