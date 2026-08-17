function figureHandle = plotOptimizerCostVsSurfaceRmse(perCombinationTable)
%PLOTOPTIMIZERCOSTVSSURFACERMSE Compare optimizer cost with true accuracy.
% This diagnostic plot places each combination at its median optimizer cost
% and median surface RMSE. IQR lines show seed variation on both axes.
%
% Input:
%   perCombinationTable - Combination table containing cost and RMSE statistics.
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

% Draw cost and RMSE IQRs before drawing the median markers.
figureHandle = figure('Name', 'Optimizer Cost and Surface RMSE', 'Color', 'w');
hold on;
for combinationIndex = 1:height(plotTable)
    xMedian = plotTable.medianBestCost(combinationIndex);
    yMedian = plotTable.medianSurfaceRmseMm(combinationIndex);
    plot([plotTable.q25BestCost(combinationIndex), ...
          plotTable.q75BestCost(combinationIndex)], ...
         [yMedian, yMedian], '-', 'Color', [0.45 0.45 0.45]);
    plot([xMedian, xMedian], ...
         [plotTable.q25SurfaceRmseMm(combinationIndex), ...
          plotTable.q75SurfaceRmseMm(combinationIndex)], ...
         '-', 'Color', [0.45 0.45 0.45]);
end
scatter(plotTable.medianBestCost, plotTable.medianSurfaceRmseMm, ...
    46, [0.20 0.63 0.17], 'filled');

% Label only the best combinations to keep a large diagnostic readable.
numberOfLabels = min(20, height(plotTable));
for labelIndex = 1:numberOfLabels
    text(plotTable.medianBestCost(labelIndex), ...
         plotTable.medianSurfaceRmseMm(labelIndex), ...
         ['  ', char(plotTable.combinationId(labelIndex))], ...
         'FontSize', 8, 'VerticalAlignment', 'bottom');
end
hold off;

grid on;
xlabel('Median optimizer bestCost');
ylabel('Median surface RMSE (mm)');
title({'Optimizer Cost vs. Ground-Truth Surface Error', ...
       'Diagnostic only: swept settings can change the cost scale'});
end
