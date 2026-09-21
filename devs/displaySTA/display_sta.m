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
temporalDelaySeconds = 0.00;

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
    pairedDelaySeconds(displayedFrameIndex) = ...
        recordedTimes(imageFrameIndex) - recordedTimes(poseFrameIndex);
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

    currentPointsRef = [bonePointsRef; imageCornersRef];
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
axis(sceneAxes, 'vis3d');
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
