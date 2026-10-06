clear; clc;

%% LOAD AND VALIDATE THE DEVELOPMENT CONFIGURATION
% Purpose of this development script:
% - Read either a collection of static ultrasound snapshots or one kinematic
%   recording from each anatomical source folder.
% - Keep every ultrasound image coupled to the Qualisys row recorded at the
%   same acquisition index.
% - Express ultrasound planes and CT bone surfaces in the shared ref frame.
% - Calculate the mesh/image-plane intersections needed by the later browser.
%
% This file is intentionally separate from
% build_ultrasoundBone_intersectionData.m. The original script is the working
% snapshot workflow, while this file is where static/kinematic support is
% developed. After preparation, the script opens the sequence-aware browser so
% the static or row-specific kinematic result can be inspected immediately. It
% also leaves snapshotPlanes, intersections, validBonePoses, and the browser
% figure handle in the MATLAB workspace for further inspection.
%
% Coordinate-frame convention used throughout this script:
%   p_target = T_source_target * p_source
% For example, T_image_ref maps an image-frame point into the ref frame.
% Transform chains are composed from right to left. Therefore
% T_image_ref = T_probe_ref * T_image_probe first maps image -> probe, then
% probe -> ref. The word "global" below refers to the tracking-system frame.

% Find this script from MATLAB itself instead of relying on the current
% working folder. A junior developer can therefore run the script from any
% folder and still obtain the correct project and configuration paths.
scriptFullPath = mfilename('fullpath');
if isempty(scriptFullPath)
    error('build_ultrasoundBone_intersectionData_poseModes:ScriptPathUnavailable', ...
        'Run this file as a complete script so its configuration can be located.');
end
scriptDirectory = fileparts(scriptFullPath);
projectRoot     = fileparts(fileparts(scriptDirectory));

% This tool is located two levels below the project root. Add the reusable
% functions tree and the tool-local helpers before reading any project data.
functionsDirectory = fullfile(projectRoot, 'functions');
helperDirectory    = fullfile(scriptDirectory, 'helpers');
addpath(genpath(functionsDirectory));
addpath(helperDirectory);

% Keep reusable inputs, processing settings, and the export location in one
% structured JSON file so a new measurement does not require script edits.
configurationPath = fullfile(scriptDirectory, 'configs', 'ultrasoundBone_intersectionData_poseModesConfig.json');
configuration     = readPoseModeProcessConfiguration(configurationPath);

% Copy validated configuration values into short, descriptive names used by
% the processing sections below. processingMode is derived from bonePoseMode:
% average/first/last are static, while perDataRow is kinematic.
acquisitionDirectory             = configuration.input.acquisitionDirectory;
fullfile_fcalconfig              = fullfile( ...
                                   configuration.input.fcalConfigFilePath, ...
                                   configuration.input.fcalConfigFileName);
fullfile_bonectpostprocess       = fullfile( ...
                                   configuration.input.ctPostProcessedMatFilePath, ...
                                   configuration.input.ctPostProcessedMatFileName);
pinSelection                     = configuration.pinSelection;
bonePoseMode                     = configuration.bonePoseMode;
processingMode                   = configuration.processingMode;
requiredRigidBodyNames           = configuration.requiredRigidBodyNames;
ultrasoundIntersectionOutputPath = configuration.output.ultrasoundIntersectionOutputPath;

fprintf('Preparing ultrasound and bone data in %s mode (%s)...\n', ...
    processingMode, bonePoseMode);

%% READ AND ALIGN EVERY MHA/CSV FILE PAIR
% Input directory layout:
% - The acquisition root contains source folders such as femur_medial or
%   tibia_shaft. The folder name tells us which CT bone belongs to its images.
% - Static input contains several pairs per source folder. Each MHA contains
%   one image packet and its paired CSV contains one Qualisys row.
% - Kinematic input contains one pair per source folder. Its MHA contains the
%   complete ultrasound sequence and its CSV contains the matching pose rows.
%
% The acquisition software writes both streams in the same order. This makes
% MHA packet n correspond to CSV row n. We validate the counts before looking
% at validity flags; otherwise removing an invalid packet could shift all later
% poses and make an ultrasound image use the wrong bone pose.

% Read only immediate child folders. Sorting them gives repeatable group
% indices, which are stored later as snapshotIndex provenance.
directoryEntries    = dir(acquisitionDirectory);
isSourceDirectory   = [directoryEntries.isdir] & ~ismember({directoryEntries.name}, {'.', '..'});
sourceDirectories   = directoryEntries(isSourceDirectory);
[~, directoryOrder] = sort({sourceDirectories.name});
sourceDirectories   = sourceDirectories(directoryOrder);

% A sequence pair keeps the two files and their parsed contents together.
% Keeping this boundary is important for kinematic data because packetIndex
% and rigidBodyRowIndex are meaningful only inside their original file pair.
emptySequencePairs = struct( ...
    'mhaPath', {}, ...
    'csvPath', {}, ...
    'sequence', {}, ...
    'rigidBodies', {});
sourceGroupTemplate = struct( ...
    'name', '', ...
    'bone', 'U', ...
    'path', '', ...
    'sequencePairs', emptySequencePairs);
% Preallocate one outer record per source folder. Empty source folders remain
% visible as empty groups instead of disappearing from the output ordering.
sourceGroups = repmat(sourceGroupTemplate, 1, numel(sourceDirectories));

