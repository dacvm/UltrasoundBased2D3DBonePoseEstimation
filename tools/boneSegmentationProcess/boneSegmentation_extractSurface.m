clear; clc; close all;

%% SELECT INPUTS AND CONFIGURATION

% Locate this script first so configuration paths do not depend on MATLAB's
% current working folder.
scriptFullPath = mfilename('fullpath');
if isempty(scriptFullPath)
    error('boneSegmentation_extractSurface:ScriptPathUnavailable', ...
          ['Run boneSegmentation_extractSurface.m as a complete script so ' ...
           'its configuration file can be located.']);
end
extractionToolDirectory = fileparts(scriptFullPath);
projectDirectory = fileparts(fileparts(extractionToolDirectory));

% Read dataset and output locations from a separate workflow configuration.
% The algorithm settings remain in their own JSON file selected by this one.
workflowConfigurationFilePath = fullfile(extractionToolDirectory, 'configs', 'boneSegmentation_extractSurface.json');
workflowConfiguration         = readSurfaceExtractionWorkflowConfiguration(workflowConfigurationFilePath);

% Build complete input filenames from the separately configured directories
% and filenames. Segmentation file:
segmentationFileName        = workflowConfiguration.input.segmentationFileName;
segmentationFilePath        = fullfile(workflowConfiguration.input.segmentationFilePath, segmentationFileName);
% Ultrasound sequence file:
ultrasoundFileName          = workflowConfiguration.input.ultrasoundSequenceFileName;
ultrasoundFilePath          = fullfile(workflowConfiguration.input.ultrasoundSequenceFilePath, ultrasoundFileName);
% Configuration file
configurationFilePath       = fullfile(workflowConfiguration.input.configurationFilePath, workflowConfiguration.input.configurationFileName);
boneSurfaceOutputDirectory  = workflowConfiguration.output.boneSurfaceOutputPath;

% Add the public extractor and its separated helpers explicitly so this tool
% also works when MATLAB starts outside the project directory.
surfaceExtractionDirectory       = fullfile(projectDirectory, 'functions', 'boneSurfaceExtraction');
surfaceExtractionHelperDirectory = fullfile(surfaceExtractionDirectory, 'helpers');
displayFunctionDirectory         = fullfile(projectDirectory, 'functions', 'display');
if ~isfolder(surfaceExtractionDirectory) || ~isfolder(surfaceExtractionHelperDirectory) || ~isfolder(displayFunctionDirectory)
    error('boneSegmentation_extractSurface:MissingExtractionFunctions', ...
          'Bone-surface extraction or display functions were not found under the project functions directory: %s', ...
          fullfile(projectDirectory, 'functions'));
end
addpath(surfaceExtractionDirectory, surfaceExtractionHelperDirectory, displayFunctionDirectory);

%% LOAD THE SEGMENTATION AND MATCHING B-MODE DATA

% Check that the segmentation result exists before calling LOAD. Without this
% check MATLAB would stop with a generic file error, which would make it harder
% to tell the user which input is missing and where the script looked for it.
if ~isfile(segmentationFilePath)
    error('boneSegmentation_extractSurface:MissingSegmentationFile', ...
          'Segmentation file was not found: %s', segmentationFilePath);
end
segmentationFileData = load(segmentationFilePath, 'segmentationResults');

% The extractor needs the variable named segmentationResults from the MAT-file.
% Check for it explicitly so a file with the wrong contents fails with a useful
% message instead of causing an unclear error later in the processing pipeline.
if ~isfield(segmentationFileData, 'segmentationResults')
    error('boneSegmentation_extractSurface:MissingSegmentationResults', ...
          'The selected segmentation file does not contain segmentationResults.');
end
segmentationResults = segmentationFileData.segmentationResults;
clear segmentationFileData;

% Check the ultrasound file before loading it for the same reason as above:
% report the missing input with its full path instead of exposing LOAD's generic
% error message.
if ~isfile(ultrasoundFilePath)
    error('boneSegmentation_extractSurface:MissingUltrasoundFile', ...
          'Ultrasound file was not found: %s', ultrasoundFilePath);
