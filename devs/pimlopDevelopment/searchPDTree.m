function [Ybest, Ebest, searchDetails] = searchPDTree( ...
    X, Psi, R_p, positionCovarianceImage, kappa, options)
%SEARCHPDTREE Find a P-IMLOP mesh match by traversing the prepared PD-tree.
%   This Stage 4 implementation deliberately performs an exhaustive tree
%   traversal: it visits every leaf and evaluates every valid triangle. It
%   does not prune any node yet. This simple version proves that the tree
%   structure, leaf contents, triangle matcher, and E_match calculation work
%   together before Stage 5 adds the more delicate pruning rule.
%
%   The easiest way to understand this function is to imagine the PD-tree as
%   a family tree of boxes:
%
%       root box
%          |-- smaller left box
%          |       |-- ...
%          |-- smaller right box
%                  |-- ...
%
%   An internal node is only a box that points to two smaller child boxes. A
%   leaf node is a final box that stores a short list of mesh triangles. The
%   search walks down this hierarchy until it reaches a leaf, then asks:
%   "Which point on each triangle is the most likely match for X?"
%
%   Algorithm 2 in the P-IMLOP paper contains one additional decision before
%   entering a node: it tests whether the current positional-error ellipsoid
%   intersects the node's oriented bounding box. A non-intersecting node can
%   be pruned. Stage 4 intentionally skips that decision. In other words, it
%   behaves as though every node passes the intersection test. This makes the
%   result slow, but it gives us a simple reference that must agree with the
%   Stage 3 brute-force search before pruning is introduced.
%
%   At a high level, this function performs five steps:
%       1. Rotate the positional covariance into the shared 3D search frame.
%       2. Put the root node on a list of nodes waiting to be visited.
%       3. Repeatedly remove one waiting node.
%       4. For an internal node, add its two children to the waiting list.
%          For a leaf, evaluate every triangle stored in that leaf.
%       5. Keep the candidate having the smallest Equation (7) match error.
%
%   Inputs
%   ------
%   X : Scalar projection-oriented measurement structure with:
%       position3D    - 3-by-1 point in the shared 3D search frame;
%       normal2DImage - 2-by-1 normal in local ultrasound image X-Y.
%   Psi : Complete P-IMLOP model structure. Its mesh, faceNormals, and
%       validFaceMask describe the model geometry, while Psi.pdTree contains
%       the tree created by buildPIMLOPPDTree. All model geometry must use the
%       same 3D frame as X.
%   R_p : 3-by-3 rotation from the local ultrasound image frame into the
%       shared 3D search frame.
%   positionCovarianceImage : 3-by-3 position covariance in the local image
%       X-Y-Z frame.
%   kappa : Nonnegative von Mises concentration for orientation matching.
%   options : Optional scalar structure. Stage 4 supports UsePruning=false
%       only. Stage 5 can extend this option without changing the function's
%       inputs or outputs.
%
%   Outputs
%   -------
%   Ybest : Best oriented model point with:
%       position3D - 3-by-1 point on the winning triangle;
%       normal3D   - 3-by-1 unit face normal;
%       faceIndex  - original row in Psi.mesh.ConnectivityList.
%   Ebest : Smallest nonnegative Equation (7) match error found in the tree.
%   searchDetails : Diagnostic structure containing traversal counts, elapsed
%       time, the winning barycentric coordinates, and the winning E_match
%       details. In this exhaustive stage, numberOfNodesPruned is always zero.
%
%   Example
%   -------
%       options.UsePruning = false;
%       [YmatchCT, Ebest, details] = searchPDTree( ...
%           XqueryCT, PsiCT, R_image_CT, SigmaImage, 50, options);

% -------------------------------------------------------------------------
% STEP 0: SELECT THE STAGE 4 SEARCH BEHAVIOUR
%
% Keep exhaustive traversal as the default. The option is already part of
% the interface so Stage 5 can add pruning without changing existing calls.
% A caller therefore does not need to know whether the internal search is the
% simple Stage 4 traversal or the future accelerated traversal.
if nargin < 6 || isempty(options)
    options = struct();
end
if ~isfield(options, 'UsePruning')
    options.UsePruning = false;
end

% Stage 4 must remain an easily trusted baseline. Silently accepting true
% here would suggest that Algorithm 2's node-rejection test is active even
% though it is not implemented in this function yet.
if options.UsePruning
    error('searchPDTree:PruningNotImplemented', ...
          'Stage 4 supports only options.UsePruning = false.');
end

% The search requires the hierarchy prepared by buildPIMLOPPDTree. At this
% point the mesh geometry and the tree are already stored together in Psi.
if isempty(Psi.pdTree)
    error('searchPDTree:MissingPDTree', ...
          'Psi.pdTree must be built before searchPDTree is called.');
