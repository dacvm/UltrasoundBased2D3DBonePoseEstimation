clear; clc; close all;

%% SETTINGS

% Keep the playback speed in one visible setting so it is easy to adjust.
% This is a fixed delay between displayed frames; it does not try to reproduce
% the original acquisition timing.
frameDelaySeconds = 0.05;

% A positive value means that the ultrasound image content was recorded this
% many seconds after the physical motion that produced it. We compensate for
% that delay by showing a later recorded image with an earlier pose:
%
%     pose time                 : 1.00 s
%     requested image time      : 1.00 s + 0.10 s = 1.10 s
%     displayed combination     : pose from 1.00 s + image from 1.10 s
%
% Set this value to zero to reproduce the original frame pairing.
temporalDelaySeconds = 0.12;

% Use the same smoothing approach as smoothTransformations_demo.m. The window
% controls how many neighbouring motion samples influence each result. A larger
% value removes more jitter but can also soften fast, intentional movement.
smoothingMethod = 'sgolay';
smoothingWindow = 15;

%% LOAD THE REVIEWED ULTRASOUND AND BONE DATA

% Find the project root from this script instead of using a computer-specific
% absolute path. display_sta.m is stored two folders below the project root:
% project root -> devs -> displaySTA -> display_sta.m.
scriptDirectory = fileparts(mfilename('fullpath'));
projectRoot     = fileparts(fileparts(scriptDirectory));

% Add the shared project functions so the standard image-plane and rigid-
% transform helpers are available to this development script.
addpath(genpath(fullfile(projectRoot, 'functions')));

dataFilePath = fullfile(projectRoot, 'tools', ...
    'ultrasoundSpatialProcessing', 'outputs', ...
    'validSnapshots_20260919_110840_meas04c.mat');
loadedData = load(dataFilePath, 'validSnapshots', 'validBonePoses');

% Load the extracted ultrasound bone surfaces separately. Each surface record
% contains XYZ points that were already transformed into the ref frame by the
% segmentation-recovery workflow.
surfaceFilePath = fullfile(projectRoot, 'tools', ...
    'boneSegmentationProcess', 'outputs', ...
    'boneSurface_20260921_172157.mat');
loadedSurfaceData = load(surfaceFilePath, 'surfaceResults');

% This reviewed file contains one ultrasound sequence. Its bone code identifies
% which mesh and pose sequence belongs with the ultrasound images. For this
% recording the code is F, so the femur is selected instead of the tibia.
snapshotGroup = loadedData.validSnapshots(1);
frameRecords  = snapshotGroup.data;
boneCode      = string(snapshotGroup.bone);

availableBoneCodes = string({loadedData.validBonePoses.bonePoses.bone});
bonePoseIndex      = find(availableBoneCodes == boneCode, 1);
bonePose           = loadedData.validBonePoses.bonePoses(bonePoseIndex);
poseRecords        = bonePose.data;
numberOfFrames     = numel(frameRecords);

% Select the surface group describing the same acquisition location and bone as
% the ultrasound group. This file contains femur_middle, but matching by stored
% identity keeps the relationship visible instead of relying on array position.
surfaceGroupNames = string({loadedSurfaceData.surfaceResults.name});
surfaceGroupBones = string({loadedSurfaceData.surfaceResults.bone});
surfaceGroupIndex = find( ...
    surfaceGroupNames == string(snapshotGroup.name) & ...
    surfaceGroupBones == boneCode, 1);
surfaceRecords = loadedSurfaceData.surfaceResults(surfaceGroupIndex).data;

%% PAIR EVERY ULTRASOUND FRAME WITH ITS BONE POSE

% The reviewed frames are stored in chronological order, but their original
% rigid-body row numbers are not necessarily consecutive. Therefore, do not use
% the loop index to choose a bone pose. Match the identifiers that describe the
% original source group, sequence file, and rigid-body row instead.
poseIndexByFrame = zeros(1, numberOfFrames);

% Loop through every reviewed ultrasound frame to find its matching bone pose.
for frameIndex = 1:numberOfFrames
    currentPlane = frameRecords(frameIndex).plane;

    poseMatches = ...
        [poseRecords.snapshotIndex] == currentPlane.snapshotIndex & ...
        [poseRecords.sequenceIndex] == currentPlane.sequenceIndex & ...
        [poseRecords.rigidBodyRowIndex] == currentPlane.rigidBodyRowIndex;

    matchingPoseIndex = find(poseMatches);
    if numel(matchingPoseIndex) ~= 1
        error('Expected one matching bone pose for ultrasound frame %d.', frameIndex);
    end

    poseIndexByFrame(frameIndex) = matchingPoseIndex;
