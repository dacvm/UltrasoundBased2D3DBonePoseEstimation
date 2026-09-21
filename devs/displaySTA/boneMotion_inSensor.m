clear; clc; close all;

%% SETTINGS

% Use a fixed delay between displayed frames. This controls playback speed only;
% it does not change the acquisition timestamps used for temporal alignment.
frameDelaySeconds = 0.05;

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
scriptDirectory = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(scriptDirectory));
addpath(genpath(fullfile(projectRoot, 'functions')));

snapshotFilePath = fullfile(projectRoot, 'tools', ...
    'ultrasoundSpatialProcessing', 'outputs', ...
    'validSnapshots_20260919_110840_meas04c.mat');
snapshotData = load(snapshotFilePath, 'validSnapshots', 'validBonePoses');

surfaceFilePath = fullfile(projectRoot, 'tools', ...
    'boneSegmentationProcess', 'outputs', ...
    'boneSurface_20260921_172157.mat');
surfaceData = load(surfaceFilePath, 'surfaceResults');

% Select the reviewed ultrasound sequence and its CT mesh/pose sequence.
snapshotGroup = snapshotData.validSnapshots(1);
frameRecords = snapshotGroup.data;
boneCode = string(snapshotGroup.bone);
numberOfFrames = numel(frameRecords);

availableBoneCodes = string({snapshotData.validBonePoses.bonePoses.bone});
bonePoseIndex = find(availableBoneCodes == boneCode, 1);
bonePose = snapshotData.validBonePoses.bonePoses(bonePoseIndex);
poseRecords = bonePose.data;

% Select the extracted-surface group describing the same acquisition and bone.
surfaceGroupNames = string({surfaceData.surfaceResults.name});
surfaceGroupBones = string({surfaceData.surfaceResults.bone});
surfaceGroupIndex = find( ...
    surfaceGroupNames == string(snapshotGroup.name) & ...
    surfaceGroupBones == boneCode, 1);
surfaceRecords = surfaceData.surfaceResults(surfaceGroupIndex).data;

%% MATCH EACH ULTRASOUND FRAME TO ITS BONE POSE AND SURFACE RECORD

% Reviewed frame numbers can skip original acquisition rows. Match records by
% their stored identities instead of assuming unrelated arrays share an index.
poseIndexByFrame = zeros(1, numberOfFrames);
surfaceIndexByFrame = zeros(1, numberOfFrames);
surfaceSourceIndices = [surfaceRecords.sourceIndex];

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

    frameSourceIndex = frameRecords(frameIndex).sourceIndex;
    surfaceIndexByFrame(frameIndex) = find( ...
        surfaceSourceIndices == frameSourceIndex, 1);
end

%% SMOOTH THE IMAGE AND BONE POSE SEQUENCES

% T_image_ref maps image -> ref, while T_CT_ref maps CT -> ref. Build and
% smooth the two trajectories separately before combining their relative motion.
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

%% PAIR EACH EARLIER POSE WITH ITS DELAYED ULTRASOUND IMAGE

% If an image is delayed, pixels showing the event at pose time t are stored near
% t + delay. Keep the two rigid-body poses at time t, but select pixels and the
% extracted surface from the nearest later image timestamp.
allPlanes = [frameRecords.plane];
recordedTimes = double([allPlanes.timestamp]);
targetImageTimes = recordedTimes + temporalDelaySeconds;

hasAvailableImage = ...
    targetImageTimes >= recordedTimes(1) & ...
    targetImageTimes <= recordedTimes(end);
poseIndexByDisplayedFrame = find(hasAvailableImage);
numberOfDisplayedFrames = numel(poseIndexByDisplayedFrame);

if numberOfDisplayedFrames == 0
    error('The temporal delay leaves no overlapping pose and image data.');
end

imageIndexByDisplayedFrame = zeros(1, numberOfDisplayedFrames);
pairedDelaySeconds = zeros(1, numberOfDisplayedFrames);

