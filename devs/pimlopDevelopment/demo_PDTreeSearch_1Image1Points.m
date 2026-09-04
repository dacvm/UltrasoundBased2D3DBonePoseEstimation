clear; clc; close all;

%% P-IMLOP PD-TREE SEARCH: MINIMAL ONE-POINT DEMO
%
% This script demonstrates the complete correspondence workflow for one
% projection-oriented ultrasound measurement:
%
%   1. load one tracked ultrasound image and its extracted bone surface;
%   2. select one measured surface point X and its 2D image-plane normal;
%   3. prepare the complete tibia mesh as the P-IMLOP model Psi;
%   4. build one reusable PD-tree around that model in CT coordinates;
%   5. transform X from ref into CT and search the tree for its best model
%      correspondence Y according to the P-IMLOP E_match value;
%   6. transform Y back to ref and display the complete physical setup.
%
% Scope of this example
% ---------------------
% The script uses only one ultrasound image and one measured point. It does
% not perform rigid registration or optimize the bone pose. Instead, it
% demonstrates the correspondence calculation that a future optimizer can
% call repeatedly for different candidate bone poses.
%
% The PD-tree remains fixed in CT. For each candidate pose, only the small
% query X is moved from ref into CT. This is much cheaper than rebuilding or
% transforming the complete tree at every optimizer evaluation.


%% 1. LOAD THE PREPARED ULTRASOUND AND BONE DATA

% Resolve every path from this file, so the demo also works when MATLAB was
% started from a different folder.
demoFolder   = fileparts(mfilename('fullpath'));
projectRoot  = fileparts(fileparts(demoFolder));
setupFilePath = fullfile(demoFolder, 'optimization_setup.mat');

% The shared project functions provide rigid transformations and display
% helpers. The demo folder contains the P-IMLOP preparation and search
% functions developed alongside dev_PDTreeSearch.m.
addpath(genpath(fullfile(projectRoot, 'functions')));
addpath(demoFolder);

% The saved setup contains the CT tibia mesh, tracked image planes, extracted
% ultrasound surface measurements, and the initial CT-to-ref registration.
load(setupFilePath, 'data');


%% 2. SELECT ONE ULTRASOUND IMAGE AND ONE ORIENTED MEASUREMENT X

% Image plane 11 is used throughout the development example because it
% intersects the pre-registered tibia. Change this index to demonstrate a
% different image, provided its surface measurement contains valid normals.
planeIndex                 = 11;
selectedPlane              = data.imagePlanesRef(planeIndex);
selectedSurfaceMeasurement = data.boneSurfaceMeasurements(planeIndex);

% Choose the middle point having a valid estimated surface normal. This
% avoids selecting an endpoint of the segmented bone curve.
validNormalIndices = find(selectedSurfaceMeasurement.surfaceNormalMask);
surfacePointIndex  = validNormalIndices(round((numel(validNormalIndices) + 1) / 2));

% A P-IMLOP ultrasound measurement has two parts:
%   - a 3D position in ref;
%   - a 2D unit normal in the local ultrasound image X-Y plane.
% The normal stays in the image frame because R_image_CT will later tell the
% matching function how that image plane is oriented in 3D.
X = struct();
X.position3DRef = double(selectedSurfaceMeasurement.surfaceCoordinatesXYZRef(surfacePointIndex, :)).';
X.normal2DImage = double(selectedSurfaceMeasurement.surfaceNormalXY(surfacePointIndex, :)).';
X.normal2DImage = X.normal2DImage / norm(X.normal2DImage);


%% 3. PREPARE THE CT MODEL Psi AND BUILD ITS REUSABLE PD-TREE

% preparePIMLOPModel keeps the original triangulation and computes the area,
% validity, and unit face normal of every mesh triangle. The result PsiCT is
% the complete oriented P-IMLOP model, expressed in CT coordinates.
PsiCT = preparePIMLOPModel(data.boneMeshCT);

% buildPIMLOPPDTree organizes all valid triangles into principal-direction
% boxes. Model preparation and tree construction are one-time operations: 
% a later optimizer should reuse this same PsiCT for every candidate pose.
PsiCT.pdTree = buildPIMLOPPDTree(PsiCT.mesh, PsiCT.validFaceMask);


