function [doesIntersect, minimumMahalanobisDistanceSquared] = ...
    ellipsoidIntersectsOBB(Xposition3D, positionPrecision3D, ...
    maximumPositionError, node)
%ELLIPSOIDINTERSECTSOBB Test the P-IMLOP search ellipsoid against one node box.
%   P-IMLOP may skip a PD-tree node when no point inside that node's
%   oriented bounding box can have a positional error smaller than the
%   current best complete match error. This function performs that test by
%   finding the smallest Mahalanobis distance from X to the box.
%
%   The node box is easiest to describe in its own local coordinate frame:
%
%       node.boundsMinNode <= pointNode <= node.boundsMaxNode.
%
%   There are only three local coordinates. The closest point must therefore
%   be either inside the box, on one of its faces, on one of its edges, or at
%   one of its corners. The function checks these possibilities by allowing
%   each coordinate to be free, fixed at its lower limit, or fixed at its
%   upper limit. This gives only 3^3 = 27 small cases and avoids requiring an
%   optimization toolbox.
%
%   Inputs
%   ------
%   Xposition3D : 3-by-1 query position in the same 3D frame as the PD-tree.
%   positionPrecision3D : 3-by-3 inverse positional covariance in that frame.
%       If Sigma3D is the covariance, positionPrecision3D is inv(Sigma3D).
%   maximumPositionError : Nonnegative positional-error limit. In the
%       Stage 5 P-IMLOP search this is Ebest because the paper assumes that
%       the smallest possible orientation error in a node is zero.
%   node : One element of Psi.pdTree.nodes. The function uses T_node_CT,
%       boundsMinNode, and boundsMaxNode to describe its oriented box.
%
%   Outputs
%   -------
%   doesIntersect : True when the ellipsoid reaches or overlaps the node box.
%   minimumMahalanobisDistanceSquared : Smallest value of
%       (z-X)'*positionPrecision3D*(z-X) over all points z inside the box.
%
%   Example
%   -------
%       positionPrecision3D = eye(3);
%       [keepNode, minimumDistanceSquared] = ellipsoidIntersectsOBB( ...
%           X.position3D, positionPrecision3D, Ebest, currentNode);

% Transform X and the precision matrix into the node's local frame. The
% rotation inside T_node_CT maps node coordinates into the shared 3D frame,
% so its transpose performs the opposite change of coordinates.
R_node_3D     = node.T_node_CT(1:3, 1:3);
nodeOrigin3D  = node.T_node_CT(1:3, 4);
XpositionNode = R_node_3D.' * (double(Xposition3D) - nodeOrigin3D);

precisionNode = R_node_3D.' * double(positionPrecision3D) * R_node_3D;
precisionNode = 0.5 * (precisionNode + precisionNode.');

lowerBoundNode = node.boundsMinNode(:);
upperBoundNode = node.boundsMaxNode(:);

% Each state describes one possible location of the closest box point:
%   -1 means that coordinate is fixed at the lower box boundary;
%    0 means that coordinate is free;
%   +1 means that coordinate is fixed at the upper box boundary.
% Checking every combination covers the box interior, its faces, its edges,
% and its corners. The smallest feasible candidate is the true closest point.
coordinateStates = [-1, 0, 1];
minimumMahalanobisDistanceSquared = inf;

% A tiny tolerance accepts a free coordinate that lands just outside a box
% boundary because of normal floating-point round-off.
boxScale = max(1, norm(upperBoundNode - lowerBoundNode));
boundTolerance = 1e-12 * boxScale;

for stateX = coordinateStates
    for stateY = coordinateStates
        for stateZ = coordinateStates
            coordinateState = [stateX; stateY; stateZ];
            fixedCoordinateMask = coordinateState ~= 0;
            freeCoordinateMask  = ~fixedCoordinateMask;

            candidatePointNode = zeros(3, 1);
            candidatePointNode(coordinateState == -1) = ...
                lowerBoundNode(coordinateState == -1);
            candidatePointNode(coordinateState == 1) = ...
                upperBoundNode(coordinateState == 1);

            % On the selected face, edge, or interior, minimize the quadratic
            % Mahalanobis distance over the coordinates that remain free. Its
            % gradient is linear, so one small matrix solve gives the answer.
            if any(freeCoordinateMask)
                fixedResidualNode = candidatePointNode(fixedCoordinateMask) ...
                    - XpositionNode(fixedCoordinateMask);

                freePrecision = precisionNode( ...
                    freeCoordinateMask, freeCoordinateMask);
                fixedInfluence = precisionNode( ...
                    freeCoordinateMask, fixedCoordinateMask) ...
                    * fixedResidualNode;

                candidatePointNode(freeCoordinateMask) = ...
                    XpositionNode(freeCoordinateMask) ...
                    - freePrecision \ fixedInfluence;

                freeValues = candidatePointNode(freeCoordinateMask);
                freeLowerBounds = lowerBoundNode(freeCoordinateMask);
                freeUpperBounds = upperBoundNode(freeCoordinateMask);

                % This stationary point belongs to the current box feature
                % only when every free coordinate stays inside its interval.
                if any(freeValues < freeLowerBounds - boundTolerance) || ...
                        any(freeValues > freeUpperBounds + boundTolerance)
                    continue;
                end

                % Clamp only the accepted round-off-sized boundary excess so
                % the distance is evaluated at a point that is exactly in-box.
                candidatePointNode(freeCoordinateMask) = min( ...
                    max(freeValues, freeLowerBounds), freeUpperBounds);
            end

            candidateResidualNode = candidatePointNode - XpositionNode;
            candidateDistanceSquared = candidateResidualNode.' ...
                * precisionNode * candidateResidualNode;

            minimumMahalanobisDistanceSquared = min( ...
                minimumMahalanobisDistanceSquared, candidateDistanceSquared);
        end
    end
end

% Equation (8) writes the positional ellipsoid boundary as
%
%   (z-X)' * inv(Sigma) * (z-X) <= 2 * E_position,max.
%
% In Stage 5, E_position,max equals Ebest. Equality means tangency, which is
% still an intersection and must remain searchable.
ellipsoidLimitSquared = 2 * double(maximumPositionError);
comparisonTolerance = 1e-10 * max( ...
    [1, abs(ellipsoidLimitSquared), abs(minimumMahalanobisDistanceSquared)]);

doesIntersect = minimumMahalanobisDistanceSquared ...
    <= ellipsoidLimitSquared + comparisonTolerance;
end
