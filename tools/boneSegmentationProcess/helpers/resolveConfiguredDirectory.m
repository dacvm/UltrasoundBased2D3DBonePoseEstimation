function resolvedDirectory = resolveConfiguredDirectory( ...
        configuredDirectory, configurationDirectory, fieldLabel, ...
        createIfMissing, errorNamespace)
%RESOLVECONFIGUREDDIRECTORY Resolve and validate a configured directory.
% This shared helper anchors relative settings beside their JSON file and
% applies the same input/output directory rules across all three workflows.
%
% Inputs:
%   configuredDirectory   - Absolute path or path relative to the JSON file.
%   configurationDirectory - Directory containing the JSON configuration.
%   fieldLabel            - User-facing JSON field path used in errors.
%   createIfMissing       - Logical true when a missing directory may be made.
%   errorNamespace        - Calling script's error-identifier namespace.
%
% Output:
%   resolvedDirectory - Canonical absolute path to the usable directory.

% Preserve absolute settings and anchor only relative settings beside the
% configuration file.
if isAbsolutePath(configuredDirectory)
    candidateDirectory = configuredDirectory;
else
    candidateDirectory = fullfile( ...
        configurationDirectory, configuredDirectory);
end

% Input directories must already exist. Output directories may be created
% because clean source-control checkouts do not retain empty folders.
if ~isfolder(candidateDirectory)
    if ~createIfMissing
        error([errorNamespace ':ConfiguredDirectoryNotFound'], ...
              'Configured directory "%s" was not found: %s', ...
              fieldLabel, candidateDirectory);
    end
    [directoryCreated, creationMessage] = mkdir(candidateDirectory);
    if ~directoryCreated
        error([errorNamespace ':OutputDirectoryCreationFailed'], ...
              'Could not create configured directory "%s": %s', ...
              candidateDirectory, creationMessage);
    end
end

% Canonicalize the existing directory so saved provenance and later errors
% use a stable absolute path.
[pathFound, pathAttributes] = fileattrib(candidateDirectory);
if ~pathFound
    error([errorNamespace ':DirectoryResolutionFailed'], ...
          'Could not resolve configured directory "%s": %s', ...
          fieldLabel, candidateDirectory);
end
resolvedDirectory = pathAttributes.Name;
end
