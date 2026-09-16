clear; clc; close all;

%% P-IMLOP PD-TREE SEARCH: ONE IMAGE WITH ALL MEASUREMENT POINTS
%
% This script extends the one-point demonstration to the complete set of
% oriented bone-surface measurements extracted from one ultrasound image:
%
%   1. load one tracked ultrasound image and all of its valid surface points;
%   2. prepare the complete tibia mesh and its reusable CT-frame PD-tree;
%   3. transform every measured point from ref into the fixed CT search frame;
%   4. search the same PD-tree once for every measurement X_i;
%   5. collect one most-likely oriented model point Y_i for every X_i;
%   6. transform the selected model points back to ref and display them.
%
% Scope of this example
% ---------------------
% The setup contains one ultrasound image in ref, every measurement point in
% that image having a valid estimated normal, and the complete pre-registered
% tibia mesh that intersects the image plane. The script computes many
% correspondences, but it still does not optimize or update the bone pose.
% It evaluates only the saved initial pre-registration.
%
% The result is an indexed pair of sets:
%
%       X(1) <-> YmatchesCT(1)
%       X(2) <-> YmatchesCT(2)
%                    ...
%       X(N) <-> YmatchesCT(N)
%
% This pairing is what a future P-IMLOP-based bone-pose cost function will
% use: each optimizer candidate creates a new CT-frame query set, the PD-tree
% supplies the current Y correspondences, and their E_match values are then
% combined into one scalar registration cost.


%% 1. LOAD THE PREPARED ULTRASOUND AND BONE DATA

% Resolve every path from this file, so the demo works even when MATLAB was
% started from a different folder.
demoFolder    = fileparts(mfilename('fullpath'));
projectRoot   = fileparts(fileparts(demoFolder));
setupFilePath = fullfile(demoFolder, 'optimization_setup.mat');

% The shared project functions provide rigid transformations and display
% helpers. The demo folder contains the P-IMLOP model and search functions.
addpath(genpath(fullfile(projectRoot, 'functions')));
addpath(demoFolder);

% The saved setup contains the CT tibia mesh, tracked image planes, extracted
% ultrasound measurements, and the initial CT-to-ref registration.
load(setupFilePath, 'data');


%% 2. SELECT ONE IMAGE AND COLLECT ALL OF ITS ORIENTED MEASUREMENTS X

% Use the same image as the one-point and development demonstrations. This
% image intersects the pre-registered tibia and contains a complete extracted
% bone-surface curve. A different plane can be tested by changing this index.
planeIndex                 = 11;
selectedPlane              = data.imagePlanesRef(planeIndex);
selectedSurfaceMeasurement = data.boneSurfaceMeasurements(planeIndex);

% A valid P-IMLOP measurement requires a 3D position, a 2D image-plane
% normal, and a true entry in surfaceNormalMask. Check these inputs before
% forming the set so an older or incomplete setup fails with a useful message.
requiredMeasurementFields = { ...
    'surfaceCoordinatesXYZRef', ...
    'surfaceNormalXY', ...
    'surfaceNormalMask'};
if ~all(isfield(selectedSurfaceMeasurement, requiredMeasurementFields))
    error('demo_PDTreeSearch_1ImageNPoints:MissingMeasurementFields', ...
          'The selected surface measurement does not contain positions, normals, and a normal-validity mask.');
end

allMeasurementPositionsRef = double(selectedSurfaceMeasurement.surfaceCoordinatesXYZRef);
allMeasurementNormals2DImage = double(selectedSurfaceMeasurement.surfaceNormalXY);
surfaceNormalMask = logical(selectedSurfaceMeasurement.surfaceNormalMask(:));

% Each row of the position, normal, and mask arrays must refer to the same
% extracted surface sample. A row-count mismatch would destroy the X_i-to-Y_i
% correspondence that the later registration cost depends upon.
numberOfStoredMeasurements = size(allMeasurementPositionsRef, 1);
if size(allMeasurementPositionsRef, 2) ~= 3 || ...
        size(allMeasurementNormals2DImage, 2) ~= 2 || ...
        size(allMeasurementNormals2DImage, 1) ~= numberOfStoredMeasurements || ...
        numel(surfaceNormalMask) ~= numberOfStoredMeasurements
    error('demo_PDTreeSearch_1ImageNPoints:InconsistentMeasurementSizes', ...
          'Measurement positions, normals, and validity mask must have matching rows.');
