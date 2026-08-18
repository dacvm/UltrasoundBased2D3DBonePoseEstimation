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

% Draw both summary boxes and the actual CMA-ES seed measurements.
figureHandle = figure('Name', 'Surface RMSE Across Seeds');
boxchart(combinationCategory, plotRuns.surfaceRmseMm, 'BoxFaceColor', [0.32 0.56 0.82]);
hold on;
swarmchart(combinationCategory, plotRuns.surfaceRmseMm, 28, [0.10 0.10 0.10], 'filled', 'MarkerFaceAlpha', 0.65);
hold off;

grid on;
xlabel('Hyperparameter combination');
ylabel('Surface RMSE (mm)');
title(sprintf('Surface RMSE Across Seeds — Top %d Combinations', numberToPlot));
xtickangle(45);
end
