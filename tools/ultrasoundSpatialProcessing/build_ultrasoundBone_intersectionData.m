clear; clc; close all;

%% LOAD AND VALIDATE THE CONFIGURATION
% Find this script instead of relying on MATLAB's current folder. This makes
% the config-driven workflow behave the same when it is launched elsewhere.
scriptFullPath = mfilename('fullpath');
if isempty(scriptFullPath)
    error('build_ultrasoundBone_intersectionData:ScriptPathUnavailable', ...
          'Run build_ultrasoundBone_intersectionData.m as a complete script so its configuration file can be located.');
end
scriptDirectory = fileparts(scriptFullPath);

% This script lives in tools/ultrasoundSpatialProcessing, two folders below the project root.
projectRoot = fileparts(fileparts(scriptDirectory));

% Add the project helpers through an absolute path from the project root.
functionsDirectory = fullfile(projectRoot, 'functions');
if ~isfolder(functionsDirectory)
    error('build_ultrasoundBone_intersectionData:FunctionsDirectoryNotFound', ...
          'Required functions directory not found: %s', functionsDirectory);
end
addpath(genpath(functionsDirectory));

% Add this workflow's extracted helpers so the script remains runnable from
% any current working directory without embedding its utility functions.
helperDirectory = fullfile(scriptDirectory, 'helpers');
if ~isfolder(helperDirectory)
    error('build_ultrasoundBone_intersectionData:HelperDirectoryNotFound', ...
          'Required helper directory not found: %s', helperDirectory);
end
addpath(helperDirectory);

% Keep this tool's settings beside the workflow so its configuration does
% not get mixed with configuration files owned by other project tools.
configurationPath = fullfile(scriptDirectory, 'configs', 'extra_snapshotProcess_config.json');
configuration     = readSnapshotProcessConfiguration(configurationPath);

% Use the tool-local outputs folder as the first save location shown by the
% review browser, independent of MATLAB's current working directory.
defaultOutputDirectory = fullfile(scriptDirectory, 'outputs');
if ~isfolder(defaultOutputDirectory)
    % Recreate the standard output folder when a fresh checkout does not yet
    % contain it because empty directories are not retained by source control.
    [outputDirectoryCreated, outputDirectoryMessage] = mkdir(defaultOutputDirectory);
    if ~outputDirectoryCreated
        error('build_ultrasoundBone_intersectionData:OutputDirectoryCreationFailed', ...
              'Could not create the default output directory "%s". Reason: %s', ...
              defaultOutputDirectory, outputDirectoryMessage);
    end
end

% Use short workflow variable names below so the copied processing sections
% remain easy to compare with the original quick-check script.
filepath_snapshots          = configuration.snapshotDirectory;
fullfile_fcalconfig         = configuration.fcalConfigFile;
fullfile_bonectpostprocess  = configuration.ctPostProcessedMatFile;
pinSelection                = configuration.pinSelection;
rigidBodyNamesToAverage     = configuration.rigidBodyNamesToAverage;
displayMode                 = configuration.displayMode;

%% READ THE SNAPSHOT DATA
% Load each ultrasound snapshot group together with its tracking data.
% Summary:
% - Find and sort the snapshot folders, then identify each folder as femur, tibia, or unknown.
% - Pair the ultrasound MHA files with their tracking CSV files and check that the pairs are complete.
% - Read the paired files and combine the tracking rows for each snapshot group.
% - Store the images, tracking data, folder information, and bone labels in snapshotData.

fprintf('Reading the snapshot data...\n');

% The validated snapshot root was loaded from snapshotDirectory in JSON.

% Stop early with a clear message when the configured snapshot root is missing.
if ~isfolder(filepath_snapshots)
    error('Snapshot root directory not found: %s', filepath_snapshots);
end

% Read the snapshot root and keep only its immediate child directories.
% These directories represent the anatomical snapshot groups.
directoryEntries    = dir(filepath_snapshots);
isSnapshotDirectory = [directoryEntries.isdir] & ~ismember({directoryEntries.name}, {'.', '..'});
snapshotDirectories = directoryEntries(isSnapshotDirectory);

