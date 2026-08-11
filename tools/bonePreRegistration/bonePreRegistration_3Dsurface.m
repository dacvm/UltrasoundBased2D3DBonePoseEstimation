clear; clc; close all;

%% PATH DEFINITION

filepath_ultrasoundimage = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\bmodeimage_3dspace\tools\ultrasoundSpatialProcessing\outputs';
filename_ultrasoundimage = 'validSnapshots_20260811_204712.mat';

filepath_bonesurface = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\bmodeimage_3dspace\tools\boneSegmentationProcess\outputs';
filename_bonesurface = 'boneSurface_20260811_211029.mat';

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


%% LOAD THE ULTRASOUND IMAGE DATA AND BONE POSES GROUND TRUTH

% Load the reviewed ultrasound data and the ground-truth bone poses that were
% produced together by the Snapshot spatial-processing workflow.
ultrasoundFilePath = fullfile(filepath_ultrasoundimage, filename_ultrasoundimage);
ultrasoundFileData = load(ultrasoundFilePath);
if ~isfield(ultrasoundFileData, 'validSnapshots') || ...
        ~isfield(ultrasoundFileData, 'validBonePoses')
    error('bonePreRegistration:MissingSnapshotBonePoses', ...
          ['The selected MAT file must contain validSnapshots and ' ...
           'validBonePoses. Rerun the Snapshot spatial-processing workflow.']);
end

ultrasoundSequence = ultrasoundFileData.validSnapshots;
validBonePoses     = ultrasoundFileData.validBonePoses;
clear ultrasoundFileData;

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

% Use the CT source recorded by spatial processing so the coarse and
% ground-truth meshes come from the same CT dataset.
ctmatFullPath = char(validBonePoses.ctPostProcessedMatFile);
if ~isfile(ctmatFullPath)
    error('bonePreRegistration:MissingCtMatFile', ...
          'The configured CT MAT file does not exist: %s', ctmatFullPath);
end

% Load the CT bones used for coarse registration. The saved ground-truth
% meshes are already in ref and do not require the pin data here.
loadedCtData = load(ctmatFullPath, 'bones');
if ~isfield(loadedCtData, 'bones')
    error('bonePreRegistration:MissingBonesVariable', ...
          'The CT MAT file does not contain a variable named bones: %s', ctmatFullPath);
end
bones = loadedCtData.bones;

%% LOAD BONE LANDMARKS

% Build and check the exact MAT-file path before attempting to load it.
bonelandmarksFullPath = fullfile(filepath_bonelandmarks, filename_bonelandmarks);
if ~isfile(bonelandmarksFullPath)
    error('bonePreRegistration:MissingBoneLandmarksFile', ...
          'The configured bone-landmarks MAT file does not exist: %s', bonelandmarksFullPath);
end

% Load only the two expected variables so unrelated saved values cannot
% accidentally replace settings or intermediate variables in this script.
loadedBoneLandmarks = load(bonelandmarksFullPath, 'intersectionDiagnostics', 'landmarks');
if ~isfield(loadedBoneLandmarks, 'intersectionDiagnostics')
    error('bonePreRegistration:MissingIntersectionDiagnosticsVariable', ...
          'The bone-landmarks MAT file does not contain a variable named intersectionDiagnostics: %s', bonelandmarksFullPath);
end
intersectionDiagnostics = loadedBoneLandmarks.intersectionDiagnostics;
if ~isfield(loadedBoneLandmarks, 'landmarks')
    error('bonePreRegistration:MissingLandmarksVariable', ...
          'The bone-landmarks MAT file does not contain a variable named landmarks: %s', bonelandmarksFullPath);
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

