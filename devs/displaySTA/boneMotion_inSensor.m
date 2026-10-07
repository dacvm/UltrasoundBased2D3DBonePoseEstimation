clear; clc; close all;

%% SETTINGS

% Use a fixed delay between displayed frames. This controls playback speed only;
% it does not change the acquisition timestamps used for temporal alignment.
frameDelaySeconds = 0.05;

% Set this to true to record the complete figure as an MP4 video. Set it to
% false when only an interactive visualization is needed. The Code Analyzer
% suppression is needed because the disabled recording branches are expected
% to be unreachable while this user setting is false.
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

% Store one simple skin-to-bone distance estimate for every displayed
% timeframe. Each estimate comes only from the extracted ultrasound surface:
% the mean describes its average depth, while the standard deviation describes
% how much the extracted surface depth varies across that image.
dest_bone_mean = zeros(1, numberOfDisplayedFrames);
dest_bone_std = zeros(1, numberOfDisplayedFrames);

% The ground-truth surface is the part of the CT bone mesh that the image plane
% cuts and that faces the probe (intersection.probeFacingPixels). This is the
% surface ultrasound can actually show; the raw intersection would also include
% the far side of the bone. Its depth statistics mirror the extracted ones.
groundTruthPointsImageByDisplayedFrame = cell(1, numberOfDisplayedFrames);
dgt_bone_mean = zeros(1, numberOfDisplayedFrames);
dgt_bone_std = zeros(1, numberOfDisplayedFrames);

for displayedFrameIndex = 1:numberOfDisplayedFrames
    poseFrameIndex = poseIndexByDisplayedFrame(displayedFrameIndex);
    imageFrameIndex = imageIndexByDisplayedFrame(displayedFrameIndex);
    surfaceIndex = surfaceIndexByDisplayedFrame(displayedFrameIndex);
    imagePlane = frameRecords(imageFrameIndex).plane;
    surfaceCoordinatesXY = ...
        double(surfaceRecords(surfaceIndex).surfaceCoordinatesXY);

    pixelSpacingX = imagePlane.W / (imagePlane.nCols - 1);
    pixelSpacingY = imagePlane.H / (imagePlane.nRows - 1);
    numberOfSurfacePoints = size(surfaceCoordinatesXY, 1);

    surfacePointsImage = [ ...
        (surfaceCoordinatesXY(:, 1) - 1) * pixelSpacingX, ...
        (surfaceCoordinatesXY(:, 2) - 1) * pixelSpacingY, ...
        zeros(numberOfSurfacePoints, 1)];

    surfacePointsImageByDisplayedFrame{displayedFrameIndex} = ...
        surfacePointsImage;

    % The image origin represents the sensor-side edge of the image. Therefore,
    % the physical Y_image coordinate is the requested depth from the sensor.
    % This is the same conversion used to place the surface points on the image.
    dest_bone = surfacePointsImage(:, 2);
    dest_bone_mean(displayedFrameIndex) = mean(dest_bone);
    dest_bone_std(displayedFrameIndex) = std(dest_bone);

    % WHY THE GROUND TRUTH USES poseFrameIndex, NOT imageFrameIndex
    %
    % Each displayed frame combines two acquisition rows:
    %   - poseFrameIndex  (time t):        the rigid-body poses, which place
    %                                      the bone mesh in this scene.
    %   - imageFrameIndex (time t + delay): the ultrasound pixels, and so the
    %                                      extracted surface.
    % The delay is a property of the PIXELS only: the pixels stored at
    % t + delay show the bone as it was at time t. Pairing the two rows
    % shifts the pixels back so that the image, the extracted surface, and
    % the displayed mesh all describe the same physical moment t.
    %
    % The intersection contains NO pixels. The intersection tool computed it
    % purely from the plane pose and bone pose of its own row (CT mesh cut by
    % the image plane), without any delay. So intersection(poseFrameIndex)
    % describes moment t, which is the same moment as the displayed mesh and
    % the delay-corrected image. In the 3D scene it lies on the displayed
    % mesh, up to the small difference between raw and smoothed poses.
    %
    % Using intersection(imageFrameIndex) instead would describe the bone
    % at t + delay. It would sit off the displayed mesh, and in dplotAxes the
    % ground-truth curve would shift by the delay (about 4 rows here)
    % relative to the extracted curve. That would bring back the lag the
    % pairing above removes, and the depth comparison would mix two moments.
    %
    % A useful side effect: the extracted curve (pixels) and the ground-truth
    % curve (poses) are aligned only through temporalDelaySeconds. If their
    % dips consistently lead or lag each other, the delay setting is off.
    %
    % probeFacingPixels is one-based [row,column], the reverse of
    % surfaceCoordinatesXY, so swap the columns before the same conversion.
    groundTruthPixels = ...
        frameRecords(poseFrameIndex).intersection.probeFacingPixels;
    numberOfGroundTruthPoints = size(groundTruthPixels, 1);

    groundTruthPointsImage = [ ...
        (groundTruthPixels(:, 2) - 1) * pixelSpacingX, ...
        (groundTruthPixels(:, 1) - 1) * pixelSpacingY, ...
        zeros(numberOfGroundTruthPoints, 1)];

    groundTruthPointsImageByDisplayedFrame{displayedFrameIndex} = ...
        groundTruthPointsImage;

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
    groundTruthPointsImage = ...
        groundTruthPointsImageByDisplayedFrame{displayedFrameIndex};

    imageCorners = [ ...
        0,            0,            0; ...
        imagePlane.W, 0,            0; ...
        imagePlane.W, imagePlane.H, 0; ...
        0,            imagePlane.H, 0];

    currentPointsImage = [bonePointsImage; imageCorners; ...
        surfacePointsImage; groundTruthPointsImage];
    sceneMinimum = min(sceneMinimum, min(currentPointsImage, [], 1));
    sceneMaximum = max(sceneMaximum, max(currentPointsImage, [], 1));
