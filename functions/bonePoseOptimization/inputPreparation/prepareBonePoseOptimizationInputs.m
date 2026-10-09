function [data, validationData] = prepareBonePoseOptimizationInputs(config)
%PREPAREBONEPOSEOPTIMIZATIONINPUTS Prepare standardized optimization inputs.
% This function loads reviewed ultrasound snapshots, optional bone-surface
% measurements, the CT bone model, and coarse registration produced by
% tools/. It prepares fixed estimation data once so the cost function only
% needs to evaluate candidate poses.
%
% Where it fits in the framework:
%   The goal of the whole pipeline is to find where the bone is (its pose in
%   the tracker "ref" frame) by moving the CT bone mesh until it agrees with
%   the tracked ultrasound images. The optimizer (CMA-ES) does this by
%   trying thousands of candidate poses and asking a cost function "how well
%   does the bone fit the images at this pose?".
%
%   This function is the setup step that runs BEFORE that search starts. It
%   is called once per hyperparameter combination (with the config made by
%   createBonePoseOptimizationRunConfig), and its output is reused by every
%   seed of that combination. It gathers everything the cost function will
%   need and that does NOT change while the optimizer moves the bone:
%     - the CT bone mesh (the shape we are moving around),
%     - the ultrasound image planes in the ref frame (what we compare to),
%     - optional bone-surface points extracted from those images,
%     - the coarse start pose (where the search begins),
%     - pre-built structures such as the P-IMLOP PD-tree and the
%       smoothed images used by the intensity cost.
%
% Why it is needed:
%   A cost function is called a huge number of times, so it must be fast.
%   Loading files, checking that they belong together, and building search
%   trees are slow, and their result is the same for every candidate pose.
%   Doing that work once here, and handing over a ready "data" struct,
%   keeps each cost evaluation down to the part that truly depends on the
%   pose. It is also the one place where we check that all input files
%   (made by different tools in tools/) are consistent with each other, so
%   a mismatch is reported clearly instead of producing a wrong pose.
%
%   The function also separates what the optimizer is ALLOWED to see from
%   what it must NOT see. The ground truth (true bone pose, true
%   intersections) is only needed afterwards to judge how good the result
%   is. It goes into validationData, never into data, so the estimation can
%   never accidentally "cheat" by using the answer.
%
% Input:
%   config         - Scalar configuration returned by
%                    createBonePoseOptimizationRunConfig.
%
% Outputs:
%   data           - Estimation-only data containing the CT mesh, ultrasound
%                    measurements, and initial transforms.
%                    data.extra.pimlop.PsiCT holds the CT-frame P-IMLOP model
%                    with its PD-tree, used by cost_PIMLOP_v01. When the
%                    config sets intensitySmoothingSigmaMm,
%                    data.extra.intensityLine.smoothedImages holds one
%                    blurred image per plane, used by cost_intensityLine_v01.
%   validationData - Saved ground-truth intersections, bone pose, and source
%                    metadata. This output must not be passed to the optimizer.

% Every input file can contain several bones (for example femur 'F' and
% tibia 'T'), but one optimization run estimates the pose of ONE bone. The
% bone code is how we pick the matching record out of each file. Using one
% uppercase form avoids missing a match just because one tool wrote 'f'
% and another wrote 'F'.
targetBone = upper(char(config.input.bone));

%% LOAD STANDARDIZED TOOL OUTPUTS

% The reviewed snapshots are the heart of the measurement: each snapshot is
% one tracked ultrasound image, together with where that image plane was in
% the ref frame when it was taken. These are what the bone will be compared
% to during optimization. The same file also stores the ground-truth bone
% poses, which we only keep for evaluating the result afterwards.
% snapshotOutput is structured as:
%   snapshotOutput.validSnapshots = struct array of reviewed snapshots;
%   snapshotOutput.validBonePoses  = struct containing ground-truth poses.
% So we extract both saved variables from the wrapper returned by MATLAB load.
snapshotOutput            = loadRequiredVariables(config.input.validSnapshotsMatFile, {'validSnapshots', 'validBonePoses'});
validSnapshots            = snapshotOutput.validSnapshots;
validBonePoses            = snapshotOutput.validBonePoses;

