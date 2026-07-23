function [surfaceRows, confidenceByColumn, diagnostics] = ...
        regularizeSurfaceSegments(rawSurfaceRows, rawConfidenceByColumn, ...
        observedMask, interpolatedMask, segmentIds, numberOfImageRows, ...
        pixelSpacingXYMm, options, sourceIndex)
%REGULARIZESURFACESEGMENTS Refine raw paths with bounded curvature smoothing.
% The raw dynamic-programming path decides which probe-facing echo response is
% bone. This stage reduces rapid bending while allowing the final approximation
% to leave the sparse coordinate set within its raw-path and image bounds.
%
% Inputs:
%   rawSurfaceRows       : Raw DP/PCHIP row at each column, with NaN elsewhere.
%   rawConfidenceByColumn: Raw confidence at observed and interpolated columns.
%   observedMask         : Logical columns directly selected from image evidence.
%   interpolatedMask     : Logical columns filled across accepted short gaps.
%   segmentIds           : Nonzero segment label at each retained column.
%   numberOfImageRows    : Height of the displayed B-mode image.
%   pixelSpacingXYMm     : [xSpacing,ySpacing] in millimetres.
%   options              : Validated extraction and regularization settings.
%   sourceIndex          : Source-frame identifier used in fallback warnings.
%
% Outputs:
%   surfaceRows       : Final subpixel row at each retained column.
%   confidenceByColumn: Raw confidence reduced according to refinement movement
%                       and decayed across interpolated gaps.
%   diagnostics       : Scalar struct containing status, movement, bound-hit,
%                       and before/after roughness audit values.

surfaceRows = rawSurfaceRows;
confidenceByColumn = rawConfidenceByColumn;
validMask = isfinite(rawSurfaceRows);

% Signed movement retains direction for audit. Absent columns remain NaN so
% downstream code cannot mistake them for unchanged surface samples.
displacementMmByColumn = nan(size(rawSurfaceRows));
displacementMmByColumn(validMask) = 0;
boundHitColumnMask = false(size(rawSurfaceRows));

roughnessBeforePerMm = computeSurfaceRoughness( ...
    rawSurfaceRows, segmentIds, pixelSpacingXYMm);

if ~any(validMask)
    diagnostics = buildRegularizationDiagnostics( ...
        'notApplicable', displacementMmByColumn, boundHitColumnMask, ...
        roughnessBeforePerMm, roughnessBeforePerMm);
    return;
end

if ~options.regularizationEnabled
    % Disabled mode is an exact compatibility path, including confidence.
    diagnostics = buildRegularizationDiagnostics( ...
        'disabled', displacementMmByColumn, boundHitColumnMask, ...
        roughnessBeforePerMm, roughnessBeforePerMm);
    return;
end

segmentNumbers = unique(double(segmentIds(validMask)));
segmentNumbers(segmentNumbers == 0) = [];
numberAttempted = 0;
numberSucceeded = 0;
numberFailed = 0;

for segmentNumber = segmentNumbers(:).'
    segmentColumns = find(double(segmentIds) == segmentNumber);

    % Fewer than three columns cannot define a second derivative. Preserve
    % these rare short segments exactly as the legacy extraction produced them.
    if numel(segmentColumns) < 3
        continue;
    end

    numberAttempted = numberAttempted + 1;
    [refinedRows, segmentBoundHits, succeeded, failureMessage] = ...
        regularizeOneSurfaceSegment( ...
        rawSurfaceRows(segmentColumns), ...
        rawConfidenceByColumn(segmentColumns), ...
        observedMask(segmentColumns), numberOfImageRows, ...
        pixelSpacingXYMm, options);

    if succeeded
        numberSucceeded = numberSucceeded + 1;
        surfaceRows(segmentColumns) = refinedRows;
        boundHitColumnMask(segmentColumns) = segmentBoundHits;
        displacementMmByColumn(segmentColumns) = ...
            (refinedRows - rawSurfaceRows(segmentColumns)) * ...
            pixelSpacingXYMm(2);
    else
        % A numerical failure must never remove an otherwise valid surface.
        numberFailed = numberFailed + 1;
        warning( ...
            'extractBoneSurfacesFromSegmentation:RegularizationFallback', ...
            ['Regularization failed for sourceIndex %g, segment %d: %s ' ...
            'The raw path was retained.'], ...
            sourceIndex, segmentNumber, failureMessage);
    end
end

if numberAttempted == 0
    regularizationStatus = 'notApplicable';
elseif numberFailed == 0
    regularizationStatus = 'applied';
elseif numberSucceeded == 0
    regularizationStatus = 'fallback';
else
    regularizationStatus = 'partialFallback';
end

% The final location may leave the listed coordinates, so confidence derives
% from raw image support and decays monotonically with movement.
confidenceByColumn = applyDisplacementConfidenceDecay( ...
    rawConfidenceByColumn, displacementMmByColumn, observedMask, ...
    interpolatedMask, segmentIds, pixelSpacingXYMm(1), ...
    options.maxInterpolatedGapMm, ...
    options.regularizationMaxDisplacementMm);

roughnessAfterPerMm = computeSurfaceRoughness( ...
    surfaceRows, segmentIds, pixelSpacingXYMm);
diagnostics = buildRegularizationDiagnostics( ...
    regularizationStatus, displacementMmByColumn, boundHitColumnMask, ...
    roughnessBeforePerMm, roughnessAfterPerMm);
end
