function [cost, details] = cost_PIMLOP_v01(poseVector, data, config)
%COST_PIMLOP_V01 Evaluate one candidate bone pose with the P-IMLOP cost.
% This development version connects the existing batched PD-tree search to
% the bone-pose optimization interface. It is intentionally written with the
% same three inputs used by the production cost models so it can be promoted
% later without changing its scientific workflow.
%
% Why this function is needed
% ---------------------------
% The PD-tree describes the fixed CT model and is expensive to construct.
% The caller therefore prepares it once and stores it in
% data.extra.pimlop.PsiCT. This function only performs work that changes for
% a candidate pose: it moves the ultrasound queries into CT, finds their
% most-likely oriented model points, and sums their match errors.
%
% Inputs
% ------
% poseVector : Six-value optimizer state [vx; vy; vz; wx; wy; wz].
%     Translation is in millimetres and rotation is a rotation vector in
%     radians. The state is applied around data.T_CT_ref_initial by
%     stateVectorToTMatrix.
% data : Prepared optimization data containing the initial transforms,
%     tracked ultrasound image planes, aligned bone-surface measurements,
%     and the fixed CT-frame model at data.extra.pimlop.PsiCT.
% config : Runtime configuration containing these scalar fields under
%     config.cost.parameters:
%         measurementSubsampleFraction
%         positionStandardDeviationImageXmm
%         positionStandardDeviationImageYmm
%         positionStandardDeviationImageZmm
%         kappa
%     CONFIG may be omitted when the same structure is available as
%     data.config.
%
% Outputs
% -------
% cost : Scalar sum of the minimum P-IMLOP E_match value for every retained
%     measurement. Lower values indicate a more likely alignment.
% details : Diagnostic structure used by the tutorial demonstration. It
%     contains candidate transforms, per-image inputs and correspondences,
%     combined X and Y arrays, individual match errors, settings, and source
%     indices. CMA-ES normally requests only COST, so detailed search reports
%     are produced only when this second output is requested.

%% 1. READ THE FIXED INPUTS AND COST SETTINGS

% Interactive scripts may omit CONFIG. In that case, use the configuration
% that travelled with the prepared data, matching the other cost functions.
if nargin < 3 || isempty(config)
    config = data.config;
end

% The optimizer accepts either a row or column vector. Convert it to the
% project's column-vector convention before creating the rigid transform.
validateattributes(poseVector, {'numeric'}, ...
    {'vector','numel',6,'real','finite'}, mfilename, 'poseVector');
poseVector = poseVector(:);

% PsiCT must already contain the CT model and its PD-tree. Keeping this
% requirement explicit prevents an expensive tree build from accidentally
% happening during every optimizer evaluation.
if ~isfield(data, 'extra') || ~isfield(data.extra, 'pimlop') ...
        || ~isfield(data.extra.pimlop, 'PsiCT')
    error('cost_PIMLOP_v01:MissingPreparedModel', ...
        'Prepare data.extra.pimlop.PsiCT before evaluating the P-IMLOP cost.');
end
PsiCT = data.extra.pimlop.PsiCT;
if ~isfield(PsiCT, 'pdTree') || isempty(PsiCT.pdTree)
    error('cost_PIMLOP_v01:MissingPDTree', ...
        'data.extra.pimlop.PsiCT.pdTree must be built before cost evaluation.');
end

% Every image plane must stay paired with the surface measurement extracted
% from that image. The input-preparation stage establishes this ordering.
numberOfImages = numel(data.imagePlanesRef);
if numberOfImages == 0 || numel(data.boneSurfaceMeasurements) ~= numberOfImages
    error('cost_PIMLOP_v01:ImageCountMismatch', ...
        'Image planes and bone-surface measurements must be nonempty and equally sized.');
end

% Convert the five readable scalar configuration values into the covariance,
% concentration, and sampling settings used by the mathematical functions.
costSettings = readPIMLOPCostSettings(config);

% Keep the traversal controls fixed during this first implementation. These
% are the same defaults used by searchPDTree_batchedProcess and affect speed,
% not the scientific definition of the P-IMLOP match cost.
searchOptions = struct( ...
    'UsePruning', true, ...
    'QueryBatchSize', 64, ...
    'MaxPairsPerBatch', 8192);

%% 2. BUILD THE CANDIDATE CT-TO-REFERENCE TRANSFORM

