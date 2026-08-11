clear;
clc;
close all;

%% LOAD AND VALIDATE THE CONFIGURATION

% Find this script rather than relying on MATLAB's current folder. This lets
% a user run the tool from any working directory.
script_full_path = mfilename('fullpath');
if isempty(script_full_path)
    error('preprocess_markerstls:ScriptPathUnavailable', ...
          'Run build_ct_knee_reference_model.m as a complete script so its configuration file can be located.');
end
tool_directory = fileparts(script_full_path);

% Walk up from tools/ctkneePostProcess to the repository root. Keeping this
% relationship explicit lets the tool reuse the parent project's functions
% while keeping its own configuration and outputs beside the tool.
tools_directory = fileparts(tool_directory);
project_directory = fileparts(tools_directory);

% Add only the shared geometry and display folders used by this tool. In
% particular, estimateRBfrom3Points_v2 is owned by functions/geometry in the
% project root and is not duplicated inside this tool.
geometry_directory = fullfile(project_directory, 'functions', 'geometry');
display_directory = fullfile(project_directory, 'functions', 'display');
if ~isfolder(geometry_directory)
    error('preprocess_markerstls:GeometryDirectoryNotFound', ...
          'Required geometry directory not found: %s', geometry_directory);
end
if ~isfolder(display_directory)
    error('preprocess_markerstls:DisplayDirectoryNotFound', ...
          'Required display directory not found: %s', display_directory);
end

% Add the tool-local helper directory so each extracted helper is available
% when the script is launched from any current working directory.
helper_directory = fullfile(tool_directory, 'helpers');
if ~isfolder(helper_directory)
    error('preprocess_markerstls:HelperDirectoryNotFound', ...
          'Required helper directory not found: %s', helper_directory);
end

addpath(geometry_directory);
addpath(display_directory);
addpath(helper_directory);

% Read this workflow's configuration from its tool-local configs folder so
% unrelated project tools do not share one configuration directory.
configuration_path = fullfile(tool_directory, 'configs', 'preprocess_markerstls_config.json');
configuration      = readJsonConfiguration(configuration_path);

% Convert the user settings into checked, absolute input and output paths.
% The returned specifications also keep the femur/tibia metadata in one place.
[bonepin_specs, bone_specs, acs_mat_path, output_paths] = ...
    prepareConfiguration(configuration, fileparts(configuration_path));

% Read and validate the ACS before starting the slower mesh processing. A
% malformed MAT file therefore fails early with a direct explanation.
acs = loadAndValidateAcs(acs_mat_path);

% Keep processing and display choices inside the script so the JSON only
% contains values that normally change between datasets.
pcfitsphere_max_distance_fraction = 0.05;
bonepin_axis_scale_fraction       = 0.50;
bone_axis_scale_fraction          = 0.15;
png_resolution_dpi                = 300;

%% LOAD MARKER MESHES AND FIT THEIR SPHERES

% Store each marker's source, mesh, fitted sphere, and centroid together so
% the later rigid-body and display sections use the same checked data.
markerstls = struct( ...
    'name', {}, ...
    'path', {}, ...
    'mesh', {}, ...
    'pointcloud', {}, ...
    'sphere', {}, ...
    'sphere_radius', {}, ...
    'sphere_mean_error', {}, ...
    'centroid', {}, ...
    'bonepin_index', {}, ...
    'marker_number', {});