end

%% PAIR EVERY ULTRASOUND FRAME WITH ITS EXTRACTED SURFACE

% Surface extraction preserves sourceIndex from the reviewed ultrasound file.
% Match that stable identity once here so later code does not assume that two
% independently saved arrays always have the same storage order.
surfaceSourceIndices = [surfaceRecords.sourceIndex];
surfaceIndexByFrame = zeros(1, numberOfFrames);

for frameIndex = 1:numberOfFrames
    frameSourceIndex = frameRecords(frameIndex).sourceIndex;
    matchingSurfaceIndex = find( ...
        surfaceSourceIndices == frameSourceIndex, 1);
    surfaceIndexByFrame(frameIndex) = matchingSurfaceIndex;
end

%% SMOOTH THE IMAGE AND BONE POSE SEQUENCES

% smoothTransformations expects a 4-by-4-by-N array. Build one transform stack
% for the ultrasound image and another for the bone. They must be smoothed
% separately because they come from different tracked rigid bodies:
%
%   - T_image_ref comes from the ultrasound sequence and maps image -> ref.
%   - T_CT_ref comes from the rigid-body table and maps CT -> ref.
%
% Both transforms already have ref as their target frame. Smoothing them in
% their current form therefore reduces visible pose jitter without changing the
% transformation chains used later to place the image and mesh in the scene.
imageTransformsRef = zeros(4, 4, numberOfFrames);
boneTransformsRef  = zeros(4, 4, numberOfFrames);

% Loop through every matched frame to build the two 4-by-4-by-N pose stacks.
for frameIndex = 1:numberOfFrames
    currentPlane = frameRecords(frameIndex).plane;
    currentPose  = poseRecords(poseIndexByFrame(frameIndex));

    imageTransformsRef(:, :, frameIndex) = currentPlane.T_image_ref;
    boneTransformsRef(:, :, frameIndex)  = currentPose.T_CT_ref;
end

imageTransformsRefSmoothed = smoothTransformations( ...
    imageTransformsRef, ...
    'method', smoothingMethod, ...
    'window', smoothingWindow);

boneTransformsRefSmoothed = smoothTransformations( ...
    boneTransformsRef, ...
    'method', smoothingMethod, ...
    'window', smoothingWindow);

%% COMPENSATE FOR THE ULTRASOUND IMAGE DELAY

% The ultrasound pixels and the rigid-body transforms are stored together at
% each recorded time, but the pixels show an event that happened earlier. If the
% image delay is 0.10 s, an image stored at 1.10 s represents approximately the
% same physical time as the rigid-body poses measured at 1.00 s.
%
% The following simplified example uses a delay of two samples. I1 means the
% ultrasound image content created by physical event 1. P1 and B1 are the image-
% plane and bone poses measured during that same physical event.
%
% What is stored before temporal compensation:
%
%     recorded sample           :  1 |  2 |  3 |  4 |  5 | ...
%     image pixels              :  - |  - | I1 | I2 | I3 | ...
%     image-plane pose from MHA : P1 | P2 | P3 | P4 | P5 | ...
%     bone pose from CSV        : B1 | B2 | B3 | B4 | B5 | ...
%
% The current same-index pairing would display P3 + B3 + I1 at sample 3. That
% is temporally wrong because I1 shows the anatomy during physical event 1.
%
% What we want to display after temporal compensation:
%
%     displayed physical event :  1 |  2 |  3 | ...
%     image-plane pose          : P1 | P2 | P3 | ...
%     bone pose                 : B1 | B2 | B3 | ...
%     ultrasound pixels         : I1 | I2 | I3 | ...
%     pixels read from sample   :  3 |  4 |  5 | ...
%
% Therefore, displayed event 1 uses P1 and B1 from sample 1, but reads I1 from
% sample 3. We are not changing the image itself. We are changing which recorded
% image is paired with each pose.
%
% Therefore, for every pose time, look FORWARD in the recorded image sequence:
%
%     target image time = pose time + temporal delay
%
% The plus sign can initially look backwards. It is correct because an image
% showing an earlier physical event appears later in the recorded image stream.
% Starting from pose time 1.00 s with a delay of 0.10 s, we must look forward to
% the image stored near 1.10 s to recover the image content belonging to 1.00 s.
%
% Only the image pixels move forward in this pairing. The smoothed image-plane
% pose and smoothed bone pose remain together at the same pose index. This is
% important because both transforms describe the same physical acquisition time
% in the common ref coordinate system.
allPlanes        = [frameRecords.plane];
recordedTimes    = double([allPlanes.timestamp]);
targetImageTimes = recordedTimes + temporalDelaySeconds;

