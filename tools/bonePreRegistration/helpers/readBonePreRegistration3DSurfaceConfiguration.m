function configuration = readBonePreRegistration3DSurfaceConfiguration( ...
        configurationFilePath)
%READBONEPREREGISTRATION3DSURFACECONFIGURATION Read 3D registration settings.
% This function loads and validates the run-specific JSON paths needed by the
% 3D surface pre-registration script, keeping dataset choices out of its code.
%
% Input:
%   configurationFilePath - Path to the JSON configuration file to read.
%
% Output:
%   configuration - Scalar structure containing validated absolute input and
%                   output directories plus the three input MAT filenames.

% Report a missing file separately because it requires a different fix than
% malformed JSON or an incorrect field inside an existing configuration.
if ~isfile(configurationFilePath)
    error('bonePreRegistration:ConfigurationNotFound', ...
          'Configuration file was not found: %s', configurationFilePath);
end

% Include the source filename when JSON parsing fails so the configuration
% can be found quickly when several workflow JSON files are present.
try
    configurationText = fileread(configurationFilePath);
    rawConfiguration = jsondecode(configurationText);
catch configurationError
    error('bonePreRegistration:InvalidConfigurationJson', ...
          'Could not read configuration JSON "%s". Reason: %s', ...
          configurationFilePath, configurationError.message);
end

% The reader expects one object with named input and output sections rather
% than an array of alternative configurations.
if ~isstruct(rawConfiguration) || ~isscalar(rawConfiguration)
    error('bonePreRegistration:InvalidConfigurationRoot', ...
          'Configuration JSON must contain one object at its top level: %s', ...
          configurationFilePath);
end
inputConfiguration = requireConfigurationObject( ...
    rawConfiguration, 'input', 'input');
outputConfiguration = requireConfigurationObject( ...
    rawConfiguration, 'output', 'output');

% Read every required JSON value as nonempty text before resolving paths so
% errors identify the exact setting that needs correction.
ultrasoundImageFilePathSetting = requireConfigurationText( ...
    inputConfiguration, 'ultrasoundImageFilePath', ...
    'input.ultrasoundImageFilePath');
ultrasoundImageFileName = requireConfigurationText( ...
    inputConfiguration, 'ultrasoundImageFileName', ...
    'input.ultrasoundImageFileName');
boneSurfaceFilePathSetting = requireConfigurationText( ...
    inputConfiguration, 'boneSurfaceFilePath', ...
    'input.boneSurfaceFilePath');
boneSurfaceFileName = requireConfigurationText( ...
    inputConfiguration, 'boneSurfaceFileName', ...
    'input.boneSurfaceFileName');
boneLandmarksFilePathSetting = requireConfigurationText( ...
    inputConfiguration, 'boneLandmarksFilePath', ...
    'input.boneLandmarksFilePath');
boneLandmarksFileName = requireConfigurationText( ...
    inputConfiguration, 'boneLandmarksFileName', ...
    'input.boneLandmarksFileName');
coarseRegistrationOutputPathSetting = requireConfigurationText( ...
    outputConfiguration, 'coarseRegistrationOutputPath', ...
    'output.coarseRegistrationOutputPath');

% A configured filename must remain separate from its directory and must
% identify a MAT file because each input is loaded with MATLAB's LOAD.
validateMatFileName( ...
    ultrasoundImageFileName, 'input.ultrasoundImageFileName');
validateMatFileName(boneSurfaceFileName, 'input.boneSurfaceFileName');
validateMatFileName( ...
    boneLandmarksFileName, 'input.boneLandmarksFileName');

% Resolve relative directories beside the JSON file, matching the other tool
% configurations and making behavior independent of MATLAB's current folder.
configurationDirectory = fileparts(configurationFilePath);
ultrasoundImageFilePath = resolveConfigurationDirectory( ...
    ultrasoundImageFilePathSetting, configurationDirectory, ...
    'input.ultrasoundImageFilePath', false);
boneSurfaceFilePath = resolveConfigurationDirectory( ...
    boneSurfaceFilePathSetting, configurationDirectory, ...
    'input.boneSurfaceFilePath', false);
boneLandmarksFilePath = resolveConfigurationDirectory( ...
    boneLandmarksFilePathSetting, configurationDirectory, ...
    'input.boneLandmarksFilePath', false);
coarseRegistrationOutputPath = resolveConfigurationDirectory( ...
    coarseRegistrationOutputPathSetting, configurationDirectory, ...
    'output.coarseRegistrationOutputPath', true);

% Validate complete input paths before the main script loads large variables.
% This catches a mismatched directory and filename as one clear error.
validateInputFile(ultrasoundImageFilePath, ultrasoundImageFileName, ...
    'ultrasound image');
validateInputFile(boneSurfaceFilePath, boneSurfaceFileName, 'bone surface');
validateInputFile(boneLandmarksFilePath, boneLandmarksFileName, ...
    'bone landmarks');

% Preserve the JSON hierarchy in the result while returning absolute paths
% that the main workflow can pass directly to FULLFILE.
configuration = struct();
configuration.input = struct( ...
    'ultrasoundImageFilePath', ultrasoundImageFilePath, ...
    'ultrasoundImageFileName', ultrasoundImageFileName, ...
    'boneSurfaceFilePath', boneSurfaceFilePath, ...
    'boneSurfaceFileName', boneSurfaceFileName, ...
    'boneLandmarksFilePath', boneLandmarksFilePath, ...
    'boneLandmarksFileName', boneLandmarksFileName);
configuration.output = struct( ...
    'coarseRegistrationOutputPath', coarseRegistrationOutputPath);
end

