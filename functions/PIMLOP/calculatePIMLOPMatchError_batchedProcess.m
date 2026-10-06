function [E_match, details] = calculatePIMLOPMatchError_batchedProcess( ...
    X, Y, R_p, positionCovarianceImage, kappa)
%CALCULATEPIMLOPMATCHERROR_BATCHEDPROCESS Evaluate an array of matched pairs.
%   Row i of X is paired with row i of Y. This numerical-only counterpart of
%   calculatePIMLOPMatchError returns the same nonnegative Equation (7) cost.
%   Validation and covariance preparation are shared by the entire batch.
%   No graphics handles are constructed, even when details are requested.
%
%   Inputs
%   ------
%   X : Scalar structure with position3D (N-by-3) in the shared search frame
%       and normal2DImage (N-by-2) in local ultrasound image coordinates.
%   Y : Scalar structure with position3D (N-by-3) and normal3D (N-by-3), both
%       in the shared search frame. Each row belongs to the matching X row.
%   R_p : Proper 3-by-3 rotation from image coordinates to the search frame.
%   positionCovarianceImage : Shared symmetric positive-definite 3-by-3
%       positional covariance expressed in image coordinates.
%   kappa : Shared nonnegative orientation concentration.
%
%   Outputs
%   -------
%   E_match : N-by-1 Equation (7) costs; lower means more likely.
%   details : Scalar structure with row-based versions of the original
%       diagnostic fields. Covariances are shared 3-by-3 matrices, while
%       distances, angles, validity flags, and cost contributions have N rows.
%       These diagnostics are evaluated only when this output is requested.
%
%   Use this function for paired results. The search ranks query-by-triangle
%   blocks using their already computed positional errors and projected face
%   normals, then calls this function once for the winning correspondences.

% STEP 1: VALIDATE THE BATCH ONCE, INCLUDING ITS SHARED NOISE MODEL
validateattributes(X.position3D, {'numeric'}, {'real','finite','2d','ncols',3});
count = size(X.position3D,1);
validateattributes(X.normal2DImage, {'numeric'}, {'real','finite','size',[count 2]});
validateattributes(Y.position3D, {'numeric'}, {'real','finite','size',[count 3]});
validateattributes(Y.normal3D, {'numeric'}, {'real','finite','size',[count 3]});
validateattributes(R_p, {'numeric'}, {'real','finite','size',[3 3]});
validateattributes(positionCovarianceImage, {'numeric'}, {'real','finite','size',[3 3]});
validateattributes(kappa, {'numeric'}, {'real','finite','scalar','nonnegative'});
if norm(R_p.'*R_p-eye(3),'fro') > 1e-6 || abs(det(R_p)-1) > 1e-6
    error('calculatePIMLOPMatchError_batchedProcess:InvalidRotation','R_p must be a proper rotation.');
end
if norm(positionCovarianceImage-positionCovarianceImage.','fro') > 1e-10*max(1,norm(positionCovarianceImage,'fro'))
    error('calculatePIMLOPMatchError_batchedProcess:InvalidCovariance','Covariance must be symmetric.');
end
SigmaImage = 0.5*(double(positionCovarianceImage)+double(positionCovarianceImage).');
chol(SigmaImage);
Sigma3D = R_p*SigmaImage*R_p.';
Sigma3D = 0.5*(Sigma3D+Sigma3D.');
covarianceLower = chol(Sigma3D,'lower');

% STEP 2: CALCULATE POSITIONAL DISAGREEMENT FOR ALL PAIRED ROWS
% Row-vector division by L' is the transpose of the scalar solve L\d.
residual = double(Y.position3D)-double(X.position3D);
normalizedResidual = residual/covarianceLower.';
distanceSquared = sum(normalizedResidual.^2,2);
positionError = 0.5*distanceSquared;

% STEP 3: PROJECT AND RENORMALIZE THE MODEL NORMALS AS IN EQUATION (1)
% The measured normals stay in image coordinates. A zero projected model
% normal receives zero agreement, matching the original function's convention.
xLength = vecnorm(X.normal2DImage,2,2);
yLength = vecnorm(Y.normal3D,2,2);
if any(xLength <= 1e-12) || any(yLength <= 1e-12)
    error('calculatePIMLOPMatchError_batchedProcess:ZeroNormal','Normals must be nonzero.');
end
xNormal = double(X.normal2DImage)./xLength;
yNormal = double(Y.normal3D)./yLength;
yImage = yNormal*R_p;
projectedRaw = yImage(:,1:2);
projectedLength = vecnorm(projectedRaw,2,2);
defined = projectedLength > 1e-12;
projected = zeros(count,2);
projected(defined,:) = projectedRaw(defined,:)./projectedLength(defined);
cosine = min(1,max(-1,sum(projected.*xNormal,2)));
orientationMismatch = kappa*(1-cosine);
E_match = positionError+orientationMismatch;

% STEP 4: DESCRIBE ONLY THE REQUESTED RESULTS
% Ranking needs E_match alone. Angles, percentages, and explanatory fields
% are useful for the final selected pairs but unnecessary for every candidate.
if nargout > 1
    details = struct();
    details.E_position = positionError;
    details.E_orientation = -kappa*cosine;
    details.E_orientationMismatch = orientationMismatch;
    details.E_matchEquation3 = E_match-kappa;
    details.positionResidual3D = residual;
    details.mahalanobisDistance = sqrt(distanceSquared);
    details.mahalanobisDistanceSquared = distanceSquared;
    details.euclideanDistanceMm = vecnorm(residual,2,2);
    details.orientationCosine = cosine;
    details.orientationAngleDeg = rad2deg(acos(cosine));
    details.orientationChordDistance = vecnorm(projected-xNormal,2,2);
    details.projectedYNormal2DImage = projected;
    details.projectedYNormal2DImageUnnormalized = projectedRaw;
    details.projectedYNormalLength = projectedLength;
    details.projectionIsDefined = defined;
    details.positionCovarianceImage = SigmaImage;
    details.positionCovariance3D = Sigma3D;
    details.positionContributionPercent = zeros(count,1);
    details.orientationContributionPercent = zeros(count,1);
    positive = E_match > 0;
    details.positionContributionPercent(positive) = 100*positionError(positive)./E_match(positive);
    details.orientationContributionPercent(positive) = 100*orientationMismatch(positive)./E_match(positive);
end
end
