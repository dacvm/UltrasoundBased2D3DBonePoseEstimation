clear; clc; close all;

%% LOAD AND VALIDATE THE CONFIGURATION
% Find this script instead of relying on MATLAB's current folder. This makes
% the config-driven workflow behave the same when it is launched elsewhere.
scriptFullPath = mfilename('fullpath');
if isempty(scriptFullPath)
    error('extra_snapshotProcess_from_config:ScriptPathUnavailable', ...
          'Run extra_snapshotProcess_from_config.m as a complete script so its configuration file can be located.');
end
scriptDirectory = fileparts(scriptFullPath);

% This script lives in tools/snapshotProcess, two folders below the project root.
projectRoot = fileparts(fileparts(scriptDirectory));

% Add the project helpers through an absolute path from the project root.
functionsDirectory = fullfile(projectRoot, 'functions');
if ~isfolder(functionsDirectory)
    error('extra_snapshotProcess_from_config:FunctionsDirectoryNotFound', ...
          'Required functions directory not found: %s', functionsDirectory);
end
addpath(genpath(functionsDirectory));

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
        error('extra_snapshotProcess_from_config:OutputDirectoryCreationFailed', ...
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
        missingRigidBodyNames = setdiff( ...
            rigidBodyNamesToAverage, ...
            currentRigidBodies.Properties.VariableNames, ...
            'stable');
        if ~isempty(missingRigidBodyNames)
            error('extra_snapshotProcess_from_config:MissingCsvRigidBody', ...
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
    error('extra_snapshotProcess_from_config:InvalidFcalImageToProbeTransform', ...
        ['Expected exactly one ImageToProbe transform in "%s", but found ' ...
         '%d.'], ...
        fullfile_fcalconfig, numel(imageToProbeTransformIndex));
end
T_image_probecalib = ...
    transformations(imageToProbeTransformIndex).Matrix;

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

% Count every packet before the display loop so the plane array can be
% allocated once. Packets with invalid tracking will be removed afterward.
maximumSnapshotPlaneCount = 0;
for snapshotIndex = 1:numel(snapshotData)
    currentSnapshotSequences = snapshotData(snapshotIndex).sequences;
    for sequenceIndex = 1:numel(currentSnapshotSequences)
        maximumSnapshotPlaneCount = maximumSnapshotPlaneCount + ...
            numel(currentSnapshotSequences(sequenceIndex).packets);
    end
end

% Prepare one flat record per valid image plane. The geometry fields follow
% meshPlaneIntersectionPixels, while the metadata keeps each result linked
% to the source snapshot after the browser table is sorted.
snapshotPlaneTemplate = struct( ...
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
snapshotPlanes = repmat(snapshotPlaneTemplate, 1, maximumSnapshotPlaneCount);
snapshotPlaneCount = 0;

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
            snapshotPlaneCount = snapshotPlaneCount + 1;
            snapshotPlanes(snapshotPlaneCount).p0 = T_image_ref(1:3, 4);
            snapshotPlanes(snapshotPlaneCount).ex = T_image_ref(1:3, 1);
            snapshotPlanes(snapshotPlaneCount).ey = T_image_ref(1:3, 2);
            snapshotPlanes(snapshotPlaneCount).n  = T_image_ref(1:3, 3);

            % Packet images use [width, height] storage, so width follows
            % the first dimension and rows follow the second dimension.
            snapshotPlanes(snapshotPlaneCount).W             = (size(current_packet.Image, 1) - 1) * S_image_probecalib(1);
            snapshotPlanes(snapshotPlaneCount).H             = (size(current_packet.Image, 2) - 1) * S_image_probecalib(2);
            snapshotPlanes(snapshotPlaneCount).nRows         = size(current_packet.Image, 2);
            snapshotPlanes(snapshotPlaneCount).nCols         = size(current_packet.Image, 1);
            snapshotPlanes(snapshotPlaneCount).image         = current_packet.Image;
            snapshotPlanes(snapshotPlaneCount).timestamp     = current_packet.Timestamp;

            % Preserve source identifiers because a sortable table cannot
            % rely on its visible row number to identify the original data.
            snapshotPlanes(snapshotPlaneCount).bone          = snapshotData(snapshotIndex).bone;
            snapshotPlanes(snapshotPlaneCount).snapshotName  = snapshotData(snapshotIndex).name;
            snapshotPlanes(snapshotPlaneCount).snapshotIndex = snapshotIndex;
            snapshotPlanes(snapshotPlaneCount).sequenceIndex = sequenceIndex;
            snapshotPlanes(snapshotPlaneCount).packetIndex   = packetIndex;

            % Update the figure during the loop so MATLAB shows progress while loading all snapshots.
            % drawnow;

        end
    end
end

% Discard unused preallocated entries created for packets that failed the
% existing probe or reference tracking checks.
snapshotPlanes = snapshotPlanes(1:snapshotPlaneCount);


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
        error('extra_snapshotProcess_from_config:NoValidRigidBodySamples', ...
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
        error('extra_snapshotProcess_from_config:MissingAveragedPinRigidBody', ...
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
    pinMarkerCentroidsRef = applyRigidTransform( ...
        currentPin.marker_centroids.', T_CT_ref);

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
intersections = repmat(intersectionTemplate, 1, numel(snapshotPlanes));

% Compute every result once so table browsing only redraws the selected
% image and never repeats the expensive mesh-plane intersection calculation.
for planeIndex = 1:numel(snapshotPlanes)

    % Get the current plane and bone
    currentPlane    = snapshotPlanes(planeIndex);
    currentBoneCode = char(currentPlane.bone);
    intersections(planeIndex).timestamp = currentPlane.timestamp;

    % Keep unknown bone groups visible in the table, but do not intersect
    % them with an arbitrary anatomical mesh.
    if isempty(currentBoneCode) || ~isvarname(currentBoneCode) || ~isfield(boneMeshesRefByCode, currentBoneCode)

        % Store the status for future debugging
        intersections(planeIndex).status = sprintf('Skipped: no reference-frame mesh for bone code "%s".', currentBoneCode);
        % Display the status for the user
        fprintf('[Snapshot %d/%d, %s] %s\n', planeIndex, numel(snapshotPlanes), currentPlane.snapshotName, intersections(planeIndex).status);

        % Skip this plane.
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
    [probeFacingSegmentMask, probeFacingSegments3D, probeFacingSegmentsUV, probeFacingPixels, segmentFacingScore] = ...
        selectProbeFacingIntersectionSegments( ...
            currentMesh, segments3D, segmentsUV, segmentFaceIdx, currentPlane, ...
            du, dv, currentPlane.nRows, currentPlane.nCols, normalFacingToleranceDeg);

    % Store all geometry outputs in the same order as snapshotPlanes so one
    % stable result index can drive both the table and image display.
    intersections(planeIndex).mask                      = mask;
    intersections(planeIndex).pixelList                 = pixelList;
    intersections(planeIndex).segments3D                = segments3D;
    intersections(planeIndex).segmentsUV                = segmentsUV;
    intersections(planeIndex).segmentFaceIdx            = segmentFaceIdx;
    intersections(planeIndex).probeFacingSegmentMask    = probeFacingSegmentMask;
    intersections(planeIndex).probeFacingSegments3D     = probeFacingSegments3D;
    intersections(planeIndex).probeFacingSegmentsUV     = probeFacingSegmentsUV;
    intersections(planeIndex).probeFacingPixels         = probeFacingPixels;
    intersections(planeIndex).segmentFacingScore        = segmentFacingScore;
    intersections(planeIndex).status                    = 'Computed';

    % Print compact progress because processing many snapshots can take long
    % enough that users need to see which input is currently being evaluated.
    fprintf(['[Snapshot %d/%d, %s, t = %.3f] %d hit pixels, ' ...
        '%d segments, %d probe-facing segments, %d probe-facing pixels.\n'], ...
        planeIndex, numel(snapshotPlanes), currentPlane.snapshotName, ...
        double(currentPlane.timestamp), size(pixelList, 1), numel(segments3D), ...
        numel(probeFacingSegments3D), size(probeFacingPixels, 1));
end

% Open the existing results-first browser in the configured mode after all
% intersection records are ready. Review mode provides MAT-file export.
[figIntersectionBrowser, validSnapshots, outputFilePath] = ...
    displaySnapshotIntersectionBrowser( ...
        snapshotPlanes, intersections, boneMeshesRefByCode, ...
        'Mode', displayMode, ...
        'OutputDirectory', defaultOutputDirectory);




%% HELPER: READ SNAPSHOT PROCESS CONFIGURATION

function configuration = readSnapshotProcessConfiguration(configurationPath)
%READSNAPSHOTPROCESSCONFIGURATION Load and validate snapshot workflow settings.
% This function reads the user-editable JSON file and prepares the paths and
% options needed by the snapshot workflow. Keeping this work here prevents
% experiment-specific values from being hardcoded in the processing script.
%
% Input:
%   configurationPath - Path to the JSON configuration file.
%
% Output:
%   configuration - Scalar struct containing validated absolute input paths,
%                   normalized pin selections and rigid-body names, and the
%                   normalized browser mode.

% Check the file first so a missing config is reported separately from bad
% JSON syntax.
if ~isfile(configurationPath)
    error('extra_snapshotProcess_from_config:ConfigurationNotFound', ...
        'Configuration file not found: %s', configurationPath);
end

% Include the config path in parsing errors because that is the file the user
% needs to correct.
try
    configurationText = fileread(configurationPath);
    rawConfiguration = jsondecode(configurationText);
catch configurationError
    error('extra_snapshotProcess_from_config:InvalidConfigurationJson', ...
        'Could not read configuration JSON "%s". Reason: %s', ...
        configurationPath, configurationError.message);
end

% One top-level JSON object gives every required setting one unambiguous
% location.
if ~isstruct(rawConfiguration) || ~isscalar(rawConfiguration)
    error('extra_snapshotProcess_from_config:InvalidConfigurationRoot', ...
        'Configuration JSON must contain one object at its top level: %s', ...
        configurationPath);
end
configurationDirectory = fileparts(configurationPath);

% Read path text before resolving it so missing fields and path failures have
% separate, useful messages.
snapshotDirectorySetting = requireConfigurationText( ...
    rawConfiguration, 'snapshotDirectory', 'snapshotDirectory');
fcalConfigFileSetting = requireConfigurationText( ...
    rawConfiguration, 'fcalConfigFile', 'fcalConfigFile');
ctPostProcessedMatFileSetting = requireConfigurationText( ...
    rawConfiguration, ...
    'ctPostProcessedMatFile', ...
    'ctPostProcessedMatFile');

% Relative settings start beside the JSON file. Existing absolute paths are
% preserved, which supports both portable and machine-specific configs.
snapshotDirectory = resolveConfiguredInputPath( ...
    snapshotDirectorySetting, ...
    configurationDirectory, ...
    'snapshotDirectory', ...
    'directory', ...
    '');
fcalConfigFile = resolveConfiguredInputPath( ...
    fcalConfigFileSetting, ...
    configurationDirectory, ...
    'fcalConfigFile', ...
    'file', ...
    '.xml');
ctPostProcessedMatFile = resolveConfiguredInputPath( ...
    ctPostProcessedMatFileSetting, ...
    configurationDirectory, ...
    'ctPostProcessedMatFile', ...
    'file', ...
    '.mat');

% Read the two required pin places and normalize them before they are used to
% build motion-capture rigid-body names.
rawPinSelection = requireConfigurationObject( ...
    rawConfiguration, 'pinSelection', 'pinSelection');
femurPinPlace = normalizePinPlace( ...
    requireConfigurationText(rawPinSelection, 'F', 'pinSelection.F'), ...
    'F', ...
    'pinSelection.F');
tibiaPinPlace = normalizePinPlace( ...
    requireConfigurationText(rawPinSelection, 'T', 'pinSelection.T'), ...
    'T', ...
    'pinSelection.T');
pinSelection = struct('F', femurPinPlace, 'T', tibiaPinPlace);

% Preserve the configured averaging order while normalizing the names to the
% table-field spelling used by the processing loop.
rigidBodyNamesToAverage = requireConfigurationTextArray( ...
    rawConfiguration, ...
    'rigidBodyNamesToAverage', ...
    'rigidBodyNamesToAverage');
rigidBodyNamesToAverage = cellfun( ...
    @(name) upper(strtrim(name)), ...
    rigidBodyNamesToAverage, ...
    'UniformOutput', false);

% Reject invalid or duplicate names before any CSV files are opened.
for rigidBodyIndex = 1:numel(rigidBodyNamesToAverage)
    currentRigidBodyName = rigidBodyNamesToAverage{rigidBodyIndex};
    if isempty(currentRigidBodyName) || ~isvarname(currentRigidBodyName)
        error('extra_snapshotProcess_from_config:InvalidRigidBodyName', ...
            ['Configuration field "rigidBodyNamesToAverage" contains an ' ...
             'invalid MATLAB table variable name: "%s".'], ...
            currentRigidBodyName);
    end
end
if numel(unique(rigidBodyNamesToAverage, 'stable')) ...
        ~= numel(rigidBodyNamesToAverage)
    error('extra_snapshotProcess_from_config:DuplicateRigidBodyName', ...
        ['Configuration field "rigidBodyNamesToAverage" must not contain ' ...
         'duplicate names.']);
end

% Registration always needs the reference and both selected bone pins.
% Enforcing this relationship here prevents a later missing-field failure.
requiredRigidBodyNames = { ...
    'B_N_REF', ...
    sprintf('C_F_%s', femurPinPlace), ...
    sprintf('C_T_%s', tibiaPinPlace)};
missingRequiredRigidBodyNames = requiredRigidBodyNames( ...
    ~ismember(requiredRigidBodyNames, rigidBodyNamesToAverage));
if ~isempty(missingRequiredRigidBodyNames)
    error('extra_snapshotProcess_from_config:MissingRequiredRigidBodyName', ...
        ['Configuration field "rigidBodyNamesToAverage" must include "%s" ' ...
         'for the selected reference and pin configuration.'], ...
        missingRequiredRigidBodyNames{1});
end

% Normalize the browser option once so the main workflow can pass it directly
% to displaySnapshotIntersectionBrowser.
displayMode = lower(requireConfigurationText( ...
    rawConfiguration, 'displayMode', 'displayMode'));
if ~ismember(displayMode, {'display', 'review'})
    error('extra_snapshotProcess_from_config:InvalidDisplayMode', ...
        'Configuration field "displayMode" must be "display" or "review".');
end

% Return only checked values so the processing sections never need to access
% raw JSON data.
configuration = struct();
configuration.snapshotDirectory = snapshotDirectory;
configuration.fcalConfigFile = fcalConfigFile;
configuration.ctPostProcessedMatFile = ctPostProcessedMatFile;
configuration.pinSelection = pinSelection;
configuration.rigidBodyNamesToAverage = rigidBodyNamesToAverage;
configuration.displayMode = displayMode;
end


%% HELPER: REQUIRE CONFIGURATION OBJECT

function requiredObject = requireConfigurationObject(parentObject, fieldName, fieldLabel)
%REQUIRECONFIGURATIONOBJECT Return one required scalar JSON object.
% This helper gives missing and incorrectly typed config sections a direct
% error instead of allowing an unclear field-access failure later.
%
% Inputs:
%   parentObject - Scalar MATLAB struct decoded from a JSON object.
%   fieldName    - Field name to read from parentObject.
%   fieldLabel   - User-facing field path included in error messages.
%
% Output:
%   requiredObject - Required scalar struct stored in the named field.

% Check both presence and type because nested config code assumes one object.
if ~isstruct(parentObject) ...
        || ~isscalar(parentObject) ...
        || ~isfield(parentObject, fieldName)
    error('extra_snapshotProcess_from_config:MissingConfigurationField', ...
        'Required configuration object "%s" is missing.', fieldLabel);
end
requiredObject = parentObject.(fieldName);
if ~isstruct(requiredObject) || ~isscalar(requiredObject)
    error('extra_snapshotProcess_from_config:InvalidConfigurationField', ...
        'Configuration field "%s" must contain one JSON object.', ...
        fieldLabel);
end
end


%% HELPER: REQUIRE CONFIGURATION TEXT

function textValue = requireConfigurationText(parentObject, fieldName, fieldLabel)
%REQUIRECONFIGURATIONTEXT Return one required nonempty JSON text value.
% This helper normalizes JSON text to a MATLAB character vector so later
% path and option checks use one predictable representation.
%
% Inputs:
%   parentObject - Scalar MATLAB struct decoded from a JSON object.
%   fieldName    - Field name to read from parentObject.
%   fieldLabel   - User-facing field path included in error messages.
%
% Output:
%   textValue - Trimmed, nonempty character vector from the named field.

% Report a missing value before trying to inspect its type.
if ~isstruct(parentObject) ...
        || ~isscalar(parentObject) ...
        || ~isfield(parentObject, fieldName)
    error('extra_snapshotProcess_from_config:MissingConfigurationField', ...
        'Required configuration field "%s" is missing.', fieldLabel);
end
rawValue = parentObject.(fieldName);

% Accept either MATLAB text type because jsondecode behavior can differ by
% release and JSON shape.
if isstring(rawValue) && isscalar(rawValue)
    textValue = char(rawValue);
elseif ischar(rawValue) && isrow(rawValue)
    textValue = rawValue;
else
    error('extra_snapshotProcess_from_config:InvalidConfigurationField', ...
        'Configuration field "%s" must contain one text value.', ...
        fieldLabel);
end
textValue = strtrim(textValue);
if isempty(textValue)
    error('extra_snapshotProcess_from_config:InvalidConfigurationField', ...
        'Configuration field "%s" cannot be empty.', fieldLabel);
end
end


%% HELPER: REQUIRE CONFIGURATION TEXT ARRAY

function textValues = requireConfigurationTextArray(parentObject, fieldName, fieldLabel)
%REQUIRECONFIGURATIONTEXTARRAY Return a required nonempty JSON string array.
% This helper preserves the JSON element order because the averaging loop
% should follow the order chosen in the configuration.
%
% Inputs:
%   parentObject - Scalar MATLAB struct decoded from the top-level JSON object.
%   fieldName    - Field name of the JSON string array.
%   fieldLabel   - User-facing field path included in error messages.
%
% Output:
%   textValues - Row cell array of trimmed, nonempty character vectors.

% Check field presence before converting the decoded array.
if ~isstruct(parentObject) ...
        || ~isscalar(parentObject) ...
        || ~isfield(parentObject, fieldName)
    error('extra_snapshotProcess_from_config:MissingConfigurationField', ...
        'Required configuration field "%s" is missing.', fieldLabel);
end
rawValues = parentObject.(fieldName);

% JSON string arrays normally decode as cell arrays of char vectors. Also
% accept MATLAB string vectors for compatibility with prepared structs.
if iscell(rawValues) && isvector(rawValues)
    textValues = rawValues(:).';
elseif isstring(rawValues) && isvector(rawValues)
    textValues = cellstr(rawValues(:).');
else
    error('extra_snapshotProcess_from_config:InvalidConfigurationField', ...
        'Configuration field "%s" must be a JSON string array.', ...
        fieldLabel);
end
if isempty(textValues)
    error('extra_snapshotProcess_from_config:InvalidConfigurationField', ...
        'Configuration field "%s" cannot be empty.', fieldLabel);
end

% Normalize every entry separately so one invalid item identifies its array
% index in the error.
for valueIndex = 1:numel(textValues)
    currentValue = textValues{valueIndex};
    if isstring(currentValue) && isscalar(currentValue)
        currentValue = char(currentValue);
    end
    if ~ischar(currentValue) || ~isrow(currentValue)
        error('extra_snapshotProcess_from_config:InvalidConfigurationField', ...
            ['Configuration field "%s" item %d must contain one text ' ...
             'value.'], ...
            fieldLabel, valueIndex);
    end

    currentValue = strtrim(currentValue);
    if isempty(currentValue)
        error('extra_snapshotProcess_from_config:InvalidConfigurationField', ...
            'Configuration field "%s" item %d cannot be empty.', ...
            fieldLabel, valueIndex);
    end
    textValues{valueIndex} = currentValue;
end
end


%% HELPER: NORMALIZE PLACE

function normalizedPlace = normalizePinPlace(rawPlace, boneCode, fieldLabel)
%NORMALIZEPINPLACE Normalize and validate one configured bone-pin location.
% The normalized place is used both for CT pin selection and for building the
% matching motion-capture table variable, so both systems stay consistent.
%
% Inputs:
%   rawPlace   - Nonempty configured pin-location text.
%   boneCode   - Bone code used in the rigid-body name, such as F or T.
%   fieldLabel - User-facing configuration field path for error messages.
%
% Output:
%   normalizedPlace - Uppercase pin-location character vector.

% Uppercase the place because CT and motion-capture identifiers use the same
% case-insensitive convention.
normalizedPlace = upper(strtrim(rawPlace));
candidateRigidBodyName = sprintf('C_%s_%s', boneCode, normalizedPlace);

% The CSV reader stores rigid bodies as table variable names, so the generated
% name must be valid for dynamic table access.
if ~isvarname(candidateRigidBodyName)
    error('extra_snapshotProcess_from_config:InvalidPinSelection', ...
        ['Configuration field "%s" creates invalid rigid-body name ' ...
         '"%s".'], ...
        fieldLabel, candidateRigidBodyName);
end
end


%% HELPER: RESOLVE PATH

function resolvedPath = resolveConfiguredInputPath( ...
        configuredPath, configurationDirectory, fieldLabel, ...
        expectedKind, expectedExtension)
%RESOLVECONFIGUREDINPUTPATH Resolve and validate one configured input path.
% Relative paths are anchored beside the JSON file so configuration behavior
% does not depend on MATLAB's current working directory.
%
% Inputs:
%   configuredPath        - Absolute path or path relative to the JSON file.
%   configurationDirectory - Directory containing the JSON configuration.
%   fieldLabel            - User-facing field name for error messages.
%   expectedKind          - Expected path kind: 'file' or 'directory'.
%   expectedExtension     - Required file extension, or empty for a directory.
%
% Output:
%   resolvedPath - Canonical absolute path to the existing input.

% Build the candidate path without changing already absolute settings.
if isAbsolutePath(configuredPath)
    candidatePath = configuredPath;
else
    candidatePath = fullfile(configurationDirectory, configuredPath);
end

% File settings include an extension check so selecting the wrong input type
% is reported before the workflow calls a specialized reader.
if strcmp(expectedKind, 'file')
    [~, ~, actualExtension] = fileparts(candidatePath);
    if ~strcmpi(actualExtension, expectedExtension)
        error('extra_snapshotProcess_from_config:InvalidInputExtension', ...
            'Configuration field "%s" must identify a %s file.', ...
            fieldLabel, expectedExtension);
    end
    inputExists = isfile(candidatePath);
elseif strcmp(expectedKind, 'directory')
    inputExists = isfolder(candidatePath);
else
    error('extra_snapshotProcess_from_config:InvalidExpectedPathKind', ...
        'Internal path kind "%s" is not supported.', expectedKind);
end
if ~inputExists
    error('extra_snapshotProcess_from_config:ConfiguredInputNotFound', ...
        'Configured input "%s" was not found: %s', ...
        fieldLabel, candidatePath);
end

% Canonicalize the existing path for stable error messages and provenance.
[pathFound, pathAttributes] = fileattrib(candidatePath);
if ~pathFound
    error('extra_snapshotProcess_from_config:PathResolutionFailed', ...
        'Could not resolve configured input "%s": %s', ...
        fieldLabel, candidatePath);
end
resolvedPath = pathAttributes.Name;
end


%% HELPER: IS ABSOLUTE PATH
function isAbsolute = isAbsolutePath(pathValue)
%ISABSOLUTEPATH Identify absolute Windows, UNC, and Unix-style paths.
% This helper is needed so relative configuration paths can be anchored
% beside the JSON file without changing paths that are already absolute.
%
% Input:
%   pathValue - Path stored as a character vector.
%
% Output:
%   isAbsolute - Logical true when pathValue is an absolute path.

% Windows accepts drive-rooted, UNC, and separator-rooted paths. Other
% platforms use a leading forward slash.
if ispc
    hasDriveRoot = ~isempty(regexp( ...
        pathValue, '^[A-Za-z]:[\\/]', 'once'));
    hasSeparatorRoot = startsWith(pathValue, filesep) ...
        || startsWith(pathValue, '/');
    isAbsolute = hasDriveRoot || hasSeparatorRoot;
else
    isAbsolute = startsWith(pathValue, '/');
end
end