% Outer source-folder loop:
% Visit each anatomical acquisition folder once. During one iteration we
% classify the folder, pair its MHA and CSV files, validate every pair, and
% store the completed folder record in sourceGroups.
for snapshotIndex = 1:numel(sourceDirectories)

    sourceName = sourceDirectories(snapshotIndex).name;
    sourcePath = fullfile(acquisitionDirectory, sourceName);

    % Keep the established folder-name convention for choosing a CT bone.
    % Unknown folders receive U rather than being guessed as femur or tibia;
    % their ultrasound data can still be inspected, but no bone intersection
    % will be calculated for them.
    sourceNameLower = lower(sourceName);
    if contains(sourceNameLower, 'femur')
        boneCode = 'F';
    elseif contains(sourceNameLower, 'tibia')
        boneCode = 'T';
    else
        boneCode = 'U';
    end

    % MHA and CSV files have different prefixes, so sort the two lists
    % independently. Matching positions then reproduce the acquisition order
    % used by the existing snapshot workflow.
    mhaFiles = dir(fullfile(sourcePath, '*.mha'));
    csvFiles = dir(fullfile(sourcePath, '*.csv'));
    [~, mhaOrder] = sort({mhaFiles.name});
    [~, csvOrder] = sort({csvFiles.name});
    mhaFiles = mhaFiles(mhaOrder);
    csvFiles = csvFiles(csvOrder);

    % An empty folder remains represented in the output. A partly populated
    % folder is an error because the remaining file has no acquisition partner.
    if numel(mhaFiles) ~= numel(csvFiles)
        error('build_ultrasoundBone_intersectionData_poseModes:FilePairCountMismatch', ...
              'Source folder "%s" contains %d MHA and %d CSV files.', ...
              sourcePath, numel(mhaFiles), numel(csvFiles));
    end
    % A kinematic file already contains its whole time series. More than one
    % pair would make "row n" ambiguous across recordings in the same folder.
    if processingMode == "kinematic" && numel(mhaFiles) > 1
        error('build_ultrasoundBone_intersectionData_poseModes:MultipleKinematicPairs', ...
              'Kinematic source folder "%s" must contain at most one MHA/CSV pair.', ...
              sourcePath);
    end

    % Allocate the exact number of parsed pairs before reading large images.
    sequencePairs = repmat(struct( ...
        'mhaPath', '', ...
        'csvPath', '', ...
        'sequence', [], ...
        'rigidBodies', table()), ...
        1, numel(mhaFiles));

    % Inner file-pair loop for the current source folder:
    % Read the MHA and CSV at each matching sorted position as one acquisition
    % pair. The completed iteration stores both parsed streams together after
    % their required rigid bodies and packet-to-row counts have been checked.
    for sequenceIndex = 1:numel(mhaFiles)
        mhaPath = fullfile(sourcePath, mhaFiles(sequenceIndex).name);
        csvPath = fullfile(sourcePath, csvFiles(sequenceIndex).name);

        % The MHA reader always returns a packet array with DimSize(3)
        % positions. The V02 CSV reader likewise preserves every CSV row and
        % marks unavailable rigid bodies instead of deleting their rows.
        currentSequence    = read_sequence_image(mhaPath);
        currentRigidBodies = readCSV_qualisysRigidBodiesV02(csvPath);

        % Every bone registration needs the tracked reference plus the pin
        % selected for each bone. Check column names here so an error points to
        % the exact CSV file rather than failing later during pose propagation.
        missingRigidBodyNames = setdiff(requiredRigidBodyNames, currentRigidBodies.Properties.VariableNames, 'stable');
        if ~isempty(missingRigidBodyNames)
            error('build_ultrasoundBone_intersectionData_poseModes:MissingRigidBody', ...
                  'CSV file "%s" does not contain rigid body "%s".', ...
                  csvPath, missingRigidBodyNames{1});
        end

        % Enforce the central alignment contract before checking whether any
        % individual image or transform is valid. Equal counts mean that index
        % n identifies the same acquisition time in both parsed containers.
        numberOfPackets = numel(currentSequence.packets);
        numberOfRows    = height(currentRigidBodies);
        if numberOfPackets ~= numberOfRows
            error('build_ultrasoundBone_intersectionData_poseModes:PacketRowCountMismatch', ...
                  'Paired files must contain the same number of records. MHA "%s" has %d packet(s); CSV "%s" has %d row(s).', ...
                  mhaPath, numberOfPackets, csvPath, numberOfRows);
        end
        % Static mode describes snapshots, not a continuous sequence. Requiring
        % one record in each pair prevents accidentally processing a recording
        % with an averaging mode when perDataRow was intended.
        if processingMode == "static" && numberOfPackets ~= 1
            error('build_ultrasoundBone_intersectionData_poseModes:InvalidStaticPairSize', ...
                  'Static pair "%s" must contain exactly one packet and one CSV row.', ...
                  mhaPath);
        end

        % Store paths beside parsed data so every later warning or provenance
        % record can be traced back to its original acquisition pair.
        sequencePairs(sequenceIndex).mhaPath = mhaPath;
        sequencePairs(sequenceIndex).csvPath = csvPath;
        sequencePairs(sequenceIndex).sequence = currentSequence;
        sequencePairs(sequenceIndex).rigidBodies = currentRigidBodies;
    end

    % Finish this outer group only after all of its pairs passed validation.
    sourceGroups(snapshotIndex).name = sourceName;
    sourceGroups(snapshotIndex).bone = boneCode;
    sourceGroups(snapshotIndex).path = sourcePath;
    sourceGroups(snapshotIndex).sequencePairs = sequencePairs;
end

%% READ THE ULTRASOUND PROBE CALIBRATION
% fCal connects image pixels to the tracked ultrasound probe. Its stored 3x3
% block contains both axis directions and pixel scaling, while the project
% convention requires every T_*_* variable to be a pure rigid transform.
% Therefore this section separates those two meanings:
% - T_image_probe keeps only the closest proper rotation and the translation;
% - S_image_probe keeps the original column lengths as physical pixel spacing.
% The pixel spacing is applied when W and H are calculated, so removing scale
% from the transform does not remove the image's physical size.

