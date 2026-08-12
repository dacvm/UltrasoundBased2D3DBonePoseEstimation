function displayBonePoseOptimizationScene( ...
        data, poseVector, config, figureName, validationData)
%DISPLAYBONEPOSEOPTIMIZATIONSCENE Display estimated and optional ground-truth poses.
% This function draws the current estimated bone pose and ultrasound image
% planes. When validationData is provided, it also overlays the saved
% ground-truth bone mesh and anatomical coordinate system.
%
% Inputs:
%   data           - Prepared estimation data containing the CT mesh, image
%                    planes, initial pose, and anatomical CT transform.
%   poseVector     - Six-value candidate perturbation around the initial pose.
%   config         - Optional optimization configuration. data.config is
%                    used when this input is empty.
%   figureName     - Optional figure title.
%   validationData - Optional validation struct containing
%                    groundTruthBonePose. When omitted, only the estimate is shown.
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

% Show ground truth only when the caller explicitly provides validation data.
showGroundTruth = nargin >= 5 && ~isempty(validationData);
if showGroundTruth
    groundTruthBonePose = validationData.groundTruthBonePose;
end

%% CONVERT THE CURRENT POSE TO DISPLAY GEOMETRY

% Convert the current state into the transform applied to CT mesh points.
T_CT_ref_candidate = stateVectorToTMatrix( ...
    poseVector, data.T_CT_ref_initial);
% Derive the anatomical bone-frame pose for the coordinate-axis display.
T_bone_ref_candidate = T_CT_ref_candidate * data.T_bone_CT;
% Move CT vertices into the same reference frame as the ultrasound planes.
bonePointsRefCandidate = applyRigidTransform( ...
    data.boneMeshCT.Points, T_CT_ref_candidate);

% Read fixed topology and observations once for the drawing loops below.
meshFaces = data.boneMeshCT.ConnectivityList;
planes = data.imagePlanesRef;

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

% Draw the transformed target bone as one patch so the estimated pose is visible.
estimatedMeshHandle = patch(ax, ...
    'Faces', meshFaces, ...
    'Vertices', bonePointsRefCandidate, ...
    'FaceColor', [0.92 0.83 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.55, ...
    'DisplayName', 'Estimated bone mesh', ...
    'Tag', 'plot_bone_pose_estimated_mesh');

% Overlay the saved reference-frame ground-truth surface when requested.
if showGroundTruth
    groundTruthMeshHandle = patch(ax, ...
        'Faces', groundTruthBonePose.boneMeshRef.ConnectivityList, ...
        'Vertices', groundTruthBonePose.boneMeshRef.Points, ...
        'FaceColor', [0.55 0.55 0.55], ...
        'EdgeColor', 'none', ...
        'FaceAlpha', 0.25, ...
        'DisplayName', 'Ground-truth bone mesh', ...
        'Tag', 'plot_bone_pose_ground_truth_mesh');
end

% Compute a display scale from the mesh size so coordinate axes stay readable across data sets.
meshExtent = max(bonePointsRefCandidate, [], 1) - min(bonePointsRefCandidate, [], 1);

% Use a conservative fraction of mesh size for triad arrows.
quiverScale = max(meshExtent) * 0.08;

% Fall back to a fixed scale if the mesh extent is empty or numerically degenerate.
if isempty(quiverScale) || ~isfinite(quiverScale) || quiverScale <= 0
    quiverScale = 20;
end

% Draw the anatomical bone frame, not the CT image frame, at the candidate pose.
display_axis_v2(ax, ...
                T_bone_ref_candidate(1:3, 4), ...
                T_bone_ref_candidate(1:3, 1:3), ...
                quiverScale, ...
                sprintf('%s estimated ACS', data.boneName), ...
                'Tag', 'plot_bone_pose_estimated_acs', ...
                'Mode', 'default');

% Draw dashed anatomical axes so the ground-truth orientation is easy to compare.
if showGroundTruth
    display_axis_v2(ax, ...
                    groundTruthBonePose.T_bone_ref(1:3, 4), ...
                    groundTruthBonePose.T_bone_ref(1:3, 1:3), ...
                    quiverScale, ...
                    sprintf('%s ground-truth ACS', data.boneName), ...
                    'Tag', 'plot_bone_pose_ground_truth_acs', ...
                    'Mode', 'shadow');
end

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

% Keep the legend focused on the two surfaces instead of listing every image plane.
if showGroundTruth
    legend(ax, [estimatedMeshHandle, groundTruthMeshHandle], ...
        'Location', 'best', 'Interpreter', 'none');
end

% Add headlight-style lighting so the 3D mesh surface is easier to read.
camlight(ax, 'headlight');
lighting(ax, 'gouraud');
material(ax, 'dull');
title(ax, figureName, 'Interpreter', 'none');

% Force MATLAB to draw the figure before the script continues.
drawnow;
end
