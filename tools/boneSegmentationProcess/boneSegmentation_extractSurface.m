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

% Add the shared helpers and this script's specific helpers before reading
% configuration. The public surface extractor is also stored in the
% script-specific folder, while MATLAB finds its private helpers automatically.
sharedHelperDirectory = fullfile(extractionToolDirectory, 'helpers');
scriptHelperDirectory = fullfile( ...
    sharedHelperDirectory, 'boneSegmentation_extractSurface');
if ~isfolder(sharedHelperDirectory) || ~isfolder(scriptHelperDirectory)
    error('boneSegmentation_extractSurface:HelperDirectoryNotFound', ...
          'Required bone-segmentation helper directory was not found: %s', ...
          scriptHelperDirectory);
end
addpath(sharedHelperDirectory, scriptHelperDirectory, '-begin');

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

% Add only the shared display functions here. The extraction functions were
% already added with this script's helper folder above.
displayFunctionDirectory = fullfile(projectDirectory, 'functions', 'display');
if ~isfolder(displayFunctionDirectory)
    error('boneSegmentation_extractSurface:MissingDisplayFunctions', ...
          'Display functions were not found under the project functions directory: %s', ...
          displayFunctionDirectory);
end
addpath(displayFunctionDirectory);

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

% Give a clear message when an incompatible MAT file was selected.
if ~isfield(ultrasoundFileData, 'validSnapshots')
    error('boneSegmentation_semiAutomatic:MissingValidSnapshots', ...
          'The selected MAT file does not contain validSnapshots: %s', ...
          ultrasoundFilePath);
end
% Give the loaded sequence one stable name for the segmentation workflow.
ultrasoundSequence = ultrasoundFileData.validSnapshots;
clear ultrasoundFileData;

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

%% EXTRACT AND REVIEW THE THIN BONE SURFACES

% Extract the 2D bone surface. Each output record also reserves an empty
% surfaceCoordinatesXYZRef field that the later 3D recovery step will fill.
[surfaceResults, extractionMetadata] = extractBoneSurfacesFromSegmentation(segmentationResults, ultrasoundSequence, extractionOptions);

% The extraction function receives arrays, so add the original file and
% variable names here while they are still easy to identify.
extractionMetadata.sourceSegmentationFile     = segmentationFilePath;
extractionMetadata.sourceSegmentationVariable = 'segmentationResults';
extractionMetadata.sourceUltrasoundFile       = ultrasoundFilePath;
extractionMetadata.sourceUltrasoundVariable   = 'validSnapshots';
extractionMetadata.configurationFile          = configurationFilePath;

% Launch one interactive browser instead of creating paged 3-by-3 figures.
% Row selection redraws a single image and the JSON settings remain read only.
% - The grouped surface, segmentation, and ultrasound arguments let the GUI 
%   keep each reviewed overlay matched to its source directory and frame.
% - The extraction options and their file path explain which settings 
%   produced the visible result.
%- Metadata is passed separately because it must remain beside surfaceResults in
%  an exported MAT-file, while the output directory tells the GUI where its
%  user-triggered export belongs without making the user choose the folder again.
reviewFigureHandle = createBoneSurfaceReviewGUI( ...
    surfaceResults, segmentationResults, ultrasoundSequence, ...
    extractionOptions, configurationFilePath, extractionMetadata, ...
    boneSurfaceOutputDirectory);
fprintf('Opened the interactive bone-surface review GUI.\n');