% Select by transform name instead of assuming that ImageToProbe is the first
% entry in the XML file. Exactly one match keeps the frame mapping unambiguous.
transformations   = read_fcal_transforms(fullfile_fcalconfig);
imageToProbeIndex = find(strcmp({transformations.Name}, 'ImageToProbe'));
if numel(imageToProbeIndex) ~= 1
    error('build_ultrasoundBone_intersectionData_poseModes:InvalidImageToProbe', ...
        'The fCal file must contain exactly one ImageToProbe transform.');
end

% The original T_image_probe contains
% Extract the original 3x3 rotation block from Image->Probe transform.
T_image_probe = transformations(imageToProbeIndex).Matrix;
R_image_probe_raw = T_image_probe(1:3, 1:3);
% Decompose the raw matrix with SVD to separate rotation part and scale part.
[U_image_probe, ~, V_image_probe] = svd(R_image_probe_raw);
% Build the closest orthogonal rotation (minimum Frobenius error).
R_image_probe = U_image_probe * V_image_probe';
% If determinant is negative, flip the last axis to enforce a proper right-handed rotation (det = +1).
if det(R_image_probe) < 0
    U_image_probe(:, 3) = -U_image_probe(:, 3);
    R_image_probe = U_image_probe * V_image_probe';
end
% Rebuild the rigid calibration and independently retain the physical scale
% encoded by the original rotation-scale columns.
T_image_probe(1:3, 1:3) = R_image_probe;
S_image_probe = vecnorm(R_image_probe_raw, 2, 1);

%% PREPARE ONE ULTRASOUND PLANE RECORD PER REQUIRED PACKET
% Each valid ultrasound packet becomes a finite rectangular plane in ref.
% Static mode keeps the established behavior and omits packets with invalid
% probe/reference tracking. Kinematic mode keeps every time index and marks an
% unusable packet so later records never shift away from their CSV row.
%
% The finite plane is parameterized as:
%   point_ref = p0 + u*ex + v*ey
% where 0 <= u <= W and 0 <= v <= H. ex and ey are unit directions in ref,
% n is the plane normal, and p0 is the image origin in ref.

% Use NaN geometry in the template because zero would look like a valid pose
% at the ref origin. Metadata and raw images can still be filled for invalid
% kinematic records, while isValid tells later code whether geometry is usable.
planeTemplate = struct( ...
    'sourceIndex', 0, ...                  % Raw acquisition index inside this source group.
    'T_image_ref', nan(4, 4), ...          % Rigid transform mapping image coordinates into ref.
    'p0', nan(3, 1), ...                   % Image-plane origin expressed in ref.
    'ex', nan(3, 1), ...                   % Unit direction of increasing image columns in ref.
    'ey', nan(3, 1), ...                   % Unit direction of increasing image rows in ref.
    'n', nan(3, 1), ...                    % Image-plane normal expressed in ref.
    'W', 0, ...                            % Physical image width from pixel count and spacing.
    'H', 0, ...                            % Physical image height from pixel count and spacing.
    'nRows', 0, ...                        % Image row count expected by rasterization helpers.
    'nCols', 0, ...                        % Image column count expected by rasterization helpers.
    'image', uint8([]), ...                % Original ultrasound pixels from the MHA packet.
    'timestamp', 0, ...                    % Timestamp stored in the MHA packet.
    'rigidBodyTimestamp', 0, ...           % Timestamp from the paired CSV row.
    'bone', 'U', ...                       % F, T, or U classification inherited from the folder.
    'snapshotName', '', ...                % Source-folder name used by the later browser.
    'snapshotIndex', 0, ...                % Stable outer source-group index.
    'sequenceIndex', 0, ...                % MHA/CSV pair index inside the source group.
    'packetIndex', 0, ...                  % Original packet position inside the MHA file.
    'rigidBodyRowIndex', 0, ...            % Matching row position inside the CSV file.
    'isValid', false, ...                  % True only when plane geometry can be used.
    'status', 'Not prepared');             % Human-readable reason for success or failure.

% snapshotPlanes mirrors the acquisition-folder hierarchy. Keeping this outer
% grouping makes equally numbered sourceIndex values safe in different folders.
planeGroupTemplate = struct( ...
    'name', '', 'bone', 'U', 'path', '', ...
    'data', repmat(planeTemplate, 1, 0));
snapshotPlanes = repmat(planeGroupTemplate, 1, numel(sourceGroups));

% Keep the override local, like the working script. An empty value uses the
% packet's own Reference-to-Tracker transform. If an experiment was recorded
% without a tracked reference, a known T_ref_global may be supplied here.
% The name follows the project convention: it maps ref-frame points to global.
T_ref_global_override = [];