% Bone surfaces are the bright bone edges that were detected in each
% ultrasound image, both as 2D pixel coordinates and as 3D points in the
% ref frame. Point-based cost models (such as ICP-like or P-IMLOP) compare
% the bone mesh to these points rather than to the raw image. Cost models
% that only look at image intensity do not need them, so the file is
% optional and only loaded when the config names one.
hasBoneSurface = ~isempty(config.input.boneSurfaceMatFile);
surfaceOutput = struct();
if hasBoneSurface
    surfaceOutput = loadRequiredVariables(config.input.boneSurfaceMatFile, {'surfaceResults', 'extractionMetadata'});
end

% The CT file holds the bone shape we want to place: a triangle mesh
% segmented from CT, in CT coordinates. The coarse-registration file holds a
% rough first guess of where that mesh sits in the ref frame. The optimizer
% needs both: the mesh is what it moves, and the coarse pose is where it
% starts moving from.
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

% Now pick out the record of the bone we are estimating from both files.
% We search by bone code instead of assuming "femur is always element 1",
% because different tools may save bones in a different order, and a silent
% order mismatch would pair the femur mesh with the tibia's start pose.
% currentCoarseRegistration is one record selected from coarseRegistration:
%   currentCoarseRegistration.bone            = targetBone;
%   currentCoarseRegistration.status          = "registered";
%   currentCoarseRegistration.T_CT_ref_est    = 4-by-4 transform;
%   currentCoarseRegistration.T_bone_ref_est  = 4-by-4 transform;
%   currentCoarseRegistration.boneMeshRef_est = triangulation in ref coordinates.
boneIndex                 = findUniqueBoneIndex(bones, targetBone, 'CT bone model');
coarseIndex               = findUniqueBoneIndex(coarseRegistration, targetBone, 'coarse-registration result');
currentBone               = bones(boneIndex);
currentCoarseRegistration = coarseRegistration(coarseIndex);

% The ground-truth pose of the same bone is picked the same way. It is the
% "answer" we hope the optimizer will find, and it is used only after the
% optimization to measure the pose error.
% validBonePoses.bonePoses is also an array with one record per bone:
%   validBonePoses.bonePoses(1).bone = 'F';
%   validBonePoses.bonePoses(2).bone = 'T';
% The current schema stores the CT mesh once beside data, while data contains
% the selected ground-truth transform. Keeping these two levels separate avoids
% duplicating the complete CT mesh for every pose in a kinematic recording.
groundTruthIndex           = findUniqueBoneIndex(validBonePoses.bonePoses, targetBone, 'ground-truth bone pose');
currentGroundTruthBonePose = validBonePoses.bonePoses(groundTruthIndex);
currentGroundTruthPose     = currentGroundTruthBonePose.data;

% The current optimization assumes the bone did not move while the images
% were taken, so it looks for ONE pose that fits all images at once. A
% recording where the bone moves (one pose per image row) would need a
% different method. We stop here with a clear message, instead of letting
% MATLAB quietly read only the first pose of the series and produce a
% misleading result.
if ~isstruct(currentGroundTruthPose) || ~isscalar(currentGroundTruthPose)
    error('prepareBonePoseOptimizationInputs:UnsupportedGroundTruthPoseSeries', ...
        ['The selected bone must contain exactly one ground-truth pose. ' ...
         'perDataRow kinematic ground truth is not yet supported by this optimization workflow.']);
end

% The optimizer only searches in a limited region around its start pose, so
% it needs a sensible start. If the coarse-registration tool skipped this
% bone, there is no start pose to use, and continuing would make no sense.
if ~strcmpi(string(currentCoarseRegistration.status), "registered")
    error('prepareBonePoseOptimizationInputs:BoneNotRegistered', ...
          'The coarse-registration result for bone %s is not registered: %s', ...
          targetBone, string(currentCoarseRegistration.status));
end

%% COLLECT ESTIMATION AND VALIDATION RECORDS

% The snapshot file groups images by recording (sweep), and each record
% mixes things the optimizer may use (the image and its plane) with things
% it must not use (the ground-truth intersection of bone and plane). Here we
% flatten all records of this bone into simple arrays and split them:
% imagePlanesRef goes to the optimizer, groundTruthIntersections goes to
% validation, and snapshotSources remembers where each image came from so
% results can be traced back to the original recording. The original order
% is kept, so plane k always means the same image in every output.
[imagePlanesRef, groundTruthIntersections, snapshotSources] = collectBoneSnapshots(validSnapshots, targetBone);
% Each image plane is used by the cost function to cut the bone mesh and
% compare the cut with the image. Checking the plane fields now (origin,
% axes, size, image) means a broken plane is reported here, by index,
% rather than as a confusing error deep inside a cost evaluation.
validateImagePlanes(imagePlanesRef);

