%% SUMMARY OF THIS SCRIPT
% This is an example script. Treat it as a guideline if you want to do
% things in the following:
% 1. What are the data that is required
% 2. How to read the data that is required
% 3. Showing the ultrasound 2D image plane in 3D
% 4. Showing the scene (mesh and the image planes)
% 5. How to calculate 2D/3D intersection
% 6. How to show the 2D/3D intersection

clear; clc; close all;

% Generate path to functions
addpath(genpath('functions'));

% toggle for recording
is_record = false;

%% LOADING THE ULTRASOUND CALIBRATION FILE

% Build the absolute path to the sample fCal XML file containing
% calibration matrix for ultrasound
str_filename = 'PlusDeviceSet_fCal_Epiphan_NDIPolaris_UTNML__20260312_120634.xml';
fcalConfigPath = fullfile(pwd, 'data', str_filename);

% Parse all <Transform> entries under <CoordinateDefinitions>.
transformations = read_fcal_transforms(fcalConfigPath);
% get the transformation of the image in the probe coordinate frame
T_image_probecalib = transformations(1).Matrix;

% The original T_image_probe contains
% Extract the original 3x3 rotation block from Image->Probe transform.
R_image_probe_raw = T_image_probecalib(1:3, 1:3);
% Decompose the raw matrix with SVD to separate rotation part and scale part.
[U_image_probe, ~, V_image_probe] = svd(R_image_probe_raw);
% Build the closest orthogonal rotation (minimum Frobenius error).
R_image_probe_orth = U_image_probe * V_image_probe';
% If determinant is negative, flip the last axis to enforce a proper right-handed rotation (det = +1).
if det(R_image_probe_orth) < 0
    U_image_probe(:, 3) = -U_image_probe(:, 3);
    R_image_probe_orth = U_image_probe * V_image_probe';
end
% Write the orthogonalized rotation back into the 4x4 rigid transform.
T_image_probecalib(1:3, 1:3) = R_image_probe_orth;

% Get the scaling vector
S_image_probecalib = vecnorm(R_image_probe_raw,2,1);   % [sx sy sz]


%% SMOOTHING THE RIGID BODY TRANSFORMATION DATA

filenames = {'SequenceRecording_2026-04-13_17-49-02.mha', ...
             'SequenceRecording_2026-04-13_17-52-51.mha'};
n_filename = length(filenames);

% Initialize
sequences = cell(1,n_filename);

fprintf('Smoothing the qualisys data...\n');
for index_filename = 1:n_filename
    % Get the Sequence Recording file
    sequencePath = fullfile('D:\Documents\BELANDA\SonoSkin\data\dennis_data\2026-13-04_phantom', filenames{index_filename});
    % Parse the sequence file into a MATLAB struct.
    sequence = read_sequence_image(sequencePath);
    
    % Get all of the rigid body matrix of the probe (from qualisys)
    ProbeToTrackerDeviceTransform_all     = cat(3, sequence.packets.ProbeToTrackerDeviceTransform);
    ReferenceToTrackerDeviceTransform_all = cat(3, sequence.packets.ReferenceToTrackerDeviceTransform);
    
    % Filter the qualisys measurement
    ProbeToTrackerDeviceTransform_all_smooth     = smoothTransformations(ProbeToTrackerDeviceTransform_all, 'method', 'sgolay', 'window', 20);
    ReferenceToTrackerDeviceTransform_all_smooth = smoothTransformations(ReferenceToTrackerDeviceTransform_all, 'method', 'sgolay', 'window', 20);
    % Visualize the smoothing 
    % visualize_smoothing_results(ProbeToTrackerDeviceTransform_all, ProbeToTrackerDeviceTransform_all_smooth);
    
    C = reshape(num2cell(cat(3, ProbeToTrackerDeviceTransform_all_smooth), [1 2]), 1, []);
    [sequence.packets.ProbeToTrackerDeviceTransform_Filtered] = deal(C{:});
    C = reshape(num2cell(cat(3, ReferenceToTrackerDeviceTransform_all_smooth), [1 2]), 1, []);
    [sequence.packets.ReferenceToTrackerDeviceTransform_Filtered] = deal(C{:});

    % Store the sequence
    sequences{index_filename} = sequence;
    % Print and indicator that smoothing is done
    fprintf('%s done.\n', filenames{index_filename});
end


%% COLLECTING 2D IMAGE PLANES

% Prepare the figure object
fig1 = figure('Name', 'Figure');
ax1  = axes(fig1);
xlabel(ax1,'X');
ylabel(ax1,'Y');
zlabel(ax1,'Z');
grid(ax1, 'on');
axis(ax1, 'equal')
hold(ax1, 'on');
view(ax1, 35, 40);

