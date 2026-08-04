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

% The production suggestions are intentionally ignored because the test owns
% an exact disposable destination through root application data.
unusedPickerInputs = varargin; %#ok<NASGU>
applicationDataKey = 'BoneSegmentationTestExportPath';
if ~isappdata(groot, applicationDataKey)
    error('testLaunchBoneSegmentationToolsGrouped:MissingExportPath', ...
        'The grouped browser test did not configure an export path.');
end

exportPath = char(string(getappdata(groot, applicationDataKey)));
[selectedDirectory, baseFileName, fileExtension] = fileparts(exportPath);
selectedFileName = [baseFileName, fileExtension];
selectedFilterIndex = 1;
end
