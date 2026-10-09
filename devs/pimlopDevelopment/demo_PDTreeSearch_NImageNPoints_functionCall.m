clear; clc; close all;

%% P-IMLOP COST FUNCTION DEMO: MANY IMAGES AND MANY MEASUREMENTS
%
% This demonstration is the next step after
% demo_PDTreeSearch_NImageNPoints_batchProcessed.m. The earlier script shows
% every calculation directly. This script shows how the same workflow looks
% when an optimizer-facing cost function owns the candidate-dependent work.
%
% The responsibilities are deliberately separated:
%
%   This script prepares once:
%       1. the fixed CT-oriented model PsiCT;
%       2. the fixed CT-space PD-tree;
%       3. one runtime configuration and one candidate pose.
%
%   cost_PIMLOP performs for that candidate:
%       1. inverse-transforming ultrasound measurements into CT;
%       2. searching each image with its own image-to-CT orientation;
%       3. finding one most-likely model point for every retained measurement;
%       4. summing the individual E_match values into one scalar cost.
%
% This separation simulates the later optimization workflow. Input
% preparation will build data.extra.pimlop.PsiCT once, and CMA-ES will call
% the cost function many times with different poseVector values.

%% 1. LOAD THE SAME PREPARED DATA USED BY THE DIRECT DEMONSTRATION

% Resolve every path from this script so the demonstration also works when
% MATLAB was started from another folder.
demoFolder    = fileparts(mfilename('fullpath'));
projectRoot   = fileparts(fileparts(demoFolder));
setupFilePath = fullfile(demoFolder, 'optimization_setup.mat');
addpath(genpath(fullfile(projectRoot, 'functions')));

% The saved DATA structure contains the CT mesh, coarse registration,
% ultrasound image planes, and extracted bone-surface measurements. It does
% not yet contain a P-IMLOP model because Step 3 of the integration plan has
% intentionally not been implemented in this development stage.
load(setupFilePath, 'data');

%% 2. DEFINE THE P-IMLOP SETTINGS USED FOR THIS DEMONSTRATION

% Use exactly the same scientific values and batch-search defaults as the
% existing all-image direct demonstration. Keeping these values equal makes
% the two workflows directly comparable.
measurementSubsampleFraction = 0.5;
positionStandardDeviationImageMm = [1.0; 1.0; 1.5];
kappa = 50;

% cost_PIMLOP already uses the standard optimizer interface, so place the
% settings under config.cost.parameters just as a future JSON run config will.
config                 = struct();
config.cost            = struct();
config.cost.model      = 'PIMLOP';
config.cost.parameters = struct();
config.cost.parameters.measurementSubsampleFraction   = measurementSubsampleFraction;
config.cost.parameters.positionXStandardDeviationImage = positionStandardDeviationImageMm(1);
config.cost.parameters.positionYStandardDeviationImage = positionStandardDeviationImageMm(2);
config.cost.parameters.positionZStandardDeviationImage = positionStandardDeviationImageMm(3);
config.cost.parameters.kappa = kappa;

% This value changes only the appearance of the ultrasound planes. It never
% enters the P-IMLOP correspondence search or the numerical cost.
imageFaceAlpha = 0.15;

%% 3. PREPARE THE FIXED CT MODEL AND BUILD ITS PD-TREE ONCE

% PsiCT is the complete oriented model. It keeps the CT triangulation and
% adds one area, one unit normal, and one validity flag for every mesh face.
PsiCT = preparePIMLOPModel_batchedProcess(data.boneMeshCT);

% Build the spatial hierarchy before calling the cost function. This is the
% important architectural point of the demonstration: the tree belongs to
% prepared data, not to one candidate-pose evaluation.
PsiCT.pdTree = buildPIMLOPPDTree_batchedProcess(PsiCT.mesh, PsiCT.validFaceMask);

% Store the model in the same nested location planned for the production
% optimization input. The extra layer leaves room for future cost-specific
% prepared structures without mixing them with common optimization fields.
if ~isfield(data, 'extra')
    data.extra = struct();
end
data.extra.pimlop       = struct();
data.extra.pimlop.PsiCT = PsiCT;

%% 4. EVALUATE ONE CANDIDATE POSE THROUGH THE COST FUNCTION

% A zero state means no correction around the saved coarse registration.
% During CMA-ES this vector will be replaced by each generated candidate.
poseVector = zeros(6,1);

