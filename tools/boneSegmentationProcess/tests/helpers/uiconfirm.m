function selectedOption = uiconfirm( ...
        parentFigure, messageText, titleText, varargin)
%UICONFIRM Select the first confirmation option during automated GUI tests.
% This test-only replacement prevents modal confirmation dialogs from blocking
% batch tests while still exercising the confirmed branches of GUI callbacks.
%
% Inputs:
%   parentFigure : Figure that would own the real confirmation dialog.
%   messageText  : Explanatory message that would appear in the dialog.
%   titleText    : Title that would identify the confirmation operation.
%   varargin     : Name-value inputs, including the required Options list.
%
% Output:
%   selectedOption : First option supplied by the callback under test.

% These values document the normal dialog call but are intentionally unused by
% the deterministic test replacement.
unusedDialogInputs = {parentFigure, messageText, titleText}; %#ok<NASGU>

% Find the Options name-value pair without depending on its argument position.
optionNameIndex = find(cellfun( ...
    @(value) (ischar(value) || (isstring(value) && isscalar(value))) && ...
        strcmpi(string(value), "Options"), varargin), 1);
if isempty(optionNameIndex) || optionNameIndex == numel(varargin)
    error('testLaunchBoneSegmentationToolsGrouped:MissingDialogOptions', ...
        'The test confirmation replacement requires an Options value.');
end

dialogOptions = varargin{optionNameIndex + 1};
selectedOption = dialogOptions{1};
end
