function validateOutputBaseName(output_base_name)
% validateOutputBaseName Ensure one base safely forms all three output names.
%
% This helper prevents a configured output base name from silently creating
% paths, extensions, or platform-invalid filenames during export.
%
% Inputs:
%   output_base_name - Output basename without a directory or extension.
%
% Outputs:
%   None.

    % Identify path and extension components before checking platform-invalid
    % filename characters.
    [base_folder, parsed_base_name, base_extension] = fileparts(output_base_name);
    invalid_filename_characters = '<>:"/\|?*';

    % Reject paths, extensions, and characters that Windows cannot use in a
    % filename. This gives a clear configuration error before export begins.
    if ~isempty(base_folder) ...
            || ~isempty(base_extension) ...
            || ~strcmp(parsed_base_name, output_base_name) ...
            || any(ismember(output_base_name, invalid_filename_characters)) ...
            || isspace(output_base_name(end)) ...
            || output_base_name(end) == '.'
        error('preprocess_markerstls:InvalidOutputBaseName', ...
            ['Configuration field "output.base_name" must be a filename ' ...
             'without a directory, extension, trailing space, or special path characters.']);
    end
end
