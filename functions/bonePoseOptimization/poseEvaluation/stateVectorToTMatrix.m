function T_CT_ref_candidate = stateVectorToTMatrix(stateVector, T_CT_ref_initial, pivotPointRef)
%STATEVECTORTOTMATRIX Convert an optimizer state into a CT-to-ref transform.
% The optimizer stores a small six-value correction around the coarse
% registration. This function turns that correction into a rigid move of
% the bone in the reference frame and applies it to the start pose.
%
% Why a pivot point: a rotation matrix on its own turns points about the
% origin of the frame. The ref origin can be hundreds of millimetres away
% from the bone, so one degree there would swing the bone several
% millimetres sideways. The correction therefore rotates the bone about
% pivotPointRef, a fixed point at the centre of the bone. That way the
% three rotation values only turn the bone about itself, and the three
% translation values only shift it.
%
% The move applied to a point p in ref is
%     p_new = R*(p - c) + c + v = R*p + (c - R*c + v),
% with c = pivotPointRef: shift so the pivot sits at the origin, rotate,
% shift back, then add the requested translation.
%
% Inputs:
%   stateVector      - Six-value vector [vx; vy; vz; wx; wy; wz].
%                      v is the shift of the pivot in mm along the ref
%                      axes. w is a rotation vector in radians (direction =
%                      rotation axis along ref axes, length = angle), turning
%                      about the pivot.
%   T_CT_ref_initial - Initial 4-by-4 transform from CT to reference.
%   pivotPointRef    - 3-by-1 point in ref (mm) the rotation turns about.
%                      It is fixed for the whole run (data.pivotPointRef).
%
% Output:
%   T_CT_ref_candidate - Candidate 4-by-4 transform from CT to reference.

% Check the flat optimizer input before building its matrix representation.
validateattributes(stateVector, {'numeric'}, ...
    {'vector', 'numel', 6, 'finite'}, mfilename, 'stateVector');
validateattributes(T_CT_ref_initial, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_CT_ref_initial');
validateattributes(pivotPointRef, {'numeric'}, ...
    {'size', [3 1], 'finite'}, mfilename, 'pivotPointRef');

% Use one column-vector convention throughout the optimizer interface.
stateVector       = stateVector(:);
translationRef    = stateVector(1:3);
rotationVectorRef = stateVector(4:6);

% Turn the rotation vector into a rotation matrix. The skew-symmetric
% matrix of w, passed through the matrix exponential, gives the rotation
% by angle |w| about the axis w / |w| (Rodrigues' formula).
rotationHatRef = [0,                    -rotationVectorRef(3),  rotationVectorRef(2); ...
                  rotationVectorRef(3),  0,                   -rotationVectorRef(1); ...
                 -rotationVectorRef(2),  rotationVectorRef(1), 0];
R_delta_ref = expm(rotationHatRef);

% Build the move p_new = R*p + (c - R*c + v). The translation column holds
% everything that does not depend on p: undoing the pivot's own swing
% (c - R*c) plus the requested shift v. A pure rotation therefore leaves
% the pivot where it is, and a pure translation moves it by exactly v.
t_delta_ref = pivotPointRef - R_delta_ref * pivotPointRef + translationRef;
T_delta_ref = [R_delta_ref, t_delta_ref; 0 0 0 1];

% Apply the move on the left: first place CT in ref with the start pose,
% then move the bone in ref.
T_CT_ref_candidate = T_delta_ref * T_CT_ref_initial;
end