% Outer plane-preparation loop:
% Process one source group at a time and build its complete array of ultrasound
% planes. Working group-by-group preserves the folder hierarchy required by
% snapshotPlanes and by the later visualization workflow.
for snapshotIndex = 1:numel(sourceGroups)

    currentGroup = sourceGroups(snapshotIndex);
    groupPlanes  = repmat(planeTemplate, 1, 0);
    % sourceIndex counts raw packets across all file pairs in this folder. It
    % advances even when static mode later omits an invalid packet.
    sourceIndex  = 0;

    % Middle sequence-pair loop for the current source group:
    % Visit every validated MHA/CSV pair. A static folder may contain several
    % one-frame pairs, while a kinematic folder normally contains one pair with
    % many synchronized packets and rows.
    for sequenceIndex = 1:numel(currentGroup.sequencePairs)
        currentPair = currentGroup.sequencePairs(sequenceIndex);

        % Inner packet loop for the current MHA/CSV pair:
        % Convert every MHA packet into one plane record and attach metadata from
        % the CSV row at the identical packetIndex. This loop also applies the
        % different static-versus-kinematic invalid-record retention policy.
        for packetIndex = 1:numel(currentPair.sequence.packets)
            sourceIndex = sourceIndex + 1;
            currentPacket = currentPair.sequence.packets(packetIndex);

            % Build metadata before checking validity so kinematic invalid rows
            % still carry the exact indices needed to find their bone pose.
            currentPlane = planeTemplate;
            currentPlane.sourceIndex        = sourceIndex;
            currentPlane.image              = currentPacket.Image;
            currentPlane.timestamp          = currentPacket.Timestamp;
            currentPlane.rigidBodyTimestamp = currentPair.rigidBodies.Timestamps(packetIndex);
            currentPlane.bone               = currentGroup.bone;
            currentPlane.snapshotName       = currentGroup.name;
            currentPlane.snapshotIndex      = snapshotIndex;
            currentPlane.sequenceIndex      = sequenceIndex;
            currentPlane.packetIndex        = packetIndex;
            currentPlane.rigidBodyRowIndex  = packetIndex;
            % The MHA reader stores image memory as [width, height]. The
            % intersection interface names the second dimension nRows and the
            % first dimension nCols, matching the established workflow.
            currentPlane.nRows              = size(currentPacket.Image, 2);
            currentPlane.nCols              = size(currentPacket.Image, 1);
            % Pixel centers span count-1 intervals. Multiplying those intervals
            % by the fCal spacing gives the physical finite-plane dimensions.
            if ~isempty(currentPacket.Image)
                currentPlane.W = (size(currentPacket.Image, 1) - 1) * S_image_probe(1);
                currentPlane.H = (size(currentPacket.Image, 2) - 1) * S_image_probe(2);
            end

            % Static mode intentionally follows the old tracking-status checks.
            % Kinematic mode additionally records image validity because every
            % time index remains present even when geometry cannot be prepared.
            % A status flag is the acquisition system's validity decision. The
            % finite check additionally prevents a status marked OK from sending
            % NaN coordinates into matrix division and intersection geometry.
            isProbeValid = currentPacket.ProbeToTrackerDeviceTransformStatus && ...
                           all(isfinite(currentPacket.ProbeToTrackerDeviceTransform(:)));
            % Normally the ref pose comes from the same MHA packet as the probe.
            % An explicit override replaces that measurement for every packet.
            if isempty(T_ref_global_override)
                isReferenceValid = currentPacket.ReferenceToTrackerDeviceTransformStatus && ...
                                   all(isfinite(currentPacket.ReferenceToTrackerDeviceTransform(:)));
                T_ref_global     = currentPacket.ReferenceToTrackerDeviceTransform;
            else
                isReferenceValid = all(isfinite(T_ref_global_override(:)));
                T_ref_global     = T_ref_global_override;
            end
            isImageValid = currentPacket.ImageStatus && ~isempty(currentPacket.Image);

            % Assign only the first blocking reason. The record still retains
            % its timestamps and indices, which is essential in perDataRow mode.
            if ~isProbeValid
                currentPlane.status = 'Invalid: probe transform is unavailable.';
            elseif ~isReferenceValid
                currentPlane.status = 'Invalid: reference transform is unavailable.';
            elseif processingMode == "kinematic" && ~isImageValid
                currentPlane.status = 'Invalid: ultrasound image is unavailable.';
                
            else
                % Transform propagation from image coordinates to ref:
                %
                %   T_probe_global maps probe -> global.
                %   T_ref_global   maps ref   -> global.
                %
                % We need probe -> ref. Solving
                %   T_ref_global * T_probe_ref = T_probe_global
                % gives the left-division expression below. It is equivalent to
                % inv(T_ref_global)*T_probe_global but avoids an explicit inverse.
                T_probe_global = currentPacket.ProbeToTrackerDeviceTransform;
                T_probe_ref    = T_ref_global \ T_probe_global;

                % T_image_probe maps image -> probe. Compose right to left:
                % image -> probe -> ref. This produces the final image pose in
                % the same ref coordinates later used for the CT bone mesh.
                T_image_ref    = T_probe_ref * T_image_probe;

                % A homogeneous transform stores axis directions in columns
                % 1:3 and the transformed origin in column 4. Copy these values
                % into the finite-plane interface used by the geometry helpers.
                currentPlane.T_image_ref = T_image_ref;
                currentPlane.p0          = T_image_ref(1:3, 4);
                currentPlane.ex          = T_image_ref(1:3, 1);
                currentPlane.ey          = T_image_ref(1:3, 2);
                currentPlane.n           = T_image_ref(1:3, 3);
                currentPlane.isValid     = true;
                currentPlane.status = 'Valid';
            end

            % Invalid static tracking records are omitted, while all kinematic
            % records are appended in their original acquisition order.
            if processingMode == "kinematic" || currentPlane.isValid
                groupPlanes(end + 1) = currentPlane; %#ok<SAGROW>
            end
        end
    end

    % Copy group metadata beside the completed plane array. Empty groups are
    % intentionally retained so group indices do not change between stages.
    snapshotPlanes(snapshotIndex).name = currentGroup.name;
    snapshotPlanes(snapshotIndex).bone = currentGroup.bone;
    snapshotPlanes(snapshotIndex).path = currentGroup.path;
    snapshotPlanes(snapshotIndex).data = groupPlanes;
end

