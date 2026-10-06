function booleanValue = requireConfigurationBoolean( ...
        parentValue, fieldName, fieldLabel, errorNamespace)
%REQUIRECONFIGURATIONBOOLEAN Read one required JSON Boolean value.
% This shared helper ensures configuration switches use literal JSON true or
% false values so workflow behavior cannot depend on numeric or text aliases.
%
% Inputs:
%   parentValue    - Structure expected to contain the Boolean field.
%   fieldName      - MATLAB field name created by JSONDECODE.
%   fieldLabel     - User-facing JSON field path used in error messages.
%   errorNamespace - Calling script's error-identifier namespace.
%
% Output:
%   booleanValue - Logical scalar read from the requested field.

% Report an absent field separately so the user knows which configuration
% setting must be added.
if ~isfield(parentValue, fieldName)
    error([errorNamespace ':MissingConfigurationField'], ...
          'Required configuration field "%s" is missing.', fieldLabel);
end
booleanValue = parentValue.(fieldName);

% JSONDECODE returns literal JSON true and false values as MATLAB logicals.
% Requiring one scalar rejects numbers, text, and arrays.
if ~islogical(booleanValue) || ~isscalar(booleanValue)
    error([errorNamespace ':InvalidConfigurationBoolean'], ...
          'Configuration field "%s" must contain one Boolean value.', ...
          fieldLabel);
end
end
