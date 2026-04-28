function displayBonePoseOptimizationScene(data, poseVector, config, figureName)
%DISPLAYBONEPOSEOPTIMIZATIONSCENE Display the current mesh pose and image-plane poses.
% This function declaration gives the optimization script one display-only helper.
%
% What this function does:
%   This function draws the current 3D bone mesh pose and the sampled 2D
%   ultrasound image planes in one 3D figure. It is meant for checking the
%   setup before optimization and the result after optimization.
%
% Important details:
%   - This function only displays geometry.
%   - This function does not compute the cost.
%   - This function does not run or change the optimizer.

%% HANDLE OPTIONAL INPUTS

% Use the configuration stored inside data when the caller does not pass config.
if nargin < 3 || isempty(config)
    config = data.config;
end

% Check that the configuration is a scalar struct so future display options can rely on the same input shape.
validateattributes(config, {'struct'}, {'scalar'}, mfilename, 'config');

% Use a clear default figure name when the caller does not pass one.
if nargin < 4 || isempty(figureName)
    figureName = 'Bone Pose Optimization Scene';
end

% Convert MATLAB string input to a character vector because older graphics functions handle char names most consistently.
figureName = char(figureName);

%% CONVERT THE CURRENT POSE TO DISPLAY GEOMETRY

% Convert the current state vector into the 4-by-4 mesh transform used by the geometry pipeline.
T_mesh_ref            = stateVectorToTMatrix(poseVector, data.T_init_originct);
% Move the local mesh vertices into the same reference frame as the ultrasound image planes.
meshVerticesReference = applyRigidTransform(data.meshVerticesLocal, T_mesh_ref);

% Store mesh vertices and faces in local variables so the patch call stays easy to read.
meshFaces = data.meshFaces;
% Read the image planes once because every plane will be drawn in the same axes.
planes    = data.planes;

%% CREATE THE 3D FIGURE

% Create one named figure so the initial and final scenes are easy to identify.
fig = figure('Name', figureName);
ax = axes(fig);
hold(ax, 'on');
grid(ax, 'on');
axis(ax, 'equal');
xlabel(ax, 'X');
ylabel(ax, 'Y');
zlabel(ax, 'Z');
view(ax, 35, 40);

%% DRAW THE CURRENT BONE MESH POSE

% Draw the transformed femur mesh as one patch so the current bone pose is visible.
patch(ax, ...
    'Faces', meshFaces, ...
    'Vertices', meshVerticesReference, ...
    'FaceColor', [0.92 0.83 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.55, ...
    'Tag', 'plot_bone_pose_optimization_mesh');

% Compute a display scale from the mesh size so coordinate axes stay readable across data sets.
meshExtent = max(meshVerticesReference, [], 1) - min(meshVerticesReference, [], 1);

% Use a conservative fraction of mesh size for triad arrows.
quiverScale = max(meshExtent) * 0.08;

% Fall back to a fixed scale if the mesh extent is empty or numerically degenerate.
if isempty(quiverScale) || ~isfinite(quiverScale) || quiverScale <= 0
    quiverScale = 20;
end

% Draw the mesh coordinate frame so the current bone transform can be inspected.
display_axis_v2(ax, ...
                T_mesh_ref(1:3, 4), ...
                T_mesh_ref(1:3, 1:3), ...
                quiverScale, ...
                'Bone', ...
                'Tag', 'plot_bone_pose_optimization_axis', ...
                'Mode', 'default');

%% DRAW THE CURRENT ULTRASOUND IMAGE-PLANE POSES

% Loop over every sampled image plane so the full optimization setup is visible.
for idx_plane = 1:numel(planes)

    % Read the current plane once so all drawing for this plane uses one pose.
    plane = planes(idx_plane);

    % Rebuild the image-to-reference transform from the stored plane basis and origin.
    T_image_ref = [plane.ex, plane.ey, plane.n, plane.p0; 0, 0, 0, 1];

    % Recover pixel spacing from the stored physical plane size so the drawn image has the same extent as the plane.
    pixelSpacing = [plane.W / max(plane.nCols - 1, 1), plane.H / max(plane.nRows - 1, 1)];

    % Draw the ultrasound frame as a textured 3D surface at its current pose.
    display_image3D(ax, ...
                    plane.image, ...
                    T_image_ref, ...
                    'SwapXY', true, ...
                    'PixelSpacing', pixelSpacing, ...
                    'Tag', 'plot_bone_pose_optimization_image', ...
                    'Colormap', 'gray', ...
                    'FaceAlpha', 0.35);

    % Draw a thin coordinate frame for this image plane so the plane pose is visible even through transparency.
    display_axis_v2(ax, ...
                    plane.p0, ...
                    [plane.ex, plane.ey, plane.n], ...
                    quiverScale * 0.6, ...
                    sprintf('Image %d', idx_plane), ...
                    'Tag', 'plot_bone_pose_optimization_image_axis', ...
                    'Mode', 'thin');
end

%% FINISH THE DISPLAY STYLE

% Add headlight-style lighting so the 3D mesh surface is easier to read.
camlight(ax, 'headlight');
lighting(ax, 'gouraud');
material(ax, 'dull');
title(ax, figureName, 'Interpreter', 'none');

% Force MATLAB to draw the figure before the script continues.
drawnow;
end