end
ultrasoundFileData      = load(ultrasoundFilePath);
ultrasoundVariableNames = fieldnames(ultrasoundFileData);

% This tool expects the ultrasound MAT-file to contain exactly one variable.
% Requiring one variable makes the next dynamic field lookup unambiguous and
% prevents the script from silently choosing the wrong dataset.
if numel(ultrasoundVariableNames) ~= 1
    error('boneSegmentation_extractSurface:UnexpectedUltrasoundVariables', ...
          'Expected one ultrasound variable in "%s", but found %d.', ...
          ultrasoundFileName, numel(ultrasoundVariableNames));
end
ultrasoundSequence = ultrasoundFileData.(ultrasoundVariableNames{1});
clear ultrasoundFileData ultrasoundVariableNames;

% Verify that the JSON settings file exists before trying to read its text.
% The extractor depends on these settings, so continuing without them could
% produce incomplete or incorrectly configured surface results.
if ~isfile(configurationFilePath)
    error('boneSegmentation_extractSurface:MissingConfigurationFile', ...
          'Extraction configuration was not found: %s', configurationFilePath);
end

% Reading and decoding JSON can fail when the file is malformed or contains a
% format MATLAB cannot decode. Convert that low-level failure into a named error
% that identifies this tool and explains that the configuration is invalid.
try
    % JSON groups related settings by algorithm stage. JSONDECODE preserves
    % that hierarchy so the extractor receives an easier-to-navigate struct.
    extractionOptions = jsondecode(fileread(configurationFilePath));
catch configurationError
    error('boneSegmentation_extractSurface:InvalidConfigurationFile', ...
          'Could not read the extraction configuration: %s', ...
          configurationError.message);
end

%% EXTRACT AND SAVE THE THIN BONE SURFACES

% Extract the bone surface
[surfaceResults, extractionMetadata] = extractBoneSurfacesFromSegmentation(segmentationResults, ultrasoundSequence, extractionOptions);

% The public function receives arrays rather than file paths, so record the
% resolved provenance here before saving the result artifact.
extractionMetadata.sourceSegmentationFile = segmentationFilePath;
extractionMetadata.sourceUltrasoundFile   = ultrasoundFilePath;
extractionMetadata.configurationFile      = configurationFilePath;

% Create metadata
runTimestamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
surfaceOutputFilePath = fullfile( ...
    boneSurfaceOutputDirectory, ['boneSurface_', runTimestamp, '.mat']);

% Save the numerical result before opening the non-blocking review window.
% The GUI is intentionally not part of the saved artifact because it can be
% recreated from these arrays and the recorded configuration at any time.
extractionMetadata.outputFile = surfaceOutputFilePath;

save(surfaceOutputFilePath, 'surfaceResults', 'extractionMetadata', '-v7.3');

% Count nested records rather than outer source groups so the message reports
% the number of processed ultrasound frames after grouped extraction.
numberOfSurfaceRecords = sum(arrayfun( ...
    @(surfaceGroup) numel(surfaceGroup.data), surfaceResults));
fprintf('Saved %d surface result(s) to:\n%s\n', ...
    numberOfSurfaceRecords, surfaceOutputFilePath);

% Launch one interactive browser instead of creating paged 3-by-3 figures.
% Row selection redraws a single image and the JSON settings remain read only.
reviewFigureHandle = createBoneSurfaceReviewGUI( ...
    surfaceResults, segmentationResults, ultrasoundSequence, ...
    extractionOptions, configurationFilePath);
fprintf('Opened the interactive bone-surface review GUI.\n');










%% HELPER: READ WORKFLOW CONFIGURATION

function configuration = readSurfaceExtractionWorkflowConfiguration( ...
        configurationFilePath)
%READSURFACEEXTRACTIONWORKFLOWCONFIGURATION Load extraction workflow paths.
% This function reads and validates the input and output locations needed by
% the surface-extraction script so changing datasets does not change code.
%
% Input:
%   configurationFilePath - Path to the workflow JSON configuration file.
%
% Output:
%   configuration - Scalar structure containing validated absolute input
%                   and output directories plus the three input filenames.

