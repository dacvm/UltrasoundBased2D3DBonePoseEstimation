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

% Add the shared helpers and this script's specific helpers before reading
% configuration because the reader now lives outside the main script.
sharedHelperDirectory = fullfile(segmentationToolDirectory, 'helpers');
scriptHelperDirectory = fullfile(sharedHelperDirectory, 'boneSegmentation_semiAutomatic');
if ~isfolder(sharedHelperDirectory) || ~isfolder(scriptHelperDirectory)
    error('boneSegmentation_semiAutomatic:HelperDirectoryNotFound', ...
          'Required bone-segmentation helper directory was not found: %s', ...
          scriptHelperDirectory);
end
addpath(sharedHelperDirectory, scriptHelperDirectory, '-begin');

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

% Load only validSnapshots because validBonePoses belongs to the later
% pre-registration workflow and is not needed for image segmentation.
ultrasoundFilePath = fullfile(filepath_ultrasoundimage, filename_ultrasoundimage);
ultrasoundFileData = load(ultrasoundFilePath, 'validSnapshots');

% Give a clear message when an incompatible MAT file was selected.
if ~isfield(ultrasoundFileData, 'validSnapshots')
    error('boneSegmentation_semiAutomatic:MissingValidSnapshots', ...
          'The selected MAT file does not contain validSnapshots: %s', ...
          ultrasoundFilePath);
end

% Give the loaded sequence one stable name for the segmentation workflow.
ultrasoundSequence = ultrasoundFileData.validSnapshots;
clear ultrasoundFileData;

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
% Pass the input MAT-file path to the browser so each exported segmentation
% can record which ultrasound dataset it came from.
[segmentationFigure, segmentationResults] = launchBoneSegmentationTools( ...
    ultrasoundSequence, segmentationOutputDirectory, ultrasoundFilePath);