%% 4. EXPRESS THE QUERY X IN THE FIXED CT SEARCH FRAME
% Why do we move X into CT before searching?
% A distance or orientation comparison is meaningful only when the query
% and model use the same 3D coordinate frame. At this point, they do not:
%
%   - X.position3DRef is the measured ultrasound point in ref;
%   - PsiCT.mesh, its face normals, and every PD-tree box are fixed in CT.
%
% We could transform the complete mesh and all PD-tree boxes into ref, but
% that would move thousands of model quantities whenever an optimizer tests
% a new bone pose. The simpler and cheaper choice is the opposite: keep the
% model and its tree unchanged, and temporarily transform the single query X
% from ref into CT. searchPDTree can then compare X with every model triangle
% in their shared CT frame.
%
% This temporary frame change does not undo the pre-registration and does
% not change the optimizer's meaning. The candidate transform still describes
% where the CT bone lies in ref. We merely use its inverse to ask the
% equivalent question: "Where does this measured ref point lie relative to
% the fixed CT bone?"

% The saved initial registration maps CT model points into ref:
%
%       p_ref = T_CT_ref_candidate * p_CT.
%
% This demo treats that pre-registration as the current candidate bone pose.
T_CT_ref_candidate = data.T_CT_ref_initial;

% Invert the rigid transform explicitly. The inverse of [R,t] is
% [R',-R'*t]. The resulting transform lets us move only X into CT.
R_CT_ref_candidate = T_CT_ref_candidate(1:3, 1:3);
t_CT_ref_candidate = T_CT_ref_candidate(1:3, 4);
T_ref_CT_candidate = eye(4);
T_ref_CT_candidate(1:3, 1:3) = R_CT_ref_candidate.';
T_ref_CT_candidate(1:3, 4)   = -R_CT_ref_candidate.' * t_CT_ref_candidate;

% Combine the tracked image pose with the candidate bone pose. R_image_CT
% tells P-IMLOP how to rotate image-frame normals and uncertainty into CT.
T_image_CT = T_ref_CT_candidate * selectedPlane.T_image_ref;
R_image_CT = T_image_CT(1:3, 1:3);

