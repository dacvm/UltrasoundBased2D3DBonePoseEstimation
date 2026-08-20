clear; clc; close all;

% Load the data from the setup of the optimization
load('optimization_setup.mat');


%% DISPLAYING THE SETUP

% Locate the project functions from this script so the display remains usable
% when MATLAB's current folder is the development folder.
developmentFolder = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(developmentFolder));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Stop early when the saved fixture does not contain the aligned 3D surface
% measurements required by this development workflow.
if ~isfield(data, 'hasBoneSurface') || ~data.hasBoneSurface || ~isfield(data, 'boneSurfaceMeasurements') || isempty(data.boneSurfaceMeasurements)
    error('dev_bonePoseCost3DPointCloudV1:MissingBoneSurface', ...
          'The loaded optimization setup does not contain aligned bone-surface measurements.');
end

% Move the original CT mesh to its coarse initial pose in the reference
% frame. This is the same pose represented by a zero optimizer state.
bonePointsRefInitial = applyRigidTransform(data.boneMeshCT.Points, data.T_CT_ref_initial);
boneMeshRefInitial = triangulation( data.boneMeshCT.ConnectivityList, bonePointsRefInitial);

% Collect the per-image 3D surface measurements into one point cloud for
% this overview while keeping the aligned records unchanged inside data.
numberOfMeasurements = numel(data.boneSurfaceMeasurements);
surfacePointCells    = cell(numberOfMeasurements, 1);
for measurementIndex = 1:numberOfMeasurements
    surfacePointCells{measurementIndex} = data.boneSurfaceMeasurements(measurementIndex).surfaceCoordinatesXYZRef;
end
boneSurfacePointsRef = vertcat(surfacePointCells{:});

% An available artifact may still contain only empty surface records, which
% would make the requested setup display misleading.
if isempty(boneSurfacePointsRef)
    error('dev_bonePoseCost3DPointCloudV1:EmptyBoneSurface', ...
          'The loaded optimization setup contains no 3D bone-surface points.');
end

% Use the bone size to keep anatomical and image coordinate axes readable
% without relying on a data-set-specific arrow length.
boneExtentRef = max(bonePointsRefInitial, [], 1) - min(bonePointsRefInitial, [], 1);
axisDisplayScale = 0.08 * max(boneExtentRef);
if ~isfinite(axisDisplayScale) || axisDisplayScale <= 0
    axisDisplayScale = 20;
end

% Create one interactive reference-frame scene for inspecting the complete
% fixed setup before any point-to-mesh distance is calculated.
setupFigure = figure('Name', '3D Point-Cloud Cost Development: Initial Setup');
setupAxes = axes(setupFigure);
hold(setupAxes, 'on');
grid(setupAxes, 'on');
axis(setupAxes, 'equal');
axis(setupAxes, 'vis3d');
view(setupAxes, 35, 40);
xlabel(setupAxes, 'X_{ref} (mm)');
ylabel(setupAxes, 'Y_{ref} (mm)');
zlabel(setupAxes, 'Z_{ref} (mm)');

% Draw the initial candidate bone mesh using its coordinates in ref.
boneMeshHandle = patch(setupAxes, ...
    'Faces', boneMeshRefInitial.ConnectivityList, ...
    'Vertices', boneMeshRefInitial.Points, ...
    'FaceColor', [0.92, 0.83, 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.45, ...
    'DisplayName', 'Initial bone mesh');

% Draw the anatomical bone coordinate system at its coarse pose in ref.
display_axis_v2(setupAxes, ...
    data.T_bone_ref_initial(1:3, 4), ...
    data.T_bone_ref_initial(1:3, 1:3), ...
    axisDisplayScale, ...
    sprintf('%s anatomical coordinate system', data.boneName), ...
    'Tag', 'dev_point_cloud_bone_acs', ...
    'Mode', 'default');

% Draw every tracked ultrasound image at its saved pose in ref. The first
% image supplies the single legend entry so a large data set stays readable.
ultrasoundImageHandle = gobjects(1);
% Loop for all image plane in the data
for planeIndex = 1:numel(data.imagePlanesRef)

    % Get the current plane
    plane = data.imagePlanesRef(planeIndex);

    % Convert the stored physical image extent into local pixel spacing for
    % the textured image-plane helper.
    pixelSpacing = [ ...
        plane.W / max(plane.nCols - 1, 1), ...
        plane.H / max(plane.nRows - 1, 1)];

    currentImageHandle = display_image3D(setupAxes, ...
        plane.image, ...
        plane.T_image_ref, ...
        'SwapXY', true, ...
        'PixelSpacing', pixelSpacing, ...
        'Tag', 'dev_point_cloud_ultrasound_image', ...
        'Colormap', 'gray', ...
        'FaceAlpha', 0.30);

    if planeIndex == 1
        currentImageHandle.DisplayName = 'Ultrasound images';
        ultrasoundImageHandle = currentImageHandle;
    else
        currentImageHandle.HandleVisibility = 'off';
    end

    % Draw an unlabeled thin coordinate triad so each ultrasound plane's
    % orientation is visible without filling the scene with text labels.
    display_axis_v2(setupAxes, ...
        plane.T_image_ref(1:3, 4), ...
        plane.T_image_ref(1:3, 1:3), ...
        axisDisplayScale * 0.6, ...
        '', ...
        'Tag', 'dev_point_cloud_ultrasound_axis', ...
        'Mode', 'thin');
end

% Overlay the measured ultrasound bone surface as one ref-frame point cloud.
boneSurfaceHandle = scatter3(setupAxes, ...
    boneSurfacePointsRef(:, 1), ...
    boneSurfacePointsRef(:, 2), ...
    boneSurfacePointsRef(:, 3), ...
    14, ...
    [0.00, 0.65, 0.95], ...
    'filled', ...
    'DisplayName', 'Measured 3D bone surface');

% Finish the scene with a focused legend and surface lighting. The figure
% remains rotatable so correspondences can be inspected from any direction.
legend(setupAxes, ...
    [boneMeshHandle, ultrasoundImageHandle, boneSurfaceHandle], ...
    'Location', 'best', ...
    'Interpreter', 'none');
camlight(setupAxes, 'headlight');
lighting(setupAxes, 'gouraud');
material(setupAxes, 'dull');
title(setupAxes, sprintf( ...
    '%s initial setup in ref (%d surface points)', ...
    data.boneName, size(boneSurfacePointsRef, 1)), ...
    'Interpreter', 'none');
rotate3d(setupFigure, 'on');
drawnow;

%% 

