function textValues = requireConfigurationTextArray(parentObject, fieldName, fieldLabel)
%REQUIRECONFIGURATIONTEXTARRAY Return a required nonempty JSON string array.
% This helper preserves the JSON element order because the averaging loop
% should follow the order chosen in the configuration.
%
% Inputs:
%   parentObject - Scalar MATLAB struct decoded from the top-level JSON object.
%   fieldName    - Field name of the JSON string array.
%   fieldLabel   - User-facing field path included in error messages.
%
% Output:
%   textValues - Row cell array of trimmed, nonempty character vectors.

% Check field presence before converting the decoded array.
if ~isstruct(parentObject) ...
        || ~isscalar(parentObject) ...
        || ~isfield(parentObject, fieldName)
    error('build_ultrasoundBone_intersectionData:MissingConfigurationField', ...
        'Required configuration field "%s" is missing.', fieldLabel);
end
rawValues = parentObject.(fieldName);

% JSON string arrays normally decode as cell arrays of char vectors. Also
% accept MATLAB string vectors for compatibility with prepared structs.
if iscell(rawValues) && isvector(rawValues)
    textValues = rawValues(:).';
elseif isstring(rawValues) && isvector(rawValues)
    textValues = cellstr(rawValues(:).');
else
    error('build_ultrasoundBone_intersectionData:InvalidConfigurationField', ...
        'Configuration field "%s" must be a JSON string array.', ...
        fieldLabel);
end
if isempty(textValues)
    error('build_ultrasoundBone_intersectionData:InvalidConfigurationField', ...
        'Configuration field "%s" cannot be empty.', fieldLabel);
end

% Normalize every entry separately so one invalid item identifies its array
% index in the error.
for valueIndex = 1:numel(textValues)
    currentValue = textValues{valueIndex};
    if isstring(currentValue) && isscalar(currentValue)
        currentValue = char(currentValue);
    end
    if ~ischar(currentValue) || ~isrow(currentValue)
        error('build_ultrasoundBone_intersectionData:InvalidConfigurationField', ...
            ['Configuration field "%s" item %d must contain one text ' ...
             'value.'], ...
            fieldLabel, valueIndex);
    end

    currentValue = strtrim(currentValue);
    if isempty(currentValue)
        error('build_ultrasoundBone_intersectionData:InvalidConfigurationField', ...
            'Configuration field "%s" item %d cannot be empty.', ...
            fieldLabel, valueIndex);
    end
    textValues{valueIndex} = currentValue;
end
end
