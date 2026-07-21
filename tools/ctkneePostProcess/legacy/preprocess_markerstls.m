clear;
clc;
close all;

% Locate this legacy script instead of depending on MATLAB's current folder.
% The path can therefore be prepared correctly when the script is run from
% the editor, command window, or another project script.
script_full_path = mfilename('fullpath');
if isempty(script_full_path)
    error('preprocess_markerstls:ScriptPathUnavailable', ...
        'Run preprocess_markerstls.m as a complete script so the project functions can be located.');
end

% Walk up from tools/ctkneePostProcess/legacy to the repository root, then
% add the shared geometry and display folders required by this workflow.
legacy_directory = fileparts(script_full_path);
tool_directory = fileparts(legacy_directory);
tools_directory = fileparts(tool_directory);
project_directory = fileparts(tools_directory);
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

%% READ THE MARKER STL FILES

% Path to .stl files represents the optical markers of the bone pins
filepath_markerstls = 'D:\Documents\BELANDA\SonoSkin\data\CTdata-KneePhantom\NoStudyDescription\meshes\markers';

% Find every STL file inside the marker STL folder so the script can process
% all marker meshes without hard-coding file names.
files_markerstls = dir(fullfile(filepath_markerstls, '*.stl'));

% Create a struct array with predictable fields before the loop, so each STL
% file can store its file data, point cloud, sphere fit, and centroid in one place.
markerstls = struct('name', {}, 'path', {}, 'mesh', {}, 'pointcloud', {}, 'sphere', {}, 'sphere_radius', {}, 'sphere_mean_error', {}, 'centroid', {});

% Read each STL file found in the folder and keep the loaded mesh together
% with the source file information for later preprocessing steps.
for idx_markerstl = 1:numel(files_markerstls)
    % Build the full file path because stlread needs the folder and file name.
    current_markerstl_path = fullfile(files_markerstls(idx_markerstl).folder, files_markerstls(idx_markerstl).name);

    % Store the short file name so results can be matched back to the source STL.
    markerstls(idx_markerstl).name = files_markerstls(idx_markerstl).name;

    % Store the full path so later code can reload or report the exact source file.
    markerstls(idx_markerstl).path = current_markerstl_path;

    % Read the STL mesh from disk; recent MATLAB versions return a triangulation object.
    markerstls(idx_markerstl).mesh = stlread(current_markerstl_path);
end

%% DISPLAY MARKER STL FILES

% Setting up the figure first, later we can use the axes object
fig1 = figure('Name', 'Setup Display');
ax1 = axes(fig1);
axis(ax1, 'equal');
hold(ax1, 'on');
grid(ax1, 'on');
xlabel(ax1, 'X');
ylabel(ax1, 'Y');
zlabel(ax1, 'Z');

% Give each mesh a different color so nearby marker STL surfaces are easier
% to tell apart in the same 3D axes.
mesh_colors = lines(max(numel(markerstls), 1));

% Draw every loaded marker STL mesh and place its file name next to the mesh.
for idx_markerstl = 1:numel(markerstls)
    % Keep the current mesh in a short variable so the plotting code is easier to read.
    current_mesh = markerstls(idx_markerstl).mesh;

    % Build a triangulation object explicitly so trisurf receives the mesh in
    % the same compact form MATLAB uses for triangle surface data.
    current_triangulation = triangulation(current_mesh.ConnectivityList, current_mesh.Points);

    % Plot the STL surface with trisurf on the prepared axes.
    trisurf(current_triangulation, ...
        'Parent', ax1, ...
        'FaceColor', mesh_colors(idx_markerstl, :), ...
        'FaceAlpha', 0.45, ...
        'EdgeColor', 'none');

    % Keep the vertex coordinates available for label placement beside the mesh.
    current_vertices = current_triangulation.Points;

    % Find the mesh center so the text label can be placed at the same height
    % as the object instead of floating far above or below it.
    mesh_center = mean(current_vertices, 1);

    % Find the mesh size so the label can be moved to the side without sitting
    % directly on top of the surface.
    mesh_size = max(current_vertices, [], 1) - min(current_vertices, [], 1);

    % Use a small offset to the positive X side; eps prevents a zero offset for
    % very small or flat meshes.
    label_offset_x = max(mesh_size(1) * 0.20, eps);

    % Place the file name next to the mesh and disable TeX parsing so underscores
    % and other file-name characters display literally.
    text(ax1, ...
        mesh_center(1) + label_offset_x, ...
        mesh_center(2), ...
        mesh_center(3), ...
        markerstls(idx_markerstl).name, ...
        'Interpreter', 'none', ...
        'FontSize', 9, ...
        'Color', mesh_colors(idx_markerstl, :), ...
        'FontWeight', 'bold');
