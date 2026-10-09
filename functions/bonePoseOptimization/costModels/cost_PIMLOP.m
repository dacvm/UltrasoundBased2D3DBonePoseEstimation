function [cost, details] = cost_PIMLOP(poseVector, data, config)
%COST_PIMLOP Evaluate one candidate bone pose with the P-IMLOP cost.
% This cost model connects the batched PD-tree search in functions/PIMLOP/
% to the bone-pose optimization interface. It uses the same three inputs as
% the other cost models in this folder. Its configuration validator is
% validate_cost_PIMLOP.
%
% What P-IMLOP is
% ---------------
% P-IMLOP (Projected Iterative Most-Likely Oriented Point) registers a 3D
% model shape to "projection-oriented points": points that have a 3D
% position but only a 2D orientation, measured inside an image plane. That
% is exactly what tracked 2D ultrasound gives: the bone surface segmented in
% each B-mode image is a curve of 3D points (known through tracking), and
% the surface normal seen in the image is only the PROJECTION of the true
% 3D bone normal onto that image plane (paper Fig. 1).
%
% For every measured point x = (x_3dp, x_2dn) the method looks for the
% most-likely model point y = (y_3dp, y_3dn) on the bone mesh, using a
% probabilistic noise model (paper Eqs. 1-3):
%   - position:    anisotropic 3D Gaussian with covariance Sigma. Ultrasound
%                  is sharper axially/laterally than out of plane, so the
%                  uncertainty is not the same in every direction;
%   - orientation: 2D von Mises with concentration kappa, comparing the
%                  measured 2D normal x_2dn with the model normal y_3dn
%                  after rotating it into the image frame (R_p') and
%                  projecting it onto the image x-y plane (operator P).
%
% Reference paper (citation, notation, and code map in notes.md; the PDF is
% stored locally only):
%   literatures/P-IMLOP/
%   Billings et al., "Minimally invasive registration for computer-assisted
%   orthopedic surgery: combining tracked ultrasound and bone surface points
%   via the P-IMLOP algorithm", Int J CARS 10:761-771 (2015).
%
% How this function relates to the paper's algorithm
% --------------------------------------------------
% The paper's Algorithm 1 alternates two phases until convergence:
%   (a) correspondence phase: for every data point, find the most-likely
%       model point with a PD-tree search (Algorithm 2, Eqs. 5-8);
%   (b) registration phase: update [R,t] by minimizing the total match
%       error, Eq. 4, with BFGS (Eqs. 9-21).
% This function implements ONLY phase (a), for one given candidate pose, and
% returns the summed match error as a scalar cost. Phase (b) is replaced by
% the project's pose optimizer (CMA-ES): it proposes candidate poses, and
% for each one the correspondences are searched again from scratch here.
% So instead of alternating "match, then register", the optimizer
% minimizes the total match error with correspondences re-chosen per pose.
%
% Other differences from the paper (see also notes.md):
%   - The cost sums the non-negative Eq. 7 form, kappa*(1 - cos), not the
%     Eq. 3/4 form -kappa*cos. Per measurement they differ by the constant
%     kappa. Because the set of measurements is fixed for every candidate
%     pose, the total differs by a constant (n*kappa), so both forms have
%     the same best pose.
%   - The matched model point may lie anywhere on a triangle (most-likely
%     point under the Mahalanobis metric), not only at a triangle centre.
%     Its normal is the triangle's face normal.
%   - Measurements can be subsampled (measurementSubsampleFraction) to make
%     each cost evaluation cheaper. This is not part of the paper.
%   - Only ultrasound points are used; the paper's extra pointer-sampled
%     points (kappa = 0) are not part of this cost.
%   - One Sigma (given in image axes) and one kappa are shared by all
%     measurements, like the paper's experiments.
%
% What is precomputed and what is computed here
% ---------------------------------------------
% The model shape Psi of the paper is the CT bone mesh. Everything about it
% that does not depend on the pose is prepared ONCE, before optimization,
% by prepareBonePoseOptimizationInputs and stored in data.extra.pimlop.PsiCT:
%   PsiCT.mesh               - CT-frame bone triangulation (the model Psi);
%   PsiCT.faceNormals        - unit outward normal per triangle (y_3dn);
%   PsiCT.faceAreas, PsiCT.validFaceMask - triangle areas and a mask that
%                              excludes degenerate triangles;
%   PsiCT.triangleVerticesCT - cached triangle vertices for fast search;
%   PsiCT.pdTree             - the PD-tree over the triangles (paper
%                              section "correspondence phase
%                              implementation"): nodes with oriented
%                              bounding boxes used to skip most triangles.
% Building the PD-tree is slow, while this cost function is called thousands
% of times. Because the tree stays in CT, the pose never changes it: for each
% candidate pose we move the ultrasound measurements INTO CT instead of
% moving the mesh, and reuse the same tree. This function therefore assumes
% PsiCT (with its pdTree) already exists and stops if it does not.
%
% Done inside this function for every candidate pose:
%   1. turn the pose vector into the candidate transform and its inverse;
%   2. per image: move measured positions ref -> CT, build the image-to-CT
%      rotation R_p, and run the PD-tree search for the most-likely model
%      point of each measurement (Algorithm 2, Eq. 7);
%   3. sum the winning match errors into one cost (Eq. 4, Eq. 7 form).
%
% Inputs
% ------
% poseVector : Six-value optimizer state [vx; vy; vz; wx; wy; wz].
%     Translation is in millimetres and rotation is a rotation vector in
%     radians. The state is applied around data.T_CT_ref_initial by
%     stateVectorToTMatrix. Zero means "the coarse-registration pose".
%
% data : Prepared optimization data. Fields used here:
%     T_CT_ref_initial        - coarse start pose, CT -> ref;
%     T_bone_CT               - anatomical bone frame -> CT (for details);
%     imagePlanesRef(k)       - tracked image k; its T_image_ref gives the image orientation needed for R_p;
%     boneSurfaceMeasurements(k) - bone surface segmented in image k, aligned with imagePlanesRef(k):
%         surfaceCoordinatesXYZRef - N-by-3 points in ref (x_3dp before moving to CT);
%         surfaceNormalXY          - N-by-2 in-plane normals in image axes (x_2dn);
%         surfaceNormalMask        - N-by-1, true where the normal is valid;
%     extra.pimlop.PsiCT      - the precomputed model described above.
%
% config : Runtime configuration containing these fields under
%     config.cost.parameters:
%         measurementSubsampleFraction   - fraction (0,1] of valid points
%                                          kept per image;
%         positionXStandardDeviationImage,
%         positionYStandardDeviationImage,
%         positionZStandardDeviationImage - one scalar each, in mm: the
%                                          position noise along the
%                                          image x, y and out-of-plane z
%                                          axes; Sigma_image =
%                                          diag([sx sy sz].^2);
%         kappa                          - von Mises concentration of the
%                                          normal (0 turns orientation off).
%     CONFIG may be omitted when the same structure is available as
%     data.config.
%
% Outputs
% -------
% cost : Scalar sum, over every retained measurement of every image, of the
%     minimum Eq. 7 match error found by the PD-tree search. Lower values
%     mean a more likely alignment. This is the Eq. 4 total match error,
%     up to the constant n*kappa described above.
%
% details : Diagnostic structure used by the tutorial demonstration. It
%     contains candidate transforms, per-image inputs and correspondences
%     (resultsByImage), combined X (measurements) and YmatchesCT (matched
%     model points) arrays, the individual match errors EMatchValues,
%     settings, and source indices linking each match back to its image and
%     surface point. CMA-ES normally requests only COST, so detailed search
%     reports are produced only when this second output is requested.

%% 1. READ THE FIXED INPUTS AND COST SETTINGS

% Interactive scripts may omit CONFIG. In that case, use the configuration
% that travelled with the prepared data, matching the other cost functions.
if nargin < 3 || isempty(config)
    config = data.config;
end

% The optimizer accepts either a row or column vector. Convert it to the
% project's column-vector convention before creating the rigid transform.
validateattributes(poseVector, {'numeric'}, {'vector','numel',6,'real','finite'}, mfilename, 'poseVector');
poseVector = poseVector(:);

% PsiCT is the precomputed model Psi (mesh, face normals, PD-tree) in CT.
% It must already exist: building the PD-tree here would repeat a slow,
% pose-independent step in every optimizer evaluation.
if ~isfield(data, 'extra') || ~isfield(data.extra, 'pimlop') || ~isfield(data.extra.pimlop, 'PsiCT')
    error('cost_PIMLOP:MissingPreparedModel', ...
          'Prepare data.extra.pimlop.PsiCT before evaluating the P-IMLOP cost.');
end
PsiCT = data.extra.pimlop.PsiCT;
if ~isfield(PsiCT, 'pdTree') || isempty(PsiCT.pdTree)
    error('cost_PIMLOP:MissingPDTree', ...
          'data.extra.pimlop.PsiCT.pdTree must be built before cost evaluation.');
end

% Each image k has its own plane orientation (R_pi in the paper), so its
% surface points must be searched with that image's rotation. This only
% works if surface measurement k really comes from image plane k; input
% preparation guarantees that ordering, and here we check the counts match.
numberOfImages = numel(data.imagePlanesRef);
if numberOfImages == 0 || numel(data.boneSurfaceMeasurements) ~= numberOfImages
    error('cost_PIMLOP:ImageCountMismatch', ...
        'Image planes and bone-surface measurements must be nonempty and equally sized.');
end

% Turn the readable config values into the paper's noise parameters: the
% image-frame position covariance (Sigma before rotation, from the three
% standard deviations), the orientation concentration kappa, and the
% subsampling fraction.
costSettings = readPIMLOPCostSettings(config);

% Controls of the PD-tree traversal (Algorithm 2). UsePruning applies the
% ellipsoid-OBB test of Eq. 8 to skip nodes that cannot hold a better match;
% the batch sizes only bound memory. They change speed, not the result: the
% search still returns the minimum Eq. 7 error for each measurement.
searchOptions = struct( ...
    'UsePruning', true, ...
    'QueryBatchSize', 64, ...
    'MaxPairsPerBatch', 8192);

%% 2. BUILD THE CANDIDATE CT-TO-REFERENCE TRANSFORM

% The optimizer state is a small correction around the coarse registration.
% It gives the candidate bone pose: a CT point moves into the common ref
% frame (where the tracked images live) as
%
%   p_ref = T_CT_ref_candidate * p_CT.
%
% T_bone_ref_candidate is the same pose in the anatomical bone frame; it is
% not needed for the cost, only reported in DETAILS.
T_CT_ref_candidate   = stateVectorToTMatrix(poseVector, data.T_CT_ref_initial);
T_bone_ref_candidate = T_CT_ref_candidate * data.T_bone_CT;

% The paper moves the data points with T = [R,t] onto the fixed model
% (Algorithm 1: R*x_3dp + t). Here the model (PsiCT and its PD-tree) is
% fixed in CT, so T plays the role of ref -> CT, i.e. the INVERSE of the
% candidate pose. For a rigid transform [R,t], the inverse is [R',-R'*t];
% writing it out keeps the frame direction visible.
R_CT_ref_candidate = T_CT_ref_candidate(1:3,1:3);
t_CT_ref_candidate = T_CT_ref_candidate(1:3,4);
T_ref_CT_candidate = eye(4);
T_ref_CT_candidate(1:3,1:3) = R_CT_ref_candidate.';
T_ref_CT_candidate(1:3,4)   = -R_CT_ref_candidate.' * t_CT_ref_candidate;

%% 3. CORRESPONDENCE PHASE: SEARCH EACH IMAGE WITH ITS OWN ORIENTATION

% This is Algorithm 1, step 3 (the correspondence phase) for the current
% candidate pose. Images are searched one at a time because the PD-tree
% search takes ONE image rotation R_p for a group of queries, and every
% tracked image has a different orientation.
%
% One result entry is kept for every input image. An image without a usable
% normal is marked as skipped rather than removed, so its original index is
% preserved for reporting and visualization.
emptyResult = struct( ...
    'imageIndex', 0, ...
    'status', "pending", ...
    'skipReason', "", ...
    'numberOfValidMeasurementsBeforeSubsampling', 0, ...
    'numberOfMeasurements', 0, ...
    'X', struct(), ...
    'XqueriesCT', struct(), ...
    'T_image_CT', [], ...
    'R_image_CT', [], ...
    'YmatchesCT', struct(), ...
    'EMatchValues', [], ...
    'batchSearchDetails', struct());
resultsByImage = repmat(emptyResult, numberOfImages, 1);

% The optimizer requests only one scalar, while the demonstration requests
% diagnostic details. This flag avoids calculating the optional detailed
% search report during the many ordinary CMA-ES evaluations.
collectDetails = nargout > 1;
cost = 0;

for planeIndex = 1:numberOfImages

    selectedPlane       = data.imagePlanesRef(planeIndex);
    selectedMeasurement = data.boneSurfaceMeasurements(planeIndex);
    resultsByImage(planeIndex).imageIndex = planeIndex;

    % Build this image's projection-oriented data points x = (x_3dp, x_2dn).
    % Only points with a valid normal can be used, because the P-IMLOP match
    % error needs both a position and an in-plane normal. The positions are
    % still in ref; the 2-D normals stay in this image's own x-y axes, which
    % is the frame where the paper compares them (after projection P).
    % Subsampling is the same for every candidate pose, so every candidate
    % is scored on exactly the same measurements.
    [X, numberOfValidMeasurements] = prepareImageMeasurements(selectedMeasurement, costSettings.measurementSubsampleFraction);

    resultsByImage(planeIndex).numberOfValidMeasurementsBeforeSubsampling = numberOfValidMeasurements;

    % An image without any valid normal contributes nothing to the cost.
    % It is recorded as skipped so reports still show every image.
    if isempty(X.position3DRef)
        resultsByImage(planeIndex).status = "skipped";
        resultsByImage(planeIndex).skipReason = ...
            "No measurements with valid normals";
        continue;
    end

    numberOfMeasurements = size(X.position3DRef,1);
    resultsByImage(planeIndex).numberOfMeasurements = numberOfMeasurements;
    resultsByImage(planeIndex).X = X;

    % R_p for this image, expressed in the model (CT) frame. In Algorithm 1
    % the search uses R*R_pi: the image orientation R_pi followed by the
    % current registration rotation R. Here that is image -> ref (from
    % tracking) followed by ref -> CT (from the candidate pose). It is used
    % for two things inside the search:
    %   - rotating the model normal back into image axes, R_p'*y_3dn, before
    %     projecting it with P and comparing it to x_2dn (Eqs. 3 and 7);
    %   - rotating the image-frame covariance into CT,
    %     Sigma = R_p * Sigma_image * R_p' (the paper's R*Sigma_i*R').
    % Both depend on the candidate pose, so they are recomputed every call.
    T_image_CT = T_ref_CT_candidate * selectedPlane.T_image_ref;
    R_image_CT = T_image_CT(1:3,1:3);

    % Move the measured positions into CT: this is R*x_3dp + t of
    % Algorithm 1. The saved surface positions are already in ref, so only
    % ref -> CT is applied; using T_image_CT would apply image -> ref twice.
    % The 2-D normals are NOT moved: they stay in image axes, and the
    % rotation is accounted for through R_image_CT above.
    XqueriesCT = struct();
    XqueriesCT.position3D = applyRigidTransform(X.position3DRef, T_ref_CT_candidate);
    XqueriesCT.normal2DImage = X.normal2DImage;

    % Find the most-likely oriented model point for every measurement (the
    % C_MLP operator, Eq. 2) with the PD-tree search of Algorithm 2: walk the
    % fixed CT tree, skip nodes whose bounding box does not meet the Eq. 8
    % ellipsoid, and in the leaves evaluate the Eq. 7 error on the triangles.
    % It returns, per measurement, the winning model point Y (position,
    % face normal, face index) and its minimum match error E.
    % When DETAILS is wanted, request the selected Y points and search
    % diagnostics needed by the demo. During optimization, request only the
    % vector of winning match errors.
    if collectDetails
        [YmatchesCT, EMatchValues, batchSearchDetails] = ...
            searchPDTree_batchedProcess( ...
            XqueriesCT, PsiCT, R_image_CT, ...
            costSettings.positionCovarianceImage, ...
            costSettings.kappa, searchOptions);
    else
        [~, EMatchValues] = searchPDTree_batchedProcess( ...
            XqueriesCT, PsiCT, R_image_CT, ...
            costSettings.positionCovarianceImage, ...
            costSettings.kappa, searchOptions);
        YmatchesCT = struct();
        batchSearchDetails = struct();
    end

    % Total match error (Eq. 4): measurements are assumed independent, so
    % their errors are summed. Each value is the non-negative Eq. 7 form;
    % see the help text for why this gives the same best pose as Eq. 4.
    % Unlike the paper, this sum is not minimized here: it is returned to
    % the pose optimizer, which plays the role of the registration phase.
    cost = cost + sum(EMatchValues);

    resultsByImage(planeIndex).XqueriesCT = XqueriesCT;
    resultsByImage(planeIndex).T_image_CT = T_image_CT;
    resultsByImage(planeIndex).R_image_CT = R_image_CT;
    resultsByImage(planeIndex).YmatchesCT = YmatchesCT;
    resultsByImage(planeIndex).EMatchValues = EMatchValues;
    resultsByImage(planeIndex).batchSearchDetails = batchSearchDetails;
    resultsByImage(planeIndex).status = "processed";
end

% If no image had a single usable measurement, the cost would be 0 for
% every pose and the optimizer would have nothing to fit, so stop instead.
processedImageMask = [resultsByImage.status] == "processed";
if ~any(processedImageMask)
    error('cost_PIMLOP:NoValidMeasurements', ...
          'No ultrasound image contains a measurement with a valid normal.');
end

%% 4. PACKAGE OPTIONAL DETAILS FOR THE DEMONSTRATION

% CMA-ES uses only COST. Stop here when the caller did not request the second
% output so no combined diagnostic arrays or source-index table are created.
if ~collectDetails
    return;
end

processedPlaneIndices = find(processedImageMask);
Xsets = [resultsByImage(processedImageMask).X];
Ysets = [resultsByImage(processedImageMask).YmatchesCT];

% Build the paper's full data set X = {x_i} and its matches {y_i} as single
% arrays, for plotting and inspection. Concatenate only after each image has
% been searched with its own R_image_CT. Image order and within-image row
% order are preserved, so row i of X, YmatchesCT and EMatchValues always
% describe the same correspondence.
X = struct();
X.position3DRef      = vertcat(Xsets.position3DRef);
X.normal2DImage      = vertcat(Xsets.normal2DImage);
X.sourcePointIndices = vertcat(Xsets.sourcePointIndices);
measurementsPerProcessedImage = [resultsByImage(processedImageMask).numberOfMeasurements].';
X.imageIndex = repelem(processedPlaneIndices(:), measurementsPerProcessedImage);

YmatchesCT = struct();
YmatchesCT.position3D = vertcat(Ysets.position3D);
YmatchesCT.normal3D   = vertcat(Ysets.normal3D);
YmatchesCT.faceIndex  = vertcat(Ysets.faceIndex);

% correspondenceIndex links each row back to its image and to the point's
% row in the original surface measurement (before masking and subsampling).
EMatchValues        = vertcat(resultsByImage(processedImageMask).EMatchValues);
correspondenceIndex = table(X.imageIndex, X.sourcePointIndices, 'VariableNames', {'imageIndex','sourcePointIndex'});

details = struct();
details.T_CT_ref_candidate      = T_CT_ref_candidate;
details.T_ref_CT_candidate      = T_ref_CT_candidate;
details.T_bone_ref_candidate    = T_bone_ref_candidate;
details.processedImageMask      = processedImageMask;
details.processedPlaneIndices   = processedPlaneIndices;
details.resultsByImage          = resultsByImage;
details.X                       = X;
details.YmatchesCT              = YmatchesCT;
details.EMatchValues            = EMatchValues;
details.correspondenceIndex     = correspondenceIndex;
details.numberOfImages          = numberOfImages;
details.numberOfProcessedImages = nnz(processedImageMask);
details.numberOfSkippedImages   = numberOfImages - nnz(processedImageMask);
details.numberOfMeasurements    = numel(EMatchValues);
details.totalMatchError         = cost;
details.meanMatchError          = mean(EMatchValues);
details.maximumMatchError       = max(EMatchValues);
details.costSettings            = costSettings;
details.searchOptions           = searchOptions;
details.status                  = 'pimlop_cost_computed';
end


function costSettings = readPIMLOPCostSettings(config)
%READPIMLOPCOSTSETTINGS Convert readable scalar settings into P-IMLOP inputs.
% The config stores the noise model in readable units (standard deviations
% in mm per image axis). The search needs the paper's parameters instead:
% the position covariance Sigma and the concentration kappa.
%
% Input:
%   config - Runtime configuration containing config.cost.parameters.
% Output:
%   costSettings - Structure containing the sampling fraction, image-frame
%                  covariance matrix, standard deviations, and kappa.

parameters = config.cost.parameters;
requiredNames = { ...
    'measurementSubsampleFraction', ...
    'positionXStandardDeviationImage', ...
    'positionYStandardDeviationImage', ...
    'positionZStandardDeviationImage', ...
    'kappa'};
if ~all(isfield(parameters, requiredNames))
    error('cost_PIMLOP:MissingCostSetting', ...
          'The P-IMLOP runtime configuration is missing a required cost setting.');
end

costSettings = struct();
costSettings.measurementSubsampleFraction = double(parameters.measurementSubsampleFraction);
% The config keeps one scalar per image axis; the covariance below needs
% them together as one [sx; sy; sz] column.
costSettings.positionStandardDeviationImageMm = double([ ...
    parameters.positionXStandardDeviationImage; ...
    parameters.positionYStandardDeviationImage; ...
    parameters.positionZStandardDeviationImage]);
costSettings.kappa = double(parameters.kappa);

validateattributes(costSettings.measurementSubsampleFraction, {'numeric'}, ...
    {'scalar','real','finite','>',0,'<=',1}, mfilename, ...
    'measurementSubsampleFraction');
validateattributes(costSettings.positionStandardDeviationImageMm, {'numeric'}, ...
    {'vector','numel',3,'real','finite','positive'}, mfilename, ...
    'positionStandardDeviationImageMm');
validateattributes(costSettings.kappa, {'numeric'}, ...
    {'scalar','real','finite','nonnegative'}, mfilename, 'kappa');

% Sigma in the image frame: independent noise along image x, y and the
% out-of-plane z axis (the paper uses 1 mm in-plane, 1.5 mm out-of-plane).
% The search rotates it into CT per image with R_image_CT.
costSettings.positionCovarianceImage = diag(costSettings.positionStandardDeviationImageMm .^ 2);
end


function [X, numberOfValidMeasurements] = prepareImageMeasurements(surfaceMeasurement, measurementSubsampleFraction)
%PREPAREIMAGEMEASUREMENTS Select one image's valid oriented measurements.
% Builds the projection-oriented data points x = (x_3dp, x_2dn) of one image
% from its segmented bone surface: keeps only points with a valid in-plane
% normal, normalizes the normals, and evenly subsamples along the curve.
%
% Inputs:
%   surfaceMeasurement - One aligned bone-surface measurement record. Its
%                        positions use ref and its 2-D normals use image axes.
%   measurementSubsampleFraction - Fraction of valid rows retained from the
%                                  complete ordered surface curve.
% Outputs:
%   X - Structure containing position3DRef, normalized normal2DImage, and the
%       original sourcePointIndices for the retained rows.
%   numberOfValidMeasurements - Number of valid rows before subsampling.

% Give a completely empty measurement the standard array shapes used below.
allPositionsRef = double(surfaceMeasurement.surfaceCoordinatesXYZRef);
allNormalsImage = double(surfaceMeasurement.surfaceNormalXY);
normalMask      = logical(surfaceMeasurement.surfaceNormalMask(:));
if isempty(allPositionsRef) && isempty(allNormalsImage) && isempty(normalMask)
    allPositionsRef = zeros(0,3);
    allNormalsImage = zeros(0,2);
end

% Keep only points with a valid normal: the P-IMLOP match error needs both
% x_3dp and x_2dn, so points without a normal cannot be used.
validIndices = find(normalMask);
numberOfValidMeasurements = numel(validIndices);

X = struct( ...
    'position3DRef', zeros(0,3), ...
    'normal2DImage', zeros(0,2), ...
    'sourcePointIndices', zeros(0,1));
if numberOfValidMeasurements == 0
    return;
end

positionsRef = allPositionsRef(validIndices,:);
normalsImage = allNormalsImage(validIndices,:);

% x_2dn must be a unit vector so that its dot product with the projected
% model normal is a true cosine in the von Mises term (Eqs. 3 and 7).
% The upstream estimator already returns unit vectors, but normalizing again
% prevents small numerical drift from influencing dot products.
normalLengths = vecnorm(normalsImage,2,2);
normalsImage = normalsImage ./ normalLengths;

% Subsampling (not part of the paper) makes each cost evaluation cheaper.
% Retain points across the complete ordered curve rather than selecting one
% consecutive block, so the whole visible bone surface still constrains the
% pose. With one retained point use the middle; with two or more include
% both ends and distribute the remaining indices between them. The choice is
% deterministic, so it is identical for every candidate pose.
numberToKeep = max(1, round(measurementSubsampleFraction * numberOfValidMeasurements));
if numberToKeep == 1
    retainedRows = round((numberOfValidMeasurements + 1) / 2);
else
    retainedRows = round(linspace(1, numberOfValidMeasurements, numberToKeep)).';
end

X.position3DRef      = positionsRef(retainedRows,:);
X.normal2DImage      = normalsImage(retainedRows,:);
X.sourcePointIndices = validIndices(retainedRows);
end