% Set the quiver scale
quiverscale = 20;

% Create a template for storing plane
template    = struct('p0', [], 'ex', [], 'ey', [], 'n', [], 'W', 0, 'H', 0, 'image', [], 'timestamp', 0);
plane_index = 1; 

% loop for all .mha files we have
for index_filename = 1:n_filename

    % get the current sequence
    sequence = sequences{index_filename};
    % Grab the number of packet
    n_packet = sequence.header.DimSize(3);
    
    % Loop over the data
    for idx_packet = 100:100:n_packet
    
        % Delete necessary object from previous iterations
        delete(findobj('Tag', 'plot_axes'));
        delete(findobj('Tag', 'plot_origin_window'));
    
        % Get the current packet
        current_packet = sequence.packets(idx_packet);
        % Check whether the current packet is invalid or not
        if(~current_packet.ProbeToTrackerDeviceTransformStatus)
            continue;
        end
    
        % I want to give a bit of context for transparancy of the process here
        % for next particular line:
        T_global_probe = current_packet.ProbeToTrackerDeviceTransform_Filtered;
        T_global_ref   = current_packet.ReferenceToTrackerDeviceTransform_Filtered;
        T_probe_ref    = inv(T_global_ref) * T_global_probe;
        % visualzie the coordinate frame of the probe
        origin      = T_probe_ref(1:3, 4);
        base_axes   = T_probe_ref(1:3, 1:3);
        axisname    = 'B_N_PRB';
        display_axis_v2(ax1, origin, base_axes, quiverscale, axisname, 'Tag', 'plot_axes', 'Mode', 'default');
    
        % calculate the coordinate frame of the image
        T_image_ref = T_probe_ref * T_image_probecalib;
        % visualize the coordinate frame of the image
        origin      = T_image_ref(1:3, 4);
        base_axes   = T_image_ref(1:3, 1:3);
        axisname    = 'Image';
        display_axis_v2(ax1, origin, base_axes, quiverscale, axisname, 'Tag', 'plot_axes', 'Mode', 'default');
    
        % Draw the ultrasound image plane in 3D using a helper function to keep this loop compact.
        % Keep SwapXY=true because sequence packets store image as [width, height].
        % Keep grayscale colormap configurable here so future experiments only change one line.
        h = display_image3D(ax1, current_packet.Image, T_image_ref, ...
                            'SwapXY', true, ...
                            'PixelSpacing', [S_image_probecalib(1) S_image_probecalib(2)], ...
                            'Tag', 'plot_usimage', ...
                            'Colormap', 'gray', ...
                            'FaceAlpha', 0.5);    
        drawnow;

        % Store the plane in this format
        plane.p0 = origin;
        plane.ex = base_axes(:,1);
        plane.ey = base_axes(:,2);
        plane.n  = base_axes(:,3);
        plane.W  = (size(current_packet.Image, 1)-1) * S_image_probecalib(1);
        plane.H  = (size(current_packet.Image, 2)-1) * S_image_probecalib(2);
        plane.nRows = size(current_packet.Image, 2);
        plane.nCols = size(current_packet.Image, 1);
        plane.image     = current_packet.Image;
        plane.timestamp = current_packet.Timestamp;
        planes(plane_index) = plane;

        plane_index = plane_index+1;

    end
end


%% LOAD ACS DATA

% Build the absolute path to the femur ACS mat file in the bones folder.
acs_filename = 'CT_Femur_editedFlipped_scaled_20260421-174922.mat';
acs_path     = fullfile(pwd, 'data', 'bones', acs_filename);

% Load the mat content into a struct so we can safely pick the ACS variable by name.
acs_loaded = load(acs_path);
% Use the "acs" field directly when available because that is the expected variable name.
if isfield(acs_loaded, 'acs')
    acs = acs_loaded.acs;
else
    % Fall back to the first variable in the mat file to keep this robust to name changes.
    acs_fields = fieldnames(acs_loaded);
    acs = acs_loaded.(acs_fields{1});
end

% Build the baseline femur transform from CT frame to target frame.
% Why transposed (R' and origin')? Because the function for calculating ACS
% from RadboudUMC is using different convention of rotation matrix
T_femurct_originct = [acs.f.R', acs.f.origin'; 0 0 0 1];


%% LOAD MANUAL ADJUSTMENT DATA

