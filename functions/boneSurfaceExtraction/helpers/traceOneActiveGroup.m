function [selectedRows, selectedConfidence] = traceOneActiveGroup( ...
        activeColumns, candidateConfidence, candidateMask, ...
        xSpacingMm, ySpacingMm, options)
%TRACEONEACTIVEGROUP Find the minimum-cost path through one lateral group.
% Dynamic programming compares every mask row, including rows from multiple
% disconnected runs, and returns the globally best first-order smooth path.
%
% Inputs:
%   activeColumns       : Increasing vector of columns in one gap-bounded group.
%   candidateConfidence : Image-sized confidence map.
%   candidateMask       : Sparse raster of exported coordinate candidates.
%   xSpacingMm          : Lateral pixel spacing in millimetres.
%   ySpacingMm          : Axial pixel spacing in millimetres.
%   options             : Validated extraction configuration.
%
% Outputs:
%   selectedRows       : One selected integer row per active column.
%   selectedConfidence : Local candidate confidence at each selected row.

numberOfActiveColumns = numel(activeColumns);
candidateRows = cell(1, numberOfActiveColumns);
backPointers = cell(1, numberOfActiveColumns);
smallValue = 1e-6;

% The path penalty belongs to the surface-tracing stage in the configuration.
surfaceTracingOptions = options.surfaceTracing;

firstColumn = activeColumns(1);
candidateRows{1} = find(candidateMask(:, firstColumn));
previousCosts = -log(max( ...
    candidateConfidence(candidateRows{1}, firstColumn), smallValue));
previousCosts = previousCosts(:);

for activeIndex = 2:numberOfActiveColumns
    currentColumn = activeColumns(activeIndex);
    previousColumn = activeColumns(activeIndex - 1);
    previousRows = candidateRows{activeIndex - 1};
    currentRows = find(candidateMask(:, currentColumn));
    candidateRows{activeIndex} = currentRows;

    endpointDistanceMm = (currentColumn - previousColumn) * xSpacingMm;
    depthDifferenceMm = ( ...
        double(currentRows(:).') - double(previousRows(:))) * ySpacingMm;
    slope = depthDifferenceMm / endpointDistanceMm;
    transitionCost = surfaceTracingOptions.smoothnessWeight * ...
        (slope .^ 2) * endpointDistanceMm;

    accumulatedCosts = previousCosts + transitionCost;
    [bestPreviousCost, bestPreviousIndex] = min( ...
        accumulatedCosts, [], 1);
    currentDataCost = -log(max( ...
        candidateConfidence(currentRows, currentColumn), smallValue));
    previousCosts = currentDataCost(:) + bestPreviousCost(:);
    backPointers{activeIndex} = bestPreviousIndex(:);
end

[~, selectedStateIndex] = min(previousCosts);
selectedRows = zeros(1, numberOfActiveColumns);
selectedRows(end) = candidateRows{end}(selectedStateIndex);

for activeIndex = numberOfActiveColumns:-1:2
    selectedStateIndex = backPointers{activeIndex}(selectedStateIndex);
    selectedRows(activeIndex - 1) = ...
        candidateRows{activeIndex - 1}(selectedStateIndex);
end

linearIndices = sub2ind(size(candidateConfidence), ...
    selectedRows, activeColumns);
selectedConfidence = candidateConfidence(linearIndices);
end
