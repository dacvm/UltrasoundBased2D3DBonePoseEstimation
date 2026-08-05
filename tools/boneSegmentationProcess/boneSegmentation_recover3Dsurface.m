clear; clc; close all;

%% SELECT INPUTS AND CONFIGURATION

% This script combines two artifacts from the same processing workflow:
% - boneSurface contains the detected bone coordinates in 2D image pixels.
% - validSnapshots contains the matching ultrasound images and their poses.
% Keep each directory and filename separate so selecting another run only
% requires changing these values.
filepath_boneSurface = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\bmodeimage_3dspace\tools\boneSegmentationProcess\outputs';
filename_boneSurface = 'boneSurface_20260806_011723.mat';
fullpath_boneSurface = fullfile(filepath_boneSurface, filename_boneSurface);

filepath_ultrasoundimage = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\bmodeimage_3dspace\tools\ultrasoundSpatialProcessing\outputs';
filename_ultrasoundimage = 'validSnapshots_20260804_152821.mat';
fullfile_ultrasoundimage = fullfile(filepath_ultrasoundimage, filename_ultrasoundimage);

%% PREPARE THE REQUIRED FUNCTION PATHS

% The script uses one geometry helper to transform points and one display
% helper to draw ultrasound images in 3D. Find these folders relative to this
% script instead of assuming that MATLAB was started in the project root.
scriptDirectory  = fileparts(mfilename('fullpath'));
projectDirectory = fileparts(fileparts(scriptDirectory));
geometryFunctionDirectory = fullfile(projectDirectory, 'functions', 'geometry');
displayFunctionDirectory  = fullfile(projectDirectory, 'functions', 'display');

% Stop here when the project layout is incomplete. Otherwise MATLAB would fail
% later with a less helpful "undefined function" message.
if ~isfolder(geometryFunctionDirectory) || ~isfolder(displayFunctionDirectory)
    error('boneSegmentation_recover3Dsurface:MissingFunctionDirectory', ...
        'The geometry or display function folder is missing.');
end
addpath(geometryFunctionDirectory, displayFunctionDirectory);

%% LOAD THE BONE SURFACE RESULTS

% LOAD with an output returns a temporary structure. Requesting the variable
% name explicitly avoids reading other large values stored in the MAT-file.
if ~isfile(fullpath_boneSurface)
    error('boneSegmentation_recover3Dsurface:MissingSurfaceFile', ...
        'Bone-surface file not found: %s', fullpath_boneSurface);
end
surfaceFileData = load(fullpath_boneSurface, 'surfaceResults');
if ~isfield(surfaceFileData, 'surfaceResults')
    error('boneSegmentation_recover3Dsurface:MissingSurfaceResults', ...
        'The selected MAT-file does not contain surfaceResults.');
end
surfaceResults = surfaceFileData.surfaceResults;
clear surfaceFileData;

% The extraction step must declare the complete result schema before this
% script fills the 3D coordinates. Reject older artifacts instead of silently
% creating a new field here, because that would make saved results inconsistent.
for groupIndex = 1:numel(surfaceResults)
    currentSurfaceData = surfaceResults(groupIndex).data;
    if ~isstruct(currentSurfaceData) || ...
            ~isfield(currentSurfaceData, 'surfaceCoordinatesRefXYZ')
        error('boneSegmentation_recover3Dsurface:MissingSurfaceCoordinatesRefXYZ', ...
            ['Surface group %d does not contain surfaceCoordinatesRefXYZ. ' ...
             'Rerun boneSegmentation_extractSurface.m to create a compatible MAT-file.'], ...
            groupIndex);
    end
end

%% LOAD THE ULTRASOUND SEQUENCE

% validSnapshots contains the image-plane geometry that belongs to the 2D
% surface results. Rename it to ultrasoundSequence after loading so this script
% uses the same terminology as the segmentation and extraction code.
if ~isfile(fullfile_ultrasoundimage)
    error('boneSegmentation_recover3Dsurface:MissingUltrasoundFile', ...
        'Valid-snapshot file not found: %s', fullfile_ultrasoundimage);
end
ultrasoundFileData = load(fullfile_ultrasoundimage, 'validSnapshots');
if ~isfield(ultrasoundFileData, 'validSnapshots')
    error('boneSegmentation_recover3Dsurface:MissingValidSnapshots', ...
        'The selected MAT-file does not contain validSnapshots.');
end
ultrasoundSequence = ultrasoundFileData.validSnapshots;
clear ultrasoundFileData;

%% CHECK THE ONE-TO-ONE CORRESPONDENCE