% Fill in an "empty" bone-surface result first. Cost models can then always
% read the same fields (isAvailable, measurements, ...) and simply check
% isAvailable, instead of first testing whether the fields exist at all.
boneSurface.isAvailable        = false;
boneSurface.extractionMetadata = struct();
boneSurface.measurements       = struct([]);

% When surface points were provided, collect the ones belonging to this bone
% and check them on their own first: correct coordinate convention (which
% image axis is the beam direction), matching 2D and 3D points, valid
% normals. A point-based cost model trusts these points completely, so an
% axis or unit mix-up here would pull the bone to a wrong pose without any
% visible error.
if hasBoneSurface
    collectedBoneSurface = collectBoneSurfaceMeasurements(surfaceOutput, targetBone);
    validateBoneSurfaceMeasurements(collectedBoneSurface);
end

%% VALIDATE AND ALIGN RELATED ULTRASOUND INPUTS

% The surface points were extracted from the same images, but they live in a
% different file and may be stored in a different order. Cost models that
% use both the image plane and its surface points assume that surface k
% belongs to plane k. Aligning them here, by matching each surface to its
% source snapshot, makes that assumption true, so the cost function can
% simply use the same index for both.
if hasBoneSurface
    boneSurface = alignBoneSurfacesToSnapshots(collectedBoneSurface, snapshotSources, config.input.validSnapshotsMatFile);
end

%% PREPARE THE CT MESH AND INITIAL POSE

% The bone mesh stays in CT coordinates. During optimization, each candidate
% pose moves this same mesh into the ref frame where the images are. Keeping
% one fixed CT copy (instead of a pre-moved one) means every candidate pose
% is applied to the same, unchanged shape.
boneMeshCT = currentBone.mesh;
if ~isa(boneMeshCT, 'triangulation')
    error('prepareBonePoseOptimizationInputs:InvalidBoneMesh', ...
          'bones(%d).mesh must be a triangulation.', boneIndex);
end

% Two transforms describe where the bone is:
%   - T_bone_CT moves points from the anatomical bone frame (axes aligned
%     with the bone itself) into CT. It comes from the CT tool and never
%     changes; it lets us report results in anatomical terms.
%   - T_CT_ref_initial is the coarse estimate of where CT sits in the ref
%     frame. This is the start pose: the optimizer searches for a small
%     correction around it.
% Both are checked to be proper rigid transforms, because a slightly
% non-rigid matrix (e.g. a scaling sneaked in) would distort the bone shape
% and make every cost value meaningless.
T_bone_CT        = currentBone.T_bone_CT;
T_CT_ref_initial = currentCoarseRegistration.T_CT_ref_est;
validateRigidTransform(T_bone_CT, 'bones.T_bone_CT');
validateRigidTransform(T_CT_ref_initial, 'coarseRegistration.T_CT_ref_est');

% These are the true poses of the bone, measured independently during data
% collection. The optimizer never sees them; they are used afterwards to
% compute how far the estimated pose is from the truth. They are checked
% like the other transforms so the error we report is trustworthy.
T_CT_ref_groundTruth = currentGroundTruthPose.T_CT_ref;
T_bone_ref_groundTruth = currentGroundTruthPose.T_bone_ref;
validateRigidTransform(T_CT_ref_groundTruth, 'validBonePoses.bonePoses.data.T_CT_ref');
validateRigidTransform(T_bone_ref_groundTruth, 'validBonePoses.bonePoses.data.T_bone_ref');

% For evaluation and plots we also want the bone mesh at its TRUE pose in
% the ref frame, e.g. to compare it visually with the estimated mesh or to
% recompute true intersections. The current files store the mesh once in CT
% (to save space) rather than inside every pose record, so we rebuild the
% ref-frame mesh by applying the ground-truth transform to it.
if isfield(currentGroundTruthBonePose, 'meshCT')
    boneMeshCTGroundTruth = currentGroundTruthBonePose.meshCT;
    if ~isa(boneMeshCTGroundTruth, 'triangulation')
        error('prepareBonePoseOptimizationInputs:InvalidGroundTruthMesh', ...
            'validBonePoses.bonePoses.meshCT must be a triangulation.');
    end
    bonePointsRefGroundTruth = applyRigidTransform(boneMeshCTGroundTruth.Points, T_CT_ref_groundTruth);
    boneMeshRefGroundTruth   = triangulation(boneMeshCTGroundTruth.ConnectivityList, bonePointsRefGroundTruth);