% A pose can only be displayed when its target image time is inside the recorded
% image interval. Cropping the non-overlapping end is more honest than repeating
% the last image or inventing missing image data.
hasAvailableImage = ...
    targetImageTimes >= recordedTimes(1) & ...
    targetImageTimes <= recordedTimes(end);
poseIndexByDisplayedFrame = find(hasAvailableImage);
numberOfDisplayedFrames   = numel(poseIndexByDisplayedFrame);

if numberOfDisplayedFrames == 0
    error('The temporal delay leaves no overlapping pose and image data.');
end

% Ultrasound images are discrete, so choose the recorded image whose timestamp
% is closest to the requested target time. Keep the actual paired delay as well;
% it can differ slightly from the requested value because no image interpolation
% is performed.
imageIndexByDisplayedFrame = zeros(1, numberOfDisplayedFrames);
pairedDelaySeconds         = zeros(1, numberOfDisplayedFrames);

% Loop through the usable pose frames to choose one delayed image for each pose.
for displayedFrameIndex = 1:numberOfDisplayedFrames

    % Convert the current animation position back to its original frame index.
    % This pose index refers to both synchronized rigid-body transforms:
    % T_image_ref for the image plane and T_CT_ref for the bone mesh.
    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);

    % Read the ideal recorded image time for this pose. For example, a pose at
    % 1.00 s with a requested delay of 0.10 s needs an image near 1.10 s.
    targetImageTime = targetImageTimes(poseFrameIndex);

    % Calculate the absolute time difference between the ideal image time and
    % every available recorded image. min returns the image with the smallest
    % difference. The '~' discards that minimum difference because only its
    % image index is needed here.
    [~, imageFrameIndex] = min(abs(recordedTimes - targetImageTime));

    % Store the selected image index at the same animation position as its pose
    % index. These two arrays later drive the visualization side by side.
    imageIndexByDisplayedFrame(displayedFrameIndex) = imageFrameIndex;

    % Record the delay that was actually achieved by the nearest image. It may
    % differ slightly from temporalDelaySeconds because the image sequence has
    % discrete timestamps. This value is shown in the figure title for review.
    pairedDelaySeconds(displayedFrameIndex) = recordedTimes(imageFrameIndex) - recordedTimes(poseFrameIndex);
end

% Surface points were extracted from the ultrasound pixels, so they must follow
% imageIndexByDisplayedFrame rather than poseIndexByDisplayedFrame. For example,
% when an earlier pose is paired with a later recorded image, use the surface
% extracted from that same later image.
surfaceIndexByDisplayedFrame = ...
    surfaceIndexByFrame(imageIndexByDisplayedFrame);

%% RECONSTRUCT THE EXTRACTED SURFACE WITH THE SMOOTHED IMAGE POSES

% surfaceCoordinatesXY is the measurement that belongs to the delayed image.
% It has not yet been attached to a 3D tracking trajectory. Reconstruct it once
% here so both visualizations use exactly the same local surface points.
surfacePointsImageByDisplayedFrame = cell(1, numberOfDisplayedFrames);
surfacePointsRefSmoothedByDisplayedFrame = ...
    cell(1, numberOfDisplayedFrames);

for displayedFrameIndex = 1:numberOfDisplayedFrames
    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);
    surfaceIndex = surfaceIndexByDisplayedFrame(displayedFrameIndex);

    imagePlane = frameRecords(imageFrameIndex).plane;
    surfaceCoordinatesXY = ...
        double(surfaceRecords(surfaceIndex).surfaceCoordinatesXY);

    % surfaceCoordinatesXY stores one-based [column, row] positions. W and H
    % measure the distance from the first to the last pixel centre, so dividing
    % by count-1 gives the physical millimetres per pixel interval. Subtract one
    % from the pixel coordinates to place the first pixel centre at [0, 0].
    pixelSpacingX = imagePlane.W / (imagePlane.nCols - 1);
    pixelSpacingY = imagePlane.H / (imagePlane.nRows - 1);
    numberOfSurfacePoints = size(surfaceCoordinatesXY, 1);
    surfacePointsImage = [ ...
        (surfaceCoordinatesXY(:, 1) - 1) * pixelSpacingX, ...
        (surfaceCoordinatesXY(:, 2) - 1) * pixelSpacingY, ...
        zeros(numberOfSurfacePoints, 1)];

    % Temporal compensation pairs the later image measurements with an earlier
    % physical pose. Therefore, use the pose-side smoothed T_image_ref here—not
    % the raw transform originally stored beside the later image record.
    T_image_ref_smoothed = ...
        imageTransformsRefSmoothed(:, :, poseFrameIndex);
    surfacePointsRefSmoothed = applyRigidTransform( ...
        surfacePointsImage, T_image_ref_smoothed);

    surfacePointsImageByDisplayedFrame{displayedFrameIndex} = ...
        surfacePointsImage;
    surfacePointsRefSmoothedByDisplayedFrame{displayedFrameIndex} = ...
        surfacePointsRefSmoothed;