% The optimizer state describes a correction around the coarse registration.
% The resulting transform moves a CT point into the common ref frame:
%
%   p_ref = T_CT_ref_candidate * p_CT.
T_CT_ref_candidate = stateVectorToTMatrix( ...
    poseVector, data.T_CT_ref_initial);
T_bone_ref_candidate = T_CT_ref_candidate * data.T_bone_CT;

% The PD-tree remains fixed in CT, so the ultrasound measurements must move
% in the opposite direction. For a rigid transform [R,t], the inverse is
% [R',-R'*t]. Constructing it explicitly keeps the frame direction visible.
R_CT_ref_candidate = T_CT_ref_candidate(1:3,1:3);
t_CT_ref_candidate = T_CT_ref_candidate(1:3,4);
T_ref_CT_candidate = eye(4);
T_ref_CT_candidate(1:3,1:3) = R_CT_ref_candidate.';
T_ref_CT_candidate(1:3,4)   = -R_CT_ref_candidate.' * t_CT_ref_candidate;

%% 3. SEARCH EACH IMAGE WITH ITS OWN IMAGE-TO-CT ORIENTATION

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

    % Read, normalize, and deterministically subsample this image's oriented
    % measurements. X positions stay in ref for now, while the 2-D normals
    % stay in the local coordinate system of this ultrasound image.
    [X, numberOfValidMeasurements] = prepareImageMeasurements( ...
        selectedMeasurement, costSettings.measurementSubsampleFraction);

    resultsByImage(planeIndex).numberOfValidMeasurementsBeforeSubsampling = ...
        numberOfValidMeasurements;

    if isempty(X.position3DRef)
        resultsByImage(planeIndex).status = "skipped";
        resultsByImage(planeIndex).skipReason = ...
            "No measurements with valid normals";
        continue;
    end

    numberOfMeasurements = size(X.position3DRef,1);
    resultsByImage(planeIndex).numberOfMeasurements = numberOfMeasurements;
    resultsByImage(planeIndex).X = X;

    % Compose image -> ref with the candidate-dependent ref -> CT transform.
    % Each image has a different pose, so each image receives its own
    % R_image_CT for projecting CT model normals into that image plane.
    T_image_CT = T_ref_CT_candidate * selectedPlane.T_image_ref;
    R_image_CT = T_image_CT(1:3,1:3);

    % The saved surface positions already use ref coordinates. Therefore,
    % apply only ref -> CT here; applying T_image_CT would repeat the earlier
    % image -> ref conversion that created the saved measurements.
    XqueriesCT = struct();
    XqueriesCT.position3D = applyRigidTransform( ...
        X.position3DRef, T_ref_CT_candidate);
    XqueriesCT.normal2DImage = X.normal2DImage;

    % Search the same fixed CT tree for every image. When DETAILS is wanted,
    % request the selected Y points and search diagnostics needed by the demo.
    % During optimization, request only the vector of winning match errors.
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

    % Equation (4) combines the independent correspondence terms by summing
    % them. The number of retained measurements is fixed across candidates,
    % so every candidate is evaluated on exactly the same evidence.
    cost = cost + sum(EMatchValues);

    resultsByImage(planeIndex).XqueriesCT = XqueriesCT;
    resultsByImage(planeIndex).T_image_CT = T_image_CT;
    resultsByImage(planeIndex).R_image_CT = R_image_CT;
    resultsByImage(planeIndex).YmatchesCT = YmatchesCT;
    resultsByImage(planeIndex).EMatchValues = EMatchValues;
    resultsByImage(planeIndex).batchSearchDetails = batchSearchDetails;
    resultsByImage(planeIndex).status = "processed";
end

