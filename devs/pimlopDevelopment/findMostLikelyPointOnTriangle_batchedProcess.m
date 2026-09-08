function [yPositions3D, barycentricCoordinates, distanceSquared] = ...
    findMostLikelyPointOnTriangle_batchedProcess( ...
    xPositions3D, triangleVertices3D, positionCovariance3D, covarianceLower)
%FINDMOSTLIKELYPOINTONTRIANGLE_BATCHEDPROCESS Minimize over complete triangles.
%   This is the array version of findMostLikelyPointOnTriangle. It finds the
%   best position on every supplied triangle for every supplied query. It
%   preserves interior, edge, and vertex solutions under Mahalanobis distance.
%
%   Inputs
%   ------
%   xPositions3D : Q-by-3 query positions in one shared 3D frame.
%   triangleVertices3D : 3-by-3-by-M complete triangles in that same frame.
%       Page j contains triangle j, with one vertex per row.
%   positionCovariance3D : Shared symmetric positive-definite 3-by-3 covariance.
%   covarianceLower : Optional lower Cholesky factor of that covariance.
%       A search may supply its already prepared factor to avoid repeating
%       CHOL in every leaf. It must satisfy Sigma = covarianceLower*covarianceLower'.
%
%   Outputs
%   -------
%   yPositions3D : Q-by-M-by-3 positions; (i,j,:) is the match on triangle j
%       for query i. These are physical coordinates, not whitened coordinates.
%   barycentricCoordinates : Q-by-M-by-3 nonnegative vertex weights summing
%       to one. One zero indicates an edge; two zeros indicate a vertex.
%   distanceSquared : Q-by-M minimum squared Mahalanobis distances. Half of
%       this array is Equation (5), ready to reuse in the complete match cost.
%
%   The caller bounds Q*M by splitting large searches into leaf-sized blocks.
%   No parallel workers are used. The only usual loop below has three edges.

validateattributes(xPositions3D, {'numeric'}, {'real','finite','2d','ncols',3,'nonempty'});
validateattributes(triangleVertices3D, {'numeric'}, {'real','finite','nonempty'});
if size(triangleVertices3D,1) ~= 3 || size(triangleVertices3D,2) ~= 3 || ndims(triangleVertices3D) > 3
    error('findMostLikelyPointOnTriangle_batchedProcess:TriangleShape', ...
        'Triangles must be a 3-by-3-by-M array, with vertices in rows.');
end
validateattributes(positionCovariance3D, {'numeric'}, {'real','finite','size',[3 3]});
if nargin < 4 || isempty(covarianceLower)
    covarianceLower = chol(positionCovariance3D, 'lower');
end

% STEP 1: WHITEN DISPLACEMENTS, SHARING THE SAME METRIC ACROSS THE BLOCK
% Sigma=L*L' implies d'*inv(Sigma)*d = ||L\d||^2. Subtract the triangle
% anchor before whitening to avoid subtracting large transformed coordinates.
queryCount = size(xPositions3D,1);
triangleCount = size(triangleVertices3D,3);
a = reshape(double(triangleVertices3D(1,:,:)),3,[]).';
b = reshape(double(triangleVertices3D(2,:,:)),3,[]).';
c = reshape(double(triangleVertices3D(3,:,:)),3,[]).';
edge12 = (covarianceLower \ (b-a).').';
edge13 = (covarianceLower \ (c-a).').';
displacement = reshape(double(xPositions3D),queryCount,1,3) - reshape(a,1,triangleCount,3);
displacement = reshape(reshape(displacement,[],3) / covarianceLower.', queryCount,triangleCount,3);
e12 = reshape(edge12,1,triangleCount,3);
e13 = reshape(edge13,1,triangleCount,3);

% STEP 2: PROJECT EACH QUERY ONTO EACH INFINITE TRIANGLE PLANE
% Solve the two-variable normal equations for q=a+u*(b-a)+v*(c-a).
% The Gram coefficients depend only on the triangle, so all queries share them.
g11 = sum(edge12.^2,2).';
g12 = sum(edge12.*edge13,2).';
g22 = sum(edge13.^2,2).';
rhs1 = sum(displacement.*e12,3);
rhs2 = sum(displacement.*e13,3);
determinant = g11.*g22-g12.^2;
regular = determinant > 1e-12*(g11.*g22);
u = zeros(queryCount,triangleCount);
v = u;
u(:,regular) = (rhs1(:,regular).*g22(regular)-rhs2(:,regular).*g12(regular))./determinant(regular);
v(:,regular) = (rhs2(:,regular).*g11(regular)-rhs1(:,regular).*g12(regular))./determinant(regular);

% Very skinny triangles make normal equations poorly conditioned. Only those
% uncommon pages use a direct least-squares solve, still for all queries at once.
for j = find(~regular)
    basis = [edge12(j,:).', edge13(j,:).'];
    if rank(basis) < 2
        error('findMostLikelyPointOnTriangle_batchedProcess:DegenerateTriangle', ...
            'The supplied triangle is degenerate in the positional metric.');
    end
    coordinates = basis \ reshape(displacement(:,j,:),queryCount,3).';
    u(:,j) = coordinates(1,:).';
    v(:,j) = coordinates(2,:).';
end
weights = cat(3,1-u-v,u,v);
inside = all(weights >= 0,3);
planeResidual = u.*e12+v.*e13-displacement;
distanceSquared = sum(planeResidual.^2,3);
distanceSquared(~inside) = inf;

% STEP 3: CHECK ALL THREE FINITE EDGES FOR OUTSIDE PROJECTIONS
% Clamping the line parameter to [0,1] includes both vertices automatically.
% Only outside projections can be replaced; an interior projection is already
% the global minimum on its triangle. The strict comparison preserves edge order.
whitenedVertices = {zeros(size(e12)), e12, e13};
edgePairs = [1 2; 2 3; 3 1];
for edgeNumber = 1:3
    first = edgePairs(edgeNumber,1);
    second = edgePairs(edgeNumber,2);
    start = whitenedVertices{first};
    direction = whitenedVertices{second}-start;
    parameter = sum((displacement-start).*direction,3)./sum(direction.^2,3);
    parameter = min(1,max(0,parameter));
    residual = start+parameter.*direction-displacement;
    edgeDistance = sum(residual.^2,3);
    improve = ~inside & edgeDistance < distanceSquared;
    distanceSquared(improve) = edgeDistance(improve);
    for vertexNumber = 1:3
        newWeight = zeros(queryCount,triangleCount);
        if vertexNumber == first
            newWeight = 1-parameter;
        elseif vertexNumber == second
            newWeight = parameter;
        end
        oldWeight = weights(:,:,vertexNumber);
        oldWeight(improve) = newWeight(improve);
        weights(:,:,vertexNumber) = oldWeight;
    end
end

% STEP 4: RETURN THE POSITION AND THE POSITIONAL COST WITHOUT RECOMPUTING IT
% Barycentric weights are unchanged by whitening. Reconstruct with physical
% edges so every output stays in the same frame and units as the inputs.
barycentricCoordinates = weights;
yPositions3D = reshape(a,1,triangleCount,3) ...
    + weights(:,:,2).*reshape(b-a,1,triangleCount,3) ...
    + weights(:,:,3).*reshape(c-a,1,triangleCount,3);
end
