function [data, validationData] = prepareBonePoseOptimizationInputs(config)
%PREPAREBONEPOSEOPTIMIZATIONINPUTS Prepare standardized optimization inputs.
% This function loads the reviewed ultrasound snapshots, CT bone model, and
% coarse registration produced by tools/. It prepares fixed estimation data
% once so the cost function only needs to evaluate candidate poses.
%
% Input:
%   config         - Scalar configuration returned by
%                    createBonePoseOptimizationRunConfig.
%
% Outputs:
%   data           - Estimation-only data containing the CT mesh, ultrasound
%                    planes, initial transforms, and initial pixel counts.
%   validationData - Saved ground-truth intersections, bone pose, and source
%                    metadata. This output must not be passed to the optimizer.

% Use one uppercase code to match the same bone across all standardized files.
targetBone = upper(char(config.input.bone));

%% LOAD STANDARDIZED TOOL OUTPUTS

% snapshotOutput is structured as:
%   snapshotOutput.validSnapshots = struct array of reviewed snapshots;
%   snapshotOutput.validBonePoses  = struct containing ground-truth poses.
% So we extract both saved variables from the wrapper returned by MATLAB load.
snapshotOutput            = loadRequiredVariables(config.input.validSnapshotsMatFile, {'validSnapshots', 'validBonePoses'});
validSnapshots            = snapshotOutput.validSnapshots;
validBonePoses            = snapshotOutput.validBonePoses;

% bones and coarseRegistration are structured as arrays with one record per bone:
%   bones(1).bone              = 'F';
%   bones(2).bone              = 'T';
%   coarseRegistration(1).bone = 'F';
%   coarseRegistration(2).bone = 'T';
% So we load the complete CT-model and coarse-registration arrays first.
ctOutput                  = loadRequiredVariables(config.input.ctPostProcessedMatFile, {'bones'});
coarseOutput              = loadRequiredVariables(config.input.coarseRegistrationMatFile, {'coarseRegistration'});
bones                     = ctOutput.bones;
coarseRegistration        = coarseOutput.coarseRegistration;

% currentCoarseRegistration is one record selected from coarseRegistration:
%   currentCoarseRegistration.bone            = targetBone;
%   currentCoarseRegistration.status          = "registered";
%   currentCoarseRegistration.T_CT_ref_est    = 4-by-4 transform;
%   currentCoarseRegistration.T_bone_ref_est  = 4-by-4 transform;
%   currentCoarseRegistration.boneMeshRef_est = triangulation in ref coordinates.
% So we find the matching bone codes instead of assuming a fixed array position.
boneIndex                 = findUniqueBoneIndex(bones, targetBone, 'CT bone model');
coarseIndex               = findUniqueBoneIndex(coarseRegistration, targetBone, 'coarse-registration result');
currentBone               = bones(boneIndex);
currentCoarseRegistration = coarseRegistration(coarseIndex);

% validBonePoses.bonePoses is also an array with one record per bone:
%   validBonePoses.bonePoses(1).bone = 'F';
%   validBonePoses.bonePoses(2).bone = 'T';
% Each record's data field contains its ground-truth transforms and mesh.
% So we select the targetBone record and keep its data for later validation.
groundTruthIndex          = findUniqueBoneIndex(validBonePoses.bonePoses, targetBone, 'ground-truth bone pose');
currentGroundTruthPose    = validBonePoses.bonePoses(groundTruthIndex).data;

% A skipped coarse-registration record cannot provide an optimization start pose.
if ~strcmpi(string(currentCoarseRegistration.status), "registered")
    error('prepareBonePoseOptimizationInputs:BoneNotRegistered', ...
        'The coarse-registration result for bone %s is not registered: %s', ...
        targetBone, string(currentCoarseRegistration.status));
end

%% COLLECT ESTIMATION AND VALIDATION RECORDS

% Copy planes and ground truth into separate arrays while preserving source order.
[imagePlanesRef, groundTruthIntersections, snapshotSources] = collectBoneSnapshots(validSnapshots, targetBone);

% Check the fixed plane geometry before it is used in repeated evaluations.
validateImagePlanes(imagePlanesRef);

%% PREPARE THE CT MESH AND INITIAL POSE

% Keep the source mesh in CT coordinates throughout optimization preparation.
boneMeshCT = currentBone.mesh;
if ~isa(boneMeshCT, 'triangulation')
    error('prepareBonePoseOptimizationInputs:InvalidBoneMesh', ...
        'bones(%d).mesh must be a triangulation.', boneIndex);
