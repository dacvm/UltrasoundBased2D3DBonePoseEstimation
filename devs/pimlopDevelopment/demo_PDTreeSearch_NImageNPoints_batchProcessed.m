clear; clc; close all;

%% BATCHED P-IMLOP PD-TREE SEARCH: ALL IMAGES WITH ALL OR SUBSAMPLED POINTS
%
% This is the next step after demo_PDTreeSearch_1ImageNPoints_batchProcessed.
% The numbered sections and the per-image variable names remain familiar:
%
%   1. load the same prepared ultrasound and tibia data;
%   2. collect and optionally subsample each image's valid oriented points;
%   3. prepare the complete CT tibia and build its PD-tree only once;
%   4. express each image's queries in the fixed CT search frame;
%   5. search once per image, batching the measurement points within it;
%   6. report per-image and combined correspondence results;
%   7. show every image and correspondence together in one ref-frame overview.
%
% Scope of this example
% ---------------------
% The default uses every image and every valid measurement in the saved setup.
% Lowering measurementSubsampleFraction retains a distributed subset within
% EACH image. The full tibia mesh remains available to every search.
% This evaluates the saved initial pre-registration; it does not optimize the
% bone pose, alter the P-IMLOP objective, or constrain Y to the image plane.
%
% The key difference from one image is its local normal coordinate system.
% Each image has its own R_image_CT, so it must have its own batched search
% call. The ordinary image loop shares the same PsiCT and uses no parfor.
%
% Within resultsByImage(planeIndex), row i of X corresponds to row i of
% YmatchesCT and EMatchValues. The combined arrays keep imageIndex together
% with sourcePointIndices so every match can be traced back to its image and
% original extracted surface row. Local 2D normals are meaningful only with
% that image identity; their ref-frame 3D versions can be plotted together.


%% 1. LOAD THE PREPARED ULTRASOUND AND BONE DATA

% Resolve paths from this script, exactly as in the single-image demo.
demoFolder    = fileparts(mfilename('fullpath'));
projectRoot   = fileparts(fileparts(demoFolder));
setupFilePath = fullfile(demoFolder, 'optimization_setup.mat');
addpath(genpath(fullfile(projectRoot, 'functions')));
addpath(demoFolder);
load(setupFilePath, 'data');

% Keep the experiment controls together. Fraction 1 uses all valid points;
% 0.3 keeps approximately 30 percent independently within every image.
% The shared covariance remains expressed in each image's LOCAL axes.
measurementSubsampleFraction = 0.5;
positionStandardDeviationImageMm = [1.0; 1.0; 1.5];
positionCovarianceImage = diag(positionStandardDeviationImageMm .^ 2);
kappa = 50;
searchOptions = struct('UsePruning',true,'QueryBatchSize',64,'MaxPairsPerBatch',8192);
imageFaceAlpha = 0.15;
validateattributes(measurementSubsampleFraction, {'numeric'}, ...
    {'real','finite','scalar','>',0,'<=',1}, mfilename, 'measurementSubsampleFraction');


%% 2. COLLECT EACH IMAGE'S ORIENTED MEASUREMENTS X

% The setup pairs imagePlanesRef(i) with boneSurfaceMeasurements(i).
% Source and sequence identifiers can repeat across acquisition groups;
% use the array position planeIndex as the identity within this demonstration.
numberOfImages = numel(data.imagePlanesRef);
if numberOfImages == 0 || numel(data.boneSurfaceMeasurements) ~= numberOfImages
    error('demo_PDTreeSearch_NImageNPoints_batchProcessed:ImageCountMismatch', ...
        'The setup must contain equally sized, nonempty image and measurement arrays.');
end

% Each entry is a small record of the same quantities used by the one-image
% script. Preallocating entries also lets an empty image keep its original
% index and an explicit skip reason without shifting subsequent images.
emptyResult = struct('imageIndex',0,'status',"pending",'skipReason',"", ...
    'sourceMetadata',struct(),'numberOfValidMeasurementsBeforeSubsampling',0, ...
    'numberOfMeasurements',0,'X',struct(),'XqueriesCT',struct(), ...
    'T_image_CT',[],'R_image_CT',[],'YmatchesCT',struct(), ...
    'YmatchesRef',struct(),'measurementNormals3DRef',[], ...
    'EMatchValues',[],'batchSearchDetails',struct(),'totalSearchSeconds',0);
resultsByImage = repmat(emptyResult,numberOfImages,1);