% Snapshot mode combines all valid observations because they describe one
% static bone pose. Kinematic preparation will be added in a future workflow.
processingMode = lower(string(validBonePoses.processingMode));
switch processingMode
    case "snapshot"
        % Continue with the existing Snapshot surface grouping below.
    case "kinematic"
        % TODO: Select synchronized surface data for Kinematic pre-registration.
        error('bonePreRegistration_onlyImage:KinematicNotImplemented', ...
              'Kinematic pre-registration has not been implemented yet.');
    otherwise
        error('bonePreRegistration_onlyImage:UnknownProcessingMode', ...
              'Unknown processing mode: %s', processingMode);
end

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

    % Get the current data
    groupName = lower(string(surfaceResults(groupIndex).name));
    boneCode = upper(string(surfaceResults(groupIndex).bone));

    % Read the region from names such as tibia_medial. The existing name
    % femur_mid refers to the femur shaft, so both names use the shaft field.
    nameParts = split(groupName, "_");
    regionName = nameParts(end);
    if regionName == "mid"
        regionName = "shaft";
    end

    % Check if there is unknown region
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

% Use one color per bone for its CT mesh and landmarks. Correspondence lines
% use region colors so medial, lateral, and shaft candidates can be separated.
boneDisplayColors  = lines(max(numel(landmarks), 1));
regionLineColors   = lines(numel(regionNames));
availableBoneCodes = upper(string({bones.bone}));

% Loop for all landmarks
for boneIndex = 1:numel(landmarks)

    % Get current data
    boneCorrespondences(boneIndex).name = regionalSurfacePoints(boneIndex).name;
    boneCorrespondences(boneIndex).bone = regionalSurfacePoints(boneIndex).bone;

    % Find the CT mesh by bone code instead of assuming bones and landmarks
    % were saved in the same order.
    currentBoneCode = boneCorrespondences(boneIndex).bone;
    meshBoneIndex   = find(availableBoneCodes == currentBoneCode);
    if numel(meshBoneIndex) ~= 1
        error('bonePreRegistration_onlyImage:UnmatchedBoneMesh', ...
              'Expected one CT mesh for bone code "%s", but found %d.', ...
              currentBoneCode, numel(meshBoneIndex));
    end
    currentBoneMesh = bones(meshBoneIndex).mesh;
    if ~isa(currentBoneMesh, 'triangulation')
        error('bonePreRegistration_onlyImage:InvalidBoneMesh', ...
              'The CT mesh for bone code "%s" must be a triangulation.', ...
              currentBoneCode);
    end

    % Keep the mesh in its original CT coordinates. It will appear away from
    % the ultrasound data, which remains in the ref coordinate system.
    patch(ax1, ...
        'Faces', currentBoneMesh.ConnectivityList, ...
        'Vertices', currentBoneMesh.Points, ...
        'FaceColor', boneDisplayColors(boneIndex, :), ...
        'FaceAlpha', 0.25, ...
        'EdgeColor', 'none', ...
        'DisplayName', sprintf('%s mesh (CT)', boneCorrespondences(boneIndex).name));

    % Process the regions in a fixed order so the final rows are easy to
    % inspect: medial first, followed by lateral and shaft.
    for regionIndex = 1:numel(regionNames)

        % Get current data
        regionName    = regionNames(regionIndex);
        regionField   = char(regionName);
        surfacePoints = regionalSurfacePoints(boneIndex).(regionField);
        landmarkPoint = landmarks(boneIndex).(regionField);

        % One regional landmark must be one finite XYZ point. A clear error
        % here is easier to diagnose than a later estgeotform3d failure.
        if ~isnumeric(landmarkPoint) || ~isreal(landmarkPoint) || ~isequal(size(landmarkPoint), [1, 3]) || any(~isfinite(landmarkPoint))
            error('bonePreRegistration_onlyImage:InvalidLandmarkPoint', ...
                  'landmarks(%d).%s must be a finite numeric 1-by-3 point.', boneIndex, regionField);
        end
        landmarkPoint = double(landmarkPoint);

        % Plot all three CT landmarks, including landmarks whose regional
        % ultrasound measurement is currently empty.
        landmarkHandle = scatter3(ax1, ...
                            landmarkPoint(1), landmarkPoint(2), landmarkPoint(3), ...
                            90, boneDisplayColors(boneIndex, :), 'filled', ...
                            'MarkerEdgeColor', 'k', ...
                            'LineWidth', 1.0);
        if regionIndex == 1
            landmarkHandle.DisplayName = sprintf('%s landmarks (CT)', boneCorrespondences(boneIndex).name);
        else
            landmarkHandle.HandleVisibility = 'off';
        end

        % A missing regional measurement is valid. It contributes no rows or
        % correspondence lines for this bone and region.
        if isempty(surfacePoints)
            continue;
        end

        % Repeat the regional landmark once for every surface point. Row k in
        % landmarkPointsCT then corresponds to row k in surfacePointsRef.
        numberOfSurfacePoints  = size(surfacePoints, 1);
        repeatedLandmarkPoints = repmat(landmarkPoint, numberOfSurfacePoints, 1);
        repeatedRegionLabels   = repmat(regionName, numberOfSurfacePoints, 1);

        % Store the bone correspondences for documentation
        boneCorrespondences(boneIndex).landmarkPointsCT = [ boneCorrespondences(boneIndex).landmarkPointsCT; repeatedLandmarkPoints];
        boneCorrespondences(boneIndex).surfacePointsRef = [ boneCorrespondences(boneIndex).surfacePointsRef; surfacePoints];
        boneCorrespondences(boneIndex).regionLabels     = [ boneCorrespondences(boneIndex).regionLabels; repeatedRegionLabels];

        % Randomly sample at most 20 pairs per region only for visualization,
        % so drawing the correspondence lines remains fast.
        numberOfPointsToPlot = min(20, numberOfSurfacePoints);
        pointIndicesToPlot   = randperm(numberOfSurfacePoints, numberOfPointsToPlot);
        % Each line starts at the CT landmark and ends at one sampled regional
        % surface point in ref.
        for pointIndex = pointIndicesToPlot
            plot3(ax1, ...
                [landmarkPoint(1), surfacePoints(pointIndex, 1)], ...
                [landmarkPoint(2), surfacePoints(pointIndex, 2)], ...
                [landmarkPoint(3), surfacePoints(pointIndex, 3)], ...
                '-', ...
                'Color', regionLineColors(regionIndex, :), ...
                'LineWidth', 0.25, ...
                'HandleVisibility', 'off', ...
                'Tag', 'regional_correspondence_candidate');
        end
    end