end

% Read the frame-explicit transforms produced by the CT and coarse-registration tools.
T_bone_CT        = currentBone.T_bone_CT;
T_CT_ref_initial = currentCoarseRegistration.T_CT_ref_est;
validateRigidTransform(T_bone_CT, 'bones.T_bone_CT');
validateRigidTransform(T_CT_ref_initial, 'coarseRegistration.T_CT_ref_est');

% Read and validate the ground-truth transforms saved by spatial processing.
T_CT_ref_groundTruth = currentGroundTruthPose.T_CT_ref;
T_bone_ref_groundTruth = currentGroundTruthPose.T_bone_ref;
boneMeshRefGroundTruth = currentGroundTruthPose.mesh;
validateRigidTransform(T_CT_ref_groundTruth, 'validBonePoses.bonePoses.data.T_CT_ref');
validateRigidTransform(T_bone_ref_groundTruth, 'validBonePoses.bonePoses.data.T_bone_ref');
if ~isa(boneMeshRefGroundTruth, 'triangulation')
    error('prepareBonePoseOptimizationInputs:InvalidGroundTruthMesh', ...
          'The ground-truth bone mesh must be a triangulation.');
end

% The saved anatomical frame must come from the same CT pose and CT bone model.
if norm(T_bone_ref_groundTruth - T_CT_ref_groundTruth * T_bone_CT, 'fro') > 1e-8
    error('prepareBonePoseOptimizationInputs:InconsistentGroundTruthTransform', ...
          'Ground-truth T_bone_ref does not equal T_CT_ref * T_bone_CT.');
end

% Derive the anatomical-frame pose from the CT pose so both always stay synchronized.
T_bone_ref_initial = T_CT_ref_initial * T_bone_CT;
if norm(T_bone_ref_initial - currentCoarseRegistration.T_bone_ref_est, 'fro') > 1e-8
    error('prepareBonePoseOptimizationInputs:InconsistentBoneTransform', ...
          'T_bone_ref_est does not equal T_CT_ref_est * T_bone_CT.');
end

% Confirm that the coarse mesh belongs to this CT mesh and transform.
validateCoarseMesh(boneMeshCT, currentCoarseRegistration.boneMeshRef_est, T_CT_ref_initial);

%% COMPUTE THE INITIAL COVERAGE REFERENCE

% Recompute intersections at the coarse pose; saved intersections are validation data only.
[initialPoseEvaluation, ~] = computeProbeFacingPixelsForPose(boneMeshCT, imagePlanesRef, T_CT_ref_initial, config);

% Store one fixed reference count per plane for active-plane and coverage scoring.
nInitialIntersectionPixels = arrayfun( ...
    @(evaluation) size(evaluation.probeFacingPixels, 1), ...
    initialPoseEvaluation);

%% PACKAGE ESTIMATION DATA

% Keep estimation fields together and name geometry by its coordinate frame.
data.bone                       = targetBone;
data.boneName                   = char(string(currentBone.name));
data.boneMeshCT                 = boneMeshCT;
data.imagePlanesRef             = imagePlanesRef;
data.T_bone_CT                  = T_bone_CT;
data.T_CT_ref_initial           = T_CT_ref_initial;
data.T_bone_ref_initial         = T_bone_ref_initial;
data.nInitialIntersectionPixels = nInitialIntersectionPixels;
data.config                     = config;

% Keep ground truth outside data so estimation code cannot use it accidentally.
validationData.bone                            = targetBone;
validationData.groundTruthIntersections        = groundTruthIntersections;
validationData.snapshotSources                 = snapshotSources;
validationData.groundTruthBonePose.bone        = targetBone;
validationData.groundTruthBonePose.T_CT_ref    = T_CT_ref_groundTruth;
validationData.groundTruthBonePose.T_bone_ref  = T_bone_ref_groundTruth;
validationData.groundTruthBonePose.boneMeshRef = boneMeshRefGroundTruth;

% Print a compact summary only when preparation logging is enabled.
if config.logging.printPreparationProgress
    fprintf('Prepared %d image planes for bone %s.\n', ...
        numel(imagePlanesRef), targetBone);
end
end




function loadedData = loadRequiredVariables(filePath, variableNames)
%LOADREQUIREDVARIABLES Load several related variables from one MAT-file.
% filePath identifies the MAT-file, variableNames lists the required saved
% variables, and loadedData is the struct returned by MATLAB load.