end

% Give short local names to the arrays used repeatedly in the inner loop.
% datumFaceIndices stored in a leaf refers to rows of boneFaces, and each row
% of boneFaces refers to three rows of bonePoints3D.
boneFaces    = Psi.mesh.ConnectivityList;
bonePoints3D = double(Psi.mesh.Points);
pdTree       = Psi.pdTree;

% -------------------------------------------------------------------------
% STEP 1: EXPRESS POSITIONAL UNCERTAINTY IN THE SEARCH FRAME
%
% positionCovarianceImage describes the uncertainty directions in the local
% ultrasound image frame. X and the CT mesh are expressed in the shared 3D
% search frame. Therefore, rotate the covariance with R_p before using it to
% find the most likely point on a triangle:
%
%     Sigma_3D = R_p * Sigma_image * R_p'.
%
% This is calculated once, outside the triangle loop, because every triangle
% uses the same measurement and the same covariance. The second line removes
% only tiny numerical asymmetry caused by floating-point arithmetic.
positionCovariance3D = R_p * double(positionCovarianceImage) * R_p.';
positionCovariance3D = 0.5 * (positionCovariance3D + positionCovariance3D.');

% -------------------------------------------------------------------------
% STEP 2: PREPARE AN EMPTY "BEST MATCH SO FAR"
%
% Algorithm 2 carries [y_best, E_best] through the tree. Before examining the
% first triangle, no candidate exists. Setting Ebest to infinity is a simple
% way to express that state: every real, finite match error is better than
% infinity, so the first evaluated triangle automatically becomes the first
% best candidate. Each later triangle must beat that stored error.
%
% Ybest and the two detail variables receive placeholder values only so the
% outputs have predictable shapes before the first leaf is processed.
Ebest = inf;
Ybest = struct('position3D', zeros(3, 1), 'normal3D', zeros(3, 1), 'faceIndex', 0);
bestBarycentricCoordinates = nan(3, 1);
bestMatchDetails = struct();

% These counters do not affect the selected match. They provide visible proof
% that Stage 4 really visited the complete tree. Later, they will also make it
% easy to measure how much work Stage 5 pruning avoids.
numberOfNodesVisited  = 0;
numberOfLeavesVisited = 0;
numberOfFacesEvaluated = 0;
searchTimer = tic;

% -------------------------------------------------------------------------
% STEP 3: START A DEPTH-FIRST WALK FROM THE ROOT
%
% nodeStack is a "to-do list" of node indices that still need to be visited.
% We use the last-in, first-out rule of a stack:
%       push = add an index at the end;
%       pop  = take the most recently added index from the end.
%
% This produces a depth-first traversal: after entering an internal node, the
% search follows one child downward before returning for the other child.
% Recursion could express the same idea, as Algorithm 2 does in the paper, but
% an explicit stack keeps the MATLAB control flow visible and avoids creating
% one function call for every node.
%
% The stack can never need more entries than the total number of tree nodes,
% so allocate that amount once. numberOfPendingNodes indicates both how many
% entries are waiting and where the current top of the stack is located.
nodeStack = zeros(pdTree.numberOfNodes, 1);
numberOfPendingNodes = 1;
nodeStack(numberOfPendingNodes) = pdTree.rootNodeIndex;

while numberOfPendingNodes > 0
    % POP: read the node at the top of the stack, then shorten the waiting
    % list by one entry. The stored number is an index into pdTree.nodes.
    currentNodeIndex = nodeStack(numberOfPendingNodes);
    numberOfPendingNodes = numberOfPendingNodes - 1;

    currentNode = pdTree.nodes(currentNodeIndex);
    numberOfNodesVisited = numberOfNodesVisited + 1;

    % This is where the ellipsoid-versus-oriented-bounding-box test from
    % Algorithm 2 will belong in Stage 5. If that test proves that a node
    % cannot improve Ebest, the future search will skip the node and all of
    % its descendants. Stage 4 performs no such test, so every popped node is
    % processed and every branch remains searchable.
    if ~currentNode.isLeaf
        % An internal node does not represent a final match candidate. Its
        % purpose is to guide us to two smaller spatial groups, so place both
        % children on the waiting stack.
        %
        % Push the right child first and the left child second. Because a
        % stack pops the most recently pushed item, the left child is visited
        % next. This ordering is chosen only to make traversal predictable;
        % without pruning, reversing it cannot change the final minimum.
        numberOfPendingNodes = numberOfPendingNodes + 1;
        nodeStack(numberOfPendingNodes) = currentNode.rightNodeIndex;
        numberOfPendingNodes = numberOfPendingNodes + 1;
        nodeStack(numberOfPendingNodes) = currentNode.leftNodeIndex;
        continue;
    end

    % ---------------------------------------------------------------------
    % STEP 4: EVALUATE EVERY TRIANGLE DATUM IN THIS LEAF
    %
    % Reaching this line means currentNode is a leaf. In the terminology of
    % the paper, each mesh triangle is one model "datum." The leaf owns the
    % final list of datum face indices that must be tested individually.
    %
    % Internal nodes also retain face lists for tree construction and
    % visualization. We intentionally do not evaluate those lists: the same
    % triangle also exists in one descendant leaf, so evaluating it at every
    % ancestor would repeat work and would corrupt the verification counts.
    numberOfLeavesVisited = numberOfLeavesVisited + 1;

    for datumNumber = 1:numel(currentNode.datumFaceIndices)
        % Convert the stored face index into the triangle's three 3D vertex
        % positions. faceIndex remains the original mesh face number, which
        % lets the returned Y point identify its source triangle.
        faceIndex = currentNode.datumFaceIndices(datumNumber);
        triangleVertices3D = bonePoints3D(boneFaces(faceIndex, :), :);

        % The triangle centre used while building the PD-tree is only a
        % representative position for grouping and splitting datums. It is
        % not automatically the most likely correspondence.
        %
        % The true model point y_3dp may lie anywhere inside the triangle.
        % findMostLikelyPointOnTriangle therefore minimizes the positional
        % Mahalanobis term over the complete triangle using Sigma_3D. The
        % returned barycentric coordinates describe where that point lies
        % relative to the triangle's three vertices.
        [candidatePosition3D, candidateBarycentricCoordinates] = ...
            findMostLikelyPointOnTriangle( ...
            X.position3D, triangleVertices3D, positionCovariance3D);

        % Pair the candidate position with the triangle's face normal. This
        % produces one oriented model point Y, matching the paper's notation
        % y = (y_3dp, y_3dn). A triangle has one constant face normal, so the
        % normal is the same wherever the candidate position lies on it.
        Ycandidate = struct();
        Ycandidate.position3D = candidatePosition3D;
        Ycandidate.normal3D   = Psi.faceNormals(faceIndex, :).';

        % Evaluate Equation (7) from the paper. It adds:
        %   - positional disagreement measured with the covariance; and
        %   - projected-normal disagreement weighted by kappa.
        % Equation (7) is nonnegative, and a perfect position-and-orientation
        % match has zero error. Lower candidateError therefore means a more
        % likely correspondence under the P-IMLOP noise model.
        [candidateError, candidateDetails] = calculatePIMLOPMatchError( ...
            X, Ycandidate, R_p, positionCovarianceImage, kappa);
        numberOfFacesEvaluated = numberOfFacesEvaluated + 1;

        % -----------------------------------------------------------------
        % STEP 5: UPDATE THE BEST MATCH ONLY WHEN THIS CANDIDATE IS BETTER
        %
        % This is the update operation shown inside the leaf loop of
        % Algorithm 2. If the new Equation (7) error is smaller, save all
        % information belonging to this candidate together. If it is not
        % smaller, leave the current best match unchanged and continue.
        if candidateError < Ebest
            Ebest = candidateError;
            Ybest.position3D = candidatePosition3D;
            Ybest.normal3D   = Ycandidate.normal3D;
            Ybest.faceIndex  = faceIndex;
            bestBarycentricCoordinates = candidateBarycentricCoordinates;
            bestMatchDetails = candidateDetails;
        end
    end
end

% -------------------------------------------------------------------------
% PACKAGE THE SEARCH RESULT AND ITS VERIFICATION INFORMATION
%
% After the stack becomes empty, every reachable node has been processed and
% Ebest is the minimum over every valid mesh triangle. Return compact evidence
% about what the search actually did. For Stage 4, the visited counts should
% equal the complete tree counts and numberOfNodesPruned must remain zero.
% Later, a correct pruned search should return the same Ybest and Ebest while
% visiting fewer nodes, leaves, and triangle datums.
searchDetails = struct();
searchDetails.numberOfNodesVisited          = numberOfNodesVisited;
searchDetails.numberOfLeavesVisited         = numberOfLeavesVisited;
searchDetails.numberOfFacesEvaluated        = numberOfFacesEvaluated;
searchDetails.numberOfNodesPruned           = 0;
searchDetails.elapsedSeconds                = toc(searchTimer);
searchDetails.barycentricCoordinates        = bestBarycentricCoordinates;
searchDetails.matchDetails                  = bestMatchDetails;
end
