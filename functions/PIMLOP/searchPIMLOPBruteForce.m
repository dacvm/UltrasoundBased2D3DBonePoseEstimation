function [Ybest, Ebest, searchDetails] = searchPIMLOPBruteForce( ...
    X, Psi, R_p, positionCovarianceImage, kappa)
%SEARCHPIMLOPBRUTEFORCE Find the best P-IMLOP mesh match by checking all faces.
%   This function is a deliberately simple correctness reference for the
%   future PD-tree search. It visits every valid triangle in Psi, finds the
%   most likely position on that triangle, evaluates the full P-IMLOP match
%   error, and returns the candidate with the smallest error.
%
%   Brute-force search is slower than a PD-tree, but its direct loop is easy
%   to inspect. Later stages can prove that an accelerated tree search is
%   correct by requiring it to return the same Y and Ebest as this function.
%
%   Inputs
%   ------
%   X : Scalar projection-oriented measurement structure with:
%       position3D   - 3-by-1 point in the shared 3D search frame;
%       normal2DImage - 2-by-1 normal in local ultrasound image X-Y.
%   Psi : Complete P-IMLOP model structure prepared by preparePIMLOPModel.
%       Psi.mesh, Psi.faceNormals, and Psi.validFaceMask must all describe
%       the same mesh in the same 3D search frame as X.
%   R_p : 3-by-3 rotation from the local ultrasound image frame into the
%       shared 3D search frame.
%   positionCovarianceImage : 3-by-3 position covariance in the local image
%       X-Y-Z frame.
%   kappa : Nonnegative von Mises concentration for orientation matching.
%
%   Outputs
%   -------
%   Ybest : Best oriented model point with:
%       position3D - 3-by-1 point on the winning triangle;
%       normal3D   - 3-by-1 unit face normal;
%       faceIndex  - original row in Psi.mesh.ConnectivityList.
%   Ebest : Smallest nonnegative Equation (7) match error.
%   searchDetails : Diagnostic structure containing the number of evaluated
%       faces, elapsed time, winning barycentric coordinates, and the
%       calculatePIMLOPMatchError details for the winning candidate.
%
%   Example
%   -------
%       [Ybest, Ebest, details] = searchPIMLOPBruteForce( ...
%           XqueryCT, PsiCT, R_image_CT, SigmaImage, 50);

boneFaces      = Psi.mesh.ConnectivityList;
bonePoints3D   = double(Psi.mesh.Points);
validFaceIndices = find(Psi.validFaceMask);

% Rotate the measurement covariance once into the shared search frame. The
% same covariance is used to find the best position on every triangle.
positionCovariance3D = R_p * double(positionCovarianceImage) * R_p.';
positionCovariance3D = 0.5 * (positionCovariance3D + positionCovariance3D.');

Ebest = inf;
Ybest = struct('position3D', zeros(3, 1), 'normal3D', zeros(3, 1), 'faceIndex', 0);
bestBarycentricCoordinates = nan(3, 1);
bestMatchDetails = struct();
searchTimer = tic;

for validFaceNumber = 1:numel(validFaceIndices)
    faceIndex = validFaceIndices(validFaceNumber);
    triangleVertices3D = bonePoints3D(boneFaces(faceIndex, :), :);

    % The candidate position is allowed to move anywhere on this triangle.
    % Its orientation is the triangle's constant unit face normal.
    [candidatePosition3D, candidateBarycentricCoordinates] = ...
        findMostLikelyPointOnTriangle( ...
        X.position3D, triangleVertices3D, positionCovariance3D);
    Ycandidate = struct();
    Ycandidate.position3D = candidatePosition3D;
    Ycandidate.normal3D   = Psi.faceNormals(faceIndex, :).';

    [candidateError, candidateDetails] = calculatePIMLOPMatchError( ...
        X, Ycandidate, R_p, positionCovarianceImage, kappa);

    if candidateError < Ebest
        Ebest = candidateError;
        Ybest.position3D = candidatePosition3D;
        Ybest.normal3D   = Ycandidate.normal3D;
        Ybest.faceIndex  = faceIndex;
        bestBarycentricCoordinates = candidateBarycentricCoordinates;
        bestMatchDetails = candidateDetails;
    end
end

searchDetails = struct();
searchDetails.numberOfFacesEvaluated       = numel(validFaceIndices);
searchDetails.elapsedSeconds               = toc(searchTimer);
searchDetails.barycentricCoordinates       = bestBarycentricCoordinates;
searchDetails.matchDetails                 = bestMatchDetails;
end