end

validMeasurementIndices = find(surfaceNormalMask);
if isempty(validMeasurementIndices)
    error('demo_PDTreeSearch_1ImageNPoints:NoValidMeasurements', ...
          'The selected image does not contain a measurement with a valid normal.');
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
    error('demo_PDTreeSearch_1ImageNPoints:InvalidMeasurement', ...
          'A measurement marked valid contains a nonfinite value or a zero normal.');
end

% Normalize every measured direction row by row. The estimator already
% returns unit normals, but repeating this inexpensive step prevents harmless
% floating-point drift from entering the orientation comparison.
measurementNormals2DImage = ...
    measurementNormals2DImage ./ measurementNormalLengths;

% X represents the complete measured oriented-point set for this image. Row
% i of position3DRef and normal2DImage belongs to the same measurement X_i.
% sourcePointIndices preserves the corresponding row in the original surface
% extraction, which is useful when a result needs to be traced back later.
X = struct();
X.position3DRef      = measurementPositionsRef;
X.normal2DImage      = measurementNormals2DImage;
X.sourcePointIndices = validMeasurementIndices;
numberOfMeasurements = size(X.position3DRef, 1);


%% 3. PREPARE THE CT MODEL Psi AND BUILD ONE REUSABLE PD-TREE

% preparePIMLOPModel keeps the CT triangulation and computes the area,
% validity, and unit face normal of every triangle. PsiCT is the complete
% oriented model set searched for every measurement in X.
PsiCT = preparePIMLOPModel(data.boneMeshCT);

% buildPIMLOPPDTree groups all valid triangles into principal-direction
% bounding boxes. This is deliberately outside the measurement loop: model
% preparation is a one-time operation and the same tree serves every X_i.
PsiCT.pdTree = buildPIMLOPPDTree(PsiCT.mesh, PsiCT.validFaceMask);


%% 4. EXPRESS ALL QUERIES IN THE FIXED CT SEARCH FRAME
%
% The ultrasound measurements begin in ref while PsiCT and its tree are in
% CT. The search therefore uses the inverse candidate bone pose to transform
% only the query positions into CT. This does not undo the pre-registration:
% T_CT_ref_candidate still describes where the CT bone lies in ref, and this
% demo simply evaluates that candidate pose from the model's fixed frame.

% Use the saved pre-registration as the one candidate pose evaluated here.
T_CT_ref_candidate = data.T_CT_ref_initial;

% For a rigid transform [R,t], the inverse is [R',-R'*t]. Construct it
% explicitly so the source and target frames remain clear in the code.
R_CT_ref_candidate = T_CT_ref_candidate(1:3, 1:3);
t_CT_ref_candidate = T_CT_ref_candidate(1:3, 4);
T_ref_CT_candidate = eye(4);
T_ref_CT_candidate(1:3, 1:3) = R_CT_ref_candidate.';
T_ref_CT_candidate(1:3, 4)   = -R_CT_ref_candidate.' * t_CT_ref_candidate;

% R_image_CT tells P-IMLOP how the local ultrasound image axes are oriented
% relative to the CT model. It is shared by all measurements in this image.
T_image_CT = T_ref_CT_candidate * selectedPlane.T_image_ref;
R_image_CT = T_image_CT(1:3, 1:3);

% Transform all query positions in one operation. Their 2D normals remain in
% the local image X-Y frame and therefore do not change numerically.
measurementPositionsCT = applyRigidTransform( ...
    X.position3DRef, T_ref_CT_candidate);


%% 5. FIND ONE MOST-LIKELY MODEL POINT Y_i FOR EVERY X_i

% These settings define the same P-IMLOP measurement model for every point
% from this image. The covariance remains in local image X-Y-Z coordinates;
% R_image_CT rotates it into the shared CT search frame when needed.
positionStandardDeviationImageMm = [1.0; 1.0; 1.5];
positionCovarianceImage = diag(positionStandardDeviationImageMm .^ 2);
kappa = 50;

% Use the Algorithm 2 pruning mode demonstrated by the one-point script. It
% must return the same best candidate as exhaustive traversal while avoiding
% triangles whose PD-tree boxes cannot improve the current E_match value.
searchOptions = struct('UsePruning', true);

% Preallocate one Y structure and concise diagnostic values for every X_i.
% Maintaining the same array index is essential: YmatchesCT(i) is the model
% correspondence selected specifically for measurement X_i.
emptyModelPoint = struct( ...
    'position3D', zeros(3, 1), ...
    'normal3D', zeros(3, 1), ...
    'faceIndex', 0);
