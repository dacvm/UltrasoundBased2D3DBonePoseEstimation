clear; clc; close all;
% Generate path to functions
addpath(genpath('functions'));

% toggle for recording
is_record = false;

%%

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


%% 

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

    % store the sequence
    sequences{index_filename} = sequence;

    fprintf('%s done.\n', filenames{index_filename});
end


%% INITIALIZE FIGURE OBJECTS

% prepare the figure object
fig1 = figure('Name', 'Figure');
ax1  = axes(fig1);
xlabel(ax1,'X');
ylabel(ax1,'Y');
zlabel(ax1,'Z');
grid(ax1, 'on');
axis(ax1, 'equal')
hold(ax1, 'on');
view(ax1, 35, 40);

% set the quiver scale
quiverscale = 20;

%%

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
        
    end
end

%%

% Store the femur ACS mat filename in a dedicated variable so we do not mix it with XML filenames.
acs_filename = 'CT_Femur_editedFlipped_scaled_20260421-174922.mat';
% Build the absolute path to the femur ACS mat file in the bones folder.
acs_path = fullfile(pwd, 'data', 'bones', acs_filename);
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
% Keep acs.f.R' as requested, and use acs.f.origin' so translation is a 3x1 column vector.
T_femurct_originct = [acs.f.R', acs.f.origin'; 0 0 0 1];

%% INTERACTIVE FEMUR STL POSE CONTROL

% Build the fixed STL path from project root exactly as requested.
stl_path = fullfile(pwd, 'data', 'bones', 'CT_Femur_editedFlipped_scaled_distal.stl');
% Read STL mesh into faces and vertices while handling common stlread output variants.
[femur_faces, femur_vertices_ct] = readStlMeshLocal(stl_path);

