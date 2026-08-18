function figureHandle = plotTranslationRotationErrors(perCombinationTable)
%PLOTTRANSLATIONROTATIONERRORS Compare position and orientation accuracy.
% This plot places one hyperparameter combination at its median translation
% and rotation error. Horizontal and vertical lines show the corresponding
% IQR across CMA-ES seeds.
%
% Input:
%   perCombinationTable - Ranked table containing translation and rotation statistics.
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

% Draw both IQR directions before adding the median point markers.
figureHandle = figure('Name', 'Translation and Rotation Errors');
hold on;
for combinationIndex = 1:height(plotTable)

    xMedian = plotTable.medianTranslationErrorMm(combinationIndex);
    yMedian = plotTable.medianRotationErrorDeg(combinationIndex);
    
    plot([plotTable.q25TranslationErrorMm(combinationIndex), ...
          plotTable.q75TranslationErrorMm(combinationIndex)], ...
         [yMedian, yMedian], ...
         '-', 'Color', [0.45 0.45 0.45]);
    plot([xMedian, xMedian], ...
         [plotTable.q25RotationErrorDeg(combinationIndex), ...
          plotTable.q75RotationErrorDeg(combinationIndex)], ...
         '-', 'Color', [0.45 0.45 0.45]);
end
scatter(plotTable.medianTranslationErrorMm, ...
        plotTable.medianRotationErrorDeg, 46, ...
        [0.84 0.37 0.00], 'filled');

% Label only the best combinations so a large sweep does not hide the points.
numberOfLabels = min(20, height(plotTable));
for labelIndex = 1:numberOfLabels
    text(plotTable.medianTranslationErrorMm(labelIndex), ...
         plotTable.medianRotationErrorDeg(labelIndex), ...
         ['  ', char(erase(plotTable.combinationId(labelIndex), "combination_"))], ...
         'FontSize', 8, 'VerticalAlignment', 'bottom');
end
hold off;

grid on;
xlabel('Median translation error (mm)');
ylabel('Median rotation error (deg)');
title('Translation and Rotation Errors with IQR');
end
