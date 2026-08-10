clear; clc; close all;

%% PATH DEFINITION

filepath_ultrasoundimage = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\bmodeimage_3dspace\tools\ultrasoundSpatialProcessing\outputs';
filename_ultrasoundimage = 'validSnapshots_20260810_120415.mat';

filepath_bonesurface = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\bmodeimage_3dspace\tools\boneSegmentationProcess\outputs';
filename_bonesurface = 'boneSurface_20260810_123356.mat';

filepath_ctmat = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\bmodeimage_3dspace\tools\ctkneePostProcess\outputs\kneephantom';
filename_ctmat = 'kneephantom_bones_and_bonepins.mat';

filepath_bonelandmarks = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\bmodeimage_3dspace\tools\bonePreRegistration\outputs\';
filename_bonelandmarks = 'boneLandmarks_20260810_174351.mat';

%% REQUIRED PATH

% Locate this script first so the configuration file can be found even when
% MATLAB was started from a different current folder.
scriptFullPath = mfilename('fullpath');
if isempty(scriptFullPath)
    error('bonePreRegistration:ScriptPathUnavailable', ...
          'Run boneSegmentation_recover3Dsurface.m as a complete script so its configuration file can be located.');
end
scriptDirectory = fileparts(scriptFullPath);

% The script uses one geometry helper to transform points and one display
% helper to draw ultrasound images in 3D. Find these folders relative to this
% script instead of assuming that MATLAB was started in the project root.
projectDirectory = fileparts(fileparts(scriptDirectory));
geometryFunctionDirectory = fullfile(projectDirectory, 'functions', 'geometry');
displayFunctionDirectory  = fullfile(projectDirectory, 'functions', 'display');

% Stop here when the project layout is incomplete. Otherwise MATLAB would fail
% later with a less helpful "undefined function" message.
if ~isfolder(geometryFunctionDirectory) || ~isfolder(displayFunctionDirectory)
    error('bonePreRegistration:MissingFunctionDirectory', ...
          'The geometry or display function folder is missing.');
end
addpath(geometryFunctionDirectory, displayFunctionDirectory);


%% LOAD THE ULTRASOUND IMAGE DATA

% Load the MAT-file into a structure so its saved variable does not appear
% directly in the script workspace under an unknown name.
ultrasoundFilePath = fullfile(filepath_ultrasoundimage, filename_ultrasoundimage);
ultrasoundFileData = load(ultrasoundFilePath);

% Require one saved variable so the script cannot silently choose the wrong
% data when a MAT-file contains unrelated values.
savedVariableNames = fieldnames(ultrasoundFileData);
if numel(savedVariableNames) ~= 1
    error('bonePreRegistration:UnexpectedUltrasoundVariables', ...
          'Expected exactly one variable in "%s", but found %d.', ...
          filename_ultrasoundimage, numel(savedVariableNames));
end

% Give the loaded sequence one stable name for the segmentation workflow.
ultrasoundSequence = ultrasoundFileData.(savedVariableNames{1});
clear ultrasoundFileData savedVariableNames;

%% LOAD DETECTED SURFACE DATA

% LOAD with an output returns a temporary structure. Requesting both required
% variables explicitly avoids reading other large values stored in the MAT-file.
fullpath_boneSurface     = fullfile(filepath_bonesurface, filename_bonesurface);
if ~isfile(fullpath_boneSurface)
    error('bonePreRegistration:MissingSurfaceFile', ...
        'Bone-surface file not found: %s', fullpath_boneSurface);
end
surfaceFileData = load(fullpath_boneSurface, 'surfaceResults', 'extractionMetadata');
if ~isfield(surfaceFileData, 'surfaceResults')
    error('bonePreRegistration:MissingSurfaceResults', ...
          'The selected MAT-file does not contain surfaceResults.');
end
if ~isfield(surfaceFileData, 'extractionMetadata')
    error('bonePreRegistration:MissingExtractionMetadata', ...
          'The selected MAT-file does not contain extractionMetadata.');
end
surfaceResults     = surfaceFileData.surfaceResults;
extractionMetadata = surfaceFileData.extractionMetadata;
clear surfaceFileData;

% The extraction step must declare the complete result schema before this
% script fills the 3D coordinates. Reject older artifacts instead of silently
% creating a new field here, because that would make saved results inconsistent.
for groupIndex = 1:numel(surfaceResults)
    currentSurfaceData = surfaceResults(groupIndex).data;
    if ~isstruct(currentSurfaceData) || ~isfield(currentSurfaceData, 'surfaceCoordinatesXYZRef')
        error('bonePreRegistration:MissingSurfaceCoordinatesXYZRef', ...
              ['Surface group %d does not contain surfaceCoordinatesXYZRef.' ...
               'Rerun boneSegmentation_extractSurface.m to create a compatible MAT-file.'], ...
            groupIndex);
    end