%% LOAD THE CT BONES AND MATCH THEIR SELECTED PINS
% The CT post-processing result supplies three pieces needed here:
% - each bone surface, whose vertices are expressed in the CT frame;
% - T_bone_CT, which places the anatomical bone frame inside CT;
% - T_pin_CT for every scanned bone pin, which places that pin inside CT.
%
% coupleBonesAndPins groups each bone with its available pins and applies the
% configured pin choice. This avoids assuming femur/tibia or pin records occur
% in a fixed array order. The CT mesh stays in CT coordinates in stored output.
% A row-specific T_CT_ref will create a temporary ref-frame copy only when an
% intersection is calculated, avoiding one full duplicate mesh per time row.

% Load only the two promised variables so unrelated MAT-file contents cannot
% accidentally overwrite variables already prepared in this script.
loadedCtData = load(fullfile_bonectpostprocess, 'bonepins', 'bones');
if ~isfield(loadedCtData, 'bonepins') || ~isfield(loadedCtData, 'bones')
    error('build_ultrasoundBone_intersectionData_poseModes:MissingCtData', ...
         'The CT MAT file must contain both bones and bonepins.');
end
% Each returned unit contains one bone, all matching pins, and the index of the
% pin selected by pinSelection.F or pinSelection.T.
boneUnits = coupleBonesAndPins(loadedCtData.bones, loadedCtData.bonepins, pinSelection);

%% CALCULATE THE BONE POSE FROM EACH PAIRED CSV ROW
% This is the central rigid-transform section of the workflow.
%
% Qualisys measures both the reference object and the selected bone pin in its
% global tracking frame. For every CSV row i we first calculate:
%
%   T_pin_ref_i = T_ref_global_i \ T_pin_global_i
%
% This maps pin -> ref and removes global motion shared by the reference and
% pin. It must be calculated per row before average/first/last is applied.
% Averaging the two global trajectories separately would lose the paired
% rotational relationship when the reference moves.
%
% The CT scan already tells us how that same physical pin sits in CT through
% T_pin_CT. The transform chain is:
%
%   CT -> pin -> ref
%   T_CT_ref = T_pin_ref * inv(T_pin_CT)
%
% MATLAB right division expresses this as T_pin_ref / T_pin_CT. Finally,
% T_bone_ref = T_CT_ref * T_bone_CT maps the anatomical bone frame through CT
% into ref. Mesh vertices are CT-frame points, so they use T_CT_ref directly;
% T_bone_ref is for the anatomical coordinate axes, not for mesh vertices.

% Every per-row record uses the same fields. NaN transforms clearly distinguish
% an unavailable pose from a real identity transform.
poseDataTemplate = struct( ...
    'sourceIndex', 0, ...                  % Raw acquisition index inside one source group.
    'snapshotIndex', 0, ...                % Outer source-group index.
    'sequenceIndex', 0, ...                % MHA/CSV pair index inside the group.
    'packetIndex', 0, ...                  % Matching MHA packet index.
    'rigidBodyRowIndex', 0, ...            % Original row index in the paired CSV.
    'rigidBodyTimestamp', 0, ...           % CSV time used to choose first or last.
    'sourceSampleCount', 0, ...            % Number of raw poses represented by this record.
    'isValid', false, ...                  % True only when all three transforms are usable.
    'status', 'Not prepared', ...          % Explanation retained for invalid kinematic rows.
    'T_pin_ref', nan(4, 4), ...            % Selected tracked pin expressed in ref.
    'T_CT_ref', nan(4, 4), ...             % CT frame expressed in ref; used for mesh points.
    'T_bone_ref', nan(4, 4));              % Anatomical bone frame expressed in ref.

% Store the heavy CT mesh once per bone. The data array then remains small in
% perDataRow mode because it contains transforms rather than repeated meshes.
bonePoseTemplate = struct( ...
    'bone', '', ...
    'meshCT', [], ...
    'T_bone_CT', [], ...
    'data', repmat(poseDataTemplate, 1, 0));
% Keep the current public container name while recording the new mode. Static
% modes produce one data record per bone; perDataRow produces one per raw CSV
% row and preserves invalid records in place.
validBonePoses = struct( ...
    'processingMode', processingMode, ...
    'poseHandlingMode', bonePoseMode, ...
    'ctPostProcessedMatFile', string(fullfile_bonectpostprocess), ...
    'bonePoses', repmat(bonePoseTemplate, 1, numel(boneUnits)));