YmatchesCT = repmat(emptyModelPoint, numberOfMeasurements, 1);
EMatchValues = zeros(numberOfMeasurements, 1);
euclideanDistancesMm = zeros(numberOfMeasurements, 1);
orientationAnglesDeg = zeros(numberOfMeasurements, 1);
projectedYNormals2DImage = zeros(numberOfMeasurements, 2);
facesEvaluatedPerMeasurement = zeros(numberOfMeasurements, 1);
nodesPrunedPerMeasurement = zeros(numberOfMeasurements, 1);
searchSecondsPerMeasurement = zeros(numberOfMeasurements, 1);
projectionIsDefined = false(numberOfMeasurements, 1);

% searchPDTree currently accepts one projection-oriented query at a time.
% The loop is therefore the clearest interface for this demonstration. A
% future cost function can use the same pattern for every optimizer candidate.
fprintf('\nSearching the PD-tree for %d measurements from image plane %d...\n', ...
    numberOfMeasurements, planeIndex);
allSearchTimer = tic;
progressInterval = max(1, ceil(numberOfMeasurements / 10));
for measurementNumber = 1:numberOfMeasurements
    XqueryCT = struct();
    XqueryCT.position3D = measurementPositionsCT(measurementNumber, :).';
    XqueryCT.normal2DImage = X.normal2DImage(measurementNumber, :).';

    [YmatchesCT(measurementNumber), EMatchValues(measurementNumber), currentSearchDetails] = ...
        searchPDTree( ...
        XqueryCT, PsiCT, R_image_CT, ...
        positionCovarianceImage, kappa, searchOptions);

    % The search already retains the E_match details for its winning model
    % point. Save only the quantities useful for a compact demonstration
    % report rather than printing a development trace for every point.
    euclideanDistancesMm(measurementNumber) = ...
        currentSearchDetails.matchDetails.euclideanDistanceMm;
    orientationAnglesDeg(measurementNumber) = ...
        currentSearchDetails.matchDetails.orientationAngleDeg;
    projectionIsDefined(measurementNumber) = ...
        currentSearchDetails.matchDetails.projectionIsDefined;
    projectedYNormals2DImage(measurementNumber, :) = ...
        currentSearchDetails.matchDetails.projectedYNormal2DImage.';
    facesEvaluatedPerMeasurement(measurementNumber) = ...
        currentSearchDetails.numberOfFacesEvaluated;
    nodesPrunedPerMeasurement(measurementNumber) = ...
        currentSearchDetails.numberOfNodesPruned;
    searchSecondsPerMeasurement(measurementNumber) = ...
        currentSearchDetails.elapsedSeconds;

    % A complete image can take several minutes with the present scalar
    % search interface. Print only ten progress milestones so the user knows
    % that MATLAB is working without producing a development-level trace.
    if mod(measurementNumber, progressInterval) == 0 || ...
            measurementNumber == numberOfMeasurements
        fprintf('  Completed %d / %d measurements (%.0f%%).\n', ...
            measurementNumber, numberOfMeasurements, ...
            100 * measurementNumber / numberOfMeasurements);
    end
end
totalSearchSeconds = toc(allSearchTimer);

% Convert the structure-array result into row-based matrices for summaries,
% rigid transformations, and vectorized plotting. The structure array remains
% available because it mirrors the individual oriented-point output of
% searchPDTree, while these matrices make operations on the whole set simple.
YmatchPositionsCT = reshape([YmatchesCT.position3D], 3, []).';
YmatchNormalsCT   = reshape([YmatchesCT.normal3D], 3, []).';
YmatchFaceIndices = [YmatchesCT.faceIndex].';
uniqueMatchedFaceIndices = unique(YmatchFaceIndices, 'stable');


%% 6. PRINT A SHORT, USER-ORIENTED RESULT SUMMARY

% Report quantities that describe correspondence quality and search effort.
% Per-point development details remain available in the arrays above, but a
% short statistical summary is more useful when hundreds of points are used.
averageFacesEvaluated = mean(facesEvaluatedPerMeasurement);
averageFacesEvaluatedPercent = ...
    100 * averageFacesEvaluated / PsiCT.pdTree.numberOfDatums;