for displayedFrameIndex = 1:numberOfDisplayedFrames
    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);
    targetImageTime = targetImageTimes(poseFrameIndex);
    [~, imageFrameIndex] = min(abs(recordedTimes - targetImageTime));

    imageIndexByDisplayedFrame(displayedFrameIndex) = imageFrameIndex;
    pairedDelaySeconds(displayedFrameIndex) = ...
        recordedTimes(imageFrameIndex) - recordedTimes(poseFrameIndex);
end

% Surface extraction belongs to the delayed image pixels, so use the surface
% record associated with imageFrameIndex rather than poseFrameIndex.
surfaceIndexByDisplayedFrame = ...
    surfaceIndexByFrame(imageIndexByDisplayedFrame);

%% RECONSTRUCT SURFACE POINTS IN THE LOCAL IMAGE FRAME

% surfaceCoordinatesXY contains one-based [column,row] image coordinates. Turn
% them into physical [X_image,Y_image,0] points. They can then be plotted directly
% in this image-frame visualization without using an unsmoothed tracking pose.
surfacePointsImageByDisplayedFrame = cell(1, numberOfDisplayedFrames);

for displayedFrameIndex = 1:numberOfDisplayedFrames
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);
    surfaceIndex = surfaceIndexByDisplayedFrame(displayedFrameIndex);
    imagePlane = frameRecords(imageFrameIndex).plane;
    surfaceCoordinatesXY = ...
        double(surfaceRecords(surfaceIndex).surfaceCoordinatesXY);

    pixelSpacingX = imagePlane.W / (imagePlane.nCols - 1);
    pixelSpacingY = imagePlane.H / (imagePlane.nRows - 1);
    numberOfSurfacePoints = size(surfaceCoordinatesXY, 1);

    surfacePointsImageByDisplayedFrame{displayedFrameIndex} = [ ...
        (surfaceCoordinatesXY(:, 1) - 1) * pixelSpacingX, ...
        (surfaceCoordinatesXY(:, 2) - 1) * pixelSpacingY, ...
        zeros(numberOfSurfacePoints, 1)];
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
T_CT_imageByDisplayedFrame = zeros(4, 4, numberOfDisplayedFrames);

for displayedFrameIndex = 1:numberOfDisplayedFrames
    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);
    T_image_ref_smoothed = ...
        imageTransformsRefSmoothed(:, :, poseFrameIndex);
    T_CT_ref_smoothed = ...
        boneTransformsRefSmoothed(:, :, poseFrameIndex);
    T_CT_imageByDisplayedFrame(:, :, displayedFrameIndex) = ...
        T_image_ref_smoothed \ T_CT_ref_smoothed;
end

%% CALCULATE FIXED IMAGE-FRAME AXES LIMITS

% Include every moving bone pose, the fixed image rectangle, and the extracted
% surface points so the camera limits remain unchanged throughout playback.
sceneMinimum = [Inf, Inf, Inf];
sceneMaximum = [-Inf, -Inf, -Inf];

for displayedFrameIndex = 1:numberOfDisplayedFrames
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);
    imagePlane = frameRecords(imageFrameIndex).plane;
    bonePointsImage = applyRigidTransform( ...
        bonePose.meshCT.Points, ...
        T_CT_imageByDisplayedFrame(:, :, displayedFrameIndex));
    surfacePointsImage = ...
        surfacePointsImageByDisplayedFrame{displayedFrameIndex};

    imageCorners = [ ...
        0,            0,            0; ...
        imagePlane.W, 0,            0; ...
        imagePlane.W, imagePlane.H, 0; ...
        0,            imagePlane.H, 0];

    currentPointsImage = [bonePointsImage; imageCorners; surfacePointsImage];
    sceneMinimum = min(sceneMinimum, min(currentPointsImage, [], 1));
    sceneMaximum = max(sceneMaximum, max(currentPointsImage, [], 1));
end

scenePadding = 0.05 * max(sceneMaximum - sceneMinimum);

%% PREPARE THE IMAGE-FRAME FIGURE

figureHandle = figure( ...
    'Name', 'Bone motion relative to the ultrasound image', ...
    'Color', 'white');
sceneAxes = axes(figureHandle);