end

% Add simple lighting and a 3D view so the marker surfaces are easier to inspect.
camlight(ax1, 'headlight');
lighting(ax1, 'gouraud');
view(ax1, 3);

%% FIT A SPHERE TO EACH OF THE MARKER MESH TO DEFINE THE CENTROID

% Choose how far a mesh point can be from the fitted sphere and still count
% as an inlier; the value is scaled by each marker size so it works across files.
pcfitsphere_max_distance_fraction = 0.05;

% Convert each marker mesh to a point cloud, fit a sphere, and store the sphere
% center as the centroid of that marker.
for idx_markerstl = 1:numel(markerstls)

    % Keep the current mesh in a short variable so the fitting code is easier to read.
    current_mesh = markerstls(idx_markerstl).mesh;

    % Use the mesh vertices as point-cloud points because the scanned marker
    % sphere can be treated as a cloud of 3D surface samples.
    current_points = current_mesh.Points;
    % Convert the mesh vertices to a MATLAB pointCloud object because
    % pcfitsphere expects pointCloud input.
    current_pointcloud = pointCloud(current_points);

    % Estimate the marker size from its bounding box so the inlier tolerance
    % adapts to the scale of the current STL file.
    current_mesh_size = max(current_points, [], 1) - min(current_points, [], 1);

    % Use a fraction of the largest mesh dimension as the maximum distance
    % allowed between inlier points and the fitted sphere.
    current_max_distance = max(current_mesh_size) * pcfitsphere_max_distance_fraction;

    % Fit a sphere to the noisy marker point cloud using MATLAB's robust
    % point-cloud sphere fitting function.
    [current_sphere, ~, ~, current_mean_error] = pcfitsphere(current_pointcloud, current_max_distance);

    % Store all the necessary information for later steps can inspect or reuse the converted data.
    markerstls(idx_markerstl).pointcloud        = current_pointcloud;
    markerstls(idx_markerstl).sphere            = current_sphere;
    markerstls(idx_markerstl).sphere_radius     = current_sphere.Radius;
    markerstls(idx_markerstl).sphere_mean_error = current_mean_error;
    markerstls(idx_markerstl).centroid          = current_sphere.Center;

    % Show the fitted sphere overlaying the mesh
    % Make a unit sphere grid that can be scaled by the fitted radius and moved
    % to the fitted center.
    [unit_sphere_x, unit_sphere_y, unit_sphere_z] = sphere(32);

    % Scale the unit sphere by the fitted radius and move it to the fitted center.
    fitted_sphere_x = unit_sphere_x * current_sphere.Radius + current_sphere.Center(1);
    fitted_sphere_y = unit_sphere_y * current_sphere.Radius + current_sphere.Center(2);
    fitted_sphere_z = unit_sphere_z * current_sphere.Radius + current_sphere.Center(3);

    % Wash out the original mesh color by mixing it with white, so the fitted
    % sphere is visible but does not hide the scanned mesh underneath.
    fitted_sphere_color = mesh_colors(idx_markerstl, :) * 0.35 + [1 1 1] * 0.65;

    % Draw the fitted sphere with low opacity so the original STL mesh remains
    % the main visual reference.
    surf(ax1, ...
        fitted_sphere_x, ...
        fitted_sphere_y, ...
        fitted_sphere_z, ...
        'FaceColor', fitted_sphere_color, ...
        'FaceAlpha', 0.18, ...
        'EdgeColor', 'none');

    % Show the centroid as a point
    % Draw the fitted sphere center as a filled point using the original mesh
    % color, so it is easy to match the centroid to its marker.
    plot3(ax1, ...
        markerstls(idx_markerstl).centroid(1), ...
        markerstls(idx_markerstl).centroid(2), ...
        markerstls(idx_markerstl).centroid(3), ...
        'o', ...
        'MarkerSize', 8, ...
        'MarkerFaceColor', mesh_colors(idx_markerstl, :), ...
        'MarkerEdgeColor', 'k');
