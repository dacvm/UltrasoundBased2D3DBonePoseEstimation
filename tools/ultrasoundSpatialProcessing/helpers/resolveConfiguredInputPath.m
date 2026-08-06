function resolvedPath = resolveConfiguredInputPath( ...
        configuredPath, configurationDirectory, fieldLabel, ...
        expectedKind, expectedExtension)
%RESOLVECONFIGUREDINPUTPATH Resolve and validate one configured input path.
% Relative paths are anchored beside the JSON file so configuration behavior
% does not depend on MATLAB's current working directory.
%
% Inputs:
%   configuredPath        - Absolute path or path relative to the JSON file.
%   configurationDirectory - Directory containing the JSON configuration.
%   fieldLabel            - User-facing field name for error messages.
%   expectedKind          - Expected path kind: 'file' or 'directory'.
%   expectedExtension     - Required file extension, or empty for a directory.
%
% Output:
%   resolvedPath - Canonical absolute path to the existing input.

% Build the candidate path without changing already absolute settings.
if isAbsolutePath(configuredPath)
    candidatePath = configuredPath;
else
    candidatePath = fullfile(configurationDirectory, configuredPath);
end

% File settings include an extension check so selecting the wrong input type
% is reported before the workflow calls a specialized reader.
if strcmp(expectedKind, 'file')
    [~, ~, actualExtension] = fileparts(candidatePath);
    if ~strcmpi(actualExtension, expectedExtension)
        error('build_ultrasoundBone_intersectionData:InvalidInputExtension', ...
            'Configuration field "%s" must identify a %s file.', ...
            fieldLabel, expectedExtension);
    end
    inputExists = isfile(candidatePath);
elseif strcmp(expectedKind, 'directory')
    inputExists = isfolder(candidatePath);
else
    error('build_ultrasoundBone_intersectionData:InvalidExpectedPathKind', ...
        'Internal path kind "%s" is not supported.', expectedKind);
end
if ~inputExists
    error('build_ultrasoundBone_intersectionData:ConfiguredInputNotFound', ...
        'Configured input "%s" was not found: %s', ...
        fieldLabel, candidatePath);
end

% Canonicalize the existing path for stable error messages and provenance.
[pathFound, pathAttributes] = fileattrib(candidatePath);
if ~pathFound
    error('build_ultrasoundBone_intersectionData:PathResolutionFailed', ...
        'Could not resolve configured input "%s": %s', ...
        fieldLabel, candidatePath);
end
resolvedPath = pathAttributes.Name;
end