% Report a missing workflow configuration separately from malformed JSON so
% the user receives a direct description of the required correction.
if ~isfile(configurationFilePath)
    error('boneSegmentation_extractSurface:WorkflowConfigurationNotFound', ...
          'Workflow configuration file was not found: %s', ...
          configurationFilePath);
end

% Add the source filename to JSON parsing errors because this workflow uses
% two JSON files with different purposes.
try
    configurationText = fileread(configurationFilePath);
    rawConfiguration = jsondecode(configurationText);
catch configurationError
    error('boneSegmentation_extractSurface:InvalidWorkflowConfigurationJson', ...
          'Could not read workflow configuration JSON "%s". Reason: %s', ...
          configurationFilePath, configurationError.message);
end

% Require one top-level object because the remaining code expects exactly
% one input section and one output section.
if ~isstruct(rawConfiguration) || ~isscalar(rawConfiguration)
    error('boneSegmentation_extractSurface:InvalidWorkflowConfigurationRoot', ...
          'Workflow configuration must contain one top-level object: %s', ...
          configurationFilePath);
end

% Validate the section types before accessing their nested fields so missing
% or incorrectly shaped JSON objects produce clear errors.
inputConfiguration = requireConfigurationObject( ...
    rawConfiguration, 'input', 'input');
outputConfiguration = requireConfigurationObject( ...
    rawConfiguration, 'output', 'output');

% Read all requested input settings as nonempty text before resolving paths.
% Keeping field labels here makes later errors point to the exact JSON entry.
segmentationFilePathSetting = requireConfigurationText( ...
    inputConfiguration, 'segmentationFilePath', ...
    'input.segmentationFilePath');
segmentationFileName = requireConfigurationText( ...
    inputConfiguration, 'segmentationFileName', ...
    'input.segmentationFileName');
ultrasoundSequenceFilePathSetting = requireConfigurationText( ...
    inputConfiguration, 'ultrasoundSequenceFilePath', ...
    'input.ultrasoundSequenceFilePath');
ultrasoundSequenceFileName = requireConfigurationText( ...
    inputConfiguration, 'ultrasoundSequenceFileName', ...
    'input.ultrasoundSequenceFileName');
extractionConfigurationFilePathSetting = requireConfigurationText( ...
    inputConfiguration, 'configurationFilePath', ...
    'input.configurationFilePath');
extractionConfigurationFileName = requireConfigurationText( ...
    inputConfiguration, 'configurationFileName', ...
    'input.configurationFileName');
boneSurfaceOutputPathSetting = requireConfigurationText( ...
    outputConfiguration, 'boneSurfaceOutputPath', ...
    'output.boneSurfaceOutputPath');

% Check that each filename is only a filename and uses the file type expected
% by its loader. This prevents a path in a filename field from overriding the
% separately configured parent directory.
validateConfiguredFileName( ...
    segmentationFileName, 'input.segmentationFileName', '.mat');
validateConfiguredFileName( ...
    ultrasoundSequenceFileName, ...
    'input.ultrasoundSequenceFileName', '.mat');
validateConfiguredFileName( ...
    extractionConfigurationFileName, ...
    'input.configurationFileName', '.json');

% Resolve relative paths beside this workflow JSON so execution is stable
% even when MATLAB starts from another current folder.
configurationDirectory = fileparts(configurationFilePath);
segmentationFileDirectory = resolveConfiguredDirectory( ...
    segmentationFilePathSetting, configurationDirectory, ...
    'input.segmentationFilePath', false);
ultrasoundSequenceFileDirectory = resolveConfiguredDirectory( ...
    ultrasoundSequenceFilePathSetting, configurationDirectory, ...
    'input.ultrasoundSequenceFilePath', false);
extractionConfigurationFileDirectory = resolveConfiguredDirectory( ...
    extractionConfigurationFilePathSetting, configurationDirectory, ...
    'input.configurationFilePath', false);
boneSurfaceOutputDirectory = resolveConfiguredDirectory( ...
    boneSurfaceOutputPathSetting, configurationDirectory, ...
    'output.boneSurfaceOutputPath', true);

% Validate each combined input path before the script starts loading large
% data so a configuration mistake fails early with the exact resolved path.
requireConfiguredFile( ...
    segmentationFileDirectory, segmentationFileName, ...
    'input.segmentationFilePath and input.segmentationFileName');
