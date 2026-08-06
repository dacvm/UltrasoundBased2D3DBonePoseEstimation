function validateFileExtension(filename, expected_extension, field_label)
% validateFileExtension Catch accidental file-type selections in the JSON.
%
% This helper rejects input names with the wrong extension before file loading
% so configuration mistakes receive a direct message.
%
% Inputs:
%   filename          - Filename whose extension should be checked.
%   expected_extension - Required extension, including its leading dot.
%   field_label       - Human-readable field path used in the error message.
%
% Outputs:
%   None.

    % Compare extensions without case sensitivity because Windows filenames
    % commonly use mixed-case suffixes.
    [~, ~, actual_extension] = fileparts(filename);
    if ~strcmpi(actual_extension, expected_extension)
        error('preprocess_markerstls:InvalidInputExtension', ...
            'Configuration field "%s" must name a %s file.', ...
            field_label, expected_extension);
    end
end