end


%% LOAD BONE DATA

% Build and check the exact MAT-file path before attempting to load it.
ctmatFullPath = fullfile(filepath_ctmat, filename_ctmat);
if ~isfile(ctmatFullPath)
    error('bonePreRegistration:MissingCtMatFile', ...
        'The configured CT MAT file does not exist: %s', ctmatFullPath);
end

% Load only the variable needed by this workflow so unrelated saved values
% cannot accidentally replace settings or intermediate variables.
loadedCtData = load(ctmatFullPath, 'bones', 'bonepins');
if ~isfield(loadedCtData, 'bones')
    error('bonePreRegistration:MissingBonesVariable', ...
          'The CT MAT file does not contain a variable named bones: %s', ...
          ctmatFullPath);
end
bones = loadedCtData.bones;
if ~isfield(loadedCtData, 'bonepins')
    error('bonePreRegistration:MissingBonepinsVariable', ...
          'The CT MAT file does not contain a variable named bonepins: %s', ...
          ctmatFullPath);
end
bonepins = loadedCtData.bonepins;

%% LOAD BONE LANDMARKS

% Build and check the exact MAT-file path before attempting to load it.
bonelandmarksFullPath = fullfile(filepath_bonelandmarks, filename_bonelandmarks);
if ~isfile(bonelandmarksFullPath)
    error('bonePreRegistration:MissingBoneLandmarksFile', ...
          'The configured bone-landmarks MAT file does not exist: %s', ...
          bonelandmarksFullPath);
end

% Load only the two expected variables so unrelated saved values cannot
% accidentally replace settings or intermediate variables in this script.
loadedBoneLandmarks = load(bonelandmarksFullPath, ...
                           'intersectionDiagnostics', 'landmarks');
if ~isfield(loadedBoneLandmarks, 'intersectionDiagnostics')
    error('bonePreRegistration:MissingIntersectionDiagnosticsVariable', ...
          ['The bone-landmarks MAT file does not contain a variable named ' ...
           'intersectionDiagnostics: %s'], bonelandmarksFullPath);
end
intersectionDiagnostics = loadedBoneLandmarks.intersectionDiagnostics;

if ~isfield(loadedBoneLandmarks, 'landmarks')
    error('bonePreRegistration:MissingLandmarksVariable', ...
          ['The bone-landmarks MAT file does not contain a variable named ' ...
           'landmarks: %s'], bonelandmarksFullPath);
end
landmarks = loadedBoneLandmarks.landmarks;

% Remove the temporary wrapper structure after both variables have been
% copied to stable names used by the remaining workflow.
clear loadedBoneLandmarks;


%% SHOW THE DETECTED BONE SURFACE IN 3D SPACE

% The script uses this direct relationship:
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
    error('bonePreRegistration_onlyImage:GroupCountMismatch', ...
          'surfaceResults and ultrasoundSequence have different group counts.');
