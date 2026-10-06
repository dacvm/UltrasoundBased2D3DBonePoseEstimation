function pdTree = buildPIMLOPPDTree(boneMeshCT, validFaceMask, options)
%BUILDPIMLOPPDTREE Build a position-based PD-tree around CT mesh triangles.
%   P-IMLOP treats every valid mesh triangle as one model datum. This
%   function groups those datums into a binary tree. Every node receives its
%   own principal-direction coordinate frame and an oriented bounding box
%   that contains the complete triangles assigned to that node.
%
%   The construction follows the same repeated idea at every level:
%       1. find the main spatial directions of this group of triangles;
%       2. place a tight oriented box around the complete triangles;
%       3. stop if the group is already small enough;
%       4. otherwise divide it along its main direction and repeat for both
%          smaller groups.
%
%   The resulting hierarchy is prepared once in CT coordinates. A later
%   correspondence search can reject large regions of the mesh by testing a
%   node box before inspecting the individual triangles inside its leaves.
%
%   Inputs
%   ------
%   boneMeshCT : MATLAB triangulation whose points are expressed in CT
%       coordinates and whose point units are millimetres.
%   validFaceMask : M-by-1 logical array. A true entry means that the face at
%       the same row of boneMeshCT.ConnectivityList may enter the tree.
%   options : Optional scalar structure with these fields:
%       faceCountThreshold     - stop when a node has at most this many
%                                faces; default is 15;
%       minimumNodeDiagonalMm  - stop when the node OBB diagonal is at most
%                                this size; default is 15 mm.
%
%   Output
%   ------
%   pdTree : Structure containing the complete PD-tree. Important fields are:
%       nodes            - flat structure array containing every tree node;
%       rootNodeIndex    - index of the root inside nodes;
%       faceCentersCT    - representative triangle points used for PCA and
%                          splitting; these are not final P-IMLOP matches;
%       options          - stopping settings used to build the tree;
%       numberOfDatums   - number of valid triangles in the tree;
%       numberOfNodes    - total number of nodes;
%       numberOfLeaves   - number of leaf nodes;
%       maximumDepth     - root-to-leaf depth, with the root at depth zero.
%
%   Each element of pdTree.nodes contains:
%       datumFaceIndices - original mesh face indices assigned to the node;
%       T_node_CT        - 4-by-4 transform from node-local coordinates to CT;
%       boundsMinNode    - lower OBB corner in node-local coordinates;
%       boundsMaxNode    - upper OBB corner in node-local coordinates;
%       parentNodeIndex, leftNodeIndex, rightNodeIndex, depth, and isLeaf.
%
%   Example
%   -------
%       options.faceCountThreshold = 15;
%       options.minimumNodeDiagonalMm = 15;
%       pdTree = buildPIMLOPPDTree( ...
%           PsiCT.mesh, PsiCT.validFaceMask, options);

% Supply readable defaults when the caller does not need to experiment with
% tree size. A smaller threshold generally creates more nodes and smaller
% leaves; a larger threshold creates fewer nodes but leaves more triangles
% for a future correspondence search to inspect individually.
if nargin < 3 || isempty(options)
    options = struct();
end
if ~isfield(options, 'faceCountThreshold')
    options.faceCountThreshold = 15;
end
if ~isfield(options, 'minimumNodeDiagonalMm')
    options.minimumNodeDiagonalMm = 15;
end

% These are the two values a future experiment is most likely to tune. Keep
% their validation short and close to the defaults so their meaning remains
% obvious to a new developer.
validateattributes(options.faceCountThreshold, {'numeric'}, ...
    {'scalar', 'integer', 'positive'}, mfilename, 'options.faceCountThreshold');
validateattributes(options.minimumNodeDiagonalMm, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'nonnegative'}, mfilename, 'options.minimumNodeDiagonalMm');

bonePointsCT = double(boneMeshCT.Points);
boneFaces    = boneMeshCT.ConnectivityList;
validFaceIndices = find(validFaceMask);

