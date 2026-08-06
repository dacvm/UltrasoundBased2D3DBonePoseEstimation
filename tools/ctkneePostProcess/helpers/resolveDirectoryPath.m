function resolved_directory = resolveDirectoryPath( ...
        configured_directory, configuration_directory, field_label, create_if_missing)
% resolveDirectoryPath Make a configured directory absolute and validate it.
%
% This helper resolves relative directories beside the JSON file, optionally
% creates the output directory, and returns a canonical existing path.
%
% Inputs:
%   configured_directory  - Directory value read from the configuration.
%   configuration_directory - Directory containing the JSON configuration.
%   field_label           - Human-readable field path used in error messages.
%   create_if_missing     - True when a missing directory may be created.
%
% Outputs:
%   resolved_directory - Canonical absolute directory path.

    % Relative directories start beside the JSON file, which makes a copied
    % project configuration portable without depending on MATLAB's pwd.
    if isAbsolutePath(configured_directory)
        candidate_directory = configured_directory;
    else
        candidate_directory = fullfile(configuration_directory, configured_directory);
    end

    % Input directories must already exist. The output directory is the only
    % configured directory that the workflow is allowed to create.
    if ~isfolder(candidate_directory)
        if ~create_if_missing
            error('preprocess_markerstls:InputDirectoryNotFound', ...
                'Configured directory "%s" was not found: %s', ...
                field_label, candidate_directory);
        end

        % Create only the explicitly configured output directory when needed.
        [directory_created, creation_message] = mkdir(candidate_directory);
        if ~directory_created
            error('preprocess_markerstls:OutputDirectoryCreationFailed', ...
                'Could not create output directory "%s". Reason: %s', ...
                candidate_directory, creation_message);
        end
    end

    % Canonicalize the path so saved provenance does not depend on the current
    % MATLAB working directory or relative path spelling.
    resolved_directory = canonicalExistingPath(candidate_directory, field_label);
end
