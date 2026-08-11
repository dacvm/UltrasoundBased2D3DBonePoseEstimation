function requiredObject = requireConfigurationObject(parentObject, fieldName, fieldLabel)
%REQUIRECONFIGURATIONOBJECT Return one required scalar JSON object.
% This helper gives missing and incorrectly typed config sections a direct
% error instead of allowing an unclear field-access failure later.
%
% Inputs:
%   parentObject - Scalar MATLAB struct decoded from a JSON object.
%   fieldName    - Field name to read from parentObject.
%   fieldLabel   - User-facing field path included in error messages.
%
% Output:
%   requiredObject - Required scalar struct stored in the named field.

% Check both presence and type because nested config code assumes one object.
if ~isstruct(parentObject) ...
        || ~isscalar(parentObject) ...
        || ~isfield(parentObject, fieldName)
    error('build_ultrasoundBone_intersectionData:MissingConfigurationField', ...
        'Required configuration object "%s" is missing.', fieldLabel);
end
requiredObject = parentObject.(fieldName);
if ~isstruct(requiredObject) || ~isscalar(requiredObject)
    error('build_ultrasoundBone_intersectionData:InvalidConfigurationField', ...
        'Configuration field "%s" must contain one JSON object.', ...
        fieldLabel);
end
end
