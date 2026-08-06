function resolved_file = resolveInputFile(parent_directory, configured_file, field_label)
% resolveInputFile Resolve and validate one file below its configured directory.
%
% This helper keeps input files relative to their configured directory and
% returns a canonical path after checking that each file exists.
%
% Inputs:
%   parent_directory - Checked directory containing the input file.
%   configured_file  - Relative filename or path fragment from the JSON.
%   field_label      - Human-readable field path used in error messages.
%
% Outputs:
%   resolved_file - Canonical absolute input-file path.

    % Individual input settings are filenames or relative path fragments.
    % Keeping directories separate prevents repeated marker paths in JSON.
    if isAbsolutePath(configured_file)
        error('preprocess_markerstls:AbsoluteFilenameNotAllowed', ...
            'Configuration field "%s" must be relative to its configured directory.', ...
            field_label);
    end

    % Build the candidate path below the already validated parent directory.
    candidate_file = fullfile(parent_directory, configured_file);
    if ~isfile(candidate_file)
        error('preprocess_markerstls:InputFileNotFound', ...
            'Configured input file "%s" was not found: %s', ...
            field_label, candidate_file);
    end

    % Return one normalized path for all downstream processing and provenance.
    resolved_file = canonicalExistingPath(candidate_file, field_label);
end