% Request DETAILS because this is an explanatory demonstration. An optimizer
% normally requests only the first output and therefore avoids the optional
% diagnostic arrays used by the report and figure below.
evaluationTimer   = tic;
[pimlopCost, costDetails] = cost_PIMLOP(poseVector, data, config);
evaluationSeconds = toc(evaluationTimer);

%% 5. READ THE FUNCTION OUTPUTS USING FRAME-EXPLICIT NAMES

% The function returns all model-side correspondences in CT, because that is
% the coordinate frame of the fixed PD-tree. Measurement positions remain in
% ref, and their image-local 2-D normals keep an image index beside them.
%
% Copy the fields we need out of the DETAILS structure into short local
% variables, so the code below is easier to read:
%   - resultsByImage: one entry per ultrasound image with its own results.
%   - processedImageMask / processedPlaneIndices: which images were used
%     (true/index) and which were skipped (for example, no measurements).
%   - X: the measured bone-surface points from all used images, stacked.
%   - YmatchesCT: for every measured point, the closest matching point on
%     the CT bone model (in CT coordinates).
%   - EMatchValues: the match error of every point; their sum is the cost.
%   - T_CT_ref_candidate: the tested bone pose (moves CT points into ref).
resultsByImage           = costDetails.resultsByImage;
processedImageMask       = costDetails.processedImageMask;
processedPlaneIndices    = costDetails.processedPlaneIndices;
X                        = costDetails.X;
YmatchesCT               = costDetails.YmatchesCT;
EMatchValues             = costDetails.EMatchValues;
T_CT_ref_candidate       = costDetails.T_CT_ref_candidate;

% Keep only the rotation part of the pose. Normals are directions, not
% positions, so they must be rotated but never shifted.
R_CT_ref_candidate       = T_CT_ref_candidate(1:3,1:3);

% Simple counts used later in the printed report.
numberOfImages           = costDetails.numberOfImages;
numberOfProcessedImages  = costDetails.numberOfProcessedImages;
numberOfSkippedImages    = costDetails.numberOfSkippedImages;
numberOfMeasurements     = costDetails.numberOfMeasurements;

% Split the matched model points into separate arrays: their positions,
% their surface normals, and the index of the mesh triangle they lie on.
% The list of unique triangles shows how much of the bone was actually used.
YmatchPositionsCT        = YmatchesCT.position3D;
YmatchNormalsCT          = YmatchesCT.normal3D;
YmatchFaceIndices        = YmatchesCT.faceIndex;
uniqueMatchedFaceIndices = unique(YmatchFaceIndices, 'stable');

% Join the per-image diagnostics in the same order used by the combined X,
% Y, and E_match arrays. These values explain the cost but do not recompute it.
%   - euclideanDistancesMm: straight-line distance between each measured
%     point and its matched model point.
%   - orientationAnglesDeg: angle between the measured normal and the
%     matched model normal (small angle = surfaces face the same way).
%   - facesEvaluatedPerMeasurement / nodesPrunedPerMeasurement: how much work
%     the PD-tree search did; fewer faces tested means a faster search.
searchDetailsByImage        = [resultsByImage(processedImageMask).batchSearchDetails];
matchDetailsByImage          = [searchDetailsByImage.matchDetails];
euclideanDistancesMm         = vertcat(matchDetailsByImage.euclideanDistanceMm);
orientationAnglesDeg         = vertcat(matchDetailsByImage.orientationAngleDeg);
projectionIsDefined          = vertcat(matchDetailsByImage.projectionIsDefined);
facesEvaluatedPerMeasurement = vertcat(searchDetailsByImage.numberOfFacesEvaluated);
nodesPrunedPerMeasurement    = vertcat(searchDetailsByImage.numberOfNodesPruned);

%% 6. PRINT A SHORT RESULT REPORT

% First print one table row per ultrasound image. This shows whether some
% images fit the bone model much worse than others, which a single total
% cost would hide.
fprintf('\nP-IMLOP cost-function demonstration\n');
fprintf(' Image   Valid   Used   Mean distance(mm)   Mean angle(deg)   Mean E_match\n');
for planeIndex = 1:numberOfImages
    result = resultsByImage(planeIndex);

    % A skipped image has no matches, so print the reason instead of numbers.
    if result.status == "skipped"
        fprintf(' %5d       0      0   SKIPPED: %s\n', planeIndex, result.skipReason);
        continue;
    end

    % For a used image, print how many measurements it had, how many were
    % kept after subsampling, and the average match quality of those points.
    imageMatchDetails = result.batchSearchDetails.matchDetails;
    fprintf(' %5d   %5d  %5d       %8.3f          %8.2f         %8.3f\n', ...
        planeIndex, ...
        result.numberOfValidMeasurementsBeforeSubsampling, ...
        result.numberOfMeasurements, ...
        mean(imageMatchDetails.euclideanDistanceMm), ...
        mean(imageMatchDetails.orientationAngleDeg), ...
        mean(result.EMatchValues));
