function figureHandle = plotTranslationRotationErrors(perCombinationTable, topCombinationCount)
%PLOTTRANSLATIONROTATIONERRORS Compare position and orientation accuracy.
% This plot places one hyperparameter combination at its median translation
% and rotation error. Horizontal and vertical lines show the corresponding
% IQR across CMA-ES seeds. The top-ranked combinations are highlighted so
% they match the combinations shown in the surface-RMSE boxplot.
%
% Inputs:
%   perCombinationTable - Ranked table containing translation and rotation statistics.
%   topCombinationCount - Number of best-ranked combinations to highlight.
%
% Output:
%   figureHandle        - Handle to the created MATLAB figure.

% Keep only combinations with both pose-error summaries available.
plotRows = isfinite(perCombinationTable.medianTranslationErrorMm) & ...
           isfinite(perCombinationTable.medianRotationErrorDeg);
plotTable = perCombinationTable(plotRows, :);
if isempty(plotTable)
    error('plotTranslationRotationErrors:NoEvaluatedCombinations', ...
        'No evaluated combinations are available for the pose-error plot.');
end

% Collect the seed statistics on each axis in [q25, median, q75] order.
translationStatistics = [plotTable.q25TranslationErrorMm, ...
                         plotTable.medianTranslationErrorMm, ...
                         plotTable.q75TranslationErrorMm];
rotationStatistics    = [plotTable.q25RotationErrorDeg, ...
                         plotTable.medianRotationErrorDeg, ...
                         plotTable.q75RotationErrorDeg];

% Highlight the same top combinations as the other ranked plots, and colour
% the points on the RMSE range shared by every evaluation figure.
isTopCombination  = plotTable.combinationRank <= topCombinationCount;
combinationLabels = erase(string(plotTable.combinationId), "combination_");
colorLimits       = getSurfaceRmseColorLimits(perCombinationTable);

% Draw the points on the shared evaluation figure layout.
style = getEvaluationPlotStyle();
figureHandle = createEvaluationFigure('Translation and Rotation Errors', style.figureSizeCm, style);
layout = tiledlayout(figureHandle, 1, 1, 'Padding', 'compact');
ax = nexttile(layout);
plotMedianIqrScatter(ax, translationStatistics, rotationStatistics, ...
                     plotTable.medianSurfaceRmseMm, colorLimits, ...
                     isTopCombination, combinationLabels, style);

xlabel(ax, 'Median translation error (mm)');
ylabel(ax, 'Median rotation error (deg)');
addEvaluationFigureTitle(layout, 'Translation vs. rotation error', ...
    'Median per combination; top combinations ranked by median surface RMSE', style);
end