end

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
        surfaceCoordinatesXYZRef = surfaceResults(groupIndex).data(recordIndex).surfaceCoordinatesXYZRef;

        % Some valid records may contain no detected surface. Their image plane
        % remains visible, but there are no 3D bone points to draw.
        if isempty(surfaceCoordinatesXYZRef)
            continue;
        end

        % Display the 3d bone surface
        boneSurfaceHandle = scatter3(ax1, ...
            surfaceCoordinatesXYZRef(:, 1), ...
            surfaceCoordinatesXYZRef(:, 2), ...
            surfaceCoordinatesXYZRef(:, 3), ...
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
    % Render group names literally so underscores are not interpreted as TeX subscripts.
    legend(ax1, 'show', 'Location', 'best', 'Interpreter', 'none');
end

axis(ax1, 'tight');
axis(ax1, 'equal');
drawnow;

%% PRE-REGISTRATION STEP

%% FLATTEN AND GROUP THE REGIONAL BONE-SURFACE POINTS

% Keep the same region names as landmarks. This allows later code to access a
% surface and its landmark with the same field name.
regionNames = ["medial", "lateral", "shaft"];

% Make one output entry for each bone in landmarks. Empty regions start as
% 0-by-3 matrices, so bones without surface measurements remain valid entries.
regionalSurfacePoints = repmat(struct( ...
    'name', "", ...
    'bone', "", ...
    'coordinateFrame', "ref", ...
    'medial', zeros(0, 3), ...
    'lateral', zeros(0, 3), ...
    'shaft', zeros(0, 3)), size(landmarks));

for boneIndex = 1:numel(landmarks)
    regionalSurfacePoints(boneIndex).name = string(landmarks(boneIndex).name);
    regionalSurfacePoints(boneIndex).bone = upper(string(landmarks(boneIndex).bone));
end

% Each surfaceResults entry already represents one anatomical region. Combine
% all image records from that entry into the matching output region.
for groupIndex = 1:numel(surfaceResults)
    groupName = lower(string(surfaceResults(groupIndex).name));
    boneCode = upper(string(surfaceResults(groupIndex).bone));

    % Read the region from names such as tibia_medial. The existing name
    % femur_mid refers to the femur shaft, so both names use the shaft field.
    nameParts = split(groupName, "_");
    regionName = nameParts(end);
    if regionName == "mid"
        regionName = "shaft";
    end

    if ~any(regionName == regionNames)
        error('bonePreRegistration_onlyImage:UnknownSurfaceRegion', ...
              'Cannot identify the region for surface group "%s".', groupName);
    end

    % There must be exactly one landmark entry for the group's bone code.
    outputBoneIndex = find([regionalSurfacePoints.bone] == boneCode);
    if numel(outputBoneIndex) ~= 1
        error('bonePreRegistration_onlyImage:UnmatchedSurfaceBone', ...
              'Expected one landmarks entry for bone code "%s", but found %d.', ...
              boneCode, numel(outputBoneIndex));
    end

    % Append each nonempty image-level surface to the regional collection.
    for recordIndex = 1:numel(surfaceResults(groupIndex).data)
        points = surfaceResults(groupIndex).data(recordIndex).surfaceCoordinatesXYZRef;
        if isempty(points)
            continue;
        end

        % Registration expects one XYZ row per point. Stop early when an input
        % cannot safely be used as a 3D point collection.
        if ~isnumeric(points) || ~isreal(points) || ~ismatrix(points) || size(points, 2) ~= 3 || any(~isfinite(points(:)))
            error('bonePreRegistration_onlyImage:InvalidSurfacePoints', ...
                  'The surface points in group %d, record %d must be a finite numeric N-by-3 matrix.', ...
                  groupIndex, recordIndex);
        end

        regionField = char(regionName);
        regionalSurfacePoints(outputBoneIndex).(regionField) = [ regionalSurfacePoints(outputBoneIndex).(regionField); double(points)];
    end
end

%% BUILD REGIONAL CORRESPONDENCE CANDIDATES

% Store one correspondence set per bone. The two point matrices will always
% have the same number of rows, which is required by estgeotform3d.
boneCorrespondences = repmat(struct( ...
    'name', "", ...
    'bone', "", ...
    'landmarkPointsCT', zeros(0, 3), ...
    'surfacePointsRef', zeros(0, 3), ...
    'regionLabels', strings(0, 1)), size(landmarks));

for boneIndex = 1:numel(landmarks)
    boneCorrespondences(boneIndex).name = regionalSurfacePoints(boneIndex).name;
    boneCorrespondences(boneIndex).bone = regionalSurfacePoints(boneIndex).bone;

    % Process the regions in a fixed order so the final rows are easy to
    % inspect: medial first, followed by lateral and shaft.
    for regionIndex = 1:numel(regionNames)
        regionName = regionNames(regionIndex);
        regionField = char(regionName);
        surfacePoints = regionalSurfacePoints(boneIndex).(regionField);

        % A missing regional measurement is valid. It contributes no rows to
        % this bone's correspondence matrices.
        if isempty(surfacePoints)
            continue;
        end

        landmarkPoint = landmarks(boneIndex).(regionField);

        % One regional landmark must be one finite XYZ point. A clear error
        % here is easier to diagnose than a later estgeotform3d failure.
        if ~isnumeric(landmarkPoint) || ~isreal(landmarkPoint) || ~isequal(size(landmarkPoint), [1, 3]) || any(~isfinite(landmarkPoint))
            error('bonePreRegistration_onlyImage:InvalidLandmarkPoint', ...
                  'landmarks(%d).%s must be a finite numeric 1-by-3 point.', ...
                  boneIndex, regionField);
        end

        numberOfSurfacePoints = size(surfacePoints, 1);

        % Repeat the regional landmark once for every surface point. Row k in
        % landmarkPointsCT then corresponds to row k in surfacePointsRef.
        repeatedLandmarkPoints = repmat( double(landmarkPoint), numberOfSurfacePoints, 1);
        repeatedRegionLabels = repmat( regionName, numberOfSurfacePoints, 1);

        boneCorrespondences(boneIndex).landmarkPointsCT = [ boneCorrespondences(boneIndex).landmarkPointsCT; repeatedLandmarkPoints];
        boneCorrespondences(boneIndex).surfacePointsRef = [ boneCorrespondences(boneIndex).surfacePointsRef; surfacePoints];
        boneCorrespondences(boneIndex).regionLabels     = [ boneCorrespondences(boneIndex).regionLabels; repeatedRegionLabels];

        
    end
end


%%