end

%% CALCULATE FIXED LIMITS FOR THE COMPLETE ANIMATION

% MATLAB normally changes the axes limits when plotted objects move. That would
% make the camera appear to zoom during the animation. Find the complete spatial
% extent first, then use one fixed set of limits for every frame.
sceneMinimum = [Inf, Inf, Inf];
sceneMaximum = [-Inf, -Inf, -Inf];

% Loop through all compensated frame pairs to find their combined 3D extent.
for displayedFrameIndex = 1:numberOfDisplayedFrames
    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);

    % The pose record supplies both transforms. The image record supplies only
    % the delayed pixel data and its physical rectangle size.
    imagePlane = frameRecords(imageFrameIndex).plane;
    T_image_ref_smoothed = imageTransformsRefSmoothed(:, :, poseFrameIndex);
    T_CT_ref_smoothed = boneTransformsRefSmoothed(:, :, poseFrameIndex);

    % Mesh vertices are stored in CT coordinates. T_CT_ref maps a CT point into
    % ref coordinates, following the project convention:
    %
    %     p_ref = T_CT_ref * p_CT
    %
    % The anatomical T_bone_ref transform is not used here because the mesh
    % vertices do not live in the anatomical bone coordinate frame.
    bonePointsRef = applyRigidTransform(bonePose.meshCT.Points, T_CT_ref_smoothed);

    % These four points describe the ultrasound rectangle in its own image
    % frame. W and H are physical distances, so the corners use millimetres
    % rather than pixel indices.
    imageCorners = [ ...
        0,            0,            0; ...
        imagePlane.W, 0,            0; ...
        imagePlane.W, imagePlane.H, 0; ...
        0,            imagePlane.H, 0];

    % T_image_ref already contains the complete image -> probe -> ref transform
    % chain prepared during spatial processing. Applying it places the physical
    % ultrasound rectangle in the same ref coordinate system as the bone mesh.
    imageCornersRef = applyRigidTransform(imageCorners, T_image_ref_smoothed);

    % Use the extracted surface reconstructed with the same smoothed image pose
    % that positions the displayed ultrasound plane in ref.
    surfacePointsRef = ...
        surfacePointsRefSmoothedByDisplayedFrame{displayedFrameIndex};

    currentPointsRef = [bonePointsRef; imageCornersRef; surfacePointsRef];
    sceneMinimum     = min(sceneMinimum, min(currentPointsRef, [], 1));
    sceneMaximum     = max(sceneMaximum, max(currentPointsRef, [], 1));
end

% Add a small border around the moving data so objects do not touch the axes.
scenePadding = 0.05 * max(sceneMaximum - sceneMinimum);

%% PREPARE THE 3D SCENE

figureHandle = figure( ...
    'Name', 'Smoothed and time-aligned ultrasound and bone poses in ref', ...
    'Color', 'white');
sceneAxes = axes(figureHandle);

hold(sceneAxes, 'on');
grid(sceneAxes, 'on');
axis(sceneAxes, 'equal');
view(sceneAxes, 35, 30);

xlabel(sceneAxes, 'X_{ref} (mm)');
ylabel(sceneAxes, 'Y_{ref} (mm)');
zlabel(sceneAxes, 'Z_{ref} (mm)');

xlim(sceneAxes, [sceneMinimum(1) - scenePadding, ...
                  sceneMaximum(1) + scenePadding]);
ylim(sceneAxes, [sceneMinimum(2) - scenePadding, ...
                  sceneMaximum(2) + scenePadding]);
zlim(sceneAxes, [sceneMinimum(3) - scenePadding, ...
                  sceneMaximum(3) + scenePadding]);