% Report the shared input path before trying to read its related variables.
if ~isfile(filePath)
    error('prepareBonePoseOptimizationInputs:MissingInputFile', ...
        'Input MAT-file was not found: %s', filePath);
end

% Read related snapshot outputs together so they always come from one file.
loadedData = load(filePath, variableNames{:});
for variableIndex = 1:numel(variableNames)
    variableName = variableNames{variableIndex};
    if ~isfield(loadedData, variableName)
        error('prepareBonePoseOptimizationInputs:MissingVariable', ...
            'MAT-file %s does not contain variable %s.', filePath, variableName);
    end
end
end


function boneIndex = findUniqueBoneIndex(records, targetBone, sourceName)
%FINDUNIQUEBONEINDEX Match exactly one struct record by bone code.
% records is a struct array with a bone field, targetBone is the requested
% code, sourceName labels errors, and boneIndex is the unique matching index.

% Bone codes are the stable identity shared by the standardized tool outputs.
recordBoneCodes = upper(string({records.bone}));
boneIndex = find(recordBoneCodes == string(targetBone));

% Array order is not an identity, so continue only with one code match.
if numel(boneIndex) ~= 1
    error('prepareBonePoseOptimizationInputs:NonuniqueBoneMatch', ...
        'Expected one %s for bone %s, but found %d.', ...
        sourceName, targetBone, numel(boneIndex));
end
end


function [imagePlanesRef, groundTruthIntersections, snapshotSources] = ...
        collectBoneSnapshots(validSnapshots, targetBone)
%COLLECTBONESNAPSHOTS Flatten selected records for one bone in stable order.
% validSnapshots is the grouped review output and targetBone is the selected
% code. The outputs are aligned plane, ground-truth intersection, and source
% arrays that preserve group order followed by record order.

% Select every source group belonging to the requested bone.
groupBoneCodes = upper(string({validSnapshots.bone}));
targetGroupIndices = find(groupBoneCodes == string(targetBone));

% Count selected records first so the output arrays can be allocated once.
nRecords = 0;
for groupIndex = targetGroupIndices
    nRecords = nRecords + numel(validSnapshots(groupIndex).data);
end

% Optimization needs at least one fixed ultrasound observation.
if nRecords == 0
    error('prepareBonePoseOptimizationInputs:NoSelectedSnapshots', ...
        'No selected ultrasound snapshots were found for bone %s.', targetBone);
end

% Find the first selected record to preserve the exact saved struct layouts.
firstGroupIndex = targetGroupIndices( ...
    find(arrayfun(@(index) ~isempty(validSnapshots(index).data), ...
    targetGroupIndices), 1));
firstRecord = validSnapshots(firstGroupIndex).data(1);

% Preallocate aligned estimation and validation arrays from their saved templates.
imagePlanesRef = repmat(firstRecord.plane, 1, nRecords);
groundTruthIntersections = repmat(firstRecord.intersection, 1, nRecords);
sourceTemplate = struct('groupName', '', 'groupPath', '', ...
    'groupIndex', 0, 'recordIndex', 0, 'sourceIndex', 0);
snapshotSources = repmat(sourceTemplate, 1, nRecords);

% Flatten groups without sorting again so review order remains reproducible.
outputIndex = 1;
for groupIndex = targetGroupIndices
    currentGroup = validSnapshots(groupIndex);
    for recordIndex = 1:numel(currentGroup.data)
        currentRecord = currentGroup.data(recordIndex);
        imagePlanesRef(outputIndex) = currentRecord.plane;
        groundTruthIntersections(outputIndex) = currentRecord.intersection;
        snapshotSources(outputIndex).groupName = char(string(currentGroup.name));
        snapshotSources(outputIndex).groupPath = char(string(currentGroup.path));
        snapshotSources(outputIndex).groupIndex = groupIndex;
        snapshotSources(outputIndex).recordIndex = recordIndex;
        snapshotSources(outputIndex).sourceIndex = currentRecord.sourceIndex;
        outputIndex = outputIndex + 1;
    end
end
end


function validateImagePlanes(imagePlanesRef)
%VALIDATEIMAGEPLANES Check the fields used by geometry and intensity scoring.
% imagePlanesRef is the plane struct array. This helper has no output and
% stops when a plane cannot be used consistently in the reference frame.

