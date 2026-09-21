clear; clc; close all;

%% SETTINGS

% Keep the playback speed in one visible setting so it is easy to adjust.
% This is a fixed delay between displayed frames; it does not try to reproduce
% the original acquisition timing.
frameDelaySeconds = 0.05;

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
projectRoot = fileparts(fileparts(scriptDirectory));

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
frameRecords = snapshotGroup.data;
boneCode = string(snapshotGroup.bone);

availableBoneCodes = string({loadedData.validBonePoses.bonePoses.bone});
bonePoseIndex = find(availableBoneCodes == boneCode, 1);
bonePose = loadedData.validBonePoses.bonePoses(bonePoseIndex);
poseRecords = bonePose.data;
numberOfFrames = numel(frameRecords);

%% PAIR EVERY ULTRASOUND FRAME WITH ITS BONE POSE

% The reviewed frames are stored in chronological order, but their original
% rigid-body row numbers are not necessarily consecutive. Therefore, do not use
% the loop index to choose a bone pose. Match the identifiers that describe the
% original source group, sequence file, and rigid-body row instead.
poseIndexByFrame = zeros(1, numberOfFrames);

for frameIndex = 1:numberOfFrames
    currentPlane = frameRecords(frameIndex).plane;

    poseMatches = ...
        [poseRecords.snapshotIndex] == currentPlane.snapshotIndex & ...
        [poseRecords.sequenceIndex] == currentPlane.sequenceIndex & ...
        [poseRecords.rigidBodyRowIndex] == currentPlane.rigidBodyRowIndex;

    matchingPoseIndex = find(poseMatches);
    if numel(matchingPoseIndex) ~= 1
        error('Expected one matching bone pose for ultrasound frame %d.', ...
            frameIndex);
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
boneTransformsRef = zeros(4, 4, numberOfFrames);

for frameIndex = 1:numberOfFrames
    currentPlane = frameRecords(frameIndex).plane;
    currentPose = poseRecords(poseIndexByFrame(frameIndex));

    imageTransformsRef(:, :, frameIndex) = currentPlane.T_image_ref;
    boneTransformsRef(:, :, frameIndex) = currentPose.T_CT_ref;
end

imageTransformsRefSmoothed = smoothTransformations( ...
    imageTransformsRef, ...
    'method', smoothingMethod, ...
    'window', smoothingWindow);

boneTransformsRefSmoothed = smoothTransformations( ...
    boneTransformsRef, ...
    'method', smoothingMethod, ...
    'window', smoothingWindow);

%% CALCULATE FIXED LIMITS FOR THE COMPLETE ANIMATION

% MATLAB normally changes the axes limits when plotted objects move. That would
% make the camera appear to zoom during the animation. Find the complete spatial
% extent first, then use one fixed set of limits for every frame.
sceneMinimum = [Inf, Inf, Inf];
sceneMaximum = [-Inf, -Inf, -Inf];

for frameIndex = 1:numberOfFrames
    currentPlane = frameRecords(frameIndex).plane;
    T_image_ref_smoothed = imageTransformsRefSmoothed(:, :, frameIndex);
    T_CT_ref_smoothed = boneTransformsRefSmoothed(:, :, frameIndex);

    % Mesh vertices are stored in CT coordinates. T_CT_ref maps a CT point into
    % ref coordinates, following the project convention:
    %
    %     p_ref = T_CT_ref * p_CT
    %
    % The anatomical T_bone_ref transform is not used here because the mesh
    % vertices do not live in the anatomical bone coordinate frame.
    bonePointsRef = applyRigidTransform( ...
        bonePose.meshCT.Points, T_CT_ref_smoothed);

    % These four points describe the ultrasound rectangle in its own image
    % frame. W and H are physical distances, so the corners use millimetres
    % rather than pixel indices.
    imageCorners = [ ...
        0,              0,              0; ...
        currentPlane.W, 0,              0; ...
        currentPlane.W, currentPlane.H, 0; ...
        0,              currentPlane.H, 0];

    % T_image_ref already contains the complete image -> probe -> ref transform
    % chain prepared during spatial processing. Applying it places the physical
    % ultrasound rectangle in the same ref coordinate system as the bone mesh.
    imageCornersRef = applyRigidTransform( ...
        imageCorners, T_image_ref_smoothed);

    currentPointsRef = [bonePointsRef; imageCornersRef];
    sceneMinimum = min(sceneMinimum, min(currentPointsRef, [], 1));
    sceneMaximum = max(sceneMaximum, max(currentPointsRef, [], 1));
end

% Add a small border around the moving data so objects do not touch the axes.
scenePadding = 0.05 * max(sceneMaximum - sceneMinimum);

%% PREPARE THE 3D SCENE

figureHandle = figure( ...
    'Name', 'Smoothed ultrasound and bone poses in ref', ...
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
firstBonePointsRef = applyRigidTransform( ...
    bonePose.meshCT.Points, boneTransformsRefSmoothed(:, :, 1));

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

for frameIndex = 1:numberOfFrames
    % Allow the animation to stop cleanly when the user closes its figure.
    if ~isvalid(figureHandle)
        break;
    end

    currentPlane = frameRecords(frameIndex).plane;
    T_image_ref_smoothed = imageTransformsRefSmoothed(:, :, frameIndex);
    T_CT_ref_smoothed = boneTransformsRefSmoothed(:, :, frameIndex);

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
    pixelSpacingX = currentPlane.W / (currentPlane.nCols - 1);
    pixelSpacingY = currentPlane.H / (currentPlane.nRows - 1);

    imageHandle = display_image3D( ...
        sceneAxes, currentPlane.image, T_image_ref_smoothed, ...
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
    imageAxisScale = 0.20 * max(currentPlane.W, currentPlane.H);
    display_axis_v2( ...
        sceneAxes, imageOriginRef, imageAxesRef, imageAxisScale, 'Image', ...
        'Tag', 'plot_sta_image_axes', ...
        'Mode', 'thin');

    title(sceneAxes, { ...
        sprintf('%s | Bone %s', string(snapshotGroup.name), boneCode), ...
        sprintf('Frame %d of %d | Source row %d | Timestamp %.3f s', ...
            frameIndex, numberOfFrames, currentPlane.rigidBodyRowIndex, ...
            double(currentPlane.timestamp))}, ...
        'Interpreter', 'none');

    drawnow;
    pause(frameDelaySeconds);
end