elseif isfield(currentGroundTruthPose, 'mesh')
    % Older reviewed snapshot files stored the already transformed mesh here.
    % Retain this fallback so existing optimization inputs remain usable.
    boneMeshRefGroundTruth = currentGroundTruthPose.mesh;
    if ~isa(boneMeshRefGroundTruth, 'triangulation')
        error('prepareBonePoseOptimizationInputs:InvalidGroundTruthMesh', ...
            'validBonePoses.bonePoses.data.mesh must be a triangulation.');
    end

else
    error('prepareBonePoseOptimizationInputs:MissingGroundTruthMesh', ...
        ['The ground-truth bone pose must contain meshCT at the bone level ' ...
         'or the legacy data.mesh field.']);
end

% The ground-truth file stores the true pose twice: as CT->ref and as
% bone->ref. They must describe the same pose through the same T_bone_CT;
% if not, the ground truth was made with a different CT model, and any
% error we compute against it (in CT or anatomical terms) would be wrong.
if norm(T_bone_ref_groundTruth - T_CT_ref_groundTruth * T_bone_CT, 'fro') > 1e-8
    error('prepareBonePoseOptimizationInputs:InconsistentGroundTruthTransform', ...
          'Ground-truth T_bone_ref does not equal T_CT_ref * T_bone_CT.');
end

% The start pose in the anatomical frame is computed from the CT start pose
% instead of copied from the file, so the two can never disagree. Comparing
% it with the saved T_bone_ref_est also confirms that the coarse
% registration used the same CT model as we do.
T_bone_ref_initial = T_CT_ref_initial * T_bone_CT;
if norm(T_bone_ref_initial - currentCoarseRegistration.T_bone_ref_est, 'fro') > 1e-8
    error('prepareBonePoseOptimizationInputs:InconsistentBoneTransform', ...
          'T_bone_ref_est does not equal T_CT_ref_est * T_bone_CT.');
end

% The coarse-registration tool also saved the mesh it placed. If moving our
% CT mesh with its start pose does not give exactly that mesh, the start
% pose was found for a different mesh (e.g. an older segmentation) and
% would not be a valid starting point for this one.
validateCoarseMesh(boneMeshCT, currentCoarseRegistration.boneMeshRef_est, T_CT_ref_initial);

%% PREPARE THE P-IMLOP MODEL AND PD-TREE

% P-IMLOP is a point-to-surface registration method: for every measured
% bone-surface point it needs the most likely triangle on the bone mesh. A
% brute-force search over all triangles for every point, in every cost
% evaluation, would be far too slow. The PD-tree is a search tree over the
% mesh triangles that makes this lookup fast. Because it only depends on the
% mesh shape (not on the pose), it is built once here, in the CT frame; the
% cost function then moves the measured points into CT for each candidate
% pose instead of moving the whole mesh. The tree depends only on the CT
% mesh, so it is built for every cost model and uses the default settings.
PsiCT        = preparePIMLOPModel_batchedProcess(boneMeshCT);
PsiCT.pdTree = buildPIMLOPPDTree_batchedProcess(PsiCT.mesh, PsiCT.validFaceMask);

%% PACKAGE ESTIMATION DATA

% Put everything the cost functions and optimizer need into one struct.
% Geometry is named after the frame its coordinates are in (boneMeshCT,
% imagePlanesRef) so code using it can see at a glance whether a transform
% is still needed. The config is included so a cost function has all its
% settings at hand without any extra argument.
data.bone                    = targetBone;
data.boneName                = char(string(currentBone.name));
data.boneMeshCT              = boneMeshCT;
data.T_bone_CT               = T_bone_CT;
data.T_CT_ref_initial        = T_CT_ref_initial;
data.T_bone_ref_initial      = T_bone_ref_initial;
data.imagePlanesRef          = imagePlanesRef;
data.hasBoneSurface          = boneSurface.isAvailable;
data.boneSurfaceMetadata     = boneSurface.extractionMetadata;
data.boneSurfaceMeasurements = boneSurface.measurements;
data.config                  = config;

% Inputs that only one cost model needs go under data.extra.<model>. This
% keeps the shared top-level fields the same for all cost models, and makes
% it clear which pre-computed pieces belong to which model.
data.extra.pimlop.PsiCT      = PsiCT;

