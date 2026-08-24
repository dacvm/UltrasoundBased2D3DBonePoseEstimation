function data = prepareBonePoseOptimizationInputs_discreteFrames(config)
%PREPAREBONEPOSEOPTIMIZATIONINPUTS_DISCRETEFRAMES Load selected one-frame .mha files for optimization.
% This function prepares the same data struct as prepareBonePoseOptimizationInputs, but it reads
% already-selected discrete frame files instead of sampling packets from long sequence recordings.
%
% Main difference from prepareBonePoseOptimizationInputs:
%   Each .mha file in config.input.sequenceFolder is expected to contain exactly one frame.
%   The frame is used directly as one image plane, so no packet sampling and no transform smoothing are needed.

%% HANDLE OPTIONAL CONFIGURATION

% Create default discrete-frame settings when the caller does not provide a configuration struct.
if nargin < 1 || isempty(config)
    config = createBonePoseOptimizationConfig(fullfile(pwd, 'config', 'bonePoseOptimizationConfig_discreteFrames.json'));
end

%% LOAD ULTRASOUND CALIBRATION

% Build the absolute path to the fCal XML file that stores the Image-to-Probe transform.
fcalConfigPath  = fullfile(config.project.root, 'data', config.input.fcalFilename);
% Read all calibration transforms from the XML file using the existing project helper.
transformations = read_fcal_transforms(fcalConfigPath);

% Use the first transform because the validation script treats it as Image-to-Probe calibration.
T_image_probecalib = transformations(1).Matrix;
% Extract the raw rotation-scale block so we can split rotation from pixel scaling.
R_image_probe_raw  = T_image_probecalib(1:3, 1:3);
% Use SVD to find the closest pure rotation to the raw calibration block.
[U_image_probe, ~, V_image_probe] = svd(R_image_probe_raw);
% Build the orthogonal rotation that preserves the calibration direction as closely as possible.
R_image_probe_orth = U_image_probe * V_image_probe';

% Flip the last axis only when needed so the rotation stays right-handed.
if det(R_image_probe_orth) < 0
    % Flip one singular vector so the repaired rotation has determinant +1.
    U_image_probe(:, 3) = -U_image_probe(:, 3);
    % Rebuild the orthogonal rotation after the handedness correction.
    R_image_probe_orth = U_image_probe * V_image_probe';
end

% Replace the scaled block with the pure rotation so downstream transforms are rigid.
T_image_probecalib(1:3, 1:3) = R_image_probe_orth;
% Store the original column norms as pixel spacing values used to size image planes.
S_image_probecalib = vecnorm(R_image_probe_raw, 2, 1);

%% DISCOVER DISCRETE FRAME FILES

% Find only .mha files directly inside the configured folder so the folder itself defines the selected frames.
sequenceFiles = dir(fullfile(config.input.sequenceFolder, '*.mha'));
% Read the filenames into a cell array so MATLAB can sort them repeatably.
sequenceFileNames = {sequenceFiles.name};
% Sort by filename and keep only the index order because the dir structs still hold the names.
[~, sortIndex] = sort(sequenceFileNames);
% Apply the filename sort order to the dir structs so folder metadata stays aligned with each file.
sequenceFiles = sequenceFiles(sortIndex);

% Stop early when the selected-frame folder does not contain any sequence files.
if isempty(sequenceFiles)
    error('prepareBonePoseOptimizationInputs_discreteFrames:NoSequenceFiles', ...
        'No .mha files were found in the selected-frame folder: %s', config.input.sequenceFolder);
end

% Print a progress message when requested because reading many selected frames can still take time.
if config.logging.printPreparationProgress
    fprintf('Preparing %d discrete frame files for optimization...\n', numel(sequenceFiles));
end

%% COLLECT 2D IMAGE PLANES

% Create an empty plane struct array with all fields needed by the intersection helpers.
planes = repmat(struct('p0', [], 'ex', [], 'ey', [], 'n', [], ...
                       'W', 0, 'H', 0, 'nRows', 0, 'nCols', 0, ...
                       'image', [], 'timestamp', 0), 1, 0);

