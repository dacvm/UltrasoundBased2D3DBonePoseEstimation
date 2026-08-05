clear; clc; close all;

%% LOAD AND VALIDATE THE CONFIGURATION

% Locate this script first so configuration paths do not depend on MATLAB's
% current working folder.
scriptFullPath = mfilename('fullpath');
if isempty(scriptFullPath)
    error('boneSegmentation_semiAutomatic:ScriptPathUnavailable', ...
          'Run boneSegmentation_semiAutomatic.m as a complete script so its configuration file can be located.');
end
segmentationToolDirectory = fileparts(scriptFullPath);

% Keep dataset-specific settings in the tool-local JSON file. Changing the
% input dataset therefore does not require editing this processing script.
configurationFilePath = fullfile(segmentationToolDirectory, 'configs', 'boneSegmentation_semiAutomatic.json');
configuration = readBoneSegmentationConfiguration(configurationFilePath);

% Use short names in the workflow below while preserving the names used in
% the JSON file inside the validated configuration structure.
filepath_ultrasoundimage    = configuration.input.ultrasoundImageFilePath;
filename_ultrasoundimage    = configuration.input.ultrasoundImageFileName;
segmentationOutputDirectory = configuration.output.segmentationOutputPath;

%% LOAD THE ULTRASOUND IMAGE DATA

% Load the MAT-file into a structure so its saved variable does not appear
% directly in the script workspace under an unknown name.
ultrasoundFilePath = fullfile(filepath_ultrasoundimage, filename_ultrasoundimage);
ultrasoundFileData = load(ultrasoundFilePath);

% Require one saved variable so the script cannot silently choose the wrong
% data when a MAT-file contains unrelated values.
savedVariableNames = fieldnames(ultrasoundFileData);
if numel(savedVariableNames) ~= 1
    error('boneSegmentation_semiAutomatic:UnexpectedUltrasoundVariables', ...
          'Expected exactly one variable in "%s", but found %d.', ...
          filename_ultrasoundimage, numel(savedVariableNames));
end

% Give the loaded sequence one stable name for the segmentation workflow.
ultrasoundSequence = ultrasoundFileData.(savedVariableNames{1});
clear ultrasoundFileData savedVariableNames;

%% PREPARE THE TOOL PATHS

% Resolve the shared functions folder from this tool so the script works
% when MATLAB starts in another current folder.
projectDirectory   = fileparts(fileparts(segmentationToolDirectory));
functionsDirectory = fullfile(projectDirectory, 'functions');
if ~isfolder(functionsDirectory)
    error('boneSegmentation_semiAutomatic:FunctionsDirectoryNotFound', ...
          'Required functions directory was not found: %s', ...
          functionsDirectory);
end

% Add only the direct functions directory because launchBoneSegmentationTools
% is a project function stored at that level.
addpath(functionsDirectory);

%% LAUNCH THE SEMI-AUTOMATIC SEGMENTATION TOOL

% Open the non-blocking browser. Its callbacks keep the processing state
% alive after this script finishes running.
[segmentationFigure, segmentationResults] = launchBoneSegmentationTools(ultrasoundSequence, segmentationOutputDirectory);






%% HELPER: READ CONFIGURATION

function configuration = readBoneSegmentationConfiguration(configurationFilePath)
%READBONESEGMENTATIONCONFIGURATION Load and validate segmentation settings.
% This function reads dataset-specific paths from JSON so the segmentation
% script stays unchanged when a different ultrasound file is selected.
%
% Input:
%   configurationFilePath - Path to the JSON configuration file.
%
% Output:
%   configuration - Scalar structure containing validated absolute input
%                   and output paths plus the ultrasound MAT-file name.

% Report a missing configuration separately from malformed JSON because the
% two problems require different corrections from the user.
if ~isfile(configurationFilePath)
    error('boneSegmentation_semiAutomatic:ConfigurationNotFound', ...
          'Configuration file was not found: %s', configurationFilePath);
end

% Include the source path in parsing failures so the user knows exactly
% which file must be corrected.
try
    configurationText = fileread(configurationFilePath);
    rawConfiguration = jsondecode(configurationText);
catch configurationError
    error('boneSegmentation_semiAutomatic:InvalidConfigurationJson', ...
          'Could not read configuration JSON "%s". Reason: %s', ...
          configurationFilePath, configurationError.message);
end

