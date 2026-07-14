clear; clc; close all;

% Add every project function folder so this script can call the MHA reader.
addpath(genpath('functions'));

%% READ THE SNAPSHOT DATA

filepath_snapshots = 'D:\Documents\BELANDA\SonoSkin\data\dennis_data\2026-07-14-phantomsnapshot\measurement_01';

% Stop early with a clear message when the configured snapshot root is missing.
if ~isfolder(filepath_snapshots)
    error('Snapshot root directory not found: %s', filepath_snapshots);
end

% Read the snapshot root and keep only its immediate child directories.
% These directories represent the anatomical snapshot groups.
directoryEntries = dir(filepath_snapshots);
isSnapshotDirectory = [directoryEntries.isdir] & ...
    ~ismember({directoryEntries.name}, {'.', '..'});
snapshotDirectories = directoryEntries(isSnapshotDirectory);

% Sort directory names so repeated runs create the same struct ordering.
[~, snapshotSortOrder] = sort({snapshotDirectories.name});
snapshotDirectories = snapshotDirectories(snapshotSortOrder);

% Define an empty reader-output array for snapshot groups with no MHA files.
emptySequences = struct('header', {}, 'packets', {});

% Preallocate one result entry per snapshot group to avoid growing the array in a loop.
snapshotTemplate = struct( ...
    'name', '', ...
    'bone', 'U', ...
    'path', '', ...
    'sequences', emptySequences);
snapshotData = repmat(snapshotTemplate, 1, numel(snapshotDirectories));

% Load every snapshot group independently while keeping its identifying metadata.
for snapshotIndex = 1:numel(snapshotDirectories)

    % Preserve the full folder name and build its absolute directory path.
    snapshotName = snapshotDirectories(snapshotIndex).name;
    snapshotPath = fullfile(filepath_snapshots, snapshotName);

    % Classify the bone from the folder name without depending on letter case.
    % Unknown and misspelled bone names intentionally keep the code 'U'.
    snapshotNameLower = lower(snapshotName);
    if contains(snapshotNameLower, 'femur')
        boneCode = 'F';
    elseif contains(snapshotNameLower, 'tibia')
        boneCode = 'T';
    else
        boneCode = 'U';
    end

    % Select only MHA files directly inside this snapshot group, which ignores CSV files.
    mhaFiles = dir(fullfile(snapshotPath, '*.mha'));
    mhaFiles = mhaFiles(~[mhaFiles.isdir]);

    % Sort file names so the sequence order is predictable across runs.
    [~, fileSortOrder] = sort({mhaFiles.name});
    mhaFiles = mhaFiles(fileSortOrder);

    % Start with the required empty shape so an empty directory remains valid.
    snapshotSequences = emptySequences;

    % Keep each complete reader result, including both its header and packets.
    for fileIndex = 1:numel(mhaFiles)
        mhaPath = fullfile(snapshotPath, mhaFiles(fileIndex).name);
        snapshotSequences(fileIndex) = read_sequence_image(mhaPath);
    end

    % Store the snapshot metadata beside all sequence results from that folder.
    snapshotData(snapshotIndex).name = snapshotName;
    snapshotData(snapshotIndex).bone = boneCode;
    snapshotData(snapshotIndex).path = snapshotPath;
    snapshotData(snapshotIndex).sequences = snapshotSequences;
end

%% READ THE ULTRASOUND PROBE CALIBRATION DATA FROM FCAL SOFTWARE

% Build the absolute path to the sample fCal XML file containing
% calibration matrix for ultrasound
filename_fcalconfig = 'PlusDeviceSet_fCal_Epiphan_NDIPolaris_UTNML__20260713_143746.xml';
fullfile_fcalconfig = fullfile(pwd, 'data', filename_fcalconfig);

% Parse all <Transform> entries under <CoordinateDefinitions>.
transformations = read_fcal_transforms(fullfile_fcalconfig);
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

% Get the scaling vector [sx sy sz]
S_image_probecalib = vecnorm(R_image_probe_raw,2,1);

%% DISPLAY THE IMAGE IN 3D SPACE

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

