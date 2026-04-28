clear; clc; close all;
% Generate path to functions
addpath(genpath('functions'));

% toggle for recording
is_record = false;

%% PREPARATION

% Get the Sequence Recording file
sequencePath = fullfile(pwd, 'data', 'data_11-03-2026', 'SequenceRecording_2026-03-11_20-51-14.mha');
% sequencePath = fullfile(pwd, 'data', 'data_11-03-2026', 'SequenceRecording_2026-03-11_20-51-53.mha');
% sequencePath = fullfile(pwd, 'data', 'data_11-03-2026', 'SequenceRecording_2026-03-11_20-53-07.mha');
% Parse the sequence file into a MATLAB struct.
sequence = read_sequence_image(sequencePath);

% Build the absolute path to the sample fCal XML file in the same folder.
% str_filename = 'PlusDeviceSet_fCal_Epiphan_NDIPolaris_UTNML__20260212_153704.xml';
% str_filename = 'PlusDeviceSet_fCal_Epiphan_NDIPolaris_UTNML__20260309_152217.xml';
str_filename = 'PlusDeviceSet_fCal_Epiphan_NDIPolaris_UTNML__20260312_120634.xml';
% str_filename = 'PlusDeviceSet_fCal_Epiphan_NDIPolaris_RadboudUMC_20241217_112205.xml';
fcalConfigPath = fullfile(pwd, 'data', str_filename);

% Parse all <Transform> entries under <CoordinateDefinitions>.
transformations = read_fcal_transforms(fcalConfigPath);
% get the transformation of the image in the probe coordinate frame
T_image_probecalib = transformations(1).Matrix;

% The original T_image_probe contains
% Extract the original 3x3 rotation block from Image->Probe transform.
R_image_probe_raw = T_image_probecalib(1:3, 1:3);
% Decompose the raw matrix with SVD to separate rotation part and scale part.
[U_image_probe, S_image_probe_raw, V_image_probe] = svd(R_image_probe_raw);
% Build the closest orthogonal rotation (minimum Frobenius error).
R_image_probe_orth = U_image_probe * V_image_probe';
% If determinant is negative, flip the last axis to enforce a proper right-handed rotation (det = +1).
if det(R_image_probe_orth) < 0
    U_image_probe(:, 3) = -U_image_probe(:, 3);
    R_image_probe_orth = U_image_probe * V_image_probe';
end
% Write the orthogonalized rotation back into the 4x4 rigid transform.
T_image_probecalib(1:3, 1:3) = R_image_probe_orth * S_image_probe_raw;
% T_image_probe(1:3, 1:3) = R_image_probe_orth;
% disp(rad2deg(rotm2eul(R_image_probe_orth)))

% This one was calculated from CAD file
T_probecalib_probemeasure = [0.0   0.0  1.0  2.0;
                             0.0  -1.0  0.0  0.0;
                             1.0   0.0  0.0 -4.0;
                             0.0   0.0  0.0  1.0];

% % testing from youtube video
% T_test =[-0.002 0.079 -0.008 15.398;
%          -0.084 0.004  0.015 49.570;
%           0.016 0.007  0.080 -8.634;
%           0     0      0      1];
% R_test = T_test(1:3, 1:3);
% disp(rad2deg(rotm2eul(R_test)))


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

%% MAIN LOOP

if(is_record)
    % ask user where the recording should be saved before starting
    selected_save_dir = uigetdir(pwd, 'Select folder to save recorded video');

    % if user cancels, disable recording to avoid writing to an unknown place
    if isequal(selected_save_dir, 0)
        disp('Recording canceled: no save folder selected.');
        is_record = false;
    else
        % build full output path inside the chosen folder
        video_output_path = fullfile(selected_save_dir, 'animation.mp4');

        % create video writer with the selected output location
        v = VideoWriter(video_output_path,'MPEG-4');
        v.FrameRate = 30;
        open(v);
    end
end

% Keep only the most recent probe origins so the trajectory stays readable.
origin_window_size = 75;

% Grab the total image
n_packet = sequence.header.DimSize(3);
% Loop over the images
for idx_packet = 1:n_packet

    % Delete necessary object from previous iterations
    delete(findobj('Tag', 'plot_axes'));
    delete(findobj('Tag', 'plot_usimage'));
    delete(findobj('Tag', 'plot_origin_window'));

    % Get the current packet
    current_packet = sequence.packets(idx_packet);
    % Check whether the current packet is invalid or not
    if(~current_packet.ProbeToTrackerDeviceTransformStatus)
        continue;
    end

    % I want to give a bit of context for transparancy of the process here
    % for next particular line:
    T_global_probe = current_packet.ProbeToTrackerDeviceTransform;
    T_global_ref   = current_packet.ReferenceToTrackerDeviceTransform;
    T_probe_ref    = inv(T_global_ref) * T_global_probe;

    % visualzie the coordinate frame of the probe
    origin      = T_probe_ref(1:3, 4);
    base_axes   = T_probe_ref(1:3, 1:3);
    axisname    = 'B_N_PRB';
    display_axis_v2(ax1, origin, base_axes, quiverscale, axisname, 'Tag', 'plot_axes', 'Mode', 'default');
   
    % Draw the recent origin dots with a red fade where newer dots are more vibrant.
    display_origindot(ax1, origin, idx_packet, origin_window_size, 'plot_origin_window');

    % T_probemeasure_ref = T_probe_ref * T_probecalib_probemeasure;
    % origin      = T_probemeasure_ref(1:3, 4);
    % base_axes   = T_probemeasure_ref(1:3, 1:3);
    % axisname    = 'Image';
    % display_axis_v2(ax1, origin, base_axes, quiverscale, axisname, 'Tag', 'plot_axes', 'Mode', 'default');

    % calculate the coordinate frame of the image
    T_image_ref = T_probe_ref * T_probecalib_probemeasure * T_image_probecalib;
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
        'Tag', 'plot_usimage', ...
        'Colormap', 'gray');

    drawnow;

    % break;

    % record if user wants
    if(is_record)
        frame_now = getframe(fig1);
        writeVideo(v, frame_now);
    end

end



if(is_record)
    close(v);
end