fprintf('\nP-IMLOP one-image, many-point PD-tree demo\n');
fprintf('  Ultrasound image plane             : %d\n', planeIndex);
fprintf('  Measurements with valid normals    : %d\n', numberOfMeasurements);
fprintf('  Valid model triangles              : %d\n', PsiCT.pdTree.numberOfDatums);
fprintf('  PD-tree nodes / leaves             : %d / %d\n', ...
    PsiCT.pdTree.numberOfNodes, PsiCT.pdTree.numberOfLeaves);
fprintf('  Unique selected model faces        : %d\n', numel(uniqueMatchedFaceIndices));
fprintf('  X-to-Y distance, mean / max        : %.3f / %.3f mm\n', ...
    mean(euclideanDistancesMm), max(euclideanDistancesMm));
fprintf('  Normal angle, mean / max           : %.2f / %.2f deg\n', ...
    mean(orientationAnglesDeg), max(orientationAnglesDeg));
fprintf('  E_match, mean / max                : %.3f / %.3f\n', ...
    mean(EMatchValues), max(EMatchValues));
fprintf('  Average faces tested per point     : %.1f (%.2f%% of model)\n', ...
    averageFacesEvaluated, averageFacesEvaluatedPercent);
fprintf('  Average nodes pruned per point     : %.1f\n', ...
    mean(nodesPrunedPerMeasurement));
fprintf('  Defined projected model normals    : %d / %d\n', ...
    nnz(projectionIsDefined), numberOfMeasurements);
fprintf('  Total / average search time        : %.3f s / %.3f ms per point\n\n', ...
    totalSearchSeconds, 1000 * mean(searchSecondsPerMeasurement));


%% 7. DISPLAY ALL X-to-Y CORRESPONDENCES IN ref

% This figure is intended to explain the complete one-image correspondence
% result in one common physical coordinate frame. It contains:
%
%   1. The pre-registered tibia mesh, drawn transparently in beige.
%   2. The selected tracked ultrasound image at its pose in ref.
%   3. Mesh triangles containing at least one selected Y_i, drawn in cyan.
%   4. Ultrasound measurements X_i and their normals, drawn in red.
%   5. Most-likely model correspondences Y_i and their normals, in blue.
%   6. Each model normal projected into the ultrasound plane, in green.
%   7. A grey line joining every indexed pair X_i -> Y_i.
%
% The left panel will show the complete anatomical setup. The right panel
% will show exactly the same scene, but zoomed around the correspondence
% region so individual points, normals, and connecting lines are easier to
% inspect.
%
% Before drawing these elements together, every displayed 3-D position and
% direction must be expressed in ref. Measurement positions X_i already live
% in ref. The CT mesh and selected Y_i must be moved from CT to ref, while the
% measured and projected 2-D normals must be lifted through the selected
% image's pose.

% 7A. Transform the CT-side geometry into the display frame ===============
%
% The PD-tree search was deliberately performed in the fixed CT frame. The
% mesh and returned model correspondences therefore still use CT coordinates.
% T_CT_ref_candidate is the candidate bone pose evaluated by the search:
%
%   p_ref = T_CT_ref_candidate * p_CT
%
% Positions require the complete rigid transform because both rotation and
% translation determine their location. Normals are directions, not points,
% so translation must not be applied. With the row-vector representation used
% here, the corresponding normal conversion is:
%
%   n_ref = n_CT * R_CT_ref_candidate'
%
% Only display copies are transformed. PsiCT and its PD-tree remain fixed in
% CT and are neither modified nor rebuilt.
boneFaces       = PsiCT.mesh.ConnectivityList;
bonePointsRef   = applyRigidTransform(PsiCT.mesh.Points, T_CT_ref_candidate);
YmatchPositionsRef = applyRigidTransform(YmatchPositionsCT, T_CT_ref_candidate);
YmatchNormalsRef   = YmatchNormalsCT * R_CT_ref_candidate.';

% 7B. Lift the measured and projected normals into 3-D ref coordinates =====
%
% Each measured normal is stored as [n_x, n_y] in the local ultrasound-image
% plane. Append a zero third component to embed it in that local 3-D frame:
%
%   n_image = [n_x, n_y, 0]
%
% The zero states that the direction lies inside the ultrasound plane. Then
% rotate the direction from image -> ref using R_image_ref. Translation is
% intentionally excluded because it cannot change a direction. Since this
% demo uses only one ultrasound image, the same R_image_ref correctly applies
% to every measurement normal.
R_image_ref = selectedPlane.T_image_ref(1:3, 1:3);
measurementNormals3DRef = ...
    [X.normal2DImage, zeros(numberOfMeasurements, 1)] * R_image_ref.';

