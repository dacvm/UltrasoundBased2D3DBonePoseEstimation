clear; clc; close all;

%% LOAD THE SAVED OPTIMIZATION SETUP

% Resolve paths from this script so it works even when MATLAB was started
% from another folder.
developmentFolder = fileparts(mfilename('fullpath'));
projectRoot       = fileparts(fileparts(developmentFolder));
setupFilePath     = fullfile(developmentFolder, 'optimization_setup.mat');

% Add both the project helpers and this development folder. The latter makes
% preparePIMLOPModel available even when MATLAB starts from another folder.
addpath(genpath(fullfile(projectRoot, 'functions')));
addpath(developmentFolder);

% Load the fixed fixture created from the one-sweep optimization workflow.
% The variables remain visible in the workspace for the next E_match steps.
load(setupFilePath, 'data', 'config', 'initialPoseVector');


%% SELECT ONE IMAGE PLANE AND ONE VALID ORIENTED ULTRASOUND POINT

% Surface measurements were aligned to image planes during input
% preparation, so the same index selects one image and its extracted curve.
planeIndex                 = 11;
selectedPlane              = data.imagePlanesRef(planeIndex);
selectedSurfaceMeasurement = data.boneSurfaceMeasurements(planeIndex);

% Stop with a clear message if an older setup file without surface normals
% is loaded accidentally.
requiredNormalFields = {'surfaceCoordinatesXYZRef', 'surfaceNormalXY', 'surfaceNormalMask'};
if ~all(isfield(selectedSurfaceMeasurement, requiredNormalFields))
    error('dev_PDTreeSearch:MissingSurfaceNormals', ...
          'Surface measurement %d does not contain the required normal fields.', planeIndex);
end

% Select the middle valid normal rather than an end point, because central
% curve points are easier to inspect and are less sensitive to edge effects.
validNormalIndices = find(selectedSurfaceMeasurement.surfaceNormalMask);
if isempty(validNormalIndices)
    error('dev_PDTreeSearch:NoValidSurfaceNormal', ...
          'Surface measurement %d contains no valid surface normal.', planeIndex);
end
surfacePointIndex = validNormalIndices(round((numel(validNormalIndices) + 1) / 2));

% Store x_3dp directly in the ultrasound oriented-point struct. Row i of the
% point and normal arrays refers to the same extracted surface sample.
x.position3DRef = double(selectedSurfaceMeasurement.surfaceCoordinatesXYZRef(surfacePointIndex, :)).';

% Store x_2dn as a 2D unit direction in physical image X-Y. Force it to a
% column and normalize again to protect this development script from
% harmless floating-point drift in the saved artifact.
x.normal2DImage = double(selectedSurfaceMeasurement.surfaceNormalXY(surfacePointIndex, :)).';
x.normal2DImage = x.normal2DImage / norm(x.normal2DImage);

% Lift the 2D normal into the local 3D image frame by assigning zero to its
% out-of-plane component. Rotate it into ref using the rotation block of
% T_image_ref:
%       n_ref = R_image_ref * [n_x; n_y; 0].
% Translation is deliberately excluded because a normal is a direction.
R_image_ref            = selectedPlane.T_image_ref(1:3, 1:3);
xNormal3DRefForDisplay = R_image_ref * [x.normal2DImage; 0];
xNormal3DRefForDisplay = xNormal3DRefForDisplay / norm(xNormal3DRefForDisplay);

% X is the complete ultrasound measurement set. In this one-point setup,
% that set contains only x. Keep X here because x now has both properties
% that define one projection-oriented point: its position and 2D normal.
X = x;


%% PREPARE THE WHOLE BONE MODEL IN CT

% Read the original CT-frame triangulation from the prepared optimization
% data. Keep the source mesh unchanged so later PD-tree experiments can
% always start from the same model geometry.
if ~isfield(data, 'boneMeshCT') || ~isa(data.boneMeshCT, 'triangulation')
    error('dev_PDTreeSearch:MissingBoneMesh', ...
          'The loaded optimization setup must contain data.boneMeshCT as a triangulation.');
end
boneMeshCT = data.boneMeshCT;