end

%% CALCULATE THE RIGID BODY

% Define the two marker groups that represent the femur and tibia bone pins.
bonepin_specs = struct( ...
    'name', {'Femur', 'Tibia'}, ...
    'bone', {'F', 'T'}, ...
    'place', {'PRO', 'DIS'}, ...
    'file_pattern', {'C_F_PRO_*.stl', 'C_T_DIS_*.stl'});

% Create a struct array for the estimated rigid bodies so later steps can use
% each pin transform without searching through the marker STL list again.
bonepins = struct('name', {}, 'bone', {}, 'place', {}, 'file_pattern', {}, 'marker_indices', {}, 'marker_names', {}, 'marker_centroids', {}, 'transform', {}, 'origin', {}, 'base_axes', {});

% Estimate one rigid body for each bone pin described above.
for idx_bonepin = 1:numel(bonepin_specs)

    % Keep the current rigid-body definition in a short variable so the file
    % matching code below is easier to read.
    current_spec = bonepin_specs(idx_bonepin);

    % Prepare fixed slots for markers 1 to 4 so the special marker order is
    % kept even if the files were listed in a different order by dir().
    current_marker_indices   = nan(1, 4);
    current_marker_names     = cell(1, 4);
    current_marker_centroids = nan(3, 4);

    % Find every loaded marker that belongs to the current bone pin.
    for idx_markerstl = 1:numel(markerstls)

        % Build a strict filename pattern so only the intended bone and place
        % are used for the current rigid body.
        current_filename_pattern = sprintf('^C_%s_%s_(\\d+)\\.stl$', current_spec.bone, current_spec.place);

        % Extract the marker number from names like C_F_PRO_1.stl.
        current_filename_tokens = regexp(markerstls(idx_markerstl).name, current_filename_pattern, 'tokens', 'once');

        % Skip files that do not belong to this rigid-body marker group.
        if isempty(current_filename_tokens)
            continue;
        end

        % Convert the marker number from text to a number so it can index the
        % fixed marker slots.
        current_marker_number = str2double(current_filename_tokens{1});

        % Stop early if the filename matches the group but has an unsupported
        % marker number.
        if current_marker_number < 1 || current_marker_number > 4
            error('Unexpected marker number in file: %s', markerstls(idx_markerstl).name);
        end

        % Stop early if two STL files claim the same marker role for one pin.
        if ~isnan(current_marker_indices(current_marker_number))
            error('Duplicate marker number %d found for %s rigid body.', current_marker_number, current_spec.name);
        end

        % Store the index, name, and centroid, so this rigid body can be traced back to markerstls.
        current_marker_indices(current_marker_number)      = idx_markerstl;
        current_marker_names{current_marker_number}        = markerstls(idx_markerstl).name;
        current_marker_centroids(:, current_marker_number) = markerstls(idx_markerstl).centroid(:);
    end

    % Markers 1, 2, and 3 are required because estimateRBfrom3Points uses them
    % as origin, x-axis direction, y-axis direction, and additional point for robustness.
    required_marker_numbers = [1 2 3 4];

    % Find missing required markers before trying to estimate the transform.
    missing_required_markers = required_marker_numbers(isnan(current_marker_indices(required_marker_numbers)));

    % Stop with a clear message if the current pin does not have enough markers.
    if ~isempty(missing_required_markers)
        error('Missing marker(s) %s for %s rigid body using pattern %s.', mat2str(missing_required_markers), current_spec.name, current_spec.file_pattern);
    end

    % Arrange the centroids in the exact order required by estimateRBfrom3Points:
    % marker 1 is origin, marker 2 defines x, and marker 3 defines y.
    current_rigidbody_points = current_marker_centroids(:, required_marker_numbers);

    % Estimate the 4x4 rigid-body transform for the current bone pin.
    current_rigidbody_transform = estimateRBfrom3Points_v2(current_rigidbody_points);

    % Store the rigid-body metadata and transform in one result struct.
    bonepins(idx_bonepin).name             = current_spec.name;
    bonepins(idx_bonepin).bone             = current_spec.bone;
    bonepins(idx_bonepin).place            = current_spec.place;
    bonepins(idx_bonepin).file_pattern     = current_spec.file_pattern;
    bonepins(idx_bonepin).marker_indices   = current_marker_indices;
    bonepins(idx_bonepin).marker_names     = current_marker_names;
    bonepins(idx_bonepin).marker_centroids = current_marker_centroids;
    bonepins(idx_bonepin).transform        = current_rigidbody_transform;
    bonepins(idx_bonepin).origin           = current_rigidbody_transform(1:3, 4);
    bonepins(idx_bonepin).base_axes        = current_rigidbody_transform(1:3, 1:3);
    bonepins(idx_bonepin).T_pin_CT         = [bonepins(idx_bonepin).base_axes, bonepins(idx_bonepin).origin; 0 0 0 1];

    % Scale the displayed axes from the marker spacing so the axes are visible
    % but not much larger than the pin marker group.
    current_axis_scale = max(vecnorm(current_marker_centroids(:, required_marker_numbers) - current_marker_centroids(:, 1), 2, 1)) * 0.50;

    % Use a small fallback scale if the markers are too close or the scale is invalid.
    if isempty(current_axis_scale) || ~isfinite(current_axis_scale) || current_axis_scale <= 0
        current_axis_scale = mean([markerstls(current_marker_indices(1)).sphere_radius], 'omitnan');
    end

    % Draw the rigid-body axes on the same 3D display as the marker meshes.
    display_axis_v2(ax1, ...
        bonepins(idx_bonepin).origin, ...
        bonepins(idx_bonepin).base_axes, ...
        current_axis_scale, ...
        bonepins(idx_bonepin).name, ...
        'Tag', sprintf('plot_%s_rigidbody_axis', lower(bonepins(idx_bonepin).name)), ...
        'Mode', 'default');