processedImageMask = [resultsByImage.status] == "processed";
if ~any(processedImageMask)
    error('cost_PIMLOP_v01:NoValidMeasurements', ...
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

% Concatenate images only after each one has been searched with its own
% R_image_CT. Image order and within-image row order are preserved.
X = struct();
X.position3DRef      = vertcat(Xsets.position3DRef);
X.normal2DImage      = vertcat(Xsets.normal2DImage);
X.sourcePointIndices = vertcat(Xsets.sourcePointIndices);
measurementsPerProcessedImage = ...
    [resultsByImage(processedImageMask).numberOfMeasurements].';
X.imageIndex = repelem(processedPlaneIndices(:), ...
    measurementsPerProcessedImage);

YmatchesCT = struct();
YmatchesCT.position3D = vertcat(Ysets.position3D);
YmatchesCT.normal3D   = vertcat(Ysets.normal3D);
YmatchesCT.faceIndex  = vertcat(Ysets.faceIndex);

EMatchValues = vertcat(resultsByImage(processedImageMask).EMatchValues);
correspondenceIndex = table( ...
    X.imageIndex, X.sourcePointIndices, ...
    'VariableNames', {'imageIndex','sourcePointIndex'});

details = struct();
details.T_CT_ref_candidate = T_CT_ref_candidate;
details.T_ref_CT_candidate = T_ref_CT_candidate;
details.T_bone_ref_candidate = T_bone_ref_candidate;
details.processedImageMask = processedImageMask;
details.processedPlaneIndices = processedPlaneIndices;
details.resultsByImage = resultsByImage;
details.X = X;
details.YmatchesCT = YmatchesCT;
details.EMatchValues = EMatchValues;
details.correspondenceIndex = correspondenceIndex;
details.numberOfImages = numberOfImages;
details.numberOfProcessedImages = nnz(processedImageMask);
details.numberOfSkippedImages = numberOfImages - nnz(processedImageMask);
details.numberOfMeasurements = numel(EMatchValues);
details.totalMatchError = cost;
details.meanMatchError = mean(EMatchValues);
details.maximumMatchError = max(EMatchValues);
details.costSettings = costSettings;
details.searchOptions = searchOptions;
details.status = 'pimlop_cost_computed';
end


function costSettings = readPIMLOPCostSettings(config)
%READPIMLOPCOSTSETTINGS Convert readable scalar settings into P-IMLOP inputs.
% Input:
%   config - Runtime configuration containing config.cost.parameters.
% Output:
%   costSettings - Structure containing the sampling fraction, image-frame
%                  covariance matrix, standard deviations, and kappa.

parameters = config.cost.parameters;
requiredNames = { ...
    'measurementSubsampleFraction', ...
    'positionStandardDeviationImageXmm', ...
    'positionStandardDeviationImageYmm', ...
    'positionStandardDeviationImageZmm', ...
    'kappa'};
if ~all(isfield(parameters, requiredNames))
    error('cost_PIMLOP_v01:MissingCostSetting', ...
        'The P-IMLOP runtime configuration is missing a required cost setting.');
end

costSettings = struct();
costSettings.measurementSubsampleFraction = ...
    double(parameters.measurementSubsampleFraction);
costSettings.positionStandardDeviationImageMm = double([ ...
    parameters.positionStandardDeviationImageXmm; ...
    parameters.positionStandardDeviationImageYmm; ...
    parameters.positionStandardDeviationImageZmm]);
costSettings.kappa = double(parameters.kappa);

validateattributes(costSettings.measurementSubsampleFraction, {'numeric'}, ...
    {'scalar','real','finite','>',0,'<=',1}, mfilename, ...
    'measurementSubsampleFraction');
validateattributes(costSettings.positionStandardDeviationImageMm, {'numeric'}, ...
    {'vector','numel',3,'real','finite','positive'}, mfilename, ...
    'positionStandardDeviationImageMm');
validateattributes(costSettings.kappa, {'numeric'}, ...
    {'scalar','real','finite','nonnegative'}, mfilename, 'kappa');

costSettings.positionCovarianceImage = diag( ...
    costSettings.positionStandardDeviationImageMm .^ 2);
end


function [X, numberOfValidMeasurements] = prepareImageMeasurements( ...
    surfaceMeasurement, measurementSubsampleFraction)
%PREPAREIMAGEMEASUREMENTS Select one image's valid oriented measurements.
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

% Normalize each measured direction before it enters the orientation cost.
% The upstream estimator already returns unit vectors, but normalizing again
% prevents small numerical drift from influencing dot products.
normalLengths = vecnorm(normalsImage,2,2);
normalsImage = normalsImage ./ normalLengths;

% Retain points across the complete ordered curve rather than selecting one
% consecutive block. With one retained point use the middle; with two or more
% include both ends and distribute the remaining indices between them.
numberToKeep = max(1, round( ...
    measurementSubsampleFraction * numberOfValidMeasurements));
if numberToKeep == 1
    retainedRows = round((numberOfValidMeasurements + 1) / 2);
else
    retainedRows = round(linspace( ...
        1, numberOfValidMeasurements, numberToKeep)).';
end

X.position3DRef      = positionsRef(retainedRows,:);
X.normal2DImage      = normalsImage(retainedRows,:);
X.sourcePointIndices = validIndices(retainedRows);
end
