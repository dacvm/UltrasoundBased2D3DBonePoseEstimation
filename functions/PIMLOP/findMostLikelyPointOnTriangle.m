function [yPosition3D, barycentricCoordinates] = findMostLikelyPointOnTriangle( ...
    xPosition3D, triangleVertices3D, positionCovariance3D)
%FINDMOSTLIKELYPOINTONTRIANGLE Find the best position on one mesh triangle.
%   P-IMLOP treats a mesh triangle as one model datum. The triangle centre
%   helps organize the PD-tree, but the final model point Y may lie anywhere
%   on the triangle. This function finds that point by minimizing the
%   Mahalanobis position distance from a measured point X to the triangle.
%
%   Inputs
%   ------
%   xPosition3D : 3-by-1 position of X. It may be expressed in any 3D frame.
%       triangleVertices3D must use the same frame.
%   triangleVertices3D : 3-by-3 array containing the three triangle vertices.
%       Each row is one vertex [x, y, z].
%   positionCovariance3D : 3-by-3 positive-definite position covariance in
%       the same 3D frame as X and the triangle.
%
%   Outputs
%   -------
%   yPosition3D : 3-by-1 point on the triangle with the smallest Mahalanobis
%       distance to X.
%   barycentricCoordinates : 3-by-1 weights of the triangle vertices. The
%       weights are nonnegative and sum to one, so they also provide a simple
%       way to verify that yPosition3D lies inside the triangle.
%
%   Example
%   -------
%       triangle = [0, 0, 0; 4, 0, 0; 0, 4, 0];
%       x = [3; 3; 2];
%       Sigma = eye(3);
%       [y, barycentric] = findMostLikelyPointOnTriangle(x, triangle, Sigma);
%       % y is [2; 2; 0] and barycentric is [0; 0.5; 0.5].

validateattributes(xPosition3D, {'numeric'}, ...
    {'real', 'finite', 'size', [3, 1]}, mfilename, 'xPosition3D');
validateattributes(triangleVertices3D, {'numeric'}, ...
    {'real', 'finite', 'size', [3, 3]}, mfilename, 'triangleVertices3D');
validateattributes(positionCovariance3D, {'numeric'}, ...
    {'real', 'finite', 'size', [3, 3]}, mfilename, 'positionCovariance3D');

