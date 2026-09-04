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
    [imageHandle, xPointHandle, xNormalHandle], ...
    'Location', 'best', ...
    'Interpreter', 'tex');
drawnow;


%% STAGE 1: PREPARE THE CT MESH GEOMETRY

% -------------------------------------------------------------------------
% PART 1: PREPARE THE WHOLE BONE MODEL IN CT

% Read the original CT-frame triangulation from the prepared optimization
% data. Keep the source mesh unchanged so later PD-tree experiments can
% always start from the same model geometry.
if ~isfield(data, 'boneMeshCT') || ~isa(data.boneMeshCT, 'triangulation')
    error('dev_PDTreeSearch:MissingBoneMesh', ...
          'The loaded optimization setup must contain data.boneMeshCT as a triangulation.');
end
boneMeshCT = data.boneMeshCT;

% PsiCT is the complete model from the paper. At this first stage, the
% preparation function computes only the triangle geometry. The PD-tree is
% deliberately built later, at the beginning of Stage 2, so each
% development step remains visible and easy to study.
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
drawnow;


% -------------------------------------------------------------------------
% PART 2: VALIDATE NORMALS

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

seedFaceIndex         = validFaceIndices(round((numel(validFaceIndices) + 1) / 2));
offsetFromSeedCT      = faceCentersCT(validFaceIndices, :) - faceCentersCT(seedFaceIndex, :);
squaredSeedDistance   = sum(offsetFromSeedCT .^ 2, 2);
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


%% STAGE 2: PD-TREE CONSTRUCTION

% -------------------------------------------------------------------------
% PART 1: CONSTRUCT THE PD-TREE

% Build the fixed CT-frame PD-tree from the valid triangles prepared in
% Stage 1. Keeping this call here makes the two development steps explicit:
% first prepare the mesh geometry, and then organize it into a search tree.
pdTreeOptions = struct();
pdTreeOptions.faceCountThreshold    = 15;
pdTreeOptions.minimumNodeDiagonalMm = 15;

PsiCT.pdTree = buildPIMLOPPDTree(PsiCT.mesh, PsiCT.validFaceMask, pdTreeOptions);

% -------------------------------------------------------------------------
% PART 2: VALIDATION REPORT

% This validation asks a simple question first: "Did the tree lose or
% duplicate any model triangles?"
%
% A triangle appears in several ancestor nodes while we travel down the
% tree, but it must finish in exactly one leaf. Therefore, we collect the
% face indices from all leaves and compare that collection with the complete
% list of valid faces prepared in Stage 1.
pdTree          = PsiCT.pdTree;
treeNodes       = pdTree.nodes;
leafNodeIndices = find([treeNodes.isLeaf]);
leafFaceIndices = vertcat(treeNodes(leafNodeIndices).datumFaceIndices);

% Sorting removes any dependence on tree traversal order. The three tests
% below mean:
%   1. both lists contain the same number of entries;
%   2. both lists contain the same face indices;
%   3. the leaf list contains no repeated face index.
sortedValidFaces = sort(validFaceIndices(:));
sortedLeafFaces  = sort(leafFaceIndices(:));
everyFaceAppearsOnce = ...
    numel(sortedLeafFaces) == numel(sortedValidFaces) && ...
    isequal(sortedLeafFaces, sortedValidFaces) && ...
    numel(unique(sortedLeafFaces)) == numel(sortedLeafFaces);

% The following flags start as true. While visiting every node, a flag stays
% true only if every node examined so far satisfies that property. This
% gives one compact final result for each important tree promise:
%   - every node has a valid local coordinate frame;
%   - every node bounding box encloses its complete triangles;
%   - every internal node divides its faces correctly between two children.
allNodeFramesRigid        = true;
allNodeBoundsContainFaces = true;
childrenPartitionParents  = true;