% Represent each triangle by its centre while organizing the tree. One point
% per triangle gives PCA and the left/right split a simple, consistent input.
% This centre is only an organizational representative: it is not the final
% P-IMLOP correspondence point. Later matching may return any point on the
% selected triangle.
%
% There is also an important distinction below: triangle centres determine
% the node orientation and split, but all triangle vertices determine the
% bounding box. Using only centres for the box could leave triangle corners
% outside it, which would make later pruning unsafe.
faceVertex1CT = bonePointsCT(boneFaces(:, 1), :);
faceVertex2CT = bonePointsCT(boneFaces(:, 2), :);
faceVertex3CT = bonePointsCT(boneFaces(:, 3), :);
faceCentersCT = (faceVertex1CT + faceVertex2CT + faceVertex3CT) / 3;

% Store every node in one flat structure array. The parent and child fields
% contain integer positions in this array. This represents the same binary
% hierarchy as nested structures, but it is easier to inspect in MATLAB and
% lets a future search keep a simple stack of node indices.
emptyNode = struct( ...
    'datumFaceIndices', zeros(0, 1), ...
    'T_node_CT', eye(4), ...
    'boundsMinNode', zeros(1, 3), ...
    'boundsMaxNode', zeros(1, 3), ...
    'parentNodeIndex', 0, ...
    'leftNodeIndex', 0, ...
    'rightNodeIndex', 0, ...
    'depth', 0, ...
    'isLeaf', true);
nodes = repmat(emptyNode, 0, 1);

% Begin with one root containing every valid triangle. buildNode appends that
% node to the shared array. If it is too large, buildNode calls itself for
% the two smaller face groups; this recursion continues until every branch
% reaches a stopping condition.
rootNodeIndex = buildNode(validFaceIndices, 0, 0);

