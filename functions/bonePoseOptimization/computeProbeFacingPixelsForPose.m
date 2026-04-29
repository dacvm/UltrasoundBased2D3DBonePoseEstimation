function [poseEvaluation, mesh] = computeProbeFacingPixelsForPose(meshVerticesLocal, meshFaces, planes, T_mesh_ref, config)
%COMPUTEPROBEFACINGPIXELSFORPOSE Compute probe-facing mesh-plane pixels for one mesh pose.
% This function declaration defines the reusable geometry step that the future cost function will call repeatedly.
%
% What this function does:
%   This function evaluates one candidate pose of the 3D mesh. It transforms
%   the mesh into the reference frame, intersects that transformed mesh with
%   every stored ultrasound image plane, then keeps only the intersection
%   pixels that come from mesh faces facing the probe.
%
% Why this function exists:
%   The future cost function needs this same geometry operation many times:
%   try a pose, find where the mesh crosses the ultrasound images, select
%   the probe-facing part, and then sample image intensity at those pixels.
%   By keeping this logic in one function, the cost function can stay small
%   and focused on intensity scoring.
%
% Inputs:
%   meshVerticesLocal:
%       Nv-by-3 vertex array for the original mesh before candidate pose
%       transformation.
%
%   meshFaces:
%       Nf-by-3 triangle index array for the mesh.
%
%   planes:
%       Struct array of ultrasound image planes prepared by
%       prepareBonePoseOptimizationInputs.
%
%   T_mesh_ref:
%       4-by-4 rigid transform that places the mesh into the same reference
%       frame as the image planes.
%
%   config:
%       Nested configuration struct. This function mainly uses
%       config.intersection.normalFacingToleranceDeg and
%       config.logging.printEvaluationProgress.
%
% Outputs:
%   poseEvaluation:
%       One struct per image plane. The most important field is
%       poseEvaluation(idx).probeFacingPixels, which stores [row, col]
%       image pixels selected for the future intensity-based cost.
%
%   mesh:
%       The transformed mesh struct with fields V and F. This is useful for
%       debugging because it shows the exact mesh pose that was evaluated.
%
% Important details for junior developers:
%   - meshPlaneIntersectionPixels finds all mesh-plane intersections.
%   - selectProbeFacingIntersectionSegments filters those intersections to
%     the probe-facing mesh surface.
%   - This function should not plot anything, because an optimizer may call
%     it hundreds or thousands of times.

%% HANDLE OPTIONAL CONFIGURATION

% Create default settings when the caller does not provide a configuration struct.
if nargin < 5 || isempty(config)
    config = createBonePoseOptimizationConfig();
end

%% TRANSFORM MESH TO THE REFERENCE FRAME

% Apply the candidate rigid pose to the original local mesh vertices.
mesh.V = applyRigidTransform(meshVerticesLocal, T_mesh_ref);
% Reuse the same face connectivity because rigid motion does not change mesh topology.
mesh.F = meshFaces;

%% PREPARE OUTPUT STRUCTURE

% Count image planes once because every plane receives one evaluation result.
n_planes = numel(planes);

% Preallocate one result struct per image plane so outputs stay aligned with inputs.
poseEvaluation = repmat(struct('mask', [], 'pixelList', [], 'segments3D', {{}}, 'segmentsUV', {{}}, ...
                               'segmentFaceIdx', [], 'probeFacingSegmentMask', [], 'probeFacingSegments3D', {{}}, ...
                               'probeFacingSegmentsUV', {{}}, 'probeFacingPixels', [], 'segmentFacingScore', [], ...
                               'timestamp', []), 1, n_planes);

%% COMPUTE INTERSECTIONS FOR EACH IMAGE PLANE

% Loop through every stored image plane and compute the selected intersection pixels.
for idx_plane = 1:n_planes
    % Read the current plane once so this loop body always uses one consistent observation.
    plane = planes(idx_plane);

    % Compute all mesh-plane intersections and their rasterized pixel locations.
    [mask, pixelList, segments3D, segmentsUV, segmentFaceIdx] = meshPlaneIntersectionPixels(mesh, plane);

    % Compute the physical pixel width used to convert UV coordinates to image columns and.
    du = plane.W / plane.nCols;
    dv = plane.H / plane.nRows;

    % Keep only the intersection segments whose source mesh faces point toward the probe.
    [probeFacingSegmentMask, probeFacingSegments3D, probeFacingSegmentsUV, probeFacingPixels, segmentFacingScore] = ...
        selectProbeFacingIntersectionSegments(mesh, segments3D, segmentsUV, segmentFaceIdx, plane, ...
                                             du, dv, plane.nRows, plane.nCols, config.intersection.normalFacingToleranceDeg);

    % Store the necessary values 
    poseEvaluation(idx_plane).mask                   = mask;                    % Full binary hit mask for optional debugging.
    poseEvaluation(idx_plane).pixelList              = pixelList;               % Every hit pixel before probe-facing selection for optional comparison.
    poseEvaluation(idx_plane).segments3D             = segments3D;              % 3D intersection segments before probe-facing selection for optional debugging.
    poseEvaluation(idx_plane).segmentsUV             = segmentsUV;              % UV intersection segments before probe-facing selection for optional debugging.
    poseEvaluation(idx_plane).segmentFaceIdx         = segmentFaceIdx;          % Face indices so each segment can be traced back to the source mesh face.
    poseEvaluation(idx_plane).probeFacingSegmentMask = probeFacingSegmentMask;  % Logical mask that marks which segments passed the probe-facing test.
    poseEvaluation(idx_plane).probeFacingSegments3D  = probeFacingSegments3D;   % Selected 3D segments because they describe the visible curve in physical space.
    poseEvaluation(idx_plane).probeFacingSegmentsUV  = probeFacingSegmentsUV;   % Selected UV segments because they are useful for image-space debugging.
    poseEvaluation(idx_plane).probeFacingPixels      = probeFacingPixels;       % Selected image pixels because this is the key output needed by the future cost function.
    poseEvaluation(idx_plane).segmentFacingScore     = segmentFacingScore;      % Facing score so the future code can inspect how strongly each segment faced the probe.
    poseEvaluation(idx_plane).timestamp              = plane.timestamp;         % Timestamp so the result can be mapped back to its source image plane.

    % Print a short progress line only when enabled because optimization may evaluate many poses.
    if config.logging.printEvaluationProgress
        fprintf('[Plane %d/%d] %d probe-facing pixels.\n', idx_plane, n_planes, size(probeFacingPixels, 1));
    end
end
end
