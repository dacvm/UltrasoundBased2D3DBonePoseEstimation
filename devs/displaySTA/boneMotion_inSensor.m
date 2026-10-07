% BONEMOTION_INSENSOR  Animate bone motion as seen from the ultrasound image.
%
% WHAT THIS SCRIPT SHOWS
% Normally we look at a tracked ultrasound recording from the tracker's point
% of view (the ref frame): the probe moves and the bone moves. This script
% instead "sits on the ultrasound image": the image is held still, and the CT
% bone mesh moves relative to it. This makes it easy to see how the bone
% slides and how its depth below the probe changes over time.
%
% It also compares two estimates of the bone depth below the probe:
%   - EXTRACTED depth (green): from the bone surface detected in the
%     ultrasound pixels by the bone segmentation tool.
%   - GROUND-TRUTH depth (magenta): from where the tracked CT bone mesh
%     actually crosses the image plane.
%
% LOGICAL FLOW (one %% section per step)
%   1. SETTINGS: playback, recording, delay, and smoothing options.
%   2. LOAD: the ultrasound recording with its intersections, the bone poses,
%      and the extracted bone surfaces.
%   3. MATCH: link every ultrasound frame to its bone pose and its extracted
%      surface record.
%   4. SMOOTH: reduce tracking jitter in the probe/image and bone trajectories.
%   5. PAIR: correct for the delay between motion and ultrasound pixels by
%      pairing each pose with a slightly later image.
%   6. RECONSTRUCT: turn both bone surfaces into mm points in the image frame
%      and compute their depth statistics.
%   7. RELATIVE MOTION: compute where the bone is relative to the image.
%   8. AXES LIMITS: fix the 3D view so it does not jump during playback.
%   9. FIGURE: create every graphic object once (3D scene + distance plot).
%  10. ANIMATE: for each frame, only update the data inside those objects.
%
% Frames and transforms follow the project convention:
%   p_target = T_source_target * p_source, with frames CT, ref, and image.

clear; clc; close all;

%% SETTINGS

% Use a fixed delay between displayed frames. This controls playback speed only;
% it does not change the acquisition timestamps used for temporal alignment.
frameDelaySeconds = 0.05;

% Set this to true to record the complete figure as an MP4 video. Set it to
% false when only an interactive visualization is needed. While it is false,
% MATLAB's Code Analyzer may warn that the recording branches are unreachable;
% that is expected.
recordVisualization = false;

% A positive value means that ultrasound pixels were recorded this many seconds
% after the physical motion that produced them. The script therefore displays a
% later recorded image together with the corresponding earlier rigid-body pose.
temporalDelaySeconds = 0.12;

% Smooth both tracked pose sequences before calculating relative bone motion.
% These settings follow smoothTransformations_demo.m.
smoothingMethod = 'sgolay';
smoothingWindow = 15;

%% LOAD THE ULTRASOUND, BONE, AND EXTRACTED-SURFACE DATA

% Find the project root from this script so it can be run from any MATLAB folder.
% The script lives in <root>/devs/displaySTA, so the root is two folders up.
scriptDirectory = fileparts(mfilename('fullpath'));
projectRoot     = fileparts(fileparts(scriptDirectory));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Output of the ultrasound spatial processing tool. It holds, per ultrasound
% frame, the image plane placed in ref and its bone-mesh intersection
% (validSnapshots), plus the CT bone meshes and their poses (validBonePoses).
snapshotFilePath = fullfile(projectRoot, 'tools', ...
    'ultrasoundSpatialProcessing', 'outputs', ...
    'validSnapshots_20260919_110840_meas04c.mat');
snapshotData = load(snapshotFilePath, 'validSnapshots', 'validBonePoses');

% Output of the bone segmentation tool: the bone surface detected in each
% ultrasound image, stored as pixel coordinates.
surfaceFilePath = fullfile(projectRoot, 'tools', ...
    'boneSegmentationProcess', 'outputs', ...
    'boneSurface_20260921_172157.mat');
surfaceData = load(surfaceFilePath, 'surfaceResults');

% Select the reviewed ultrasound sequence and its CT mesh/pose sequence.
% Only the first source folder (group 1) is visualized. Its bone code ('F' or
% 'T') tells us which CT bone belongs to it.
snapshotGroup  = snapshotData.validSnapshots(1);
frameRecords   = snapshotGroup.data;
boneCode       = string(snapshotGroup.bone);
numberOfFrames = numel(frameRecords);

% Find the CT bone with the same bone code. Its data array holds one pose per
% time row (perDataRow mode).
availableBoneCodes = string({snapshotData.validBonePoses.bonePoses.bone});
bonePoseIndex      = find(availableBoneCodes == boneCode, 1);
bonePose           = snapshotData.validBonePoses.bonePoses(bonePoseIndex);
poseRecords        = bonePose.data;