% XqueryCT is the structure expected by searchPDTree. Only its 3D position
% changes frame; the measured 2D normal remains in local image coordinates.
XqueryCT = struct();
XqueryCT.position3D = applyRigidTransform(X.position3DRef.', T_ref_CT_candidate).';
XqueryCT.normal2DImage = X.normal2DImage;


%% 5. SEARCH FOR THE MOST LIKELY MODEL POINT Y

% These two quantities describe the measurement model used by E_match.
% positionCovarianceImage is in the local image X-Y-Z frame and uses mm^2.
% kappa controls how strongly disagreement between projected normals is
% penalized; a larger kappa gives orientation more influence.
positionStandardDeviationImageMm = [1.0; 1.0; 1.5];
positionCovarianceImage = diag(positionStandardDeviationImageMm .^ 2);
kappa = 50;

% Enable Algorithm 2 pruning. searchPDTree tests promising boxes, evaluates
% points on the triangles in their leaves, and returns the candidate with the
% smallest nonnegative Equation (7) match error.
searchOptions = struct('UsePruning', true);
[YmatchCT, EMatch, searchDetails] = searchPDTree( ...
    XqueryCT, PsiCT, R_image_CT, ...
    positionCovarianceImage, kappa, searchOptions);

% Recalculate the selected pair once to obtain interpretable quantities such
% as Euclidean distance and projected-normal angle. The search has already
% computed the correspondence; this call only prepares the concise report.
[~, matchDetails] = calculatePIMLOPMatchError( ...
    XqueryCT, YmatchCT, R_image_CT, positionCovarianceImage, kappa);


%% 6. PRINT A SHORT, USER-ORIENTED RESULT SUMMARY

fprintf('\nP-IMLOP one-point PD-tree demo\n');
fprintf('  Ultrasound image plane          : %d\n',            planeIndex);
fprintf('  Valid model triangles           : %d\n',            PsiCT.pdTree.numberOfDatums);
fprintf('  PD-tree nodes / leaves          : %d / %d\n',       PsiCT.pdTree.numberOfNodes, PsiCT.pdTree.numberOfLeaves);
fprintf('  Selected model face             : %d\n',            YmatchCT.faceIndex);
fprintf('  X-to-Y distance                 : %.3f mm\n',       matchDetails.euclideanDistanceMm);
fprintf('  Projected-normal angle          : %.2f deg\n',      matchDetails.orientationAngleDeg);
fprintf('  Total E_match                   : %.6f\n',          EMatch);
fprintf('  Faces evaluated                 : %d / %d\n',       searchDetails.numberOfFacesEvaluated, PsiCT.pdTree.numberOfDatums);
fprintf('  Nodes pruned / search time      : %d / %.3f s\n\n', searchDetails.numberOfNodesPruned, searchDetails.elapsedSeconds);


%% 7. DISPLAY THE COMPLETE CORRESPONDENCE SETUP IN ref

% The search was deliberately performed in CT. For presentation, transform
% the mesh and the one returned model point into ref, where the ultrasound
% image was originally tracked. The PD-tree itself is not moved or rebuilt.
boneFaces     = PsiCT.mesh.ConnectivityList;
bonePointsRef = applyRigidTransform(PsiCT.mesh.Points, T_CT_ref_candidate);

YmatchRefPosition = applyRigidTransform(YmatchCT.position3D.', T_CT_ref_candidate).';
YmatchRefNormal   = R_CT_ref_candidate * YmatchCT.normal3D;

% Lift the measured 2D ultrasound normal into ref for display. Translation
% is not applied to normals because they represent directions, not points.
R_image_ref  = selectedPlane.T_image_ref(1:3, 1:3);
Xnormal3DRef = R_image_ref * [X.normal2DImage; 0];

% Use the image dimensions to select a visible but physically meaningful
% arrow length. This scale changes only the drawing; both stored normals
% remain unit vectors in all P-IMLOP calculations.
imageExtentMm      = max([selectedPlane.W, selectedPlane.H]);
normalDisplayScale = 0.15 * imageExtentMm;
pixelSpacingXYMm   = [ ...
    selectedPlane.W / max(selectedPlane.nCols - 1, 1), ...
    selectedPlane.H / max(selectedPlane.nRows - 1, 1)];

% Use two views in one figure. The left view preserves the complete physical
% setup; the right view magnifies the sub-millimetre X-to-Y correspondence.
% Both panels contain the same geometry in ref coordinates.
demoFigure = figure( ...
    'Name', 'P-IMLOP one-point PD-tree search demo', ...
    'Position', [100, 100, 1500, 650]);
demoLayout = tiledlayout(demoFigure, 1, 2, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');
demoAxes = nexttile(demoLayout, 1);
hold(demoAxes, 'on');
grid(demoAxes, 'on');
axis(demoAxes, 'equal');
view(demoAxes, 35, 30);
xlabel(demoAxes, 'X_{ref} (mm)');
ylabel(demoAxes, 'Y_{ref} (mm)');
zlabel(demoAxes, 'Z_{ref} (mm)');

% Draw the complete pre-registered tibia lightly. It provides anatomical
% context while allowing the ultrasound image and correspondence to remain
% visible through the surface.
boneHandle = patch(demoAxes, ...
    'Faces', boneFaces, ...
    'Vertices', bonePointsRef, ...
    'FaceColor', [0.84, 0.78, 0.70], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.28, ...
    'DisplayName', 'Pre-registered tibia mesh');

% Draw the tracked ultrasound image at its original pose in ref. The mesh
% intersection is visible because both the bone and image are translucent.
imageHandle = display_image3D(demoAxes, ...
    selectedPlane.image, selectedPlane.T_image_ref, ...
    'SwapXY', true, ...
    'PixelSpacing', pixelSpacingXYMm, ...
    'Tag', 'demo_pdtree_image_plane', ...
    'Colormap', 'gray', ...
    'FaceAlpha', 0.45);
imageHandle.DisplayName = sprintf('Ultrasound plane %d', planeIndex);

% Highlight the triangle that contains Y. Although triangle centres organize
% the PD-tree, the returned Y may lie anywhere on this complete triangle.
winningTriangleHandle = patch(demoAxes, ...
    'Faces', boneFaces(YmatchCT.faceIndex, :), ...
    'Vertices', bonePointsRef, ...
    'FaceColor', [0.05, 0.75, 0.95], ...
    'EdgeColor', [0.00, 0.20, 0.35], ...
    'LineWidth', 2, ...
    'DisplayName', 'Selected model triangle');

% X and its normal are red. The point came from the ultrasound measurement,
% while the arrow is the measured 2D normal lifted into the displayed 3D
% image plane.
xPointHandle = scatter3(demoAxes, ...
    X.position3DRef(1), X.position3DRef(2), X.position3DRef(3), ...
    80, [0.90, 0.05, 0.05], 'filled', ...
    'DisplayName', 'Measurement X');
xNormalHandle = quiver3(demoAxes, ...
    X.position3DRef(1), X.position3DRef(2), X.position3DRef(3), ...
    Xnormal3DRef(1) * normalDisplayScale, ...
    Xnormal3DRef(2) * normalDisplayScale, ...
    Xnormal3DRef(3) * normalDisplayScale, ...
    0, 'Color', [0.90, 0.05, 0.05], 'LineWidth', 2.5, ...
    'MaxHeadSize', 0.8, 'DisplayName', 'Measured normal');

% Y and its model face normal are blue. These are the oriented model point
% and orientation selected from the entire tibia by the PD-tree search.
yPointHandle = scatter3(demoAxes, ...
    YmatchRefPosition(1), YmatchRefPosition(2), YmatchRefPosition(3), ...
    90, [0.05, 0.30, 0.95], 'filled', ...
    'DisplayName', 'Selected model point Y');
yNormalHandle = quiver3(demoAxes, ...
    YmatchRefPosition(1), YmatchRefPosition(2), YmatchRefPosition(3), ...
    YmatchRefNormal(1) * normalDisplayScale, ...
    YmatchRefNormal(2) * normalDisplayScale, ...
    YmatchRefNormal(3) * normalDisplayScale, ...
    0, 'Color', [0.05, 0.30, 0.95], 'LineWidth', 2.5, ...
    'MaxHeadSize', 0.8, 'DisplayName', 'Selected model normal');

% The dashed line makes the positional part of the correspondence explicit:
% it joins the measured point X to the selected model point Y.
correspondenceHandle = plot3(demoAxes, ...
    [X.position3DRef(1), YmatchRefPosition(1)], ...
    [X.position3DRef(2), YmatchRefPosition(2)], ...
    [X.position3DRef(3), YmatchRefPosition(3)], ...
    '--', 'Color', [0.15, 0.15, 0.15], 'LineWidth', 1.8, ...
    'DisplayName', 'X-to-Y correspondence');

title(demoAxes, 'Complete tracked setup in ref', 'Interpreter', 'tex');
legend(demoAxes, [ ...
    boneHandle; imageHandle; winningTriangleHandle; ...
    xPointHandle; xNormalHandle; yPointHandle; yNormalHandle; ...
    correspondenceHandle], ...
    'Location', 'northwest', ...
    'NumColumns', 2, ...
    'FontSize', 8, ...
    'Interpreter', 'tex');

% Copy the already drawn scene into a second axes, then restrict its limits
% to the winning triangle and correspondence. Copying avoids recomputing or
% redrawing a different result: both panels show the exact same objects.
closeupAxes = nexttile(demoLayout, 2);
copyobj(allchild(demoAxes), closeupAxes);
hold(closeupAxes, 'on');
grid(closeupAxes, 'on');
axis(closeupAxes, 'equal');
view(closeupAxes, 35, 30);
xlabel(closeupAxes, 'X_{ref} (mm)');
ylabel(closeupAxes, 'Y_{ref} (mm)');
zlabel(closeupAxes, 'Z_{ref} (mm)');

% The close-up limits include X, Y, and all three vertices of the selected
% triangle. Padding leaves enough room to see both normal arrows fully.
winningVertexIndices = boneFaces(YmatchCT.faceIndex, :);
closeupPointsRef = [ ...
    bonePointsRef(winningVertexIndices, :); ...
    X.position3DRef.'; ...
    YmatchRefPosition.'];
closeupMinimumRef = min(closeupPointsRef, [], 1);
closeupMaximumRef = max(closeupPointsRef, [], 1);
closeupPaddingMm  = max(5, normalDisplayScale);
xlim(closeupAxes, [closeupMinimumRef(1), closeupMaximumRef(1)] + [-1, 1] * closeupPaddingMm);
ylim(closeupAxes, [closeupMinimumRef(2), closeupMaximumRef(2)] + [-1, 1] * closeupPaddingMm);
zlim(closeupAxes, [closeupMinimumRef(3), closeupMaximumRef(3)] + [-1, 1] * closeupPaddingMm);
title(closeupAxes, 'Close-up of selected X-to-Y match', 'Interpreter', 'tex');

sgtitle(demoFigure, sprintf( ...
    'P-IMLOP match: face %d, E_{match} = %.3f', ...
    YmatchCT.faceIndex, EMatch), ...
    'Interpreter', 'tex', ...
    'FontWeight', 'bold');

% Enable mouse rotation so the user can inspect how the ultrasound plane,
% selected triangle, and both normals relate in 3D.
rotate3d(demoFigure, 'on');