% The rest of the script uses this direct relationship:
%
%   surfaceResults(groupIndex).data(recordIndex)
%       belongs to
%   ultrasoundSequence(groupIndex).data(recordIndex)
%
% The upstream workflow preserves this order. These short checks make sure the
% user did not accidentally select files from different runs before any point
% is transformed with the wrong image pose.
numberOfSurfaceGroups = numel(surfaceResults);
if numberOfSurfaceGroups ~= numel(ultrasoundSequence)
    error('boneSegmentation_recover3Dsurface:GroupCountMismatch', ...
          'surfaceResults and ultrasoundSequence have different group counts.');
end

% Loop for all group (sensor location)
for groupIndex = 1:numberOfSurfaceGroups

    % A group describes one acquisition source, such as a bone and probe
    % location. Matching name, bone, and path confirms that both arrays refer
    % to the same source before comparing the records inside it.
    surfaceGroupIdentity = string({ ...
        surfaceResults(groupIndex).name, ...
        surfaceResults(groupIndex).bone, ...
        surfaceResults(groupIndex).path});
    ultrasoundGroupIdentity = string({ ...
        ultrasoundSequence(groupIndex).name, ...
        ultrasoundSequence(groupIndex).bone, ...
        ultrasoundSequence(groupIndex).path});
    if ~isequal(surfaceGroupIdentity, ultrasoundGroupIdentity)
        error('boneSegmentation_recover3Dsurface:GroupIdentityMismatch', ...
              'Surface and ultrasound group %d do not describe the same source.', ...
              groupIndex);
    end

    % Matching groups must contain the same number of selected ultrasound
    % frames. This lets recordIndex be used safely in both arrays.
    numberOfSurfaceRecords    = numel(surfaceResults(groupIndex).data);
    numberOfUltrasoundRecords = numel(ultrasoundSequence(groupIndex).data);
    if numberOfSurfaceRecords ~= numberOfUltrasoundRecords
        error('boneSegmentation_recover3Dsurface:RecordCountMismatch', ...
            'Surface and ultrasound group %d have different record counts.', ...
            groupIndex);
    end

    % Equal counts alone are not enough: two groups could contain different
    % frames. sourceIndex identifies the original selected snapshot, so equal
    % source-index sequences confirm the record-by-record pairing.
    surfaceSourceIndices    = [surfaceResults(groupIndex).data.sourceIndex];
    ultrasoundSourceIndices = [ultrasoundSequence(groupIndex).data.sourceIndex];
    if ~isequal(surfaceSourceIndices, ultrasoundSourceIndices)
        error('boneSegmentation_recover3Dsurface:SourceIndexMismatch', ...
              'Surface and ultrasound source indices differ in group %d.', ...
              groupIndex);
    end
end

%% CONVERT THE 2D SURFACES INTO THE REFERENCE FRAME

% The coordinate conversion has two clear stages:
%
%   [column,row] pixels
%       -> [x_mm,y_mm,0] in the local image frame
%       -> [X_ref,Y_ref,Z_ref] using T_image_ref
%
% Process every paired record and store the 3D result beside its original 2D
% surface data. The counters are only used for the summary printed at the end.
totalRecoveredPointCount = 0;
totalSurfaceRecordCount = 0;

% Loop for all group (sensor location)
for groupIndex = 1:numberOfSurfaceGroups

    % Loop for all data within a group
    for recordIndex = 1:numel(surfaceResults(groupIndex).data)

        % Read both sides of the verified pair together. currentSurfaceResult
        % supplies the pixels, while currentPlane supplies physical size and
        % the image-to-reference transformation.
        currentSurfaceResult = surfaceResults(groupIndex).data(recordIndex);
        currentPlane = ultrasoundSequence(groupIndex).data(recordIndex).plane;

        % W and H span the first-to-last pixel centres, so divide each extent
        % by one fewer than the corresponding number of pixels.
        pixelSpacingXYMm = [ ...
            double(currentPlane.W) / (double(currentPlane.nCols) - 1), ...
            double(currentPlane.H) / (double(currentPlane.nRows) - 1)];

        % surfacePixelCoordinatesXY stores one-based [column,row] positions.
        % Subtract one to place the first pixel centre at image-frame [0,0].
        surfacePixelCoordinatesXY  = double(currentSurfaceResult.surfacePixelCoordinatesXY);
        numberOfSurfacePoints      = size(surfacePixelCoordinatesXY, 1);
        surfaceCoordinatesImageXYZ = [ ...
            (surfacePixelCoordinatesXY(:, 1) - 1) * pixelSpacingXYMm(1), ...
            (surfacePixelCoordinatesXY(:, 2) - 1) * pixelSpacingXYMm(2), ...
            zeros(numberOfSurfacePoints, 1)];

        % Ultrasound pixels lie on the image plane, so their local Z coordinate
        % is zero. applyRigidTransform applies both the rotation and translation
        % in T_image_ref to produce physical points in the ref frame. Fill the
        % field that was already declared by the surface extraction step.
        surfaceCoordinatesRefXYZ = applyRigidTransform(surfaceCoordinatesImageXYZ, currentPlane.T_image_ref);
        surfaceResults(groupIndex).data(recordIndex).surfaceCoordinatesRefXYZ = surfaceCoordinatesRefXYZ;

        totalRecoveredPointCount = totalRecoveredPointCount + numberOfSurfacePoints;
        totalSurfaceRecordCount  = totalSurfaceRecordCount + 1;
    end
