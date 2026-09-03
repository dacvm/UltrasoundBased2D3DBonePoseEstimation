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
everyFaceAppearsOnce = numel(sortedLeafFaces) == numel(sortedValidFaces) && ...
    isequal(sortedLeafFaces, sortedValidFaces) && ...
    numel(unique(sortedLeafFaces)) == numel(sortedLeafFaces);

% The following flags start as true. While visiting every node, a flag stays
% true only if every node examined so far satisfies that property. This
% gives one compact final result for each important tree promise:
%   - every node has a valid local coordinate frame;
%   - every node bounding box encloses its complete triangles;
%   - every internal node divides its faces correctly between two children.
allNodeFramesRigid      = true;
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

if ~everyFaceAppearsOnce || ~childrenPartitionParents || ~allNodeBoundsContainFaces || ~allNodeFramesRigid
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

%%