% Select the extracted-surface group describing the same acquisition and bone.
% Groups are identified by their source-folder name and bone code.
surfaceGroupNames = string({surfaceData.surfaceResults.name});
surfaceGroupBones = string({surfaceData.surfaceResults.bone});
surfaceGroupIndex = find( ...
    surfaceGroupNames == string(snapshotGroup.name) & ...
    surfaceGroupBones == boneCode, 1);
surfaceRecords = surfaceData.surfaceResults(surfaceGroupIndex).data;

%% MATCH EACH ULTRASOUND FRAME TO ITS BONE POSE AND SURFACE RECORD

% Reviewed frame numbers can skip original acquisition rows. Match records by
% their stored identities instead of assuming unrelated arrays share an index.
% The result is two lookup tables: for ultrasound frame k,
%   poseRecords(poseIndexByFrame(k))       is its bone pose, and
%   surfaceRecords(surfaceIndexByFrame(k)) is its extracted surface.
poseIndexByFrame     = zeros(1, numberOfFrames);
surfaceIndexByFrame  = zeros(1, numberOfFrames);
surfaceSourceIndices = [surfaceRecords.sourceIndex];

for frameIndex = 1:numberOfFrames
    currentPlane = frameRecords(frameIndex).plane;

    % A bone pose belongs to this frame when it comes from the same source
    % folder, the same MHA/CSV pair, and the same CSV row. Exactly one pose
    % must match; anything else means the input files are inconsistent.
    poseMatches = ...
        [poseRecords.snapshotIndex] == currentPlane.snapshotIndex & ...
        [poseRecords.sequenceIndex] == currentPlane.sequenceIndex & ...
        [poseRecords.rigidBodyRowIndex] == currentPlane.rigidBodyRowIndex;
    matchingPoseIndex = find(poseMatches);
    if numel(matchingPoseIndex) ~= 1
        error('Expected one matching bone pose for ultrasound frame %d.', frameIndex);
    end
    poseIndexByFrame(frameIndex) = matchingPoseIndex;

    % The segmentation tool stored the same sourceIndex as the ultrasound
    % record it processed, so sourceIndex links the two.
    frameSourceIndex = frameRecords(frameIndex).sourceIndex;
    surfaceIndexByFrame(frameIndex) = find(surfaceSourceIndices == frameSourceIndex, 1);

end

%% SMOOTH THE IMAGE AND BONE POSE SEQUENCES

% T_image_ref maps image -> ref, while T_CT_ref maps CT -> ref. Build and
% smooth the two trajectories separately before combining their relative motion.
% Each trajectory is stored as a 4x4xN stack: page k is the transform at frame k.
imageTransformsRef = zeros(4, 4, numberOfFrames);
boneTransformsRef = zeros(4, 4, numberOfFrames);

for frameIndex = 1:numberOfFrames
    currentPlane = frameRecords(frameIndex).plane;
    currentPose  = poseRecords(poseIndexByFrame(frameIndex));

    imageTransformsRef(:, :, frameIndex) = currentPlane.T_image_ref;
    boneTransformsRef(:, :, frameIndex)  = currentPose.T_CT_ref;
end

% Raw optical tracking has small frame-to-frame jitter. Without smoothing, the
% bone would visibly shake in the animation. Smoothing each trajectory over
% time removes this jitter while keeping the real motion.
imageTransformsRefSmoothed = smoothTransformations( ...
    imageTransformsRef, ...
    'method', smoothingMethod, ...
    'window', smoothingWindow);

boneTransformsRefSmoothed = smoothTransformations( ...
    boneTransformsRef, ...
    'method', smoothingMethod, ...
    'window', smoothingWindow);

%% PAIR EACH EARLIER POSE WITH ITS DELAYED ULTRASOUND IMAGE

% If an image is delayed, pixels showing the event at pose time t are stored near
% t + delay. Keep the two rigid-body poses at time t, but select pixels and the
% extracted surface from the nearest later image timestamp.
allPlanes        = [frameRecords.plane];
recordedTimes    = double([allPlanes.timestamp]);
targetImageTimes = recordedTimes + temporalDelaySeconds;

% Near the end of the recording, t + delay falls after the last image, so
% those poses have no matching image. Keep only the poses whose target image
% time lies inside the recording. These kept poses become the "displayed
% frames" of the animation.
hasAvailableImage = ...
    targetImageTimes >= recordedTimes(1) & ...
    targetImageTimes <= recordedTimes(end);
poseIndexByDisplayedFrame = find(hasAvailableImage);
numberOfDisplayedFrames = numel(poseIndexByDisplayedFrame);

if numberOfDisplayedFrames == 0
    error('The temporal delay leaves no overlapping pose and image data.');
end

