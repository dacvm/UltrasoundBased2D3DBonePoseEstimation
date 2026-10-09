function [cost, details] = cost_intensityLine_v01(poseVector, data, config)
%COST_INTENSITYLINE_V01 Score how bright the image is where the bone should be.
% For one candidate pose, this cost cuts the CT bone mesh with every
% ultrasound image plane and keeps the parts of the cut that face the probe:
% these are the bone surfaces that ultrasound should show as a bright echo.
% It then reads the smoothed image along those lines. The brighter the image
% under the predicted bone lines, the lower (better) the cost.
%
% Design choices:
%   1. No start-pose reference. The start pose is only a rough guess. If
%      the cost compared each candidate with it, the best pose of the cost
%      would depend on where the search started. Every plane is therefore
%      judged only by what the image shows at the candidate pose.
%   2. Continuous sampling. Reading whole pixels along a rasterized line
%      makes the cost jump in small steps as the line crosses pixel borders.
%      The image is instead read at evenly spaced points (every
%      sampleSpacingMm) along the continuous intersection segments, with
%      interpolation between pixels, so the cost changes smoothly with the
%      pose.
%   3. Smoothed images. The bone echo is only about 1 mm thick. On the raw
%      image the cost would be flat as soon as the line is off the echo, and
%      the optimizer would get no hint where to move. The images are blurred
%      by intensitySmoothingSigmaMm (done once in
%      prepareBonePoseOptimizationInputs), so a line near the echo still
%      reads part of it and the cost points toward the bone.
%
% Cost:
%   For plane i, evidence_i is the mean blurred intensity at the sample
%   points, divided by intensityMax so it lies in [0, 1]. A plane where the
%   probe-facing bone does not cross the image has no sample points and gets
%   evidence_i = 0: the pose explains nothing in that image. Every plane
%   counts equally, so
%
%       cost = 1 - mean over all planes of evidence_i
%
%   The cost lies in [0, 1]. 0 would mean every predicted bone line lies on
%   pixels at intensityMax; 1 means no evidence at all. Writing it as
%   "1 - evidence" instead of "-evidence" does not move the best pose; it
%   only gives the same "0 is perfect, larger is worse" reading as the
%   other cost models.
%
% Inputs:
%   poseVector - Six-value perturbation around data.T_CT_ref_initial.
%   data       - Prepared data from prepareBonePoseOptimizationInputs. It
%                must contain data.extra.intensityLine.smoothedImages, which
%                preparation builds when the config sets
%                intensitySmoothingSigmaMm.
%   config     - Scalar runtime configuration whose cost.parameters holds
%                intensityMax, sampleSpacingMm, and
%                intensitySmoothingSigmaMm.
%
% Outputs:
%   cost       - Scalar in [0, 1]; lower is better.
%   details    - Candidate geometry, per-plane evidence, sample counts and
%                sample points, the mean evidence, and the settings used.

%% BUILD THE CANDIDATE POSE

% Convert the optimizer state into the transform that places the CT mesh in ref.
T_CT_ref_candidate   = stateVectorToTMatrix(poseVector, data.T_CT_ref_initial);
T_bone_ref_candidate = T_CT_ref_candidate * data.T_bone_CT;

%% FIND WHERE THE BONE SHOULD APPEAR IN EVERY IMAGE

% Cut the mesh with every image plane and keep only the probe-facing parts.
% probeFacingSegmentsUV holds the kept parts as straight segments in plane
% coordinates (mm), already clipped to the image area.
[poseEvaluation, boneMeshRefCandidate] = computeProbeFacingPixelsForPose( ...
    data.boneMeshCT, data.imagePlanesRef, T_CT_ref_candidate, config);

%% READ THE SMOOTHED IMAGE ALONG THE PREDICTED BONE LINES

costParameters = config.cost.parameters;
smoothedImages = data.extra.intensityLine.smoothedImages;
nPlanes        = numel(data.imagePlanesRef);

% A plane that keeps the initial zero has no visible bone at this pose.
perPlaneEvidence    = zeros(1, nPlanes);
perPlaneSampleCount = zeros(1, nPlanes);
perPlaneSampleUV    = cell(1, nPlanes);