end

% Refit the axes after adding the distant CT geometry and correspondence lines.
% The labels make clear that two coordinate frames share this one view.
xlabel(ax1, 'X coordinate (mm), CT and ref frames');
ylabel(ax1, 'Y coordinate (mm), CT and ref frames');
zlabel(ax1, 'Z coordinate (mm), CT and ref frames');
title(ax1, 'CT bones and landmarks linked to regional surfaces in ref');
legend(ax1, 'show', 'Location', 'best', 'Interpreter', 'none');
axis(ax1, 'tight');
axis(ax1, 'equal');
drawnow;

%% PERFORM COARSE REGISTRATION AND DISPLAY THE TRANSFORMED MESHES

% Keep both transformation directions as raw 4x4 matrices so their source
% and target frames remain explicit throughout later processing.
coarseRegistrations = repmat(struct( ...
    'name', "", ...
    'bone', "", ...
    'status', "not processed", ...
    'T_ref_CT', [], ...
    'T_CT_ref', [], ...
    'boneMeshRef', []), size(boneCorrespondences));

% Use a separate figure so the registration result is not hidden by the
% original CT meshes, ultrasound images, and correspondence lines in ax1.
fig2 = figure('Name', 'Coarse Bone Registration');
ax2 = axes(fig2);
xlabel(ax2, 'X_{ref} (mm)');
ylabel(ax2, 'Y_{ref} (mm)');
zlabel(ax2, 'Z_{ref} (mm)');
title(ax2, 'Coarse registration versus ground-truth bone poses in ref');
grid(ax2, 'on');
axis(ax2, 'equal');
hold(ax2, 'on');
view(ax2, 35, 40);

