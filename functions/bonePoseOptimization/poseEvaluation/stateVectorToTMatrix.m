function T_CT_ref_candidate = stateVectorToTMatrix(stateVector, T_CT_ref_initial)
%STATEVECTORTOTMATRIX Convert an optimizer state into a CT-to-ref transform.
% The optimizer stores a small six-value correction around the coarse
% registration. This function maps that correction to SE(3) and applies it
% on the left, so the correction is expressed in the reference frame.
%
% Inputs:
%   stateVector      - Six-value vector [vx; vy; vz; wx; wy; wz].
%                      Translation uses mesh units and rotation uses radians.
%   T_CT_ref_initial - Initial 4-by-4 transform from CT to reference.
%
% Output:
%   T_CT_ref_candidate - Candidate 4-by-4 transform from CT to reference.

% Check the flat optimizer input before building its matrix representation.
validateattributes(stateVector, {'numeric'}, ...
    {'vector', 'numel', 6, 'finite'}, mfilename, 'stateVector');
validateattributes(T_CT_ref_initial, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_CT_ref_initial');

% Use one column-vector convention throughout the optimizer interface.
stateVector = stateVector(:);
translationRef = stateVector(1:3);
rotationVectorRef = stateVector(4:6);

% Convert the rotation vector into the skew-symmetric block of an se(3) matrix.
rotationHatRef = [0,                    -rotationVectorRef(3),  rotationVectorRef(2); ...
                  rotationVectorRef(3),  0,                   -rotationVectorRef(1); ...
                 -rotationVectorRef(2),  rotationVectorRef(1), 0];
twistHatRef = [rotationHatRef, translationRef; 0 0 0 0];

% Map the correction onto SE(3), then apply it in the reference frame.
T_delta_ref = expm(twistHatRef);
T_CT_ref_candidate = T_delta_ref * T_CT_ref_initial;
end
