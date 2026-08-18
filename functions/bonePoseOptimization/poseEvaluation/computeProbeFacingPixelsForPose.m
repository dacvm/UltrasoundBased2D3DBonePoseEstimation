function [poseEvaluation, boneMeshRefCandidate] = ...
        computeProbeFacingPixelsForPose(boneMeshCT, imagePlanesRef, ...
        T_CT_ref_candidate, config)
%COMPUTEPROBEFACINGPIXELSFORPOSE Intersect one candidate bone pose with images.
% This function transforms the fixed CT mesh into the reference frame,
% intersects it with every fixed ultrasound plane, and keeps intersection
% pixels produced by probe-facing mesh triangles.
%
% Inputs:
%   boneMeshCT         - Source bone triangulation in CT coordinates.
%   imagePlanesRef     - Ultrasound plane struct array in reference coordinates.
%   T_CT_ref_candidate - Candidate 4-by-4 transform from CT to reference.
%   config             - Optimization configuration containing intersection
%                        tolerance and logging settings.
%
% Outputs:
%   poseEvaluation      - Per-plane intersection geometry and selected pixels.
%   boneMeshRefCandidate - Candidate triangulation in reference coordinates.

%% TRANSFORM THE CT MESH

% Transform only vertex coordinates because rigid motion preserves connectivity.
bonePointsRefCandidate = applyRigidTransform( ...
    boneMeshCT.Points, T_CT_ref_candidate);
boneMeshRefCandidate = triangulation( ...
    boneMeshCT.ConnectivityList, bonePointsRefCandidate);

% Existing intersection helpers use simple V and F fields for repeated geometry work.
meshForIntersection.V = bonePointsRefCandidate;
meshForIntersection.F = boneMeshCT.ConnectivityList;

%% COMPUTE ONE RESULT PER IMAGE PLANE

% Preallocate the complete result shape so every output stays aligned with its plane.
nPlanes = numel(imagePlanesRef);
poseEvaluation = repmat(struct( ...
    'mask', [], ...
    'pixelList', [], ...
    'segments3D', {{}}, ...
    'segmentsUV', {{}}, ...
    'segmentFaceIdx', [], ...
    'probeFacingSegmentMask', [], ...
    'probeFacingSegments3D', {{}}, ...
    'probeFacingSegmentsUV', {{}}, ...
    'probeFacingPixels', [], ...
    'segmentFacingScore', [], ...
    'timestamp', []), 1, nPlanes);

for planeIndex = 1:nPlanes
    % Read one fixed observation for all geometry calculated in this iteration.
    plane = imagePlanesRef(planeIndex);

    % Find and rasterize every finite intersection before surface-facing filtering.
    [mask, pixelList, segments3D, segmentsUV, segmentFaceIdx] = ...
        meshPlaneIntersectionPixels(meshForIntersection, plane);

    % Convert physical UV distances to the stored image grid used by the selector.
    pixelWidth = plane.W / plane.nCols;
    pixelHeight = plane.H / plane.nRows;

    % Keep only segments whose source triangle faces toward the ultrasound probe.
    [probeFacingSegmentMask, probeFacingSegments3D, ...
        probeFacingSegmentsUV, probeFacingPixels, segmentFacingScore] = ...
        selectProbeFacingIntersectionSegments( ...
        meshForIntersection, segments3D, segmentsUV, segmentFaceIdx, ...
        plane, pixelWidth, pixelHeight, plane.nRows, plane.nCols, ...
        config.intersection.normalFacingToleranceDeg);

    % Package raw and filtered geometry so cost and display code share one evaluation.
    poseEvaluation(planeIndex).mask = mask;
    poseEvaluation(planeIndex).pixelList = pixelList;
    poseEvaluation(planeIndex).segments3D = segments3D;
    poseEvaluation(planeIndex).segmentsUV = segmentsUV;
    poseEvaluation(planeIndex).segmentFaceIdx = segmentFaceIdx;
    poseEvaluation(planeIndex).probeFacingSegmentMask = probeFacingSegmentMask;
    poseEvaluation(planeIndex).probeFacingSegments3D = probeFacingSegments3D;
    poseEvaluation(planeIndex).probeFacingSegmentsUV = probeFacingSegmentsUV;
    poseEvaluation(planeIndex).probeFacingPixels = probeFacingPixels;
    poseEvaluation(planeIndex).segmentFacingScore = segmentFacingScore;
    poseEvaluation(planeIndex).timestamp = plane.timestamp;

    % Keep repeated progress optional because optimizers may call this many times.
    if config.logging.printEvaluationProgress
        fprintf('[Plane %d/%d] %d probe-facing pixels.\n', ...
            planeIndex, nPlanes, size(probeFacingPixels, 1));
    end
end
end
