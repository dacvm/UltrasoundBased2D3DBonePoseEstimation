function figureHandle = plotOptimizerCostVsSurfaceRmse(perCombinationTable, topCombinationCount)
%PLOTOPTIMIZERCOSTVSSURFACERMSE Compare optimizer cost with true accuracy.
% This diagnostic plot places each combination at its median optimizer cost
% and median surface RMSE. IQR lines show seed variation on both axes. The
% top-ranked combinations are highlighted so they match the other plots.
%
% Inputs:
%   perCombinationTable - Combination table containing cost and RMSE statistics.
%   topCombinationCount - Number of best-ranked combinations to highlight.
%
% Output:
%   figureHandle        - Handle to the created MATLAB figure.

% Keep combinations that have both an optimizer result and validation result.
plotRows = isfinite(perCombinationTable.medianBestCost) & ...
           isfinite(perCombinationTable.medianSurfaceRmseMm);
plotTable = perCombinationTable(plotRows, :);
if isempty(plotTable)
    error('plotOptimizerCostVsSurfaceRmse:NoEvaluatedCombinations', ...
        'No evaluated combinations are available for the optimizer diagnostic.');
end

% Collect the seed statistics on each axis in [q25, median, q75] order.
costStatistics = [plotTable.q25BestCost, ...
                  plotTable.medianBestCost, ...
                  plotTable.q75BestCost];
rmseStatistics = [plotTable.q25SurfaceRmseMm, ...
                  plotTable.medianSurfaceRmseMm, ...
                  plotTable.q75SurfaceRmseMm];

% Highlight the same top combinations as the other ranked plots, and colour
% the points on the RMSE range shared by every evaluation figure. The colour
% repeats the y-axis here, which keeps this figure matching the others.
isTopCombination  = plotTable.combinationRank <= topCombinationCount;
combinationLabels = erase(string(plotTable.combinationId), "combination_");
colorLimits       = getSurfaceRmseColorLimits(perCombinationTable);

% Draw the points on the shared evaluation figure layout.
style = getEvaluationPlotStyle();
figureHandle = createEvaluationFigure('Optimizer Cost and Surface RMSE', style.figureSizeCm, style);
layout = tiledlayout(figureHandle, 1, 1, 'Padding', 'compact');
ax = nexttile(layout);
plotMedianIqrScatter(ax, costStatistics, rmseStatistics, ...
                     plotTable.medianSurfaceRmseMm, colorLimits, ...
                     isTopCombination, combinationLabels, style);

% The cost has no physical unit, so mark it as arbitrary units.
xlabel(ax, 'Median best cost (a.u.)');
ylabel(ax, 'Median surface RMSE (mm)');
addEvaluationFigureTitle(layout, 'Optimizer cost vs. surface RMSE', ...
    'Diagnostic only: swept settings can change the cost scale', style);
end