% Leave this empty to use the Reference-to-Tracker transform stored in each packet.
% Set it to a 4-by-4 Reference-to-Tracker matrix when the reference object was absent during acquisition.
T_global_ref_override = [eul2rotm([0 0 -pi/2]), [0 0 0]'; 0 0 0 1];

% Validate a configured override once so an invalid matrix fails before the display loop starts.
if ~isempty(T_global_ref_override)
    validateattributes(T_global_ref_override, {'numeric'}, ...
        {'size', [4, 4], 'finite'}, mfilename, 'T_global_ref_override');
end

% Visit every anatomical snapshot group because each directory stores a separate set of measurements.
for snapshotIndex = 1:numel(snapshotData)

    % Read the sequences from the current directory while keeping the outer loop easy to follow.
    currentSnapshotSequences = snapshotData(snapshotIndex).sequences;

    % Visit every MHA file stored in the current snapshot directory.
    for sequenceIndex = 1:numel(currentSnapshotSequences)

        % Read one complete sequence, including its header and image packets.
        currentSequence = currentSnapshotSequences(sequenceIndex);

        % Loop over the packet array instead of assuming that every snapshot file always has one frame.
        for packetIndex = 1:numel(currentSequence.packets)

            % Remove the previous coordinate frames only after this packet has passed all required tracking checks.
            delete(findobj(ax1, 'Tag', 'plot_axes'));
            delete(findobj(ax1, 'Tag', 'plot_origin_window'));

            % Read the image and tracking measurements that belong to the same acquisition time.
            current_packet = currentSequence.packets(packetIndex);
            % Skip this packet when the probe tracking system did not provide a usable pose.
            if ~current_packet.ProbeToTrackerDeviceTransformStatus
                continue;
            end

            % Read the probe pose from the current packet.
            T_global_probe = current_packet.ProbeToTrackerDeviceTransform;
            % Read the reference pose from the current packet.
            % The default is to use data from the packet, but the explicit 
            % override can be used for exceptional datasets (like when you 
            % forgot to put the reference object during experiment)
            if isempty(T_global_ref_override)
                % Skip the packet when normal acquisition did not provide a usable reference pose.
                if ~current_packet.ReferenceToTrackerDeviceTransformStatus
                    continue;
                end
                % Read the tracked reference pose that belongs to this packet.
                T_global_ref = current_packet.ReferenceToTrackerDeviceTransform;
            else
                % Reuse the predefined reference pose because this dataset was recorded without a reference object.
                T_global_ref = T_global_ref_override;
            end

            % Express the probe pose in the reference frame using the same propagation as the sequence display script.
            T_probe_ref    = inv(T_global_ref) * T_global_probe;

            % Draw the probe coordinate frame to make the probe pose easy to inspect.
            origin    = T_probe_ref(1:3, 4);
            base_axes = T_probe_ref(1:3, 1:3);
            axisname  = 'B_N_PRB';
            display_axis_v2(ax1, origin, base_axes, quiverscale, axisname, ...
                            'Tag', 'plot_axes', 'Mode', 'default');

            % Propagate the image-to-probe calibration so the image is expressed in the reference frame.
            T_image_ref = T_probe_ref * T_image_probecalib;

            % Draw the image coordinate frame to show the calibrated image orientation.
            origin    = T_image_ref(1:3, 4);
            base_axes = T_image_ref(1:3, 1:3);
            axisname  = 'Image';
            display_axis_v2(ax1, origin, base_axes, quiverscale, axisname, ...
                            'Tag', 'plot_axes', 'Mode', 'default');

            % Draw this ultrasound image as a physical plane while keeping earlier snapshot planes visible.
            display_image3D(ax1, current_packet.Image, T_image_ref, ...
                            'SwapXY', true, ...
                            'PixelSpacing', [S_image_probecalib(1) S_image_probecalib(2)], ...
                            'Tag', 'plot_usimage', ...
                            'Colormap', 'gray', ...
                            'FaceAlpha', 0.3);

            % Update the figure during the loop so MATLAB shows progress while loading all snapshots.
            % drawnow;

        end
    end
end


%% READ THE BONE RIGID BODY DATA FROM QUALISYS