% Apply the baseline femur transform once so the first draw matches T_femurct_originct.
femur_vertices_world = applyRigidTransformLocal(femur_vertices_ct, T_femurct_originct);
% Draw the femur as a single patch object so we can update only vertices during key presses.
h_femur = patch(ax1, ...
    'Faces', femur_faces, ...
    'Vertices', femur_vertices_world, ...
    'FaceColor', [0.92 0.83 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.55, ...
    'Tag', 'plot_femur_stl');
% Add basic lighting so the 3D shape is easier to read while aligning.
camlight(ax1, 'headlight');
lighting(ax1, 'gouraud');
material(ax1, 'dull');

% Initialize controller state that will live on the figure for every key press callback.
femur_state = struct();
% Keep baseline transform so we can report motion relative to the original T_femurct_originct.
femur_state.T0 = T_femurct_originct;
% Cache inverse once to compute T_delta quickly during interaction.
femur_state.T0_inv = inv(T_femurct_originct);
% Start current transform from the baseline pose.
femur_state.T_current = T_femurct_originct;
% Start relative delta as identity because no keyboard motion happened yet.
femur_state.T_delta = eye(4);
% Keep original CT vertices unchanged so every redraw is stable and repeatable.
femur_state.vertices_ct = femur_vertices_ct;
% Store face list once so we can update mesh data if needed in one place.
femur_state.faces = femur_faces;
% Keep the patch handle so callback can update vertices directly without recreating graphics objects.
femur_state.patch_handle = h_femur;
% Define fine translation step so small adjustments stay precise.
femur_state.step_trans_fine_mm = 1.0;
% Define fine rotation step so small angular adjustments stay precise.
femur_state.step_rot_fine_deg = 1.0;
% Define coarse translation step so large repositioning is faster.
femur_state.step_trans_coarse_mm = 5.0;
% Define coarse rotation step so large reorientation is faster.
femur_state.step_rot_coarse_deg = 5.0;
% Start in fine mode so behavior matches the previous default when script starts.
femur_state.is_coarse_step = false;
% Set active translation step from fine mode at initialization.
femur_state.step_trans_mm = femur_state.step_trans_fine_mm;
% Set active rotation step from fine mode at initialization.
femur_state.step_rot_deg = femur_state.step_rot_fine_deg;
% Accumulate only the user-entered translation increments for space-bar reporting.
femur_state.dxyz_mm = [0, 0, 0];
% Accumulate only the user-entered XYZ rotation increments (degrees) for space-bar reporting.
femur_state.drpy_deg = [0, 0, 0];
% Save state onto figure so the callback can read-modify-write it safely.
setappdata(fig1, 'FemurPoseState', femur_state);

% Register keyboard callback on the figure (this is the event connection for interactive control).
set(fig1, 'WindowKeyPressFcn', @femurKeyPress);
% Print control summary once so user knows which keys are active immediately.
fprintf('\nInteractive femur controls are ready.\n');
fprintf('Translation (+/-): W/S=X, A/D=Y, Q/E=Z  [mm]\n');
fprintf('Rotation (+/-):    I/K=Rx, J/L=Ry, U/O=Rz [deg, world-axis incremental]\n');
fprintf('Press Z to toggle step size: fine (1 mm, 1 deg) <-> coarse (5 mm, 5 deg).\n');
fprintf('Press SPACE to print accumulated delta and current transform.\n\n');

%% INTERACTIVE FUNCTIONS

% ---- Local callback and helper function declarations start here ----
% The function below is the keyboard callback ("slot") that handles all pose control keys.
function femurKeyPress(src, event)
    % Read current controller state from figure app data at the start of each key event.
    state = getappdata(src, 'FemurPoseState');
    % Exit early if state is missing so callback fails safely instead of throwing confusing errors.
    if isempty(state) || ~isstruct(state)
        return;
    end

    % Track whether this key should trigger a mesh redraw to avoid unnecessary graphics updates.
    needs_redraw = false;
    % Initialize per-key translation increment in world frame [dx dy dz].
    delta_xyz = [0, 0, 0];
    % Initialize per-key world-axis rotation matrix as identity (no rotation by default).
    R_step = eye(3);

    % Route each key to its motion command using lower-case so uppercase keyboard state still works.
    switch lower(event.Key)
        % +X translation with W.
        case 'w'
            delta_xyz = [ state.step_trans_mm, 0, 0];
            state.dxyz_mm = state.dxyz_mm + delta_xyz;
            needs_redraw = true;
        % -X translation with S.
        case 's'
            delta_xyz = [-state.step_trans_mm, 0, 0];
            state.dxyz_mm = state.dxyz_mm + delta_xyz;
            needs_redraw = true;
        % +Y translation with A.
        case 'a'
            delta_xyz = [0,  state.step_trans_mm, 0];
            state.dxyz_mm = state.dxyz_mm + delta_xyz;
            needs_redraw = true;
        % -Y translation with D.
        case 'd'
            delta_xyz = [0, -state.step_trans_mm, 0];
            state.dxyz_mm = state.dxyz_mm + delta_xyz;
            needs_redraw = true;
        % +Z translation with Q.
        case 'q'
            delta_xyz = [0, 0,  state.step_trans_mm];
            state.dxyz_mm = state.dxyz_mm + delta_xyz;
            needs_redraw = true;
        % -Z translation with E.
        case 'e'
            delta_xyz = [0, 0, -state.step_trans_mm];
            state.dxyz_mm = state.dxyz_mm + delta_xyz;
            needs_redraw = true;

        % +Rx rotation with I (world X axis).
        case 'i'
            R_step = rotXDegLocal(state.step_rot_deg);
            state.drpy_deg(1) = state.drpy_deg(1) + state.step_rot_deg;
            needs_redraw = true;
        % -Rx rotation with K (world X axis).
        case 'k'
            R_step = rotXDegLocal(-state.step_rot_deg);
            state.drpy_deg(1) = state.drpy_deg(1) - state.step_rot_deg;
            needs_redraw = true;
        % +Ry rotation with J (world Y axis).
        case 'j'
            R_step = rotYDegLocal(state.step_rot_deg);
            state.drpy_deg(2) = state.drpy_deg(2) + state.step_rot_deg;
            needs_redraw = true;
        % -Ry rotation with L (world Y axis).
        case 'l'
            R_step = rotYDegLocal(-state.step_rot_deg);
            state.drpy_deg(2) = state.drpy_deg(2) - state.step_rot_deg;
            needs_redraw = true;
        % +Rz rotation with U (world Z axis).
        case 'u'
            R_step = rotZDegLocal(state.step_rot_deg);
            state.drpy_deg(3) = state.drpy_deg(3) + state.step_rot_deg;
            needs_redraw = true;
        % -Rz rotation with O (world Z axis).
        case 'o'
            R_step = rotZDegLocal(-state.step_rot_deg);
            state.drpy_deg(3) = state.drpy_deg(3) - state.step_rot_deg;
            needs_redraw = true;

        % Z toggles between fine and coarse steps to reduce repeated key presses for large moves.
        case 'z'
            % Flip mode flag so each Z press alternates between the two step modes.
            state.is_coarse_step = ~state.is_coarse_step;
            % Use coarse values when coarse mode is active.
            if state.is_coarse_step
                state.step_trans_mm = state.step_trans_coarse_mm;
                state.step_rot_deg = state.step_rot_coarse_deg;
                fprintf('Step mode: COARSE (%.1f mm, %.1f deg)\n', state.step_trans_mm, state.step_rot_deg);
            else
                % Use fine values when coarse mode is not active.
                state.step_trans_mm = state.step_trans_fine_mm;
                state.step_rot_deg = state.step_rot_fine_deg;
                fprintf('Step mode: FINE (%.1f mm, %.1f deg)\n', state.step_trans_mm, state.step_rot_deg);
            end
            % Save the new mode immediately because Z changes state even without mesh redraw.
            setappdata(src, 'FemurPoseState', state);
            return;

        % Space prints accumulated numbers and transform matrices without changing pose.
        case 'space'
            printFemurPoseStatusLocal(state);
            return;

        % Ignore every other key so existing figure interactions remain unaffected.
        otherwise
            return;
    end

    % Update current pose only when a mapped key was pressed.
    if needs_redraw
        % Extract current rotation and position once for clear readable updates.
        R_current = state.T_current(1:3, 1:3);
        p_current = state.T_current(1:3, 4);

        % Apply translation in world frame so W/A/Q always follow global axes.
        p_current = p_current + delta_xyz(:);
        % Apply rotation in world frame incrementally and in keypress order.
        R_current = R_step * R_current;

        % Rebuild current transform from updated rotation and translation.
        state.T_current = [R_current, p_current; 0 0 0 1];
        % Recompute relative delta against original T0 so reporting stays relative as requested.
        state.T_delta = state.T_current * state.T0_inv;

        % Transform original CT mesh vertices with current pose for stable redraw behavior.
        vertices_world = applyRigidTransformLocal(state.vertices_ct, state.T_current);
        % Update only vertices on the existing patch to avoid creating new graphics objects.
        set(state.patch_handle, 'Vertices', vertices_world);
        % Trigger immediate visual refresh so every key press feels responsive.
        drawnow;

        % Write modified state back to app data so next key press starts from latest pose.
        setappdata(src, 'FemurPoseState', state);
    end
end

% Build X-axis rotation matrix from degrees so key mapping stays human-friendly.
function R = rotXDegLocal(theta_deg)
    % Convert degree input to radians for trig functions.
    t = deg2rad(theta_deg);
    % Return standard right-handed rotation matrix around X.
    R = [1,      0,       0; ...
         0, cos(t), -sin(t); ...
         0, sin(t),  cos(t)];
end

% Build Y-axis rotation matrix from degrees so key mapping stays human-friendly.
function R = rotYDegLocal(theta_deg)
    % Convert degree input to radians for trig functions.
    t = deg2rad(theta_deg);
    % Return standard right-handed rotation matrix around Y.
    R = [ cos(t), 0, sin(t); ...
                0, 1,      0; ...
         -sin(t), 0, cos(t)];
end

% Build Z-axis rotation matrix from degrees so key mapping stays human-friendly.
function R = rotZDegLocal(theta_deg)
    % Convert degree input to radians for trig functions.
    t = deg2rad(theta_deg);
    % Return standard right-handed rotation matrix around Z.
    R = [cos(t), -sin(t), 0; ...
         sin(t),  cos(t), 0; ...
              0,       0, 1];
end

% Apply a 4x4 rigid transform to N-by-3 points using homogeneous coordinates.
function vertices_out = applyRigidTransformLocal(vertices_in, T)
    % Count points once so homogeneous augmentation is dimensionally correct.
    n_vertices = size(vertices_in, 1);
    % Append a column of ones so matrix multiplication handles translation.
    vertices_h = [vertices_in, ones(n_vertices, 1)];
    % Apply transform and transpose back to N-by-3 layout expected by patch.
    vertices_h_t = (T * vertices_h.').';
    % Drop homogeneous column and keep transformed XYZ only.
    vertices_out = vertices_h_t(:, 1:3);
end

% Print accumulated motion and rigid transforms in a readable block for the user.
function printFemurPoseStatusLocal(state)
    % Start with a blank line to separate this report from previous console output.
    fprintf('\n');
    % Derive a readable mode label so user can verify whether fine or coarse mode is active.
    if state.is_coarse_step
        step_mode_label = 'COARSE';
    else
        step_mode_label = 'FINE';
    end
    % Print current step mode so next key presses are predictable.
    fprintf('Current step mode: %s (%.1f mm, %.1f deg)\n', ...
        step_mode_label, state.step_trans_mm, state.step_rot_deg);
    % Print accumulated translation entered by keyboard relative to start pose.
    fprintf('Accumulated translation [mm]: [%.3f %.3f %.3f]\n', ...
        state.dxyz_mm(1), state.dxyz_mm(2), state.dxyz_mm(3));
    % Print accumulated Euler-like key totals (Rx Ry Rz) in degrees.
    fprintf('Accumulated rotation [deg] (Rx Ry Rz): [%.3f %.3f %.3f]\n', ...
        state.drpy_deg(1), state.drpy_deg(2), state.drpy_deg(3));

    % Print relative 4x4 delta matrix (motion relative to original T_femurct_originct).
    fprintf('T_delta (relative to original T_femurct_originct):\n');
    disp(state.T_delta);
    % Print absolute 4x4 current pose matrix for direct use in downstream code.
    fprintf('T_current (current femur pose):\n');
    disp(state.T_current);
    % Save the current manual adjustments to a timestamped mat file every time SPACE is pressed.
    save_path = saveManualTransformationAdjustmentsLocal(state);
    % Print the save location so user can quickly find the exported mat file.
    fprintf('Saved manual adjustment file: %s\n', save_path);
end

% Save manual adjustment transforms to the requested output folder and variable names.
function save_path = saveManualTransformationAdjustmentsLocal(state)
    % Copy relative transform into the exact variable name requested for MAT export.
    T_femurlabmanual_bonect = state.T_delta; 
    % Copy current absolute transform into the exact variable name requested for MAT export.
    T_femurlabmanual_originct = state.T_current; 

    % Build output folder path under project output so exported files stay organized.
    output_dir = fullfile(pwd, 'output', 'manual_transformation_adjustments');
    % Create output folder only if it does not exist yet.
    if ~exist(output_dir, 'dir')
        mkdir(output_dir);
    end

    % Build timestamp in YYYYMMDD-hhmmss style using current local date-time.
    timestamp_now = string(datetime('now', 'Format', 'yyyyMMdd-HHmmss'));
    % Build final filename using the required prefix and timestamp.
    output_filename = "manual_transformation_adjustments_" + timestamp_now + ".mat";
    % Join folder and filename into absolute save path.
    save_path = fullfile(output_dir, char(output_filename));

    % Save only the two requested transform variables into the mat file.
    save(save_path, 'T_femurlabmanual_bonect', 'T_femurlabmanual_originct');
end

% Read STL mesh into faces/vertices while supporting common MATLAB stlread return styles.
function [faces, vertices] = readStlMeshLocal(stl_file_path)
    % Try modern single-output stlread first (often returns triangulation in newer MATLAB).
    mesh_data = stlread(stl_file_path);
    % Parse triangulation output directly when available.
    if isa(mesh_data, 'triangulation')
        faces = mesh_data.ConnectivityList;
        vertices = mesh_data.Points;
        return;
    end
    % Parse struct output used by some stlread implementations.
    if isstruct(mesh_data)
        if isfield(mesh_data, 'ConnectivityList') && isfield(mesh_data, 'Points')
            faces = mesh_data.ConnectivityList;
            vertices = mesh_data.Points;
            return;
        end
        if isfield(mesh_data, 'Faces') && isfield(mesh_data, 'Vertices')
            faces = mesh_data.Faces;
            vertices = mesh_data.Vertices;
            return;
        end
        if isfield(mesh_data, 'faces') && isfield(mesh_data, 'vertices')
            faces = mesh_data.faces;
            vertices = mesh_data.vertices;
            return;
        end
    end
    % Fall back to two-output call style used by older/file-exchange stlread versions.
    [faces, vertices] = stlread(stl_file_path);
end