% Outer bone loop:
% Prepare one complete pose result for each coupled CT bone and selected pin.
% Femur and tibia are independent, so a missing pin measurement for one bone
% does not invalidate the other bone at the same acquisition time.
for boneIndex = 1:numel(boneUnits)

    currentUnit      = boneUnits(boneIndex);
    currentBone      = currentUnit.boneData;
    currentPin       = currentUnit.pins(currentUnit.selectedPinIndex);

    % Build the exact Qualisys table-variable name for the selected CT pin,
    % for example C_F_PRO or C_T_DIS.
    pinRigidBodyName = sprintf('C_%s_%s', currentUnit.bone, currentUnit.selectedPinPlace);
    allPoseRows      = repmat(poseDataTemplate, 1, 0);

    % Source-group loop for the current bone:
    % Collect this bone's selected-pin pose from every source folder. The stable
    % snapshotIndex becomes part of the composite key that later reconnects a
    % perDataRow bone pose to its ultrasound plane.
    for snapshotIndex = 1:numel(sourceGroups)

        currentGroup = sourceGroups(snapshotIndex);
        sourceIndex = 0;

        % Sequence-pair loop for the current bone and source group:
        % Visit each paired acquisition without flattening its file boundary.
        % This keeps sequenceIndex meaningful when a static folder contains
        % several independent snapshot pairs.
        for sequenceIndex = 1:numel(currentGroup.sequencePairs)
            currentPair = currentGroup.sequencePairs(sequenceIndex);

            % CSV-row loop for the current bone and acquisition pair:
            % Read the reference and selected-pin measurements from one row,
            % calculate their relative transform when both are valid, and append
            % one pose record containing the exact identity of this source row.
            for rowIndex = 1:height(currentPair.rigidBodies)

                sourceIndex     = sourceIndex + 1;

                % V02 returns one validity-aware struct in each table cell.
                % The reference and selected pin must both be valid to define
                % their relative rigid transform at this acquisition time.
                referenceRecord = currentPair.rigidBodies.B_N_REF{rowIndex};
                pinRecord       = currentPair.rigidBodies.(pinRigidBodyName){rowIndex};

                currentPose = poseDataTemplate;
                currentPose.sourceIndex        = sourceIndex;
                currentPose.snapshotIndex      = snapshotIndex;
                currentPose.sequenceIndex      = sequenceIndex;
                currentPose.packetIndex        = rowIndex;
                currentPose.rigidBodyRowIndex  = rowIndex;
                currentPose.rigidBodyTimestamp = currentPair.rigidBodies.Timestamps(rowIndex);

                % Preserve invalid rows with their provenance instead of
                % inventing a pose or allowing NaNs into matrix operations.
                if ~referenceRecord.isValid
                    currentPose.status = 'Invalid: CSV reference pose is unavailable.';
                elseif ~pinRecord.isValid
                    currentPose.status = sprintf('Invalid: CSV pin pose %s is unavailable.', pinRigidBodyName);
                else
                    % Both inputs map their local frames into the same global
                    % tracking frame. Left division cancels that shared target
                    % frame and expresses the pin relative to ref.
                    T_ref_global = referenceRecord.T;
                    T_pin_global = pinRecord.T;
                    T_pin_ref    = T_ref_global \ T_pin_global;

                    % Use the CT-observed pin as the bridge from CT to ref.
                    % Right division is equivalent to multiplying by the rigid
                    % inverse of T_pin_CT, but is numerically clearer and safer.
                    T_CT_ref     = T_pin_ref / currentPin.T_pin_CT;

                    % Compose CT -> ref after bone -> CT so the anatomical bone
                    % frame is expressed in the same ref frame as ultrasound.
                    T_bone_ref   = T_CT_ref * currentBone.T_bone_CT;

                    currentPose.T_pin_ref         = T_pin_ref;
                    currentPose.T_CT_ref          = T_CT_ref;
                    currentPose.T_bone_ref        = T_bone_ref;
                    currentPose.sourceSampleCount = 1;
                    currentPose.isValid           = true;
                    currentPose.status            = 'Valid';
                end
                % Append every raw row. Reduction is deliberately postponed
                % until all groups have contributed their relative poses.
                allPoseRows(end + 1) = currentPose; %#ok<SAGROW>
            end
        end
    end

    % Keep validity as an explicit index list. Static modes reduce only valid
    % relative poses, while perDataRow returns all rows in their original order.
    validPoseIndices = find([allPoseRows.isValid]);

    % Static reduction cannot produce a pose without at least one valid
    % sample. Kinematic mode may keep an entirely invalid bone series because
    % preserving every time index is more important than forcing a transform.
    if processingMode == "static" && isempty(validPoseIndices)
        error('build_ultrasoundBone_intersectionData_poseModes:NoValidBonePose', ...
              'No valid relative pose is available for bone %s.', currentUnit.bone);
    end

    % Apply only the requested pose-handling policy. All four modes share the
    % same per-row transform calculation above, which avoids separate static
    % and kinematic geometry implementations.
    if bonePoseMode == "perDataRow"
        % No reduction is performed. data(k) continues to describe the same
        % acquisition as MHA packet k and CSV row k, including invalid rows.
        selectedPoseData = allPoseRows;
        
    elseif bonePoseMode == "average"
        % Average relative pin-to-ref poses, never the two global trajectories.
        % Translation can use an arithmetic mean. Rotation is converted to
        % scalar-first MATLAB quaternions and averaged with meanrot so wraparound
        % at +/-180 degrees is handled as rotation rather than four raw numbers.
        selectedPoseData = poseDataTemplate;
        validPoses       = allPoseRows(validPoseIndices);
        quaternionRows   = zeros(numel(validPoses), 4);
        translationRows  = zeros(numel(validPoses), 3);
        
        % Valid-pose averaging loop:
        % Extract one rotation quaternion and one translation vector from every
        % valid per-row T_pin_ref. The arrays filled by this loop are averaged
        % afterward so rotation and translation treatment stays explicit.
        for validIndex = 1:numel(validPoses)
            quaternionRows(validIndex, :)  = rotm2quat(validPoses(validIndex).T_pin_ref(1:3, 1:3));
            translationRows(validIndex, :) = validPoses(validIndex).T_pin_ref(1:3, 4).';
        end
        
        % meanrot returns one representative orientation on the rotation
        % manifold. compact converts it back to [w x y z] for quat2rotm.
        meanQuaternion = meanrot(quaternion(quaternionRows));

        % Reassemble one proper 4x4 mean relative transform, then propagate it
        % through the same CT-pin and anatomical-bone chain used per row.
        T_pin_ref = eye(4);
        T_pin_ref(1:3, 1:3) = quat2rotm(compact(meanQuaternion));
        T_pin_ref(1:3, 4)   = mean(translationRows, 1).';

        % Store some necessary values
        selectedPoseData.T_pin_ref         = T_pin_ref;
        selectedPoseData.T_CT_ref          = T_pin_ref / currentPin.T_pin_CT;
        selectedPoseData.T_bone_ref        = selectedPoseData.T_CT_ref * currentBone.T_bone_CT;
        selectedPoseData.sourceSampleCount = numel(validPoses);
        selectedPoseData.isValid           = true;
        selectedPoseData.status            = sprintf('Valid: averaged %d relative pose(s).', numel(validPoses));

    else
        % CSV time defines first and last across all source folders. min/max
        % returns the first occurrence when two valid samples share a timestamp.
        % Invalid literal endpoints are not candidates, so "first" and "last"
        % mean the earliest/latest valid relative pose for this particular bone.
        validTimestamps = [allPoseRows(validPoseIndices).rigidBodyTimestamp];
        if bonePoseMode == "first"
            [~, endpointIndex] = min(validTimestamps);
        else
            [~, endpointIndex] = max(validTimestamps);
        end
        selectedPoseData = allPoseRows(validPoseIndices(endpointIndex));
    end

    % Static reduction can safely ignore individual missing Qualisys poses, but
    % report their count so the user knows how much data contributed. Kinematic
    % mode keeps those rows and their per-row status, so no summary warning is
    % needed here.
    numberOfInvalidPoses = numel(allPoseRows) - numel(validPoseIndices);
    if processingMode == "static" && numberOfInvalidPoses > 0
        warning('build_ultrasoundBone_intersectionData_poseModes:SkippedInvalidPoses', ...
                'Skipped %d invalid pose sample(s) for bone %s.', ...
                numberOfInvalidPoses, currentUnit.bone);
    end

    % Store the source CT geometry once and the selected pose record or series
    % beside it. A later visualization can reconstruct any ref-frame mesh with
    % applyRigidTransform(meshCT.Points, data(k).T_CT_ref).
    validBonePoses.bonePoses(boneIndex).bone      = char(currentUnit.bone);
    validBonePoses.bonePoses(boneIndex).meshCT    = currentBone.mesh;
    validBonePoses.bonePoses(boneIndex).T_bone_CT = currentBone.T_bone_CT;
    validBonePoses.bonePoses(boneIndex).data      = selectedPoseData;