end


%% READ THE BONE STL

% Path to .stl files represents the bone, obtained from CT-scan
filepath_bonestls = 'D:\Documents\BELANDA\SonoSkin\data\CTdata-KneePhantom\NoStudyDescription\meshes\bones';

% Filename of the bones
files_bonestl_f   = 'Femur_1_Smoothed_Reduced.stl';
files_bonestl_t   = 'Tibia_1_Smoothed_Reduced.stl';

% .mat files that contains the rigid body definitions of femur and tibia
files_ercmat = 'ERC_CS_20260709-153426.mat';

% Define each bone with the same name and short bone-code convention used by
% rigidbodies, so the CT meshes and marker rigid bodies can be matched easily.
bones_specs = struct( ...
    'name', {'Femur', 'Tibia'}, ...
    'bone', {'F', 'T'}, ...
    'filename', {files_bonestl_f, files_bonestl_t});

% Create a result struct before loading files so each bone keeps its readable
% name, short code, source path, STL mesh, and ACS transform together.
bones = struct('name', {}, 'bone', {}, 'path', {}, 'mesh', {}, ...
    'T_bone_CT', {});

% Load the femur and tibia STL files using the definitions above.
for idx_bone = 1:numel(bones_specs)

    % Keep the current definition in a short variable to make the assignments
    % below easier to read.
    current_bones_spec = bones_specs(idx_bone);

    % Build the full STL path because stlread needs both the folder and file name.
    current_bones_path = fullfile(filepath_bonestls, current_bones_spec.filename);

    % Stop with a direct message when a configured bone STL file cannot be found.
    if ~isfile(current_bones_path)
        error('Bone STL file not found: %s', current_bones_path);
    end

    % Store the bone identity using the same fields as the rigidbodies struct.
    bones(idx_bone).name = current_bones_spec.name;
    bones(idx_bone).bone = current_bones_spec.bone;

    % Store the full path so later code can trace the mesh back to its source file.
    bones(idx_bone).path = current_bones_path;

    % Read and store the STL triangulation for later registration and display steps.
    bones(idx_bone).mesh = stlread(current_bones_path);
end

%% READ BONE ANATOMICAL COORDINATE SYSTEMS

% Pseudo-declare the expected coordinate-system struct before loading it, so
% readers can see that this script expects a struct named acs from the MAT file.
acs = struct(); % This empty value is intentionally replaced by the checked MAT-file value below.

% Build the MAT-file path from the configured bone folder and file name.
filepath_ercmat = fullfile(filepath_bonestls, files_ercmat);

% Stop with a direct message when the configured coordinate-system file is missing.
if ~isfile(filepath_ercmat)
    error('Bone coordinate-system MAT file not found: %s', filepath_ercmat);
