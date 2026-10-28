function plotMedianIqrScatter(ax, xStatistics, yStatistics, surfaceRmseMm, colorLimits, isTopCombination, pointLabels, style)
%PLOTMEDIANIQRSCATTER Draw median points with IQR lines on both axes.
% Several evaluation plots compare two seed statistics per combination. This
% function draws them all the same way: a grey IQR cross per combination,
% points coloured by median surface RMSE, and an outline plus a label on
% the top-ranked combinations.
%
% Inputs:
%   ax               - Axes inside a tiled layout to draw into.
%   xStatistics      - N-by-3 [q25, median, q75] of the x-axis quantity.
%   yStatistics      - N-by-3 [q25, median, q75] of the y-axis quantity.
%   surfaceRmseMm    - N-by-1 median surface RMSE that sets each point colour.
%   colorLimits      - Shared [lowest highest] RMSE from getSurfaceRmseColorLimits.
%   isTopCombination - N-by-1 logical; true for combinations to highlight.
%   pointLabels      - N-by-1 string labels; only top combinations show them.
%   style            - Shared style struct from getEvaluationPlotStyle.
%
% Output:
%   none

hold(ax, 'on');

% Draw every IQR cross as one line object: each combination adds a
% horizontal and a vertical segment, separated by NaN so they are not joined.
numberOfPoints = size(xStatistics, 1);
gap = nan(numberOfPoints, 1);
xLines = [xStatistics(:, 1), xStatistics(:, 3), gap, xStatistics(:, 2), xStatistics(:, 2), gap].';
yLines = [yStatistics(:, 2), yStatistics(:, 2), gap, yStatistics(:, 1), yStatistics(:, 3), gap].';
iqrHandle = plot(ax, xLines(:), yLines(:), '-', 'Color', style.iqrLineColor);

% Colour every point by its RMSE. Draw the other combinations first so the
% outlined top ones stay on top.
scatter(ax, xStatistics(~isTopCombination, 2), yStatistics(~isTopCombination, 2), ...
        style.scatterMarkerSize, surfaceRmseMm(~isTopCombination), 'filled');
scatter(ax, xStatistics(isTopCombination, 2), yStatistics(isTopCombination, 2), ...
        style.scatterMarkerSize, surfaceRmseMm(isTopCombination), 'filled', ...
        'MarkerEdgeColor', style.topMarkerEdgeColor, 'LineWidth', 1);
clim(ax, colorLimits);

% Label only the highlighted points so a large sweep stays readable.
text(ax, xStatistics(isTopCombination, 2), yStatistics(isTopCombination, 2), ...
     "  " + pointLabels(isTopCombination), ...
     'FontSize', style.pointLabelFontSize, 'VerticalAlignment', 'bottom');

% The real points have many colours, so the legend uses grey stand-in
% markers (NaN data draws nothing) that show only the outline difference.
topLegendHandle   = scatter(ax, NaN, NaN, style.scatterMarkerSize, style.legendMarkerColor, 'filled', ...
                            'MarkerEdgeColor', style.topMarkerEdgeColor, 'LineWidth', 1);
otherLegendHandle = scatter(ax, NaN, NaN, style.scatterMarkerSize, style.legendMarkerColor, 'filled');

hold(ax, 'off');
grid(ax, 'on');

% Small sweeps can have no "other" combinations; leave that entry out then.
legendHandles = [topLegendHandle, iqrHandle];
legendNames   = {sprintf('Top %d (labelled)', nnz(isTopCombination)), 'IQR across seeds'};
if any(~isTopCombination)
    legendHandles = [topLegendHandle, otherLegendHandle, iqrHandle];
    legendNames   = [legendNames(1), {'Other'}, legendNames(2)];
end
legend(ax, legendHandles, legendNames, 'Location', 'best');

addSurfaceRmseColorbar(ax, style);
end