end

%% COMPUTE INTERSECTIONS WITH THE MATCHING BONE POSE
% An intersection is meaningful only when the ultrasound plane and bone mesh
% are expressed in the same coordinate frame. Every plane above is in ref, so
% this section transforms the matching CT mesh into ref before calling the
% shared 2D/3D geometry helpers.
%
% Static modes reuse their one reduced pose for every plane of that bone.
% Kinematic mode finds the pose with the same source indices as the selected
% packet. Invalid rows remain aligned and receive an explanatory skipped status.

% A mesh face is considered probe-facing when its normal lies within this
% angular tolerance of the direction used by the established selection helper.
normalFacingToleranceDeg = 25;

% Keep raw intersections and the probe-facing subset. Empty fields are valid
% results when no surface crosses the finite image plane; isValid distinguishes
% a completed calculation from a row skipped before geometry was attempted.
intersectionTemplate = struct( ...
    'mask', [], ...                         % Binary mask of all rasterized hit pixels.
    'pixelList', [], ...                    % Raw hit pixels stored as [row, column].
    'segments3D', {{}}, ...                 % Mesh/plane line segments expressed in ref.
    'segmentsUV', {{}}, ...                 % The same segments in image-plane distances.
    'segmentFaceIdx', [], ...               % Mesh face that generated each segment.
    'probeFacingSegmentMask', [], ...       % Raw segments passing the facing test.
    'probeFacingSegments3D', {{}}, ...      % Facing segment subset in ref coordinates.
    'probeFacingSegmentsUV', {{}}, ...      % Facing segment subset in plane coordinates.
    'probeFacingPixels', [], ...            % Rasterized pixels from facing segments.
    'segmentFacingScore', [], ...           % Facing score aligned with raw segments.
    'timestamp', [], ...                    % Copy of the source MHA timestamp.
    'isValid', false, ...                   % True after geometry completes successfully.
    'status', 'Not computed');              % Computed or a clear skip explanation.

% The intersections hierarchy mirrors snapshotPlanes exactly. Consequently,
% snapshotPlanes(g).data(k) and intersections(g).data(k) always refer to the
% same retained acquisition record.
intersectionGroupTemplate = struct( ...
    'name', '', 'bone', 'U', 'path', '', ...
    'data', repmat(intersectionTemplate, 1, 0));
intersections = repmat(intersectionGroupTemplate, 1, numel(snapshotPlanes));

% Bone codes provide a stable lookup without assuming femur is item 1 or tibia
% is item 2 in the CT MAT file.
boneCodes = {validBonePoses.bonePoses.bone};

