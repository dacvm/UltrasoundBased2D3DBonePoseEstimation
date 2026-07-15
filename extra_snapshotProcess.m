clear; clc; close all;

% Add every project function folder so this script can call the MHA reader.
addpath(genpath('functions'));

%% READ THE SNAPSHOT DATA

fprintf('Reading the snapshot data...\n');

% Define the filepath to the snapshot
filepath_snapshots = 'D:\Documents\BELANDA\SonoSkin\data\dennis_data\2026-07-15_phantomflexion\measurement_01';

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

% Define the matching empty table for snapshot groups with no CSV files.
emptyRigidBodies = table();

% Preallocate one result entry per snapshot group to avoid growing the array in a loop.
snapshotTemplate = struct( ...
    'name', '', ...
    'bone', 'U', ...
    'path', '', ...
    'sequences', emptySequences, ...
    'rigidbodies', emptyRigidBodies);
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

    % Select and sort the CSV files separately because their names use a
    % different prefix from the MHA files. Both sorted lists remain in the
    % chronological acquisition order used to couple each snapshot pair.
    csvFiles = dir(fullfile(snapshotPath, '*.csv'));
    csvFiles = csvFiles(~[csvFiles.isdir]);
    [~, csvSortOrder] = sort({csvFiles.name});
    csvFiles = csvFiles(csvSortOrder);

    % Stop before reading when a snapshot is missing one half of a coupled
    % MHA/CSV pair. This prevents later rows from being paired incorrectly.
    if numel(mhaFiles) ~= numel(csvFiles)
        error(['Snapshot file count mismatch in "%s": found %d MHA ' ...
            'file(s) and %d CSV file(s).'], snapshotPath, ...
            numel(mhaFiles), numel(csvFiles));
    end

    % Start with the required empty shape so an empty directory remains valid.
    snapshotSequences = emptySequences;

    % Preallocate one cell per CSV so the loop does not repeatedly grow a
    % table while reading the individual one-row snapshot results.
    snapshotRigidBodyTables = cell(1, numel(csvFiles));

    % Read both members of each coupled snapshot in the existing file loop.
    for fileIndex = 1:numel(mhaFiles)
        mhaPath = fullfile(snapshotPath, mhaFiles(fileIndex).name);
        snapshotSequences(fileIndex) = read_sequence_image(mhaPath);

        % Read the rigid bodies acquired with the MHA snapshot at this index.
        csvPath = fullfile(snapshotPath, csvFiles(fileIndex).name);
        currentRigidBodies = readCSV_qualisysRigidBodySnapshot(csvPath);

        % A snapshot CSV must contribute exactly one row to the combined
        % table. Rejecting other sizes keeps its row aligned with one MHA file.
        if height(currentRigidBodies) ~= 1
            error('Expected one rigid-body row in "%s", but found %d.', ...
                csvPath, height(currentRigidBodies));
        end
        snapshotRigidBodyTables{fileIndex} = currentRigidBodies;
    end

    % Join all one-row tables only once after reading. Their row order now
    % matches the order of snapshotSequences in this directory.
    if isempty(snapshotRigidBodyTables)
        snapshotRigidBodies = emptyRigidBodies;
    else
        snapshotRigidBodies = vertcat(snapshotRigidBodyTables{:});
    end

    % Store the metadata, images, and combined rigid-body table together.
    snapshotData(snapshotIndex).name = snapshotName;
    snapshotData(snapshotIndex).bone = boneCode;
    snapshotData(snapshotIndex).path = snapshotPath;
    snapshotData(snapshotIndex).sequences = snapshotSequences;
    snapshotData(snapshotIndex).rigidbodies = snapshotRigidBodies;
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

fprintf('Displaying the snapshot data...\n');

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
T_global_ref_override = [];

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


%% READ THE POST-PROCESS CT-SCAN DATA (BONES AND PINS)

fprintf('Reading the CT bones and selected bone pins...\n');

filepath_bonectpostprocess = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\ctknee_postprocessing\outputs\kneephantom';
filename_bonectpostprocess = 'kneephantom_bones_and_bonepins.mat';
fullfile_bonectpostprocess = fullfile(filepath_bonectpostprocess, filename_bonectpostprocess);

