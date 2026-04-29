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
             'SequenceRecording_2026-04-13_17-51-44.mha', ...
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
                            'FaceAlpha', 0.3);
    
        drawnow;
        
    end

end
