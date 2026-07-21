clear;
clc;
close all;

%% LOAD AND VALIDATE THE CONFIGURATION

% Find this script rather than relying on MATLAB's current folder. This lets
% a user run the tool from any working directory.
script_full_path = mfilename('fullpath');
if isempty(script_full_path)
    error('preprocess_markerstls:ScriptPathUnavailable', ...
          'Run preprocess_markerstls_from_config.m as a complete script so its configuration file can be located.');
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
addpath(geometry_directory);
addpath(display_directory);

% Read this workflow's configuration from its tool-local configs folder so
% unrelated project tools do not share one configuration directory.
configuration_path = fullfile( ...
    tool_directory, 'configs', 'preprocess_markerstls_config.json');
configuration = read_json_configuration(configuration_path);

% Convert the user settings into checked, absolute input and output paths.
% The returned specifications also keep the femur/tibia metadata in one place.
[bonepin_specs, bone_specs, acs_mat_path, output_paths] = ...
    prepare_configuration(configuration, fileparts(configuration_path));

% Read and validate the ACS before starting the slower mesh processing. A
% malformed MAT file therefore fails early with a direct explanation.
acs = load_and_validate_acs(acs_mat_path);

% Keep processing and display choices inside the script so the JSON only
% contains values that normally change between datasets.
pcfitsphere_max_distance_fraction = 0.05;
bonepin_axis_scale_fraction = 0.50;
bone_axis_scale_fraction = 0.15;
png_resolution_dpi = 300;

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
        validate_stl_mesh(current_mesh, current_markerstl_path);

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
T_bone_CT = struct();
T_bone_CT.F = [acs.f.R.', acs.f.origin(:); 0 0 0 1];
T_bone_CT.T = [acs.t.R.', acs.t.origin(:); 0 0 0 1];

for idx_bone = 1:numel(bone_specs)
    % Load only the configured bone mesh and keep its exact source path in
    % the public result for later provenance checks.
    current_bone_mesh = stlread(bone_specs(idx_bone).path);
    validate_stl_mesh(current_bone_mesh, bone_specs(idx_bone).path);

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
    current_triangulation = triangulation( ...
        current_mesh.ConnectivityList, current_mesh.Points);

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
    mesh_center = mean(current_vertices, 1);
    mesh_size = max(current_vertices, [], 1) - min(current_vertices, [], 1);
    label_offset_x = max(mesh_size(1) * 0.20, eps);
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
    current_sphere = markerstls(idx_markerstl).sphere;
    fitted_sphere_x = unit_sphere_x * current_sphere.Radius + current_sphere.Center(1);
    fitted_sphere_y = unit_sphere_y * current_sphere.Radius + current_sphere.Center(2);
    fitted_sphere_z = unit_sphere_z * current_sphere.Radius + current_sphere.Center(3);
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
        current_axis_scale = mean( ...
            [markerstls(current_marker_indices).sphere_radius], 'omitnan');
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
    current_bone_triangulation = triangulation( ...
        current_bone_mesh.ConnectivityList, current_bone_mesh.Points);

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
    current_bone_size = max(current_bone_vertices, [], 1) ...
        - min(current_bone_vertices, [], 1);
    current_axis_scale = max(current_bone_size) * bone_axis_scale_fraction;
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








%% HELPER: READ JSON CONFIGURATION

function configuration = read_json_configuration(configuration_path)
%READ_JSON_CONFIGURATION Read the fixed JSON file with a useful error message.

    % Check the path first so a missing configuration is distinguished from
    % invalid JSON content.
    if ~isfile(configuration_path)
        error('preprocess_markerstls:ConfigurationNotFound', ...
            'Configuration file not found: %s', configuration_path);
    end

    % Keep JSON parsing inside a try block so syntax errors include both the
    % configuration path and MATLAB's parser explanation.
    try
        configuration_text = fileread(configuration_path);
        configuration = jsondecode(configuration_text);
    catch configuration_error
        error('preprocess_markerstls:InvalidConfigurationJson', ...
            'Could not read configuration JSON "%s". Reason: %s', ...
            configuration_path, configuration_error.message);
    end

    if ~isstruct(configuration) || ~isscalar(configuration)
        error('preprocess_markerstls:InvalidConfigurationRoot', ...
            'Configuration JSON must contain one object at its top level: %s', ...
            configuration_path);
    end
end


%% HELPER: PREPARE CONFIGURATION

function [bonepin_specs, bone_specs, acs_mat_path, output_paths] = ...
        prepare_configuration(configuration, configuration_directory)
%PREPARE_CONFIGURATION Validate settings and build absolute pipeline paths.

    % Read the three required sections before accessing their child fields so
    % missing or incorrectly typed sections produce short, specific errors.
    markers_configuration = require_struct_field(configuration, 'markers', 'markers');
    bones_configuration = require_struct_field(configuration, 'bones', 'bones');
    output_configuration = require_struct_field(configuration, 'output', 'output');
    femur_markers_configuration = require_struct_field( ...
        markers_configuration, 'femur', 'markers.femur');
    tibia_markers_configuration = require_struct_field( ...
        markers_configuration, 'tibia', 'markers.tibia');

    % Resolve user directories against the JSON location when relative paths
    % are used, while retaining absolute paths unchanged.
    marker_directory_setting = require_text_field( ...
        markers_configuration, 'directory', 'markers.directory');
    marker_directory = resolve_directory_path( ...
        marker_directory_setting, configuration_directory, ...
        'markers.directory', false);

    bone_directory_setting = require_text_field( ...
        bones_configuration, 'directory', 'bones.directory');
    bone_directory = resolve_directory_path( ...
        bone_directory_setting, configuration_directory, ...
        'bones.directory', false);

    % These keys explain the geometric meaning of each marker directly in
    % JSON, where regular code comments are not available.
    marker_file_fields = { ...
        'marker_1_origin_file', ...
        'marker_2_x_reference_file', ...
        'marker_3_y_reference_file', ...
        'marker_4_additional_file'};

    bonepin_names = {'Femur', 'Tibia'};
    bonepin_codes = {'F', 'T'};
    bonepin_places = {'PRO', 'DIS'};
    bonepin_configurations = { ...
        femur_markers_configuration, ...
        tibia_markers_configuration};

    % Build two fixed specifications because the transform function requires
    % exactly four ordered markers for both femur and tibia.
    bonepin_specs = struct( ...
        'name', {}, ...
        'bone', {}, ...
        'place', {}, ...
        'marker_names', {}, ...
        'marker_paths', {});

    for idx_bonepin = 1:numel(bonepin_names)
        current_marker_names = cell(1, 4);
        current_marker_paths = cell(1, 4);

        for current_marker_number = 1:4
            current_field_name = marker_file_fields{current_marker_number};
            current_field_label = sprintf('markers.%s.%s', ...
                lower(bonepin_names{idx_bonepin}), current_field_name);
            current_marker_name = require_text_field( ...
                bonepin_configurations{idx_bonepin}, ...
                current_field_name, current_field_label);
            validate_file_extension(current_marker_name, '.stl', current_field_label);

            current_marker_names{current_marker_number} = current_marker_name;
            current_marker_paths{current_marker_number} = resolve_input_file( ...
                marker_directory, current_marker_name, current_field_label);
        end

        bonepin_specs(idx_bonepin).name = bonepin_names{idx_bonepin};
        bonepin_specs(idx_bonepin).bone = bonepin_codes{idx_bonepin};
        bonepin_specs(idx_bonepin).place = bonepin_places{idx_bonepin};
        bonepin_specs(idx_bonepin).marker_names = current_marker_names;
        bonepin_specs(idx_bonepin).marker_paths = current_marker_paths;
    end

    % Reject repeated source files because one mesh cannot represent two
    % different physical marker roles in the same rigid-body definition.
    all_marker_paths = [bonepin_specs.marker_paths];
    marker_paths_for_comparison = string(all_marker_paths);
    if ispc
        marker_paths_for_comparison = lower(marker_paths_for_comparison);
    end
    if numel(unique(marker_paths_for_comparison)) ~= numel(marker_paths_for_comparison)
        error('preprocess_markerstls:DuplicateMarkerFile', ...
            'Each configured marker role must refer to a unique STL file.');
    end

    % Build fixed femur and tibia bone specifications using checked files in
    % the common configured bone directory.
    bone_file_fields = {'femur_stl_file', 'tibia_stl_file'};
    bone_names = {'Femur', 'Tibia'};
    bone_codes = {'F', 'T'};
    bone_specs = struct('name', {}, 'bone', {}, 'filename', {}, 'path', {});

    for idx_bone = 1:numel(bone_names)
        current_field_name = bone_file_fields{idx_bone};
        current_field_label = sprintf('bones.%s', current_field_name);
        current_bone_filename = require_text_field( ...
            bones_configuration, current_field_name, current_field_label);
        validate_file_extension(current_bone_filename, '.stl', current_field_label);

        bone_specs(idx_bone).name = bone_names{idx_bone};
        bone_specs(idx_bone).bone = bone_codes{idx_bone};
        bone_specs(idx_bone).filename = current_bone_filename;
        bone_specs(idx_bone).path = resolve_input_file( ...
            bone_directory, current_bone_filename, current_field_label);
    end

    % Resolve the ACS filename from the same bone directory, matching the
    % current dataset layout while still allowing relative subdirectories.
    acs_mat_filename = require_text_field( ...
        bones_configuration, 'acs_mat_file', 'bones.acs_mat_file');
    validate_file_extension(acs_mat_filename, '.mat', 'bones.acs_mat_file');
    acs_mat_path = resolve_input_file( ...
        bone_directory, acs_mat_filename, 'bones.acs_mat_file');

    % Create and canonicalize the output directory only after every input
    % path has passed validation.
    output_directory_setting = require_text_field( ...
        output_configuration, 'directory', 'output.directory');
    output_directory = resolve_directory_path( ...
        output_directory_setting, configuration_directory, ...
        'output.directory', true);

    % The base name intentionally has no path or extension because one value
    % is shared by the MAT, FIG, and PNG outputs.
    output_base_name = require_text_field( ...
        output_configuration, 'base_name', 'output.base_name');
    validate_output_base_name(output_base_name);

    output_paths = struct();
    output_paths.directory = output_directory;
    output_paths.mat_file = fullfile(output_directory, [output_base_name '.mat']);
    output_paths.fig_file = fullfile(output_directory, [output_base_name '.fig']);
    output_paths.png_file = fullfile(output_directory, [output_base_name '.png']);
end


%% HELPER: REQUIRE STRUCT FIELD

function required_value = require_struct_field(parent_struct, field_name, field_label)
%REQUIRE_STRUCT_FIELD Return one required scalar object from decoded JSON.

    if ~isstruct(parent_struct) || ~isscalar(parent_struct) ...
            || ~isfield(parent_struct, field_name)
        error('preprocess_markerstls:MissingConfigurationField', ...
            'Required configuration object "%s" is missing.', field_label);
    end

    required_value = parent_struct.(field_name);
    if ~isstruct(required_value) || ~isscalar(required_value)
        error('preprocess_markerstls:InvalidConfigurationField', ...
            'Configuration field "%s" must be one JSON object.', field_label);
    end
end


%% HELPER: REQUIRE TEXT FIELD

function text_value = require_text_field(parent_struct, field_name, field_label)
%REQUIRE_TEXT_FIELD Return one required, nonempty text value from decoded JSON.

    if ~isstruct(parent_struct) || ~isscalar(parent_struct) ...
            || ~isfield(parent_struct, field_name)
        error('preprocess_markerstls:MissingConfigurationField', ...
            'Required configuration field "%s" is missing.', field_label);
    end

    raw_value = parent_struct.(field_name);
    if isstring(raw_value) && isscalar(raw_value)
        text_value = char(raw_value);
    elseif ischar(raw_value) && isrow(raw_value)
        text_value = raw_value;
    else
        error('preprocess_markerstls:InvalidConfigurationField', ...
            'Configuration field "%s" must contain one text value.', field_label);
    end

    text_value = strtrim(text_value);
    if isempty(text_value)
        error('preprocess_markerstls:InvalidConfigurationField', ...
            'Configuration field "%s" cannot be empty.', field_label);
    end
end


%% HELPER: RESOLVE DIRECTORY PATH

function resolved_directory = resolve_directory_path( ...
        configured_directory, configuration_directory, field_label, create_if_missing)
%RESOLVE_DIRECTORY_PATH Make a configured directory absolute and validate it.

    % Relative directories start beside the JSON file, which makes a copied
    % project configuration portable without depending on MATLAB's pwd.
    if is_absolute_path(configured_directory)
        candidate_directory = configured_directory;
    else
        candidate_directory = fullfile(configuration_directory, configured_directory);
    end

    % Input directories must already exist. The output directory is the only
    % configured directory that the workflow is allowed to create.
    if ~isfolder(candidate_directory)
        if ~create_if_missing
            error('preprocess_markerstls:InputDirectoryNotFound', ...
                'Configured directory "%s" was not found: %s', ...
                field_label, candidate_directory);
        end

        [directory_created, creation_message] = mkdir(candidate_directory);
        if ~directory_created
            error('preprocess_markerstls:OutputDirectoryCreationFailed', ...
                'Could not create output directory "%s". Reason: %s', ...
                candidate_directory, creation_message);
        end
    end

    resolved_directory = canonical_existing_path(candidate_directory, field_label);
end


%% HELPER: RESOLVE INPUT FILE

function resolved_file = resolve_input_file(parent_directory, configured_file, field_label)
%RESOLVE_INPUT_FILE Resolve and validate one file below its configured directory.

    % Individual input settings are filenames or relative path fragments.
    % Keeping directories separate prevents eight repeated marker paths in JSON.
    if is_absolute_path(configured_file)
        error('preprocess_markerstls:AbsoluteFilenameNotAllowed', ...
            'Configuration field "%s" must be relative to its configured directory.', ...
            field_label);
    end

    candidate_file = fullfile(parent_directory, configured_file);
    if ~isfile(candidate_file)
        error('preprocess_markerstls:InputFileNotFound', ...
            'Configured input file "%s" was not found: %s', ...
            field_label, candidate_file);
    end

    resolved_file = canonical_existing_path(candidate_file, field_label);
end


%% HELPER: IS ABSOLUTE PATH

function is_absolute = is_absolute_path(path_value)
%IS_ABSOLUTE_PATH Recognize Windows, UNC, and Unix-style absolute paths.

    if ispc
        % A Windows path can start with a drive plus separator, a root
        % separator, or a forward slash accepted by MATLAB on Windows.
        has_drive_root = ~isempty(regexp(path_value, '^[A-Za-z]:[\\/]', 'once'));
        has_separator_root = startsWith(path_value, filesep) || startsWith(path_value, '/');
        is_absolute = has_drive_root || has_separator_root;
    else
        is_absolute = startsWith(path_value, '/');
    end
end


%% HELPER: CANONICAL EXISTING PATH

function canonical_path = canonical_existing_path(candidate_path, field_label)
%CANONICAL_EXISTING_PATH Return MATLAB's normalized full path for provenance.

    [path_found, path_attributes] = fileattrib(candidate_path);
    if ~path_found
        error('preprocess_markerstls:PathResolutionFailed', ...
            'Could not resolve configured path "%s": %s', ...
            field_label, candidate_path);
    end
    canonical_path = path_attributes.Name;
end


%% HELPER: VALIDATE FILE EXTENSION

function validate_file_extension(filename, expected_extension, field_label)
%VALIDATE_FILE_EXTENSION Catch accidental file-type selections in the JSON.

    [~, ~, actual_extension] = fileparts(filename);
    if ~strcmpi(actual_extension, expected_extension)
        error('preprocess_markerstls:InvalidInputExtension', ...
            'Configuration field "%s" must name a %s file.', ...
            field_label, expected_extension);
    end
end


%% HELPER: VALIDATE OUTPUT BASE NAME

function validate_output_base_name(output_base_name)
%VALIDATE_OUTPUT_BASE_NAME Ensure one base safely forms all three output names.

    [base_folder, parsed_base_name, base_extension] = fileparts(output_base_name);
    invalid_filename_characters = '<>:"/\|?*';

    % Reject paths, extensions, and characters that Windows cannot use in a
    % filename. This gives a clear configuration error before export begins.
    if ~isempty(base_folder) ...
            || ~isempty(base_extension) ...
            || ~strcmp(parsed_base_name, output_base_name) ...
            || any(ismember(output_base_name, invalid_filename_characters)) ...
            || isspace(output_base_name(end)) ...
            || output_base_name(end) == '.'
        error('preprocess_markerstls:InvalidOutputBaseName', ...
            ['Configuration field "output.base_name" must be a filename ' ...
             'without a directory, extension, trailing space, or special path characters.']);
    end
end


%% HELPER: LOAD AND VALIDATE ACS

function acs = load_and_validate_acs(acs_mat_path)
%LOAD_AND_VALIDATE_ACS Read and validate the fixed femur/tibia ACS contract.

    % Load only acs so unrelated variables in the MAT file cannot silently
    % appear in the script workspace.
    loaded_acs = load(acs_mat_path, 'acs');
    if ~isfield(loaded_acs, 'acs')
        error('preprocess_markerstls:MissingAcsVariable', ...
            'ACS MAT file does not contain the expected "acs" variable: %s', ...
            acs_mat_path);
    end

    acs = loaded_acs.acs;
    if ~isstruct(acs) || ~isscalar(acs)
        error('preprocess_markerstls:InvalidAcsVariable', ...
            'Variable "acs" must be one struct in MAT file: %s', acs_mat_path);
    end

    femur_acs = require_struct_field(acs, 'f', 'acs.f');
    tibia_acs = require_struct_field(acs, 't', 'acs.t');
    validate_acs_frame(femur_acs, 'acs.f', acs_mat_path);
    validate_acs_frame(tibia_acs, 'acs.t', acs_mat_path);
end


%% HELPER: VALIDATE ACS FRAME

function validate_acs_frame(acs_frame, frame_label, acs_mat_path)
%VALIDATE_ACS_FRAME Check one row-wise rotation matrix and origin vector.

    if ~isfield(acs_frame, 'R') || ~isfield(acs_frame, 'origin')
        error('preprocess_markerstls:MissingAcsField', ...
            'ACS frame "%s" must contain fields R and origin in: %s', ...
            frame_label, acs_mat_path);
    end

    current_rotation = acs_frame.R;
    current_origin = acs_frame.origin;

    % Only the shape and numerical validity are enforced because measured ACS
    % rotations can contain small deviations from perfect orthonormality.
    if ~isnumeric(current_rotation) ...
            || ~isreal(current_rotation) ...
            || ~isequal(size(current_rotation), [3 3]) ...
            || any(~isfinite(current_rotation), 'all')
        error('preprocess_markerstls:InvalidAcsRotation', ...
            'ACS field "%s.R" must be a finite real 3-by-3 numeric matrix.', ...
            frame_label);
    end

    if ~isnumeric(current_origin) ...
            || ~isreal(current_origin) ...
            || numel(current_origin) ~= 3 ...
            || any(~isfinite(current_origin), 'all')
        error('preprocess_markerstls:InvalidAcsOrigin', ...
            'ACS field "%s.origin" must contain three finite real numeric values.', ...
            frame_label);
    end
end


%% HELPER: VALIDATE STL MESH

function validate_stl_mesh(mesh_object, mesh_path)
%VALIDATE_STL_MESH Check the triangulation shape used by all later sections.

    if ~isa(mesh_object, 'triangulation')
        error('preprocess_markerstls:InvalidStlMesh', ...
            'stlread did not return a triangulation for: %s', mesh_path);
    end

    mesh_points = mesh_object.Points;
    mesh_connectivity = mesh_object.ConnectivityList;

    % Sphere fitting needs at least four finite 3D samples; bone meshes also
    % easily satisfy this small requirement when they are valid surfaces.
    if ~isnumeric(mesh_points) ...
            || size(mesh_points, 2) ~= 3 ...
            || size(mesh_points, 1) < 4 ...
            || any(~isfinite(mesh_points), 'all') ...
            || ~isnumeric(mesh_connectivity) ...
            || size(mesh_connectivity, 2) ~= 3 ...
            || isempty(mesh_connectivity)
        error('preprocess_markerstls:InvalidStlMesh', ...
            'STL file does not contain a finite triangular 3D mesh: %s', mesh_path);
    end
end