% Create the bone surface once. During playback only its Vertices property is
% changed, because a rigid transform moves vertices without changing which
% three vertices form each triangular face.
firstPoseFrameIndex = poseIndexByDisplayedFrame(1);
firstBonePointsRef = applyRigidTransform( ...
    bonePose.meshCT.Points, ...
    boneTransformsRefSmoothed(:, :, firstPoseFrameIndex));

boneHandle = patch(sceneAxes, ...
    'Faces', bonePose.meshCT.ConnectivityList, ...
    'Vertices', firstBonePointsRef, ...
    'FaceColor', [0.92, 0.83, 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.45, ...
    'DisplayName', 'Bone mesh');

% Draw the first extracted surface as red points. These coordinates
% were reconstructed with the same smoothed transform as the image plane.
firstSurfacePointsRef = ...
    surfacePointsRefSmoothedByDisplayedFrame{1};
surfaceHandle = scatter3(sceneAxes, ...
    firstSurfacePointsRef(:, 1), ...
    firstSurfacePointsRef(:, 2), ...
    firstSurfacePointsRef(:, 3), ...
    12, [1.00, 0.00, 0.00], 'filled', ...
    'MarkerEdgeColor', 'none', ...
    'DisplayName', 'Extracted ultrasound surface');

camlight(sceneAxes, 'headlight');
lighting(sceneAxes, 'gouraud');
colormap(sceneAxes, gray(256));

imageHandle = gobjects(0);

%% DISPLAY THE SEQUENCE FRAME BY FRAME

% Loop through every compensated pair to animate its poses and image pixels.
for displayedFrameIndex = 1:numberOfDisplayedFrames
    % Allow the animation to stop cleanly when the user closes its figure.
    if ~isvalid(figureHandle)
        break;
    end

    % Two indices are intentionally used here:
    %
    %   poseFrameIndex  selects the synchronized image-plane and bone poses.
    %   imageFrameIndex selects the later ultrasound pixels that correspond to
    %                   the earlier physical pose after delay compensation.
    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);

    posePlane = frameRecords(poseFrameIndex).plane;
    imagePlane = frameRecords(imageFrameIndex).plane;
    T_image_ref_smoothed = imageTransformsRefSmoothed(:, :, poseFrameIndex);
    T_CT_ref_smoothed = boneTransformsRefSmoothed(:, :, poseFrameIndex);

    % Update the bone pose in ref. The connectivity stays fixed, so only the
    % transformed CT vertices need to be sent to the existing patch object.
    boneHandle.Vertices = applyRigidTransform( ...
        bonePose.meshCT.Points, T_CT_ref_smoothed);

    % Use the delayed image's extracted surface after placing it with the same
    % smoothed T_image_ref that positions the displayed ultrasound plane.
    surfacePointsRef = ...
        surfacePointsRefSmoothedByDisplayedFrame{displayedFrameIndex};
    surfaceHandle.XData = surfacePointsRef(:, 1);
    surfaceHandle.YData = surfacePointsRef(:, 2);
    surfaceHandle.ZData = surfacePointsRef(:, 3);

    % Remove the previous textured plane and image coordinate axes before
    % drawing the new ultrasound pose. Recreating this small surface keeps the
    % animation code easier to follow than manually updating all texture fields.
    if ~isempty(imageHandle) && isvalid(imageHandle)
        delete(imageHandle);
    end
    delete(findobj(sceneAxes, 'Tag', 'plot_sta_image_axes'));

    % The stored image matrix uses [column, row] order, so display_image3D swaps
    % its first two dimensions. W and H describe the physical plane extents;
    % dividing them by the number of pixel intervals recovers the calibration
    % spacing expected by the display helper.
    pixelSpacingX = imagePlane.W / (imagePlane.nCols - 1);
    pixelSpacingY = imagePlane.H / (imagePlane.nRows - 1);

    imageHandle = display_image3D( ...
        sceneAxes, imagePlane.image, T_image_ref_smoothed, ...
        'SwapXY', true, ...
        'PixelSpacing', [pixelSpacingX, pixelSpacingY], ...
        'Tag', 'plot_sta_ultrasound_image', ...
        'Colormap', 'gray', ...
        'FaceAlpha', 0.75);

    % Show the image-frame X, Y, and Z directions. The red and green arrows lie
    % in the ultrasound plane; the blue arrow is its normal direction. Because
    % these axes come directly from the smoothed T_image_ref, their origin and
    % orientation are expressed in ref coordinates.
    imageOriginRef = T_image_ref_smoothed(1:3, 4);
    imageAxesRef = T_image_ref_smoothed(1:3, 1:3);
    imageAxisScale = 0.20 * max(imagePlane.W, imagePlane.H);
    display_axis_v2( ...
        sceneAxes, imageOriginRef, imageAxesRef, imageAxisScale, 'Image', ...
        'Tag', 'plot_sta_image_axes', ...
        'Mode', 'thin');

    title(sceneAxes, { ...
        sprintf('%s | Bone %s', string(snapshotGroup.name), boneCode), ...
        sprintf('Frame %d of %d | Requested delay %.3f s', ...
            displayedFrameIndex, numberOfDisplayedFrames, ...
            temporalDelaySeconds), ...
        sprintf(['Pose row %d at %.3f s | Image row %d at %.3f s | ' ...
            'Paired delay %.3f s'], ...
            posePlane.rigidBodyRowIndex, recordedTimes(poseFrameIndex), ...
            imagePlane.rigidBodyRowIndex, recordedTimes(imageFrameIndex), ...
            pairedDelaySeconds(displayedFrameIndex))}, ...
        'Interpreter', 'none');

    drawnow;
    pause(frameDelaySeconds);
