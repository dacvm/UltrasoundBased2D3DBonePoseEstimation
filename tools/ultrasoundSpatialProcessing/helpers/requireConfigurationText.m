function textValue = requireConfigurationText(parentObject, fieldName, fieldLabel)
%REQUIRECONFIGURATIONTEXT Return one required nonempty JSON text value.
% This helper normalizes JSON text to a MATLAB character vector so later
% path and option checks use one predictable representation.
%
% Inputs:
%   parentObject - Scalar MATLAB struct decoded from a JSON object.
%   fieldName    - Field name to read from parentObject.
%   fieldLabel   - User-facing field path included in error messages.
%
% Output:
%   textValue - Trimmed, nonempty character vector from the named field.

% Report a missing value before trying to inspect its type.
if ~isstruct(parentObject) ...
        || ~isscalar(parentObject) ...
        || ~isfield(parentObject, fieldName)
    error('build_ultrasoundBone_intersectionData:MissingConfigurationField', ...
        'Required configuration field "%s" is missing.', fieldLabel);
end
rawValue = parentObject.(fieldName);

% Accept either MATLAB text type because jsondecode behavior can differ by
% release and JSON shape.
if isstring(rawValue) && isscalar(rawValue)
    textValue = char(rawValue);
elseif ischar(rawValue) && isrow(rawValue)
    textValue = rawValue;
else
    error('build_ultrasoundBone_intersectionData:InvalidConfigurationField', ...
        'Configuration field "%s" must contain one text value.', ...
        fieldLabel);
end
textValue = strtrim(textValue);
if isempty(textValue)
    error('build_ultrasoundBone_intersectionData:InvalidConfigurationField', ...
        'Configuration field "%s" cannot be empty.', fieldLabel);
end
end