% For each displayed frame, pick the recorded image whose timestamp is closest
% to t + delay. pairedDelaySeconds stores the delay actually achieved, which can
% differ slightly from temporalDelaySeconds because images come at discrete
% times. It is shown in the figure title.
imageIndexByDisplayedFrame = zeros(1, numberOfDisplayedFrames);
pairedDelaySeconds         = zeros(1, numberOfDisplayedFrames);

for displayedFrameIndex = 1:numberOfDisplayedFrames
    poseFrameIndex       = poseIndexByDisplayedFrame(displayedFrameIndex);
    targetImageTime      = targetImageTimes(poseFrameIndex);
    [~, imageFrameIndex] = min(abs(recordedTimes - targetImageTime));

    imageIndexByDisplayedFrame(displayedFrameIndex) = imageFrameIndex;
    pairedDelaySeconds(displayedFrameIndex) = recordedTimes(imageFrameIndex) - recordedTimes(poseFrameIndex);
end

% Surface extraction belongs to the delayed image pixels, so use the surface
% record associated with imageFrameIndex rather than poseFrameIndex.
surfaceIndexByDisplayedFrame = ...
    surfaceIndexByFrame(imageIndexByDisplayedFrame);

%% RECONSTRUCT SURFACE POINTS IN THE LOCAL IMAGE FRAME

% This section builds two bone surfaces for every displayed frame, both as
% physical [X_image, Y_image, 0] points in mm:
%
%   1. EXTRACTED surface: detected in the ultrasound pixels
%      (surfaceRecords.surfaceCoordinatesXY).
%   2. GROUND-TRUTH surface: the part of the CT bone mesh that the image plane
%      cuts and that faces the probe (intersection.probeFacingPixels). This is
%      the surface ultrasound can actually show; the raw intersection would
%      also include the far side of the bone.
%
% Both use the same pixel-to-mm conversion, (pixelIndex - 1) * pixelSpacing,
% so they can be plotted directly in this image-frame scene without any
% tracking pose. Because the image origin is the sensor-side edge, Y_image is
% the depth from the sensor. Its mean and standard deviation per frame give
% the depth statistics: dest_bone_* (extracted) and dgt_bone_* (ground truth).
%
% WHY THE GROUND TRUTH USES poseFrameIndex, NOT imageFrameIndex
%
% Each displayed frame combines two acquisition rows:
%   - poseFrameIndex  (time t):         the rigid-body poses, which place the
%                                       bone mesh in this scene.
%   - imageFrameIndex (time t + delay): the ultrasound pixels, and so the
%                                       extracted surface.
% The delay is a property of the PIXELS only: the pixels stored at t + delay
% show the bone as it was at time t. Pairing the two rows shifts the pixels
% back so that the image, the extracted surface, and the displayed mesh all
% describe the same physical moment t.
%
% The intersection contains NO pixels. The intersection tool computed it
% purely from the plane pose and bone pose of its own row (CT mesh cut by the
% image plane), without any delay. So intersection(poseFrameIndex) describes
% moment t, which is the same moment as the displayed mesh and the
% delay-corrected image. In the 3D scene it lies on the displayed mesh, up to
% the small difference between raw and smoothed poses.
%
% Using intersection(imageFrameIndex) instead would describe the bone at
% t + delay. It would sit off the displayed mesh, and in dplotAxes the
% ground-truth curve would shift by the delay (about 4 rows here) relative to
% the extracted curve. That would bring back the lag the pairing above
% removes, and the depth comparison would mix two moments.
%
% A useful side effect: the extracted curve (pixels) and the ground-truth
% curve (poses) are aligned only through temporalDelaySeconds. If their dips
% consistently lead or lag each other, the delay setting is off.
%
% Point clouds have a different number of points per frame, so they are stored
% in cell arrays (one cell per displayed frame). The statistics are one number
% per frame, so they are stored in plain row vectors.
surfacePointsImageByDisplayedFrame = cell(1, numberOfDisplayedFrames);
dest_bone_mean = zeros(1, numberOfDisplayedFrames);
dest_bone_std  = zeros(1, numberOfDisplayedFrames);

groundTruthPointsImageByDisplayedFrame = cell(1, numberOfDisplayedFrames);
dgt_bone_mean = zeros(1, numberOfDisplayedFrames);
dgt_bone_std  = zeros(1, numberOfDisplayedFrames);

