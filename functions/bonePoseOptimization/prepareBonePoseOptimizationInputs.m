function data = prepareBonePoseOptimizationInputs(config)
%PREPAREBONEPOSEOPTIMIZATIONINPUTS Load reusable data for future bone-pose optimization.
% This function declaration separates slow data preparation from the repeated cost-function evaluation.
%
% What this function does:
%   This function prepares all fixed data needed before running a future
%   optimizer. It loads calibration, ultrasound image sequences, tracking
%   transforms, image planes, ACS data, manual initialization, and the femur
%   mesh. The result is one struct named data.
%
% Why this function exists:
%   Optimization will evaluate many candidate bone poses. We do not want to
%   reload files, smooth tracking transforms, or rebuild image planes every
%   time the cost function is called. This function does that slow setup
%   once, then stores the reusable result in data.
%
% Main output fields:
%   data.meshVerticesLocal:
%       Femur mesh vertices in the original local CT/STL coordinate system.
%       These vertices are kept local so every candidate pose can transform
%       the same unchanged source mesh.
%
%   data.meshFaces:
%       Triangle connectivity for the femur mesh. This does not change
%       during rigid-pose optimization.
%
%   data.planes:
%       Collection of 2D ultrasound image planes expressed in the reference
%       coordinate frame. Each plane also stores the raw image, dimensions,
%       physical axes, and timestamp.
%
%   data.T_init_originct:
%       Initial 4-by-4 transform built from ACS data and manual adjustment.
%       This is the starting pose used by the placeholder optimization code.
%
%   data.T_image_probecalib and data.S_image_probecalib:
%       Calibration transform and pixel scale information from the fCal XML
%       file. They are stored for debugging and future extensions.
%
% Coordinate-frame context:
%   The ultrasound image planes are expressed in the reference frame. The
%   mesh starts in its local CT coordinate frame, then data.T_init_originct
%   places it near those image planes. Later, optimization will adjust this
%   initial transform to better align the mesh with image features.
%
% Important details:
%   - This function prepares data only. It should not contain the optimizer.
%   - This function also avoids visualization, so it can be used by scripts
%     and cost functions without opening figures.
%   - If a setting should change between experiments, prefer editing the
%     JSON config file instead of editing this function.

%% HANDLE OPTIONAL CONFIGURATION

% Create default settings when the caller does not provide a configuration struct.
if nargin < 1 || isempty(config)
    config = createBonePoseOptimizationConfig();
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
    U_image_probe(:, 3) = -U_image_probe(:, 3);
    R_image_probe_orth = U_image_probe * V_image_probe';
end

% Replace the scaled block with the pure rotation so downstream transforms are rigid.
T_image_probecalib(1:3, 1:3) = R_image_probe_orth;
% Store the original column norms as pixel spacing values used to size image planes.
S_image_probecalib = vecnorm(R_image_probe_raw, 2, 1);

%% LOAD AND SMOOTH SEQUENCES

% Count sequence files once so the loop and storage are easy to read.
n_filename = numel(config.input.sequenceFilenames);

% Preallocate a cell array because each sequence can contain a different number of packets.
sequences = cell(1, n_filename);

% Print a progress message when requested because sequence parsing and smoothing may take time.
if config.logging.printPreparationProgress
    fprintf('Preparing sequence data for optimization...\n');
end

% Loop through every configured sequence recording.
for index_filename = 1:n_filename
    % Build the full sequence path from the shared folder and the current filename.
    sequencePath = fullfile(config.input.sequenceFolder, config.input.sequenceFilenames{index_filename});
    % Parse the ultrasound sequence and tracking data with the existing project helper.
    sequence = read_sequence_image(sequencePath);

    % Collect all raw Probe-to-Tracker transforms into one 3D array for smoothing.
    ProbeToTrackerDeviceTransform_all = cat(3, sequence.packets.ProbeToTrackerDeviceTransform);
    % Collect all raw Reference-to-Tracker transforms into one 3D array for smoothing.
    ReferenceToTrackerDeviceTransform_all = cat(3, sequence.packets.ReferenceToTrackerDeviceTransform);

    % Smooth the probe transforms using the same options as the validated script.
    ProbeToTrackerDeviceTransform_all_smooth = smoothTransformations( ...
        ProbeToTrackerDeviceTransform_all, ...
        'method', config.smoothing.method, ...
        'window', config.smoothing.window);
    % Smooth the reference transforms using the same options as the validated script.
    ReferenceToTrackerDeviceTransform_all_smooth = smoothTransformations( ...
        ReferenceToTrackerDeviceTransform_all, ...
        'method', config.smoothing.method, ...
        'window', config.smoothing.window);

    % Convert the smoothed probe transform stack into a cell list for assigning into packet structs.
    probeTransformCells = reshape(num2cell(cat(3, ProbeToTrackerDeviceTransform_all_smooth), [1 2]), 1, []);
    % Store the smoothed probe transform beside each packet so plane construction can use filtered poses.
    [sequence.packets.ProbeToTrackerDeviceTransform_Filtered] = deal(probeTransformCells{:});

    % Convert the smoothed reference transform stack into a cell list for assigning into packet structs.
    referenceTransformCells = reshape(num2cell(cat(3, ReferenceToTrackerDeviceTransform_all_smooth), [1 2]), 1, []);
    % Store the smoothed reference transform beside each packet so plane construction can use filtered poses.
    [sequence.packets.ReferenceToTrackerDeviceTransform_Filtered] = deal(referenceTransformCells{:});

    % Save the prepared sequence for the image-plane collection step.
    sequences{index_filename} = sequence;

    % Print the filename when requested so long preparations are easier to follow.
    if config.logging.printPreparationProgress
        fprintf('%s prepared.\n', config.input.sequenceFilenames{index_filename});
    end
