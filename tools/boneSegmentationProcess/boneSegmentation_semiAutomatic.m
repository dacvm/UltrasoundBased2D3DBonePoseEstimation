clear; clc; close all;

%% LOAD THE ULTRASOUND IMAGE DATA

filepath_ultrasoundimage = 'D:\Documents\BELANDA\SonoSkin\codes\matlab\bmodeimage_3dspace\tools\snapshotProcess\outputs';
filename_ultrasoundimage = 'validSnapshots_20260804_152821.mat';

% Load the MAT-file into a structure so its saved variable does not appear
% directly in the script workspace under an unknown name.
ultrasoundFileData = load(fullfile(filepath_ultrasoundimage, filename_ultrasoundimage));

% Require one saved variable so the script cannot silently choose the wrong
% data when a MAT-file contains unrelated values.
savedVariableNames = fieldnames(ultrasoundFileData);
if numel(savedVariableNames) ~= 1
    error('Expected exactly one variable in "%s", but found %d.', ...
          filename_ultrasoundimage, numel(savedVariableNames));
end

% Give the loaded sequence one stable name for the segmentation workflow.
ultrasoundSequence = ultrasoundFileData.(savedVariableNames{1});
clear ultrasoundFileData savedVariableNames;

%% PREPARE THE TOOL PATHS

% Resolve project paths from this script so it works from any MATLAB current
% folder without copying the launch function back into the tool directory.
segmentationToolDirectory = fileparts(mfilename('fullpath'));
projectDirectory = fileparts(fileparts(segmentationToolDirectory));
functionsDirectory = fullfile(projectDirectory, 'functions');
segmentationOutputDirectory = fullfile(segmentationToolDirectory, 'outputs');

% Add only the direct functions directory because launchBoneSegmentationTools
% is a project function stored at that level.
addpath(functionsDirectory);

%% LAUNCH THE SEMI-AUTOMATIC SEGMENTATION TOOL

% Open the non-blocking browser. Its callbacks keep the processing state
% alive after this script finishes running.
[segmentationFigure, segmentationResults] = launchBoneSegmentationTools(ultrasoundSequence, segmentationOutputDirectory);
