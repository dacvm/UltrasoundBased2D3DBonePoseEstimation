function translationErrorMm = calculateTranslationErrorMm(T_bone_ref_groundTruth, T_bone_ref_estimate)
%CALCULATETRANSLATIONERRORMM Calculate bone-origin translation error.
% This function compares two bone-to-reference transforms and returns the
% distance between their origins. The value is needed to report how far the
% estimated bone position is from the ground-truth position.
%
% Inputs:
%   T_bone_ref_groundTruth - Ground-truth 4-by-4 bone-to-reference transform.
%   T_bone_ref_estimate    - Estimated 4-by-4 bone-to-reference transform.
%
% Output:
%   translationErrorMm     - Euclidean origin distance in millimetres.

% Confirm that both inputs have the matrix shape used by this project.
validateattributes(T_bone_ref_groundTruth, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_bone_ref_groundTruth');
validateattributes(T_bone_ref_estimate, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_bone_ref_estimate');

% Compare the two bone origins in the shared reference frame.
translationDifferenceRef = T_bone_ref_estimate(1:3, 4) - T_bone_ref_groundTruth(1:3, 4);
translationErrorMm = norm(translationDifferenceRef);
end