% Load markers pin by pin and marker 1 through marker 4. This fixed order
% makes marker_indices stable and removes any dependence on dir() sorting.
idx_markerstl = 0;
for idx_bonepin = 1:numel(bonepin_specs)

    for current_marker_number = 1:4

        idx_markerstl = idx_markerstl + 1;

        % Read the exact file assigned to this semantic marker role.
        current_markerstl_path = bonepin_specs(idx_bonepin).marker_paths{current_marker_number};
        current_mesh = stlread(current_markerstl_path);
        validateStlMesh(current_mesh, current_markerstl_path);

        % Treat the STL vertices as point samples because pcfitsphere works
        % with a pointCloud rather than a triangulation object.
        current_points = current_mesh.Points;
        current_pointcloud = pointCloud(current_points);

        % Scale the sphere inlier tolerance to the current marker size so
        % the same internal fraction works for differently sized meshes.
        current_mesh_size = max(current_points, [], 1) - min(current_points, [], 1);
        current_max_distance = max(current_mesh_size) * pcfitsphere_max_distance_fraction;
        if ~isfinite(current_max_distance) || current_max_distance <= 0
            error('preprocess_markerstls:InvalidMarkerExtent', ...
                'Marker STL has no usable spatial extent: %s', current_markerstl_path);
        end

        % Fit the marker sphere and add the source path to any fitting error,
        % which helps users identify the configuration entry that failed.
        try
            [current_sphere, ~, ~, current_mean_error] = ...
                pcfitsphere(current_pointcloud, current_max_distance);
        catch sphere_error
            error('preprocess_markerstls:SphereFitFailed', ...
                'Could not fit a sphere to marker STL "%s". Reason: %s', ...
                current_markerstl_path, sphere_error.message);
        end

        % Reject an unusable fit before it can create an invalid rigid-body
        % transform that would be harder to diagnose later.
        if isempty(current_sphere) ...
                || ~isfinite(current_sphere.Radius) ...
                || current_sphere.Radius <= 0 ...
                || any(~isfinite(current_sphere.Center))
            error('preprocess_markerstls:InvalidSphereFit', ...
                'Sphere fitting returned an invalid model for marker STL: %s', ...
                current_markerstl_path);
        end

        % Save the loaded and calculated marker information for rigid-body
        % construction, diagnostics, and the final shared display.
        markerstls(idx_markerstl).name = bonepin_specs(idx_bonepin).marker_names{current_marker_number};
        markerstls(idx_markerstl).path = current_markerstl_path;
        markerstls(idx_markerstl).mesh = current_mesh;
        markerstls(idx_markerstl).pointcloud = current_pointcloud;
        markerstls(idx_markerstl).sphere = current_sphere;
        markerstls(idx_markerstl).sphere_radius = current_sphere.Radius;
        markerstls(idx_markerstl).sphere_mean_error = current_mean_error;
        markerstls(idx_markerstl).centroid = current_sphere.Center;
        markerstls(idx_markerstl).bonepin_index = idx_bonepin;
        markerstls(idx_markerstl).marker_number = current_marker_number;
    end
end

%% CALCULATE THE FEMUR AND TIBIA BONE-PIN TRANSFORMS

% Preserve the useful output fields from the original workflow. Full marker
% paths replace file_pattern because the new configuration names exact files.
bonepins = struct( ...
    'name', {}, ...
    'bone', {}, ...
    'place', {}, ...
    'marker_indices', {}, ...
    'marker_names', {}, ...
    'marker_paths', {}, ...
    'marker_centroids', {}, ...
    'origin', {}, ...
    'base_axes', {}, ...
    'T_pin_CT', {});

for idx_bonepin = 1:numel(bonepin_specs)

    % Each pin owns four consecutive records because the loading loop used
    % femur/tibia and marker 1-to-4 order explicitly.
    first_marker_index = (idx_bonepin - 1) * 4 + 1;
    current_marker_indices = first_marker_index:(first_marker_index + 3);

    % Arrange centroids as the required 3-by-4 matrix. Marker 1 is the
    % origin, marker 2 helps define x, marker 3 defines y, and marker 4 is
    % retained as an additional diagnostic marker.
    current_marker_centroids = vertcat( ...
        markerstls(current_marker_indices).centroid).';
    current_rigidbody_transform = ...
        estimateRBfrom3Points_v2(current_marker_centroids);

    % Keep identity, provenance, source centroids, and convenient transform
    % components together in each exported bone-pin record.
    bonepins(idx_bonepin).name = bonepin_specs(idx_bonepin).name;
    bonepins(idx_bonepin).bone = bonepin_specs(idx_bonepin).bone;
    bonepins(idx_bonepin).place = bonepin_specs(idx_bonepin).place;
    bonepins(idx_bonepin).marker_indices = current_marker_indices;
    bonepins(idx_bonepin).marker_names = bonepin_specs(idx_bonepin).marker_names;
    bonepins(idx_bonepin).marker_paths = bonepin_specs(idx_bonepin).marker_paths;
    bonepins(idx_bonepin).marker_centroids = current_marker_centroids;
    bonepins(idx_bonepin).origin = current_rigidbody_transform(1:3, 4);
    bonepins(idx_bonepin).base_axes = current_rigidbody_transform(1:3, 1:3);
    bonepins(idx_bonepin).T_pin_CT = current_rigidbody_transform;
end

%% LOAD BONE MESHES AND BUILD THEIR ACS TRANSFORMS

% Keep the existing bones interface so saved results remain easy to use in
% later registration and visualization code.
bones = struct( ...
    'name', {}, ...
    'bone', {}, ...
    'path', {}, ...
    'mesh', {}, ...
    'T_bone_CT', {});