% Draw the measured surface points first. These points are already in ref,
% which is also the target frame of each transformed CT mesh below.
for boneIndex = 1:numel(regionalSurfacePoints)

    % Collect each region in a cell first so the numeric point matrix can be
    % joined once after the loop instead of repeatedly growing in memory.
    boneRegionPointSets = cell(1, numel(regionNames));
    for regionIndex = 1:numel(regionNames)
        regionField = char(regionNames(regionIndex));
        boneRegionPointSets{regionIndex} = regionalSurfacePoints(boneIndex).(regionField);
    end
    allBoneSurfacePoints = vertcat(boneRegionPointSets{:});

    % Bones without measured points, such as the current femur data, do not
    % add a surface object to this result figure.
    if isempty(allBoneSurfacePoints)
        continue;
    end

    % Plot the bone surface
    scatter3(ax2, ...
        allBoneSurfacePoints(:, 1), ...
        allBoneSurfacePoints(:, 2), ...
        allBoneSurfacePoints(:, 3), ...
        10, boneDisplayColors(boneIndex, :), 'filled', ...
        'DisplayName', sprintf('%s surface (ref)', regionalSurfacePoints(boneIndex).name), ...
        'Tag', 'coarse_registration_surface');
end

%% DISPLAY THE GROUND-TRUTH BONE POSES

% Use the poses and meshes saved by Snapshot spatial processing. These are the
% same ground-truth meshes that were used to calculate the intersections.
groundTruthRegistrations = repmat(struct( ...
    'name', "", ...
    'bone', "", ...
    'T_CT_ref', [], ...
    'boneMeshRef', []), size(boneCorrespondences));
validBoneCodes = upper(string({validBonePoses.bonePoses.bone}));

for boneIndex = 1:numel(boneCorrespondences)
    currentBoneCode = upper(string(boneCorrespondences(boneIndex).bone));

    % Match the saved ground truth to the coarse-registration bone by code.
    validBoneIndex           = find(validBoneCodes == currentBoneCode, 1);
    currentValidBonePoseData = validBonePoses.bonePoses(validBoneIndex).data;
    T_CT_ref_groundTruth     = currentValidBonePoseData.T_CT_ref;
    boneMeshRefGroundTruth   = currentValidBonePoseData.mesh;

    groundTruthRegistrations(boneIndex).name        = boneCorrespondences(boneIndex).name;
    groundTruthRegistrations(boneIndex).bone        = currentBoneCode;
    groundTruthRegistrations(boneIndex).T_CT_ref    = T_CT_ref_groundTruth;
    groundTruthRegistrations(boneIndex).boneMeshRef = boneMeshRefGroundTruth;

    % Gray distinguishes ground truth from the colored coarse registration.
    % Transparency keeps both overlaid surfaces and measured points visible.
    patch(ax2, ...
        'Faces', boneMeshRefGroundTruth.ConnectivityList, ...
        'Vertices', boneMeshRefGroundTruth.Points, ...
        'FaceColor', [0.55, 0.55, 0.55], ...
        'FaceAlpha', 0.25, ...
        'EdgeColor', 'none', ...
        'DisplayName', sprintf('%s mesh (ground truth)', boneCorrespondences(boneIndex).name), ...
        'Tag', 'ground_truth_bone_mesh');
end