end

%% COLLECT 2D IMAGE PLANES

% Create an empty plane struct array with all fields needed by the intersection helpers.
planes = repmat(struct('p0', [], 'ex', [], 'ey', [], 'n', [], ...
                       'W', 0, 'H', 0, 'nRows', 0, 'nCols', 0, ...
                       'image', [], 'timestamp', 0), 1, 0);

% Start the output index at one because MATLAB arrays use one-based indexing.
plane_index = 1;

% Loop over each prepared sequence to collect all sampled image planes.
for index_filename = 1:n_filename
    % Read the current prepared sequence once so the inner loop stays focused on packets.
    sequence = sequences{index_filename};

    % Read the number of packets from the header because the sequence length can vary per recording.
    n_packet = sequence.header.DimSize(3);

    % Use the sequence end when the caller did not provide a custom packet end index.
    if isempty(config.imagePlaneSampling.packetEndIndex)
        packetEndIndex = n_packet;
    else
        packetEndIndex = min(config.imagePlaneSampling.packetEndIndex, n_packet);
    end

    % Loop over the same sampled packet indices used by the validated script.
    for idx_packet = config.imagePlaneSampling.packetStartIndex:config.imagePlaneSampling.packetStep:packetEndIndex

        % Read the current packet once so every field access refers to the same frame.
        current_packet = sequence.packets(idx_packet);
        % Skip packets whose probe tracking was invalid because their image plane pose is not trustworthy.
        if ~current_packet.ProbeToTrackerDeviceTransformStatus
            continue;
        end

        % Read the smoothed probe pose in the tracker frame.
        T_global_probe = current_packet.ProbeToTrackerDeviceTransform_Filtered;
        % Read the smoothed reference pose in the tracker frame.
        T_global_ref   = current_packet.ReferenceToTrackerDeviceTransform_Filtered;

        % Express the probe pose in the reference frame without forming an explicit matrix inverse.
        T_probe_ref = T_global_ref \ T_global_probe;
        % Build the image plane pose in the reference frame using the calibration transform.
        T_image_ref = T_probe_ref * T_image_probecalib;

        % Read the image origin in the reference frame.
        origin    = T_image_ref(1:3, 4);
        % Read the image basis axes in the reference frame.
        base_axes = T_image_ref(1:3, 1:3);

        % Store the neccesary values 
        plane.p0 = origin;                              % Top-left point of the finite image plane.
        plane.ex = base_axes(:, 1);                     % Physical direction of increasing image column.
        plane.ey = base_axes(:, 2);                     % Physical direction of increasing image row.
        plane.n = base_axes(:, 3);                      % Physical normal direction of the image plane.
        plane.W = (size(current_packet.Image, 1) - 1) * S_image_probecalib(1);  % Physical image width 
        plane.H = (size(current_packet.Image, 2) - 1) * S_image_probecalib(2);  % Physical image height
        plane.nRows = size(current_packet.Image, 2);    % Number of image rows
        plane.nCols = size(current_packet.Image, 1);    % Number of image columns 
        plane.image = current_packet.Image;             % Raw image so the future cost function can sample intensity values.
        plane.timestamp = current_packet.Timestamp;     % Timestamp so outputs can be traced back to the source packet.

        % Append the current plane to the output array.
        planes(plane_index) = plane;

        % Move to the next output slot.
        plane_index = plane_index + 1;
    end
end

%% LOAD ACS DATA

% Build the full path to the femur ACS MAT file.
acs_path = fullfile(config.project.root, 'data', 'bones', config.input.acsFilename);
% Load the ACS file into a struct so variable names can be checked safely.
acs_loaded = load(acs_path);

% Use the expected acs variable when it exists.
if isfield(acs_loaded, 'acs')
    acs = acs_loaded.acs;
else
    % Fall back to the first saved variable so the helper is robust to minor MAT-file name changes.
    acs_fields = fieldnames(acs_loaded);
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

%% PACKAGE OUTPUT DATA

data.meshVerticesLocal  = meshVerticesLocal;                % Local vertices so optimization can re-transform the same source geometry for every candidate pose.
data.meshFaces          = meshFaces;                        % Mesh faces because the topology does not change during rigid-pose optimization.
data.planes             = planes;                           % Image planes because they are fixed observations during mesh-pose optimization.
data.T_init_originct    = T_init_originct;                  % Current manual alignment as the starting pose for future optimization.
data.T_image_probecalib = T_image_probecalib;               % Calibration transform for inspection and future extensions.
data.S_image_probecalib = S_image_probecalib;               % Calibration spacing for inspection and future extensions.
data.config = config;                                       % Raw configuration with the data so future scripts can reproduce how it was prepared.

% Print the number of collected planes when requested so setup can be verified quickly.
if config.logging.printPreparationProgress
    fprintf('Collected %d image planes for optimization.\n', numel(planes));
end
end