for nodeIndex = 1:numel(treeNodes)
    % STEP 1: Read this node and validate its coordinate frame.
    %
    % T_node_CT maps a point from this node's local coordinates into CT:
    %       p_CT = T_node_CT * p_node.
    % Its upper-left 3-by-3 block must therefore be a genuine rotation.
    % Orthonormal columns preserve lengths and angles, determinant +1 rules
    % out a reflection, and the final row gives the standard homogeneous
    % rigid-transform form.
    node = treeNodes(nodeIndex);
    R_node_CT = node.T_node_CT(1:3, 1:3);

    rotationIsOrthonormal = norm(R_node_CT.' * R_node_CT - eye(3), 'fro') <= 1e-10;
    rotationIsProper      = abs(det(R_node_CT) - 1) <= 1e-10;
    homogeneousRowIsValid = norm(node.T_node_CT(4, :) - [0, 0, 0, 1]) <= 1e-12;
    allNodeFramesRigid    = allNodeFramesRigid && rotationIsOrthonormal && rotationIsProper && homogeneousRowIsValid;

    % STEP 2: Confirm that the node's oriented bounding box (OBB) really
    % contains the model geometry assigned to this node.
    %
    % The OBB limits are stored in node-local coordinates, so CT vertices
    % cannot be compared with those limits directly. We first gather every
    % unique vertex used by the node's triangles, subtract the node origin,
    % and apply R_node_CT transpose. The transpose is the inverse rotation,
    % so this operation expresses CT points in the node frame:
    %       p_node = R_node_CT' * (p_CT - origin_CT).
    nodeVertexIndices = unique(boneFaces(node.datumFaceIndices, :));
    nodePointsCT      = bonePointsCT(nodeVertexIndices, :);
    nodeOriginCT      = node.T_node_CT(1:3, 4).';
    nodePointsNode    = (R_node_CT.' * (nodePointsCT - nodeOriginCT).').';
    % Floating-point calculations may place a point an extremely small
    % distance outside a theoretically exact limit. The tolerance avoids
    % treating that numerical roundoff as a faulty box. Every local x, y,
    % and z coordinate must then lie between the saved minimum and maximum.
    boundsToleranceMm = 1e-9 * max(1, norm(node.boundsMaxNode - node.boundsMinNode));
    nodeInsideBounds  = all(nodePointsNode >= node.boundsMinNode - boundsToleranceMm, 'all') && ...
                        all(nodePointsNode <= node.boundsMaxNode + boundsToleranceMm, 'all');
    allNodeBoundsContainFaces = allNodeBoundsContainFaces && nodeInsideBounds;

    % STEP 3: If this is an internal node, confirm that its split was valid.
    %
    % A correct binary split neither invents, loses, nor duplicates faces:
    % the left and right sets must not overlap, and joining them must recover
    % the parent's complete face set. Each child also stores the index of
    % this node, allowing future tree traversal to move in either direction.
    % Leaf nodes have no children, so this step does not apply to them.
    if ~node.isLeaf
        leftNode  = treeNodes(node.leftNodeIndex);
        rightNode = treeNodes(node.rightNodeIndex);
        combinedChildFaces = [leftNode.datumFaceIndices; rightNode.datumFaceIndices];

        childrenAreDisjoint       = isempty(intersect(leftNode.datumFaceIndices, rightNode.datumFaceIndices));
        childrenCoverParent       = isequal(sort(combinedChildFaces), sort(node.datumFaceIndices));
        childrenPointBackToParent = leftNode.parentNodeIndex == nodeIndex && rightNode.parentNodeIndex == nodeIndex;

        childrenPartitionParents  = childrenPartitionParents && childrenAreDisjoint && childrenCoverParent && childrenPointBackToParent;
    end
end

leafFaceCounts = arrayfun( ...
    @(nodeIndex) numel(treeNodes(nodeIndex).datumFaceIndices), ...
    leafNodeIndices);

if ~everyFaceAppearsOnce || ...
        ~childrenPartitionParents || ...
        ~allNodeBoundsContainFaces || ...
        ~allNodeFramesRigid
    error('dev_PDTreeSearch:Stage2VerificationFailed', ...
          'The Stage 2 PD-tree did not pass its structural verification.');
end

fprintf('\nP-IMLOP Stage 2 PD-tree verification:\n');
fprintf('  Valid mesh datums                 : %d\n', pdTree.numberOfDatums);
fprintf('  Datums stored in leaves           : %d\n', numel(leafFaceIndices));
fprintf('  Total nodes                       : %d\n', pdTree.numberOfNodes);
fprintf('  Leaf nodes                        : %d\n', pdTree.numberOfLeaves);
fprintf('  Maximum depth                     : %d\n', pdTree.maximumDepth);
fprintf('  Leaf face count min / mean / max  : %d / %.2f / %d\n', min(leafFaceCounts), mean(leafFaceCounts), max(leafFaceCounts));
fprintf('  Face-count stopping threshold     : %d\n', pdTree.options.faceCountThreshold);
fprintf('  Minimum node diagonal setting     : %.2f mm\n', pdTree.options.minimumNodeDiagonalMm);
fprintf('  Every valid face appears once     : PASS\n');
fprintf('  Child sets partition parents      : PASS\n');
fprintf('  Every OBB contains its faces      : PASS\n');
fprintf('  Every node frame is rigid         : PASS\n');


% -------------------------------------------------------------------------
% PART 3: VALIDATION DISPLAY

% This figure is a visual explanation of the first three PD-tree levels:
%   - the black root box surrounds the whole valid bone mesh;
%   - the two red child boxes show the root's first spatial division;
%   - the four blue grandchild boxes show the next division.
%
% Displaying deeper levels would add hundreds of overlapping boxes and make
% the hierarchy harder to see. These first seven boxes are enough to check
% that child regions become smaller and follow the shape of their assigned
% bone regions.
treeFigure = figure('Name', 'P-IMLOP Stage 2: First PD-Tree Generations');
treeAxes   = axes(treeFigure);
hold(treeAxes, 'on');
grid(treeAxes, 'on');
axis(treeAxes, 'equal');
view(treeAxes, 35, 35);
xlabel(treeAxes, 'X_{CT} (mm)');
ylabel(treeAxes, 'Y_{CT} (mm)');
zlabel(treeAxes, 'Z_{CT} (mm)');

treeBoneHandle = patch(treeAxes, ...
    'Faces', boneFaces, ...
    'Vertices', bonePointsCT, ...
    'FaceColor', [0.65, 0.70, 0.75], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.55, ...
    'DisplayName', 'CT bone mesh');

% Each row gives the eight corners of a box in an order that makes the edge
% list below easy to follow: four corners on the lower face, then four on the
% upper face.
boxEdgePairs = [ ...
    1, 2; 2, 3; 3, 4; 4, 1; ...
    5, 6; 6, 7; 7, 8; 8, 5; ...
    1, 5; 2, 6; 3, 7; 4, 8];
depthColors = [ ...
    0.05, 0.05, 0.05; ...
    0.85, 0.15, 0.15; ...
    0.10, 0.35, 0.95];
depthNames = {'Depth 0: root OBB', 'Depth 1: child OBBs', 'Depth 2: grandchild OBBs'};
depthLegendHandles = gobjects(3, 1);

displayNodeIndices = find([treeNodes.depth] <= 2);
for displayIndex = 1:numel(displayNodeIndices)
    % STEP 1: Select one of the root, child, or grandchild nodes. Its depth
    % determines the box colour used to reveal the tree generation.
    nodeIndex = displayNodeIndices(displayIndex);
    node      = treeNodes(nodeIndex);
    depth     = node.depth;

    % STEP 2: Reconstruct the eight corners of the node's box.
    %
    % boundsMinNode and boundsMaxNode store two opposite corners in the
    % node's own coordinate frame. Taking every minimum/maximum combination
    % of x, y, and z produces all eight corners of the rectangular box.
    minimumCorner = node.boundsMinNode;
    maximumCorner = node.boundsMaxNode;
    boxCornersNode = [ ...
        minimumCorner(1), minimumCorner(2), minimumCorner(3); ...
        maximumCorner(1), minimumCorner(2), minimumCorner(3); ...
        maximumCorner(1), maximumCorner(2), minimumCorner(3); ...
        minimumCorner(1), maximumCorner(2), minimumCorner(3); ...
        minimumCorner(1), minimumCorner(2), maximumCorner(3); ...
        maximumCorner(1), minimumCorner(2), maximumCorner(3); ...
        maximumCorner(1), maximumCorner(2), maximumCorner(3); ...
        minimumCorner(1), maximumCorner(2), maximumCorner(3)];
    % The corners currently live in the node frame. Transform them into CT
    % so they can be drawn on top of the CT bone mesh in the same axes.
    boxCornersCT = applyRigidTransform(boxCornersNode, node.T_node_CT);

    % STEP 3: Turn the eight CT corners into twelve visible box edges.
    % boxEdgePairs says which two corners form each edge. A NaN after every
    % pair tells MATLAB to lift the virtual pen before drawing the next edge;
    % otherwise MATLAB would add unwanted lines between unrelated edges.
    % Drawing all twelve segments as one object also keeps the figure simple.
    boxX = [boxCornersCT(boxEdgePairs(:, 1), 1), ...
            boxCornersCT(boxEdgePairs(:, 2), 1), nan(12, 1)].';
    boxY = [boxCornersCT(boxEdgePairs(:, 1), 2), ...
            boxCornersCT(boxEdgePairs(:, 2), 2), nan(12, 1)].';
    boxZ = [boxCornersCT(boxEdgePairs(:, 1), 3), ...
            boxCornersCT(boxEdgePairs(:, 2), 3), nan(12, 1)].';

    boxHandle = plot3(treeAxes, boxX(:), boxY(:), boxZ(:), ...
        'Color', depthColors(depth + 1, :), ...
        'LineWidth', 2.4 - 0.5 * depth);

    % STEP 4: Give only the first box of each depth a legend entry. All boxes
    % at that depth have the same meaning and colour, so repeated entries
    % would add clutter without adding information.
    if ~isgraphics(depthLegendHandles(depth + 1))
        boxHandle.DisplayName = depthNames{depth + 1};
        depthLegendHandles(depth + 1) = boxHandle;
    else
        boxHandle.HandleVisibility = 'off';
    end

    % STEP 5: For the root and its children, draw the direction along which
    % that node was split. The builder defines local node X as the direction
    % with the greatest spread of triangle centres. The arrow therefore
    % shows the principal direction used to separate the left and right
    % child face sets. Grandchild arrows are omitted to reduce clutter.
    if depth <= 1
        nodeOriginCT = node.T_node_CT(1:3, 4);
        nodeXAxisCT  = node.T_node_CT(1:3, 1);
        nodeDiagonalMm = norm(node.boundsMaxNode - node.boundsMinNode);
        splitAxisLengthMm = 0.18 * nodeDiagonalMm;
        quiver3(treeAxes, ...
            nodeOriginCT(1), nodeOriginCT(2), nodeOriginCT(3), ...
            splitAxisLengthMm * nodeXAxisCT(1), ...
            splitAxisLengthMm * nodeXAxisCT(2), ...
            splitAxisLengthMm * nodeXAxisCT(3), ...
            0, ...
            'Color', depthColors(depth + 1, :), ...
            'LineWidth', 2, ...
            'MaxHeadSize', 0.7, ...
            'HandleVisibility', 'off');
    end
end

title(treeAxes, sprintf('PD-tree Stage 2: depths 0-2 (%d nodes)', numel(displayNodeIndices)));
legend(treeAxes, [treeBoneHandle; depthLegendHandles], 'Location', 'northeastoutside', 'Interpreter', 'none');
rotate3d(treeFigure, 'on');
drawnow;

%% STAGE 3: ONE-TRIANGLE MATCH AND BRUTE-FORCE REFERENCE

% -------------------------------------------------------------------------
% PART 1: VERIFY THE CLOSEST-POINT CALCULATION ON A SIMPLE TRIANGLE
% Check the new triangle-search geometry using examples whose answers are
% known before the real bone mesh is involved. If these small examples fail,
% there is no reason to trust a result obtained from thousands of bone faces.

% Before searching the real bone, use a triangle whose correct answers are
% easy to calculate by hand. The first query projects inside the triangle.
% The second query projects outside the triangle plane, so its closest point
% must lie on the diagonal edge between [4,0,0] and [0,4,0].
simpleTriangle      = [0, 0, 0;
                       4, 0, 0;
                       0, 4, 0];
isotropicCovariance = eye(3);

% Call the closest-point function twice. Each call receives:
%   1. a query position X above the triangle;
%   2. the three triangle vertices; and
%   3. an identity covariance, so Mahalanobis distance is the same as normal
%      Euclidean distance in this introductory test.
%
% The function returns the closest position on the triangle and three
% barycentric weights describing where that position lies. The first call
% should return the point directly below X. The second should return the
% nearest point on the triangle's diagonal boundary.
[insidePoint, insideBarycentric] = findMostLikelyPointOnTriangle([1; 1; 2], simpleTriangle, isotropicCovariance);
[edgePoint, edgeBarycentric]     = findMostLikelyPointOnTriangle([3; 3; 2], simpleTriangle, isotropicCovariance);

% Compare the calculated answers with their hand-computed values. NORM gives
% the size of the difference between two vectors. A result below 1e-12 means
% they agree apart from insignificant floating-point round-off.
insideTestPassed = norm(insidePoint - [1; 1; 0]) < 1e-12 && norm(insideBarycentric - [0.5; 0.25; 0.25]) < 1e-12;
edgeTestPassed   = norm(edgePoint - [2; 2; 0]) < 1e-12   && norm(edgeBarycentric - [0; 0.5; 0.5]) < 1e-12;

% Stop immediately if either basic test fails. Continuing to the bone search
% would otherwise produce a plausible-looking result built on faulty
% closest-point geometry.
if ~insideTestPassed || ~edgeTestPassed
    error('dev_PDTreeSearch:TriangleClosestPointTestFailed', ...
          'The simple one-triangle closest-point checks did not pass.');
end


% -------------------------------------------------------------------------
% PART 2: CREATE ONE KNOWN QUERY ON THE REAL CT BONE
% Build a controlled X for which we already know the correct model match Y.
% This lets us test the complete all-triangle search on the real CT geometry
% without yet introducing uncertainty about the true ultrasound match.

% Reuse the deterministic seed face from Stage 1. Place X exactly at its
% centre and align the measured 2D normal with that face normal. Therefore,
% this face contains a perfect match whose expected error is zero. This
% gives the brute-force search a result that is unambiguous and easy to
% verify before we try more difficult ultrasound measurements.
% These four variables collect the selected face number, its three vertices,
% its centre, and its prepared unit normal, all in the CT frame.
knownFaceIndex          = seedFaceIndex;
knownTriangleVerticesCT = bonePointsCT(boneFaces(knownFaceIndex, :), :);
knownFaceCenterCT       = mean(knownTriangleVerticesCT, 1).';
knownFaceNormalCT       = PsiCT.faceNormals(knownFaceIndex, :).';

% Construct a temporary ultrasound-image orientation for this synthetic
% check. Its image X-axis is deliberately set equal to the known face normal.
% Consequently, projecting the model normal into the image plane produces
% [1;0], which is also the measured 2D normal below.
%
% A 3D rotation needs three mutually perpendicular unit axes. We already
% know the desired X-axis. A helper direction lets CROSS construct a Z-axis
% perpendicular to it. If the default helper is nearly parallel to X, use a
% different helper; crossing parallel directions would produce a zero vector.
% The final cross product constructs Y and completes a right-handed frame.
imageXAxisCT      = knownFaceNormalCT;
helperDirectionCT = [0; 0; 1];
if abs(dot(imageXAxisCT, helperDirectionCT)) > 0.9
    helperDirectionCT = [0; 1; 0];
end
imageZAxisCT     = cross(imageXAxisCT, helperDirectionCT);
imageZAxisCT     = imageZAxisCT / norm(imageZAxisCT);
imageYAxisCT     = cross(imageZAxisCT, imageXAxisCT);
imageYAxisCT     = imageYAxisCT / norm(imageYAxisCT);
R_stage3Image_CT = [imageXAxisCT, imageYAxisCT, imageZAxisCT];

% Define the synthetic projection-oriented measurement X. Its position is
% the known triangle centre in CT, while its normal remains a 2D direction
% in the temporary ultrasound image plane, exactly as required by P-IMLOP.
Xstage3 = struct();
Xstage3.position3D    = knownFaceCenterCT;
Xstage3.normal2DImage = [1; 0];

% A diagonal covariance keeps this first full-mesh test easy to read while
% still exercising the covariance rotation used by the P-IMLOP equations.
% Squaring the standard deviations converts millimetres into variances in
% mm^2. Kappa controls how strongly disagreement between normals is penalized.
positionStandardDeviationImageMm = [1.0; 1.0; 1.5];
positionCovarianceImage          = diag(positionStandardDeviationImageMm .^ 2);
kappaStage3 = 50;


% -------------------------------------------------------------------------
% PART 3: SEARCH EVERY VALID TRIANGLE
% Run the simplest possible complete correspondence search and verify that
% it recovers the answer deliberately created in Part 2. This slow result
% will later serve as the trusted reference for testing the faster PD-tree.

% This is intentionally the slow, obvious reference implementation. It
% evaluates every valid triangle and keeps the smallest complete P-IMLOP
% match error. A future PD-tree search should return the same answer while
% avoiding most of these triangle evaluations.
[Ystage3, E_stage3, stage3SearchDetails] = searchPIMLOPBruteForce( ...
    Xstage3, PsiCT, R_stage3Image_CT, positionCovarianceImage, kappaStage3);

% Read the important outputs into clearly named variables. Valid barycentric
% coordinates must sum to one and must not be negative; those two properties
% guarantee that the returned Y lies on or inside the winning triangle.
% The point difference measures whether Y returned to the known centre.
stage3Barycentric        = stage3SearchDetails.barycentricCoordinates;
stage3PointDifferenceMm  = norm(Ystage3.position3D - knownFaceCenterCT);
stage3BarycentricIsValid = abs(sum(stage3Barycentric) - 1) < 1e-10 && all(stage3Barycentric >= -1e-10);
stage3PerfectMatchFound  = Ystage3.faceIndex == knownFaceIndex && stage3PointDifferenceMm < 1e-9 && E_stage3 < 1e-10;

% Require all three parts of the known answer: the correct face, the correct
% position, and essentially zero match error. The small tolerances allow for
% ordinary floating-point round-off without accepting a meaningful mismatch.
if ~stage3BarycentricIsValid || ~stage3PerfectMatchFound
    error('dev_PDTreeSearch:Stage3VerificationFailed', ...
          'The Stage 3 brute-force search did not recover the known CT match.');
end

% Print the same evidence numerically. The figure in Part 4 is intuitive,
% but this report provides exact values and confirms that every valid face
% was evaluated rather than only the highlighted neighbourhood.
fprintf('\nP-IMLOP Stage 3 triangle and brute-force verification:\n');
fprintf('  Simple projection inside triangle       : PASS\n');
fprintf('  Simple projection onto triangle edge    : PASS\n');
fprintf('  Expected CT face index                  : %d\n', knownFaceIndex);
fprintf('  Returned CT face index                  : %d\n', Ystage3.faceIndex);
fprintf('  Returned barycentric coordinates        : [%.6f, %.6f, %.6f]\n', stage3Barycentric(1), stage3Barycentric(2), stage3Barycentric(3));
fprintf('  Distance from known point               : %.3e mm\n', stage3PointDifferenceMm);
fprintf('  Best nonnegative match error            : %.3e\n', E_stage3);
fprintf('  Valid faces evaluated                   : %d\n', stage3SearchDetails.numberOfFacesEvaluated);
fprintf('  Brute-force search time                 : %.3f s\n', stage3SearchDetails.elapsedSeconds);
fprintf('  Known full-mesh match recovered         : PASS\n');


% -------------------------------------------------------------------------
% PART 4: VISUALLY INSPECT THE WINNING TRIANGLE AND ORIENTED POINTS
% Turn the numerical PASS result into a geometric picture. We want to see
% that Y is on the winning mesh triangle, X and Y coincide for this perfect
% test, and their normals point in the same direction. The covariance
% ellipsoid also shows the positional uncertainty used by E_match.

% Show a close view in CT coordinates. The complete bone is faint, while the
% winning triangle is opaque. The match-error display adds X, Y, the two
% normals, and the positional covariance ellipsoid. For this known perfect
% case, X and Y intentionally overlap and their normals point in the same
% direction. Therefore, the blue Y marker can cover the red X marker, and
% the model-normal arrow can cover the ultrasound-normal arrow. That visual
% overlap is expected evidence of the perfect synthetic match, not a missing
% plotted object.

% Create an equal-scale 3D CT view. Equal axis scaling is important because
% otherwise MATLAB could visually distort the triangle or normal directions.
stage3Figure = figure('Name', 'P-IMLOP Stage 3: Brute-Force Match');
stage3Axes = axes(stage3Figure);
hold(stage3Axes, 'on');
grid(stage3Axes, 'on');
axis(stage3Axes, 'equal');
view(stage3Axes, 35, 35);
xlabel(stage3Axes, 'X_{CT} (mm)');
ylabel(stage3Axes, 'Y_{CT} (mm)');
zlabel(stage3Axes, 'Z_{CT} (mm)');

% Draw the complete bone with very low opacity to provide anatomical context.
% Draw only the winning triangle again with a strong cyan fill and dark edge,
% making the correspondence selected from the full mesh easy to locate.
stage3BoneHandle = patch(stage3Axes, ...
    'Faces', boneFaces, ...
    'Vertices', bonePointsCT, ...
    'FaceColor', [0.82, 0.82, 0.82], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.12, ...
    'DisplayName', 'Complete CT bone mesh');
stage3TriangleHandle = patch(stage3Axes, ...
    'Faces', boneFaces(knownFaceIndex, :), ...
    'Vertices', bonePointsCT, ...
    'FaceColor', [0.10, 0.75, 0.90], ...
    'EdgeColor', [0.00, 0.20, 0.35], ...
    'LineWidth', 2, ...
    'DisplayName', 'Winning triangle');

% Measure the triangle edges and use their largest length to choose a normal
% arrow scale. This keeps the arrows visible relative to the local triangle;
% the scale changes only the drawing, never the stored unit normals or error.
stage3TriangleEdgeLengths = [ ...
    norm(knownTriangleVerticesCT(2, :) - knownTriangleVerticesCT(1, :)); ...
    norm(knownTriangleVerticesCT(3, :) - knownTriangleVerticesCT(2, :)); ...
    norm(knownTriangleVerticesCT(1, :) - knownTriangleVerticesCT(3, :))];
stage3NormalDisplayScale = max(2, 1.5 * max(stage3TriangleEdgeLengths));

% Ask the existing E_match function to add its diagnostic graphics to these
% axes. It draws the covariance ellipsoid, X, Y, their original normals, the
% projected model normal, and the positional/orientation comparison lines.
% Labels are disabled here because they would clutter this small local view.
stage3DisplayOptions = struct();
stage3DisplayOptions.ShowDisplay        = true;
stage3DisplayOptions.Axes               = stage3Axes;
stage3DisplayOptions.NormalDisplayScale = stage3NormalDisplayScale;
stage3DisplayOptions.ShowLabels         = false;
[~, ~, stage3MatchGraphics] = calculatePIMLOPMatchError( ...
    Xstage3, Ystage3, R_stage3Image_CT, ...
    positionCovarianceImage, kappaStage3, stage3DisplayOptions);

% Crop the view around the winning triangle with enough padding to include
% the uncertainty ellipsoid and normal arrows. The full bone remains present,
% but only the nearby surface is useful for judging this correspondence.
stage3PatchMinimumCT = min(knownTriangleVerticesCT, [], 1);
stage3PatchMaximumCT = max(knownTriangleVerticesCT, [], 1);
stage3ViewPaddingMm  = max(4, 3 * max(stage3TriangleEdgeLengths));
xlim(stage3Axes, [stage3PatchMinimumCT(1), stage3PatchMaximumCT(1)] + [-1, 1] * stage3ViewPaddingMm);
ylim(stage3Axes, [stage3PatchMinimumCT(2), stage3PatchMaximumCT(2)] + [-1, 1] * stage3ViewPaddingMm);
zlim(stage3Axes, [stage3PatchMinimumCT(3), stage3PatchMaximumCT(3)] + [-1, 1] * stage3ViewPaddingMm);

% Put the selected face and error in the title. Use only the most important
% graphics in the legend so it explains the verification without becoming
% overcrowded. ROTATE3D lets the developer inspect overlap from other views.
title(stage3Axes, sprintf('Stage 3 match: face %d, E_{match} = %.2e', Ystage3.faceIndex, E_stage3));
legend(stage3Axes, [ ...
    stage3BoneHandle; ...
    stage3TriangleHandle; ...
    stage3MatchGraphics.xPoint; ...
    stage3MatchGraphics.yPoint; ...
    stage3MatchGraphics.xNormal; ...
    stage3MatchGraphics.yNormal], ...
    'Location', 'northeastoutside', 'Interpreter', 'tex');
rotate3d(stage3Figure, 'on');
drawnow;


%% STAGE 4: EXHAUSTIVE PD-TREE TRAVERSAL WITHOUT PRUNING

% -------------------------------------------------------------------------
% PART 1: SEARCH THE SAME MODEL THROUGH THE PD-TREE
%
% Stage 3 found the trusted answer by looping directly over every valid bone
% triangle. Stage 4 must find that same answer by following the tree from its
% root to every leaf. No node is discarded yet. This deliberate repetition
% separates two questions that would otherwise be difficult to debug:
%   1. Does tree traversal visit every triangle exactly once?
%   2. Later, does the Stage 5 pruning rule discard only safe nodes?
%
% For this stage we answer only the first question.
stage4SearchOptions = struct();
stage4SearchOptions.UsePruning = false;

[Ystage4, E_stage4, stage4SearchDetails] = searchPDTree( ...
    Xstage3, PsiCT, R_stage3Image_CT, ...
    positionCovarianceImage, kappaStage3, stage4SearchOptions);


% -------------------------------------------------------------------------
% PART 2: COMPARE THE TREE RESULT WITH THE STAGE 3 REFERENCE
%
% Both searches evaluated the same Equation (7) candidates. Their best face,
% point, normal, and error must therefore agree. The known synthetic query has
% one intended perfect face, so an equal face index is expected here as well.
stage4ErrorDifference     = abs(E_stage4 - E_stage3);
stage4PositionDifference  = norm(Ystage4.position3D - Ystage3.position3D);
stage4NormalDifference    = norm(Ystage4.normal3D - Ystage3.normal3D);
stage4SameWinningFace     = Ystage4.faceIndex == Ystage3.faceIndex;

% Exhaustive traversal should visit every stored node and leaf. It should
% evaluate only leaf datums, and Stage 2 already proved that those leaf lists
% contain every valid face exactly once. No node may be reported as pruned.
stage4VisitedEveryNode   = stage4SearchDetails.numberOfNodesVisited == PsiCT.pdTree.numberOfNodes;
stage4VisitedEveryLeaf   = stage4SearchDetails.numberOfLeavesVisited == PsiCT.pdTree.numberOfLeaves;
stage4EvaluatedEveryFace = stage4SearchDetails.numberOfFacesEvaluated == PsiCT.pdTree.numberOfDatums;
stage4UsedNoPruning      = stage4SearchDetails.numberOfNodesPruned == 0;

stage4NumericalMatch = ...
    stage4ErrorDifference < 1e-10 && ...
    stage4PositionDifference < 1e-9 && ...
    stage4NormalDifference < 1e-12 && ...
    stage4SameWinningFace;

if (~stage4NumericalMatch || ~stage4VisitedEveryNode || ...
   ~stage4VisitedEveryLeaf || ~stage4EvaluatedEveryFace || ...
   ~stage4UsedNoPruning)
    error('dev_PDTreeSearch:Stage4VerificationFailed', ...
          'The exhaustive PD-tree search did not match the Stage 3 reference.');
end

% Stage 3 already draws the winning correspondence. Since Stage 4 must return
% that exact same Y, a second identical figure would not add new information.
% This report instead focuses on the new evidence: complete traversal counts
% and numerical equality with the brute-force reference.
fprintf('\nP-IMLOP Stage 4 exhaustive PD-tree traversal verification:\n');
fprintf('  Brute-force face index                 : %d\n',      Ystage3.faceIndex);
fprintf('  PD-tree face index                     : %d\n',      Ystage4.faceIndex);
fprintf('  Brute-force E_match                    : %.12e\n',   E_stage3);
fprintf('  PD-tree E_match                        : %.12e\n',   E_stage4);
fprintf('  Absolute E_match difference            : %.3e\n',    stage4ErrorDifference);
fprintf('  Returned position difference           : %.3e mm\n', stage4PositionDifference);
fprintf('  Returned normal difference             : %.3e\n',    stage4NormalDifference);
fprintf('  Tree nodes visited                     : %d / %d\n', stage4SearchDetails.numberOfNodesVisited, PsiCT.pdTree.numberOfNodes);
fprintf('  Tree leaves visited                    : %d / %d\n', stage4SearchDetails.numberOfLeavesVisited, PsiCT.pdTree.numberOfLeaves);
fprintf('  Valid faces evaluated                  : %d / %d\n', stage4SearchDetails.numberOfFacesEvaluated, PsiCT.pdTree.numberOfDatums);
fprintf('  Nodes pruned                           : %d\n',      stage4SearchDetails.numberOfNodesPruned);
fprintf('  Exhaustive tree-search time            : %.3f s\n',  stage4SearchDetails.elapsedSeconds);
fprintf('  Tree result equals brute-force result  : PASS\n');


%% STAGE 5: PRUNE NODES WITH THE PAPER'S POSITIONAL ELLIPSOID

% -------------------------------------------------------------------------
% PART 1: CHECK THE ELLIPSOID-BOX TEST WITH THREE OBVIOUS EXAMPLES
%
% Before allowing a node test to skip thousands of bone triangles, verify it
% on one simple axis-aligned box. The box extends from -1 to +1 along every
% axis and uses identity covariance, so Mahalanobis distance is ordinary
% Euclidean distance and the expected answers are easy to understand.
stage5TestNode = struct();
stage5TestNode.T_node_CT     = eye(4);
stage5TestNode.boundsMinNode = [-1, -1, -1];
stage5TestNode.boundsMaxNode = [ 1,  1,  1];

stage5TestPrecision3D = eye(3);

% A point inside the box has zero distance to it. With zero allowed error,
% the degenerate ellipsoid is just that point and still intersects the box.
[stage5InsideIntersects, stage5InsideDistanceSquared] = ...
    ellipsoidIntersectsOBB([0; 0; 0], stage5TestPrecision3D, 0, stage5TestNode);

% A query at x=4 is three units from the nearest box face. Its squared
% distance is nine, which is outside an ellipsoid whose Equation (8) limit is
% 2*Ebest = 2. This node must therefore be rejected.
[stage5OutsideIntersects, stage5OutsideDistanceSquared] = ...
    ellipsoidIntersectsOBB([4; 0; 0], stage5TestPrecision3D, 1, stage5TestNode);

% This last query is exactly sqrt(2) units beyond the x=1 box face. Its
% squared distance is two, exactly equal to 2*Ebest. Touching the boundary is
% an intersection, so the node must remain searchable.
[stage5TangentIntersects, stage5TangentDistanceSquared] = ...
    ellipsoidIntersectsOBB([1 + sqrt(2); 0; 0], stage5TestPrecision3D, 1, stage5TestNode);

stage5SimpleIntersectionTestsPassed = ...
    stage5InsideIntersects && ...
    ~stage5OutsideIntersects && ...
    stage5TangentIntersects && ...
    abs(stage5InsideDistanceSquared) < 1e-12 && ...
    abs(stage5OutsideDistanceSquared - 9) < 1e-12 && ...
    abs(stage5TangentDistanceSquared - 2) < 1e-10;

if ~stage5SimpleIntersectionTestsPassed
    error('dev_PDTreeSearch:Stage5IntersectionTestFailed', ...
          'The simple Stage 5 ellipsoid-versus-box checks did not pass.');
end


% -------------------------------------------------------------------------
% PART 2: SEARCH THE REAL PD-TREE WITH PRUNING ENABLED
%
% Use exactly the same X, image orientation, covariance, and kappa as Stages
% 3 and 4. The only new behavior is UsePruning=true. This makes the comparison
% fair: a correct pruning rule must reduce the amount of work without changing
% the best oriented model point or its Equation (7) error.
stage5SearchOptions = struct();
stage5SearchOptions.UsePruning = true;

[Ystage5, E_stage5, stage5SearchDetails] = searchPDTree( ...
    Xstage3, PsiCT, R_stage3Image_CT, ...
    positionCovarianceImage, kappaStage3, stage5SearchOptions);


% -------------------------------------------------------------------------
% PART 3: PROVE THAT PRUNING PRESERVED THE STAGE 4 ANSWER
%
% Stage 4 visited every valid triangle and is therefore the trusted tree
% reference. Stage 5 may visit far fewer nodes and faces, but it must return
% the same winning face, position, normal, and match error.
stage5ErrorDifference    = abs(E_stage5 - E_stage4);
stage5PositionDifference = norm(Ystage5.position3D - Ystage4.position3D);
stage5NormalDifference   = norm(Ystage5.normal3D - Ystage4.normal3D);
stage5SameWinningFace    = Ystage5.faceIndex == Ystage4.faceIndex;

stage5NumericalMatch = ...
    stage5ErrorDifference < 1e-10 && ...
    stage5PositionDifference < 1e-9 && ...
    stage5NormalDifference < 1e-12 && ...
    stage5SameWinningFace;

% The controlled query has a perfect zero-error match. Once that match is
% found, boxes that do not contain X can be discarded immediately. Require
% at least one rejected node and fewer triangle evaluations so this stage
% demonstrates actual pruning rather than only activating an unused option.
stage5ReducedTreeWork = ...
    stage5SearchDetails.numberOfNodesPruned > 0 && ...
    stage5SearchDetails.numberOfFacesEvaluated ...
    < stage4SearchDetails.numberOfFacesEvaluated;

if ~stage5NumericalMatch || ~stage5ReducedTreeWork
    error('dev_PDTreeSearch:Stage5VerificationFailed', ...
          'The pruned PD-tree search changed the result or did not reduce the search work.');
end

% The Stage 3 figure already shows the correspondence that all three searches
% must return. A duplicate figure would add no new geometric information, so
% Stage 5 ends with a numerical report focused on correctness and saved work.
fprintf('\nP-IMLOP Stage 5 pruned PD-tree search verification:\n');
fprintf('  Point-inside-box test                  : PASS (distance^2 = %.3f)\n', stage5InsideDistanceSquared);
fprintf('  Point-outside-ellipsoid test           : PASS (distance^2 = %.3f)\n', stage5OutsideDistanceSquared);
fprintf('  Tangent-ellipsoid test                 : PASS (distance^2 = %.3f)\n', stage5TangentDistanceSquared);
fprintf('  Exhaustive face index                  : %d\n',      Ystage4.faceIndex);
fprintf('  Pruned-search face index               : %d\n',      Ystage5.faceIndex);
fprintf('  Exhaustive E_match                     : %.12e\n',   E_stage4);
fprintf('  Pruned-search E_match                  : %.12e\n',   E_stage5);
fprintf('  Absolute E_match difference            : %.3e\n',    stage5ErrorDifference);
fprintf('  Returned position difference           : %.3e mm\n', stage5PositionDifference);
fprintf('  Returned normal difference             : %.3e\n',    stage5NormalDifference);
fprintf('  Node intersection tests                : %d\n',      stage5SearchDetails.numberOfNodeIntersectionTests);
fprintf('  Tree nodes visited                     : %d / %d\n', stage5SearchDetails.numberOfNodesVisited, PsiCT.pdTree.numberOfNodes);
fprintf('  Nodes pruned                           : %d\n',      stage5SearchDetails.numberOfNodesPruned);
fprintf('  Valid faces evaluated                  : %d / %d\n', stage5SearchDetails.numberOfFacesEvaluated, PsiCT.pdTree.numberOfDatums);
fprintf('  Exhaustive tree-search time            : %.3f s\n',  stage4SearchDetails.elapsedSeconds);
fprintf('  Pruned tree-search time                : %.3f s\n',  stage5SearchDetails.elapsedSeconds);
fprintf('  Pruned result equals exhaustive result : PASS\n');
fprintf('  Pruning reduced triangle evaluations   : PASS\n');


%% STAGE 6: REAL ULTRASOUND-TO-CT CORRESPONDENCE

% -------------------------------------------------------------------------
% PART 1: EXPRESS THE REAL ULTRASOUND QUERY IN THE CT SEARCH FRAME
%
% The PD-tree and every model triangle remain fixed in CT coordinates. The
% measured ultrasound point, however, was originally stored in ref. For the
% current candidate bone pose, transform this one query from ref into CT.
% This is the efficient "move the query" approach discussed during design:
% the optimizer still describes the bone pose with T_CT_ref_candidate, but
% the correspondence calculation can reuse the same CT-frame PD-tree.
T_CT_ref_candidate = data.T_CT_ref_initial;

% Invert the rigid transform directly. For a rigid rotation R and
% translation t, the inverse is [R', -R'*t]. Writing that relationship here
% makes the direction change explicit and avoids a general matrix inverse.
R_CT_ref_candidate = T_CT_ref_candidate(1:3, 1:3);
t_CT_ref_candidate = T_CT_ref_candidate(1:3, 4);
T_ref_CT_candidate = eye(4);
T_ref_CT_candidate(1:3, 1:3) = R_CT_ref_candidate.';
T_ref_CT_candidate(1:3, 4)   = -R_CT_ref_candidate.' * t_CT_ref_candidate;

% Compose the image-to-CT transform in the same order used throughout the
% project:
%       p_CT = T_ref_CT_candidate * T_image_ref * p_image.
% Its rotation block is R_p for the P-IMLOP equations when X and Y are both
% evaluated in CT coordinates.
T_image_CT = T_ref_CT_candidate * selectedPlane.T_image_ref;
R_image_CT = T_image_CT(1:3, 1:3);

% XqueryCT keeps the two parts of the ultrasound measurement in the frames
% where they naturally belong. The 3D position is transformed into CT, while
% the measured 2D normal remains in the local ultrasound image X-Y plane.
% R_image_CT later connects that 2D normal and its covariance to CT.
XqueryCT = struct();
XqueryCT.position3D    = applyRigidTransform(X.position3DRef.', T_ref_CT_candidate).';
XqueryCT.normal2DImage = X.normal2DImage;

% Reuse the simple ultrasound noise model used in the earlier development
% stages. The covariance stays in image X-Y-Z coordinates; searchPDTree and
% calculatePIMLOPMatchError rotate it into CT with R_image_CT.
stage6PositionStandardDeviationImageMm = [1.0; 1.0; 1.5];
stage6PositionCovarianceImage = diag(stage6PositionStandardDeviationImageMm .^ 2);
stage6Kappa = 50;


% -------------------------------------------------------------------------
% PART 2: SEARCH THE FIXED CT PD-TREE
%
% Enable the Stage 5 pruning rule for the real measurement. The returned
% YmatchCT is one oriented model point: its position may lie anywhere on the
% winning triangle and its normal is that triangle's prepared face normal.
stage6SearchOptions = struct();
stage6SearchOptions.UsePruning = true;

[YmatchCT, E_stage6, stage6SearchDetails] = searchPDTree( ...
    XqueryCT, PsiCT, R_image_CT, ...
    stage6PositionCovarianceImage, stage6Kappa, stage6SearchOptions);

% Evaluate the returned pair once more with the standalone E_match function.
% This is a direct consistency check between the search result and the
% already verified Equation (7) implementation.
[E_stage6Recalculated, stage6MatchDetails] = calculatePIMLOPMatchError( ...
    XqueryCT, YmatchCT, R_image_CT, ...
    stage6PositionCovarianceImage, stage6Kappa);


% -------------------------------------------------------------------------
% PART 3: VERIFY THE RETURNED MODEL POINT AND COORDINATE TRANSFORM
%
% The barycentric coordinates describe Y inside the winning triangle. They
% must sum to one and remain nonnegative. Reconstructing Y from those weights
% gives an intuitive check that the returned point really lies on that face.
stage6Barycentric                = stage6SearchDetails.barycentricCoordinates;
stage6WinningFaceIndex           = YmatchCT.faceIndex;
stage6WinningTriangleVerticesCT  = bonePointsCT(boneFaces(stage6WinningFaceIndex, :), :);
stage6ReconstructedYCT           = stage6WinningTriangleVerticesCT.' * stage6Barycentric;

stage6BarycentricIsValid         = abs(sum(stage6Barycentric) - 1) < 1e-10 && all(stage6Barycentric >= -1e-10);
stage6PointLiesOnWinningTriangle = norm(stage6ReconstructedYCT - YmatchCT.position3D) < 1e-9;
stage6NormalMatchesWinningFace   = norm(YmatchCT.normal3D - PsiCT.faceNormals(stage6WinningFaceIndex, :).') < 1e-12;
stage6ErrorIsConsistent          = abs(E_stage6Recalculated - E_stage6) < 1e-10;

% Transform the CT query back into ref. Recovering the original measurement
% confirms that the query was moved in the correct direction before search.
stage6QueryRoundTripRef         = applyRigidTransform(XqueryCT.position3D.', T_CT_ref_candidate).';
stage6QueryRoundTripErrorMm     = norm(stage6QueryRoundTripRef - X.position3DRef);
stage6TransformRoundTripIsValid = stage6QueryRoundTripErrorMm < 1e-9;

if ~stage6BarycentricIsValid || ...
        ~stage6PointLiesOnWinningTriangle || ...
        ~stage6NormalMatchesWinningFace || ...
        ~stage6ErrorIsConsistent || ...
        ~stage6TransformRoundTripIsValid
    error('dev_PDTreeSearch:Stage6VerificationFailed', ...
          'The real CT-frame correspondence did not pass Stage 6 verification.');
end

% Also express the selected model point in ref for a readable report. This
% does not move or rebuild the PD-tree; it is only the forward transform of
% the one correspondence returned by the CT search.
YmatchRefPosition = applyRigidTransform( ...
    YmatchCT.position3D.', T_CT_ref_candidate).';

fprintf('\nP-IMLOP Stage 6 real ultrasound correspondence verification:\n');
fprintf('  Ultrasound X in ref                    : [%.6f, %.6f, %.6f] mm\n', X.position3DRef);
fprintf('  Query X transformed into CT            : [%.6f, %.6f, %.6f] mm\n', XqueryCT.position3D);
fprintf('  Winning CT face index                  : %d\n',                    stage6WinningFaceIndex);
fprintf('  Matched Y in CT                        : [%.6f, %.6f, %.6f] mm\n', YmatchCT.position3D);
fprintf('  Matched Y transformed into ref         : [%.6f, %.6f, %.6f] mm\n', YmatchRefPosition);
fprintf('  Barycentric coordinates                : [%.6f, %.6f, %.6f]\n',    stage6Barycentric);
fprintf('  Euclidean X-to-Y distance              : %.6f mm\n',               stage6MatchDetails.euclideanDistanceMm);
fprintf('  Projected-normal angle                 : %.6f deg\n',              stage6MatchDetails.orientationAngleDeg);
fprintf('  Position error                         : %.6f\n',                  stage6MatchDetails.E_position);
fprintf('  Orientation mismatch                   : %.6f\n',                  stage6MatchDetails.E_orientationMismatch);
fprintf('  Total nonnegative E_match              : %.6f\n',                  E_stage6);
fprintf('  Query transform round-trip error       : %.3e mm\n',               stage6QueryRoundTripErrorMm);
fprintf('  Tree nodes visited                     : %d / %d\n',               stage6SearchDetails.numberOfNodesVisited, PsiCT.pdTree.numberOfNodes);
fprintf('  Nodes pruned                           : %d\n',                    stage6SearchDetails.numberOfNodesPruned);
fprintf('  Valid faces evaluated                  : %d / %d\n',               stage6SearchDetails.numberOfFacesEvaluated, PsiCT.pdTree.numberOfDatums);
fprintf('  Pruned tree-search time                : %.3f s\n',                stage6SearchDetails.elapsedSeconds);
fprintf('  Returned Y lies on winning triangle    : PASS\n');
fprintf('  Search and E_match values agree        : PASS\n');
fprintf('  Ref-to-CT query transform is consistent: PASS\n');


% -------------------------------------------------------------------------
% PART 4: VISUALLY INSPECT THE REAL CORRESPONDENCE IN CT
%
% This final figure shows every important object in the actual search frame:
% the fixed CT bone and PD-tree model, the tracked ultrasound image plane
% transformed into CT, the real query X, and the model point Y selected by
% searchPDTree. A highlighted face makes Y's source triangle unambiguous.
stage6Figure = figure('Name', 'P-IMLOP Stage 6: Real Correspondence in CT');
stage6Axes = axes(stage6Figure);
hold(stage6Axes, 'on');
grid(stage6Axes, 'on');
axis(stage6Axes, 'equal');
view(stage6Axes, 35, 35);
xlabel(stage6Axes, 'X_{CT} (mm)');
ylabel(stage6Axes, 'Y_{CT} (mm)');
zlabel(stage6Axes, 'Z_{CT} (mm)');

% Draw the complete bone lightly so the winning face remains visible while
% the viewer can still recognize where the correspondence lies anatomically.
stage6BoneHandle = patch(stage6Axes, ...
    'Faces', boneFaces, ...
    'Vertices', bonePointsCT, ...
    'FaceColor', [0.82, 0.82, 0.82], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.14, ...
    'DisplayName', 'Complete CT bone mesh');

% Draw the same ultrasound image used to select X, but use T_image_CT rather
% than T_image_ref. The image, query, matched point, and model are therefore
% displayed in one common coordinate system.
stage6ImageHandle = display_image3D(stage6Axes, ...
    selectedPlane.image, ...
    T_image_CT, ...
    'SwapXY', true, ...
    'PixelSpacing', pixelSpacingXYMm, ...
    'Tag', 'dev_pdtree_stage6_image_plane', ...
    'Colormap', 'gray', ...
    'FaceAlpha', 0.35);
stage6ImageHandle.DisplayName = sprintf('Ultrasound plane %d in CT', planeIndex);

% Highlight only the triangle that supplied YmatchCT. The stronger colour
% and visible border separate it from the transparent surrounding surface.
stage6TriangleHandle = patch(stage6Axes, ...
    'Faces', boneFaces(stage6WinningFaceIndex, :), ...
    'Vertices', bonePointsCT, ...
    'FaceColor', [0.10, 0.75, 0.90], ...
    'EdgeColor', [0.00, 0.20, 0.35], ...
    'LineWidth', 2, ...
    'DisplayName', 'Winning CT triangle');

% Let the existing E_match display draw the covariance ellipsoid, X and Y,
% both original normals, the projected model normal, and the position line.
% These are the same quantities used numerically during search, not separate
% display approximations. Labels are disabled to keep the real scene legible.
stage6DisplayOptions = struct();
stage6DisplayOptions.ShowDisplay        = true;
stage6DisplayOptions.Axes               = stage6Axes;
stage6DisplayOptions.NormalDisplayScale = normalDisplayScale;
stage6DisplayOptions.ShowLabels         = false;

[~, ~, stage6MatchGraphics] = calculatePIMLOPMatchError( ...
    XqueryCT, YmatchCT, R_image_CT, ...
    stage6PositionCovarianceImage, stage6Kappa, stage6DisplayOptions);

% Focus the final view on the query and its selected triangle. The full bone
% remains plotted for context, while this local crop makes a millimetre-scale
% residual and the normal directions large enough to judge by eye.
stage6FocusPointsCT = [ ...
    stage6WinningTriangleVerticesCT; ...
    XqueryCT.position3D.'; ...
    YmatchCT.position3D.'];
stage6ViewMinimumCT = min(stage6FocusPointsCT, [], 1);
stage6ViewMaximumCT = max(stage6FocusPointsCT, [], 1);
stage6ViewPaddingMm = max(5, 1.5 * normalDisplayScale);
xlim(stage6Axes, [stage6ViewMinimumCT(1), stage6ViewMaximumCT(1)] + [-1, 1] * stage6ViewPaddingMm);
ylim(stage6Axes, [stage6ViewMinimumCT(2), stage6ViewMaximumCT(2)] + [-1, 1] * stage6ViewPaddingMm);
zlim(stage6Axes, [stage6ViewMinimumCT(3), stage6ViewMaximumCT(3)] + [-1, 1] * stage6ViewPaddingMm);

title(stage6Axes, sprintf( ...
    'Stage 6 real correspondence: face %d, E_{match} = %.3f', ...
    stage6WinningFaceIndex, E_stage6), ...
    'Interpreter', 'tex');
legend(stage6Axes, [ ...
    stage6BoneHandle; ...
    stage6ImageHandle; ...
    stage6TriangleHandle; ...
    stage6MatchGraphics.xPoint; ...
    stage6MatchGraphics.yPoint; ...
    stage6MatchGraphics.xNormal; ...
    stage6MatchGraphics.yNormal; ...
    stage6MatchGraphics.positionResidual; ...
    stage6MatchGraphics.projectedYNormal], ...
    'Location', 'northeastoutside', ...
    'Interpreter', 'tex');
rotate3d(stage6Figure, 'on');
drawnow;
