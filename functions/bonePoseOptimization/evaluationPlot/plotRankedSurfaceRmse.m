function figureHandle = plotRankedSurfaceRmse(perCombinationTable)
%PLOTRANKEDSURFACERMSE Display combination accuracy and seed stability.
% This plot orders every evaluated combination by median surface RMSE and
% uses horizontal lines to show its Q25-to-Q75 seed interval.
%
% Input:
%   perCombinationTable - Ranked table containing median and quartile RMSE.
%
% Output:
%   figureHandle        - Handle to the created MATLAB figure.

% Failed combinations have no meaningful position on an accuracy plot.
plotRows = isfinite(perCombinationTable.combinationRank);
plotTable = perCombinationTable(plotRows, :);
if isempty(plotTable)
    error('plotRankedSurfaceRmse:NoEvaluatedCombinations', ...
        'No evaluated combinations are available for the ranked RMSE plot.');
end

% Use numeric row positions so long combination IDs stay readable on the y-axis.
yPosition = (1:height(plotTable)).';
figureHandle = figure('Name', 'Ranked Surface RMSE', 'Color', 'w');
hold on;
for combinationIndex = 1:height(plotTable)
    plot([plotTable.q25SurfaceRmseMm(combinationIndex), ...
          plotTable.q75SurfaceRmseMm(combinationIndex)], ...
         [yPosition(combinationIndex), yPosition(combinationIndex)], ...
         '-', 'Color', [0.35 0.35 0.35], 'LineWidth', 1.5);
end
scatter(plotTable.medianSurfaceRmseMm, yPosition, 42, ...
    [0.12 0.47 0.71], 'filled');
hold off;

grid on;
set(gca, 'YDir', 'reverse', ...
    'YTick', yPosition, ...
    'YTickLabel', cellstr(plotTable.combinationId));
xlabel('Surface RMSE (mm)');
ylabel('Hyperparameter combination');
title('Ranked Median Surface RMSE with IQR');
end