% Intensity cost models (intensityLine_v1 and the combined models built on
% it) read the images through a Gaussian blur so they still get a hint
% about the bone when the predicted line is slightly off the echo. Blurring
% every image is slow, so it is done here once. Its width is a
% hyperparameter, and this function runs once per hyperparameter
% combination, so each combination gets its own blur. Cost models without
% this setting skip the work.
if isfield(config.cost.parameters, 'intensitySmoothingSigmaMm')
    data.extra.intensityLine.smoothedImages = smoothUltrasoundImages( ...
        imagePlanesRef, config.cost.parameters.intensitySmoothingSigmaMm);
end

% Everything about the true answer goes into a separate struct. Only the
% evaluation code after the optimization receives it, so the estimation can
% never use the ground truth, even by mistake. The snapshot sources are
% kept here too, to trace each result back to the original recording.
validationData.bone                            = targetBone;
validationData.groundTruthIntersections        = groundTruthIntersections;
validationData.snapshotSources                 = snapshotSources;
validationData.groundTruthBonePose.bone        = targetBone;
validationData.groundTruthBonePose.T_CT_ref    = T_CT_ref_groundTruth;
validationData.groundTruthBonePose.T_bone_ref  = T_bone_ref_groundTruth;
validationData.groundTruthBonePose.boneMeshRef = boneMeshRefGroundTruth;

% A short summary lets the user confirm that the expected number of images
% and a sensible PD-tree were prepared, before the long optimization starts.
% It is optional so that large sweeps do not flood the command window.
if config.logging.printPreparationProgress
    fprintf('Prepared %d image planes for bone %s.\n', ...
        numel(imagePlanesRef), targetBone);
    fprintf('Prepared P-IMLOP PD-tree: %d valid faces, %d nodes, %d leaves.\n', ...
        PsiCT.pdTree.numberOfDatums, PsiCT.pdTree.numberOfNodes, ...
        PsiCT.pdTree.numberOfLeaves);
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


function validateBoneSurfaceMeasurements(boneSurface)
%VALIDATEBONESURFACEMEASUREMENTS Check collected 2D and 3D bone surfaces.
% This function validates the coordinate convention and every collected
% surface record independently from the snapshots. It is needed so future
% cost functions receive surfaces with a clear and consistent meaning.
%
% Input:
%   boneSurface - Struct returned by collectBoneSurfaceMeasurements.
%
% Output:
%   None. The function stops with an error when a surface is invalid.

metadata = boneSurface.extractionMetadata;

% These metadata fields explain how image coordinates follow the ultrasound
% beam and must be present before their values can be interpreted.
requiredMetadataFields = {'coordinateConvention', 'beamAxis', 'beamDirection'};
if ~all(isfield(metadata, requiredMetadataFields))
    error('prepareBonePoseOptimizationInputs:MissingSurfaceCoordinateMetadata', ...
          'Surface metadata must define coordinate and beam conventions.');
end

coordinateConvention = metadata.coordinateConvention;
coordinateFields = {'indexBase', 'coordinateOrder', ...
    'imageAxisByCoordinate', 'origin'};
if ~isstruct(coordinateConvention) || ...
        ~all(isfield(coordinateConvention, coordinateFields)) || ...
        coordinateConvention.indexBase ~= 1 || ...
        ~isequal(string(coordinateConvention.coordinateOrder), ["x", "y"]) || ...
        ~isequal(string(coordinateConvention.imageAxisByCoordinate), ...
                 ["column", "row"]) || ...
        string(coordinateConvention.origin) ~= "topLeftPixelCenter"
    error('prepareBonePoseOptimizationInputs:UnsupportedSurfaceCoordinateConvention', ...
          'Bone surfaces must use one-based [x,y] = [column,row] image coordinates.');
end

% Increasing image rows must follow the beam direction used during surface
% extraction and 3D recovery.
beamAxis = metadata.beamAxis;
beamDirection = metadata.beamDirection;
if ~isstruct(beamAxis) || ~isstruct(beamDirection) || ...
        ~all(isfield(beamAxis, {'name', 'matlabDimension'})) || ...
        ~all(isfield(beamDirection, {'name', 'rowIndexStep'})) || ...
        string(beamAxis.name) ~= "row" || beamAxis.matlabDimension ~= 1 || ...
        string(beamDirection.name) ~= "increasingRowIndex" || ...
        beamDirection.rowIndexStep ~= 1
    error('prepareBonePoseOptimizationInputs:UnsupportedSurfaceBeamConvention', ...
          'Bone surfaces must use increasing row index as the beam direction.');
end

% Validate the fields and coordinate arrays consumed by future cost models.
measurements = boneSurface.measurements;
requiredMeasurementFields = {'sourceIndex', 'status', ...
    'surfaceCoordinatesXY', 'surfaceCoordinatesXYZRef'};