% Sort directory names so repeated runs create the same struct ordering.
[~, snapshotSortOrder] = sort({snapshotDirectories.name});
snapshotDirectories    = snapshotDirectories(snapshotSortOrder);

% Define an empty reader-output array for snapshot groups with no MHA files.
emptySequences   = struct('header', {}, 'packets', {});
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
    mhaFiles           = mhaFiles(fileSortOrder);

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
        error('Snapshot file count mismatch in "%s": found %d MHA file(s) and %d CSV file(s).', ...
            snapshotPath, numel(mhaFiles), numel(csvFiles));
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
            error('Expected one rigid-body row in "%s", but found %d.', csvPath, height(currentRigidBodies));
        end

        % Every configured rigid body is needed by the later averaging loop.
        % Check each CSV here so the error identifies the exact bad snapshot.
        missingRigidBodyNames = setdiff(rigidBodyNamesToAverage, currentRigidBodies.Properties.VariableNames, 'stable');
        if ~isempty(missingRigidBodyNames)
            error('build_ultrasoundBone_intersectionData:MissingCsvRigidBody', ...
                  'CSV file "%s" does not contain configured rigid body "%s".', ...
                  csvPath, missingRigidBodyNames{1});
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
    snapshotData(snapshotIndex).name        = snapshotName;
    snapshotData(snapshotIndex).bone        = boneCode;
    snapshotData(snapshotIndex).path        = snapshotPath;
    snapshotData(snapshotIndex).sequences   = snapshotSequences;
    snapshotData(snapshotIndex).rigidbodies = snapshotRigidBodies;
end

%% READ THE ULTRASOUND PROBE CALIBRATION DATA FROM FCAL SOFTWARE
% Obtain the ultrasound image-to-probe calibration and image pixel scale.
% Summary:
% - Read the fCal XML file and obtain the transform from ultrasound image coordinates to probe coordinates.
% - Correct the rotation part so it can be used as a proper rigid transformation.
% - Keep the calibration scale for converting image pixels into physical image-plane dimensions.

% The validated calibration path was loaded from fcalConfigFile in JSON.

% Parse all <Transform> entries under <CoordinateDefinitions>.
transformations = read_fcal_transforms(fullfile_fcalconfig);

% Select the calibration by frame name instead of assuming it is always the
% first XML transform. Exactly one match keeps the frame mapping unambiguous.
imageToProbeTransformIndex = find(strcmp( ...
    {transformations.Name}, 'ImageToProbe'));
if numel(imageToProbeTransformIndex) ~= 1
    error('build_ultrasoundBone_intersectionData:InvalidFcalImageToProbeTransform', ...
          'Expected exactly one ImageToProbe transform in "%s", but found %d.', ...
          fullfile_fcalconfig, numel(imageToProbeTransformIndex));
end
T_image_probecalib = transformations(imageToProbeTransformIndex).Matrix;

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
% Display tracked ultrasound images in a common reference coordinate system.
% Summary:
% - Set up the 3D scene and prepare storage for the valid ultrasound image planes.
% - Process the tracked packets, skip packets with unusable poses, and transform each image into the reference frame.
% - Display the probe frames and ultrasound images in 3D using the calibration data.
% - Cache each valid plane's geometry, image, timestamp, and source information for the intersection step.

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
T_ref_global_override = [];

% Validate a configured override once so an invalid matrix fails before the display loop starts.
if ~isempty(T_ref_global_override)
    validateattributes(T_ref_global_override, {'numeric'}, ...
        {'size', [4, 4], 'finite'}, mfilename, 'T_global_ref_override');
end