for displayedFrameIndex = 1:numberOfDisplayedFrames
    % Look up the two acquisition rows paired for this displayed frame, and
    % the extracted-surface record of the image row.
    poseFrameIndex  = poseIndexByDisplayedFrame(displayedFrameIndex);
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);
    surfaceIndex    = surfaceIndexByDisplayedFrame(displayedFrameIndex);

    % Physical size of one pixel step, shared by both surfaces below.
    % W and H span the distance between the first and last pixel centers, so
    % they are divided by (count - 1) steps, not by the pixel count.
    imagePlane    = frameRecords(imageFrameIndex).plane;
    pixelSpacingX = imagePlane.W / (imagePlane.nCols - 1);
    pixelSpacingY = imagePlane.H / (imagePlane.nRows - 1);

    % --- 1. Extracted surface (from the delayed image, imageFrameIndex) ---
    % surfaceCoordinatesXY is one-based [column, row].
    surfaceCoordinatesXY  = double(surfaceRecords(surfaceIndex).surfaceCoordinatesXY);
    numberOfSurfacePoints = size(surfaceCoordinatesXY, 1);

    % Subtract 1 so pixel 1 lands at 0 mm (the image origin), then scale to
    % mm. Z is 0 because every point lies in the image plane.
    surfacePointsImage = [ ...
        (surfaceCoordinatesXY(:, 1) - 1) * pixelSpacingX, ...
        (surfaceCoordinatesXY(:, 2) - 1) * pixelSpacingY, ...
        zeros(numberOfSurfacePoints, 1)];
    surfacePointsImageByDisplayedFrame{displayedFrameIndex} = surfacePointsImage;

    % Depth from the sensor is the Y_image coordinate of each surface point.
    % The mean is the typical bone depth in this frame; the standard deviation
    % shows how much the depth varies across the image width.
    dest_bone = surfacePointsImage(:, 2);
    dest_bone_mean(displayedFrameIndex) = mean(dest_bone);
    dest_bone_std(displayedFrameIndex)  = std(dest_bone);

    % --- 2. Ground-truth surface (from the pose frame, poseFrameIndex) ---
    % probeFacingPixels is one-based [row, column], the reverse of
    % surfaceCoordinatesXY, so its columns are swapped in the conversion.
    groundTruthPixels = frameRecords(poseFrameIndex).intersection.probeFacingPixels;
    numberOfGroundTruthPoints = size(groundTruthPixels, 1);

    % Same pixel-to-mm conversion as the extracted surface above.
    groundTruthPointsImage = [ ...
        (groundTruthPixels(:, 2) - 1) * pixelSpacingX, ...
        (groundTruthPixels(:, 1) - 1) * pixelSpacingY, ...
        zeros(numberOfGroundTruthPoints, 1)];
    groundTruthPointsImageByDisplayedFrame{displayedFrameIndex} = ...
        groundTruthPointsImage;

    % Same depth statistics as the extracted surface above.
    dgt_bone = groundTruthPointsImage(:, 2);
    dgt_bone_mean(displayedFrameIndex) = mean(dgt_bone);
    dgt_bone_std(displayedFrameIndex) = std(dgt_bone);
end

%% CALCULATE BONE MOTION RELATIVE TO THE IMAGE FRAME

% Both smoothed transforms end in ref:
%
%     p_ref = T_image_ref * p_image
%     p_ref = T_CT_ref    * p_CT
%
% Left division removes the shared ref target and produces CT -> image:
%
%     T_CT_image = T_image_ref \ T_CT_ref
%
% The ultrasound image now stays fixed while the CT mesh shows bone motion
% relative to it.
%
% The poses at poseFrameIndex (time t) are used, because the paired image
% pixels show the bone at time t (see the pairing section above).
T_CT_imageByDisplayedFrame = zeros(4, 4, numberOfDisplayedFrames);

for displayedFrameIndex = 1:numberOfDisplayedFrames
    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);
    T_image_ref_smoothed = imageTransformsRefSmoothed(:, :, poseFrameIndex);
    T_CT_ref_smoothed    = boneTransformsRefSmoothed(:, :, poseFrameIndex);
    T_CT_imageByDisplayedFrame(:, :, displayedFrameIndex) = T_image_ref_smoothed \ T_CT_ref_smoothed;
end

%% CALCULATE FIXED IMAGE-FRAME AXES LIMITS

% Include every moving bone pose, the fixed image rectangle, and both surfaces
% (extracted and ground truth) so the camera limits remain unchanged throughout
% playback.
%
% Start with an "empty" box (+Inf minimum, -Inf maximum). Every frame then
% grows the box so it contains all points of that frame.
sceneMinimum = [Inf, Inf, Inf];
sceneMaximum = [-Inf, -Inf, -Inf];