% The source ACS stores local axes row-wise. Transpose each rotation so the
% exported transforms use the project's column-wise axis convention.
T_bone_CT   = struct();
T_bone_CT.F = [acs.f.R.', acs.f.origin(:); 0 0 0 1];
T_bone_CT.T = [acs.t.R.', acs.t.origin(:); 0 0 0 1];

for idx_bone = 1:numel(bone_specs)

    % Load only the configured bone mesh and keep its exact source path in
    % the public result for later provenance checks.
    current_bone_mesh = stlread(bone_specs(idx_bone).path);
    validateStlMesh(current_bone_mesh, bone_specs(idx_bone).path);

    current_bone_code = bone_specs(idx_bone).bone;
    if ~isfield(T_bone_CT, current_bone_code)
        error('preprocess_markerstls:MissingBoneTransform', ...
              'No ACS transform is available for bone code "%s".', current_bone_code);
    end

    bones(idx_bone).name = bone_specs(idx_bone).name;
    bones(idx_bone).bone = current_bone_code;
    bones(idx_bone).path = bone_specs(idx_bone).path;
    bones(idx_bone).mesh = current_bone_mesh;
    bones(idx_bone).T_bone_CT = T_bone_CT.(current_bone_code);
end

%% BUILD THE FINAL MARKER, BONE-PIN, AND BONE DISPLAY

% Prepare one visible figure so users can inspect every CT-space input and
% coordinate system together before using the exported results.
fig1 = figure( ...
    'Name', 'Preprocessed Bone and Bone-Pin Setup', ...
    'Color', 'white');
ax1 = axes('Parent', fig1);
axis(ax1, 'equal');
hold(ax1, 'on');
grid(ax1, 'on');
xlabel(ax1, 'X');
ylabel(ax1, 'Y');
zlabel(ax1, 'Z');
title(ax1, 'Marker, Bone-Pin, and Bone Coordinate Systems');

% Give every marker a separate color because nearby marker surfaces and
% fitted spheres can otherwise be difficult to distinguish.
marker_colors = lines(max(numel(markerstls), 1));

for idx_markerstl = 1:numel(markerstls)

    current_mesh = markerstls(idx_markerstl).mesh;
    current_triangulation = triangulation(current_mesh.ConnectivityList, current_mesh.Points);

    % Draw the scanned marker surface with transparency so its fitted sphere
    % and centroid remain visible in the same location.
    trisurf(current_triangulation, ...
        'Parent', ax1, ...
        'FaceColor', marker_colors(idx_markerstl, :), ...
        'FaceAlpha', 0.45, ...
        'EdgeColor', 'none', ...
        'Tag', sprintf('plot_marker_%d_mesh', idx_markerstl));

    % Place the filename slightly beside the mesh rather than directly over
    % its surface, and show filename characters without TeX formatting.
    current_vertices = current_triangulation.Points;
    mesh_center      = mean(current_vertices, 1);
    mesh_size        = max(current_vertices, [], 1) - min(current_vertices, [], 1);
    label_offset_x   = max(mesh_size(1) * 0.20, eps);
    text(ax1, ...
        mesh_center(1) + label_offset_x, ...
        mesh_center(2), ...
        mesh_center(3), ...
        markerstls(idx_markerstl).name, ...
        'Interpreter', 'none', ...
        'FontSize', 9, ...
        'Color', marker_colors(idx_markerstl, :), ...
        'FontWeight', 'bold', ...
        'Tag', sprintf('plot_marker_%d_label', idx_markerstl));

    % Scale and move a unit sphere to display the fit without hiding the
    % original marker mesh underneath it.
    [unit_sphere_x, unit_sphere_y, unit_sphere_z] = sphere(32);
    current_sphere      = markerstls(idx_markerstl).sphere;
    fitted_sphere_x     = unit_sphere_x * current_sphere.Radius + current_sphere.Center(1);
    fitted_sphere_y     = unit_sphere_y * current_sphere.Radius + current_sphere.Center(2);
    fitted_sphere_z     = unit_sphere_z * current_sphere.Radius + current_sphere.Center(3);
    fitted_sphere_color = marker_colors(idx_markerstl, :) * 0.35 + [1 1 1] * 0.65;
    surf(ax1, ...
        fitted_sphere_x, ...
        fitted_sphere_y, ...
        fitted_sphere_z, ...
        'FaceColor', fitted_sphere_color, ...
        'FaceAlpha', 0.18, ...
        'EdgeColor', 'none', ...
        'Tag', sprintf('plot_marker_%d_fitted_sphere', idx_markerstl));

    % Mark the fitted centroid with the same color as its source mesh so the
    % sphere center remains easy to associate with the correct marker.
    plot3(ax1, ...
        markerstls(idx_markerstl).centroid(1), ...
        markerstls(idx_markerstl).centroid(2), ...
        markerstls(idx_markerstl).centroid(3), ...
        'o', ...
        'MarkerSize', 8, ...
        'MarkerFaceColor', marker_colors(idx_markerstl, :), ...
        'MarkerEdgeColor', 'k', ...
        'Tag', sprintf('plot_marker_%d_centroid', idx_markerstl));
end

% Draw each bone-pin coordinate system at a scale based on its own marker
% spacing so the axes stay readable across differently sized datasets.
for idx_bonepin = 1:numel(bonepins)
    current_marker_centroids = bonepins(idx_bonepin).marker_centroids;
    current_axis_scale = max(vecnorm( ...
        current_marker_centroids - current_marker_centroids(:, 1), 2, 1)) ...
        * bonepin_axis_scale_fraction;

    % Use the fitted marker radii as a safe fallback if marker spacing does
    % not provide a positive finite display scale.
    if isempty(current_axis_scale) || ~isfinite(current_axis_scale) || current_axis_scale <= 0
        current_marker_indices = bonepins(idx_bonepin).marker_indices;
        current_axis_scale     = mean([markerstls(current_marker_indices).sphere_radius], 'omitnan');
    end
    if isempty(current_axis_scale) || ~isfinite(current_axis_scale) || current_axis_scale <= 0
        current_axis_scale = 1;
    end

    display_axis_v2(ax1, ...
        bonepins(idx_bonepin).origin, ...
        bonepins(idx_bonepin).base_axes, ...
        current_axis_scale, ...
        bonepins(idx_bonepin).name, ...
        'Tag', sprintf('plot_%s_rigidbody_axis', lower(bonepins(idx_bonepin).name)), ...
        'Mode', 'default');
end

% Use one color per bone so the femur and tibia remain distinguishable when
% their semi-transparent surfaces overlap.
bone_colors = lines(max(numel(bones), 1));

for idx_bone = 1:numel(bones)

    current_bone_mesh = bones(idx_bone).mesh;
    current_bone_triangulation = triangulation(current_bone_mesh.ConnectivityList, current_bone_mesh.Points);

    % Draw a transparent bone surface so its anatomical coordinate system
    % remains visible even when its origin lies inside the mesh.
    trisurf(current_bone_triangulation, ...
        'Parent', ax1, ...
        'FaceColor', bone_colors(idx_bone, :), ...
        'FaceAlpha', 0.35, ...
        'EdgeColor', 'none', ...
        'Tag', sprintf('plot_%s_bone_mesh', lower(bones(idx_bone).name)));

    % Scale the ACS arrows from the bone bounding box instead of assuming a
    % fixed CT coordinate unit or mesh size.
    current_bone_vertices = current_bone_triangulation.Points;
    current_bone_size     = max(current_bone_vertices, [], 1) - min(current_bone_vertices, [], 1);
    current_axis_scale    = max(current_bone_size) * bone_axis_scale_fraction;
    if isempty(current_axis_scale) || ~isfinite(current_axis_scale) || current_axis_scale <= 0
        current_axis_scale = 1;
    end

    current_bone_transform = bones(idx_bone).T_bone_CT;
    display_axis_v2(ax1, ...
        current_bone_transform(1:3, 4), ...
        current_bone_transform(1:3, 1:3), ...
        current_axis_scale, ...
        sprintf('%s ACS', bones(idx_bone).name), ...
        'Tag', sprintf('plot_%s_acs', lower(bones(idx_bone).name)), ...
        'Mode', 'default');
end

% Apply the final camera and lighting after every surface has been added so
% the on-screen display and exported image use the same finished view.
camlight(ax1, 'headlight');
lighting(ax1, 'gouraud');
view(ax1, 3);
drawnow;

%% EXPORT THE RESULTS AND DISPLAY

% Save only the two public result structs. Version 7.3 supports large mesh
% datasets that may exceed the size limit of MATLAB's older MAT format.
save(output_paths.mat_file, 'bones', 'bonepins', '-v7.3');

% Save an editable MATLAB figure and a high-resolution image of the exact
% display that remains open for the user after the script completes.
savefig(fig1, output_paths.fig_file);
exportgraphics(fig1, output_paths.png_file, 'Resolution', png_resolution_dpi);

% Report every generated path so a user can find the outputs immediately.
fprintf('Saved preprocessing results:\n');
fprintf('  MAT: %s\n', output_paths.mat_file);
fprintf('  FIG: %s\n', output_paths.fig_file);
fprintf('  PNG: %s\n', output_paths.png_file);