% Require one JSON object because the remaining validation expects named
% input and output sections rather than an array of configurations.
if ~isstruct(rawConfiguration) || ~isscalar(rawConfiguration)
    error('boneSegmentation_semiAutomatic:InvalidConfigurationRoot', ...
          'Configuration JSON must contain one object at its top level: %s', ...
          configurationFilePath);
end

% Validate the two sections before reading their nested settings. This gives
% a direct error when a section name is missing or has the wrong JSON type.
inputConfiguration = requireConfigurationObject( ...
    rawConfiguration, 'input', 'input');
outputConfiguration = requireConfigurationObject( ...
    rawConfiguration, 'output', 'output');

% Read nonempty text first so path errors can name the exact JSON field that
% supplied the invalid value.
ultrasoundImageFilePathSetting = requireConfigurationText( ...
    inputConfiguration, 'ultrasoundImageFilePath', ...
    'input.ultrasoundImageFilePath');
ultrasoundImageFileName = requireConfigurationText( ...
    inputConfiguration, 'ultrasoundImageFileName', ...
    'input.ultrasoundImageFileName');
segmentationOutputPathSetting = requireConfigurationText( ...
    outputConfiguration, 'segmentationOutputPath', ...
    'output.segmentationOutputPath');

% A separate configured filename must not contain a parent path. Keeping the
% directory and filename roles distinct prevents FULLFILE from ignoring or
% unexpectedly extending the configured input directory.
[fileParent, ~, fileExtension] = fileparts(ultrasoundImageFileName);
if ~isempty(fileParent)
    error('boneSegmentation_semiAutomatic:InvalidUltrasoundFileName', ...
          ['Configuration field "input.ultrasoundImageFileName" must ' ...
           'contain a filename only, without a directory.']);
end
if ~strcmpi(fileExtension, '.mat')
    error('boneSegmentation_semiAutomatic:InvalidUltrasoundFileExtension', ...
          ['Configuration field "input.ultrasoundImageFileName" must ' ...
           'identify a MAT-file.']);
end

% Resolve relative paths beside the JSON file so running MATLAB from another
% current folder does not change which input and output folders are used.
configurationDirectory = fileparts(configurationFilePath);
ultrasoundImageFilePath = resolveConfiguredDirectory( ...
    ultrasoundImageFilePathSetting, configurationDirectory, ...
    'input.ultrasoundImageFilePath', false);
segmentationOutputPath = resolveConfiguredDirectory( ...
    segmentationOutputPathSetting, configurationDirectory, ...
    'output.segmentationOutputPath', true);

% Check the combined input after validating its two parts so a missing file
% produces an error that displays the complete resolved path.
ultrasoundImageFullPath = fullfile( ...
    ultrasoundImageFilePath, ultrasoundImageFileName);
if ~isfile(ultrasoundImageFullPath)
    error('boneSegmentation_semiAutomatic:UltrasoundFileNotFound', ...
          'Configured ultrasound image file was not found: %s', ...
          ultrasoundImageFullPath);
end

% Return the same input/output hierarchy used by the JSON file, but with its
% directory settings normalized to absolute paths for the main workflow.
configuration = struct();
configuration.input = struct( ...
    'ultrasoundImageFilePath', ultrasoundImageFilePath, ...
    'ultrasoundImageFileName', ultrasoundImageFileName);
configuration.output = struct( ...
    'segmentationOutputPath', segmentationOutputPath);
end


%% HELPER: REQUIRE CONFIGURATION OBJECT

function objectValue = requireConfigurationObject(parentValue, fieldName, fieldLabel)
%REQUIRECONFIGURATIONOBJECT Read one required scalar JSON object.
% This helper gives missing or incorrectly typed configuration sections a
% clear error before code tries to access their nested fields.
%
% Inputs:
%   parentValue - Structure expected to contain the required object.
%   fieldName   - MATLAB field name created by JSONDECODE.
%   fieldLabel  - User-facing JSON field path used in error messages.
%
% Output:
%   objectValue - Validated scalar structure stored in the requested field.

% Check both presence and type because later code expects one named object.
if ~isfield(parentValue, fieldName)
    error('boneSegmentation_semiAutomatic:MissingConfigurationObject', ...
          'Required configuration object "%s" is missing.', fieldLabel);
end
objectValue = parentValue.(fieldName);
if ~isstruct(objectValue) || ~isscalar(objectValue)
    error('boneSegmentation_semiAutomatic:InvalidConfigurationObject', ...
          'Configuration field "%s" must contain one object.', fieldLabel);
end
end


%% HELPER: REQUIRE CONFIGURATION TEXT

