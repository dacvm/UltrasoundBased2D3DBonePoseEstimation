function normalizedPlace = normalizePinPlace(rawPlace, boneCode, fieldLabel)
%NORMALIZEPINPLACE Normalize and validate one configured bone-pin location.
% The normalized place is used both for CT pin selection and for building the
% matching motion-capture table variable, so both systems stay consistent.
%
% Inputs:
%   rawPlace   - Nonempty configured pin-location text.
%   boneCode   - Bone code used in the rigid-body name, such as F or T.
%   fieldLabel - User-facing configuration field path for error messages.
%
% Output:
%   normalizedPlace - Uppercase pin-location character vector.

% Uppercase the place because CT and motion-capture identifiers use the same
% case-insensitive convention.
normalizedPlace = upper(strtrim(rawPlace));
candidateRigidBodyName = sprintf('C_%s_%s', boneCode, normalizedPlace);

% The CSV reader stores rigid bodies as table variable names, so the generated
% name must be valid for dynamic table access.
if ~isvarname(candidateRigidBodyName)
    error('build_ultrasoundBone_intersectionData:InvalidPinSelection', ...
        ['Configuration field "%s" creates invalid rigid-body name ' ...
         '"%s".'], ...
        fieldLabel, candidateRigidBodyName);
end
end
