function confidenceByColumn = applyDisplacementConfidenceDecay( ...
        rawConfidenceByColumn, displacementMmByColumn, observedMask, ...
        interpolatedMask, segmentIds, xSpacingMm, maximumGapMm, ...
        maximumDisplacementMm)
%APPLYDISPLACEMENTCONFIDENCEDECAY Score support for the refined approximation.
% Observed confidence decreases exponentially as the final curve moves away
% from the raw image-supported location. Gap confidence retains the existing
% lower-endpoint decay after endpoint confidence has been adjusted.
%
% Inputs:
%   rawConfidenceByColumn   : Confidence before regularization.
%   displacementMmByColumn  : Signed refinement movement in millimetres.
%   observedMask            : Logical directly observed columns.
%   interpolatedMask        : Logical accepted-gap columns.
%   segmentIds              : Nonzero segment label at retained columns.
%   xSpacingMm              : Lateral pixel spacing in millimetres.
%   maximumGapMm            : Existing gap-confidence decay scale.
%   maximumDisplacementMm   : Refinement movement bound and decay scale.
%
% Output:
%   confidenceByColumn : Final confidence at observed and interpolated columns.

confidenceByColumn = rawConfidenceByColumn;
observedMovementMm = abs(displacementMmByColumn(observedMask));
confidenceByColumn(observedMask) = ...
    rawConfidenceByColumn(observedMask) .* ...
    exp(-observedMovementMm / maximumDisplacementMm);
confidenceByColumn(observedMask) = min(max( ...
    confidenceByColumn(observedMask), 0), 1);
confidenceByColumn(interpolatedMask) = nan;

segmentNumbers = unique(double(segmentIds(segmentIds > 0)));
for segmentNumber = segmentNumbers(:).'
    currentObservedColumns = find( ...
        double(segmentIds) == segmentNumber & observedMask);

    for endpointIndex = 1:(numel(currentObservedColumns) - 1)
        leftColumn = currentObservedColumns(endpointIndex);
        rightColumn = currentObservedColumns(endpointIndex + 1);
        if rightColumn <= leftColumn + 1
            continue;
        end

        gapColumns = (leftColumn + 1):(rightColumn - 1);
        gapColumns = gapColumns(interpolatedMask(gapColumns));
        if isempty(gapColumns)
            continue;
        end

        gapLengthMm = numel(gapColumns) * xSpacingMm;
        endpointConfidence = min( ...
            confidenceByColumn(leftColumn), ...
            confidenceByColumn(rightColumn));
        confidenceByColumn(gapColumns) = endpointConfidence * ...
            exp(-gapLengthMm / maximumGapMm);
    end
end
end