% Prepare the record stored for each valid image plane. The geometry fields
% follow meshPlaneIntersectionPixels, while the metadata keeps each result
% linked to its source packet after a browser table is sorted.
snapshotPlaneTemplate = struct( ...
    'T_image_ref', [], ...      % 4x4 rigid transform from the image frame to the reference frame.
    'p0', [], ...               % 3D position of the image plane's top-left corner.
    'ex', [], ...               % 3D direction of increasing image columns.
    'ey', [], ...               % 3D direction of increasing image rows.
    'n', [], ...                % 3D normal direction of the image plane.
    'W', 0, ...                 % Physical width of the image plane.
    'H', 0, ...                 % Physical height of the image plane.
    'nRows', 0, ...             % Number of rows in the ultrasound image.
    'nCols', 0, ...             % Number of columns in the ultrasound image.
    'image', [], ...            % Ultrasound image pixels for this plane.
    'timestamp', 0, ...         % Acquisition time of the ultrasound image.
    'bone', 'U', ...            % Bone label associated with this snapshot.
    'snapshotName', '', ...     % Name of the source snapshot group.
    'snapshotIndex', 0, ...     % Index of the source snapshot group.
    'sequenceIndex', 0, ...     % Index of the source sequence within the snapshot.
    'packetIndex', 0);          % Index of the source packet within the sequence.

% Give every source directory its own plane array. Keeping the same group
% metadata beside data makes it clear which bone and sensor location produced
% each set, including when all packets in a directory have invalid tracking.
emptySnapshotPlaneData = repmat(snapshotPlaneTemplate, 1, 0);
snapshotPlaneGroupTemplate = struct( ...
    'name', '', ...
    'bone', 'U', ...
    'path', '', ...
    'data', emptySnapshotPlaneData);
snapshotPlanes = repmat( ...
    snapshotPlaneGroupTemplate, 1, numel(snapshotData));

% Visit every anatomical snapshot group because each directory stores a separate set of measurements.
for snapshotIndex = 1:numel(snapshotData)

    % Copy source-directory metadata before processing so an empty or fully
    % rejected group is still represented in the grouped result.
    currentSnapshotData = snapshotData(snapshotIndex);
    snapshotPlanes(snapshotIndex).name = currentSnapshotData.name;
    snapshotPlanes(snapshotIndex).bone = currentSnapshotData.bone;
    snapshotPlanes(snapshotIndex).path = currentSnapshotData.path;

    % Count this directory's packets so only its local plane array is
    % preallocated. Invalid packets are trimmed from this array below.
    currentSnapshotSequences = currentSnapshotData.sequences;
    maximumGroupPlaneCount   = 0;
    for sequenceIndex = 1:numel(currentSnapshotSequences)
        maximumGroupPlaneCount = maximumGroupPlaneCount + numel(currentSnapshotSequences(sequenceIndex).packets);
    end
    currentGroupPlanes     = repmat(snapshotPlaneTemplate, 1, maximumGroupPlaneCount);
    currentGroupPlaneCount = 0;

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
            T_probe_global = current_packet.ProbeToTrackerDeviceTransform;
            % Read the reference pose from the current packet.
            % The default is to use data from the packet, but the explicit 
            % override can be used for exceptional datasets (like when you 
            % forgot to put the reference object during experiment)
            if isempty(T_ref_global_override)
                % Skip the packet when normal acquisition did not provide a usable reference pose.
                if ~current_packet.ReferenceToTrackerDeviceTransformStatus
                    continue;
                end
                % Read the tracked reference pose that belongs to this packet.
                T_ref_global = current_packet.ReferenceToTrackerDeviceTransform;
            else
                % Reuse the predefined reference pose because this dataset was recorded without a reference object.
                T_ref_global = T_ref_global_override;
            end

            % Express the probe pose in the reference frame using the same propagation as the sequence display script.
            % Left division is the numerically safer equivalent of inv(T_ref_global) * T_pin_global from the frame rule.
            T_probe_ref    = T_ref_global \ T_probe_global;

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

            % Store the valid packet as a finite image plane so the later
            % intersection section does not need to repeat pose propagation.
            currentGroupPlaneCount = currentGroupPlaneCount + 1;
            currentGroupPlanes(currentGroupPlaneCount).T_image_ref = T_image_ref;
            currentGroupPlanes(currentGroupPlaneCount).p0 = T_image_ref(1:3, 4);
            currentGroupPlanes(currentGroupPlaneCount).ex = T_image_ref(1:3, 1);
            currentGroupPlanes(currentGroupPlaneCount).ey = T_image_ref(1:3, 2);
            currentGroupPlanes(currentGroupPlaneCount).n  = T_image_ref(1:3, 3);

            % Packet images use [width, height] storage, so width follows
            % the first dimension and rows follow the second dimension.
            currentGroupPlanes(currentGroupPlaneCount).W         = (size(current_packet.Image, 1) - 1) * S_image_probecalib(1);
            currentGroupPlanes(currentGroupPlaneCount).H         = (size(current_packet.Image, 2) - 1) * S_image_probecalib(2);
            currentGroupPlanes(currentGroupPlaneCount).nRows     = size(current_packet.Image, 2);
            currentGroupPlanes(currentGroupPlaneCount).nCols     = size(current_packet.Image, 1);
            currentGroupPlanes(currentGroupPlaneCount).image     = current_packet.Image;
            currentGroupPlanes(currentGroupPlaneCount).timestamp = current_packet.Timestamp;

            % Preserve source identifiers because a sortable table cannot
            % rely on its visible row number to identify the original data.
            currentGroupPlanes(currentGroupPlaneCount).bone             = currentSnapshotData.bone;
            currentGroupPlanes(currentGroupPlaneCount).snapshotName     = currentSnapshotData.name;
            currentGroupPlanes(currentGroupPlaneCount).snapshotIndex    = snapshotIndex;
            currentGroupPlanes(currentGroupPlaneCount).sequenceIndex    = sequenceIndex;
            currentGroupPlanes(currentGroupPlaneCount).packetIndex      = packetIndex;

            % Update the figure during the loop so MATLAB shows progress while loading all snapshots.
            % drawnow;

        end
    end

    % Remove unused preallocation only inside this source directory. The outer
    % group remains present even when no packet passed the tracking checks.
    snapshotPlanes(snapshotIndex).data = ...
        currentGroupPlanes(1:currentGroupPlaneCount);
