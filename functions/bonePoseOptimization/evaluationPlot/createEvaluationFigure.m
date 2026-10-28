function figureHandle = createEvaluationFigure(figureName, figureSizeCm, style)
%CREATEEVALUATIONFIGURE Open an empty figure with the shared evaluation style.
% All evaluation plots start from this function so they get the same size,
% font size, and text interpreter. The defaults are set on the figure, so
% every axes, label, and legend created inside it inherits them without
% repeating the settings in each plot function.
%
% Inputs:
%   figureName   - Text shown in the figure window bar.
%   figureSizeCm - [width height] of the figure in centimetres.
%   style        - Shared style struct from getEvaluationPlotStyle.
%
% Output:
%   figureHandle - Handle to the created MATLAB figure.

% Plain text everywhere: parameter names and combination labels must show
% exactly as written, never as TeX subscripts or symbols.
figureHandle = figure( ...
    'Name', figureName, ...
    'DefaultAxesFontSize', style.fontSize, ...
    'DefaultTextInterpreter', 'none', ...
    'DefaultAxesTickLabelInterpreter', 'none', ...
    'DefaultLegendInterpreter', 'none');

% Change only the size and keep MATLAB's window position, then pull the
% window back onto the screen when a tall figure would stick out.
figureHandle.Units = 'centimeters';
figureHandle.Position(3:4) = figureSizeCm;
movegui(figureHandle, 'onscreen');
end
