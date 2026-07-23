function currentResult = createEmptySizedResult( ...
        segmentationEntry, numberOfColumns, pixelSpacingXYMm)
%CREATEEMPTYSIZEDRESULT Initialize one output with image-sized vectors.
% Sized empty vectors let downstream code distinguish missing values by NaN
% without separately reopening the source image to learn its width.
%
% Inputs:
%   segmentationEntry : One source segmentation record.
%   numberOfColumns   : Number of lateral image columns.
%   pixelSpacingXYMm  : [xSpacing,ySpacing] in millimetres.
%
% Output:
%   currentResult     : Initialized scalar surface-result struct.

currentResult = createSurfaceResultTemplate();
currentResult.sequencePosition = segmentationEntry.sequencePosition;
currentResult.sourceIndex = segmentationEntry.sourceIndex;
currentResult.surfaceRowByColumn = nan(1, numberOfColumns);
currentResult.rawSurfaceRowByColumn = nan(1, numberOfColumns);
currentResult.observedColumnMask = false(1, numberOfColumns);
currentResult.interpolatedColumnMask = false(1, numberOfColumns);
currentResult.segmentIdByColumn = zeros(1, numberOfColumns, 'uint16');
currentResult.confidenceByColumn = nan(1, numberOfColumns);
currentResult.rawConfidenceByColumn = nan(1, numberOfColumns);
currentResult.regularizationDisplacementMmByColumn = ...
    nan(1, numberOfColumns);
currentResult.regularizationBoundHitColumnMask = ...
    false(1, numberOfColumns);
currentResult.pixelSpacingXYMm = pixelSpacingXYMm;
end