end

%% PART 2: EXPRESS THE IMAGE PLANE AND BONE IN THE IMAGE FRAME

% The image frame itself is the fixed reference frame for this visualization.
% Both available time-varying transforms currently end in ref:
%
%     p_ref = T_image_ref * p_image
%     p_ref = T_CT_ref    * p_CT
%
% We want one transform that maps a CT mesh point directly into image. Solving
% the two equations for p_image gives:
%
%     p_image = T_image_ref \ T_CT_ref * p_CT
%
% Therefore:
%
%     T_CT_image = T_image_ref \ T_CT_ref
%
% Using this transform removes the shared motion of the ultrasound image frame
% in ref. The image plane stays fixed at Z_image = 0, while the bone shows only
% its changing position and orientation relative to that image plane.
% Preallocate one 4-by-4 transform for every displayed frame. Keeping the
% coordinate conversion outside the drawing loop makes the later animation
% easier to read and avoids repeating the same calculation during rendering.
T_CT_imageByDisplayedFrame = zeros(4, 4, numberOfDisplayedFrames);

for displayedFrameIndex = 1:numberOfDisplayedFrames
    % Temporal compensation can pair a pose with pixels from another row. Use
    % the pose-side index here because both rigid-body transforms must describe
    % the same physical time before their relative transform is calculated.
    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);

    % Retrieve the two smoothed transforms that currently end in ref.
    T_image_ref_smoothed = imageTransformsRefSmoothed(:, :, poseFrameIndex);
    T_CT_ref_smoothed = boneTransformsRefSmoothed(:, :, poseFrameIndex);

    % Left division solves
    % T_image_ref_smoothed * T_CT_image = T_CT_ref_smoothed without explicitly
    % calculating an inverse. The result maps CT mesh vertices into image.
    T_CT_imageByDisplayedFrame(:, :, displayedFrameIndex) = T_image_ref_smoothed \ T_CT_ref_smoothed;
end

%% CALCULATE FIXED LIMITS IN THE IMAGE FRAME

% Include every moving bone pose and the fixed image rectangle. One shared
% extent prevents the camera from zooming while the animation is playing.
% Start with opposite infinities so the first set of points always replaces the
% initial values, after which later frames can expand the accumulated bounds.
imageSceneMinimum = [Inf, Inf, Inf];
imageSceneMaximum = [-Inf, -Inf, -Inf];

for displayedFrameIndex = 1:numberOfDisplayedFrames

    % The temporally paired image record supplies the physical plane dimensions.
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);
    imagePlane      = frameRecords(imageFrameIndex).plane;

    % Move all CT vertices into the image frame for this displayed pose. A rigid
    % transform changes vertex coordinates but not the triangle connectivity.
    bonePointsImage = applyRigidTransform(bonePose.meshCT.Points, T_CT_imageByDisplayedFrame(:, :, displayedFrameIndex));

    % The extracted surface was reconstructed directly from its stored 2D pixel
    % coordinates, so it can be included beside the fixed image rectangle
    % without passing through an unsmoothed ref-frame pose.
    surfacePointsImage = ...
        surfacePointsImageByDisplayedFrame{displayedFrameIndex};

    % The image plane is already in its own coordinate frame. Its top-left
    % corner is the origin, its width follows +X_image, and its height follows
    % +Y_image. No rigid transform is needed for these four corners.
    imageCorners = [ ...
        0,            0,            0; ...
        imagePlane.W, 0,            0; ...
        imagePlane.W, imagePlane.H, 0; ...
        0,            imagePlane.H, 0];

    % Let both the moving bone and fixed image rectangle contribute to the
    % limits, then update the accumulated minimum and maximum of each XYZ axis.
    currentPointsImage = [bonePointsImage; imageCorners; surfacePointsImage];
    imageSceneMinimum = min(imageSceneMinimum, min(currentPointsImage, [], 1));
    imageSceneMaximum = max(imageSceneMaximum, max(currentPointsImage, [], 1));
