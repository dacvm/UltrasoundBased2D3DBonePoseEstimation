function [Ybest, Ebest, searchDetails] = searchPDTree_batchedProcess( ...
    X, Psi, R_p, positionCovarianceImage, kappa, options)
%SEARCHPDTREE_BATCHEDPROCESS Search a fixed PD-tree for many oriented queries.
%   This applies the P-IMLOP Algorithm 2 independently to every query while
%   sharing node tests and leaf arithmetic. Each query keeps its own best
%   error and may follow different branches. No parallel workers are used.
%
%   Inputs
%   ------
%   X : Scalar structure containing position3D (N-by-3, search frame) and
%       normal2DImage (N-by-2, local image frame). One row is one measurement.
%   Psi : Model from preparePIMLOPModel_batchedProcess with a tree from
%       buildPIMLOPPDTree_batchedProcess. Original prepared models and trees
%       are also accepted; their missing geometry caches are derived locally.
%   R_p : Shared proper 3-by-3 image-to-search rotation for this query group.
%   positionCovarianceImage : Shared positive-definite 3-by-3 image covariance.
%       Group queries separately when their image rotations or covariances differ.
%   kappa : Shared nonnegative orientation concentration.
%   options : Optional scalar structure:
%       UsePruning - true (default) applies Equation (8); false visits all faces.
%       QueryBatchSize - maximum queries traversing together (default 64).
%       MaxPairsPerBatch - maximum query/triangle pairs in one leaf block
%           (default 8192). This bounds temporary arrays without sampling faces.
%
%   Outputs
%   -------
%   Ybest : Scalar structure of row-based arrays: position3D and normal3D are
%       N-by-3; faceIndex is N-by-1 and preserves original mesh face numbers.
%   Ebest : N-by-1 minimum Equation (7) errors, in the same order as X.
%   searchDetails : Per-query traversal counts (N-by-1), barycentricCoordinates
%       (N-by-3), and batched matchDetails for the final winners. elapsedSeconds
%       is total batch wall time including shared preparation. amortizedSecondsPerQuery
%       is that total divided by N, not an individually timed query latency.
%
%   There are two levels of batching: multiple queries share each node test,
%   and a bounded query-by-triangle block is evaluated inside each leaf.
%   Tree traversal is still depth-first, left before right, as in the scalar
%   version. Batch minima preserve the first candidate when costs tie exactly.

timer = tic;
if nargin < 6 || isempty(options)
    options = struct();