end

% Compute the summary numbers for all images together. The percentage of
% faces tested tells how well the PD-tree avoids checking every triangle:
% 100% would mean no speed-up compared with a brute-force search.
numberOfValidMeasurementsBeforeSubsampling = sum([resultsByImage.numberOfValidMeasurementsBeforeSubsampling]);
averageFacesEvaluated                      = mean(facesEvaluatedPerMeasurement);
averageFacesEvaluatedPercent               = 100 * averageFacesEvaluated / PsiCT.pdTree.numberOfDatums;

% Print the overall summary: data used, model and tree size, match quality,
% the final cost, and how long one cost evaluation took.
fprintf('\n  Images processed / skipped       : %d / %d\n', ...
    numberOfProcessedImages, ...
    numberOfSkippedImages);
fprintf('  Valid / retained measurements    : %d / %d (fraction %.3f)\n', ...
    numberOfValidMeasurementsBeforeSubsampling, ...
    numberOfMeasurements, ...
    measurementSubsampleFraction);
fprintf('  Valid model triangles            : %d\n', ...
    PsiCT.pdTree.numberOfDatums);
fprintf('  PD-tree nodes / leaves           : %d / %d\n', ...
    PsiCT.pdTree.numberOfNodes, ...
    PsiCT.pdTree.numberOfLeaves);
fprintf('  Unique selected model faces      : %d\n', ...
    numel(uniqueMatchedFaceIndices));
fprintf('  X-to-Y distance, mean / max      : %.3f / %.3f mm\n', ...
    mean(euclideanDistancesMm), ...
    max(euclideanDistancesMm));
fprintf('  Normal angle, mean / max         : %.2f / %.2f deg\n', ...
    mean(orientationAnglesDeg), ...
    max(orientationAnglesDeg));
fprintf('  E_match, total / mean / max      : %.3f / %.3f / %.3f\n', ...
    pimlopCost, mean(EMatchValues), ...
    max(EMatchValues));
fprintf('  Average faces tested per point   : %.1f (%.2f%% of model)\n', ...
    averageFacesEvaluated, ...
    averageFacesEvaluatedPercent);
fprintf('  Average nodes pruned per point   : %.1f\n', ...
    mean(nodesPrunedPerMeasurement));
fprintf('  Candidate evaluation time        : %.3f s\n\n', ...
    evaluationSeconds);

%% 7. CONVERT SEARCH RESULTS FROM CT INTO REF FOR DISPLAY

% The search remains in CT, but the ultrasound images and measurements are
% displayed in ref. Transform model positions with the full rigid transform
% and model normals with rotation only.
%   - boneFaces: the triangle list does not change when the mesh moves, so
%     it is reused as-is.
%   - bonePointsRef: the whole bone mesh placed at the tested pose.
%   - YmatchPositionsRef / YmatchNormalsRef: the matched model points and
%     their normals, now in the same frame as the ultrasound images.
boneFaces         = PsiCT.mesh.ConnectivityList;
bonePointsRef      = applyRigidTransform(PsiCT.mesh.Points, T_CT_ref_candidate);
YmatchPositionsRef = applyRigidTransform(YmatchPositionsCT, T_CT_ref_candidate);
YmatchNormalsRef   = YmatchNormalsCT * R_CT_ref_candidate.';

% Each 2-D measured normal and projected model normal belongs to one image.
% Embed it as [nx,ny,0] in that image and rotate it into ref using the pose of
% that particular ultrasound image.
%
% Create empty output arrays for all measurements at once. The loop below
% fills them image by image, in the same stacked order as X.
measurementNormals3DRef = zeros(numberOfMeasurements,3);
projectedYNormals3DRef  = zeros(numberOfMeasurements,3);
firstCombinedRow        = 1;

