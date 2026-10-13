function [closestPointsXYZ, squaredDistances] = closestPointsOnTriangles(queryPointsXYZ, cornersA, cornersB, cornersC)
%CLOSESTPOINTSONTRIANGLES Closest point on a triangle for many point-triangle pairs at once.
% Row i of every input describes one pair: query point i and the triangle
% with corners A(i,:), B(i,:), C(i,:). For every pair the function returns
% the exact closest location on that triangle (inside it, on an edge, or at
% a corner) and the squared Euclidean distance to it.
%
% Why it is needed:
%   distancePointMesh (geom3d) answers the same question, but it handles one
%   query point per call. The previous ICP-like cost (now
%   devs/costFunctionDevelopment/dev_cost_ICPLike.m) called it once for each
%   of ~3400 measured points, and almost all of the time went into the fixed
%   cost of each call rather than into the arithmetic. Here every step is one
%   array operation over ALL pairs, so the fixed cost is paid only once.
%   cost_ICPLike uses this function for its point-to-mesh distances.
%   (geom3d's own vectorized mode is not an alternative: its region-3 test
%   reads "c <= e" where it should read "c <= -e". This function does not
%   share that bug.)
%
% Method (same geometry as findMostLikelyPointOnTriangle_batchedProcess in
% functions/PIMLOP/, but with plain Euclidean distance, so no covariance
% whitening):
%   1. Project the point onto the triangle's plane by solving the 2x2
%      normal equations with Cramer's rule. If the barycentric weights
%      (1-u-v, u, v) are all non-negative, the projection lies inside the
%      triangle and is the closest point.
%   2. Otherwise the closest point lies on the boundary, so take the closest
%      of the three edge segments. Clamping to each segment also covers the
%      corners. On a tie the strict "<" keeps the first edge found.
% A triangle is convex, so its closest point is unique: this method and the
% region-based Eberly method used by distancePointMesh give the same point,
% up to floating-point rounding.
%
% Assumes no zero-area triangles (the determinant of the 2x2 system would
% be zero); devdemo_cost_ICPLike2 checks that the project mesh has none.
%
% Inputs:
%   queryPointsXYZ - N-by-3 query points.
%   cornersA       - N-by-3 first triangle corner of each pair.
%   cornersB       - N-by-3 second triangle corner of each pair.
%   cornersC       - N-by-3 third triangle corner of each pair.
%                    All inputs must be in the same coordinate frame.
%
% Outputs:
%   closestPointsXYZ - N-by-3 closest point on triangle i to query point i,
%                      in the same frame as the inputs.
%   squaredDistances - N-by-1 squared distance between query point i and
%                      closestPointsXYZ(i,:), in squared input units.

%% STEP 1: PROJECT EVERY POINT ONTO ITS TRIANGLE'S PLANE

% Any location on a triangle's plane can be written as A + u*(B-A) + v*(C-A),
% so the two edges leaving corner A become our local axes. Measuring the
% query point from A too keeps the numbers small, even though the raw
% coordinates are large ref-frame positions in mm.
edgeAB        = cornersB - cornersA;
edgeAC        = cornersC - cornersA;
pointFromA    = queryPointsXYZ - cornersA;

% The (u,v) of the perpendicular foot solve a 2-by-2 linear system (the
% normal equations) whose coefficients are dot products. Multiplying
% element-wise and summing each row gives these dot products for all pairs
% in one go.
gramABAB      = sum(edgeAB .* edgeAB, 2);
gramABAC      = sum(edgeAB .* edgeAC, 2);
gramACAC      = sum(edgeAC .* edgeAC, 2);
rightSideAB   = sum(pointFromA .* edgeAB, 2);
rightSideAC   = sum(pointFromA .* edgeAC, 2);

% A 2-by-2 system has a closed-form answer (Cramer's rule), which works on
% whole columns without a loop. The determinant is zero only for a zero-area
% triangle; the project meshes have none (devdemo_cost_ICPLike2 checks
% this), so no special case is needed.
determinant   = gramABAB .* gramACAC - gramABAC .^ 2;
u = (gramACAC .* rightSideAB - gramABAC .* rightSideAC) ./ determinant;
v = (gramABAB .* rightSideAC - gramABAC .* rightSideAB) ./ determinant;

% With (u,v) known, the foot lies inside the triangle exactly when all three
% barycentric weights (1-u-v, u, v) are non-negative. For those pairs the
% plane projection is already the final answer.
isInside        = (u >= 0) & (v >= 0) & (u + v <= 1);
planeProjection = cornersA + u .* edgeAB + v .* edgeAC;

% Fill the outputs with the plane solution, but mark outside pairs as
% "no answer yet" with an infinite distance, so that any edge candidate
% found in step 2 will replace it.
closestPointsXYZ = planeProjection;
squaredDistances = sum((queryPointsXYZ - planeProjection) .^ 2, 2);
squaredDistances(~isInside) = inf;

%% STEP 2: FOR POINTS OUTSIDE, TAKE THE CLOSEST OF THE THREE EDGES

% A point whose foot fell outside the triangle is closest to the boundary.
% The boundary is three segments, A->B, B->C and C->A, listed here so one
% loop can treat them all the same way.
edgeStarts = {cornersA, cornersB, cornersC};
edgeEnds   = {cornersB, cornersC, cornersA};

for edgeIndex = 1:3
    % Pick the current edge for all pairs at once.
    edgeStart     = edgeStarts{edgeIndex};
    edgeDirection = edgeEnds{edgeIndex} - edgeStart;

    % Project onto the infinite line through the edge, then clamp the line
    % parameter to [0, 1] so the point stays on the segment. Clamping lands
    % on a corner when that is closest, so corners need no separate check.
    lineParameter = sum((queryPointsXYZ - edgeStart) .* edgeDirection, 2) ./ sum(edgeDirection .^ 2, 2);
    lineParameter = min(max(lineParameter, 0), 1);

    % Turn the clamped parameter back into a 3D point and measure how far
    % the query point is from it.
    edgePoint           = edgeStart + lineParameter .* edgeDirection;
    edgeSquaredDistance = sum((queryPointsXYZ - edgePoint) .^ 2, 2);

    % Keep this edge's point only for outside pairs where it beats the best
    % so far; inside pairs already hold the true minimum. The strict "<"
    % keeps the first edge on a tie (e.g. two edges meeting at one corner).
    isImproved = ~isInside & (edgeSquaredDistance < squaredDistances);
    closestPointsXYZ(isImproved, :) = edgePoint(isImproved, :);
    squaredDistances(isImproved)    = edgeSquaredDistance(isImproved);
end
end
