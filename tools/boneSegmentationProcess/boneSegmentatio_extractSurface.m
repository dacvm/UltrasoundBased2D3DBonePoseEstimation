clear; clc; close all;

%% SELECT INPUTS AND CONFIGURATION

% Resolve all extraction paths from this script so it can be run from any
% MATLAB current folder without changing project-wide paths.
extractionToolDirectory = fileparts(mfilename('fullpath'));
projectDirectory        = fileparts(fileparts(extractionToolDirectory));

% Define the path to the segmentation result
segmentationOutputDirectory = fullfile(extractionToolDirectory, 'outputs');
segmentationFileName        = 'boneSegmentation_20260722_162046.mat';
segmentationFilePath        = fullfile(segmentationOutputDirectory, segmentationFileName);

% Define the path to the ultrasound sequence file
snapshotOutputDirectory     = fullfile(fileparts(extractionToolDirectory), 'snapshotProcess', 'outputs');
ultrasoundFileName          = 'validSnapshots_20260721_145143.mat';
ultrasoundFilePath          = fullfile(snapshotOutputDirectory, ultrasoundFileName);

% Define the path to the configuration file
configurationFilePath       = fullfile(extractionToolDirectory, 'configs', 'boneSurfaceExtraction.json');

% Add the public extractor and its separated helpers explicitly so this tool
% also works when MATLAB starts outside the project directory.
surfaceExtractionDirectory       = fullfile(projectDirectory, 'functions', 'boneSurfaceExtraction');
surfaceExtractionHelperDirectory = fullfile(surfaceExtractionDirectory, 'helpers');
displayFunctionDirectory          = fullfile(projectDirectory, 'functions', 'display');
if ~isfolder(surfaceExtractionDirectory) || ...
        ~isfolder(surfaceExtractionHelperDirectory) || ...
        ~isfolder(displayFunctionDirectory)
    error('boneSegmentatio_extractSurface:MissingExtractionFunctions', ...
          ['Bone-surface extraction or display functions were not found ' ...
           'under the project functions directory: %s'], ...
          fullfile(projectDirectory, 'functions'));
end
addpath(surfaceExtractionDirectory, surfaceExtractionHelperDirectory, ...
    displayFunctionDirectory);

%% LOAD THE SEGMENTATION AND MATCHING B-MODE DATA

if ~isfile(segmentationFilePath)
    error('boneSegmentatio_extractSurface:MissingSegmentationFile', ...
        'Segmentation file was not found: %s', segmentationFilePath);
end
segmentationFileData = load(segmentationFilePath, 'segmentationResults');
if ~isfield(segmentationFileData, 'segmentationResults')
    error('boneSegmentatio_extractSurface:MissingSegmentationResults', ...
        'The selected segmentation file does not contain segmentationResults.');
end
segmentationResults = segmentationFileData.segmentationResults;
clear segmentationFileData;

if ~isfile(ultrasoundFilePath)
    error('boneSegmentatio_extractSurface:MissingUltrasoundFile', ...
        'Ultrasound file was not found: %s', ultrasoundFilePath);
end
ultrasoundFileData = load(ultrasoundFilePath);
ultrasoundVariableNames = fieldnames(ultrasoundFileData);
if numel(ultrasoundVariableNames) ~= 1
    error('boneSegmentatio_extractSurface:UnexpectedUltrasoundVariables', ...
        'Expected one ultrasound variable in "%s", but found %d.', ...
        ultrasoundFileName, numel(ultrasoundVariableNames));
end
ultrasoundSequence = ultrasoundFileData.(ultrasoundVariableNames{1});
clear ultrasoundFileData ultrasoundVariableNames;

if ~isfile(configurationFilePath)
    error('boneSegmentatio_extractSurface:MissingConfigurationFile', ...
        'Extraction configuration was not found: %s', configurationFilePath);
end
try
    % JSON groups related settings by algorithm stage. JSONDECODE preserves
    % that hierarchy so the extractor receives an easier-to-navigate struct.
    extractionOptions = jsondecode(fileread(configurationFilePath));
catch configurationError
    error('boneSegmentatio_extractSurface:InvalidConfigurationFile', ...
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
fprintf('Saved %d surface result(s) to:\n%s\n', numel(surfaceResults), surfaceOutputFilePath);

% Launch one interactive browser instead of creating paged 3-by-3 figures.
% Row selection redraws a single image and the JSON settings remain read only.
reviewFigureHandle = createBoneSurfaceReviewGUI( ...
    surfaceResults, segmentationResults, ultrasoundSequence, ...
    extractionOptions, configurationFilePath);
fprintf('Opened the interactive bone-surface review GUI.\n');
