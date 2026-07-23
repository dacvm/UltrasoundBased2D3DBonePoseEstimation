function [surfaceRows, confidenceByColumn, interpolatedMask, segmentIds] = ...
        interpolateAcceptedGaps(observedRows, observedConfidence, ...
        numberOfRows, xSpacingMm, options)
%INTERPOLATEACCEPTEDGAPS Fill bounded gaps and label separate surface segments.
% Interpolation never changes observed rows and never extrapolates past the
% first or last observed point of a retained segment.
%
% Inputs:
%   observedRows       : One-by-columns selected observed rows with NaN gaps.
%   observedConfidence : One-by-columns observed confidence with NaN gaps.
%   numberOfRows       : Image height used to clamp interpolated values.
%   xSpacingMm         : Lateral pixel spacing in millimetres.
%   options            : Validated extraction configuration.
%
% Outputs:
%   surfaceRows       : Observed plus interpolated surface rows.
%   confidenceByColumn: Confidence at every finite surface column.
%   interpolatedMask  : Logical mask marking inferred columns only.
%   segmentIds        : Consecutive nonzero labels for retained segments.

numberOfColumns = numel(observedRows);
surfaceRows = observedRows;
confidenceByColumn = observedConfidence;
interpolatedMask = false(1, numberOfColumns);
segmentIds = zeros(1, numberOfColumns, 'uint16');
observedColumns = find(isfinite(observedRows));

if isempty(observedColumns)
    return;
end

missingGapMm = (diff(observedColumns) - 1) * xSpacingMm;
segmentStarts = [1, find(missingGapMm > ...
    options.maxInterpolatedGapMm) + 1];
segmentEnds = [segmentStarts(2:end) - 1, numel(observedColumns)];

for segmentIndex = 1:numel(segmentStarts)
    currentObservedColumns = observedColumns( ...
        segmentStarts(segmentIndex):segmentEnds(segmentIndex));
    fullSegmentColumns = currentObservedColumns(1): ...
        currentObservedColumns(end);

    if isscalar(currentObservedColumns)
        interpolatedRows = observedRows(currentObservedColumns);
    else
        interpolationMethod = options.interpolationMethod;
        if numel(currentObservedColumns) == 2
            % Two endpoints define a straight line; explicitly using linear
            % avoids implying curvature without supporting observations.
            interpolationMethod = 'linear';
        end
        interpolatedRows = interp1( ...
            double(currentObservedColumns), ...
            observedRows(currentObservedColumns), ...
            double(fullSegmentColumns), interpolationMethod);
    end

    interpolatedRows = min(max(interpolatedRows, 1), numberOfRows);
    surfaceRows(fullSegmentColumns) = interpolatedRows;
    segmentIds(fullSegmentColumns) = uint16(segmentIndex);

    currentInterpolated = ~isfinite(observedRows(fullSegmentColumns));
    interpolatedColumns = fullSegmentColumns(currentInterpolated);
    interpolatedMask(interpolatedColumns) = true;

    % Assign the requested confidence decay separately for each bounded gap.
    for endpointIndex = 1:(numel(currentObservedColumns) - 1)
        leftColumn = currentObservedColumns(endpointIndex);
        rightColumn = currentObservedColumns(endpointIndex + 1);
        if rightColumn <= leftColumn + 1
            continue;
        end

        gapColumns = (leftColumn + 1):(rightColumn - 1);
        gapLengthMm = numel(gapColumns) * xSpacingMm;
        endpointConfidence = min( ...
            observedConfidence(leftColumn), ...
            observedConfidence(rightColumn));
        confidenceByColumn(gapColumns) = endpointConfidence * ...
            exp(-gapLengthMm / options.maxInterpolatedGapMm);
    end
end
end