end

%% SHOW THE DETECTED BONE SURFACE IN 3D SPACE

% Create one shared 3D scene. Every plane and point is already expressed in
% ref, so they can be plotted together without any additional transformation.
fig1 = figure('Name', 'Recovered 3D Bone Surfaces');
ax1 = axes(fig1);
xlabel(ax1, 'X_{ref} (mm)');
ylabel(ax1, 'Y_{ref} (mm)');
zlabel(ax1, 'Z_{ref} (mm)');
title(ax1, 'Recovered bone surfaces and ultrasound image planes');
grid(ax1, 'on');
axis(ax1, 'equal');
hold(ax1, 'on');
view(ax1, 35, 40);

% Draw all ultrasound planes before drawing the bone points. The original
% image arrays use [width,height] storage, so SwapXY restores normal displayed
% [row,column] orientation. The same pixel spacing used during conversion
% guarantees that the texture and recovered points occupy the same plane.
imagePlaneAlpha = 0.08;

% Loop for all group (sensor location)
for groupIndex = 1:numberOfSurfaceGroups

    % Loop for all data within a group
    for recordIndex = 1:numel(surfaceResults(groupIndex).data)
        
        % Get current plane
        currentPlane = ultrasoundSequence(groupIndex).data(recordIndex).plane;
        % Compute the spacing for display
        pixelSpacingXYMm = [ ...
            double(currentPlane.W) / (double(currentPlane.nCols) - 1), ...
            double(currentPlane.H) / (double(currentPlane.nRows) - 1)];

        imagePlaneHandle = display_image3D( ...
            ax1, currentPlane.image, currentPlane.T_image_ref, ...
            'SwapXY', true, ...
            'PixelSpacing', pixelSpacingXYMm, ...
            'Tag', 'recovered_image_plane', ...
            'Colormap', 'gray', ...
            'FaceAlpha', imagePlaneAlpha);

        % Image planes provide context but should not create 30 legend entries.
        imagePlaneHandle.HandleVisibility = 'off';
    end
end

% Draw each recovered path as unconnected points. Connecting all points with a
% line could incorrectly bridge gaps between separate detected surface parts.
% A shared color identifies records from the same acquisition group.
surfaceGroupNames       = string({surfaceResults.name});
surfaceGroupBones       = string({surfaceResults.bone});
surfaceGroupColors      = lines(max(numberOfSurfaceGroups, 1));
hasVisibleSurfaceGroup  = false(1, numberOfSurfaceGroups);

% Loop for all group (sensor location)
for groupIndex = 1:numberOfSurfaceGroups

    % Loop for all data within a group
    for recordIndex = 1:numel(surfaceResults(groupIndex).data)

        % Get current data
        surfaceCoordinatesRefXYZ = surfaceResults(groupIndex).data(recordIndex).surfaceCoordinatesRefXYZ;

        % Some valid records may contain no detected surface. Their image plane
        % remains visible, but there are no 3D bone points to draw.
        if isempty(surfaceCoordinatesRefXYZ)
            continue;
        end

        % Display the 3d bone surface
        boneSurfaceHandle = scatter3(ax1, ...
            surfaceCoordinatesRefXYZ(:, 1), ...
            surfaceCoordinatesRefXYZ(:, 2), ...
            surfaceCoordinatesRefXYZ(:, 3), ...
            10, surfaceGroupColors(groupIndex, :), 'filled', ...
            'Tag', 'recovered_bone_surface');

        % Use the first visible record as the group's legend representative.
        % Hide later records from the legend without hiding their points.
        if ~hasVisibleSurfaceGroup(groupIndex)
            boneSurfaceHandle.DisplayName      = sprintf('%s (%s)', surfaceGroupNames(groupIndex), surfaceGroupBones(groupIndex));
            hasVisibleSurfaceGroup(groupIndex) = true;
        else
            boneSurfaceHandle.HandleVisibility = 'off';
        end
    end
end

% Empty groups do not need a legend entry. After all objects are present, fit
% the limits to the complete scene while preserving equal physical axis scale.
if any(hasVisibleSurfaceGroup)
    legend(ax1, 'show', 'Location', 'best');
end

axis(ax1, 'tight');
axis(ax1, 'equal');
drawnow;

fprintf('Recovered %d bone-surface point(s) from %d record(s) in ref.\n', totalRecoveredPointCount, totalSurfaceRecordCount);