requireConfiguredFile( ...
    ultrasoundSequenceFileDirectory, ultrasoundSequenceFileName, ...
    ['input.ultrasoundSequenceFilePath and ' ...
     'input.ultrasoundSequenceFileName']);
requireConfiguredFile( ...
    extractionConfigurationFileDirectory, ...
    extractionConfigurationFileName, ...
    'input.configurationFilePath and input.configurationFileName');

% Preserve the JSON hierarchy in the returned value while replacing each
% directory setting with its resolved absolute path.
configuration = struct();
configuration.input = struct( ...
    'segmentationFilePath', segmentationFileDirectory, ...
    'segmentationFileName', segmentationFileName, ...
    'ultrasoundSequenceFilePath', ultrasoundSequenceFileDirectory, ...
    'ultrasoundSequenceFileName', ultrasoundSequenceFileName, ...
    'configurationFilePath', extractionConfigurationFileDirectory, ...
    'configurationFileName', extractionConfigurationFileName);
configuration.output = struct( ...
    'boneSurfaceOutputPath', boneSurfaceOutputDirectory);
end


%% HELPER: REQUIRE CONFIGURATION OBJECT

function objectValue = requireConfigurationObject(parentValue, fieldName, fieldLabel)
%REQUIRECONFIGURATIONOBJECT Read one required scalar JSON object.
% This helper stops nested field access from hiding a missing or incorrectly
% typed configuration section behind a less useful MATLAB error.
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
    error('boneSegmentation_extractSurface:MissingConfigurationObject', ...
          'Required workflow configuration object "%s" is missing.', ...
          fieldLabel);
end
objectValue = parentValue.(fieldName);
if ~isstruct(objectValue) || ~isscalar(objectValue)
    error('boneSegmentation_extractSurface:InvalidConfigurationObject', ...
          'Workflow configuration field "%s" must contain one object.', ...
          fieldLabel);
end
end


%% HELPER: REQUIRE CONFIGURATION TEXT

function textValue = requireConfigurationText(parentValue, fieldName, fieldLabel)
%REQUIRECONFIGURATIONTEXT Read one required nonempty JSON text value.
% This helper normalizes strings to character vectors so MATLAB path
% functions receive a consistent text type.
%
% Inputs:
%   parentValue - Structure expected to contain the required text field.
%   fieldName   - MATLAB field name created by JSONDECODE.
%   fieldLabel  - User-facing JSON field path used in error messages.
%
% Output:
%   textValue - Trimmed, nonempty character vector from the requested field.

% Stop before conversion when the setting is absent so the error names the
% exact missing JSON field.
if ~isfield(parentValue, fieldName)
    error('boneSegmentation_extractSurface:MissingConfigurationField', ...
          'Required workflow configuration field "%s" is missing.', ...
          fieldLabel);
end
rawValue = parentValue.(fieldName);

% Accept either MATLAB text representation because JSONDECODE behavior can
% vary by MATLAB release, but reject arrays containing multiple values.
isCharacterText = ischar(rawValue) && isrow(rawValue);
isScalarString = isstring(rawValue) && isscalar(rawValue);
if ~isCharacterText && ~isScalarString
    error('boneSegmentation_extractSurface:InvalidConfigurationText', ...
          'Workflow configuration field "%s" must contain one text value.', ...
          fieldLabel);
end
textValue = strtrim(char(rawValue));
if isempty(textValue)
    error('boneSegmentation_extractSurface:EmptyConfigurationText', ...
          'Workflow configuration field "%s" cannot be empty.', ...
          fieldLabel);
end
end


%% HELPER: VALIDATE CONFIGURED FILENAME

function validateConfiguredFileName(fileName, fieldLabel, expectedExtension)
%VALIDATECONFIGUREDFILENAME Validate one filename separated from its path.
% This function enforces the configuration layout requested by the workflow
% and checks the file type before any data is loaded.
%
% Inputs:
%   fileName          - Configured filename without a parent directory.
%   fieldLabel        - User-facing JSON field path used in error messages.
%   expectedExtension - Required filename extension, including the period.
%
% Output:
%   This function has no output; it throws a named error for invalid input.