end

% Add five percent of the largest scene dimension on every side. One padding
% value gives a consistent visual margin along X, Y, and Z.
imageScenePadding = 0.05 * max(imageSceneMaximum - imageSceneMinimum);

%% PREPARE THE IMAGE-FRAME SCENE

% Create a dedicated figure so this view remains independent from the optional
% ref-frame visualization above it.
imageFigureHandle = figure( ...
    'Name', 'Bone motion relative to the ultrasound image', ...
    'Color', 'white');

% Explicitly attach all Part 2 graphics to these axes. This prevents MATLAB from
% drawing into another figure that happens to be active.
imageAxes = axes(imageFigureHandle);

% Keep all objects visible together, show spatial reference lines, preserve the
% same physical scale in every direction, and select an initial camera angle.
hold(imageAxes, 'on');
grid(imageAxes, 'on');
axis(imageAxes, 'equal');
view(imageAxes, -60, 40);

% State both the coordinate frame and the physical unit on each axis.
xlabel(imageAxes, 'X_{image} (mm)');
ylabel(imageAxes, 'Y_{image} (mm)');
zlabel(imageAxes, 'Z_{image} (mm)');

% Apply the limits calculated from the complete sequence. These limits stay
% fixed while the image texture and bone vertices change during playback.
xlim(imageAxes, [imageSceneMinimum(1) - imageScenePadding, ...
                  imageSceneMaximum(1) + imageScenePadding]);
ylim(imageAxes, [imageSceneMinimum(2) - imageScenePadding, ...
                  imageSceneMaximum(2) + imageScenePadding]);
zlim(imageAxes, [imageSceneMinimum(3) - imageScenePadding, ...
                  imageSceneMaximum(3) + imageScenePadding]);

% Draw the image coordinate axes once at the origin. They remain fixed because
% the image coordinate frame is the reference frame of this figure.
% The first displayed image supplies a representative plane size used only to
% choose readable arrow lengths; it does not affect a transformation.
firstImageFrameIndex = imageIndexByDisplayedFrame(1);
firstImagePlane      = frameRecords(firstImageFrameIndex).plane;
imageAxisScale       = 0.20 * max(firstImagePlane.W, firstImagePlane.H);

% An origin of zeros and basis eye(3) draw the image frame itself: red follows
% +X_image, green follows +Y_image, and blue follows +Z_image.
display_axis_v2( ...
    imageAxes, zeros(3, 1), eye(3), imageAxisScale, 'Image', ...
    'Tag', 'plot_sta_fixed_image_axes', ...
    'Mode', 'thin');

% Transform the CT vertices for the first displayed pose so the bone surface can
% be created at its correct initial image-frame position.
firstBonePointsImage = applyRigidTransform(bonePose.meshCT.Points, T_CT_imageByDisplayedFrame(:, :, 1));

