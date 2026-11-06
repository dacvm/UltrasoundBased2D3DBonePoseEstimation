function stateVector = TMatrixToStateVector(T_CT_ref_candidate, T_CT_ref_initial, pivotPointRef)
%TMATRIXTOSTATEVECTOR Convert a CT-to-ref transform into an optimizer state.
% This is the inverse of stateVectorToTMatrix. It removes the initial coarse
% pose, reads the rotation about the pivot and the shift of the pivot, and
% returns the six values expected by the optimizer.
%
% Inputs:
%   T_CT_ref_candidate - Candidate 4-by-4 transform from CT to reference.
%   T_CT_ref_initial   - Initial 4-by-4 transform from CT to reference.
%   pivotPointRef      - 3-by-1 point in ref (mm) the rotation turns about;
%                        must be the same pivot used by stateVectorToTMatrix.
%
% Output:
%   stateVector        - Six-value vector [vx; vy; vz; wx; wy; wz]: v is the
%                        shift of the pivot in mm, w the rotation vector in
%                        radians about the pivot.

% Check the inputs before comparing the two poses.
validateattributes(T_CT_ref_candidate, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_CT_ref_candidate');
validateattributes(T_CT_ref_initial, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_CT_ref_initial');
validateattributes(pivotPointRef, {'numeric'}, ...
    {'size', [3 1], 'finite'}, mfilename, 'pivotPointRef');

% Remove the initial pose on the right because the forward move is
% applied on the left: T_CT_ref_candidate = T_delta_ref * T_CT_ref_initial.
T_delta_ref = T_CT_ref_candidate / T_CT_ref_initial;
R_delta_ref = T_delta_ref(1:3, 1:3);
t_delta_ref = T_delta_ref(1:3, 4);

% The matrix logarithm undoes expm and gives back the skew-symmetric matrix
% of the rotation vector. For a real rotation below 180 degrees it is real;
% real() only drops floating-point round-off.
rotationHatRef = real(logm(R_delta_ref));
rotationVectorRef = [rotationHatRef(3, 2); ...
                     rotationHatRef(1, 3); ...
                     rotationHatRef(2, 1)];

% The forward translation column is t = c - R*c + v, so v = t - c + R*c.
translationRef = t_delta_ref - pivotPointRef + R_delta_ref * pivotPointRef;

stateVector = [translationRef; rotationVectorRef];
end