% projectedYNormals2DImage contains the normalized projection of each chosen
% model normal onto the local ultrasound image X-Y plane. These are the exact
% projected directions used in the orientation part of E_match. As above,
% append a zero image-Z component and rotate image -> ref for display:
%
%   projected n_ref = [projected n_x, projected n_y, 0] * R_image_ref'
%
% The resulting green directions lie in the tracked ultrasound plane. They
% will be drawn from X_i, because that is where each projected model normal is
% compared against the corresponding red measured normal.
projectedYNormals3DRef = ...
    [projectedYNormals2DImage, zeros(numberOfMeasurements, 1)] * ...
    R_image_ref.';

% 7C. Prepare display-only sizes and correspondence line geometry ==========
%
% Unit normals would appear very short relative to the image and bone. Give
% every arrow one common visible length based on the ultrasound-image extent.
% This scale changes only the rendered arrows; it does not modify any stored
% normal or the orientation term used by P-IMLOP.
imageExtentMm      = max([selectedPlane.W, selectedPlane.H]);
normalDisplayScale = 0.04 * imageExtentMm;

% display_image3D needs the physical spacing between neighboring pixels. The
% max(...,1) safeguard avoids division by zero for a one-pixel dimension.
pixelSpacingXYMm   = [ ...
    selectedPlane.W / max(selectedPlane.nCols - 1, 1), ...
    selectedPlane.H / max(selectedPlane.nRows - 1, 1)];