end

scenePadding = 0.05 * max(sceneMaximum - sceneMinimum);

%% PREPARE THE IMAGE-FRAME FIGURE

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

hold(sceneAxes, 'on');
grid(sceneAxes, 'on');
axis(sceneAxes, 'equal');
view(sceneAxes, -40, 40);
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

% Bone depth follows the positive Y_image direction, so use green for every
% depth indicator. This darker green is easier to read than pure [0, 1, 0],
% especially against the white plot background and grayscale ultrasound image.
meanDistanceColor = [0.10, 0.55, 0.20];
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

% The ground-truth points are already in the image frame, which is the frame of
% this whole scene, so they are plotted directly like the extracted surface.
groundTruthColor = [1, 0, 1];
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
firstImageColumnX = 0;
meanDistanceDisplayOffset = 0.002 * ...
    max(firstImagePlane.W, firstImagePlane.H);
meanDistanceLine = plot3(sceneAxes, ...
    [firstImageColumnX, firstImageColumnX], ...
    [0, dest_bone_mean(1)], ...
    [meanDistanceDisplayOffset, meanDistanceDisplayOffset], ...
    '-', ...
    'Color', 'g', ...
    'LineWidth', 1, ...
    'DisplayName', 'Mean bone distance');
meanDistanceEndpoint = scatter3(sceneAxes, ...
    firstImageColumnX, dest_bone_mean(1), meanDistanceDisplayOffset, ...
    42, meanDistanceColor, 'filled', ...
    'MarkerEdgeColor', 'white', ...
    'LineWidth', 1, ...
    'HandleVisibility', 'off');

% Add row-wise guides across the image so the mean and its spread can be read
% spatially. The thick dashed guide marks the mean depth. The two thin dashed
% guides mark one standard deviation below and above the mean.
% meanDepthGuideLine = plot3(sceneAxes, ...
%     [0, firstImagePlane.W], ...
%     [dest_bone_mean(1), dest_bone_mean(1)], ...
%     [meanDistanceDisplayOffset, meanDistanceDisplayOffset], ...
%     '--', ...
%     'Color', meanDistanceColor, ...
%     'LineWidth', 3, ...
%     'HandleVisibility', 'off');
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

camlight(sceneAxes, 'headlight');
lighting(sceneAxes, 'gouraud');
colormap(sceneAxes, gray(256));

imageHandle = gobjects(0);
T_image_image = eye(4);

% Plot the complete distance history before starting the animation. This keeps
% the distance curve fixed while only the current-frame indicators move.
timeframeValues = 1:numberOfDisplayedFrames;
distanceLowerBound = dest_bone_mean - dest_bone_std;
distanceUpperBound = dest_bone_mean + dest_bone_std;

hold(dplotAxes, 'on');
grid(dplotAxes, 'on');

fill(dplotAxes, ...
    [timeframeValues, fliplr(timeframeValues)], ...
    [distanceLowerBound, fliplr(distanceUpperBound)], ...
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
    [timeframeValues, fliplr(timeframeValues)], ...
    [dgt_bone_mean - dgt_bone_std, ...
     fliplr(dgt_bone_mean + dgt_bone_std)], ...
    groundTruthColor, ...
    'FaceAlpha', 0.20, ...
    'EdgeColor', 'none', ...
    'DisplayName', 'Ground truth: mean \pm std');

plot(dplotAxes, timeframeValues, dgt_bone_mean, ...
    'Color', groundTruthColor, ...
    'LineWidth', 1.8, ...
    'DisplayName', 'Ground truth: mean');

% These two handles are updated inside the animation loop. The line shows the
% current timeframe, and the point shows its corresponding mean bone distance.
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

    groundTruthPointsImage = ...
        groundTruthPointsImageByDisplayedFrame{displayedFrameIndex};
    groundTruthHandle.XData = groundTruthPointsImage(:, 1);
    groundTruthHandle.YData = groundTruthPointsImage(:, 2);
    groundTruthHandle.ZData = groundTruthPointsImage(:, 3);

    % Update the first-column ruler, its endpoint, and all three row-wise depth
    % guides. Reading W from the current image also keeps the guides correct if a
    % future dataset contains frames with a different physical image width.
    meanDistanceLine.YData = [0, dest_bone_mean(displayedFrameIndex)];
    meanDistanceEndpoint.YData = dest_bone_mean(displayedFrameIndex);

    currentMeanDepth = dest_bone_mean(displayedFrameIndex);
    currentDepthStd = dest_bone_std(displayedFrameIndex);
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

    % Keep the distance plot synchronized with the 3D scene. Both indicators use
    % displayedFrameIndex, so they always refer to the image currently shown.
    currentTimeframeLine.Value = displayedFrameIndex;
    currentDistancePoint.XData = displayedFrameIndex;
    currentDistancePoint.YData = dest_bone_mean(displayedFrameIndex);
    currentGroundTruthPoint.XData = displayedFrameIndex;
    currentGroundTruthPoint.YData = dgt_bone_mean(displayedFrameIndex);

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

    drawnow;

    % Capture the complete maximized figure after both axes have been updated.
    % When recording is disabled, MATLAB skips all video-related work.
    if recordVisualization
        videoFrame = getframe(figureHandle);
        writeVideo(videoWriter, videoFrame);
    end

    pause(frameDelaySeconds);
end

% Finalize the MP4 so it can be opened immediately after the script finishes.
if recordVisualization
    close(videoWriter);
    fprintf('Animation saved to:\n%s\n', videoFilePath);
end
