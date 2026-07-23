function [surfaceResults, extractionMetadata] = extractBoneSurfacesFromSegmentation( ...
        segmentationResults, ultrasoundSequence, options)
%EXTRACTBONESURFACESFROMSEGMENTATION Estimate thin bone-surface curves.
% This function converts cleaned boundary coordinates into one or more thin
% surface segments. It scores only the supplied coordinates in the matching
% raw B-mode image, then uses global continuity and bounded curvature to select
% a stable probe-facing bone surface.
%
% Inputs:
%   segmentationResults : Struct vector exported by the semi-automatic bone
%                         segmentation tool. Each entry must contain
%                         sequencePosition, sourceIndex, pixelCoordinates, and
%                         status. pixelCoordinates uses [row,column] order.
%   ultrasoundSequence  : Struct vector containing sourceIndex and plane. The
%                         plane must contain image, W, H, nRows, and nCols.
%   options             : Optional scalar struct whose fields override the JSON
%                         defaults in tools/boneSegmentationProcess/configs.
%
% Outputs:
%   surfaceResults      : Struct vector aligned with segmentationResults. Each
%                         entry contains the extracted surface, confidence,
%                         segment labels, physical spacing, and summary values.
%   extractionMetadata : Scalar struct describing the algorithm, coordinate
%                        convention, creation time, and resolved configuration.

if nargin < 3
    options = struct();
end

% Resolve one complete configuration before validating inputs so every frame
% is processed with the same documented settings.
resolvedOptions = resolveExtractionOptions(options);

% Match frames by sourceIndex so reordered ultrasound inputs cannot silently
% attach boundary coordinates to the wrong B-mode image.
ultrasoundMatchIndices = validateAndMatchInputs(segmentationResults, ultrasoundSequence);

% Preallocate one output record per segmentation entry to preserve the input
% order expected by downstream processing.
numberOfResults = numel(segmentationResults);
surfaceResults = repmat(createSurfaceResultTemplate(), 1, numberOfResults);

for resultIndex = 1:numberOfResults
    segmentationEntry = segmentationResults(resultIndex);
    ultrasoundEntry   = ultrasoundSequence(ultrasoundMatchIndices(resultIndex));

    % Validate and align the stored packet before checking status. This keeps
    % skipped outputs correctly sized and catches corrupt source files early.
    [displayedImage, candidateMask, pixelSpacingXYMm] = prepareFrameData(segmentationEntry, ultrasoundEntry, resultIndex);

    numberOfColumns = size(displayedImage, 2);
    currentResult = createEmptySizedResult(segmentationEntry, numberOfColumns, pixelSpacingXYMm);

    if ~strcmpi(char(string(segmentationEntry.status)), 'processed')
        % Unprocessed coordinates are not evidence that no bone exists, so preserve
        % that distinction instead of reporting a successful empty extraction.
        currentResult.status = 'skippedUnprocessed';
        surfaceResults(resultIndex) = currentResult;
        continue;
    end

    if ~any(candidateMask(:))
        % A processed record with no exported candidates is a valid no-surface
        % outcome. A documentation mask must never override this decision.
        currentResult.status = 'noSurface';
        surfaceResults(resultIndex) = currentResult;
        continue;
    end

    % Estimate evidence only at exported coordinates, then choose one globally
    % consistent depth from the competing boundary points in each scan line.
    candidateConfidence = computeCandidateConfidence(displayedImage, candidateMask, pixelSpacingXYMm, resolvedOptions);
    frameSurface        = traceSurfacePaths(candidateConfidence, candidateMask, pixelSpacingXYMm, resolvedOptions, segmentationEntry.sourceIndex);

    currentResult.surfaceRowByColumn                    = frameSurface.surfaceRowByColumn;
    currentResult.rawSurfaceRowByColumn                 = frameSurface.rawSurfaceRowByColumn;
    currentResult.observedColumnMask                    = frameSurface.observedColumnMask;
    currentResult.interpolatedColumnMask                = frameSurface.interpolatedColumnMask;
    currentResult.segmentIdByColumn                     = frameSurface.segmentIdByColumn;
    currentResult.confidenceByColumn                    = frameSurface.confidenceByColumn;
    currentResult.rawConfidenceByColumn                 = frameSurface.rawConfidenceByColumn;
    currentResult.regularizationDisplacementMmByColumn  = frameSurface.regularizationDisplacementMmByColumn;
    currentResult.regularizationBoundHitColumnMask      = frameSurface.regularizationBoundHitColumnMask;
    currentResult.regularizationStatus                  = frameSurface.regularizationStatus;
    currentResult.roughnessBeforePerMm                  = frameSurface.roughnessBeforePerMm;
    currentResult.roughnessAfterPerMm                   = frameSurface.roughnessAfterPerMm;
    currentResult.regularizationRmsDisplacementMm       = frameSurface.regularizationRmsDisplacementMm;
    currentResult.regularizationMaxDisplacementMm       = frameSurface.regularizationMaxDisplacementMm;
    currentResult.observedLengthMm                      = frameSurface.observedLengthMm;
    currentResult.interpolatedLengthMm                  = frameSurface.interpolatedLengthMm;
    currentResult.meanConfidence                        = frameSurface.meanConfidence;
    currentResult.numberOfSegments                      = frameSurface.numberOfSegments;

    validColumns = find(isfinite(frameSurface.surfaceRowByColumn));
    currentResult.surfacePixelCoordinatesXY = [ ...
        double(validColumns(:)), ...
        frameSurface.surfaceRowByColumn(validColumns).'];

    if isempty(validColumns)
        currentResult.status = 'noSurface';
    else
        currentResult.status = 'extracted';
    end

    surfaceResults(resultIndex) = currentResult;
end

% Record reproducibility information once rather than duplicating it in every
% per-frame result.
extractionMetadata = buildExtractionMetadata(resolvedOptions, surfaceResults);
end
