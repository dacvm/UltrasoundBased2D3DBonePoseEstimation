function text_value = requireTextField(parent_struct, field_name, field_label)
% requireTextField Return one required, nonempty text value from decoded JSON.
%
% This helper normalizes JSON strings to MATLAB character rows and rejects
% missing, non-text, or empty settings before path processing uses them.
%
% Inputs:
%   parent_struct - Structure expected to contain the required field.
%   field_name    - Name of the field to read.
%   field_label   - Human-readable field path used in error messages.
%
% Outputs:
%   text_value - Nonempty character row stored in the requested field.

    % Reject a missing parent field before dynamic field access can produce a
    % less helpful MATLAB error.
    if ~isstruct(parent_struct) || ~isscalar(parent_struct) ...
            || ~isfield(parent_struct, field_name)
        error('preprocess_markerstls:MissingConfigurationField', ...
            'Required configuration field "%s" is missing.', field_label);
    end

    % Accept scalar JSON strings and character rows, which are the two text
    % representations that can arrive from jsondecode or direct MATLAB use.
    raw_value = parent_struct.(field_name);
    if isstring(raw_value) && isscalar(raw_value)
        text_value = char(raw_value);
    elseif ischar(raw_value) && isrow(raw_value)
        text_value = raw_value;
    else
        error('preprocess_markerstls:InvalidConfigurationField', ...
            'Configuration field "%s" must contain one text value.', field_label);
    end

    % Trim accidental surrounding whitespace and reject a value that becomes
    % empty after trimming.
    text_value = strtrim(text_value);
    if isempty(text_value)
        error('preprocess_markerstls:InvalidConfigurationField', ...
            'Configuration field "%s" cannot be empty.', field_label);
    end
end