end


%% READ THE POST-PROCESS CT-SCAN DATA (BONES AND PINS)
% Load the post-processed CT meshes and the selected bone-pin data.
% Summary:
% - Locate the MAT file produced by the CT post-processing workflow and check that it exists.
% - Load and validate the expected bones and bonepins data.
% - Make the CT meshes, anatomical coordinate systems, and pin information available for registration.

fprintf('Reading the CT bones and selected bone pins...\n');

% The validated CT MAT path was loaded from ctPostProcessedMatFile in JSON.

% Stop with a direct message when the configured coordinate-system file is missing.
if ~isfile(fullfile_bonectpostprocess)
    error('Knee CT post-processed MAT file not found: %s', fullfile_bonectpostprocess);
end

% Pseudo-declare the expected CT structs before loading them so readers can
% see the two named variables required from the MAT file.
% These empty values are replaced by the checked MAT-file values below.
bonepins = struct(); % This placeholder documents the expected MAT variable.
bones    = struct(); % This placeholder documents the expected MAT variable.

% Load only the expected variable into a temporary struct to avoid silently
% adding unrelated MAT-file variables to the script workspace.
loaded_ctmat = load(fullfile_bonectpostprocess, 'bonepins', 'bones');

% Verify that the MAT file contains the promised variable.
if ~isfield(loaded_ctmat, 'bonepins')
    error('MAT file does not contain the expected ''bonepins'' struct: %s', fullfile_bonectpostprocess);
end
if ~isfield(loaded_ctmat, 'bones')
    error('MAT file does not contain the expected ''bones'' struct: %s', fullfile_bonectpostprocess);
end

% Replace the pseudo-declaration with the loaded femur and tibia coordinate systems.
bonepins = loaded_ctmat.bonepins;
bones    = loaded_ctmat.bones;

%% GATHERING ALL THE TRANFORMATION TO BE IN ONE COORDINATE SYSTEM (REF) AND DISPLAYING THE BONES AND PINS
% Put motion-capture data, CT anatomy, and pin markers into the shared reference frame.
% Summary:
% - Average the reference and selected bone-pin tracking poses to obtain stable transforms.
% - Use the tracked pin correspondences to calculate how the CT data maps into the reference frame.
% - Transform the bone meshes, bone coordinate systems, and pin markers into that common frame.
% - Display the registered bones and pins together with the ultrasound scene.