% Start the output index at one because MATLAB arrays use one-based indexing.
plane_index = 1;

% Loop over each selected one-frame sequence file.
for index_file = 1:numel(sequenceFiles)
    % Build the full path for the current selected-frame file.
    sequencePath = fullfile(sequenceFiles(index_file).folder, sequenceFiles(index_file).name);

    % Read and validate the current one-frame file without stopping the whole run for a bad file.
    [isValidFrame, current_packet, skipReason] = readAndValidateDiscreteFrame(sequencePath);

    % Skip invalid files with a warning so the user can fix the folder while still using valid frames.
    if ~isValidFrame
        warning('prepareBonePoseOptimizationInputs_discreteFrames:SkippedFrame', ...
            'Skipping %s: %s', sequenceFiles(index_file).name, skipReason);
        continue;
    end

    % Read the raw probe pose in the tracker frame because discrete frames are already selected.
    T_global_probe = current_packet.ProbeToTrackerDeviceTransform;
    % Read the raw reference pose in the tracker frame because no temporal smoothing is applied.
    T_global_ref   = current_packet.ReferenceToTrackerDeviceTransform;

    % Express the probe pose in the reference frame without forming an explicit matrix inverse.
    T_probe_ref = T_global_ref \ T_global_probe;
    % Build the image plane pose in the reference frame using the calibration transform.
    T_image_ref = T_probe_ref * T_image_probecalib;

    % Read the image origin in the reference frame.
    origin    = T_image_ref(1:3, 4);
    % Read the image basis axes in the reference frame.
    base_axes = T_image_ref(1:3, 1:3);

    % Store the finite plane geometry and image data in the same layout as prepareBonePoseOptimizationInputs.
    plane.p0        = origin;                                                       % Top-left point of the finite image plane.
    plane.ex        = base_axes(:, 1);                                              % Physical direction of increasing image column.
    plane.ey        = base_axes(:, 2);                                              % Physical direction of increasing image row.
    plane.n         = base_axes(:, 3);                                              % Physical normal direction of the image plane.
    plane.W         = (size(current_packet.Image, 1) - 1) * S_image_probecalib(1);  % Physical image width.
    plane.H         = (size(current_packet.Image, 2) - 1) * S_image_probecalib(2);  % Physical image height.
    plane.nRows     = size(current_packet.Image, 2);                                % Number of image rows.
    plane.nCols     = size(current_packet.Image, 1);                                % Number of image columns.
    plane.image     = current_packet.Image;                                         % Raw image so the cost function can sample intensity values.
    plane.timestamp = current_packet.Timestamp;                                     % Timestamp so outputs can be traced back to the source packet.

    % Append the current plane to the output array.
    planes(plane_index) = plane;

    % Move to the next output slot.
    plane_index = plane_index + 1;

    % Print the filename when requested so long preparations are easier to follow.
    if config.logging.printPreparationProgress
        fprintf('%s prepared.\n', sequenceFiles(index_file).name);
    end
end

% Stop before later geometry work when every selected-frame file was skipped.
if isempty(planes)
    error('prepareBonePoseOptimizationInputs_discreteFrames:NoValidPlanes', ...
        'No valid one-frame image planes were collected from: %s', config.input.sequenceFolder);
end

%% LOAD ACS DATA

% Build the full path to the femur ACS MAT file.
acs_path = fullfile(config.project.root, 'data', 'bones', config.input.acsFilename);
% Load the ACS file into a struct so variable names can be checked safely.
acs_loaded = load(acs_path);

% Use the expected acs variable when it exists.
if isfield(acs_loaded, 'acs')
    % Read the named ACS variable used by the current project data files.
    acs = acs_loaded.acs;
else
    % Fall back to the first saved variable so the helper is robust to minor MAT-file name changes.
    acs_fields = fieldnames(acs_loaded);
    % Read the first available variable as the ACS data.
    acs = acs_loaded.(acs_fields{1});