% PsiCT is the complete searchable model from the paper. Stage 1 computes
% only triangle areas, face normals, and the valid-face mask. Its pdTree
% field intentionally remains empty until Stage 2 is implemented.
PsiCT = preparePIMLOPModel(boneMeshCT);

% The existing overview figure remains in ref because it helps relate the
% bone to the tracked ultrasound measurement. This transformed copy is for
% display only; the prepared P-IMLOP model itself stays fixed in CT.
% The coarse-registration transform maps CT coordinates into ref:
%       p_ref = T_CT_ref_initial * p_CT.
% Transform every mesh vertex with the shared project helper, then rebuild
% the triangulation with the original face connectivity.
T_CT_ref_initial = data.T_CT_ref_initial;
bonePointsRef    = applyRigidTransform(PsiCT.mesh.Points, T_CT_ref_initial);
boneMeshRef      = triangulation(PsiCT.mesh.ConnectivityList, bonePointsRef);


%% DISPLAY THE SETUP

% Use the physical image size to keep all arrows readable without hard-coded
% lengths that only work for one acquisition.
imageExtentMm      = max([selectedPlane.W, selectedPlane.H]);
axisDisplayScale   = 0.15 * imageExtentMm;
normalDisplayScale = 0.15 * imageExtentMm;
pixelSpacingXYMm   = [ ...
    selectedPlane.W / max(selectedPlane.nCols - 1, 1), ...
    selectedPlane.H / max(selectedPlane.nRows - 1, 1)];

setupFigure = figure('Name', 'P-IMLOP PD-SEARCH');
setupAxes   = axes(setupFigure);
hold(setupAxes, 'on');
grid(setupAxes, 'on');
axis(setupAxes, 'equal');
view(setupAxes, 35, 35);
xlabel(setupAxes, 'X_{ref} (mm)');
ylabel(setupAxes, 'Y_{ref} (mm)');
zlabel(setupAxes, 'Z_{ref} (mm)');

