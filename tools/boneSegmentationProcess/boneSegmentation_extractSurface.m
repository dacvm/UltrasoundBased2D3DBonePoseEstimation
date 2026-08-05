clear; clc; close all;

%% SELECT INPUTS AND CONFIGURATION

% Resolve all extraction paths from this script so it can be run from any
% MATLAB current folder without changing project-wide paths.
extractionToolDirectory = fileparts(mfilename('fullpath'));
projectDirectory        = fileparts(fileparts(extractionToolDirectory));

% Define the path to the segmentation result
segmentationOutputDirectory = fullfile(extractionToolDirectory, 'outputs');
segmentationFileName        = 'boneSegmentation_20260805_094513.mat';
segmentationFilePath        = fullfile(segmentationOutputDirectory, segmentationFileName);

% Define the path to the ultrasound sequence file
snapshotOutputDirectory     = fullfile(fileparts(extractionToolDirectory), 'ultrasoundSpatialProcessing', 'outputs');
ultrasoundFileName          = 'validSnapshots_20260804_152821.mat';
ultrasoundFilePath          = fullfile(snapshotOutputDirectory, ultrasoundFileName);

% Define the path to the configuration file
configurationFilePath       = fullfile(extractionToolDirectory, 'configs', 'boneSurfaceExtraction.json');

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
ultrasoundFileData = load(ultrasoundFilePath);
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
surfaceOutputFilePath = fullfile(segmentationOutputDirectory, ['boneSurface_', runTimestamp, '.mat']);

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
