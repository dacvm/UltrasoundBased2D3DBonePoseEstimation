function required_value = requireStructField(parent_struct, field_name, field_label)
% requireStructField Return one required scalar object from decoded JSON.
%
% This helper centralizes object-field validation so every configuration error
% uses the same clear message and scalar-structure contract.
%
% Inputs:
%   parent_struct - Structure expected to contain the required field.
%   field_name    - Name of the field to read.
%   field_label   - Human-readable field path used in error messages.
%
% Outputs:
%   required_value - Scalar structure stored in the requested field.

    % Reject a missing parent field before dynamic field access can produce a
    % less helpful MATLAB error.
    if ~isstruct(parent_struct) || ~isscalar(parent_struct) ...
            || ~isfield(parent_struct, field_name)
        error('preprocess_markerstls:MissingConfigurationField', ...
            'Required configuration object "%s" is missing.', field_label);
    end

    % Read the field only after confirming the parent has the expected shape.
    required_value = parent_struct.(field_name);
    if ~isstruct(required_value) || ~isscalar(required_value)
        error('preprocess_markerstls:InvalidConfigurationField', ...
            'Configuration field "%s" must be one JSON object.', field_label);
    end
end