% Estimate and apply one independent rigid transformation for each bone.
for boneIndex = 1:numel(boneCorrespondences)
    coarseRegistrations(boneIndex).name = boneCorrespondences(boneIndex).name;
    coarseRegistrations(boneIndex).bone = boneCorrespondences(boneIndex).bone;

    % matchedPoints1 and matchedPoints2 intentionally follow the requested
    % stable order: measured surface in ref first, CT landmarks second.
    matchedPoints1 = boneCorrespondences(boneIndex).surfacePointsRef;
    matchedPoints2 = boneCorrespondences(boneIndex).landmarkPointsCT;

    % A 3D rigid estimate needs at least three unique, non-collinear points
    % in both sets. Skip incomplete bones instead of stopping other bones.
    uniqueMatchedPoints1  = unique(matchedPoints1, 'rows', 'stable');
    uniqueMatchedPoints2  = unique(matchedPoints2, 'rows', 'stable');
    hasEnoughUniquePoints = size(uniqueMatchedPoints1, 1) >= 3 &&  size(uniqueMatchedPoints2, 1) >= 3;
    hasNoncollinearPoints = hasEnoughUniquePoints && ...
                            rank(uniqueMatchedPoints1 - mean(uniqueMatchedPoints1, 1)) >= 2 && ...
                            rank(uniqueMatchedPoints2 - mean(uniqueMatchedPoints2, 1)) >= 2;
    if ~hasNoncollinearPoints
        coarseRegistrations(boneIndex).status = "skipped: fewer than three non-collinear correspondence points";
        warning('bonePreRegistration_onlyImage:InsufficientRegistrationPoints', ...
                'Skipping coarse registration for bone "%s" because it does not have three non-collinear correspondence points.', ...
                boneCorrespondences(boneIndex).bone);
        continue;
    end

    % Let MATLAB estimate the ref-to-CT transform, then immediately extract
    % its premultiply matrix so the rest of the workflow uses raw 4x4 transforms.
    tform_ref_CT = estgeotform3d(matchedPoints1, matchedPoints2, 'rigid', 'MaxDistance', 100);
    T_ref_CT     = tform_ref_CT.A;

    % The CT mesh must be moved into ref, so derive the opposite direction
    % explicitly from the estimated ref-to-CT matrix.
    T_CT_ref = inv(T_ref_CT);

    % Find this bone's CT triangulation by its code, then transform every
    % vertex while keeping the triangle connectivity unchanged.
    currentBoneCode = boneCorrespondences(boneIndex).bone;
    meshBoneIndex = find(availableBoneCodes == currentBoneCode);
    if numel(meshBoneIndex) ~= 1
        error('bonePreRegistration_onlyImage:UnmatchedBoneMesh', ...
              'Expected one CT mesh for bone code "%s", but found %d.', ...
              currentBoneCode, numel(meshBoneIndex));
    end
    currentBoneMesh = bones(meshBoneIndex).mesh;

    % Transform only the CT-frame vertices and reuse the original triangle
    % connectivity to build a mesh whose points are expressed in ref.
    bonePointsRef = applyRigidTransform(currentBoneMesh.Points, T_CT_ref);
    boneMeshRef   = triangulation(currentBoneMesh.ConnectivityList, bonePointsRef);

    % Store frame-named matrices and the ref-frame mesh for later use.
    coarseRegistrations(boneIndex).status      = "registered";
    coarseRegistrations(boneIndex).T_CT_ref    = T_CT_ref;
    coarseRegistrations(boneIndex).boneMeshRef = boneMeshRef;

    % Display the transformed CT mesh in the same ref frame as the measured
    % points. Transparency keeps surface points visible through the mesh.
    patch(ax2, ...
        'Faces', boneMeshRef.ConnectivityList, ...
        'Vertices', boneMeshRef.Points, ...
        'FaceColor', boneDisplayColors(boneIndex, :), ...
        'FaceAlpha', 0.30, ...
        'EdgeColor', 'none', ...
        'DisplayName', sprintf('%s mesh (registered)', boneCorrespondences(boneIndex).name), ...
        'Tag', 'coarsely_registered_bone_mesh');
end

% Fit the final view after all successful registrations have been drawn.
legend(ax2, 'show', 'Location', 'best', 'Interpreter', 'none');
axis(ax2, 'tight');
axis(ax2, 'equal');
drawnow;
