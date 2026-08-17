function surfaceRmseMm = calculateSurfaceRmseMm(boneMeshRefGroundTruth, boneMeshRefEstimate)
%CALCULATESURFACERMSEMM Calculate corresponding bone-surface point error.
% This function measures the RMS distance between matching vertices on the
% ground-truth and estimated bone meshes. Direct correspondence is used so
% rotational errors cannot be hidden by a nearest-neighbour search.
%
% Inputs:
%   boneMeshRefGroundTruth - Ground-truth triangulation in the reference frame.
%   boneMeshRefEstimate    - Estimated triangulation in the reference frame.
%
% Output:
%   surfaceRmseMm          - RMS corresponding-vertex distance in millimetres.

% Both meshes must come from the same source model for row-wise comparison.
if ~isa(boneMeshRefGroundTruth, 'triangulation') || ...
        ~isa(boneMeshRefEstimate, 'triangulation')
    error('calculateSurfaceRmseMm:ExpectedTriangulation', ...
        'Both bone meshes must be triangulation objects.');
end

% Matching connectivity confirms that the two vertex arrays share one ordering.
if ~isequal(boneMeshRefGroundTruth.ConnectivityList, ...
            boneMeshRefEstimate.ConnectivityList) || ...
        ~isequal(size(boneMeshRefGroundTruth.Points), ...
                 size(boneMeshRefEstimate.Points))
    error('calculateSurfaceRmseMm:MeshCorrespondenceMismatch', ...
        'Ground-truth and estimated meshes must have matching vertices and connectivity.');
end

% Calculate one 3D displacement magnitude for every corresponding vertex.
vertexDifferenceRef = ...
    boneMeshRefEstimate.Points - boneMeshRefGroundTruth.Points;
vertexSquaredDistance = sum(vertexDifferenceRef.^2, 2);

% Combine all surface-point errors into one value used for run ranking.
surfaceRmseMm = sqrt(mean(vertexSquaredDistance));
end
