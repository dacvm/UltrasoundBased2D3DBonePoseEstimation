function figureHandle = plotHyperparameterFacetedHeatmaps(perCombinationTable)
%PLOTHYPERPARAMETERFACETEDHEATMAPS Show interactions between swept settings.
% This function creates one heatmap for each normal-tolerance and missing-
% penalty pair. Each cell shows the median surface RMSE for one combination.
%
% Input:
%   perCombinationTable - Combination table containing hyperparameters and RMSE.
%
% Output:
%   figureHandle        - Handle to the created MATLAB figure.

% Build stable axis and facet values from the complete combination table.
minReferenceValues      = unique(perCombinationTable.minReferencePixels, 'sorted');
nMinValues              = unique(perCombinationTable.nMinPixels, 'sorted');
normalToleranceValues   = unique(perCombinationTable.normalFacingToleranceDeg, 'sorted');
lambdaValues            = unique(perCombinationTable.lambdaMissing, 'sorted');

% Use one colour range so colours have the same meaning in every panel.
finiteRmse = perCombinationTable.medianSurfaceRmseMm(isfinite(perCombinationTable.medianSurfaceRmseMm));
if isempty(finiteRmse)
    error('plotHyperparameterFacetedHeatmaps:NoEvaluatedCombinations', ...
          'No evaluated combinations are available for the heatmaps.');
end
colorLimits = [min(finiteRmse), max(finiteRmse)];
if colorLimits(1) == colorLimits(2)
    colorLimits = colorLimits + [-0.5 0.5];
end

% Arrange normal tolerance by rows and lambda by columns as agreed for the sweep.
figureHandle = figure('Name', 'Hyperparameter Faceted Heatmaps');
layout = tiledlayout(numel(normalToleranceValues), numel(lambdaValues), ...
    'TileSpacing', 'compact', 'Padding', 'compact');

for normalIndex = 1:numel(normalToleranceValues)
    for lambdaIndex = 1:numel(lambdaValues)

        heatmapValues = nan(numel(nMinValues), numel(minReferenceValues));

        % Fill each cell from the matching hyperparameter-combination row.
        for xIndex = 1:numel(minReferenceValues)
            for yIndex = 1:numel(nMinValues)
                matchingRow = ...
                    perCombinationTable.normalFacingToleranceDeg == normalToleranceValues(normalIndex) & ...
                    perCombinationTable.lambdaMissing == lambdaValues(lambdaIndex) & ...
                    perCombinationTable.minReferencePixels == minReferenceValues(xIndex) & ...
                    perCombinationTable.nMinPixels == nMinValues(yIndex);
                if any(matchingRow)
                    heatmapValues(yIndex, xIndex) = perCombinationTable.medianSurfaceRmseMm(find(matchingRow, 1));
                end
            end
        end

        % Show unavailable combinations through the grey axes background.
        ax = nexttile(layout);
        imagesc(ax, heatmapValues, 'AlphaData', isfinite(heatmapValues));
        ax.Color = [0.82 0.82 0.82];
        ax.YDir = 'normal';
        clim(ax, colorLimits);
        xticks(ax, 1:numel(minReferenceValues));
        xticklabels(ax, string(minReferenceValues));
        yticks(ax, 1:numel(nMinValues));
        yticklabels(ax, string(nMinValues));
        xlabel(ax, 'minReferencePixels');
        ylabel(ax, 'nMinPixels');
        title(ax, sprintf('Tolerance %.4g deg, lambda %.4g', ...
            normalToleranceValues(normalIndex), lambdaValues(lambdaIndex)));
    end
end

colormap(figureHandle, parula);
colorBar = colorbar;
colorBar.Layout.Tile = 'east';
colorBar.Label.String = 'Median surface RMSE (mm)';
title(layout, 'Hyperparameter Effects on Surface RMSE');
end