% STEP 1: MOVE THE PROBLEM INTO WHITENED COORDINATES
%
% P-IMLOP does not judge every displacement equally. A displacement along a
% direction with small measurement uncertainty is more costly than the same
% displacement along a direction with large uncertainty. This weighted
% distance is the Mahalanobis distance.
%
% CHOL factors the covariance as
%
%       positionCovariance3D = covarianceLower * covarianceLower'.
%
% Subtracting X makes the query point the origin. Solving covarianceLower\d
% then rescales and rotates each displacement d according to its uncertainty.
% This operation is called whitening. After whitening, Mahalanobis distance
% in physical space is exactly ordinary Euclidean distance from the origin.
% We can therefore solve a familiar closest-point-to-triangle problem.
covarianceLower  = chol(positionCovariance3D, 'lower');
triangleWhitened = (covarianceLower \ (double(triangleVertices3D).' - double(xPosition3D))).';

% STEP 2: PROJECT THE ORIGIN ONTO THE INFINITE TRIANGLE PLANE
%
% Start at the first whitened vertex q1. The two vectors edge12 and edge13
% span the triangle plane. Any point on that plane can be written as
%
%       q = q1 + u*(q2-q1) + v*(q3-q1).
%
% The 2-by-1 vector planeCoordinates contains u and v for the point on this
% infinite plane nearest to the origin. The matrix expression below is the
% least-squares solution of edgeMatrix*[u;v] = -q1. In intuitive terms, it
% drops a perpendicular line from the origin onto the triangle's plane.
q1 = triangleWhitened(1, :).';
edge12 = triangleWhitened(2, :).' - q1;
edge13 = triangleWhitened(3, :).' - q1;
edgeMatrix = [edge12, edge13];
planeCoordinates  = (edgeMatrix.' * edgeMatrix) \ (-edgeMatrix.' * q1);

% Convert u and v into three barycentric weights [w1;w2;w3]. They satisfy
%
%       q = w1*q1 + w2*q2 + w3*q3,       w1+w2+w3 = 1.
%
% Here w2=u, w3=v, and the remaining weight w1=1-u-v. Barycentric weights
% are useful because their signs tell us whether q lies inside the finite
% triangle or only somewhere else on its infinite plane.
insideBarycentric = [1 - sum(planeCoordinates); planeCoordinates];

% STEP 3: ACCEPT AN INTERIOR PROJECTION OR SEARCH THE TRIANGLE BOUNDARY
%
% If all three weights are nonnegative, the plane projection lies inside or
% on the triangle. It must then be the closest allowed point, so reconstruct
% its whitened 3D position directly from the weighted vertices.
if all(insideBarycentric >= 0)
    barycentricCoordinates = insideBarycentric;
    closestWhitened        = triangleWhitened.' * barycentricCoordinates;
else
    % At least one negative weight means the perpendicular plane projection
    % fell outside the finite triangle. The nearest allowed point must then
    % lie somewhere on the boundary: edge 1-2, edge 2-3, or edge 3-1.
    % List those three vertex pairs and prepare to keep the best candidate.
    edgeVertexPairs        = [1, 2; 2, 3; 3, 1];
    bestSquaredDistance    = inf;
    closestWhitened        = zeros(3, 1);
    barycentricCoordinates = zeros(3, 1);

    for edgeIndex = 1:3
        % Read the two endpoints of this edge in whitened coordinates. The
        % direction vector points from its first endpoint to its second.
        firstVertexIndex  = edgeVertexPairs(edgeIndex, 1);
        secondVertexIndex = edgeVertexPairs(edgeIndex, 2);
        edgeStart         = triangleWhitened(firstVertexIndex, :).';
        edgeEnd           = triangleWhitened(secondVertexIndex, :).';
        edgeDirection     = edgeEnd - edgeStart;

        % Parameterize a point on the infinite edge line as
        %
        %       edgeStart + t*edgeDirection.
        %
        % The dot-product expression finds the t whose point is closest to
        % the origin. However, a triangle edge is a finite segment: t<0 lies
        % before its first vertex, and t>1 lies beyond its second vertex.
        % Clamping t into [0,1] therefore produces the closest allowed point
        % on the finite edge, including either endpoint when necessary.
        edgeCoordinate = dot(-edgeStart, edgeDirection) / dot(edgeDirection, edgeDirection);
        edgeCoordinate = min(1, max(0, edgeCoordinate));
        edgeCandidate  = edgeStart + edgeCoordinate * edgeDirection;
        candidateSquaredDistance = dot(edgeCandidate, edgeCandidate);

        % Compare this edge candidate with the best one found so far. Squared
        % distance is sufficient because taking a square root would preserve
        % the ordering while adding unnecessary work.
        if candidateSquaredDistance < bestSquaredDistance
            bestSquaredDistance = candidateSquaredDistance;
            closestWhitened     = edgeCandidate;

            % Convert the edge parameter back to triangle barycentric
            % weights. The unused third vertex receives zero weight. Along
            % this edge, the weights smoothly change from [1,0] at t=0 to
            % [0,1] at t=1.
            barycentricCoordinates = zeros(3, 1);
            barycentricCoordinates(firstVertexIndex)  = 1 - edgeCoordinate;
            barycentricCoordinates(secondVertexIndex) = edgeCoordinate;
        end
    end
end

% STEP 4: RETURN FROM WHITENED SPACE TO THE ORIGINAL 3D FRAME
%
% closestWhitened is a displacement from the whitened origin. Multiplying by
% covarianceLower reverses the whitening, and adding X reverses the earlier
% translation. The result is the physical model point Y in the same frame and
% millimetre units as the input X and triangle vertices.
yPosition3D = double(xPosition3D) + covarianceLower * closestWhitened;
end