end

% Build the femur transform from the ACS convention used by the RadboudUMC function.
T_femurct_originct = [acs.f.R', acs.f.origin'; 0 0 0 1];

%% LOAD MANUAL INITIAL POSE

% Build the full path to the manual adjustment file used as the current initial alignment.
manualadjustment_path = fullfile(config.project.root, 'output', 'manual_transformation_adjustments', config.input.manualAdjustmentFilename);

% Load the manual transform file into a struct so the needed variable can be extracted explicitly.
manualadjustment_loaded = load(manualadjustment_path);
% Read the manual transform that moves the CT bone mesh close to the ultrasound image planes.
T_femurlabmanual_bonect = manualadjustment_loaded.T_femurlabmanual_bonect;

% Combine the original ACS transform and manual adjustment into the initial origin-CT pose.
T_init_originct         = T_femurlabmanual_bonect * T_femurct_originct;

%% LOAD MESH FILE

% Build the full path to the femur STL file.
stl_path = fullfile(config.project.root, 'data', 'bones', config.input.stlFilename);
% Read the femur mesh in its local CT coordinate frame.
[meshFaces, meshVerticesLocal] = readStlMesh(stl_path);

%% COMPUTE INITIAL-POSE INTERSECTION COUNTS

% Evaluate the initial manual pose once so the optimizer can compare later candidates against a fixed coverage baseline.
[referencePoseEvaluation, ~] = computeProbeFacingPixelsForPose( ...
                                meshVerticesLocal, ...
                                meshFaces, ...
                                planes, ...
                                T_init_originct, ...
                                config);

% Preallocate one initial-count slot per plane so the count vector stays aligned with data.planes.
n_initialIntersectionPixel = zeros(1, numel(referencePoseEvaluation));

% Loop through the initial-pose evaluation and count only the probe-facing pixels used by the cost function.
for idx_plane = 1:numel(referencePoseEvaluation)
    % Store the initial-pose selected-pixel count so the cost function can penalize tiny bright intersections.
    n_initialIntersectionPixel(idx_plane) = size(referencePoseEvaluation(idx_plane).probeFacingPixels, 1);
end

%% PACKAGE OUTPUT DATA

data.meshVerticesLocal          = meshVerticesLocal;            % Local vertices so optimization can re-transform the same source geometry for every candidate pose.
data.meshFaces                  = meshFaces;                    % Mesh faces because the topology does not change during rigid-pose optimization.
data.planes                     = planes;                       % Image planes because they are fixed observations during mesh-pose optimization.
data.T_init_originct            = T_init_originct;              % Current manual alignment as the starting pose for future optimization.
data.T_image_probecalib         = T_image_probecalib;           % Calibration transform for inspection and future extensions.
data.S_image_probecalib         = S_image_probecalib;           % Calibration spacing for inspection and future extensions.
data.n_initialIntersectionPixel = n_initialIntersectionPixel;   % Initial-pose per-plane counts used as the fixed coverage baseline by the cost function.
data.config                     = config;                       % Raw configuration with the data so future scripts can reproduce how it was prepared.

% Print the number of collected planes when requested so setup can be verified quickly.
if config.logging.printPreparationProgress
    fprintf('Collected %d discrete image planes for optimization.\n', numel(planes));
end
end


%% HELPER: READ AND VALIDATE ONE-FRAME FILE

function [isValidFrame, packet, reason] = readAndValidateDiscreteFrame(sequencePath)
%READANDVALIDATEDISCRETEFRAME Read one selected-frame file and explain why it should be skipped.
% This helper keeps the main plane-collection loop focused on successful plane construction.

% Start with safe defaults so every early return has predictable outputs.
isValidFrame = false;
% Return an empty packet when validation fails before a packet can be trusted.
packet = [];

% Try to parse the file because a malformed MHA should skip only that one selected frame.
try
    % Use the existing PLUS sequence reader so the discrete path follows the same file format support.
    sequence = read_sequence_image(sequencePath);