% Each match should appear as an independent line from X_i to Y_i. NaN rows
% separate successive segments inside one long polyline. This gives the same
% visual result as hundreds of individual plot3 calls while using only one
% graphics object, making the figure faster to draw and rotate.
correspondenceX = reshape([ ...
    X.position3DRef(:, 1), YmatchPositionsRef(:, 1), nan(numberOfMeasurements, 1)].', [], 1);
correspondenceY = reshape([ ...
    X.position3DRef(:, 2), YmatchPositionsRef(:, 2), nan(numberOfMeasurements, 1)].', [], 1);
correspondenceZ = reshape([ ...
    X.position3DRef(:, 3), YmatchPositionsRef(:, 3), nan(numberOfMeasurements, 1)].', [], 1);

% 7D. Create two coordinated views of the same correspondence result =======
%
% The first axes is the overview. Equal axis scaling is important because it
% prevents the bone, image plane, and correspondence distances from being
% visually stretched along one coordinate direction.
demoFigure = figure( ...
    'Name', 'P-IMLOP one-image, many-point PD-tree search demo', ...
    'Position', [80, 80, 1550, 700]);
demoLayout = tiledlayout(demoFigure, 1, 2, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

setupAxes = nexttile(demoLayout, 1);
hold(setupAxes, 'on');
grid(setupAxes, 'on');
axis(setupAxes, 'equal');
view(setupAxes, 35, 30);
xlabel(setupAxes, 'X_{ref} (mm)');
ylabel(setupAxes, 'Y_{ref} (mm)');
zlabel(setupAxes, 'Z_{ref} (mm)');

% 7E. Draw the anatomical context: bone mesh and ultrasound image ===========
%
% Draw the complete candidate tibia pose lightly in beige. Transparency keeps
% the anatomy recognizable while allowing image pixels and correspondences on
% the far side of the surface to remain visible.
boneHandle = patch(setupAxes, ...
    'Faces', boneFaces, ...
    'Vertices', bonePointsRef, ...
    'FaceColor', [0.84, 0.78, 0.70], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.24, ...
    'DisplayName', 'Pre-registered tibia mesh');

% Draw the selected ultrasound image at its tracked pose in ref.
% display_image3D uses T_image_ref to place the local image pixels correctly
% in the same frame as the bone and correspondence points.
imageHandle = display_image3D(setupAxes, ...
    selectedPlane.image, selectedPlane.T_image_ref, ...
    'SwapXY', true, ...
    'PixelSpacing', pixelSpacingXYMm, ...
    'Tag', 'demo_pdtree_npoints_image_plane', ...
    'Colormap', 'gray', ...
    'FaceAlpha', 0.45);
imageHandle.DisplayName = sprintf('Ultrasound plane %d', planeIndex);

% 7F. Highlight the model surface regions selected by the search ===========
%
% Every Y_i lies on one triangle of the CT mesh. Draw the selected triangles
% in cyan to reveal which parts of the bone surface supplied correspondences.
% Neighboring measurements may select the same triangle, so the unique face
% list prevents the same triangle from being drawn repeatedly.
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
% measured in-plane normals after Block 7B rotated them from image into ref.
% Each arrow starts at its own measurement point.
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
% search. Blue arrows are their surface normals. Row ordering is preserved,
% so the i-th blue point and normal belong to the i-th red measurement X_i.
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

% 7I. Draw the projected model-normal directions in green ==================
%
% The green arrow at X_i is the selected model normal after projection and
% renormalization in the ultrasound image plane. It therefore lies exactly in
% that plane. Comparing the green arrow with the red arrow at the same origin
% reveals the angular disagreement that contributes to E_match.
%
% A projection is undefined when a model normal has essentially no component
% inside the image plane. Draw only rows marked as defined by the same match
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

% 7J. Connect every X_i to its corresponding Y_i ===========================
%
% Each thin grey segment starts at a red measurement X_i and ends at its blue
% model match Y_i. A long or unexpected segment can therefore be judged in
% relation to the image plane, selected triangle, and the two normal arrows.
correspondenceHandle = plot3(setupAxes, ...
    correspondenceX, correspondenceY, correspondenceZ, ...
    '-', 'Color', [0.25, 0.25, 0.25], 'LineWidth', 0.65, ...
    'DisplayName', 'X_i-to-Y_i correspondences');

% 7K. Label the overview and explain its visual encoding ===================
title(setupAxes, 'Complete tracked setup in ref', 'Interpreter', 'tex');
legend(setupAxes, [ ...
    boneHandle; imageHandle; matchedFacesHandle; ...
    xPointHandle; xNormalHandle; yPointHandle; yNormalHandle; ...
    projectedYNormalHandle; correspondenceHandle], ...
    'Location', 'northwest', ...
    'NumColumns', 2, ...
    'FontSize', 8, ...
    'Interpreter', 'tex');

% 7L. Create a close-up without recomputing or redrawing the result =========
%
% Copy the completed overview scene into the second axes, then restrict its
% limits around the X_i and Y_i point sets. Because the graphics objects are
% copied, both panels show exactly the same search result; no second PD-tree
% search is performed and no correspondence can accidentally differ.
closeupAxes = nexttile(demoLayout, 2);
copyobj(allchild(setupAxes), closeupAxes);
hold(closeupAxes, 'on');
grid(closeupAxes, 'on');
axis(closeupAxes, 'equal');
view(closeupAxes, 35, 30);
xlabel(closeupAxes, 'X_{ref} (mm)');
ylabel(closeupAxes, 'Y_{ref} (mm)');
zlabel(closeupAxes, 'Z_{ref} (mm)');

closeupPointsRef = [X.position3DRef; YmatchPositionsRef];
closeupMinimumRef = min(closeupPointsRef, [], 1);
closeupMaximumRef = max(closeupPointsRef, [], 1);
closeupPaddingMm  = max(3, 1.5 * normalDisplayScale);
xlim(closeupAxes, [closeupMinimumRef(1), closeupMaximumRef(1)] + [-1, 1] * closeupPaddingMm);
ylim(closeupAxes, [closeupMinimumRef(2), closeupMaximumRef(2)] + [-1, 1] * closeupPaddingMm);
zlim(closeupAxes, [closeupMinimumRef(3), closeupMaximumRef(3)] + [-1, 1] * closeupPaddingMm);
title(closeupAxes, 'Close-up of all selected X_i-to-Y_i matches', 'Interpreter', 'tex');

% 7M. Add the overall result summary and enable interactive inspection =====
%
% The shared title reports the number of displayed measurements, how many
% distinct model faces they selected, and the mean match cost for this pose.
sgtitle(demoFigure, sprintf( ...
    'P-IMLOP: %d measurements, %d selected model faces, mean E_{match} = %.3f', ...
    numberOfMeasurements, numel(uniqueMatchedFaceIndices), mean(EMatchValues)), ...
    'Interpreter', 'tex', ...
    'FontWeight', 'bold');

% Rotation is enabled for inspecting overlapping points, surface triangles,
% normals, and correspondence lines from different viewpoints.
rotate3d(demoFigure, 'on');
