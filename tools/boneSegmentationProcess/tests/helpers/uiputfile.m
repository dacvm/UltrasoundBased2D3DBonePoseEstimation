function [selectedFileName, selectedDirectory, selectedFilterIndex] = ...
        uiputfile(varargin)
%UIPUTFILE Return the export path configured by the grouped browser test.
% This test-only replacement avoids an interactive file picker and directs the
% real export callback to a unique temporary MAT file chosen by the test.
%
% Inputs:
%   varargin : File filter, dialog title, and suggested path from production.
%
% Outputs:
%   selectedFileName    : File name portion of the configured temporary path.
%   selectedDirectory   : Directory portion of the configured temporary path.
%   selectedFilterIndex : Filter index 1 for the MAT-file choice.

% Surface-review tests use their own destination key because they share this
% dialog replacement with the segmentation-browser tests.
surfaceExportPathKey = 'BoneSurfaceTestExportPath';
segmentationExportPathKey = 'BoneSegmentationTestExportPath';
if isappdata(groot, surfaceExportPathKey)
    applicationDataKey = surfaceExportPathKey;
elseif isappdata(groot, segmentationExportPathKey)
    applicationDataKey = segmentationExportPathKey;
else
    error('testLaunchBoneSegmentationToolsGrouped:MissingExportPath', ...
        'The GUI test did not configure an export path.');
end

exportPath = char(string(getappdata(groot, applicationDataKey)));

% Retain the surface dialog inputs so its test can verify that the production
% callback starts in the directory supplied by the workflow configuration.
if strcmp(applicationDataKey, surfaceExportPathKey)
    setappdata(groot, 'BoneSurfaceTestPickerInputs', varargin);
end
[selectedDirectory, baseFileName, fileExtension] = fileparts(exportPath);
selectedFileName = [baseFileName, fileExtension];
selectedFilterIndex = 1;
end