end
if ~isfield(options,'UsePruning'), options.UsePruning = true; end
if ~isfield(options,'QueryBatchSize'), options.QueryBatchSize = 64; end
if ~isfield(options,'MaxPairsPerBatch'), options.MaxPairsPerBatch = 8192; end
validateattributes(options.UsePruning, {'logical','numeric'}, {'scalar','binary'});
validateattributes(options.QueryBatchSize, {'numeric'}, {'scalar','integer','positive','finite'});
validateattributes(options.MaxPairsPerBatch, {'numeric'}, {'scalar','integer','positive','finite'});
validateattributes(X.position3D, {'numeric'}, {'real','finite','2d','ncols',3,'nonempty'});
count = size(X.position3D,1);
validateattributes(X.normal2DImage, {'numeric'}, {'real','finite','size',[count 2]});
validateattributes(R_p, {'numeric'}, {'real','finite','size',[3 3]});
validateattributes(positionCovarianceImage, {'numeric'}, {'real','finite','size',[3 3]});
validateattributes(kappa, {'numeric'}, {'real','finite','scalar','nonnegative'});
if norm(R_p.'*R_p-eye(3),'fro') > 1e-6 || abs(det(R_p)-1) > 1e-6
    error('searchPDTree_batchedProcess:InvalidRotation','R_p must be a proper rotation.');
end
if norm(positionCovarianceImage-positionCovarianceImage.','fro') > 1e-10*max(1,norm(positionCovarianceImage,'fro'))
    error('searchPDTree_batchedProcess:InvalidCovariance','Covariance must be symmetric.');
end
if isempty(Psi.pdTree)
    error('searchPDTree_batchedProcess:MissingTree','Prepare Psi.pdTree before searching.');
end

% STEP 1: SHARE METRIC AND ORIENTATION PREPARATION ACROSS ALL MEASUREMENTS
% These values depend on the candidate image orientation, not on which query
% reaches a leaf. Rebuild them per call so a new optimizer pose cannot reuse
% stale covariance or projected-normal information.
SigmaImage = 0.5*(double(positionCovarianceImage)+double(positionCovarianceImage).');
chol(SigmaImage);
Sigma3D = R_p*SigmaImage*R_p.';
Sigma3D = 0.5*(Sigma3D+Sigma3D.');
covarianceLower = chol(Sigma3D,'lower');
precision = Sigma3D\eye(3);
precision = 0.5*(precision+precision.');
normalLengths = vecnorm(X.normal2DImage,2,2);
if any(normalLengths <= 1e-12)
    error('searchPDTree_batchedProcess:ZeroNormal','Measurement normals must be nonzero.');
end
xNormals = double(X.normal2DImage)./normalLengths;
faceNormals = double(Psi.faceNormals);
faceNormals = faceNormals./vecnorm(faceNormals,2,2);
faceNormalsImage = faceNormals*R_p;
projectedLengths = vecnorm(faceNormalsImage(:,1:2),2,2);
projectedNormals = zeros(size(faceNormals,1),2);
defined = projectedLengths > 1e-12;
projectedNormals(defined,:) = faceNormalsImage(defined,1:2)./projectedLengths(defined);
tree = Psi.pdTree;
if isfield(Psi,'triangleVerticesCT')
    triangles = Psi.triangleVerticesCT;
else
    % Compatibility with the original preparation is useful for comparisons.
    faces = Psi.mesh.ConnectivityList;
    vertices = double(Psi.mesh.Points);
    triangles = permute(cat(3,vertices(faces(:,1),:), ...
        vertices(faces(:,2),:),vertices(faces(:,3),:)),[3 2 1]);
end

% STEP 2: KEEP SEPARATE BEST-MATCH STATE FOR EVERY QUERY
% A finite bound from one query must never prune the search for another.
Ebest = inf(count,1);
Ybest = struct('position3D',zeros(count,3),'normal3D',zeros(count,3), ...
    'faceIndex',zeros(count,1));
bestBarycentric = nan(count,3);
nodesVisited = zeros(count,1);
leavesVisited = zeros(count,1);
facesEvaluated = zeros(count,1);
nodesPruned = zeros(count,1);
intersectionTests = zeros(count,1);
batchSize = min(options.QueryBatchSize,options.MaxPairsPerBatch);

% STEP 3: TRAVERSE WITH A NODE AND ITS STILL-ACTIVE QUERY INDICES
% Group size bounds memory. Each group searches the same fixed tree, and
% each node filters only its own active queries using their current errors.
for firstQuery = 1:batchSize:count
    nodeStack = zeros(tree.numberOfNodes,1);
    queryStack = cell(tree.numberOfNodes,1);
    pending = 1;
    nodeStack(1) = tree.rootNodeIndex;
    queryStack{1} = (firstQuery:min(count,firstQuery+batchSize-1)).';
    while pending > 0
        nodeIndex = nodeStack(pending);
        active = queryStack{pending};
        queryStack{pending} = [];
        pending = pending-1;
        currentNode = tree.nodes(nodeIndex);
        nodesVisited(active) = nodesVisited(active)+1;

        % Equation (7) has a nonnegative orientation term. Set its lower
        % bound to zero, as in the paper; Equation (8) then uses 2*Ebest(i).
        if options.UsePruning
            finiteBound = isfinite(Ebest(active));
            tested = active(finiteBound);
            if ~isempty(tested)
                box = currentNode;
                if isfield(tree,'batchGeometry')
                    box.rotationNodeToCT = tree.batchGeometry.rotationsNodeToCT(:,:,nodeIndex);
                    box.originCT = tree.batchGeometry.originsCT(nodeIndex,:);
                    box.boundsMinNode = tree.batchGeometry.boundsMinNode(nodeIndex,:);
                    box.boundsMaxNode = tree.batchGeometry.boundsMaxNode(nodeIndex,:);
                end
                keep = ellipsoidIntersectsOBB_batchedProcess( ...
                    X.position3D(tested,:),precision,Ebest(tested),box);
                intersectionTests(tested) = intersectionTests(tested)+1;
                nodesPruned(tested(~keep)) = nodesPruned(tested(~keep))+1;
                survive = true(size(active));
                survive(finiteBound) = keep;
                active = active(survive);
            end
        end
        if isempty(active), continue; end
        if ~currentNode.isLeaf
            % Push right first so left is processed next. When right is
            % popped it sees the improved per-query bounds obtained on left.
            pending = pending+1;
            nodeStack(pending) = currentNode.rightNodeIndex;
            queryStack{pending} = active;
            pending = pending+1;
            nodeStack(pending) = currentNode.leftNodeIndex;
            queryStack{pending} = active;
            continue;
        end

        % STEP 4: EVALUATE COMPLETE TRIANGLES IN BOUNDED LEAF BLOCKS
        % The triangle routine returns the minimum positional distance, so
        % Equation (7) needs only a projected-normal dot product afterward.
        % No validation-heavy scalar cost calls or graphics allocations occur
        % for rejected candidates. All triangles in the leaf are still tested.
        leavesVisited(active) = leavesVisited(active)+1;
        faceIds = currentNode.datumFaceIndices;
        facesEvaluated(active) = facesEvaluated(active)+numel(faceIds);
        trianglesPerBlock = max(1,floor(options.MaxPairsPerBatch/numel(active)));
        for firstFace = 1:trianglesPerBlock:numel(faceIds)
            blockFaces = faceIds(firstFace:min(numel(faceIds),firstFace+trianglesPerBlock-1));
            [positions,weights,squaredDistances] = findMostLikelyPointOnTriangle_batchedProcess( ...
                X.position3D(active,:),triangles(:,:,blockFaces),Sigma3D,covarianceLower);
            cosine = min(1,max(-1,xNormals(active,:)*projectedNormals(blockFaces,:).'));
            errors = 0.5*squaredDistances+kappa*(1-cosine);
            [blockBest,winningColumn] = min(errors,[],2);
            improve = blockBest < Ebest(active);
            if any(improve)
                improvedQueries = active(improve);
                pairs = sub2ind(size(errors),find(improve),winningColumn(improve));
                winningFaces = blockFaces(winningColumn(improve));
                Ebest(improvedQueries) = blockBest(improve);
                Ybest.faceIndex(improvedQueries) = winningFaces;
                Ybest.normal3D(improvedQueries,:) = Psi.faceNormals(winningFaces,:);
                for coordinate = 1:3
                    positionPage = positions(:,:,coordinate);
                    weightPage = weights(:,:,coordinate);
                    Ybest.position3D(improvedQueries,coordinate) = positionPage(pairs);
                    bestBarycentric(improvedQueries,coordinate) = weightPage(pairs);
                end
            end
        end
    end
end

% STEP 5: DIAGNOSE THE FINAL MATCHES ONCE, NOT EVERY CANDIDATE
% Preserve the useful scalar report fields as row arrays. An amortized time
% is reported honestly: shared batch work cannot be timed as individual calls.
if nargout > 2
    [~,matchDetails] = calculatePIMLOPMatchError_batchedProcess(X,Ybest,R_p,positionCovarianceImage,kappa);
    searchDetails = struct();
    searchDetails.numberOfNodesVisited = nodesVisited;
    searchDetails.numberOfLeavesVisited = leavesVisited;
    searchDetails.numberOfFacesEvaluated = facesEvaluated;
    searchDetails.numberOfNodesPruned = nodesPruned;
    searchDetails.numberOfNodeIntersectionTests = intersectionTests;
    searchDetails.barycentricCoordinates = bestBarycentric;
    searchDetails.matchDetails = matchDetails;
    searchDetails.usePruning = logical(options.UsePruning);
    searchDetails.elapsedSeconds = toc(timer);
    searchDetails.amortizedSecondsPerQuery = searchDetails.elapsedSeconds/count;
    searchDetails.options = options;
end
end
