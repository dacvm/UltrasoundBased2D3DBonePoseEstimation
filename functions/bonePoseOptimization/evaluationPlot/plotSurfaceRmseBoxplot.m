function figureHandle = plotSurfaceRmseBoxplot(perRunTable, perCombinationTable, topCombinationCount)
%PLOTSURFACERMSEBOXPLOT Show seed variation for the best combinations.
% This plot compares the surface-RMSE distributions of the highest-ranked
% hyperparameter combinations. Individual seed points are shown so small
% sample sizes remain easy to interpret.
%
% Inputs:
%   perRunTable          - Per-run evaluation table with surface RMSE values.
%   perCombinationTable  - Ranked per-combination evaluation table.
%   topCombinationCount  - Maximum number of ranked combinations to display.
%
% Output:
%   figureHandle         - Handle to the created MATLAB figure.

% Select only ranked combinations and limit the plot to readable labels.
rankedRows = isfinite(perCombinationTable.combinationRank);
rankedCombinations = perCombinationTable(rankedRows, :);
numberToPlot = min(topCombinationCount, height(rankedCombinations));
if numberToPlot == 0
    error('plotSurfaceRmseBoxplot:NoEvaluatedCombinations', ...
          'No evaluated combinations are available for the RMSE boxplot.');
end

topCombinationIds    = rankedCombinations.combinationId(1:numberToPlot);
topCombinationLabels = erase(topCombinationIds, "combination_");
plotRows = ismember(string(perRunTable.combinationId), topCombinationIds) & ...
           isfinite(perRunTable.surfaceRmseMm);
plotRuns = perRunTable(plotRows, :);

% Use an ordered category so the x-axis follows the surface-RMSE ranking.
combinationCategory = categorical(string(plotRuns.combinationId), ...
    topCombinationIds, cellstr(topCombinationLabels), 'Ordinal', true);

% Pick each box colour from its combination's median RMSE on the range
% shared by every evaluation figure, so the boxes match the other plots.
style = getEvaluationPlotStyle();
colorLimits = getSurfaceRmseColorLimits(perCombinationTable);
boxColors = surfaceRmseToColor(rankedCombinations.medianSurfaceRmseMm(1:numberToPlot), colorLimits, style.colormap);

figureHandle = createEvaluationFigure('Surface RMSE Across Seeds', style.figureSizeCm, style);
layout = tiledlayout(figureHandle, 1, 1, 'Padding', 'compact');
ax = nexttile(layout);
hold(ax, 'on');

% boxchart takes one face colour per call, so draw one box per combination.
% The ordinal categories keep every box at its ranked x position. Outlier
% markers are hidden because every seed is already drawn as a dot.
for boxIndex = 1:numberToPlot
    boxRuns = string(plotRuns.combinationId) == string(topCombinationIds(boxIndex));
    boxchart(ax, combinationCategory(boxRuns), plotRuns.surfaceRmseMm(boxRuns), ...
             'BoxFaceColor', boxColors(boxIndex, :), 'BoxFaceAlpha', style.boxFaceAlpha, ...
             'MarkerStyle', 'none');
end

% Dark grey seed dots stay readable on top of every box colour.
swarmchart(ax, combinationCategory, plotRuns.surfaceRmseMm, style.markerSize, ...
           style.seedPointColor, 'filled', 'MarkerFaceAlpha', 0.65);
hold(ax, 'off');

grid(ax, 'on');
clim(ax, colorLimits);
addSurfaceRmseColorbar(ax, style);
xlabel(ax, 'Hyperparameter combination');
ylabel(ax, 'Surface RMSE (mm)');
xtickangle(ax, 45);
addEvaluationFigureTitle(layout, 'Surface RMSE across seeds', ...
    sprintf('Top %d combinations, ranked by median surface RMSE; dots are seeds', numberToPlot), style);
end


function colors = surfaceRmseToColor(surfaceRmseMm, colorLimits, colorMap)
%SURFACERMSETOCOLOR Look up the colormap colour of each RMSE value.
% surfaceRmseMm is an N-by-1 vector of RMSE values, colorLimits the shared
% [lowest highest] range, and colorMap an M-by-3 colormap. colors is the
% N-by-3 RGB colour of each value, as a colour bar with the same range shows it.

% Scale each value to a colormap row; values outside the range get an end colour.
relativePosition = (surfaceRmseMm - colorLimits(1)) / diff(colorLimits);
rowIndexes = round(1 + relativePosition * (size(colorMap, 1) - 1));
rowIndexes = min(max(rowIndexes, 1), size(colorMap, 1));
colors = colorMap(rowIndexes, :);
end