function textValue = requireConfigurationText(parentValue, fieldName, fieldLabel)
%REQUIRECONFIGURATIONTEXT Read one required nonempty JSON text value.
% This helper normalizes strings to character vectors so MATLAB path
% functions receive one consistent text type.
%
% Inputs:
%   parentValue - Structure expected to contain the required text field.
%   fieldName   - MATLAB field name created by JSONDECODE.
%   fieldLabel  - User-facing JSON field path used in error messages.
%
% Output:
%   textValue - Trimmed, nonempty character vector from the requested field.

% Stop before type conversion when the field is absent so the message points
% directly to the missing JSON setting.
if ~isfield(parentValue, fieldName)
    error('boneSegmentation_semiAutomatic:MissingConfigurationField', ...
          'Required configuration field "%s" is missing.', fieldLabel);
end
rawValue = parentValue.(fieldName);

% Accept either MATLAB text type because JSONDECODE behavior can vary between
% MATLAB releases, but reject arrays that cannot represent one path value.
isCharacterText = ischar(rawValue) && isrow(rawValue);
isScalarString = isstring(rawValue) && isscalar(rawValue);
if ~isCharacterText && ~isScalarString
    error('boneSegmentation_semiAutomatic:InvalidConfigurationText', ...
          'Configuration field "%s" must contain one text value.', ...
          fieldLabel);
end
textValue = strtrim(char(rawValue));
if isempty(textValue)
    error('boneSegmentation_semiAutomatic:EmptyConfigurationText', ...
          'Configuration field "%s" cannot be empty.', fieldLabel);
end
end


%% HELPER: RESOLVE CONFIGURED DIRECTORY

function resolvedDirectory = resolveConfiguredDirectory( ...
        configuredDirectory, configurationDirectory, fieldLabel, ...
        createIfMissing)
%RESOLVECONFIGUREDDIRECTORY Resolve and validate one configured directory.
% Relative paths are anchored beside the JSON file so configuration behavior
% remains independent of MATLAB's current folder.
%
% Inputs:
%   configuredDirectory  - Absolute path or path relative to the JSON file.
%   configurationDirectory - Directory containing the JSON configuration.
%   fieldLabel           - User-facing JSON field path for error messages.
%   createIfMissing      - Logical true when a missing directory may be made.
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

% Input folders must already exist. Output folders may be created because a
% clean checkout does not retain empty output directories in source control.
if ~isfolder(candidateDirectory)
    if ~createIfMissing
        error('boneSegmentation_semiAutomatic:ConfiguredDirectoryNotFound', ...
              'Configured directory "%s" was not found: %s', ...
              fieldLabel, candidateDirectory);
    end
    [directoryCreated, creationMessage] = mkdir(candidateDirectory);
    if ~directoryCreated
        error('boneSegmentation_semiAutomatic:OutputDirectoryCreationFailed', ...
              'Could not create configured directory "%s": %s', ...
              candidateDirectory, creationMessage);
    end
end

% Canonicalize the existing directory for stable paths in later errors and
% in the segmentation tool's saved output metadata.
[pathFound, pathAttributes] = fileattrib(candidateDirectory);
if ~pathFound
    error('boneSegmentation_semiAutomatic:DirectoryResolutionFailed', ...
          'Could not resolve configured directory "%s": %s', ...
          fieldLabel, candidateDirectory);
end
resolvedDirectory = pathAttributes.Name;
end


%% HELPER: IS ABSOLUTE PATH

function isAbsolute = isAbsolutePath(pathValue)
%ISABSOLUTEPATH Identify absolute Windows, UNC, and Unix-style paths.
% This helper is needed so relative configuration paths can be anchored
% without modifying paths that are already absolute.
%
% Input:
%   pathValue - Directory path stored as a character vector.
%
% Output:
%   isAbsolute - Logical true when pathValue is an absolute path.

% Windows accepts drive-rooted, UNC, and separator-rooted paths. Other
% platforms use a leading forward slash.
if ispc
    hasDriveRoot = ~isempty(regexp( ...
        pathValue, '^[A-Za-z]:[\\/]', 'once'));
    hasUncRoot = startsWith(pathValue, '\\') || startsWith(pathValue, '//');
    hasSeparatorRoot = startsWith(pathValue, '\') || startsWith(pathValue, '/');
    isAbsolute = hasDriveRoot || hasUncRoot || hasSeparatorRoot;
else
    isAbsolute = startsWith(pathValue, '/');
end
end