hold(sceneAxes, 'on');
grid(sceneAxes, 'on');
axis(sceneAxes, 'equal');
view(sceneAxes, -60, 40);
xlabel(sceneAxes, 'X_{image} (mm)');
ylabel(sceneAxes, 'Y_{image} (mm)');
zlabel(sceneAxes, 'Z_{image} (mm)');

xlim(sceneAxes, [sceneMinimum(1) - scenePadding, ...
                  sceneMaximum(1) + scenePadding]);
ylim(sceneAxes, [sceneMinimum(2) - scenePadding, ...
                  sceneMaximum(2) + scenePadding]);
zlim(sceneAxes, [sceneMinimum(3) - scenePadding, ...
                  sceneMaximum(3) + scenePadding]);

firstImageFrameIndex = imageIndexByDisplayedFrame(1);
firstImagePlane = frameRecords(firstImageFrameIndex).plane;
imageAxisScale = 0.20 * max(firstImagePlane.W, firstImagePlane.H);
display_axis_v2( ...
    sceneAxes, zeros(3, 1), eye(3), imageAxisScale, 'Image', ...
    'Tag', 'plot_bone_motion_image_axes', ...
    'Mode', 'thin');

firstBonePointsImage = applyRigidTransform( ...
    bonePose.meshCT.Points, T_CT_imageByDisplayedFrame(:, :, 1));
boneHandle = patch(sceneAxes, ...
    'Faces', bonePose.meshCT.ConnectivityList, ...
    'Vertices', firstBonePointsImage, ...
    'FaceColor', [0.92, 0.83, 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.45, ...
    'DisplayName', 'Bone mesh');

firstSurfacePointsImage = surfacePointsImageByDisplayedFrame{1};
surfaceHandle = scatter3(sceneAxes, ...
    firstSurfacePointsImage(:, 1), ...
    firstSurfacePointsImage(:, 2), ...
    firstSurfacePointsImage(:, 3), ...
    3, 'red', 'filled', ...
    'MarkerEdgeColor', 'none', ...
    'DisplayName', 'Extracted ultrasound surface');

camlight(sceneAxes, 'headlight');
lighting(sceneAxes, 'gouraud');
colormap(sceneAxes, gray(256));

imageHandle = gobjects(0);
T_image_image = eye(4);

%% DISPLAY BONE MOTION IN THE IMAGE FRAME

for displayedFrameIndex = 1:numberOfDisplayedFrames
    if ~isvalid(figureHandle)
        break;
    end

    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);
    posePlane = frameRecords(poseFrameIndex).plane;
    imagePlane = frameRecords(imageFrameIndex).plane;

    boneHandle.Vertices = applyRigidTransform( ...
        bonePose.meshCT.Points, ...
        T_CT_imageByDisplayedFrame(:, :, displayedFrameIndex));

    surfacePointsImage = ...
        surfacePointsImageByDisplayedFrame{displayedFrameIndex};
    surfaceHandle.XData = surfacePointsImage(:, 1);
    surfaceHandle.YData = surfacePointsImage(:, 2);
    surfaceHandle.ZData = surfacePointsImage(:, 3);

    % Only the image texture changes. Identity keeps its physical plane fixed in
    % the image coordinate frame for every animation step.
    if ~isempty(imageHandle) && isvalid(imageHandle)
        delete(imageHandle);
    end

    pixelSpacingX = imagePlane.W / (imagePlane.nCols - 1);
    pixelSpacingY = imagePlane.H / (imagePlane.nRows - 1);
    imageHandle = display_image3D( ...
        sceneAxes, imagePlane.image, T_image_image, ...
        'SwapXY', true, ...
        'PixelSpacing', [pixelSpacingX, pixelSpacingY], ...
        'Tag', 'plot_bone_motion_ultrasound_image', ...
        'Colormap', 'gray', ...
        'FaceAlpha', 0.75);

    title(sceneAxes, { ...
        sprintf('%s | Bone %s | Ultrasound image frame', ...
            string(snapshotGroup.name), boneCode), ...
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