for displayedFrameIndex = 1:numberOfDisplayedFrames

    % Collect everything that will be drawn for this frame, all in the image
    % frame: the moved bone mesh, the two surfaces, and the image rectangle.
    imageFrameIndex        = imageIndexByDisplayedFrame(displayedFrameIndex);
    imagePlane             = frameRecords(imageFrameIndex).plane;
    bonePointsImage        = applyRigidTransform(bonePose.meshCT.Points, T_CT_imageByDisplayedFrame(:, :, displayedFrameIndex));
    surfacePointsImage     = surfacePointsImageByDisplayedFrame{displayedFrameIndex};
    groundTruthPointsImage = groundTruthPointsImageByDisplayedFrame{displayedFrameIndex};

    % In the image frame, the image is the rectangle from (0, 0) to (W, H)
    % in the Z = 0 plane.
    imageCorners = [ ...
        0,            0,            0; ...
        imagePlane.W, 0,            0; ...
        imagePlane.W, imagePlane.H, 0; ...
        0,            imagePlane.H, 0];

    % Grow the bounding box with this frame's smallest and largest X, Y, Z.
    currentPointsImage = [bonePointsImage; imageCorners; ...
                          surfacePointsImage; groundTruthPointsImage];
    sceneMinimum = min(sceneMinimum, min(currentPointsImage, [], 1));
    sceneMaximum = max(sceneMaximum, max(currentPointsImage, [], 1));

end

% Add a 5% margin so nothing touches the edge of the axes.
scenePadding = 0.05 * max(sceneMaximum - sceneMinimum);

%% PREPARE THE IMAGE-FRAME FIGURE

% Every graphic object is created ONCE here, using the first displayed frame.
% The animation loop below only changes the data inside these objects. This is
% much faster than redrawing everything, and it keeps the view stable.

figureHandle = figure( ...
    'Name', 'Bone motion relative to the ultrasound image', ...
    'Color', 'white', ...
    'WindowState', 'maximized');