catch readError
    % Report the reader error message as the skip reason.
    reason = readError.message;
    % Return invalid status so the caller can warn and continue.
    return;
end

% Require DimSize because it tells us whether the file truly has one selected frame.
if ~isfield(sequence, 'header') || ~isfield(sequence.header, 'DimSize') || numel(sequence.header.DimSize) < 3
    % Explain that the file is missing the frame-count metadata needed for validation.
    reason = 'header.DimSize is missing or does not contain a frame count';
    % Return invalid status so the caller can warn and continue.
    return;
end

% Read the declared frame count as a double so numeric class differences do not matter.
n_packet = double(sequence.header.DimSize(3));

% Require exactly one frame because these files should already be the selected frame subset.
if n_packet ~= 1
    % Explain the declared frame count so the user can spot a long sequence accidentally placed in the folder.
    reason = sprintf('expected exactly 1 frame but DimSize(3) is %g', n_packet);
    % Return invalid status so the caller can warn and continue.
    return;
end

% Require one parsed packet because the image-plane code needs packet-level metadata and image data.
if ~isfield(sequence, 'packets') || numel(sequence.packets) ~= 1
    % Explain that the parsed packet count does not match the required one-frame file shape.
    reason = 'the parsed packet list does not contain exactly one packet';
    % Return invalid status so the caller can warn and continue.
    return;
end

% Read the only packet after the frame-count checks have passed.
packet = sequence.packets(1);

% Skip frames whose probe tracking was invalid because their image plane pose is not trustworthy.
if ~packet.ProbeToTrackerDeviceTransformStatus
    % Explain which status rejected the frame.
    reason = 'ProbeToTrackerDeviceTransformStatus is not OK';
    % Return invalid status so the caller can warn and continue.
    return;
end

% Skip frames whose reference tracking was invalid because the probe cannot be expressed in reference space.
if ~packet.ReferenceToTrackerDeviceTransformStatus
    % Explain which status rejected the frame.
    reason = 'ReferenceToTrackerDeviceTransformStatus is not OK';
    % Return invalid status so the caller can warn and continue.
    return;
end

% Skip frames whose image payload is marked invalid because the cost function needs real image intensities.
if ~packet.ImageStatus
    % Explain which status rejected the frame.
    reason = 'ImageStatus is not OK';
    % Return invalid status so the caller can warn and continue.
    return;
end

% Skip frames that have no decoded image because the finite plane size and cost image both depend on it.
if isempty(packet.Image)
    % Explain that the image bytes were missing or not decoded.
    reason = 'the image payload is empty';
    % Return invalid status so the caller can warn and continue.
    return;
end

% Require a valid 4-by-4 probe transform so the image plane can be placed in 3D.
if ~isValidTransform(packet.ProbeToTrackerDeviceTransform)
    % Explain that the probe transform itself was unusable.
    reason = 'ProbeToTrackerDeviceTransform is not a finite 4-by-4 matrix';
    % Return invalid status so the caller can warn and continue.
    return;
end

% Require a valid 4-by-4 reference transform so the probe can be expressed in reference space.
if ~isValidTransform(packet.ReferenceToTrackerDeviceTransform)
    % Explain that the reference transform itself was unusable.
    reason = 'ReferenceToTrackerDeviceTransform is not a finite 4-by-4 matrix';
    % Return invalid status so the caller can warn and continue.
    return;
end

% Mark the frame valid after every required metadata, image, and transform check passes.
isValidFrame = true;
% Store an empty reason because the caller should not warn for valid frames.
reason = '';
end


%% HELPER: VALIDATE TRANSFORM MATRIX

function isValid = isValidTransform(T)
%ISVALIDTRANSFORM Check that a parsed transform can safely be used in matrix math.
% This helper keeps repeated transform checks short and easy to read.

% A usable transform must be numeric, exactly 4-by-4, and contain only finite numbers.
isValid = isnumeric(T) && isequal(size(T), [4 4]) && all(isfinite(T(:)));
end