% These fields are the complete interface consumed by the optimization pipeline.
requiredFields = {'T_image_ref', 'p0', 'ex', 'ey', 'n', 'W', 'H', ...
    'nRows', 'nCols', 'image', 'timestamp'};

for planeIndex = 1:numel(imagePlanesRef)
    plane = imagePlanesRef(planeIndex);

    % Report a schema problem before individual geometry expressions become unclear.
    if ~all(isfield(plane, requiredFields))
        error('prepareBonePoseOptimizationInputs:InvalidPlaneSchema', ...
            'Image plane %d is missing a required field.', planeIndex);
    end

    % The basis vectors and origin must form the same image pose saved by the tool.
    if ~isequal(size(plane.p0), [3 1]) || ~isequal(size(plane.ex), [3 1]) || ...
            ~isequal(size(plane.ey), [3 1]) || ~isequal(size(plane.n), [3 1])
        error('prepareBonePoseOptimizationInputs:InvalidPlaneGeometry', ...
            'Image plane %d must store p0, ex, ey, and n as 3-by-1 vectors.', ...
            planeIndex);
    end

    validateRigidTransform(plane.T_image_ref, ...
        sprintf('imagePlanesRef(%d).T_image_ref', planeIndex));
    T_image_ref_from_fields = [plane.ex, plane.ey, plane.n, plane.p0; 0 0 0 1];
    if norm(T_image_ref_from_fields - plane.T_image_ref, 'fro') > 1e-8
        error('prepareBonePoseOptimizationInputs:InconsistentPlaneTransform', ...
            'Image plane %d geometry does not match T_image_ref.', planeIndex);
    end

    % Images are stored as [column, row] in the standardized snapshot output.
    if ~ismatrix(plane.image) || size(plane.image, 1) ~= plane.nCols || ...
            size(plane.image, 2) ~= plane.nRows || plane.W <= 0 || plane.H <= 0
        error('prepareBonePoseOptimizationInputs:InvalidPlaneImage', ...
            'Image plane %d has inconsistent dimensions or physical size.', ...
            planeIndex);
    end
end
end


function validateRigidTransform(T_source_target, transformName)
%VALIDATERIGIDTRANSFORM Check one project-format 4-by-4 rigid transform.
% T_source_target is the matrix to check and transformName identifies it in
% errors. This helper has no output.

% Check the matrix shape and finite values before testing rotation properties.
if ~isnumeric(T_source_target) || ~isequal(size(T_source_target), [4 4]) || ...
        ~all(isfinite(T_source_target(:)))
    error('prepareBonePoseOptimizationInputs:InvalidRigidTransform', ...
        '%s must be a finite numeric 4-by-4 matrix.', transformName);
end

% A project rigid transform has an orthonormal right-handed rotation and fixed last row.
rotation = T_source_target(1:3, 1:3);
if norm(rotation' * rotation - eye(3), 'fro') > 1e-6 || ...
        abs(det(rotation) - 1) > 1e-6 || ...
        norm(T_source_target(4, :) - [0 0 0 1]) > 1e-8
    error('prepareBonePoseOptimizationInputs:InvalidRigidTransform', ...
        '%s is not a proper rigid transform.', transformName);
end
end


function validateCoarseMesh(boneMeshCT, boneMeshRefEstimate, T_CT_ref_initial)
%VALIDATECOARSEMESH Confirm that coarse registration used the selected CT mesh.
% boneMeshCT is the source triangulation, boneMeshRefEstimate is the saved
% transformed triangulation, and T_CT_ref_initial is the saved coarse pose.
% This helper has no output.

% The transformed mesh should keep the CT mesh connectivity unchanged.
if ~isa(boneMeshRefEstimate, 'triangulation') || ...
        ~isequal(boneMeshCT.ConnectivityList, boneMeshRefEstimate.ConnectivityList)
    error('prepareBonePoseOptimizationInputs:CoarseMeshMismatch', ...
        'The coarse-registration mesh does not match the selected CT mesh.');
end

% Applying the saved transform should reproduce the saved reference-frame points.
expectedPointsRef = applyRigidTransform(boneMeshCT.Points, T_CT_ref_initial);
if ~isequal(size(expectedPointsRef), size(boneMeshRefEstimate.Points)) || ...
        max(abs(expectedPointsRef - boneMeshRefEstimate.Points), [], 'all') > 1e-8
    error('prepareBonePoseOptimizationInputs:CoarseMeshMismatch', ...
        'The coarse-registration mesh points do not match T_CT_ref_est.');
end
end