end

% Load only the expected variable into a temporary struct to avoid silently
% adding unrelated MAT-file variables to the script workspace.
loaded_ercmat = load(filepath_ercmat, 'acs');

% Verify that the MAT file contains the promised coordinate-system variable.
if ~isfield(loaded_ercmat, 'acs')
    error('MAT file does not contain the expected ''acs'' struct: %s', filepath_ercmat);
end

% Replace the pseudo-declaration with the loaded femur and tibia coordinate systems.
acs = loaded_ercmat.acs;

% Construct a 4x4 rigid body transformation.
% Note that `acs` was calculated from RadboudUMC's script from ERC project.
% For `R` matrix, their local axis convention is row-wise. I want to change
% it into column-wise. Why? Because i am use to this convention.
T_bonefemur_CT = [acs.f.R', acs.f.origin'; 0 0 0 1];
T_bonetibia_CT = [acs.t.R', acs.t.origin'; 0 0 0 1];

% Associate each transform with its stable bone code.
T_bone_CT = struct();
T_bone_CT.F = T_bonefemur_CT;
T_bone_CT.T = T_bonetibia_CT;

% Store each transform in the matching bone record, independent of index.
for idx_bone = 1:numel(bones)

    % Read the stable bone code that was stored with the current record.
    current_bone_code = bones(idx_bone).bone;

    % Stop if the bone has no corresponding transform.
    if ~isfield(T_bone_CT, current_bone_code)
        error('No ACS transform found for bone code "%s".', ...
            current_bone_code);
    end

    % Save the matching 4-by-4 transform in the bone record.
    bones(idx_bone).T_bone_CT = T_bone_CT.(current_bone_code);
end

%% DISPLAY BONES AND THEIR CORRESPONDING ACL

% Give each bone a different color so the femur and tibia remain easy to
% distinguish when their surfaces overlap in the shared axes.
bone_colors = lines(max(numel(bones), 1));

% Draw each ACS at a fixed fraction of its bone size so the arrows remain
% readable without depending on hard-coded CT coordinate units.
bone_axis_scale_fraction = 0.15;

% Display every bone and its matching anatomical coordinate system on ax1.
for idx_bone = 1:numel(bones)

    % Keep the current mesh in a short variable so the plotting code is easier to read.
    current_bone_mesh = bones(idx_bone).mesh;

    % Build a triangulation explicitly so trisurf receives consistent triangle data.
    current_bone_triangulation = triangulation( ...
        current_bone_mesh.ConnectivityList, ...
        current_bone_mesh.Points);

    % Draw a semi-transparent surface so the ACS remains visible inside the bone.
    trisurf(current_bone_triangulation, ...
        'Parent', ax1, ...
        'FaceColor', bone_colors(idx_bone, :), ...
        'FaceAlpha', 0.35, ...
        'EdgeColor', 'none', ...
        'Tag', sprintf('plot_%s_bone_mesh', lower(bones(idx_bone).name)));

    % Measure the bone bounding box to choose an ACS arrow length for this mesh.
    current_bone_vertices = current_bone_triangulation.Points;
    current_bone_size = max(current_bone_vertices, [], 1) ...
        - min(current_bone_vertices, [], 1);
    current_axis_scale = max(current_bone_size) * bone_axis_scale_fraction;

    % Use a small fallback when the mesh has no valid spatial extent.
    if isempty(current_axis_scale) || ~isfinite(current_axis_scale) || current_axis_scale <= 0
        current_axis_scale = 1;
    end

    % Split the stored transform into the origin and column-wise ACS directions
    % expected by display_axis_v2.
    current_bone_transform = bones(idx_bone).T_bone_CT;
    current_bone_origin = current_bone_transform(1:3, 4);
    current_bone_base_axes = current_bone_transform(1:3, 1:3);

    % Draw and label the matching ACS on the same axes as the bone surface.
    display_axis_v2(ax1, ...
        current_bone_origin, ...
        current_bone_base_axes, ...
        current_axis_scale, ...
        sprintf('%s ACS', bones(idx_bone).name), ...
        'Tag', sprintf('plot_%s_acs', lower(bones(idx_bone).name)), ...
        'Mode', 'default');
end

% % Apply smooth lighting to the newly added bone surfaces and keep a 3D view.
% lighting(ax1, 'gouraud');
% view(ax1, 3);