% Use a two-column layout so the 3D motion and its distance measurement remain
% visible together. The left axes owns the original 3D scene. The right axes
% owns the distance history and the marker synchronized with the animation.
figureLayout = tiledlayout(figureHandle, 1, 2, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');
sceneAxes = nexttile(figureLayout, 1);
dplotAxes = nexttile(figureLayout, 2);

% --- 3D scene axes (left) ---
% 'hold on' lets several objects share the axes. 'axis equal' keeps 1 mm the
% same length on every axis, so the bone shape is not distorted.
hold(sceneAxes, 'on');
grid(sceneAxes, 'on');
axis(sceneAxes, 'equal');
view(sceneAxes, -40, 40);
xlabel(sceneAxes, 'X_{image} (mm)');
ylabel(sceneAxes, 'Y_{image} (mm)');
zlabel(sceneAxes, 'Z_{image} (mm)');

% Apply the fixed limits computed above, so the camera never moves.
xlim(sceneAxes, [sceneMinimum(1) - scenePadding, sceneMaximum(1) + scenePadding]);
ylim(sceneAxes, [sceneMinimum(2) - scenePadding, sceneMaximum(2) + scenePadding]);
zlim(sceneAxes, [sceneMinimum(3) - scenePadding, sceneMaximum(3) + scenePadding]);

% Colors shared by the 3D scene and the distance plot:
%   - Extracted depth: green, because bone depth follows the positive Y_image
%     axis (drawn green). This darker green reads better than pure [0, 1, 0]
%     on the white plot background and the grayscale ultrasound image.
%   - Ground truth: magenta, so it is clearly distinct from the extracted
%     surface and every other graphic.
meanDistanceColor = [0.10, 0.55, 0.20];
groundTruthColor  = [1, 0, 1];

% The first image sets sizes that only need to be roughly right: the length of
% the drawn axis arrows (20% of the image size) and the small display offset
% used further below.
firstImageFrameIndex = imageIndexByDisplayedFrame(1);
firstImagePlane      = frameRecords(firstImageFrameIndex).plane;
imageAxisScale       = 0.20 * max(firstImagePlane.W, firstImagePlane.H);

% Draw the image frame's X/Y/Z axes at the origin. In this scene the image
% frame IS the world frame, so its origin is (0, 0, 0) and its rotation is
% the identity.
display_axis_v2( ...
    sceneAxes, zeros(3, 1), eye(3), imageAxisScale, 'Image', ...
    'Tag', 'plot_bone_motion_image_axes', ...
    'Mode', 'thin');

% Bone mesh: move the CT vertices into the image frame with T_CT_image, and
% keep the original triangle connectivity. Semi-transparent so the image and
% surfaces stay visible through it.
firstBonePointsImage = applyRigidTransform(bonePose.meshCT.Points, T_CT_imageByDisplayedFrame(:, :, 1));
boneHandle = patch(sceneAxes, ...
    'Faces', bonePose.meshCT.ConnectivityList, ...
    'Vertices', firstBonePointsImage, ...
    'FaceColor', [0.92, 0.83, 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.45, ...
    'DisplayName', 'Bone mesh');

% Extracted ultrasound surface: small red dots, already in the image frame.
firstSurfacePointsImage = surfacePointsImageByDisplayedFrame{1};
surfaceHandle = scatter3(sceneAxes, ...
    firstSurfacePointsImage(:, 1), ...
    firstSurfacePointsImage(:, 2), ...
    firstSurfacePointsImage(:, 3), ...
    3, 'red', 'filled', ...
    'MarkerEdgeColor', 'none', ...
    'DisplayName', 'Extracted ultrasound surface');

% The ground-truth points are already in the image frame, which is the frame of
% this whole scene, so they are plotted directly like the extracted surface.
firstGroundTruthPointsImage = groundTruthPointsImageByDisplayedFrame{1};
groundTruthHandle = scatter3(sceneAxes, ...
    firstGroundTruthPointsImage(:, 1), ...
    firstGroundTruthPointsImage(:, 2), ...
    firstGroundTruthPointsImage(:, 3), ...
    3, groundTruthColor, 'filled', ...
    'MarkerEdgeColor', 'none', ...
    'DisplayName', 'Ground-truth bone surface (mesh intersection)');

% Draw the mean depth as a simple ruler along the first image column. In our
% physical image coordinates, the first column is X_image = 0. The ruler starts
% at the sensor-side edge (Y_image = 0) and ends at the current dest_bone_mean.
%
% The very small positive Z offset only prevents the green graphics from
% flickering against the image texture. Geometrically, they still represent a
% measurement that lies in the ultrasound image plane.
firstImageColumnX         = 0;
meanDistanceDisplayOffset = 0.002 * max(firstImagePlane.W, firstImagePlane.H);

% The ruler line itself.
meanDistanceLine = plot3(sceneAxes, ...
    [firstImageColumnX, firstImageColumnX], ...
    [0, dest_bone_mean(1)], ...
    [meanDistanceDisplayOffset, meanDistanceDisplayOffset], ...
    '-', ...
    'Color', 'g', ...
    'LineWidth', 1, ...
    'DisplayName', 'Mean bone distance');

% A dot at the ruler's end, marking the mean depth.
meanDistanceEndpoint = scatter3(sceneAxes, ...
    firstImageColumnX, dest_bone_mean(1), meanDistanceDisplayOffset, ...
    42, meanDistanceColor, 'filled', ...
    'MarkerEdgeColor', 'white', ...
    'LineWidth', 1, ...
    'HandleVisibility', 'off');

% Add row-wise guides across the image so the spread of the extracted depth can
% be read spatially. The two thin dashed guides mark one standard deviation
% below and above the mean. A thick dashed guide at the mean itself is kept
% below as commented-out code; uncomment it (and its update in the animation
% loop) to show it.
% meanDepthGuideLine = plot3(sceneAxes, ...
%     [0, firstImagePlane.W], ...
%     [dest_bone_mean(1), dest_bone_mean(1)], ...
%     [meanDistanceDisplayOffset, meanDistanceDisplayOffset], ...
%     '--', ...
%     'Color', meanDistanceColor, ...
%     'LineWidth', 3, ...
%     'HandleVisibility', 'off');

% Each guide is a horizontal line across the full image width (X from 0 to W)
% at a constant depth Y.
lowerStdDepthGuideLine = plot3(sceneAxes, ...
    [0, firstImagePlane.W], ...
    [dest_bone_mean(1) - dest_bone_std(1), ...
     dest_bone_mean(1) - dest_bone_std(1)], ...
    [meanDistanceDisplayOffset, meanDistanceDisplayOffset], ...
    '--', ...
    'Color', 'g', ...
    'LineWidth', 0.5, ...
    'HandleVisibility', 'off');

upperStdDepthGuideLine = plot3(sceneAxes, ...
    [0, firstImagePlane.W], ...
    [dest_bone_mean(1) + dest_bone_std(1), ...
     dest_bone_mean(1) + dest_bone_std(1)], ...
    [meanDistanceDisplayOffset, meanDistanceDisplayOffset], ...
    '--', ...
    'Color', 'g', ...
    'LineWidth', 0.5, ...
    'HandleVisibility', 'off');

% Light the bone mesh from the camera so its 3D shape is readable, and use a
% gray colormap for the ultrasound image texture.
camlight(sceneAxes, 'headlight');
lighting(sceneAxes, 'gouraud');
colormap(sceneAxes, gray(256));

% The ultrasound image is the one object that is re-created every frame (see
% the animation loop). Start with an empty handle so the loop knows there is
% nothing to delete yet. T_image_image = identity places the image at the
% origin of the image frame, i.e. it never moves.
imageHandle   = gobjects(0);
T_image_image = eye(4);

% --- Distance plot axes (right) ---
% Plot the complete distance history before starting the animation. This keeps
% the distance curve fixed while only the current-frame indicators move.
%
% Each shaded band is one closed polygon: walk along the lower bound from the
% first to the last frame, then back along the upper bound (hence fliplr).
timeframeValues = 1:numberOfDisplayedFrames;
bandTimeframes  = [timeframeValues, fliplr(timeframeValues)];

extractedLowerBound   = dest_bone_mean - dest_bone_std;
extractedUpperBound   = dest_bone_mean + dest_bone_std;
groundTruthLowerBound = dgt_bone_mean - dgt_bone_std;
groundTruthUpperBound = dgt_bone_mean + dgt_bone_std;

hold(dplotAxes, 'on');
grid(dplotAxes, 'on');

% Extracted depth: green band (mean +/- std) with the mean line on top.
fill(dplotAxes, ...
    bandTimeframes, ...
    [extractedLowerBound, fliplr(extractedUpperBound)], ...
    meanDistanceColor, ...
    'FaceAlpha', 0.25, ...
    'EdgeColor', 'none', ...
    'DisplayName', 'Extracted: mean \pm std');

plot(dplotAxes, timeframeValues, dest_bone_mean, ...
    'Color', meanDistanceColor, ...
    'LineWidth', 1.8, ...
    'DisplayName', 'Extracted: mean');

% Draw the ground-truth depth the same way, in magenta, so the two estimates can
% be compared frame by frame.
fill(dplotAxes, ...
    bandTimeframes, ...
    [groundTruthLowerBound, fliplr(groundTruthUpperBound)], ...
    groundTruthColor, ...
    'FaceAlpha', 0.20, ...
    'EdgeColor', 'none', ...
    'DisplayName', 'Ground truth: mean \pm std');

plot(dplotAxes, timeframeValues, dgt_bone_mean, ...
    'Color', groundTruthColor, ...
    'LineWidth', 1.8, ...
    'DisplayName', 'Ground truth: mean');

% These three handles are updated inside the animation loop. The line shows the
% current timeframe; the two points show the extracted and ground-truth mean
% bone distance at that timeframe. 'HandleVisibility' off keeps them out of
% the legend.
currentTimeframeLine = xline(dplotAxes, timeframeValues(1), '--k', ...
    'Current timeframe', ...
    'LabelVerticalAlignment', 'bottom', ...
    'HandleVisibility', 'off');
currentDistancePoint = plot(dplotAxes, ...
    timeframeValues(1), dest_bone_mean(1), ...
    'o', ...
    'MarkerSize', 7, ...
    'MarkerFaceColor', [0.90, 0.20, 0.15], ...
    'MarkerEdgeColor', 'white', ...
    'LineWidth', 1.0, ...
    'HandleVisibility', 'off');
currentGroundTruthPoint = plot(dplotAxes, ...
    timeframeValues(1), dgt_bone_mean(1), ...
    'o', ...
    'MarkerSize', 7, ...
    'MarkerFaceColor', groundTruthColor, ...
    'MarkerEdgeColor', 'white', ...
    'LineWidth', 1.0, ...
    'HandleVisibility', 'off');

xlabel(dplotAxes, 'Timeframe');
ylabel(dplotAxes, 'Bone distance (mm)');
title(dplotAxes, 'Bone distance: extracted surface vs. ground truth');
xlim(dplotAxes, [timeframeValues(1), timeframeValues(end)]);

% Keep the distance plot wider than it is tall. The axes still receives the
% full width of the right layout tile, while MATLAB adds unused vertical space
% above and below its plotting box. This prevents the plot from becoming almost
% square when the figure window is maximized.
pbaspect(dplotAxes, [2, 1, 1]);

legend(dplotAxes, 'Location', 'best');

% Prepare the video only when recording is enabled. The output path uses
% scriptDirectory, so the MP4 is saved beside this script regardless of the
% folder from which MATLAB was started. Its playback rate matches the intended
% delay between displayed animation frames.
if recordVisualization
    videoFilePath = fullfile(scriptDirectory, 'boneMotion_inSensor_animation.mp4');
    videoWriter = VideoWriter(videoFilePath, 'MPEG-4');
    videoWriter.FrameRate = 1 / frameDelaySeconds;
    open(videoWriter);
end

%% DISPLAY BONE MOTION IN THE IMAGE FRAME

% Each loop step shows one displayed frame: update the data of the objects
% created above, redraw, optionally record, then wait before the next step.
for displayedFrameIndex = 1:numberOfDisplayedFrames
    % Stop cleanly if the user closed the figure during playback.
    if ~isvalid(figureHandle)
        break;
    end

    % The two acquisition rows paired for this displayed frame: poses come
    % from poseFrameIndex (time t), pixels from imageFrameIndex (t + delay).
    poseFrameIndex  = poseIndexByDisplayedFrame(displayedFrameIndex);
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);
    posePlane       = frameRecords(poseFrameIndex).plane;
    imagePlane      = frameRecords(imageFrameIndex).plane;

    % Move the bone mesh to this frame's position relative to the image.
    boneHandle.Vertices = applyRigidTransform(bonePose.meshCT.Points, T_CT_imageByDisplayedFrame(:, :, displayedFrameIndex));

    % Replace the points of both surfaces with this frame's points.
    surfacePointsImage  = surfacePointsImageByDisplayedFrame{displayedFrameIndex};
    surfaceHandle.XData = surfacePointsImage(:, 1);
    surfaceHandle.YData = surfacePointsImage(:, 2);
    surfaceHandle.ZData = surfacePointsImage(:, 3);

    groundTruthPointsImage  = groundTruthPointsImageByDisplayedFrame{displayedFrameIndex};
    groundTruthHandle.XData = groundTruthPointsImage(:, 1);
    groundTruthHandle.YData = groundTruthPointsImage(:, 2);
    groundTruthHandle.ZData = groundTruthPointsImage(:, 3);

    % Read this frame's depth statistics once; every depth graphic below uses
    % them.
    currentMeanDepth = dest_bone_mean(displayedFrameIndex);
    currentDepthStd = dest_bone_std(displayedFrameIndex);
    currentGroundTruthMeanDepth = dgt_bone_mean(displayedFrameIndex);

    % Update the first-column ruler, its endpoint, and the row-wise depth
    % guides. Reading W from the current image also keeps the guides correct if a
    % future dataset contains frames with a different physical image width.
    meanDistanceLine.YData     = [0, currentMeanDepth];
    meanDistanceEndpoint.YData = currentMeanDepth;

    currentImageWidth = imagePlane.W;

    % meanDepthGuideLine.XData = [0, currentImageWidth];
    % meanDepthGuideLine.YData = [currentMeanDepth, currentMeanDepth];
    lowerStdDepthGuideLine.XData = [0, currentImageWidth];
    lowerStdDepthGuideLine.YData = ...
        [currentMeanDepth - currentDepthStd, ...
         currentMeanDepth - currentDepthStd];
    upperStdDepthGuideLine.XData = [0, currentImageWidth];
    upperStdDepthGuideLine.YData = ...
        [currentMeanDepth + currentDepthStd, ...
         currentMeanDepth + currentDepthStd];

    % Keep the distance plot synchronized with the 3D scene. All three
    % indicators use displayedFrameIndex, so they always refer to the image
    % currently shown.
    currentTimeframeLine.Value    = displayedFrameIndex;
    currentDistancePoint.XData    = displayedFrameIndex;
    currentDistancePoint.YData    = currentMeanDepth;
    currentGroundTruthPoint.XData = displayedFrameIndex;
    currentGroundTruthPoint.YData = currentGroundTruthMeanDepth;

    % Only the image texture changes. Identity keeps its physical plane fixed in
    % the image coordinate frame for every animation step. display_image3D
    % creates a new object each time, so delete the previous frame's image
    % first; otherwise the images would pile up.
    if ~isempty(imageHandle) && isvalid(imageHandle)
        delete(imageHandle);
    end

    % Draw the delayed image's pixels with the same pixel spacing used for the
    % surface points, so the points sit exactly on the image. 'SwapXY' is
    % needed because the MHA reader stores the image as [width, height].
    pixelSpacingX = imagePlane.W / (imagePlane.nCols - 1);
    pixelSpacingY = imagePlane.H / (imagePlane.nRows - 1);
    imageHandle = display_image3D( ...
        sceneAxes, imagePlane.image, T_image_image, ...
        'SwapXY', true, ...
        'PixelSpacing', [pixelSpacingX, pixelSpacingY], ...
        'Tag', 'plot_bone_motion_ultrasound_image', ...
        'Colormap', 'gray', ...
        'FaceAlpha', 0.75);

    % Two-line title: line 1 is the playback position and the configured
    % delay; line 2 shows which pose row and image row are paired, their
    % timestamps, and the delay actually achieved between them.
    title(sceneAxes, { ...
        % sprintf('%s | Bone %s | Ultrasound image frame', ...
        %     string(snapshotGroup.name), boneCode), ...
        sprintf('Ultrasound image frame | Frame (%d / %d) | Delay %.3f s', ...
            displayedFrameIndex, numberOfDisplayedFrames, ...
            temporalDelaySeconds), ...
        sprintf('Pose #%d at %.3f s | Image #%d at %.3f s | Paired delay %.3f s', ...
            posePlane.rigidBodyRowIndex, recordedTimes(poseFrameIndex), ...
            imagePlane.rigidBodyRowIndex, recordedTimes(imageFrameIndex), ...
            pairedDelaySeconds(displayedFrameIndex))}, ...
        'Interpreter', 'none');

    % Push all the updates above to the screen now.
    drawnow;

    % Capture the complete maximized figure after both axes have been updated.
    % When recording is disabled, MATLAB skips all video-related work.
    if recordVisualization
        videoFrame = getframe(figureHandle);
        writeVideo(videoWriter, videoFrame);
    end

    % Wait before the next frame to control the playback speed.
    pause(frameDelaySeconds);
end

% Finalize the MP4 so it can be opened immediately after the script finishes.
if recordVisualization
    close(videoWriter);
    fprintf('Animation saved to:\n%s\n', videoFilePath);
end