fprintf('Displaying the CT bones and selected bone pins...\n');

% Average every rigid body requested by the JSON configuration over all
% acquisition places. Pooling all rows gives each sample the same weight.
averagedRigidBodyTransforms = struct();

% Count all rows once so the collection arrays have their final size.
totalRigidBodySampleCount = 0;
for snapshotIndex = 1:numel(snapshotData)
    totalRigidBodySampleCount = totalRigidBodySampleCount + height(snapshotData(snapshotIndex).rigidbodies);
end

% Loop for all selected rigid bodies
for rigidBodyIndex = 1:numel(rigidBodyNamesToAverage)

    % Get current rigid body name
    rigidBodyName = rigidBodyNamesToAverage{rigidBodyIndex};

    % Collect the quaternion and translation from every row at every place.
    quaternionSamples  = zeros(totalRigidBodySampleCount, 4);
    translationSamples = zeros(totalRigidBodySampleCount, 3);
    sampleIndex = 0;

    for snapshotIndex = 1:numel(snapshotData)
        currentRigidBodies = snapshotData(snapshotIndex).rigidbodies;

        % An empty snapshot place has no measurements to add to the average.
        if isempty(currentRigidBodies)
            continue
        end
        rigidBodyRecords = currentRigidBodies.(rigidBodyName);

        for recordIndex = 1:numel(rigidBodyRecords)
            currentRecord = rigidBodyRecords{recordIndex};

            % Normalize the scalar-first [w x y z] quaternion before storing
            % it, then store the matching translation in the same row.
            sampleIndex   = sampleIndex + 1;
            quaternionRow = reshape(currentRecord.q, 1, 4);
            quaternionSamples(sampleIndex, :)  = quaternionRow / norm(quaternionRow);
            translationSamples(sampleIndex, :) = reshape(currentRecord.t, 1, 3);
        end
    end

    % Give a direct error when the input contains no rows for this body.
    if sampleIndex == 0
        error('build_ultrasoundBone_intersectionData:NoValidRigidBodySamples', ...
            'No rigid-body samples are available for %s.', ...
            rigidBodyName);
    end

    % Convert the stored rows to MATLAB quaternion objects and use meanrot
    % for rotation. Translation uses the regular arithmetic mean.
    meanQuaternion  = meanrot(quaternion(quaternionSamples(1:sampleIndex, :)));
    meanRotation    = quat2rotm(compact(meanQuaternion));
    meanTranslation = mean(translationSamples(1:sampleIndex, :), 1);

    % Combine the two averages into one global rigid-body transform.
    meanTransform           = eye(4);
    meanTransform(1:3, 1:3) = meanRotation;
    meanTransform(1:3, 4)   = meanTranslation(:);
    averagedRigidBodyTransforms.(rigidBodyName) = meanTransform;

    fprintf('Averaged %s from %d rigid-body sample(s).\n', rigidBodyName, sampleIndex);
end

% Every bone transformation uses the same averaged reference pose.
T_ref_global = averagedRigidBodyTransforms.B_N_REF;
validateattributes(T_ref_global, {'numeric'}, {'size', [4, 4], 'finite'}, mfilename, 'T_ref_global');

% Use the validated pin place for each bone code from the JSON configuration.

% Group each bone with all pins that share its bone code. The helper also
% validates that every requested place identifies exactly one pin.
boneUnits = coupleBonesAndPins(bones, bonepins, pinSelection);

% Keep each transformed mesh under its bone code so ultrasound snapshots
% can later be intersected only with their corresponding anatomy.
boneMeshesRefByCode = struct();

