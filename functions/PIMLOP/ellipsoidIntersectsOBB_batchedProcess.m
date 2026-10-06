function [doesIntersect, minimumMahalanobisDistanceSquared] = ...
    ellipsoidIntersectsOBB_batchedProcess( ...
    xPositions3D, positionPrecision3D, maximumPositionError, node)
%ELLIPSOIDINTERSECTSOBB_BATCHEDPROCESS Test many queries against one node box.
%   This preserves the exact 27-feature box minimization used by the scalar
%   function, but each feature is solved for all query positions together.
%   Equation (8) keeps query i when its box distance is <= 2*Ebest(i).
%
%   Inputs
%   ------
%   xPositions3D : Q-by-3 positions in the same 3D frame as the tree.
%   positionPrecision3D : Shared 3-by-3 inverse covariance in that frame.
%   maximumPositionError : Q-by-1 nonnegative best costs, or one shared value.
%       Infinity is allowed before a query has obtained its first match.
%   node : Scalar structure containing T_node_CT, boundsMinNode, boundsMaxNode,
%       as in the original tree; or rotationNodeToCT, originCT, and those bounds
%       when using the packed geometry of buildPIMLOPPDTree_batchedProcess.
%
%   Outputs
%   -------
%   doesIntersect : Q-by-1 logical vector. False safely prunes this node for
%       that query only; another query may still need to search the same node.
%   minimumMahalanobisDistanceSquared : Q-by-1 true minimum over the box.

validateattributes(xPositions3D, {'numeric'}, {'real','finite','2d','ncols',3});
validateattributes(positionPrecision3D, {'numeric'}, {'real','finite','size',[3 3]});
validateattributes(maximumPositionError, {'numeric'}, {'real','nonnegative','nonnan','vector'});
queryCount = size(xPositions3D,1);
if isscalar(maximumPositionError)
    maximumPositionError = repmat(maximumPositionError,queryCount,1);
elseif numel(maximumPositionError) ~= queryCount
    error('ellipsoidIntersectsOBB_batchedProcess:CostSize','Provide one cost per query.');
end

% Express all points in the local box frame with one matrix multiplication.
% The precision matrix is shared, so its rotation is also performed only once.
if isfield(node,'rotationNodeToCT')
    rotation = node.rotationNodeToCT;
    origin = node.originCT(:).';
else
    rotation = node.T_node_CT(1:3,1:3);
    origin = node.T_node_CT(1:3,4).';
end
xNode = (double(xPositions3D)-origin)*rotation;
precisionNode = rotation.'*positionPrecision3D*rotation;
precisionNode = 0.5*(precisionNode+precisionNode.');
lower = node.boundsMinNode(:).';
upper = node.boundsMaxNode(:).';
tolerance = 1e-12*max(1,norm(upper-lower));
minimumMahalanobisDistanceSquared = inf(queryCount,1);

% Each coordinate may be lower-fixed, free, or upper-fixed. Keeping these
% 27 small cases explicit makes the mathematical coverage easy to inspect.
% A matrix right-hand side replaces one solve per measurement in each case.
for sx = -1:1
    for sy = -1:1
        for sz = -1:1
            state = [sx sy sz];
            fixed = state ~= 0;
            free = ~fixed;
            candidate = zeros(queryCount,3);
            candidate(:,state == -1) = repmat(lower(state == -1),queryCount,1);
            candidate(:,state == 1) = repmat(upper(state == 1),queryCount,1);
            feasible = true(queryCount,1);
            if any(free)
                influence = precisionNode(free,fixed)*(candidate(:,fixed)-xNode(:,fixed)).';
                candidate(:,free) = xNode(:,free)-(precisionNode(free,free)\influence).';
                feasible = all(candidate(:,free) >= lower(free)-tolerance ...
                    & candidate(:,free) <= upper(free)+tolerance,2);
                candidate(:,free) = min(max(candidate(:,free),lower(free)),upper(free));
            end
            residual = candidate-xNode;
            distances = sum((residual*precisionNode).*residual,2);
            distances(~feasible) = inf;
            minimumMahalanobisDistanceSquared = min(minimumMahalanobisDistanceSquared,distances);
        end
    end
end

% Retain tangency and the scalar function's round-off tolerance. Each row
% has its own ellipsoid radius; costs must never be shared across queries.
limit = 2*maximumPositionError(:);
comparisonTolerance = 1e-10*max([ones(queryCount,1),abs(limit),abs(minimumMahalanobisDistanceSquared)],[],2);
doesIntersect = minimumMahalanobisDistanceSquared <= limit+comparisonTolerance;
end