function value = requireConfigurationObject(parent, fieldName, fieldPath)
%REQUIRECONFIGURATIONOBJECT Read one required scalar JSON object.
% This helper produces a direct configuration error for a missing section or
% a section whose JSON type cannot be accessed through named fields.
%
% Inputs:
%   parent    - Scalar structure expected to contain the requested object.
%   fieldName - MATLAB field name of the requested object.
%   fieldPath - Full JSON path to display in an error message.
%
% Output:
%   value - Requested scalar structure from the decoded JSON.

if ~isfield(parent, fieldName)
    error('bonePreRegistration:MissingConfigurationField', ...
          'Required configuration field "%s" is missing.', fieldPath);
end
value = parent.(fieldName);
if ~isstruct(value) || ~isscalar(value)
    error('bonePreRegistration:InvalidConfigurationObject', ...
          'Configuration field "%s" must contain one JSON object.', ...
          fieldPath);
end
end

function value = requireConfigurationText(parent, fieldName, fieldPath)
%REQUIRECONFIGURATIONTEXT Read one required nonempty JSON text value.
% This helper normalizes MATLAB character and string values so all later path
% operations receive the same text representation.
%
% Inputs:
%   parent    - Scalar structure expected to contain the requested text.
%   fieldName - MATLAB field name of the requested text.
%   fieldPath - Full JSON path to display in an error message.
%
% Output:
%   value - Trimmed nonempty character vector read from the JSON field.

if ~isfield(parent, fieldName)
    error('bonePreRegistration:MissingConfigurationField', ...
          'Required configuration field "%s" is missing.', fieldPath);
end
rawValue = parent.(fieldName);
if ~(ischar(rawValue) || ...
        (isstring(rawValue) && isscalar(rawValue) && ~ismissing(rawValue)))
    error('bonePreRegistration:InvalidConfigurationText', ...
          'Configuration field "%s" must contain one text value.', ...
          fieldPath);
end
value = strtrim(char(rawValue));
if isempty(value)
    error('bonePreRegistration:EmptyConfigurationText', ...
          'Configuration field "%s" must not be empty.', fieldPath);
end
end

function validateMatFileName(fileName, fieldPath)
%VALIDATEMATFILENAME Check one separately configured MAT filename.
% This helper prevents an embedded directory from overriding the matching
% path field and rejects files that MATLAB LOAD should not read here.
%
% Inputs:
%   fileName - Configured filename to validate.
%   fieldPath - Full JSON path to display in an error message.
%
% Outputs:
%   This function has no outputs. It throws an error for an invalid filename.

[embeddedDirectory, ~, fileExtension] = fileparts(fileName);
if ~isempty(embeddedDirectory) || ~strcmpi(fileExtension, '.mat')
    error('bonePreRegistration:InvalidConfiguredMatFileName', ...
          ['Configuration field "%s" must contain a MAT filename ' ...
           'without a directory: %s'], fieldPath, fileName);
end
end

function resolvedDirectory = resolveConfigurationDirectory( ...
        configuredDirectory, configurationDirectory, fieldPath, ...
        createIfMissing)
%RESOLVECONFIGURATIONDIRECTORY Resolve and validate one configured directory.
% Relative paths are anchored beside the JSON file so running the script from
% another current folder does not change its input or output locations.
%
% Inputs:
%   configuredDirectory  - Absolute or JSON-relative directory setting.
%   configurationDirectory - Directory that contains the JSON file.
%   fieldPath            - Full JSON path to display in an error message.
%   createIfMissing      - True when a missing output directory may be made.
%
% Output:
%   resolvedDirectory - Absolute or fully anchored directory path.

% Recognize Windows drive paths, UNC paths, and Unix-style absolute paths so
% machine-specific configurations remain usable without being re-anchored.
isWindowsAbsolute = ~isempty(regexp( ...
    configuredDirectory, '^[A-Za-z]:[\\/]', 'once'));
isUncAbsolute = startsWith(configuredDirectory, '\\') || ...
    startsWith(configuredDirectory, '//');
isUnixAbsolute = startsWith(configuredDirectory, '/');
if isWindowsAbsolute || isUncAbsolute || isUnixAbsolute
    resolvedDirectory = configuredDirectory;
else
    resolvedDirectory = fullfile( ...
        configurationDirectory, configuredDirectory);
end

% Only an output directory may be created automatically. Missing input
% directories indicate a configuration mistake and should stop immediately.
if ~isfolder(resolvedDirectory) && createIfMissing
    [directoryCreated, creationMessage] = mkdir(resolvedDirectory);
    if ~directoryCreated
        error('bonePreRegistration:OutputDirectoryCreationFailed', ...
              'Could not create configured directory "%s". Reason: %s', ...
              resolvedDirectory, creationMessage);
    end
elseif ~isfolder(resolvedDirectory)
    error('bonePreRegistration:ConfiguredDirectoryNotFound', ...
          'Configuration field "%s" identifies a missing directory: %s', ...
          fieldPath, resolvedDirectory);
end
end

function validateInputFile(inputDirectory, inputFileName, inputLabel)
%VALIDATEINPUTFILE Check that one configured input file exists.
% This helper validates the directory and filename as a pair before the main
% workflow attempts to load any data from that source.
%
% Inputs:
%   inputDirectory - Resolved directory that should contain the input file.
%   inputFileName  - Validated MAT filename configured for the input.
%   inputLabel     - Short human-readable input name for error messages.
%
% Outputs:
%   This function has no outputs. It throws an error when the file is absent.

inputFullPath = fullfile(inputDirectory, inputFileName);
if ~isfile(inputFullPath)
    error('bonePreRegistration:ConfiguredInputFileNotFound', ...
          'Configured %s file was not found: %s', ...
          inputLabel, inputFullPath);
end
end