% FILEPARTS returns a nonempty parent when the setting incorrectly includes
% directory components.
[fileParent, ~, fileExtension] = fileparts(fileName);
if ~isempty(fileParent)
    error('boneSegmentation_extractSurface:InvalidConfiguredFileName', ...
          ['Workflow configuration field "%s" must contain a filename ' ...
           'only, without a directory.'], fieldLabel);
end

% Require the expected extension so an incorrect input type is reported by
% the configuration reader rather than a specialized loader later.
if ~strcmpi(fileExtension, expectedExtension)
    error('boneSegmentation_extractSurface:InvalidConfiguredFileExtension', ...
          'Workflow configuration field "%s" must identify a %s file.', ...
          fieldLabel, expectedExtension);
end
end


%% HELPER: REQUIRE CONFIGURED FILE

function requireConfiguredFile(parentDirectory, fileName, fieldLabel)
%REQUIRECONFIGUREDFILE Check that one configured input file exists.
% This helper combines validated directory and filename settings and reports
% which pair of JSON fields selected a missing file.
%
% Inputs:
%   parentDirectory - Resolved absolute directory containing the input file.
%   fileName        - Validated filename to append to the parent directory.
%   fieldLabel      - User-facing description of the related JSON fields.
%
% Output:
%   This function has no output; it throws a named error when the file is absent.

% Check the complete path because validating the parent directory alone does
% not guarantee that it contains the requested input file.
candidateFile = fullfile(parentDirectory, fileName);
if ~isfile(candidateFile)
    error('boneSegmentation_extractSurface:ConfiguredInputFileNotFound', ...
          'Configured input from "%s" was not found: %s', ...
          fieldLabel, candidateFile);
end
end


%% HELPER: RESOLVE CONFIGURED DIRECTORY

function resolvedDirectory = resolveConfiguredDirectory( ...
        configuredDirectory, configurationDirectory, fieldLabel, ...
        createIfMissing)
%RESOLVECONFIGUREDDIRECTORY Resolve and validate one configured directory.
% Relative directories are anchored beside the workflow JSON so MATLAB's
% current folder does not affect input or output selection.
%
% Inputs:
%   configuredDirectory  - Absolute path or path relative to the JSON file.
%   configurationDirectory - Directory containing the workflow JSON file.
%   fieldLabel           - User-facing JSON field path used in errors.
%   createIfMissing      - Logical true when a missing directory may be made.
%
% Output:
%   resolvedDirectory - Canonical absolute path to the usable directory.

% Keep absolute paths unchanged and anchor only relative paths beside the
% configuration file.
if isAbsolutePath(configuredDirectory)
    candidateDirectory = configuredDirectory;
else
    candidateDirectory = fullfile( ...
        configurationDirectory, configuredDirectory);
end

% Input directories must already exist. The output directory may be created
% because empty output folders are not retained in a clean checkout.
if ~isfolder(candidateDirectory)
    if ~createIfMissing
        error('boneSegmentation_extractSurface:ConfiguredDirectoryNotFound', ...
              'Configured directory "%s" was not found: %s', ...
              fieldLabel, candidateDirectory);
    end
    [directoryCreated, creationMessage] = mkdir(candidateDirectory);
    if ~directoryCreated
        error('boneSegmentation_extractSurface:OutputDirectoryCreationFailed', ...
              'Could not create configured output directory "%s": %s', ...
              candidateDirectory, creationMessage);
    end
end

% Canonicalize the directory for stable provenance paths saved with the
% extraction result.
[pathFound, pathAttributes] = fileattrib(candidateDirectory);
if ~pathFound
    error('boneSegmentation_extractSurface:DirectoryResolutionFailed', ...
          'Could not resolve configured directory "%s": %s', ...
          fieldLabel, candidateDirectory);
end
resolvedDirectory = pathAttributes.Name;
end


%% HELPER: IS ABSOLUTE PATH

function isAbsolute = isAbsolutePath(pathValue)
%ISABSOLUTEPATH Identify absolute Windows, UNC, and Unix-style paths.
% This helper distinguishes paths that must be anchored beside the workflow
% JSON from paths that already identify their filesystem root.
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