% Stop with a direct message when the configured coordinate-system file is missing.
if ~isfile(fullfile_bonectpostprocess)
    error('Knee CT post-processed MAT file not found: %s', filepath_ercmat);
end

% Pseudo-declare the expected coordinate-system struct before loading it, so
% readers can see that this script expects a struct named acs from the MAT file.
% This empty value is intentionally replaced by the checked MAT-file value below.
bonepins = struct(); 
bones    = struct();

% Load only the expected variable into a temporary struct to avoid silently
% adding unrelated MAT-file variables to the script workspace.
loaded_ctmat = load(fullfile_bonectpostprocess, 'bonepins', 'bones');

% Verify that the MAT file contains the promised variable.
if ~isfield(loaded_ctmat, 'bonepins')
    error('MAT file does not contain the expected ''bonepins'' struct: %s', filepath_ercmat);
end
if ~isfield(loaded_ctmat, 'bones')
    error('MAT file does not contain the expected ''bones'' struct: %s', filepath_ercmat);
end

% Replace the pseudo-declaration with the loaded femur and tibia coordinate systems.
bonepins = loaded_ctmat.bonepins;
bones    = loaded_ctmat.bones;

%% DISPLAY THE BONES AND PINS

fprintf('Displaying the CT bones and selected bone pins...\n');

% Choose one pin place for each bone code. Change only these values when a
% different redundant pin should drive the processing and display.
pinSelection = struct( ...
    'F', 'PRO', ...
    'T', 'DIS');

% Group each bone with all pins that share its bone code. The helper also
% validates that every requested place identifies exactly one pin.
boneUnits = coupleBonesAndPins(bones, bonepins, pinSelection);

% Visit the coupled units instead of assuming that bones and pins have the
% same array length or ordering.
for boneIndex = 1:numel(boneUnits)

    % Use short names so every display command clearly reads from the same
    % bone and from the pin selected for that bone.
    currentUnit = boneUnits(boneIndex);
    currentBone = currentUnit.boneData;
    currentPin  = currentUnit.pins(currentUnit.selectedPinIndex);

    % Draw the CT bone surface first. Transparency keeps the selected pin
    % markers and the ultrasound planes visible through the mesh.
    trisurf(currentBone.mesh, ...
        'Parent', ax1, ...
        'FaceColor', [0.92, 0.83, 0.74], ...
        'EdgeColor', 'none', ...
        'FaceAlpha', 0.40, ...
        'Tag', 'plot_ct_bone_meshes');

    % Draw the anatomical coordinate system stored with the current bone.
    boneOrigin   = currentBone.T_bone_CT(1:3, 4);
    boneBaseAxes = currentBone.T_bone_CT(1:3, 1:3);
    boneAxisName = sprintf('%s Bone ACS', char(currentUnit.name));
    display_axis_v2(ax1, boneOrigin, boneBaseAxes, quiverscale, boneAxisName, ...
        'Tag', 'plot_ct_bone_acs_axes', 'Mode', 'default');

    % The marker centroids are stored as columns of a 3-by-N matrix. Only
    % markers belonging to the pin selected above are displayed.
    scatter3(ax1, ...
        currentPin.marker_centroids(1, :), ...
        currentPin.marker_centroids(2, :), ...
        currentPin.marker_centroids(3, :), ...
        50, ...
        'filled', ...
        'MarkerFaceColor', [1.00, 0.85, 0.15], ...
        'MarkerEdgeColor', [0.20, 0.20, 0.20], ...
        'Tag', 'plot_ct_pin_markers');

    % Draw the selected pin frame directly from its authoritative CT
    % transform. Include the place in the label to show which pin was used.
    pinOrigin = currentPin.T_pin_CT(1:3, 4);
    pinBaseAxes = currentPin.T_pin_CT(1:3, 1:3);
    pinAxisName = sprintf('%s %s Pin', ...
        char(currentUnit.name), char(currentUnit.selectedPinPlace));
    display_axis_v2(ax1, pinOrigin, pinBaseAxes, quiverscale, pinAxisName, ...
        'Tag', 'plot_ct_pin_axes', 'Mode', 'default');
end

% Render the completed scene immediately after both coupled units are drawn.
drawnow;