allowedStatuses = ["extracted", "noSurface", "skippedUnprocessed"];

for measurementIndex = 1:numel(measurements)
    measurement = measurements(measurementIndex);
    if ~all(isfield(measurement, requiredMeasurementFields))
        error('prepareBonePoseOptimizationInputs:InvalidSurfaceRecord', ...
              'Surface measurement %d is missing a required field.', ...
              measurementIndex);
    end

    % Empty surfaces remain valid; each cost model decides how their status
    % contributes to its objective.
    if ~any(string(measurement.status) == allowedStatuses)
        error('prepareBonePoseOptimizationInputs:InvalidSurfaceStatus', ...
              'Surface measurement %d has unsupported status %s.', ...
              measurementIndex, string(measurement.status));
    end

    surfaceCoordinatesXY = measurement.surfaceCoordinatesXY;
    surfacePointsRef      = measurement.surfaceCoordinatesXYZRef;
    if ~isnumeric(surfaceCoordinatesXY) || ...
            size(surfaceCoordinatesXY, 2) ~= 2 || ...
            ~isnumeric(surfacePointsRef) || size(surfacePointsRef, 2) ~= 3 || ...
            size(surfaceCoordinatesXY, 1) ~= size(surfacePointsRef, 1) || ...
            ~all(isfinite(surfaceCoordinatesXY), 'all') || ...
            ~all(isfinite(surfacePointsRef), 'all')
        error('prepareBonePoseOptimizationInputs:InvalidSurfaceCoordinates', ...
              'Surface measurement %d must contain matching finite N-by-2 and N-by-3 coordinates.', ...
              measurementIndex);
    end

    % Surface normals are optional here so historical ICPLike_v1 and
    % intensity artifacts remain usable. When either new field is present,
    % require the complete row-aligned contract so a future P-IMLOP model
    % cannot silently consume ambiguous orientation data.
    hasNormalValues = isfield(measurement, 'surfaceNormalXY');
    hasNormalMask = isfield(measurement, 'surfaceNormalMask');
    if hasNormalValues ~= hasNormalMask
        error('prepareBonePoseOptimizationInputs:IncompleteSurfaceNormals', ...
            ['Surface measurement %d must provide surfaceNormalXY and ' ...
             'surfaceNormalMask together.'], measurementIndex);
    end
    if hasNormalValues
        validateOptionalSurfaceNormals( ...
            measurement, size(surfaceCoordinatesXY, 1), measurementIndex);
    end
end
end


function validateOptionalSurfaceNormals(measurement, numberOfPoints, measurementIndex)
%VALIDATEOPTIONALSURFACENORMALS Check the row-aligned 2-D normal contract.
% Normals remain optional at the generic preparation boundary, but malformed
% normals must be rejected when present so downstream cost models receive an
% unambiguous validity mask.
%
% Inputs:
%   measurement      : One prepared bone-surface measurement record.
%   numberOfPoints   : Number of corresponding surface coordinate rows.
%   measurementIndex : One-based index used in diagnostic messages.
%
% Outputs:
%   None. The function throws a descriptive error for invalid artifacts.

surfaceNormalXY = measurement.surfaceNormalXY;
surfaceNormalMask = measurement.surfaceNormalMask;
if ~isnumeric(surfaceNormalXY) || ...
        ~isequal(size(surfaceNormalXY), [numberOfPoints, 2]) || ...
        ~islogical(surfaceNormalMask) || ...
        ~isequal(size(surfaceNormalMask), [numberOfPoints, 1])
    error('prepareBonePoseOptimizationInputs:InvalidSurfaceNormalShape', ...
        ['Surface measurement %d normals must be N-by-2 numeric values and ' ...
         'an N-by-1 logical mask aligned with the surface coordinates.'], ...
        measurementIndex);
end

validNormals = surfaceNormalXY(surfaceNormalMask, :);
invalidNormals = surfaceNormalXY(~surfaceNormalMask, :);
normalLengths = vecnorm(validNormals, 2, 2);
if any(~isfinite(validNormals), 'all') || ...
        any(abs(normalLengths - 1) > 1e-10) || ...
        any(~isnan(invalidNormals), 'all')
    error('prepareBonePoseOptimizationInputs:InvalidSurfaceNormalValues', ...
        ['Surface measurement %d valid normals must be finite unit vectors, ' ...
         'and invalid rows must be [NaN,NaN].'], measurementIndex);
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
