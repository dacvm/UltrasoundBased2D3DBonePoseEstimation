function addEvaluationFigureTitle(layout, titleText, subtitleText, style)
%ADDEVALUATIONFIGURETITLE Put the shared title and subtitle above a figure.
% Every evaluation plot uses a short title that says what is shown and a
% lighter subtitle that gives the context (ranking, held values, caveats).
% Placing both on the tiled layout keeps them in the same spot and size in
% every figure, also when the figure holds several panels.
%
% Inputs:
%   layout       - Tiled chart layout of the figure.
%   titleText    - Short title text.
%   subtitleText - Context line shown below the title.
%   style        - Shared style struct from getEvaluationPlotStyle.
%
% Output:
%   none

% Layout titles do not follow the figure's text defaults, so set the
% interpreter and sizes here explicitly.
title(layout, titleText, 'Interpreter', 'none', 'FontSize', style.titleFontSize, 'FontWeight', 'bold');
subtitle(layout, subtitleText, 'Interpreter', 'none', 'FontSize', style.fontSize, 'Color', style.subtitleColor);
end