for planeIndex = processedPlaneIndices
    % Get this image's results and its rotation into ref. Only the rotation
    % is needed because we are turning directions, not moving points.
    selectedPlane = data.imagePlanesRef(planeIndex);
    imageResult   = resultsByImage(planeIndex);
    R_image_ref   = selectedPlane.T_image_ref(1:3,1:3);

    % Work out which rows of the combined arrays belong to this image.
    numberOfImageMeasurements = imageResult.numberOfMeasurements;
    combinedRows = firstCombinedRow:(firstCombinedRow + numberOfImageMeasurements - 1);

    % Measured normals: add a zero third component (the normal lies in the
    % image plane), then rotate from the image frame into ref.
    measurementNormals3DImage              = [imageResult.X.normal2DImage, zeros(numberOfImageMeasurements,1)];
    measurementNormals3DRef(combinedRows,:) = measurementNormals3DImage * R_image_ref.';

    % Projected model normals: the matched model normal flattened onto the
    % image plane. Convert it to 3-D and into ref in the same way, so it can
    % be drawn next to the measured normal for a visual comparison.
    imageProjectedYNormals2D =imageResult.batchSearchDetails.matchDetails.projectedYNormal2DImage;
    projectedYNormals3DImage = [imageProjectedYNormals2D, zeros(numberOfImageMeasurements,1)];
    projectedYNormals3DRef(combinedRows,:) = projectedYNormals3DImage * R_image_ref.';

    % Move the start row forward so the next image fills the next rows.
    firstCombinedRow = firstCombinedRow + numberOfImageMeasurements;
end

%% 8. PREPARE DISPLAY-ONLY ARROWS AND CORRESPONDENCE LINES

% Unit normals are short relative to the bone and image dimensions. Apply one
% common display length to every arrow without changing the stored normals or
% any value used by the P-IMLOP calculation.
imageExtentMm = max([[data.imagePlanesRef.W], [data.imagePlanesRef.H]]);
normalDisplayScale = 0.04 * imageExtentMm;

