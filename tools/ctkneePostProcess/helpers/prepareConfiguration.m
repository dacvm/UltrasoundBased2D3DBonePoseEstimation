function [bonepin_specs, bone_specs, acs_mat_path, output_paths] = ...
        prepareConfiguration(configuration, configuration_directory)
% prepareConfiguration Validate settings and build absolute pipeline paths.
%
% This helper converts the JSON settings into checked paths and fixed
% femur/tibia specifications before the main script loads any mesh data.
%
% Inputs:
%   configuration           - Decoded scalar JSON configuration structure.
%   configuration_directory - Directory containing the configuration file.
%
% Outputs:
%   bonepin_specs - Checked femur and tibia marker specifications.
%   bone_specs    - Checked femur and tibia bone specifications.
%   acs_mat_path  - Absolute path to the ACS MAT file.
%   output_paths  - Structure containing the output directory and file paths.

    % Read the three required sections before accessing their child fields so
    % missing or incorrectly typed sections produce short, specific errors.
    markers_configuration = requireStructField(configuration, 'markers', 'markers');
    bones_configuration = requireStructField(configuration, 'bones', 'bones');
    output_configuration = requireStructField(configuration, 'output', 'output');
    femur_markers_configuration = requireStructField( ...
        markers_configuration, 'femur', 'markers.femur');
    tibia_markers_configuration = requireStructField( ...
        markers_configuration, 'tibia', 'markers.tibia');

    % Resolve user directories against the JSON location when relative paths
    % are used, while retaining absolute paths unchanged.
    marker_directory_setting = requireTextField( ...
        markers_configuration, 'directory', 'markers.directory');
    marker_directory = resolveDirectoryPath( ...
        marker_directory_setting, configuration_directory, ...
        'markers.directory', false);

    bone_directory_setting = requireTextField( ...
        bones_configuration, 'directory', 'bones.directory');
    bone_directory = resolveDirectoryPath( ...
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
            current_marker_name = requireTextField( ...
                bonepin_configurations{idx_bonepin}, ...
                current_field_name, current_field_label);
            validateFileExtension(current_marker_name, '.stl', current_field_label);

            current_marker_names{current_marker_number} = current_marker_name;
            current_marker_paths{current_marker_number} = resolveInputFile( ...
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
        current_bone_filename = requireTextField( ...
            bones_configuration, current_field_name, current_field_label);
        validateFileExtension(current_bone_filename, '.stl', current_field_label);

        bone_specs(idx_bone).name = bone_names{idx_bone};
        bone_specs(idx_bone).bone = bone_codes{idx_bone};
        bone_specs(idx_bone).filename = current_bone_filename;
        bone_specs(idx_bone).path = resolveInputFile( ...
            bone_directory, current_bone_filename, current_field_label);
    end

    % Resolve the ACS filename from the same bone directory, matching the
    % current dataset layout while still allowing relative subdirectories.
    acs_mat_filename = requireTextField( ...
        bones_configuration, 'acs_mat_file', 'bones.acs_mat_file');
    validateFileExtension(acs_mat_filename, '.mat', 'bones.acs_mat_file');
    acs_mat_path = resolveInputFile( ...
        bone_directory, acs_mat_filename, 'bones.acs_mat_file');

    % Create and canonicalize the output directory only after every input
    % path has passed validation.
    output_directory_setting = requireTextField( ...
        output_configuration, 'directory', 'output.directory');
    output_directory = resolveDirectoryPath( ...
        output_directory_setting, configuration_directory, ...
        'output.directory', true);

    % The base name intentionally has no path or extension because one value
    % is shared by the MAT, FIG, and PNG outputs.
    output_base_name = requireTextField( ...
        output_configuration, 'base_name', 'output.base_name');
    validateOutputBaseName(output_base_name);

    % Keep every generated path in one structure so the main script does not
    % need to repeat output naming rules.
    output_paths = struct();
    output_paths.directory = output_directory;
    output_paths.mat_file = fullfile(output_directory, [output_base_name '.mat']);
    output_paths.fig_file = fullfile(output_directory, [output_base_name '.fig']);
    output_paths.png_file = fullfile(output_directory, [output_base_name '.png']);
end
