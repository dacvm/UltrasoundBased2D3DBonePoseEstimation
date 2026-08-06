function objectValue = requireConfigurationObject( ...
        parentValue, fieldName, fieldLabel, errorNamespace)
%REQUIRECONFIGURATIONOBJECT Read one required scalar JSON object.
% This shared helper gives all bone-segmentation configuration readers the
% same object validation while retaining the calling script's error namespace.
%
% Inputs:
%   parentValue    - Structure expected to contain the required object.
%   fieldName      - MATLAB field name created by JSONDECODE.
%   fieldLabel     - User-facing JSON field path used in error messages.
%   errorNamespace - Calling script's error-identifier namespace.
%
% Output:
%   objectValue - Validated scalar structure stored in the requested field.

% Check field presence before dynamic access so the error identifies the
% missing configuration object directly.
if ~isfield(parentValue, fieldName)
    error([errorNamespace ':MissingConfigurationObject'], ...
          'Required configuration object "%s" is missing.', fieldLabel);
end

% Require exactly one structure because each JSON section is one named object.
objectValue = parentValue.(fieldName);
if ~isstruct(objectValue) || ~isscalar(objectValue)
    error([errorNamespace ':InvalidConfigurationObject'], ...
          'Configuration field "%s" must contain one object.', fieldLabel);
end
end