leafMask = [nodes.isLeaf];
pdTree = struct();
pdTree.nodes          = nodes;
pdTree.rootNodeIndex  = rootNodeIndex;
pdTree.faceCentersCT  = faceCentersCT;
pdTree.options        = options;
pdTree.numberOfDatums = numel(validFaceIndices);
pdTree.numberOfNodes  = numel(nodes);
pdTree.numberOfLeaves = nnz(leafMask);
pdTree.maximumDepth   = max([nodes.depth]);

    function nodeIndex = buildNode(datumFaceIndices, parentNodeIndex, depth)
    %BUILDNODE Create one node and recursively create its children.
    %   datumFaceIndices contains original mesh face indices assigned to this
    %   node. parentNodeIndex is zero only for the root, and depth is zero at
    %   the root. The returned nodeIndex points into the shared nodes array.

        % STEP 1: Find the centre and principal directions of this face group.
        %
        % Each triangle contributes its representative centre. Their mean is
        % used as the node origin. Subtracting the mean describes how the
        % centres spread around that origin. The covariance-like matrix then
        % summarizes the directions of that spread.
        nodeCentersCT = faceCentersCT(datumFaceIndices, :);
        nodeOriginCT  = mean(nodeCentersCT, 1);
        centeredNodeCentersCT = nodeCentersCT - nodeOriginCT;
        centerCovariance = centeredNodeCentersCT.' * centeredNodeCentersCT;
        centerCovariance = 0.5 * (centerCovariance + centerCovariance.');

        % The covariance eigenvectors give three perpendicular directions.
        % Sort them by decreasing eigenvalue so local X follows the greatest
        % spread, local Y the next greatest, and local Z the smallest. The
        % local X direction will later become the splitting direction.
        [nodeAxesCT, centerVariances] = eig(centerCovariance, 'vector');
        [~, varianceOrder] = sort(centerVariances, 'descend');
        nodeAxesCT = nodeAxesCT(:, varianceOrder);

        % Eigenvectors have arbitrary signs: an axis and its negative describe
        % the same variance direction. Occasionally the three returned axes
        % form a reflected, left-handed frame. Flipping the last axis makes
        % the matrix a proper right-handed rotation without changing its fit.
        if det(nodeAxesCT) < 0
            nodeAxesCT(:, 3) = -nodeAxesCT(:, 3);
        end

        % Package the node axes and origin as a rigid transform. Its columns
        % describe the node axes in CT, so it maps node-local points into CT:
        %       p_CT = T_node_CT * p_node.
        T_node_CT = eye(4);
        T_node_CT(1:3, 1:3) = nodeAxesCT;
        T_node_CT(1:3, 4)   = nodeOriginCT.';

        % STEP 2: Build an oriented bounding box around the complete faces.
        %
        % Gather all mesh vertices touched by this node's triangles. Convert
        % them from CT into the newly created node frame by subtracting the
        % origin and applying the inverse rotation. In that local frame, the
        % principal axes align with x, y, and z, so ordinary coordinate-wise
        % minima and maxima define the oriented box.
        nodeVertexIndices = unique(boneFaces(datumFaceIndices, :));
        nodePointsCT      = bonePointsCT(nodeVertexIndices, :);
        nodePointsNode    = (nodeAxesCT.' * (nodePointsCT - nodeOriginCT).').';
        boundsMinNode     = min(nodePointsNode, [], 1);
        boundsMaxNode     = max(nodePointsNode, [], 1);
        % The diagonal summarizes the physical size of this box. It provides
        % a simple scale-based stopping rule independent of box orientation.
        nodeDiagonalMm    = norm(boundsMaxNode - boundsMinNode);

        % STEP 3: Append the completed node to the shared flat node array.
        % Store the original mesh face indices so later stages can recover
        % each triangle's vertices and normal directly from PsiCT.
        nodeIndex = numel(nodes) + 1;
        nodes(nodeIndex) = emptyNode;
        nodes(nodeIndex).datumFaceIndices = datumFaceIndices(:);
        nodes(nodeIndex).T_node_CT         = T_node_CT;
        nodes(nodeIndex).boundsMinNode     = boundsMinNode;
        nodes(nodeIndex).boundsMaxNode     = boundsMaxNode;
        nodes(nodeIndex).parentNodeIndex   = parentNodeIndex;
        nodes(nodeIndex).depth             = depth;

        % STEP 4: Decide whether this branch should stop growing.
        %
        % The node is small enough when it contains few faces OR occupies a
        % sufficiently small spatial region. It remains a leaf in either
        % case. Notice that a size-limited leaf may contain more faces than
        % faceCountThreshold; this is expected because the rules use OR.
        reachedFaceLimit = numel(datumFaceIndices) <= options.faceCountThreshold;
        reachedSizeLimit = nodeDiagonalMm <= options.minimumNodeDiagonalMm;
        if reachedFaceLimit || reachedSizeLimit
            return;
        end

        % STEP 5: Split a node that is still too large.
        %
        % Express its representative triangle centres in node coordinates.
        % The node origin is their mean, so local x = 0 is a plane through
        % the middle of the group. Local X is the greatest-spread direction;
        % therefore this plane divides the long direction of the group, as
        % prescribed by the principal-direction PD-tree construction.
        % Centres on the plane go left; centres beyond it go right.
        nodeCentersNode = (nodeAxesCT.' * centeredNodeCentersCT.').';
        leftFaceIndices  = datumFaceIndices(nodeCentersNode(:, 1) <= 0);
        rightFaceIndices = datumFaceIndices(nodeCentersNode(:, 1) > 0);

        % A useful split must create two nonempty groups. Coincident centres
        % or numerical degeneracy can exceptionally put everything on one
        % side. Recursing then would not reduce the problem, so retain this
        % node as a leaf even though the usual limits were not reached.
        if isempty(leftFaceIndices) || isempty(rightFaceIndices)
            return;
        end

        % STEP 6: Recursively build the two children.
        %
        % Mark this node as internal, create both smaller subtrees, and save
        % their returned array indices. Each child repeats Steps 1-6 using
        % only its own subset of triangle faces.
        nodes(nodeIndex).isLeaf = false;
        leftNodeIndex  = buildNode(leftFaceIndices, nodeIndex, depth + 1);
        rightNodeIndex = buildNode(rightFaceIndices, nodeIndex, depth + 1);
        nodes(nodeIndex).leftNodeIndex  = leftNodeIndex;
        nodes(nodeIndex).rightNodeIndex = rightNodeIndex;
    end
end
