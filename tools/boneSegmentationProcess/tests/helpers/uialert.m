function alertHandle = uialert(parentFigure, messageText, titleText, varargin)
%UIALERT Suppress informational alerts during automated GUI tests.
% This test-only replacement lets callbacks finish after reporting success or
% failure without leaving an alert overlay that can affect the next assertion.
%
% Inputs:
%   parentFigure : Figure that would own the real alert.
%   messageText  : Explanatory message that would appear in the alert.
%   titleText    : Title that would identify the reported condition.
%   varargin     : Optional alert name-value inputs such as Icon.
%
% Output:
%   alertHandle : Empty value because no graphical alert is created in tests.

% Preserve the full production signature while intentionally avoiding UI work.
unusedAlertInputs = {parentFigure, messageText, titleText, varargin}; %#ok<NASGU>
alertHandle = [];
end