% Insert NaN between point pairs so one plot3 object draws independent line
% segments from every measurement X_i to its matched model point Y_i.
correspondenceX = reshape([ ...
    X.position3DRef(:,1), YmatchPositionsRef(:,1), ...
    nan(numberOfMeasurements,1)].', [], 1);
correspondenceY = reshape([ ...
    X.position3DRef(:,2), YmatchPositionsRef(:,2), ...
    nan(numberOfMeasurements,1)].', [], 1);
correspondenceZ = reshape([ ...
    X.position3DRef(:,3), YmatchPositionsRef(:,3), ...
    nan(numberOfMeasurements,1)].', [], 1);

%% 9. DISPLAY ALL IMAGES AND CORRESPONDENCES IN REF

demoFigure = figure( ...
    'Name','P-IMLOP all-image cost-function demonstration', ...
    'Position',[80,80,1250,850]);
setupAxes = axes(demoFigure);
hold(setupAxes, 'on');
grid(setupAxes, 'on');
axis(setupAxes, 'equal');
view(setupAxes, 35, 30);
xlabel(setupAxes, 'X_{ref} (mm)');
ylabel(setupAxes, 'Y_{ref} (mm)');
zlabel(setupAxes, 'Z_{ref} (mm)');

% Draw the complete candidate bone lightly so correspondences on the far side
% remain visible through the surface.
boneHandle = patch(setupAxes, ...
    'Faces', boneFaces, ...
    'Vertices', bonePointsRef, ...
    'FaceColor', [0.84,0.78,0.70], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.24, ...
    'DisplayName', 'Candidate tibia mesh');

% Draw every ultrasound image, including images that had no valid measured
% normal. Their tracked poses still provide useful acquisition context.
imageHandles = gobjects(numberOfImages,1);
for planeIndex = 1:numberOfImages
    selectedPlane = data.imagePlanesRef(planeIndex);

    pixelSpacingXYMm = [ ...
        selectedPlane.W / max(selectedPlane.nCols-1,1), ...
        selectedPlane.H / max(selectedPlane.nRows-1,1)];

    imageHandle = display_image3D(setupAxes, ...
        selectedPlane.image, selectedPlane.T_image_ref, ...
        'SwapXY', true, ...
        'PixelSpacing', pixelSpacingXYMm, ...
        'Tag', sprintf('demo_pimlop_cost_image_%d',planeIndex), ...
        'Colormap', 'gray', ...
        'FaceAlpha', imageFaceAlpha);
    
    imageHandle.DisplayName = sprintf('Ultrasound image %d',planeIndex);
    imageHandles(planeIndex) = imageHandle;
end
imageHandles(1).DisplayName = sprintf('Ultrasound planes (%d)', numberOfImages);

% Cyan triangles show the mesh regions selected by at least one retained
% ultrasound measurement.
matchedFacesHandle = patch(setupAxes, ...
    'Faces', boneFaces(uniqueMatchedFaceIndices,:), ...
    'Vertices', bonePointsRef, ...
    'FaceColor', [0.10,0.80,0.95], ...
    'EdgeColor', [0.00,0.30,0.45], ...
    'FaceAlpha', 0.58, ...
    'LineWidth', 0.8, ...
    'DisplayName', 'Selected model triangles');

% Red dots and arrows represent measured oriented points from ultrasound.
xPointHandle = scatter3(setupAxes, ...
    X.position3DRef(:,1), X.position3DRef(:,2), X.position3DRef(:,3), ...
    22, [0.90,0.05,0.05], 'filled', ...
    'DisplayName', 'Measurements X_i');
xNormalHandle = quiver3(setupAxes, ...
    X.position3DRef(:,1), X.position3DRef(:,2), X.position3DRef(:,3), ...
    measurementNormals3DRef(:,1) * normalDisplayScale, ...
    measurementNormals3DRef(:,2) * normalDisplayScale, ...
    measurementNormals3DRef(:,3) * normalDisplayScale, ...
    0, 'Color', [0.90,0.05,0.05], 'LineWidth', 0.8, ...
    'MaxHeadSize', 0.35, 'DisplayName', 'Measured normals');

% Blue dots and arrows represent the selected CT model points and face normals.
yPointHandle = scatter3(setupAxes, ...
    YmatchPositionsRef(:,1), YmatchPositionsRef(:,2), ...
    YmatchPositionsRef(:,3), 28, [0.05,0.30,0.95], 'filled', ...
    'DisplayName', 'Selected model points Y_i');
yNormalHandle = quiver3(setupAxes, ...
    YmatchPositionsRef(:,1), YmatchPositionsRef(:,2), ...
    YmatchPositionsRef(:,3), ...
    YmatchNormalsRef(:,1) * normalDisplayScale, ...
    YmatchNormalsRef(:,2) * normalDisplayScale, ...
    YmatchNormalsRef(:,3) * normalDisplayScale, ...
    0, 'Color', [0.05,0.30,0.95], 'LineWidth', 0.8, ...
    'MaxHeadSize', 0.35, 'DisplayName', 'Selected model normals');

% Green arrows show the selected model normals after projection into their
% respective ultrasound planes. Their disagreement with the red arrows is
% the orientation component of E_match.
projectedYNormalHandle = quiver3(setupAxes, ...
    X.position3DRef(projectionIsDefined,1), ...
    X.position3DRef(projectionIsDefined,2), ...
    X.position3DRef(projectionIsDefined,3), ...
    projectedYNormals3DRef(projectionIsDefined,1) * normalDisplayScale, ...
    projectedYNormals3DRef(projectionIsDefined,2) * normalDisplayScale, ...
    projectedYNormals3DRef(projectionIsDefined,3) * normalDisplayScale, ...
    0, 'Color', [0.05,0.70,0.20], 'LineWidth', 1.0, ...
    'MaxHeadSize', 0.35, 'DisplayName', 'Projected model normals');

% Grey segments make the row-by-row X_i to Y_i correspondence explicit.
correspondenceHandle = plot3(setupAxes, ...
    correspondenceX, correspondenceY, correspondenceZ, ...
    '-', 'Color', [0.25,0.25,0.25], 'LineWidth', 0.65, ...
    'DisplayName', 'X_i-to-Y_i correspondences');

legend(setupAxes, [ ...
    boneHandle; imageHandles(1); matchedFacesHandle; ...
    xPointHandle; xNormalHandle; yPointHandle; yNormalHandle; ...
    projectedYNormalHandle; correspondenceHandle], ...
    'Location', 'northwest', ...
    'NumColumns', 2, ...
    'FontSize', 8, ...
    'Interpreter', 'tex');

title(setupAxes, sprintf( ...
    'P-IMLOP function call: %d images, %d measurements, total cost = %.3f', ...
    numberOfProcessedImages, numberOfMeasurements, pimlopCost), ...
    'Interpreter','tex');
rotate3d(demoFigure, 'on');