% Visit the coupled units instead of assuming that bones and pins have the
% same array length or ordering.
for boneIndex = 1:numel(boneUnits)

    % Use short names so every display command clearly reads from the same
    % bone and from the pin selected for that bone.
    currentUnit = boneUnits(boneIndex);
    currentBone = currentUnit.boneData;
    currentPin  = currentUnit.pins(currentUnit.selectedPinIndex);

    % Build the motion-capture name from the same bone code and pin place
    % used by pinSelection, for example C_F_PRO or C_T_DIS.
    pinRigidBodyName = sprintf('C_%s_%s', currentUnit.bone, currentUnit.selectedPinPlace);
    if ~isfield(averagedRigidBodyTransforms, pinRigidBodyName)
        error('build_ultrasoundBone_intersectionData:MissingAveragedPinRigidBody', ...
              'No averaged rigid-body transform was prepared for %s.', pinRigidBodyName);
    end

    % Use the pooled pin pose that was averaged in the same global frame as
    % the pooled reference pose above.
    T_pin_global = averagedRigidBodyTransforms.(pinRigidBodyName);
    validateattributes(T_pin_global, {'numeric'}, {'size', [4, 4], 'finite'}, mfilename, 'T_pin_global');

    % Express the tracked pin in ref. Left division is the numerically safer
    % equivalent of inv(T_ref_global) * T_pin_global from the frame rule.
    T_pin_ref   = T_ref_global \ T_pin_global;

    % Build the common CT-to-ref transform from the pin correspondence.
    % Right division is equivalent to T_pin_ref * inv(T_pin_CT).
    T_CT_ref    = T_pin_ref / currentPin.T_pin_CT;

    % Propagate the stored bone ACS from CT into ref using the shared CT map.
    T_bone_ref  = T_CT_ref * currentBone.T_bone_CT;

    % Mesh vertices are already CT-frame points, so transform them with
    % T_CT_ref rather than with the bone ACS transform itself.
    bonePointsRef = applyRigidTransform(currentBone.mesh.Points, T_CT_ref);
    boneMeshRef   = triangulation(currentBone.mesh.ConnectivityList, bonePointsRef);

    % Store only V and F because meshPlaneIntersectionPixels intentionally
    % enforces this exact mesh interface.
    currentBoneCode = char(currentUnit.bone);
    boneMeshesRefByCode.(currentBoneCode) = struct( ...
        'V', bonePointsRef, ...
        'F', currentBone.mesh.ConnectivityList);

    % Draw the ref-frame bone surface first. Transparency keeps the selected pin
    % markers and the ultrasound planes visible through the mesh.
    trisurf(boneMeshRef, ...
        'Parent', ax1, ...
        'FaceColor', [0.92, 0.83, 0.74], ...
        'EdgeColor', 'none', ...
        'FaceAlpha', 0.40, ...
        'Tag', 'plot_ct_bone_meshes');

    % Draw the anatomical coordinate system after propagating it into ref.
    boneOrigin   = T_bone_ref(1:3, 4);
    boneBaseAxes = T_bone_ref(1:3, 1:3);
    boneAxisName = sprintf('%s Bone ACS', char(currentUnit.name));
    display_axis_v2(ax1, boneOrigin, boneBaseAxes, quiverscale, boneAxisName, 'Tag', 'plot_ct_bone_acs_axes', 'Mode', 'default');

    % The marker centroids are CT-frame columns in a 3-by-N matrix. Transpose
    % them for the shared point helper so the displayed markers also use ref.
    pinMarkerCentroidsRef = applyRigidTransform(currentPin.marker_centroids.', T_CT_ref);

    % Only markers belonging to the pin selected above are displayed.
    scatter3(ax1, ...
        pinMarkerCentroidsRef(:, 1), ...
        pinMarkerCentroidsRef(:, 2), ...
        pinMarkerCentroidsRef(:, 3), ...
        50, ...
        'filled', ...
        'MarkerFaceColor', [1.00, 0.85, 0.15], ...
        'MarkerEdgeColor', [0.20, 0.20, 0.20], ...
        'Tag', 'plot_ct_pin_markers');

    % Draw the selected tracked pin frame in ref. Include the place in the
    % label to show which pin supplied the CT-to-ref correspondence.
    pinOrigin   = T_pin_ref(1:3, 4);
    pinBaseAxes = T_pin_ref(1:3, 1:3);
    pinAxisName = sprintf('%s %s Pin', char(currentUnit.name), char(currentUnit.selectedPinPlace));
    display_axis_v2(ax1, pinOrigin, pinBaseAxes, quiverscale, pinAxisName, 'Tag', 'plot_ct_pin_axes', 'Mode', 'default');
end

% Render the completed scene immediately after both coupled units are drawn.
drawnow;

%% COMPUTE AND SHOW THE INTERSECTION
% Find where each cached ultrasound plane intersects its matching reference-frame bone mesh.
% Summary:
% - Match each cached ultrasound plane with the corresponding femur or tibia mesh in the reference frame.
% - Calculate the raw mesh-plane intersections and identify the portions facing the ultrasound probe.
% - Store the intersection masks, pixels, segments, scores, timestamps, and status information.
% - Open the results browser so the images and intersection overlays can be inspected interactively.

fprintf('Computing snapshot mesh-plane intersections...\n');

% Match the validated example so mesh faces must lie within this angle of
% the probe-facing direction before their intersection pixels are selected.
normalFacingToleranceDeg = 25;

% Keep every raw and probe-facing output because the results browser shows
% counts and overlays without recomputing geometry during row selection.
intersectionTemplate = struct( ...
    'mask', [], ...                     % Binary image mask of all mesh-plane hit pixels.
    'pixelList', [], ...                % [row, col] coordinates of all hit pixels.
    'segments3D', {{}}, ...             % Raw intersection segments in 3D space.
    'segmentsUV', {{}}, ...             % The same clipped segments in plane coordinates.
    'segmentFaceIdx', [], ...           % Mesh-face index that produced each segment.
    'probeFacingSegmentMask', [], ...   % Mask marking segments from probe-facing faces.
    'probeFacingSegments3D', {{}}, ...  % Probe-facing intersection segments in 3D.
    'probeFacingSegmentsUV', {{}}, ...  % Probe-facing segments in plane coordinates.
    'probeFacingPixels', [], ...        % Image pixels from the probe-facing segments.
    'segmentFacingScore', [], ...       % How strongly each segment's face faces the probe.
    'timestamp', [], ...                % Timestamp of the source ultrasound image.
    'status', 'Not computed');          % Text describing the calculation state.

% Mirror the plane groups exactly so the same pair of group and local indices
% always identifies an image plane and its intersection result.
emptyIntersectionData = repmat(intersectionTemplate, 1, 0);
intersectionGroupTemplate = struct( ...
    'name', '', ...
    'bone', 'U', ...
    'path', '', ...
    'data', emptyIntersectionData);
intersections = repmat(intersectionGroupTemplate, 1, numel(snapshotPlanes));

% Count all local records only for progress reporting. This does not flatten
% the stored data or change the directory-based indexing contract.
totalSnapshotPlaneCount     = sum(arrayfun(@(snapshotGroup) numel(snapshotGroup.data), snapshotPlanes));
processedSnapshotPlaneCount = 0;

% Compute every result once so table browsing only redraws the selected image
% and never repeats the expensive mesh-plane intersection calculation.
for groupIndex = 1:numel(snapshotPlanes)

    % Get current plane group
    currentPlaneGroup = snapshotPlanes(groupIndex);

    % Copy the group metadata so both result containers expose the same outer
    % structure, including source directories that contain no valid planes.
    intersections(groupIndex).name = currentPlaneGroup.name;
    intersections(groupIndex).bone = currentPlaneGroup.bone;
    intersections(groupIndex).path = currentPlaneGroup.path;
    intersections(groupIndex).data = repmat( ...
        intersectionTemplate, 1, numel(currentPlaneGroup.data));

    for planeIndex = 1:numel(currentPlaneGroup.data)

        % Get current snapshot
        processedSnapshotPlaneCount = processedSnapshotPlaneCount + 1;

        % Read the aligned plane and initialize its timestamp before geometry
        % checks so skipped results still remain linked to their source image.
        currentPlane    = currentPlaneGroup.data(planeIndex);
        currentBoneCode = char(currentPlane.bone);
        intersections(groupIndex).data(planeIndex).timestamp = currentPlane.timestamp;

        % Keep unknown bone groups visible in the table, but do not intersect
        % them with an arbitrary anatomical mesh.
        if isempty(currentBoneCode) || ~isvarname(currentBoneCode) || ~isfield(boneMeshesRefByCode, currentBoneCode)
            intersections(groupIndex).data(planeIndex).status = sprintf( ...
                'Skipped: no reference-frame mesh for bone code "%s".', ...
                currentBoneCode);
            fprintf('[Group %d/%d, %s, snapshot %d/%d, overall %d/%d] %s\n', ...
                groupIndex, numel(snapshotPlanes), currentPlaneGroup.name, ...
                planeIndex, numel(currentPlaneGroup.data), ...
                processedSnapshotPlaneCount, totalSnapshotPlaneCount, ...
                intersections(groupIndex).data(planeIndex).status);
            continue;
        end

        % Select the transformed femur or tibia mesh that matches this plane's
        % snapshot group before running the shared geometry helper.
        currentMesh = boneMeshesRefByCode.(currentBoneCode);
        [mask, pixelList, segments3D, segmentsUV, segmentFaceIdx] = meshPlaneIntersectionPixels(currentMesh, currentPlane);

        % Use the same plane-to-pixel conversion as the validated intersection
        % example and the optimization geometry pipeline.
        du = currentPlane.W / currentPlane.nCols;
        dv = currentPlane.H / currentPlane.nRows;

        % Filter the raw intersection to mesh faces whose normals point toward
        % the ultrasound probe within the configured angular tolerance.
        [probeFacingSegmentMask, probeFacingSegments3D, ...
            probeFacingSegmentsUV, probeFacingPixels, segmentFacingScore] = ...
            selectProbeFacingIntersectionSegments( ...
                currentMesh, segments3D, segmentsUV, segmentFaceIdx, ...
                currentPlane, du, dv, currentPlane.nRows, ...
                currentPlane.nCols, normalFacingToleranceDeg);

        % Store all geometry outputs at the same group and local indices as
        % the source plane so browser callbacks never need a flattened lookup.
        intersections(groupIndex).data(planeIndex).mask                  = mask;
        intersections(groupIndex).data(planeIndex).pixelList              = pixelList;
        intersections(groupIndex).data(planeIndex).segments3D             = segments3D;
        intersections(groupIndex).data(planeIndex).segmentsUV             = segmentsUV;
        intersections(groupIndex).data(planeIndex).segmentFaceIdx         = segmentFaceIdx;
        intersections(groupIndex).data(planeIndex).probeFacingSegmentMask = probeFacingSegmentMask;
        intersections(groupIndex).data(planeIndex).probeFacingSegments3D  = probeFacingSegments3D;
        intersections(groupIndex).data(planeIndex).probeFacingSegmentsUV  = probeFacingSegmentsUV;
        intersections(groupIndex).data(planeIndex).probeFacingPixels      = probeFacingPixels;
        intersections(groupIndex).data(planeIndex).segmentFacingScore     = segmentFacingScore;
        intersections(groupIndex).data(planeIndex).status                 = 'Computed';

        % Print group-local and total progress so the directory separation is
        % visible without losing an overall estimate for long calculations.
        fprintf(['[Group %d/%d, %s, snapshot %d/%d, overall %d/%d, ' ...
                 't = %.3f] %d hit pixels, %d segments, %d probe-facing ' ...
                 'segments, %d probe-facing pixels.\n'], ...
                 groupIndex, numel(snapshotPlanes), currentPlaneGroup.name, ...
                 planeIndex, numel(currentPlaneGroup.data), ...
                 processedSnapshotPlaneCount, totalSnapshotPlaneCount, ...
                 double(currentPlane.timestamp), size(pixelList, 1), ...
                 numel(segments3D), numel(probeFacingSegments3D), ...
                 size(probeFacingPixels, 1));
    end
end

% Open the existing results-first browser in the configured mode after all
% intersection records are ready. Review mode provides MAT-file export.
[figIntersectionBrowser, validSnapshots, outputFilePath] = ...
    displaySnapshotIntersectionBrowser( ...
        snapshotPlanes, intersections, boneMeshesRefByCode, ...
        'Mode', displayMode, ...
        'OutputDirectory', defaultOutputDirectory);
