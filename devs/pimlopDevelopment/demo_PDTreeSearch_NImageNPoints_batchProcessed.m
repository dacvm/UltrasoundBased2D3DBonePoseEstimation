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
measurementSubsampleFraction = 1;
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

for planeIndex = 1:numberOfImages
    selectedPlane              = data.imagePlanesRef(planeIndex);
    selectedSurfaceMeasurement = data.boneSurfaceMeasurements(planeIndex);
    resultsByImage(planeIndex).imageIndex = planeIndex;

    % This demo uses the tibia model. Reject another bone association rather
    % than silently searching that image's measurements against the tibia.
    if ~isfield(selectedPlane,'bone') || ~isfield(selectedSurfaceMeasurement,'bone') ...
            || ~strcmpi(string(selectedPlane.bone),"T") ...
            || ~strcmpi(string(selectedSurfaceMeasurement.bone),"T")
        error('demo_PDTreeSearch_NImageNPoints_batchProcessed:BoneMismatch', ...
            'Image %d and its measurements must both be associated with tibia (T).',planeIndex);
    end

    % A valid rigid image pose is needed even if its measurements are empty,
    % because all image planes will still be shown in the final overview.
    T_image_ref = selectedPlane.T_image_ref;
    if ~isequal(size(T_image_ref),[4 4]) || any(~isfinite(T_image_ref),'all') ...
            || norm(T_image_ref(4,:)-[0 0 0 1]) > 1e-10 ...
            || norm(T_image_ref(1:3,1:3).'*T_image_ref(1:3,1:3)-eye(3),'fro') > 1e-6 ...
            || abs(det(T_image_ref(1:3,1:3))-1) > 1e-6
        error('demo_PDTreeSearch_NImageNPoints_batchProcessed:InvalidImagePose','Image %d has an invalid rigid pose.',planeIndex);
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
              'Image %d lacks positions, normals, or a normal-validity mask.',planeIndex);
    end

    allMeasurementPositionsRef = double(selectedSurfaceMeasurement.surfaceCoordinatesXYZRef);
    allMeasurementNormals2DImage = double(selectedSurfaceMeasurement.surfaceNormalXY);
    surfaceNormalMask = logical(selectedSurfaceMeasurement.surfaceNormalMask(:));

    % An extraction with no surface may store plain [] instead of 0-by-3
    % positions and 0-by-2 normals. Give that genuinely empty record its
    % expected shapes so it reaches the documented skip path below. A
    % partially missing record still fails the row-alignment check.
    if isempty(allMeasurementPositionsRef) && isempty(allMeasurementNormals2DImage) ...
            && isempty(surfaceNormalMask)
        allMeasurementPositionsRef = zeros(0,3);
        allMeasurementNormals2DImage = zeros(0,2);
    end

    % Each row of the position, normal, and mask arrays must refer to the same
    % extracted surface sample. A row-count mismatch would destroy the X_i-to-Y_i
    % correspondence that the later registration cost depends upon.
    numberOfStoredMeasurements = size(allMeasurementPositionsRef, 1);
    if size(allMeasurementPositionsRef, 2) ~= 3 || ...
            size(allMeasurementNormals2DImage, 2) ~= 2 || ...
            size(allMeasurementNormals2DImage, 1) ~= numberOfStoredMeasurements || ...
            numel(surfaceNormalMask) ~= numberOfStoredMeasurements
        error('demo_PDTreeSearch_NImageNPoints_batchProcessed:InconsistentMeasurementSizes', ...
              'Image %d has inconsistent position, normal, or mask dimensions.',planeIndex);
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
    measurementPositionsRef = allMeasurementPositionsRef(validMeasurementIndices, :);
    measurementNormals2DImage = allMeasurementNormals2DImage(validMeasurementIndices, :);
    measurementNormalLengths = vecnorm(measurementNormals2DImage, 2, 2);
    if any(~isfinite(measurementPositionsRef), 'all') || ...
            any(~isfinite(measurementNormals2DImage), 'all') || ...
            any(measurementNormalLengths <= 1e-12)
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
        subsampleIndicesWithinValidSet = round( ...
            linspace(1, numberOfValidMeasurementsBeforeSubsampling, numberOfMeasurementsToKeep)).';
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