% Loop for all image planes
for planeIndex = 1:numberOfImages

    % Get the current selected image plane
    selectedPlane              = data.imagePlanesRef(planeIndex);
    selectedSurfaceMeasurement = data.boneSurfaceMeasurements(planeIndex);
    resultsByImage(planeIndex).imageIndex = planeIndex;

    % This demo uses the tibia model. Reject another bone association rather
    % than silently searching that image's measurements against the tibia.
    if ~isfield(selectedPlane,'bone') ...
            || ~isfield(selectedSurfaceMeasurement,'bone') ...
            || ~strcmpi(string(selectedPlane.bone),"T") ...
            || ~strcmpi(string(selectedSurfaceMeasurement.bone),"T")
        error('demo_PDTreeSearch_NImageNPoints_batchProcessed:BoneMismatch', ...
            'Image %d and its measurements must both be associated with tibia (T).', planeIndex);
    end

    % A valid rigid image pose is needed even if its measurements are empty,
    % because all image planes will still be shown in the final overview.
    T_image_ref = selectedPlane.T_image_ref;
    if ~isequal(size(T_image_ref),[4 4]) ...
            || any(~isfinite(T_image_ref),'all') ...
            || norm(T_image_ref(4,:)-[0 0 0 1]) > 1e-10 ...
            || norm(T_image_ref(1:3,1:3).'*T_image_ref(1:3,1:3)-eye(3),'fro') > 1e-6 ...
            || abs(det(T_image_ref(1:3,1:3))-1) > 1e-6
        error('demo_PDTreeSearch_NImageNPoints_batchProcessed:InvalidImagePose', ...
              'Image %d has an invalid rigid pose.', planeIndex);
    end

    % Preserve the original extraction identifiers as metadata, not as a
    % substitute for planeIndex. Their values may repeat between image groups.
    metadataFields = {'sourceIndex','sequencePosition','groupName','groupPath','status'};
    for metadataNumber = 1:numel(metadataFields)
        fieldName = metadataFields{metadataNumber};
        if isfield(selectedSurfaceMeasurement,fieldName)
            resultsByImage(planeIndex).sourceMetadata.(fieldName) = selectedSurfaceMeasurement.(fieldName);
        end
    end
    % A valid P-IMLOP measurement requires a 3D position, a 2D image-plane
    % normal, and a true entry in surfaceNormalMask. Check these inputs before
    % forming the set so an older or incomplete setup fails with a useful message.
    requiredMeasurementFields = { ...
        'surfaceCoordinatesXYZRef', ...
        'surfaceNormalXY', ...
        'surfaceNormalMask'};
    if ~all(isfield(selectedSurfaceMeasurement, requiredMeasurementFields))
        error('demo_PDTreeSearch_NImageNPoints_batchProcessed:MissingMeasurementFields', ...
              'Image %d lacks positions, normals, or a normal-validity mask.', planeIndex);
    end

    allMeasurementPositionsRef   = double(selectedSurfaceMeasurement.surfaceCoordinatesXYZRef);
    allMeasurementNormals2DImage = double(selectedSurfaceMeasurement.surfaceNormalXY);
    surfaceNormalMask            = logical(selectedSurfaceMeasurement.surfaceNormalMask(:));

    % An extraction with no surface may store plain [] instead of 0-by-3
    % positions and 0-by-2 normals. Give that genuinely empty record its
    % expected shapes so it reaches the documented skip path below. A
    % partially missing record still fails the row-alignment check.
    if isempty(allMeasurementPositionsRef) ...
            && isempty(allMeasurementNormals2DImage) ...
            && isempty(surfaceNormalMask)
        allMeasurementPositionsRef = zeros(0,3);
        allMeasurementNormals2DImage = zeros(0,2);
    end

    % Each row of the position, normal, and mask arrays must refer to the same
    % extracted surface sample. A row-count mismatch would destroy the X_i-to-Y_i
    % correspondence that the later registration cost depends upon.
    numberOfStoredMeasurements = size(allMeasurementPositionsRef, 1);
    if size(allMeasurementPositionsRef, 2) ~= 3 ...
            || size(allMeasurementNormals2DImage, 2) ~= 2 ...
            || size(allMeasurementNormals2DImage, 1) ~= numberOfStoredMeasurements ...
            || numel(surfaceNormalMask) ~= numberOfStoredMeasurements
        error('demo_PDTreeSearch_NImageNPoints_batchProcessed:InconsistentMeasurementSizes', ...
              'Image %d has inconsistent position, normal, or mask dimensions.', planeIndex);
    end

    validMeasurementIndices = find(surfaceNormalMask);
    if isempty(validMeasurementIndices)
        % An image with no usable normals contributes no correspondences. Keep
        % its record and plane, report the reason, and continue with other images.
        resultsByImage(planeIndex).status = "skipped";
        resultsByImage(planeIndex).skipReason = "No measurements with valid normals";
        continue;
    end

    % Keep only measurements whose normal estimator marked them as valid. Check
    % the retained values instead of silently discarding unexpected nonfinite or
    % zero normals, because such data would make E_match impossible to interpret.
    measurementPositionsRef   = allMeasurementPositionsRef(validMeasurementIndices, :);
    measurementNormals2DImage = allMeasurementNormals2DImage(validMeasurementIndices, :);
    measurementNormalLengths  = vecnorm(measurementNormals2DImage, 2, 2);
    if any(~isfinite(measurementPositionsRef), 'all') ...
            || any(~isfinite(measurementNormals2DImage), 'all') ...
            || any(measurementNormalLengths <= 1e-12)
        error('demo_PDTreeSearch_NImageNPoints_batchProcessed:InvalidMeasurement', ...
              'Image %d has an invalid position or normal marked as valid.',planeIndex);
    end

    % Normalize every measured direction row by row. The estimator already
    % returns unit normals, but repeating this inexpensive step prevents harmless
    % floating-point drift from entering the orientation comparison.
    measurementNormals2DImage = measurementNormals2DImage ./ measurementNormalLengths;

    % 2A. RETAIN AN EVENLY DISTRIBUTED FRACTION OF THE VALID MEASUREMENTS

    % measurementSubsampleFraction was set in Section 1 and is shared by all
    % images. Apply the same rule as the single-image script within THIS image.
    % Uniform spacing below means row order along the extracted curve, not an
    % equal distance in millimetres along the physical surface.
    % The ultrasound measurements form an ordered surface curve. Choose equally
    % spaced row positions along that complete valid sequence, rather than taking
    % one consecutive block. For nine points and fraction 0.5, this produces the
    % indices [1, 3, 5, 7, 9], matching the intended distributed sampling rule.
    numberOfValidMeasurementsBeforeSubsampling = size(measurementPositionsRef, 1);
    numberOfMeasurementsToKeep = max(1, round(measurementSubsampleFraction * numberOfValidMeasurementsBeforeSubsampling));
    if numberOfMeasurementsToKeep == 1
        % A single retained sample cannot include both curve endpoints. Use the
        % middle sample so this extreme setting still represents the whole curve.
        subsampleIndicesWithinValidSet = round((numberOfValidMeasurementsBeforeSubsampling + 1) / 2);
    else
        % With two or more retained samples, LINSPACE includes both endpoints and
        % distributes every intermediate selection across the full valid curve.
        subsampleIndicesWithinValidSet = round(linspace(1, numberOfValidMeasurementsBeforeSubsampling, numberOfMeasurementsToKeep)).';
    end

    % Apply exactly the same retained rows to positions, normals, and original
    % source indices. This preserves every X_i's position-normal pairing and lets
    % a result still be traced to its original row in the extracted image curve.
    measurementPositionsRef   = measurementPositionsRef(subsampleIndicesWithinValidSet, :);
    measurementNormals2DImage = measurementNormals2DImage(subsampleIndicesWithinValidSet, :);
    validMeasurementIndices   = validMeasurementIndices(subsampleIndicesWithinValidSet);

    % X represents the retained measured oriented-point set for this image. Row
    % i of position3DRef and normal2DImage belongs to the same measurement X_i.
    % sourcePointIndices preserves the corresponding row in the original surface
    % extraction, which is useful when a result needs to be traced back later.
    X = struct();
    X.position3DRef      = measurementPositionsRef;
    X.normal2DImage      = measurementNormals2DImage;
    X.sourcePointIndices = validMeasurementIndices;
    numberOfMeasurements = size(X.position3DRef, 1);


    % Save this image's X before the next loop iteration reuses the variable.
    resultsByImage(planeIndex).X = X;
    resultsByImage(planeIndex).numberOfValidMeasurementsBeforeSubsampling = numberOfValidMeasurementsBeforeSubsampling;
    resultsByImage(planeIndex).numberOfMeasurements = numberOfMeasurements;
    resultsByImage(planeIndex).status = "ready";
end

processedImageMask    = [resultsByImage.status] == "ready";
processedPlaneIndices = find(processedImageMask);
if isempty(processedPlaneIndices)
    error('demo_PDTreeSearch_NImageNPoints_batchProcessed:NoValidMeasurements', ...
          'No image contains a measurement with a valid normal.');
end


%% 3. PREPARE THE CT MODEL Psi AND BUILD ONE REUSABLE PD-TREE

% preparePIMLOPModel_batchedProcess keeps the CT triangulation and computes the area,
% validity, and unit face normal of every triangle. PsiCT is the complete
% oriented model set searched for every measurement in X.
PsiCT = preparePIMLOPModel_batchedProcess(data.boneMeshCT);

% buildPIMLOPPDTree_batchedProcess groups all valid triangles into principal-direction
% bounding boxes. This is deliberately outside the measurement loop: model
% preparation is a one-time operation and the same tree serves every X_i.
PsiCT.pdTree = buildPIMLOPPDTree_batchedProcess(PsiCT.mesh, PsiCT.validFaceMask);


%% 4. EXPRESS ALL QUERIES IN THE FIXED CT SEARCH FRAME
%
% The PD-tree was built once in the CT coordinate frame, so every query must
% also be expressed in CT before the search can begin. There are two related
% coordinate-frame paths in this section:
%
%   Measurement positions:  ref   --T_ref_CT_candidate--> CT
%
%   Image orientation:      image --T_image_ref---------> ref
%                                 --T_ref_CT_candidate--> CT
%
% The second path is needed because each 2-D measurement normal is stored in
% its own ultrasound-image coordinates. Later, the search uses R_image_CT to
% relate that local 2-D direction to candidate surface normals from the CT
% model.

% 4A. Select and validate the candidate bone pose =========================
%
% T_CT_ref_candidate maps a point from CT into ref:
%
%   p_ref = T_CT_ref_candidate * p_CT
%
% In this demonstration, the saved pre-registration is the single candidate
% pose being evaluated. During pose optimization, the optimizer will provide
% a different T_CT_ref_candidate at every cost-function evaluation.
T_CT_ref_candidate = data.T_CT_ref_initial;

candidatePoseHasExpectedSize = isequal(size(T_CT_ref_candidate), [4 4]);
if ~candidatePoseHasExpectedSize
    error('demo_PDTreeSearch_NImageNPoints_batchProcessed:InvalidBonePose', ...
          'The candidate bone pose must be a finite rigid transform.');
end

R_CT_ref_candidate = T_CT_ref_candidate(1:3, 1:3);
t_CT_ref_candidate = T_CT_ref_candidate(1:3, 4);

candidatePoseIsFinite              = all(isfinite(T_CT_ref_candidate), 'all');
candidatePoseHasHomogeneousLastRow = norm(T_CT_ref_candidate(4,:) - [0 0 0 1]) <= 1e-10;
candidateRotationIsOrthonormal     = norm(R_CT_ref_candidate.' * R_CT_ref_candidate - eye(3), 'fro') <= 1e-6;
candidateRotationIsProper          = abs(det(R_CT_ref_candidate) - 1) <= 1e-6;
if ~candidatePoseIsFinite ...
        || ~candidatePoseHasHomogeneousLastRow ...
        || ~candidateRotationIsOrthonormal ...
        || ~candidateRotationIsProper
    error('demo_PDTreeSearch_NImageNPoints_batchProcessed:InvalidBonePose', ...
          'The candidate bone pose must be a finite rigid transform.');
end

% 4B. Invert the candidate pose once for all ultrasound images ============
%
% The model pose above maps CT -> ref, but the fixed PD-tree requires the
% opposite direction, ref -> CT. For a rigid transform [R,t], its inverse is
% [R', -R'*t]. We construct that inverse explicitly so the direction of the
% transformation remains visible in the variable name and in the code:
%
%   p_CT = T_ref_CT_candidate * p_ref
%
% This inverse is shared by every ultrasound image because all measurements
% use the same ref frame and are evaluated against the same candidate bone
% pose.
T_ref_CT_candidate = eye(4);
T_ref_CT_candidate(1:3, 1:3) = R_CT_ref_candidate.';
T_ref_CT_candidate(1:3, 4)   = -R_CT_ref_candidate.' * t_CT_ref_candidate;

% 4C. Propagate every image and its measurements into CT ==================
%
% Only the image-specific work belongs inside this loop. Each image has its
% own pose in ref, while T_ref_CT_candidate is common to all images.
for planeIndex = processedPlaneIndices

    % Retrieve this image plane and the measurement set prepared from it.
    % X.position3DRef is already expressed in ref. X.normal2DImage remains a
    % 2-D direction in the local coordinate system of this ultrasound image.
    selectedPlane = data.imagePlanesRef(planeIndex);
    X = resultsByImage(planeIndex).X;

    % ----- Propagate the ultrasound-image frame into CT -----------------
    % T_image_ref maps image -> ref, and T_ref_CT_candidate maps ref -> CT.
    % Matrix transformations compose from right to left, so their product is
    %
    %   p_CT = T_ref_CT_candidate * T_image_ref * p_image
    %        = T_image_CT * p_image.
    %
    % This two-step propagation is the important connection between an
    % image-local normal and the fixed CT model. The translation is relevant
    % to image points, while the rotation R_image_CT is the part later needed
    % to compare directions and normals.
    T_image_ref = selectedPlane.T_image_ref;
    T_image_CT  = T_ref_CT_candidate * T_image_ref;
    R_image_CT  = T_image_CT(1:3,1:3);

    % ----- Transform the measurement positions from ref into CT --------
    % These points have already been converted from image coordinates to ref
    % earlier in the script. Therefore, apply only the remaining ref -> CT
    % transform here. Applying T_image_CT would incorrectly repeat the
    % image -> ref step.
    measurementPositionsCT = applyRigidTransform(X.position3DRef, T_ref_CT_candidate);

    % ----- Assemble the CT-frame query batch ----------------------------
    % Query positions are now in the PD-tree's CT frame. The measured normal
    % components deliberately stay in their original 2-D image coordinates;
    % searchPDTreePIMLOP_batchedProcess receives R_image_CT separately and
    % uses it to perform the required orientation comparison consistently.
    XqueriesCT = struct();
    XqueriesCT.position3D    = measurementPositionsCT;
    XqueriesCT.normal2DImage = X.normal2DImage;

    % Save all image-specific CT-frame quantities together. Section 5 can
    % then perform the batched search without repeating any transformations.
    resultsByImage(planeIndex).T_image_CT = T_image_CT;
    resultsByImage(planeIndex).R_image_CT = R_image_CT;
    resultsByImage(planeIndex).XqueriesCT = XqueriesCT;
end


%% 5. FIND ONE MOST-LIKELY MODEL POINT Y_i FOR EVERY X_i IN EACH IMAGE

% 5A. Search each ultrasound image with its own orientation ================
%
% All query positions and all model triangles are now expressed in CT, but
% the measured normals are still 2-D directions in their respective image
% frames. Consequently, each image must be searched with its own R_image_CT.
% That rotation tells the search how this particular ultrasound image is
% oriented relative to the fixed CT model.
%
% This is why the measurements are processed one image batch at a time. If
% measurements from every image were concatenated first and searched using
% one R_image_CT, normals from the other images would be projected using the
% wrong image-plane orientation. Their orientation costs, and therefore
% possibly their selected correspondences, would be incorrect.
%
% The following quantities do remain common to every image batch:
%
%   PsiCT                  - the fixed CT mesh and its fixed PD-tree
%   positionCovarianceImage - positional uncertainty defined in image axes
%   kappa                  - concentration of the measured normal direction
%   searchOptions          - numerical and traversal settings
%
% The loop changes only XqueriesCT and R_image_CT for the current image.
for planeIndex = processedPlaneIndices

    % ----- Retrieve the current image-specific search inputs ------------
    % XqueriesCT.position3D is already in CT. Its normal2DImage rows still
    % belong to this image's local 2-D frame. R_image_CT is therefore the
    % required bridge between those local directions and the CT-frame model
    % normals evaluated by the correspondence search.
    XqueriesCT = resultsByImage(planeIndex).XqueriesCT;
    R_image_CT = resultsByImage(planeIndex).R_image_CT;
    numberOfMeasurements = resultsByImage(planeIndex).numberOfMeasurements;

    % Give the user visible progress because a separate batched PD-tree
    % traversal is performed for every retained ultrasound image.
    fprintf('Searching image %d / %d: %d retained measurements...\n', planeIndex, numberOfImages, numberOfMeasurements);

    % ----- Find one most-likely model correspondence for every X_i ------
    % The batched search evaluates the P-IMLOP match cost while traversing
    % the fixed PD-tree. For every measurement X_i, it returns:
    %
    %   YmatchesCT(i)       - the selected point and normal on the CT mesh
    %   EMatchValues(i)     - the winning P-IMLOP correspondence cost
    %   batchSearchDetails  - diagnostics describing the completed search
    %
    % No rigid transformation is estimated here. We are evaluating the one
    % candidate pose chosen in Section 4 and finding its correspondences.
    allSearchTimer = tic;
    [YmatchesCT, EMatchValues, batchSearchDetails] = ...
        searchPDTree_batchedProcess(XqueriesCT, PsiCT, R_image_CT,positionCovarianceImage, kappa, searchOptions);
    totalSearchSeconds = toc(allSearchTimer);

    % ----- Keep this image's outputs grouped with its original inputs ----
    % Storing results by image preserves the local-frame association. It
    % also makes per-image inspection possible before results are combined
    % for the global report and visualization below.
    resultsByImage(planeIndex).YmatchesCT = YmatchesCT;
    resultsByImage(planeIndex).EMatchValues = EMatchValues;
    resultsByImage(planeIndex).batchSearchDetails = batchSearchDetails;
    resultsByImage(planeIndex).totalSearchSeconds = totalSearchSeconds;
    resultsByImage(planeIndex).status = "processed";
end

% 5B. Combine the completed per-image correspondence sets =================
%
% Concatenation is safe only AFTER every image has been searched with its own
% R_image_CT. The combined arrays are convenient for computing whole-dataset
% statistics and for drawing all correspondences in one figure.
%
% The comma-separated structure expansion below follows processed image
% order. vertcat then preserves that image order and, within each image, the
% original order of its retained measurements. Thus row i remains aligned
% across X, YmatchesCT, EMatchValues, and the diagnostic arrays assembled
% later in this section.
Xsets = [resultsByImage(processedImageMask).X];
Ysets = [resultsByImage(processedImageMask).YmatchesCT];

% Combine all measurement-side quantities. The 3-D positions share the ref
% frame, but normal2DImage contains local 2-D components from several image
% frames. X.imageIndex records which local frame belongs to every row.
X = struct();
X.position3DRef      = vertcat(Xsets.position3DRef);
X.normal2DImage      = vertcat(Xsets.normal2DImage);
X.sourcePointIndices = vertcat(Xsets.sourcePointIndices);
measurementsPerProcessedImage = [resultsByImage(processedImageMask).numberOfMeasurements].';
X.imageIndex         = repelem(processedPlaneIndices(:), measurementsPerProcessedImage);

% Combine the corresponding model-side quantities. All Y_i positions and
% normals are expressed in the single fixed CT frame, so they can be placed
% directly into common arrays without any additional transformation.
YmatchesCT = struct();
YmatchesCT.position3D = vertcat(Ysets.position3D);
YmatchesCT.normal3D   = vertcat(Ysets.normal3D);
YmatchesCT.faceIndex  = vertcat(Ysets.faceIndex);

% EMatchValues uses exactly the same row order as X and YmatchesCT. The
% number of combined measurements is retained under the familiar variable
% name used by the reporting and visualization sections.
EMatchValues = vertcat(resultsByImage(processedImageMask).EMatchValues);
numberOfMeasurements = size(X.position3DRef,1);

% 5C. Create a traceability table for every combined row ==================
%
% A row number in a combined array is not enough to identify its source.
% correspondenceIndex maps each row back to both the ultrasound image and
% the original point row in data.boneSurfaceMeasurements. This is useful
% when a suspicious correspondence seen in a figure needs to be inspected
% in the source data.
correspondenceIndex = table(X.imageIndex, X.sourcePointIndices, 'VariableNames', {'imageIndex','sourcePointIndex'});

% 5D. Combine search diagnostics in the same correspondence order =========
%
% Search details are first collected by image and then concatenated by
% measurement. Because this uses the same processed-image order as Block 5B,
% every diagnostic row remains paired with the same X_i and Y_i.
searchDetailsByImage         = [resultsByImage(processedImageMask).batchSearchDetails];
matchDetailsByImage          = [searchDetailsByImage.matchDetails];
euclideanDistancesMm         = vertcat(matchDetailsByImage.euclideanDistanceMm);
orientationAnglesDeg         = vertcat(matchDetailsByImage.orientationAngleDeg);
projectionIsDefined          = vertcat(matchDetailsByImage.projectionIsDefined);
facesEvaluatedPerMeasurement = vertcat(searchDetailsByImage.numberOfFacesEvaluated);
nodesPrunedPerMeasurement    = vertcat(searchDetailsByImage.numberOfNodesPruned);

% 5E. Prepare concise aliases used by later reports and figures ===========
%
% These variables do not transform or recompute the selected model points.
% They simply give later sections short, descriptive names for commonly used
% fields and identify the unique mesh faces containing the selected Y_i.
YmatchPositionsCT = YmatchesCT.position3D;
YmatchNormalsCT   = YmatchesCT.normal3D;
YmatchFaceIndices = YmatchesCT.faceIndex;
uniqueMatchedFaceIndices = unique(YmatchFaceIndices,'stable');


%% 6. PRINT A SHORT, USER-ORIENTED RESULT SUMMARY

% One row per image makes a sparse or poorly matched image visible. Skipped
% images keep their index and reason instead of disappearing from the report.
fprintf('\nP-IMLOP all-image, many-point BATCHED PD-tree demo\n');
fprintf(' Image   Valid   Used   Mean distance(mm)   Mean angle(deg)   Mean E_match   Search(s)\n');
for planeIndex = 1:numberOfImages
    result = resultsByImage(planeIndex);
    if result.status == "skipped"
        fprintf(' %5d       0      0   SKIPPED: %s\n',planeIndex,result.skipReason);
        continue;
    end
    details = result.batchSearchDetails.matchDetails;
    fprintf(' %5d   %5d  %5d       %8.3f          %8.2f         %8.3f      %7.3f\n', ...
        planeIndex,result.numberOfValidMeasurementsBeforeSubsampling, ...
        result.numberOfMeasurements,mean(details.euclideanDistanceMm), ...
        mean(details.orientationAngleDeg),mean(result.EMatchValues),result.totalSearchSeconds);
end

% Global means are over POINTS, not means of image means. An image containing
% more retained measurements contributes more rows. The summed cost describes
% this fixed pose and selected point set; subsampling changes that sum's scale.
numberOfProcessedImages      = nnz(processedImageMask);
numberOfSkippedImages        = numberOfImages-numberOfProcessedImages;
numberOfValidMeasurementsBeforeSubsampling = sum([resultsByImage.numberOfValidMeasurementsBeforeSubsampling]);
totalSearchSeconds           = sum([resultsByImage.totalSearchSeconds]);
averageFacesEvaluated        = mean(facesEvaluatedPerMeasurement);
averageFacesEvaluatedPercent = 100*averageFacesEvaluated/PsiCT.pdTree.numberOfDatums;
fprintf('\n  Images processed / skipped       : %d / %d\n',                    numberOfProcessedImages,numberOfSkippedImages);
fprintf('  Valid / retained measurements    : %d / %d (fraction %.3f)\n',      numberOfValidMeasurementsBeforeSubsampling, numberOfMeasurements, measurementSubsampleFraction);
fprintf('  Valid model triangles            : %d\n',                           PsiCT.pdTree.numberOfDatums);
fprintf('  PD-tree nodes / leaves           : %d / %d\n',                      PsiCT.pdTree.numberOfNodes, PsiCT.pdTree.numberOfLeaves);
fprintf('  Unique selected model faces      : %d\n',                           numel(uniqueMatchedFaceIndices));
fprintf('  X-to-Y distance, mean / max      : %.3f / %.3f mm\n',               mean(euclideanDistancesMm), max(euclideanDistancesMm));
fprintf('  Normal angle, mean / max         : %.2f / %.2f deg\n',              mean(orientationAnglesDeg), max(orientationAnglesDeg));
fprintf('  E_match, total / mean / max      : %.3f / %.3f / %.3f\n',           sum(EMatchValues), mean(EMatchValues), max(EMatchValues));
fprintf('  Average faces tested per point   : %.1f (%.2f%% of model)\n',       averageFacesEvaluated, averageFacesEvaluatedPercent);
fprintf('  Average nodes pruned per point   : %.1f\n',                         mean(nodesPrunedPerMeasurement));
fprintf('  Defined projected model normals  : %d / %d\n',                      nnz(projectionIsDefined), numberOfMeasurements);
fprintf('  Total / amortized search time    : %.3f s / %.3f ms per point\n\n', totalSearchSeconds, 1000*totalSearchSeconds/numberOfMeasurements);
% Search time sums the batched calls, including their shared preparation.
% It excludes one-time mesh/tree building, input selection, and plotting.


%% 7. DISPLAY ALL X-to-Y CORRESPONDENCES IN ref

% This figure is intended to show the complete correspondence problem in one
% common physical coordinate frame. It contains the following elements:
%
%   1. The pre-registered tibia mesh, drawn transparently in beige.
%   2. Every tracked ultrasound image plane, drawn semi-transparently.
%   3. The mesh triangles containing at least one selected Y_i, in cyan.
%   4. Retained ultrasound measurements X_i and their normals, in red.
%   5. Most-likely model correspondences Y_i and their normals, in blue.
%   6. Each model normal projected into its ultrasound plane, in green.
%   7. A grey line joining each indexed pair X_i -> Y_i.
%
% For these elements to overlay correctly, every displayed 3-D position and
% normal direction must first be expressed in ref. Measurement positions X_i
% already live in ref. The CT mesh and selected Y_i must be moved from CT to
% ref, while every measured and projected 2-D normal must be lifted through
% the pose of the particular ultrasound image from which it came.

% 7A. Transform the CT-side geometry into the display frame ===============
%
% The mesh and selected model correspondences were kept in CT during the
% PD-tree search. T_CT_ref_candidate is the candidate bone pose evaluated by
% the search, and maps their positions back into ref:
%
%   p_ref = T_CT_ref_candidate * p_CT
%
% A position is affected by both rotation and translation. A normal is a
% direction rather than a location, so translation must not be applied to
% it. With the row-vector convention used by the stored normal arrays, the
% corresponding direction conversion is:
%
%   n_ref = n_CT * R_CT_ref_candidate'
%
% After this block, the mesh vertices, Y_i positions, and Y_i normals all use
% the same ref frame as X.position3DRef.
boneFaces          = PsiCT.mesh.ConnectivityList;
bonePointsRef      = applyRigidTransform(PsiCT.mesh.Points, T_CT_ref_candidate);
YmatchPositionsRef = applyRigidTransform(YmatchPositionsCT, T_CT_ref_candidate);
YmatchNormalsRef   = YmatchNormalsCT * R_CT_ref_candidate.';

% 7B. Lift measured and projected normals through each image pose ===========
%
% A measured normal and a projected model normal are each stored as two
% components [n_x, n_y] in a local ultrasound-image plane. To display either
% direction in 3-D ref coordinates:
%
%   1. Append a zero third component: [n_x, n_y, 0]. The zero states that
%      the direction lies inside the local ultrasound image plane.
%   2. Rotate the resulting 3-D direction using this image's R_image_ref.
%
% Every tracked image can have a different orientation. Therefore, using one
% shared rotation for all normals would be incorrect. The loop fills the rows
% of the combined arrays image by image, matching the row order established
% when the correspondence results were concatenated in Section 5.
measurementNormals3DRef = zeros(numberOfMeasurements,3);
projectedYNormals3DRef = zeros(numberOfMeasurements,3);
firstRow = 1;
for planeIndex = processedPlaneIndices
    % Retrieve both types of local 2-D normal and this image's image -> ref
    % pose. The projected model normals are the exact normalized projections
    % retained by the P-IMLOP match calculation for the selected Y_i.
    selectedPlane = data.imagePlanesRef(planeIndex);
    imageX        = resultsByImage(planeIndex).X;
    R_image_ref   = selectedPlane.T_image_ref(1:3,1:3);

    % Locate this image's rows in the combined X/Y arrays. The same row range
    % applies to X.position3DRef, YmatchPositionsRef, and YmatchNormalsRef.
    numberOfImageMeasurements = resultsByImage(planeIndex).numberOfMeasurements;
    combinedRows = firstRow:(firstRow + numberOfImageMeasurements - 1);

    % Embed the local 2-D normals in the image's 3-D coordinate system, then
    % rotate them from image -> ref. Translation is intentionally excluded.
    measurementNormals3DImage = [imageX.normal2DImage, zeros(numberOfImageMeasurements,1)];
    measurementNormals3DRef(combinedRows,:) = measurementNormals3DImage * R_image_ref.';
    
    % Retrieve the projected image normal
    imageMatchDetails        = resultsByImage(planeIndex).batchSearchDetails.matchDetails;
    imageProjectedYNormals2D = imageMatchDetails.projectedYNormal2DImage;

    % Apply the same image -> ref rotation to the projected model-normal
    % directions. Their image-Z components are zero by construction, so the
    % resulting green arrows remain inside this tracked ultrasound plane.
    projectedYNormals3DImage = [imageProjectedYNormals2D, zeros(numberOfImageMeasurements,1)];
    projectedYNormals3DRef(combinedRows,:) = projectedYNormals3DImage * R_image_ref.';

    % Keep convenient per-image ref-frame results for later inspection. This
    % does not alter the matches; it only groups their display-ready values.
    resultsByImage(planeIndex).measurementNormals3DRef = measurementNormals3DRef(combinedRows,:);
    resultsByImage(planeIndex).projectedYNormals3DRef  = projectedYNormals3DRef(combinedRows,:);
    resultsByImage(planeIndex).YmatchesRef = struct( ...
        'position3D', YmatchPositionsRef(combinedRows,:), ...
        'normal3D', YmatchNormalsRef(combinedRows,:), ...
        'faceIndex', YmatchFaceIndices(combinedRows));

    firstRow = firstRow + numberOfImageMeasurements;
end

% 7C. Prepare display-only geometry for arrows and correspondence lines ====
%
% All normals are unit directions, so they would appear very short compared
% with the overall image and bone dimensions. Use one common arrow length
% based on the ultrasound-image extent. This scale affects only the plotted
% arrows; it does not change the normals or the P-IMLOP orientation cost.
imageExtentMm = max([[data.imagePlanesRef.W],[data.imagePlanesRef.H]]);
normalDisplayScale = 0.04 * imageExtentMm;

% Each correspondence should appear as an independent grey line from X_i to
% Y_i. NaN rows separate consecutive segments inside one long polyline. This
% produces the same visual result as hundreds of individual plot3 calls, but
% uses only one graphics object and is much faster to draw and manipulate.
correspondenceX = reshape([ ...
    X.position3DRef(:, 1), YmatchPositionsRef(:, 1), nan(numberOfMeasurements, 1)].', [], 1);
correspondenceY = reshape([ ...
    X.position3DRef(:, 2), YmatchPositionsRef(:, 2), nan(numberOfMeasurements, 1)].', [], 1);
correspondenceZ = reshape([ ...
    X.position3DRef(:, 3), YmatchPositionsRef(:, 3), nan(numberOfMeasurements, 1)].', [], 1);

% 7D. Create one interactive 3-D overview in ref ===========================
%
% A single axes is used so the complete spatial relationship can be judged:
% where every ultrasound plane intersects the bone, where each measurement
% lies, and which surface point it selected. Equal axis scaling prevents the
% geometry from being visually stretched along one coordinate direction.
demoFigure = figure( ...
    'Name','P-IMLOP all-image, many-point BATCHED PD-tree search demo', ...
    'Position',[80,80,1250,850]);
setupAxes = axes(demoFigure);
hold(setupAxes, 'on');
grid(setupAxes, 'on');
axis(setupAxes, 'equal');
view(setupAxes, 35, 30);
xlabel(setupAxes, 'X_{ref} (mm)');
ylabel(setupAxes, 'Y_{ref} (mm)');
zlabel(setupAxes, 'Z_{ref} (mm)');

% 7E. Draw the anatomical context: bone mesh and ultrasound planes =========
%
% Draw the complete candidate tibia pose lightly in beige. Its transparency
% provides anatomical context while allowing image planes and correspondence
% markers on the far side of the surface to remain visible.
boneHandle = patch(setupAxes, ...
    'Faces', boneFaces, ...
    'Vertices', bonePointsRef, ...
    'FaceColor', [0.84, 0.78, 0.70], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.24, ...
    'DisplayName', 'Pre-registered tibia mesh');

% Draw every tracked ultrasound image, including images skipped by the search
% because they had no valid measurements. display_image3D applies each
% T_image_ref internally, so the image pixels appear at their tracked pose in
% ref. A low opacity is important because many planes overlap in this view.
%
% Each surface receives a unique tag for later programmatic identification.
% Only the first handle is included in the common legend, which avoids one
% repeated legend entry for every ultrasound image.
imageHandles = gobjects(numberOfImages,1);
for planeIndex = 1:numberOfImages
    selectedPlane = data.imagePlanesRef(planeIndex);

    % Convert the physical image width and height into pixel spacing. The
    % max(...,1) safeguard avoids division by zero for a one-pixel dimension.
    pixelSpacingXYMm = [
        selectedPlane.W/max(selectedPlane.nCols-1,1), ...
        selectedPlane.H/max(selectedPlane.nRows-1,1)];

    imageHandle = display_image3D(setupAxes, ...
        selectedPlane.image,selectedPlane.T_image_ref, ...
        'SwapXY', true, ...
        'PixelSpacing',pixelSpacingXYMm, ...
        'Tag', sprintf('demo_pdtree_image_plane_%d',planeIndex), ...
        'Colormap', 'gray', ...
        'FaceAlpha', imageFaceAlpha);

    imageHandle.DisplayName  = sprintf('Ultrasound image %d',planeIndex);
    imageHandles(planeIndex) = imageHandle;
end
imageHandles(1).DisplayName = sprintf('Ultrasound planes (%d)',numberOfImages);

% 7F. Highlight the model surface regions selected by the search ===========
%
% A model correspondence Y_i lies on one triangle of the CT mesh. Highlight
% every selected triangle in cyan to show which surface regions contributed
% matches. Neighboring measurements can select the same triangle, so the
% unique face list prevents identical triangles from being drawn repeatedly.
matchedFacesHandle = patch(setupAxes, ...
    'Faces', boneFaces(uniqueMatchedFaceIndices, :), ...
    'Vertices', bonePointsRef, ...
    'FaceColor', [0.10, 0.80, 0.95], ...
    'EdgeColor', [0.00, 0.30, 0.45], ...
    'FaceAlpha', 0.58, ...
    'LineWidth', 0.8, ...
    'DisplayName', 'Selected model triangles');

% 7G. Draw the measurement side of every correspondence in red =============
%
% Red dots are the retained ultrasound measurements X_i. Red arrows show the
% measured in-plane normals after Block 7B converted each one through its own
% image -> ref rotation. Their common origins make it easy to associate each
% direction with its measurement point.
xPointHandle = scatter3(setupAxes, ...
    X.position3DRef(:, 1), X.position3DRef(:, 2), X.position3DRef(:, 3), ...
    22, [0.90, 0.05, 0.05], 'filled', ...
    'DisplayName', 'Measurements X_i');
xNormalHandle = quiver3(setupAxes, ...
    X.position3DRef(:, 1), X.position3DRef(:, 2), X.position3DRef(:, 3), ...
    measurementNormals3DRef(:, 1) * normalDisplayScale, ...
    measurementNormals3DRef(:, 2) * normalDisplayScale, ...
    measurementNormals3DRef(:, 3) * normalDisplayScale, ...
    0, 'Color', [0.90, 0.05, 0.05], 'LineWidth', 0.8, ...
    'MaxHeadSize', 0.35, 'DisplayName', 'Measured normals');

% 7H. Draw the selected model side of every correspondence in blue =========
%
% Blue dots are the most-likely model points Y_i returned by the PD-tree
% search. Blue arrows are their model surface normals. Row ordering is still
% preserved: the i-th blue point and normal belong to the i-th red X_i.
yPointHandle = scatter3(setupAxes, ...
    YmatchPositionsRef(:, 1), YmatchPositionsRef(:, 2), YmatchPositionsRef(:, 3), ...
    28, [0.05, 0.30, 0.95], 'filled', ...
    'DisplayName', 'Selected model points Y_i');
yNormalHandle = quiver3(setupAxes, ...
    YmatchPositionsRef(:, 1), YmatchPositionsRef(:, 2), YmatchPositionsRef(:, 3), ...
    YmatchNormalsRef(:, 1) * normalDisplayScale, ...
    YmatchNormalsRef(:, 2) * normalDisplayScale, ...
    YmatchNormalsRef(:, 3) * normalDisplayScale, ...
    0, 'Color', [0.05, 0.30, 0.95], 'LineWidth', 0.8, ...
    'MaxHeadSize', 0.35, 'DisplayName', 'Selected model normals');

% 7I. Draw each projected model-normal direction in green ==================
%
% The green arrow at X_i is the selected model normal after projection and
% renormalization in X_i's own ultrasound image plane. Comparing the green
% arrow with the red measured-normal arrow at the same origin reveals the
% angular disagreement that contributes to E_match.
%
% A projection is undefined when a model normal has essentially no component
% inside its image plane. Draw only rows marked as defined by the same match
% calculation used during the PD-tree search.
projectedYNormalHandle = quiver3(setupAxes, ...
    X.position3DRef(projectionIsDefined, 1), ...
    X.position3DRef(projectionIsDefined, 2), ...
    X.position3DRef(projectionIsDefined, 3), ...
    projectedYNormals3DRef(projectionIsDefined, 1) * normalDisplayScale, ...
    projectedYNormals3DRef(projectionIsDefined, 2) * normalDisplayScale, ...
    projectedYNormals3DRef(projectionIsDefined, 3) * normalDisplayScale, ...
    0, 'Color', [0.05, 0.70, 0.20], 'LineWidth', 1.0, ...
    'MaxHeadSize', 0.35, 'DisplayName', 'Projected model normals');

% 7J. Connect each X_i to its corresponding Y_i ============================
%
% The thin grey segments make the one-to-one association explicit. Segment i
% begins at red measurement X_i and ends at its blue model match Y_i. A long
% or unexpected segment can therefore be inspected together with its source
% image and normals instead of judging the two point clouds independently.
correspondenceHandle = plot3(setupAxes, ...
    correspondenceX, correspondenceY, correspondenceZ, ...
    '-', 'Color', [0.25, 0.25, 0.25], 'LineWidth', 0.65, ...
    'DisplayName', 'X_i-to-Y_i correspondences');

% 7K. Finish the legend, result summary, and interactive view ==============
%
% The legend explains the visual encoding without repeating one entry per
% image. The title summarizes how much data is displayed and the mean match
% cost for this candidate pose. Enabling rotation lets the user inspect dense
% or overlapping correspondences from different viewpoints.
legend(setupAxes, [ ...
    boneHandle; imageHandles(1); matchedFacesHandle; ...
    xPointHandle; xNormalHandle; yPointHandle; yNormalHandle; ...
    projectedYNormalHandle; correspondenceHandle], ...
    'Location', 'northwest', ...
    'NumColumns', 2, ...
    'FontSize', 8, ...
    'Interpreter', 'tex');

title(setupAxes,sprintf( ...
    'P-IMLOP: %d / %d images searched, %d measurements, mean E_{match} = %.3f', ...
    numberOfProcessedImages,numberOfImages,numberOfMeasurements,mean(EMatchValues)), ...
    'Interpreter','tex');
rotate3d(demoFigure,'on');
