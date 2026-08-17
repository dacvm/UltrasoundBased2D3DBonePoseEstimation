function rotationErrorDeg = calculateRotationErrorDeg(T_bone_ref_groundTruth, T_bone_ref_estimate)
%CALCULATEROTATIONERRORDEG Calculate the shortest bone-orientation error.
% This function compares two bone-to-reference rotations using the
% geodesic angle on SO(3). The result is independent of Euler-angle order
% and reports the smallest rotation needed to align the estimate.
%
% Inputs:
%   T_bone_ref_groundTruth - Ground-truth 4-by-4 bone-to-reference transform.
%   T_bone_ref_estimate    - Estimated 4-by-4 bone-to-reference transform.
%
% Output:
%   rotationErrorDeg       - Smallest orientation difference in degrees.

% Confirm that both inputs have the matrix shape used by this project.
validateattributes(T_bone_ref_groundTruth, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_bone_ref_groundTruth');
validateattributes(T_bone_ref_estimate, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_bone_ref_estimate');

% Express the estimated orientation relative to the ground-truth orientation.
R_boneError = T_bone_ref_groundTruth(1:3, 1:3).' * ...
              T_bone_ref_estimate(1:3, 1:3);

% Convert the relative rotation matrix to its shortest rotation angle.
cosRotationError = (trace(R_boneError) - 1) / 2;

% Clamp tiny floating-point overshoots so acos always receives a valid value.
cosRotationError = max(-1, min(1, cosRotationError));
rotationErrorDeg = rad2deg(acos(cosRotationError));
end