% Draw the complete bone model after transforming it from CT into ref. A
% transparent surface keeps the selected image and measurement point visible
% while still showing the full model domain that the PD-tree will search.
boneMeshHandle = patch(setupAxes, ...
    'Faces', boneMeshRef.ConnectivityList, ...
    'Vertices', boneMeshRef.Points, ...
    'FaceColor', [0.92, 0.83, 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.30, ...
    'DisplayName', 'Bone mesh \Psi in ref');

% Draw the selected tracked image at its saved pose in ref.
imageHandle = display_image3D(setupAxes, ...
    selectedPlane.image, ...
    selectedPlane.T_image_ref, ...
    'SwapXY', true, ...
    'PixelSpacing', pixelSpacingXYMm, ...
    'Tag', 'dev_pdtree_image_plane', ...
    'Colormap', 'gray', ...
    'FaceAlpha', 0.40);
imageHandle.DisplayName = sprintf('Ultrasound plane %d', planeIndex);

% Draw the rigid-body axes stored by T_image_ref. The columns of its rotation
% block are the local image X, Y, and Z directions expressed in ref.
display_axis_v2(setupAxes, ...
    selectedPlane.T_image_ref(1:3, 4), ...
    R_image_ref, ...
    axisDisplayScale, ...
    '', ...
    'Tag', 'dev_pdtree_image_axes', ...
    'Mode', 'default');

% Draw the selected ultrasound surface sample x as a red point.
xPointHandle = scatter3(setupAxes, ...
    x.position3DRef(1), x.position3DRef(2), x.position3DRef(3), ...
    70, [0.90, 0.05, 0.05], 'filled', ...
    'DisplayName', 'Ultrasound point x');

% Draw the lifted 2D ultrasound normal from the measured point. AutoScale is
% disabled because the vector is already multiplied by the desired length.
xNormalHandle = quiver3(setupAxes, ...
    x.position3DRef(1), x.position3DRef(2), x.position3DRef(3), ...
    xNormal3DRefForDisplay(1) * normalDisplayScale, ...
    xNormal3DRefForDisplay(2) * normalDisplayScale, ...
    xNormal3DRefForDisplay(3) * normalDisplayScale, ...
    0, ...
    'Color', [0.90, 0.05, 0.05], ...
    'LineWidth', 2.5, ...
    'MaxHeadSize', 0.8, ...
    'DisplayName', 'Ultrasound normal x_{2dn} in ref');

% Use one compact legend for the visible model and measurement objects. The
% three image-frame axis arrows remain visible without separate legend rows.
legend(setupAxes, ...
    [boneMeshHandle, imageHandle, xPointHandle, xNormalHandle], ...
    'Location', 'best', ...
    'Interpreter', 'tex');
drawnow;


%% VALIDATE STAGE 1: MODEL GEOMETRY

% Summarize the prepared arrays before drawing them. These checks focus on
% the properties needed by later P-IMLOP stages without adding PD-tree logic.
validFaceIndices         = find(PsiCT.validFaceMask);
validFaceAreasMm2        = PsiCT.faceAreas(PsiCT.validFaceMask);
validFaceNormalsCT       = PsiCT.faceNormals(PsiCT.validFaceMask, :);
validNormalLengths       = vecnorm(validFaceNormalsCT, 2, 2);
maximumNormalLengthError = max(abs(validNormalLengths - 1));

allValidAreasPositive    = all(validFaceAreasMm2 > 0);
allValidNormalsFinite    = all(isfinite(validFaceNormalsCT), 'all');
pdTreeIsEmpty            = isempty(PsiCT.pdTree);

if ~allValidAreasPositive || ~allValidNormalsFinite || ...
        maximumNormalLengthError > 1e-12 || ~pdTreeIsEmpty
    error('dev_PDTreeSearch:Stage1VerificationFailed', ...
          'The prepared Stage 1 CT mesh geometry did not pass verification.');
end

fprintf('\nP-IMLOP Stage 1 model geometry verification:\n');
fprintf('  Vertices                         : %d\n',        size(PsiCT.mesh.Points, 1));
fprintf('  Faces                            : %d\n',        size(PsiCT.mesh.ConnectivityList, 1));
fprintf('  Valid faces                      : %d\n',        nnz(PsiCT.validFaceMask));
fprintf('  Invalid or degenerate faces      : %d\n',        nnz(~PsiCT.validFaceMask));
fprintf('  Minimum valid face area          : %.6f mm^2\n', min(validFaceAreasMm2));
fprintf('  Median valid face area           : %.6f mm^2\n', median(validFaceAreasMm2));
fprintf('  Maximum valid face area          : %.6f mm^2\n', max(validFaceAreasMm2));
fprintf('  Maximum normal-length error      : %.3e\n',      maximumNormalLengthError);
fprintf('  All valid normals finite         : PASS\n');
fprintf('  All valid areas positive         : PASS\n');
fprintf('  PD-tree remains empty (Stage 1)  : PASS\n');

% Choose one deterministic local group of faces. The middle valid face is
% used as a seed, and the closest face centres form a compact patch that is
% easier to inspect than thousands of normal arrows on the whole bone.
boneFaces          = PsiCT.mesh.ConnectivityList;
bonePointsCT       = PsiCT.mesh.Points;
faceVertex1CT      = bonePointsCT(boneFaces(:, 1), :);
faceVertex2CT      = bonePointsCT(boneFaces(:, 2), :);
faceVertex3CT      = bonePointsCT(boneFaces(:, 3), :);
faceCentersCT      = (faceVertex1CT + faceVertex2CT + faceVertex3CT) / 3;

seedFaceIndex      = validFaceIndices(round((numel(validFaceIndices) + 1) / 2));
offsetFromSeedCT   = faceCentersCT(validFaceIndices, :) - faceCentersCT(seedFaceIndex, :);
squaredSeedDistance = sum(offsetFromSeedCT .^ 2, 2);
[~, nearestFaceOrder] = sort(squaredSeedDistance, 'ascend');

numberOfPatchFaces = min(80, numel(validFaceIndices));
patchFaceIndices   = validFaceIndices(nearestFaceOrder(1:numberOfPatchFaces));
patchCentersCT     = faceCentersCT(patchFaceIndices, :);
patchNormalsCT     = PsiCT.faceNormals(patchFaceIndices, :);

% Use the actual vertices of the selected triangles to define a close-up
% view. Without these limits, the full bone makes the local arrows too small
% to inspect even though the calculations themselves are correct.
patchVertexIndices = unique(boneFaces(patchFaceIndices, :));
patchPointsCT      = bonePointsCT(patchVertexIndices, :);
patchMinimumCT     = min(patchPointsCT, [], 1);
patchMaximumCT     = max(patchPointsCT, [], 1);
patchSpanCT        = patchMaximumCT - patchMinimumCT;
patchPaddingMm     = max(0.5, 0.15 * max(patchSpanCT));

% Scale every arrow equally. Face area is already encoded by surface colour,
% while equal arrow lengths make normal directions easy to compare.
patchExtentCT         = max(patchCentersCT, [], 1) - min(patchCentersCT, [], 1);
normalDisplayScaleCT  = max(1.5, 0.15 * norm(patchExtentCT));

geometryFigure = figure('Name', 'P-IMLOP Stage 1: CT Mesh Geometry');
geometryAxes   = axes(geometryFigure);
hold(geometryAxes, 'on');
grid(geometryAxes, 'on');
axis(geometryAxes, 'equal');
view(geometryAxes, 35, 35);
xlabel(geometryAxes, 'X_{CT} (mm)');
ylabel(geometryAxes, 'Y_{CT} (mm)');
zlabel(geometryAxes, 'Z_{CT} (mm)');

% The transparent whole bone provides location context for the opaque local
% patch. Its edges are hidden so the selected triangles remain readable.
wholeBoneHandle = patch(geometryAxes, ...
    'Faces', boneFaces, ...
    'Vertices', bonePointsCT, ...
    'FaceColor', [0.82, 0.82, 0.82], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.12, ...
    'DisplayName', 'Complete CT bone mesh');

% Colour each selected triangle by its physical area. This shows both the
% chosen local mesh region and whether neighbouring triangle sizes vary in
% a plausible way.
areaPatchHandle = patch(geometryAxes, ...
    'Faces', boneFaces(patchFaceIndices, :), ...
    'Vertices', bonePointsCT, ...
    'FaceVertexCData', PsiCT.faceAreas(patchFaceIndices), ...
    'FaceColor', 'flat', ...
    'EdgeColor', [0.20, 0.20, 0.20], ...
    'LineWidth', 0.5, ...
    'DisplayName', 'Local faces coloured by area');

normalHandle = quiver3(geometryAxes, ...
    patchCentersCT(:, 1), patchCentersCT(:, 2), patchCentersCT(:, 3), ...
    normalDisplayScaleCT * patchNormalsCT(:, 1), ...
    normalDisplayScaleCT * patchNormalsCT(:, 2), ...
    normalDisplayScaleCT * patchNormalsCT(:, 3), ...
    0, ...
    'Color', [0.85, 0.05, 0.05], ...
    'LineWidth', 1.1, ...
    'MaxHeadSize', 0.7, ...
    'DisplayName', 'Unit face normals');

% Crop the axes to the selected neighbourhood while retaining a little
% surrounding transparent bone for context.
xlim(geometryAxes, [patchMinimumCT(1), patchMaximumCT(1)] + [-1, 1] * patchPaddingMm);
ylim(geometryAxes, [patchMinimumCT(2), patchMaximumCT(2)] + [-1, 1] * patchPaddingMm);
zlim(geometryAxes, [patchMinimumCT(3), patchMaximumCT(3)] + [-1, 1] * patchPaddingMm);

areaColorbar = colorbar(geometryAxes);
areaColorbar.Label.String = 'Face area (mm^2)';
colormap(geometryAxes, parula);
title(geometryAxes, sprintf('Stage 1 verification: %d nearby CT faces', numberOfPatchFaces));
legend(geometryAxes, [wholeBoneHandle, areaPatchHandle, normalHandle], 'Location', 'best');
rotate3d(geometryFigure, 'on');
drawnow;
