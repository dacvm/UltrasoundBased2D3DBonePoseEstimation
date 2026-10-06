function [Ybest, Ebest, searchDetails] = searchPDTree( ...
    X, Psi, R_p, positionCovarianceImage, kappa, options)
%SEARCHPDTREE Find a P-IMLOP mesh match by traversing the prepared PD-tree.
%   This function supports both development modes of the P-IMLOP search:
%       UsePruning = false visits every leaf and provides the trusted Stage 4
%       exhaustive reference;
%       UsePruning = true applies the Stage 5 ellipsoid-versus-oriented-box
%       test from Algorithm 2 and skips nodes that cannot improve Ebest.
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
%   Algorithm 2 tests whether the current positional-error ellipsoid
%   intersects each node's oriented bounding box. A non-intersecting node is
%   pruned because its triangles cannot produce a smaller complete match
%   error. The exhaustive option deliberately skips this decision, making it
%   useful for checking that pruning has not changed the selected match.
%
%   At a high level, this function performs six steps:
%       1. Rotate the positional covariance into the shared 3D search frame.
%       2. Put the root node on a list of nodes waiting to be visited.
%       3. Repeatedly remove one waiting node.
%       4. When pruning is enabled, reject the node if its box lies completely
%          outside the current Equation (8) search ellipsoid.
%       5. For an internal node, add its two children to the waiting list.
%          For a leaf, evaluate every triangle stored in that leaf.
%       6. Keep the candidate having the smallest Equation (7) match error.
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
%   options : Optional scalar structure with UsePruning. True enables the
%       Stage 5 node-pruning test and is the default. False preserves the
%       exhaustive Stage 4 traversal for verification.
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
%       details. numberOfNodesPruned is zero when UsePruning is false.
%
%   Example
%   -------
%       options.UsePruning = true;
%       [YmatchCT, Ebest, details] = searchPDTree( ...
%           XqueryCT, PsiCT, R_image_CT, SigmaImage, 50, options);

% -------------------------------------------------------------------------
% STEP 0: SELECT EXHAUSTIVE OR PRUNED SEARCH BEHAVIOUR
%
% The completed correspondence search uses Algorithm 2 pruning by default.
% Stage 4 still requests UsePruning=false explicitly, so the slow exhaustive
% reference remains available without maintaining a second search function.
if nargin < 6 || isempty(options)
    options = struct();
end
if ~isfield(options, 'UsePruning')
    options.UsePruning = true;
end
usePruning = logical(options.UsePruning);

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

% The node test repeatedly evaluates Mahalanobis distances. Compute the
% inverse covariance once here rather than solving the same system again for
% every visited node. Symmetrizing removes only numerical round-off.
positionPrecision3D = positionCovariance3D \ eye(3);
positionPrecision3D = 0.5 * (positionPrecision3D + positionPrecision3D.');

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
% that Stage 4 visited the complete tree and show how much work Stage 5 avoids.
numberOfNodesVisited  = 0;
numberOfLeavesVisited = 0;
numberOfFacesEvaluated = 0;
numberOfNodesPruned = 0;
numberOfNodeIntersectionTests = 0;
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

    % ---------------------------------------------------------------------
    % STAGE 5 NODE TEST: CAN THIS BOX STILL IMPROVE THE BEST MATCH?
    %
    % Equation (7) is a sum of nonnegative position and orientation terms.
    % Following the paper, assume the best possible orientation error inside
    % any node is zero. A candidate can beat Ebest only when its positional
    % error is therefore smaller than Ebest.
    %
    % Equation (8) describes all positions that satisfy that requirement as
    % an ellipsoid around X. If this ellipsoid does not touch the node's OBB,
    % no triangle in the node can improve the current match. CONTINUE then
    % skips both the node and every descendant below it.
    %
    % Before the first triangle is evaluated, Ebest is infinite and there is
    % no finite ellipsoid yet. We simply enter nodes until the first leaf gives
    % us a real candidate and a useful finite bound.
    if usePruning && isfinite(Ebest)
        numberOfNodeIntersectionTests = numberOfNodeIntersectionTests + 1;
        nodeCanImproveBestMatch = ellipsoidIntersectsOBB(X.position3D, positionPrecision3D, Ebest, currentNode);

        if ~nodeCanImproveBestMatch
            numberOfNodesPruned = numberOfNodesPruned + 1;
            continue;
        end
    end

    if ~currentNode.isLeaf
        % An internal node does not represent a final match candidate. Its
        % purpose is to guide us to two smaller spatial groups, so place both
        % children on the waiting stack.
        %
        % Push the right child first and the left child second. Because a
        % stack pops the most recently pushed item, the left child is visited
        % next. This ordering is chosen only to make traversal predictable;
        % without pruning, reversing it cannot change the final minimum.
        numberOfPendingNodes            = numberOfPendingNodes + 1;
        nodeStack(numberOfPendingNodes) = currentNode.rightNodeIndex;
        numberOfPendingNodes            = numberOfPendingNodes + 1;
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
        faceIndex          = currentNode.datumFaceIndices(datumNumber);
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
        [candidatePosition3D, candidateBarycentricCoordinates] = findMostLikelyPointOnTriangle(X.position3D, triangleVertices3D, positionCovariance3D);

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
        [candidateError, candidateDetails] = calculatePIMLOPMatchError(X, Ycandidate, R_p, positionCovarianceImage, kappa);
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
% After the stack becomes empty, every remaining searchable branch has been
% processed. A pruned branch cannot beat Ebest because it failed the safe
% positional lower-bound test. Return compact evidence about what the search
% actually did. For Stage 4, the visited counts should equal the complete tree
% counts and numberOfNodesPruned must remain zero. Stage 5 should return the
% same Ybest and Ebest while evaluating fewer triangle datums.
searchDetails = struct();
searchDetails.numberOfNodesVisited          = numberOfNodesVisited;
searchDetails.numberOfLeavesVisited         = numberOfLeavesVisited;
searchDetails.numberOfFacesEvaluated        = numberOfFacesEvaluated;
searchDetails.numberOfNodesPruned           = numberOfNodesPruned;
searchDetails.numberOfNodeIntersectionTests = numberOfNodeIntersectionTests;
searchDetails.usePruning                    = usePruning;
searchDetails.elapsedSeconds                = toc(searchTimer);
searchDetails.barycentricCoordinates        = bestBarycentricCoordinates;
searchDetails.matchDetails                  = bestMatchDetails;
end