for planeIndex = 1:nPlanes
    plane      = data.imagePlanesRef(planeIndex);
    segmentsUV = poseEvaluation(planeIndex).probeFacingSegmentsUV;

    % --- Step 1: place evenly spaced sample points along the bone line ---
    % - The predicted bone line in this image is a chain of short straight
    %   segments. 
    % - Each segment is a 2-by-2 array: row 1 is its start point and
    %   row 2 its end point, both as [u v] in mm (u along the image width, 
    %   v along the image height). 
    % - We walk along every segment and put points on it so that no two 
    %   neighbouring points are more than sampleSpacingMm apart. 
    % - Every segment gets at least its two endpoints. 
    % - Because points are spread by length, a long segment gets more 
    %   points than a short one, so it also counts more in this plane's 
    %   mean below. 
    % - The result, sampleUV, is an M-by-2 list of [u v] points in mm; 
    %   it stays empty when the bone does not cross this image.
    sampleUV = zeros(0, 2);
    for segmentIndex = 1:numel(segmentsUV)
        % Read the two endpoints of this segment, each as a 1-by-2 [u v] in mm.
        startUV = segmentsUV{segmentIndex}(1, :);
        endUV   = segmentsUV{segmentIndex}(2, :);

        % Decide how many points this segment needs. Dividing its length by
        % the spacing gives the number of gaps; one more than that is the
        % number of points (e.g. 0.35 mm at 0.1 mm spacing -> 4 gaps -> 5
        % points, so each gap is 0.0875 mm, never more than 0.1 mm). A very
        % short segment still gets at least its two endpoints.
        segmentLengthMm = norm(endUV - startUV);
        nPoints         = max(2, ceil(segmentLengthMm / costParameters.sampleSpacingMm) + 1);

        % Evenly spaced fractions of the way along the segment, as a column:
        % 0 is the start point and 1 is the end point.
        fractions       = linspace(0, 1, nPoints).';

        % Turn each fraction into a point: start + fraction * (end - start).
        % Each row of fractions times the 1-by-2 direction gives one [u v]
        % point, so this adds an nPoints-by-2 block to the plane's list.
        sampleUV = [sampleUV; startUV + fractions .* (endUV - startUV)];
    end
    perPlaneSampleUV{planeIndex}    = sampleUV;
    perPlaneSampleCount(planeIndex) = size(sampleUV, 1);

    % No sample points means no visible bone: keep this plane's evidence at 0.
    if isempty(sampleUV)
        continue;
    end

    % Step 2: Convert the sample points from mm to pixel positions --------
    % - The image only has values at pixel centres, so we need each point's
    %   position in pixel units. 
    % - Pixel k covers the range [(k-1), k] * pixel size, so its centre 
    %   lies at (k - 0.5) * pixel size. 
    % - Turning this around gives: 
    %   pixel position = position in mm / pixel size + 0.5.
    % - The result is a continuous (non-integer) position, 
    %   for example 12.3 means "30% of the way from the centre of pixel 12 
    %   to that of pixel 13".
    pixelWidthMm   = plane.W / plane.nCols;
    pixelHeightMm  = plane.H / plane.nRows;
    columnPosition = sampleUV(:, 1) / pixelWidthMm  + 0.5;
    rowPosition    = sampleUV(:, 2) / pixelHeightMm + 0.5;

    % The segments are already clipped to the image, but a point exactly on
    % the outer image edge lies half a pixel beyond the outermost pixel
    % centre, where there is no value to interpolate (interp2 would return NaN). 
    % Moving such a point onto the nearest pixel centre reads the edge
    % pixel, which is also what the pixel rasterizer does.
    columnPosition = min(max(columnPosition, 1), plane.nCols);
    rowPosition    = min(max(rowPosition, 1), plane.nRows);

    % Step 3: Read the smoothed image at those positions ------------------
    % - Linear interpolation blends the four surrounding pixel values by
    %   distance, so the read value changes smoothly when a point moves by
    %   less than a pixel. That keeps the cost smooth in the pose.
    % - Note the argument order: interp2(V, x, y) takes x along the SECOND
    %   dimension of V and y along the FIRST. Images in this pipeline are
    %   stored as [column, row], so the first dimension is the column: x is
    %   therefore the row position and y the column position.
    sampledIntensities = interp2(smoothedImages{planeIndex}, rowPosition, columnPosition, 'linear');

    % Step 4: summarize the plane as one evidence value in [0, 1] ---------
    % The mean over all points along the line, divided by intensityMax, so
    % that 1 means "the whole line lies on maximally bright pixels".
    perPlaneEvidence(planeIndex) = mean(sampledIntensities) / costParameters.intensityMax;
end

%% TURN THE EVIDENCE INTO A COST

% Every plane is weighted the same, whatever the length of its bone line.
% Weighting by sample count instead would let a few planes with long lines
% dominate, and a pose could then ignore the images with short lines.
meanEvidence = mean(perPlaneEvidence);
cost         = 1 - meanEvidence;

%% PACKAGE DETAILS FOR INSPECTION

% Keep the common geometry at the top level, where evaluation code expects it.
details.T_CT_ref_candidate   = T_CT_ref_candidate;
details.T_bone_ref_candidate = T_bone_ref_candidate;
details.boneMeshRefCandidate = boneMeshRefCandidate;
details.poseEvaluation       = poseEvaluation;

details.perPlaneEvidence     = perPlaneEvidence;      % Mean normalized smoothed intensity per plane, in [0, 1].
details.perPlaneSampleCount  = perPlaneSampleCount;   % Number of sample points per plane; 0 means no visible bone.
details.perPlaneSampleUV     = perPlaneSampleUV;      % [u v] sample points in mm per plane, to show where the image was read.
details.meanEvidence         = meanEvidence;          % Mean of perPlaneEvidence; cost = 1 - meanEvidence.
details.costSettings         = costParameters;
details.status               = 'smoothed_intensity_cost_computed';
end
