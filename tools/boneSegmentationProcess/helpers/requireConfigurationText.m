function textValue = requireConfigurationText( ...
        parentValue, fieldName, fieldLabel, errorNamespace)
%REQUIRECONFIGURATIONTEXT Read one required nonempty JSON text value.
% This shared helper normalizes JSON text for all bone-segmentation workflows
% while retaining the calling script's error-identifier namespace.
%
% Inputs:
%   parentValue    - Structure expected to contain the required text field.
%   fieldName      - MATLAB field name created by JSONDECODE.
%   fieldLabel     - User-facing JSON field path used in error messages.
%   errorNamespace - Calling script's error-identifier namespace.
%
% Output:
%   textValue - Trimmed, nonempty character vector from the requested field.

% Stop before type conversion when the field is absent so the error points
% directly to the missing JSON setting.
if ~isfield(parentValue, fieldName)
    error([errorNamespace ':MissingConfigurationField'], ...
          'Required configuration field "%s" is missing.', fieldLabel);
end
rawValue = parentValue.(fieldName);

% Accept either MATLAB text representation but reject arrays and non-text
% values that cannot represent one path or option.
isCharacterText = ischar(rawValue) && isrow(rawValue);
isScalarString = isstring(rawValue) && isscalar(rawValue);
if ~isCharacterText && ~isScalarString
    error([errorNamespace ':InvalidConfigurationText'], ...
          'Configuration field "%s" must contain one text value.', ...
          fieldLabel);
end

% Remove accidental surrounding whitespace and reject a value that becomes
% empty after normalization.
textValue = strtrim(char(rawValue));
if isempty(textValue)
    error([errorNamespace ':EmptyConfigurationText'], ...
          'Configuration field "%s" cannot be empty.', fieldLabel);
end
end