processedImageMask = [resultsByImage.status] == "ready";
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
% The ultrasound measurements begin in ref while PsiCT and its tree are in
% CT. The search therefore uses the inverse candidate bone pose to transform
% only the query positions into CT. This does not undo the pre-registration:
% T_CT_ref_candidate still describes where the CT bone lies in ref, and this
% demo simply evaluates that candidate pose from the model's fixed frame.

% Use the saved pre-registration as the one candidate pose evaluated here.
T_CT_ref_candidate = data.T_CT_ref_initial;
if ~isequal(size(T_CT_ref_candidate),[4 4]) || any(~isfinite(T_CT_ref_candidate),'all') ...
        || norm(T_CT_ref_candidate(4,:)-[0 0 0 1]) > 1e-10 ...
        || norm(T_CT_ref_candidate(1:3,1:3).'*T_CT_ref_candidate(1:3,1:3)-eye(3),'fro') > 1e-6 ...
        || abs(det(T_CT_ref_candidate(1:3,1:3))-1) > 1e-6
    error('demo_PDTreeSearch_NImageNPoints_batchProcessed:InvalidBonePose','The candidate bone pose must be a finite rigid transform.');
end

% For a rigid transform [R,t], the inverse is [R',-R'*t]. Construct it
% explicitly so the source and target frames remain clear in the code.
R_CT_ref_candidate = T_CT_ref_candidate(1:3, 1:3);
t_CT_ref_candidate = T_CT_ref_candidate(1:3, 4);
T_ref_CT_candidate = eye(4);
T_ref_CT_candidate(1:3, 1:3) = R_CT_ref_candidate.';
T_ref_CT_candidate(1:3, 4)   = -R_CT_ref_candidate.' * t_CT_ref_candidate;

% Only the image-specific part of Section 4 moves into a loop. The inverse
% bone pose above is shared. Every R_image_CT below describes a different
% local image frame relative to the same fixed CT model.
for planeIndex = processedPlaneIndices
    selectedPlane = data.imagePlanesRef(planeIndex);
    X = resultsByImage(planeIndex).X;
    T_image_CT = T_ref_CT_candidate * selectedPlane.T_image_ref;
    R_image_CT = T_image_CT(1:3,1:3);
    measurementPositionsCT = applyRigidTransform(X.position3DRef,T_ref_CT_candidate);
    XqueriesCT = struct();
    XqueriesCT.position3D = measurementPositionsCT;
    XqueriesCT.normal2DImage = X.normal2DImage;

    resultsByImage(planeIndex).T_image_CT = T_image_CT;
    resultsByImage(planeIndex).R_image_CT = R_image_CT;
    resultsByImage(planeIndex).XqueriesCT = XqueriesCT;
end


%% 5. FIND ONE MOST-LIKELY MODEL POINT Y_i FOR EVERY X_i IN EACH IMAGE

% The function calls are exactly those of the single-image batched demo.
% What changes is which XqueriesCT and R_image_CT enter each call. PsiCT,
% kappa, and the LOCAL image covariance are reused across all image groups.
% Do not concatenate all queries into one search with a single R_image_CT:
% that would incorrectly use the same image plane to project every normal.
for planeIndex = processedPlaneIndices
    XqueriesCT = resultsByImage(planeIndex).XqueriesCT;
    R_image_CT = resultsByImage(planeIndex).R_image_CT;
    numberOfMeasurements = resultsByImage(planeIndex).numberOfMeasurements;
    fprintf('Searching image %d / %d: %d retained measurements...\n', ...
        planeIndex,numberOfImages,numberOfMeasurements);
    allSearchTimer = tic;
    [YmatchesCT,EMatchValues,batchSearchDetails] = searchPDTree_batchedProcess( ...
        XqueriesCT,PsiCT,R_image_CT,positionCovarianceImage,kappa,searchOptions);
    totalSearchSeconds = toc(allSearchTimer);

    resultsByImage(planeIndex).YmatchesCT = YmatchesCT;
    resultsByImage(planeIndex).EMatchValues = EMatchValues;
    resultsByImage(planeIndex).batchSearchDetails = batchSearchDetails;
    resultsByImage(planeIndex).totalSearchSeconds = totalSearchSeconds;
    resultsByImage(planeIndex).status = "processed";
end

% Combine rows only AFTER searching with the correct image-specific rotations.
% Vertcat preserves image order, then original retained-row order within each
% image. Keep the familiar X and YmatchesCT names for the combined result.
Xsets = [resultsByImage(processedImageMask).X];
Ysets = [resultsByImage(processedImageMask).YmatchesCT];
X = struct();
X.position3DRef = vertcat(Xsets.position3DRef);
X.normal2DImage = vertcat(Xsets.normal2DImage);
X.sourcePointIndices = vertcat(Xsets.sourcePointIndices);
X.imageIndex = repelem(processedPlaneIndices(:), ...
    [resultsByImage(processedImageMask).numberOfMeasurements].');
YmatchesCT = struct();
YmatchesCT.position3D = vertcat(Ysets.position3D);
YmatchesCT.normal3D = vertcat(Ysets.normal3D);
YmatchesCT.faceIndex = vertcat(Ysets.faceIndex);
EMatchValues = vertcat(resultsByImage(processedImageMask).EMatchValues);
numberOfMeasurements = size(X.position3DRef,1);

% The combined 2D normals retain X.imageIndex because their rows belong to
% different LOCAL frames. The explicit index table is convenient for tracing
% any plotted pair to data.boneSurfaceMeasurements(imageIndex)'s source row.
correspondenceIndex = table(X.imageIndex,X.sourcePointIndices, ...
    'VariableNames',{'imageIndex','sourcePointIndex'});
searchDetailsByImage = [resultsByImage(processedImageMask).batchSearchDetails];
matchDetailsByImage = [searchDetailsByImage.matchDetails];
euclideanDistancesMm = vertcat(matchDetailsByImage.euclideanDistanceMm);
orientationAnglesDeg = vertcat(matchDetailsByImage.orientationAngleDeg);
projectionIsDefined = vertcat(matchDetailsByImage.projectionIsDefined);
facesEvaluatedPerMeasurement = vertcat(searchDetailsByImage.numberOfFacesEvaluated);
nodesPrunedPerMeasurement = vertcat(searchDetailsByImage.numberOfNodesPruned);
YmatchPositionsCT = YmatchesCT.position3D;
YmatchNormalsCT = YmatchesCT.normal3D;
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
numberOfProcessedImages = nnz(processedImageMask);
numberOfSkippedImages = numberOfImages-numberOfProcessedImages;
numberOfValidMeasurementsBeforeSubsampling = sum([resultsByImage.numberOfValidMeasurementsBeforeSubsampling]);
totalSearchSeconds = sum([resultsByImage.totalSearchSeconds]);
averageFacesEvaluated = mean(facesEvaluatedPerMeasurement);
averageFacesEvaluatedPercent = 100*averageFacesEvaluated/PsiCT.pdTree.numberOfDatums;
fprintf('\n  Images processed / skipped       : %d / %d\n',numberOfProcessedImages,numberOfSkippedImages);
fprintf('  Valid / retained measurements    : %d / %d (fraction %.3f)\n', ...
    numberOfValidMeasurementsBeforeSubsampling,numberOfMeasurements,measurementSubsampleFraction);
fprintf('  Valid model triangles            : %d\n',PsiCT.pdTree.numberOfDatums);
fprintf('  PD-tree nodes / leaves           : %d / %d\n',PsiCT.pdTree.numberOfNodes,PsiCT.pdTree.numberOfLeaves);
fprintf('  Unique selected model faces      : %d\n',numel(uniqueMatchedFaceIndices));
fprintf('  X-to-Y distance, mean / max       : %.3f / %.3f mm\n',mean(euclideanDistancesMm),max(euclideanDistancesMm));
fprintf('  Normal angle, mean / max          : %.2f / %.2f deg\n',mean(orientationAnglesDeg),max(orientationAnglesDeg));
fprintf('  E_match, total / mean / max       : %.3f / %.3f / %.3f\n',sum(EMatchValues),mean(EMatchValues),max(EMatchValues));
fprintf('  Average faces tested per point   : %.1f (%.2f%% of model)\n',averageFacesEvaluated,averageFacesEvaluatedPercent);
fprintf('  Average nodes pruned per point   : %.1f\n',mean(nodesPrunedPerMeasurement));
fprintf('  Defined projected model normals  : %d / %d\n',nnz(projectionIsDefined),numberOfMeasurements);
fprintf('  Total / amortized search time    : %.3f s / %.3f ms per point\n\n', ...
    totalSearchSeconds,1000*totalSearchSeconds/numberOfMeasurements);
% Search time sums the batched calls, including their shared preparation.
% It excludes one-time mesh/tree building, input selection, and plotting.


%% 7. DISPLAY ALL X-to-Y CORRESPONDENCES IN ref

% Return model positions and normals to ref exactly as in the one-image demo.
% Translation moves points; only rotation changes a normal's direction.
boneFaces = PsiCT.mesh.ConnectivityList;
bonePointsRef = applyRigidTransform(PsiCT.mesh.Points,T_CT_ref_candidate);
YmatchPositionsRef = applyRigidTransform(YmatchPositionsCT,T_CT_ref_candidate);
YmatchNormalsRef = YmatchNormalsCT*R_CT_ref_candidate.';

% Each measurement normal must be lifted through ITS OWN image rotation.
% Fill the combined row ranges in image order and retain each image's ref
% results for later inspection without needing to repeat the search.
measurementNormals3DRef = zeros(numberOfMeasurements,3);
firstRow = 1;
for planeIndex = processedPlaneIndices
    selectedPlane = data.imagePlanesRef(planeIndex);
    imageX = resultsByImage(planeIndex).X;
    rows = firstRow:firstRow+resultsByImage(planeIndex).numberOfMeasurements-1;
    R_image_ref = selectedPlane.T_image_ref(1:3,1:3);
    measurementNormals3DRef(rows,:) = ...
        [imageX.normal2DImage,zeros(numel(rows),1)]*R_image_ref.';
    resultsByImage(planeIndex).measurementNormals3DRef = measurementNormals3DRef(rows,:);
    resultsByImage(planeIndex).YmatchesRef = struct( ...
        'position3D',YmatchPositionsRef(rows,:),'normal3D',YmatchNormalsRef(rows,:), ...
        'faceIndex',YmatchFaceIndices(rows));
    firstRow = firstRow+numel(rows);
end

% Use one common display length for every unit normal. Changing this scale
% affects only the arrows, never the orientation term in the match cost.
imageExtentMm = max([[data.imagePlanesRef.W],[data.imagePlanesRef.H]]);
normalDisplayScale = 0.04*imageExtentMm;
% Prepare all correspondence segments as one polyline separated by NaNs.
% One plot object is much lighter than creating hundreds of individual lines.
correspondenceX = reshape([ ...
    X.position3DRef(:, 1), YmatchPositionsRef(:, 1), nan(numberOfMeasurements, 1)].', [], 1);
correspondenceY = reshape([ ...
    X.position3DRef(:, 2), YmatchPositionsRef(:, 2), nan(numberOfMeasurements, 1)].', [], 1);
correspondenceZ = reshape([ ...
    X.position3DRef(:, 3), YmatchPositionsRef(:, 3), nan(numberOfMeasurements, 1)].', [], 1);

% One overview contains the whole experiment. Image opacity is intentionally
% low because several tracked planes overlap. Rotation lets the user inspect
% their spatial arrangement and all red-to-blue correspondence pairs.
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

% Draw the complete pre-registered tibia lightly. Its transparency lets the
% tracked image and selected correspondences remain visible through it.
boneHandle = patch(setupAxes, ...
    'Faces', boneFaces, ...
    'Vertices', bonePointsRef, ...
    'FaceColor', [0.84, 0.78, 0.70], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.24, ...
    'DisplayName', 'Pre-registered tibia mesh');

% Draw ALL tracked images, including any skipped by correspondence search.
% Give each surface its own tag. Only the first handle represents ultrasound
% planes in the common legend, avoiding fifteen repeated legend entries.
imageHandles = gobjects(numberOfImages,1);
for planeIndex = 1:numberOfImages
    selectedPlane = data.imagePlanesRef(planeIndex);
    pixelSpacingXYMm = [selectedPlane.W/max(selectedPlane.nCols-1,1), ...
        selectedPlane.H/max(selectedPlane.nRows-1,1)];
    imageHandle = display_image3D(setupAxes, ...
        selectedPlane.image,selectedPlane.T_image_ref, ...
        'SwapXY',true,'PixelSpacing',pixelSpacingXYMm, ...
        'Tag',sprintf('demo_pdtree_image_plane_%d',planeIndex), ...
        'Colormap','gray','FaceAlpha',imageFaceAlpha);
    imageHandle.DisplayName = sprintf('Ultrasound image %d',planeIndex);
    imageHandles(planeIndex) = imageHandle;
end
imageHandles(1).DisplayName = sprintf('Ultrasound planes (%d)',numberOfImages);

% Highlight every unique mesh face selected by at least one measurement.
% Several neighboring X points may choose the same triangle, so plotting the
% unique face list avoids drawing identical triangles repeatedly.
matchedFacesHandle = patch(setupAxes, ...
    'Faces', boneFaces(uniqueMatchedFaceIndices, :), ...
    'Vertices', bonePointsRef, ...
    'FaceColor', [0.10, 0.80, 0.95], ...
    'EdgeColor', [0.00, 0.30, 0.45], ...
    'FaceAlpha', 0.58, ...
    'LineWidth', 0.8, ...
    'DisplayName', 'Selected model triangles');

% Plot all measured points and their image-plane normals in red. These are
% the combined retained X sets from every processed ultrasound image.
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

% Plot every selected model point and face normal in blue. The i-th blue
% point is the most-likely oriented correspondence Y_i of the i-th red point.
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

% Join every paired X_i and Y_i with a thin grey segment. Together these
% lines make the complete set of indexed correspondence pairs easy to recognize.
correspondenceHandle = plot3(setupAxes, ...
    correspondenceX, correspondenceY, correspondenceZ, ...
    '-', 'Color', [0.25, 0.25, 0.25], 'LineWidth', 0.65, ...
    'DisplayName', 'X_i-to-Y_i correspondences');

title(setupAxes, 'Complete tracked setup in ref', 'Interpreter', 'tex');
legend(setupAxes, [ ...
    boneHandle; imageHandles(1); matchedFacesHandle; ...
    xPointHandle; xNormalHandle; yPointHandle; yNormalHandle; ...
    correspondenceHandle], ...
    'Location', 'northwest', ...
    'NumColumns', 2, ...
    'FontSize', 8, ...
    'Interpreter', 'tex');

% The title reports retained points, so the effect of subsampling is visible.
title(setupAxes,sprintf( ...
    'P-IMLOP: %d / %d images searched, %d measurements, mean E_{match} = %.3f', ...
    numberOfProcessedImages,numberOfImages,numberOfMeasurements,mean(EMatchValues)), ...
    'Interpreter','tex');
rotate3d(demoFigure,'on');