% Get the transformation from the CT-scan coordinate frame to the manual
% adjustment (T that transform the bone close to the images, I did this manually)
% Build the absolute path to the .mat file that contains that transformation
manualadjustment_filename = 'manual_transformation_adjustments_20260422-154031.mat';
manualadjustment_path     = fullfile(pwd, 'output', 'manual_transformation_adjustments', manualadjustment_filename);

% Load the content (T_femurlabmanual_bonect and T_femurlabmanual_originct)
manualadjustment_loaded   = load(manualadjustment_path);
T_femurlabmanual_bonect   = manualadjustment_loaded.T_femurlabmanual_bonect;

% Propagate the original femur transformation with this manual adjustment
T_femurlabmanual_originct = T_femurlabmanual_bonect * T_femurct_originct;


%% LOAD MESH FILE

% Read STL mesh into faces and vertices while handling common stlread output variants.
stl_path                      = fullfile(pwd, 'data', 'bones', 'CT_Femur_editedFlipped_scaled_distal.stl');
[femur_faces, femur_vertices] = readStlMesh(stl_path);

% Apply the baseline femur transform once so the first draw matches T_femurct_originct.
femur_vertices_world = applyRigidTransform(femur_vertices, T_femurlabmanual_originct);

% Draw the femur as a single patch object so we can update only vertices during key presses.
h_femur = patch(ax1, ...
    'Faces', femur_faces, ...
    'Vertices', femur_vertices_world, ...
    'FaceColor', [0.92 0.83 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.55, ...
    'Tag', 'plot_femur_stl');
% Visualize the coordinate frame of the femur
display_axis_v2(ax1, T_femurlabmanual_originct(1:3, 4), ...
                     T_femurlabmanual_originct(1:3, 1:3), ...
                     quiverscale, 'Femur', ...
                     'Tag', 'plot_axes', ...
                     'Mode', 'default');

% Add basic lighting so the 3D shape is easier to read while aligning.
camlight(ax1, 'headlight');
lighting(ax1, 'gouraud');
material(ax1, 'dull');

% Use the already transformed femur vertices because the image plane also lives in the reference frame.
mesh.V = femur_vertices_world;
mesh.F = femur_faces;


%% COMPUTE THE INTERSECTION OF THE 3D MESH WITH THE 2D IMAGE PLANE

% Count how many stored planes we will test against the same mesh.
n_planes = numel(planes);
% Set the maximum angle from -plane.ey used to keep mesh faces that face the probe direction.
normalFacingToleranceDeg = 50;

% Preallocate a result struct array so every plane keeps its own intersection outputs.
intersections = repmat(struct('mask', [], 'pixelList', [], 'segments3D', {{}}, 'segmentsUV', {{}}, ...
                              'segmentFaceIdx', [], 'probeFacingSegmentMask', [], 'probeFacingSegments3D', {{}}, ...
                              'probeFacingSegmentsUV', {{}}, 'probeFacingPixels', [], 'segmentFacingScore', [], ...
                              'timestamp', []), 1, n_planes);

% Remove older intersection overlays so repeated runs do not stack stale results.
delete(findobj(ax1, 'Tag', 'plot_mesh_plane_intersection'));

% Open a new figure that will show one tile per plane image.
fig_mask = figure('Name', 'Mesh-Plane Intersection Images');
n_tile_cols = ceil(sqrt(n_planes));           % Choose a compact tile count so many planes still fit in one figure reasonably.
n_tile_rows = ceil(n_planes / n_tile_cols);   % Choose the matching number of tile rows so every plane gets a tile.
tile_layout = tiledlayout(fig_mask, n_tile_rows, n_tile_cols, 'TileSpacing', 'compact', 'Padding', 'compact');

% Loop over every stored plane so the same mesh is tested against each image plane.
for idx_plane = 1:n_planes

    % Read the current plane struct once so the loop body stays easy to read.
    plane = planes(idx_plane);
    % Run the mesh-plane intersection for the current plane.
    [mask, pixelList, segments3D, segmentsUV, segmentFaceIdx] = meshPlaneIntersectionPixels(mesh, plane);

    % Compute the physical pixel width once so UV points can be resampled and converted to pixels.
    du = plane.W / plane.nCols;
    dv = plane.H / plane.nRows;
    % Keep only segments whose source mesh face normal points against plane.ey within the requested tolerance.
    [probeFacingSegmentMask, probeFacingSegments3D, probeFacingSegmentsUV, probeFacingPixels, segmentFacingScore] = ...
        selectProbeFacingIntersectionSegments(mesh, segments3D, segmentsUV, segmentFaceIdx, plane, ...
                                             du, dv, plane.nRows, plane.nCols, normalFacingToleranceDeg);

    % Count how many returned segments survived the probe-facing selection.
    n_probe_facing_segments = sum(probeFacingSegmentMask);
    % Count how many image pixels were rasterized from the probe-facing segments.
    n_probe_facing_pixels = size(probeFacingPixels, 1);
    % Print a compact summary for the current plane so progress is easy to follow in the console.
    fprintf(['[Plane %d/%d, timestamp %.3f]\n' ...
             '%d hit pixels, %d 3D segments, %d UV segments,\n' ...
             '%d probe-facing segments and %d probe-facing pixels within %.1f deg of -plane.ey.\n'], ...
            idx_plane, n_planes, double(plane.timestamp), size(pixelList, 1), numel(segments3D), numel(segmentsUV), ...
            n_probe_facing_segments, n_probe_facing_pixels, normalFacingToleranceDeg);

    % Store the current outputs so they remain available after the loop finishes.
    intersections(idx_plane).mask           = mask;
    intersections(idx_plane).pixelList      = pixelList;
    intersections(idx_plane).segments3D     = segments3D;
    intersections(idx_plane).segmentsUV     = segmentsUV;
    intersections(idx_plane).segmentFaceIdx = segmentFaceIdx;
    intersections(idx_plane).probeFacingSegmentMask = probeFacingSegmentMask;
    intersections(idx_plane).probeFacingSegments3D  = probeFacingSegments3D;
    intersections(idx_plane).probeFacingSegmentsUV  = probeFacingSegmentsUV;
    intersections(idx_plane).probeFacingPixels      = probeFacingPixels;
    intersections(idx_plane).segmentFacingScore     = segmentFacingScore;
    intersections(idx_plane).timestamp              = plane.timestamp;

    % Draw returned 3D segments on top of the femur and image plane when intersections exist.
    if ~isempty(segments3D)
        % Loop over each returned 3D segment because every triangle contributes at most one segment.
        for idx_segment = 1:numel(segments3D)
            % Read and plot the current 3D segment endpoints from the cell array.
            current_segment3D = segments3D{idx_segment};
            plot3(ax1, current_segment3D(:, 1), current_segment3D(:, 2), current_segment3D(:, 3), 'r-', ...
                 'LineWidth', 2, 'Tag', 'plot_mesh_plane_intersection');
        end
    end

    % Create the next tile so this plane gets its own image view.
    ax_tile = nexttile(tile_layout);
    display_image = plane.image.';    % Transpose the stored image for display because packets are stored as [width, height].
    imagesc(ax_tile, display_image);
    axis(ax_tile, 'image');
    colormap(ax_tile, gray);
    hold(ax_tile, 'on');
    xlabel(ax_tile, 'Column');
    ylabel(ax_tile, 'Row');
    title(ax_tile, sprintf('Plane %d | t = %.3f', idx_plane, double(plane.timestamp)));

    % Overlay the rasterized hit pixels so the discrete pixel result can be compared to the red UV lines.
    if ~isempty(pixelList)
        % Read the stored pixel rows because pixelList is returned as [row, col].
        pixel_rows = pixelList(:, 1);
        pixel_cols = pixelList(:, 2);
        % Plot the rasterized pixels as yellow dots so users can see the discrete sampling result.
        plot(ax_tile, pixel_cols, pixel_rows, 'y.', 'MarkerSize', 10);
    end

    % Overlay the clipped UV segments on the current plane image.
    for idx_segment = 1:numel(segmentsUV)
        % Read the current clipped UV segment from the cell array.
        current_segmentUV = segmentsUV{idx_segment};
        % Convert the local u coordinate into MATLAB-style column and row indices.
        cols = current_segmentUV(:, 1) ./ du + 1;
        rows = current_segmentUV(:, 2) ./ dv + 1;
        % Plot the UV segment on top of the plane image so image and geometry can be compared.
        plot(ax_tile, cols, rows, 'r-', 'LineWidth', 1.5);
    end

    % Overlay the probe-facing pixels so the selected mesh surface stands out from the full intersection.
    if ~isempty(probeFacingPixels)
        % Read the stored rows because the helper returns probe-facing pixels as [row, col].
        selected_rows = probeFacingPixels(:, 1);
        selected_cols = probeFacingPixels(:, 2);
        % Plot the selected pixels in green so the probe-facing surface is easy to inspect.
        plot(ax_tile, selected_cols, selected_rows, 'go', 'MarkerSize', 5, 'LineWidth', 1);
    end


end

% Add one shared title so the tiled figure is easy to recognize.
title(tile_layout, 'Mesh-Plane Intersection Overlays');