% Create the mesh once. Later frames replace only Vertices because rigid motion
% does not change which three vertices form each triangular Face.
imageFrameBoneHandle = patch(imageAxes, ...
    'Faces', bonePose.meshCT.ConnectivityList, ...
    'Vertices', firstBonePointsImage, ...
    'FaceColor', [0.92, 0.83, 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.45, ...
    'DisplayName', 'Bone mesh');

% Draw the first extracted surface in local image coordinates. Because these
% points and the ultrasound texture share the image frame, they lie on the fixed
% image plane while the CT mesh moves relative to them.
firstSurfacePointsImage = surfacePointsImageByDisplayedFrame{1};
imageFrameSurfaceHandle = scatter3(imageAxes, ...
    firstSurfacePointsImage(:, 1), ...
    firstSurfacePointsImage(:, 2), ...
    firstSurfacePointsImage(:, 3), ...
    12, [1.00, 0.00, 0.00], 'filled', ...
    'MarkerEdgeColor', 'none', ...
    'DisplayName', 'Extracted ultrasound surface');

% Lighting makes changes in surface orientation easier to see. The gray colormap
% is used by the grayscale B-mode image texture drawn below.
camlight(imageAxes, 'headlight');
lighting(imageAxes, 'gouraud');
colormap(imageAxes, gray(256));

% No ultrasound surface exists before the first iteration. gobjects(0) provides
% an empty graphics handle that can be checked safely before deletion.
fixedImageHandle = gobjects(0);

% A coordinate frame expressed in itself has identity rotation and zero
% translation. Reusing this transform guarantees that the image plane stays
% fixed while its pixel values change.
T_image_image = eye(4);

%% DISPLAY THE SEQUENCE IN THE IMAGE FRAME

for displayedFrameIndex = 1:numberOfDisplayedFrames
    % Stop playback naturally if the user closes this figure.
    if ~isvalid(imageFigureHandle)
        break;
    end

    % Read both sides of the temporal-delay pairing:
    % - poseFrameIndex controls the relative bone transformation.
    % - imageFrameIndex selects the later ultrasound pixel data.
    poseFrameIndex  = poseIndexByDisplayedFrame(displayedFrameIndex);
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);

    % Keep the full records for readable metadata access in the title.
    % imagePlane also contains the pixel matrix and physical plane dimensions.
    posePlane  = frameRecords(poseFrameIndex).plane;
    imagePlane = frameRecords(imageFrameIndex).plane;

    % The bone vertices change because T_CT_image changes over time. The image
    % plane uses T_image_image = identity, so its position and orientation can
    % never move away from the image-frame origin and XY plane.
    imageFrameBoneHandle.Vertices = applyRigidTransform( ...
        bonePose.meshCT.Points, ...
        T_CT_imageByDisplayedFrame(:, :, displayedFrameIndex));

    % Update the extracted points with the surface that belongs to the currently
    % displayed delayed ultrasound image.
    surfacePointsImage = ...
        surfacePointsImageByDisplayedFrame{displayedFrameIndex};
    imageFrameSurfaceHandle.XData = surfacePointsImage(:, 1);
    imageFrameSurfaceHandle.YData = surfacePointsImage(:, 2);
    imageFrameSurfaceHandle.ZData = surfacePointsImage(:, 3);

    % Recreate only the textured surface so the delay-compensated pixel content
    % advances over time. Every frame uses the same identity transform, keeping
    % the ultrasound plane geometry fixed.
    if ~isempty(fixedImageHandle) && isvalid(fixedImageHandle)
        delete(fixedImageHandle);
    end

    % W and H measure the distance from the first to the last pixel centre.
    % Dividing by count-1 recovers the physical spacing between neighbouring
    % pixels along local X_image and Y_image.
    pixelSpacingX = imagePlane.W / (imagePlane.nCols - 1);
    pixelSpacingY = imagePlane.H / (imagePlane.nRows - 1);

    % Draw the new pixel matrix on the fixed image-frame XY plane. SwapXY is
    % required because acquisition packets store their matrix as [column, row].
    fixedImageHandle = display_image3D( ...
        imageAxes, imagePlane.image, T_image_image, ...
        'SwapXY', true, ...
        'PixelSpacing', [pixelSpacingX, pixelSpacingY], ...
        'Tag', 'plot_sta_fixed_ultrasound_image', ...
        'Colormap', 'gray', ...
        'FaceAlpha', 0.75);

    % Show both source rows so the user can inspect the temporal pairing. The
    % actual paired delay may differ slightly from the request because the code
    % chooses the closest available discrete ultrasound image.
    title(imageAxes, { ...
        sprintf('%s | Bone %s | Ultrasound image frame', ...
            string(snapshotGroup.name), ...
            boneCode), ...
        sprintf('Frame %d of %d | Requested delay %.3f s', ...
            displayedFrameIndex, ...
            numberOfDisplayedFrames, ...
            temporalDelaySeconds), ...
        sprintf(['Pose row %d at %.3f s | Image row %d at %.3f s | ' ...
            'Paired delay %.3f s'], ...
            posePlane.rigidBodyRowIndex, ...
            recordedTimes(poseFrameIndex), ...
            imagePlane.rigidBodyRowIndex, ...
            recordedTimes(imageFrameIndex), ...
            pairedDelaySeconds(displayedFrameIndex))}, ...
        'Interpreter', 'none');

    % Send the new vertices, texture, and title to the figure, then wait for the
    % configured playback interval before advancing to the next pair.
    drawnow;
    pause(frameDelaySeconds);
end