% Outer intersection-group loop:
% Visit every ultrasound source group and create a result group with identical
% metadata and length. Completing one group at a time preserves alignment even
% when the source group is empty.
for groupIndex = 1:numel(snapshotPlanes)

    currentPlaneGroup = snapshotPlanes(groupIndex);

    % Copy outer metadata and preallocate one result per retained plane before
    % performing the more expensive mesh intersection calculations.
    intersections(groupIndex).name = currentPlaneGroup.name;
    intersections(groupIndex).bone = currentPlaneGroup.bone;
    intersections(groupIndex).path = currentPlaneGroup.path;
    intersections(groupIndex).data = repmat(intersectionTemplate, 1, numel(currentPlaneGroup.data));

    % Inner plane-intersection loop for the current source group:
    % For each retained plane, find the correct static or per-row bone pose,
    % transform the CT mesh into ref, compute the intersection, and store the
    % result at the identical group-local planeIndex.
    for planeIndex = 1:numel(currentPlaneGroup.data)
        currentPlane        = currentPlaneGroup.data(planeIndex);
        currentIntersection = intersectionTemplate;

        % Initialize the timestamp even for skipped rows so the reason remains
        % traceable to the original ultrasound acquisition.
        currentIntersection.timestamp = currentPlane.timestamp;

        % A plane without a valid pose cannot define 3D geometry in ref. Keep
        % its aligned result slot and carry the plane's reason forward.
        if ~currentPlane.isValid
            currentIntersection.status = ['Skipped: ' currentPlane.status];
            intersections(groupIndex).data(planeIndex) = currentIntersection;
            continue;
        end

        % Select the CT bone named by the source folder. Unknown folders stay in
        % the results but cannot be intersected with an arbitrary anatomy.
        boneIndex = find(strcmp(boneCodes, currentPlane.bone), 1);
        if isempty(boneIndex)
            currentIntersection.status = sprintf('Skipped: no CT bone for code "%s".', currentPlane.bone);
            intersections(groupIndex).data(planeIndex) = currentIntersection;
            continue;
        end

        % get the current bone pose
        currentBonePose = validBonePoses.bonePoses(boneIndex);

        if processingMode == "static"
            % average, first, and last each produce exactly one pose for this
            % bone, which is intentionally reused for all static snapshots.
            poseData = currentBonePose.data;

        else
            % perDataRow stores a flat pose series per bone. Match the complete
            % source identity rather than an array position because sourceIndex
            % starts again inside every source folder.
            poseCandidates = currentBonePose.data;
            poseMatch = [poseCandidates.snapshotIndex] == currentPlane.snapshotIndex & ...
                        [poseCandidates.sequenceIndex] == currentPlane.sequenceIndex & ...
                        [poseCandidates.rigidBodyRowIndex] == currentPlane.rigidBodyRowIndex;
            poseIndex = find(poseMatch, 1);

            % This should not occur after successful packet/row validation, but
            % retaining the result slot keeps output alignment understandable.
            if isempty(poseIndex)
                currentIntersection.status = 'Skipped: matching bone pose was not found.';
                intersections(groupIndex).data(planeIndex) = currentIntersection;
                continue;
            end            
            poseData = poseCandidates(poseIndex);
        end

        % The plane can be valid while this bone pin was missing in Qualisys.
        % In that case geometry is skipped only for this bone and time row.
        if ~poseData.isValid
            currentIntersection.status = ['Skipped: ' poseData.status];
            intersections(groupIndex).data(planeIndex) = currentIntersection;
            continue;
        end

        % Mesh vertices are CT-frame points. Apply T_CT_ref—not T_bone_ref—to
        % map every vertex into ref. T_bone_ref describes anatomical axes and
        % would incorrectly treat CT vertices as bone-frame coordinates.
        bonePointsRef = applyRigidTransform(currentBonePose.meshCT.Points, poseData.T_CT_ref);

        % meshPlaneIntersectionPixels expects a lightweight struct with V and F.
        % Reuse CT connectivity because a rigid transform moves vertices without
        % changing which vertices form each triangular face.
        currentMesh = struct( ...
            'V', bonePointsRef, ...
            'F', currentBonePose.meshCT.ConnectivityList);

        % Intersect the transformed triangular surface with the finite image
        % rectangle. The helper returns both reference-frame segments and their
        % image-plane UV representation for later 3D and 2D visualization.
        [mask, pixelList, segments3D, segmentsUV, segmentFaceIdx] = ...
            meshPlaneIntersectionPixels(currentMesh, currentPlane);

        % Convert physical plane distances into pixel steps using the same
        % convention as the established intersection workflow.
        du = currentPlane.W / currentPlane.nCols;
        dv = currentPlane.H / currentPlane.nRows;

        % Retain the complete raw result, then identify the subset generated by
        % mesh faces oriented toward the probe within the configured tolerance.
        [probeFacingSegmentMask, probeFacingSegments3D, ...
            probeFacingSegmentsUV, probeFacingPixels, segmentFacingScore] = ...
            selectProbeFacingIntersectionSegments( ...
                currentMesh, segments3D, segmentsUV, segmentFaceIdx, ...
                currentPlane, du, dv, currentPlane.nRows, ...
                currentPlane.nCols, normalFacingToleranceDeg);

        % Copy all calculated outputs into the result record only after both
        % geometry steps finish, then mark this aligned row as computed.
        currentIntersection.mask = mask;
        currentIntersection.pixelList              = pixelList;
        currentIntersection.segments3D             = segments3D;
        currentIntersection.segmentsUV             = segmentsUV;
        currentIntersection.segmentFaceIdx         = segmentFaceIdx;
        currentIntersection.probeFacingSegmentMask = probeFacingSegmentMask;
        currentIntersection.probeFacingSegments3D  = probeFacingSegments3D;
        currentIntersection.probeFacingSegmentsUV  = probeFacingSegmentsUV;
        currentIntersection.probeFacingPixels      = probeFacingPixels;
        currentIntersection.segmentFacingScore     = segmentFacingScore;
        currentIntersection.isValid                = true;
        currentIntersection.status                 = 'Computed';

        intersections(groupIndex).data(planeIndex) = currentIntersection;
    end
end

%% DISPLAY THE PREPARED STATIC OR KINEMATIC RESULTS
% Open the sequence-aware browser only after every aligned intersection record
% has been prepared. The browser reads validBonePoses.poseHandlingMode itself:
% - average, first, and last keep the established single-mesh static display;
% - perDataRow reconstructs the mesh belonging to the selected table row and
%   adds the valid row-1 baseline when the selected time is later than row 1.
%
% Display mode is intentionally non-blocking. The script therefore finishes
% and leaves all prepared variables available while the browser remains open.
figIntersectionBrowser = displaySnapshotSequenceIntersectionBrowser( ...
    snapshotPlanes, intersections, validBonePoses, ...
    'Mode', 'review', ...
    'OutputDirectory', ultrasoundIntersectionOutputPath);

fprintf(['Preparation complete: snapshotPlanes, intersections, ' ...
    'validBonePoses, and figIntersectionBrowser are available in the workspace.\n']);
