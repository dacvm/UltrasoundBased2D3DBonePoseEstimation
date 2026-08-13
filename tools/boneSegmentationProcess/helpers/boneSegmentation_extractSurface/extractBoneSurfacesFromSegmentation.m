function [surfaceResults, extractionMetadata] = extractBoneSurfacesFromSegmentation( ...
        segmentationResults, ultrasoundSequence, options)
%EXTRACTBONESURFACESFROMSEGMENTATION Estimate thin bone-surface curves.
% This function converts cleaned boundary coordinates into one or more thin
% surface segments. It scores only the supplied coordinates in the matching
% raw B-mode image, then uses global continuity and bounded curvature to select
% a stable probe-facing bone surface.
%
% Inputs:
%   segmentationResults : Group struct vector exported by the semi-automatic
%                         bone segmentation tool. Every group contains name,
%                         bone, path, and group-local data records.
%   ultrasoundSequence  : Group struct vector containing matching name, bone,
%                         path, and group-local sourceIndex/plane records.
%   options             : Optional scalar struct whose nested fields override
%                         the JSON defaults in tools/boneSegmentationProcess/
%                         configs. The groups follow the extraction stages:
%                         imageEvidence, surfaceTracing, gapInterpolation, and
%                         regularization.
%
% Outputs:
%   surfaceResults      : Group struct vector aligned with segmentationResults.
%                         Every group retains name, bone, path, and data; each
%                         data record contains the extracted-surface fields,
%                         confidence, spacing, summary values, and an empty
%                         surfaceCoordinatesXYZRef field reserved for later 3D
%                         recovery in the reference coordinate frame.
%   extractionMetadata : Scalar struct describing the algorithm, coordinate
%                        convention, creation time, and resolved configuration.

if nargin < 3
    options = struct();
end

% Resolve one complete configuration before validating inputs so every frame
% is processed with the same documented settings.
resolvedOptions = resolveExtractionOptions(options);

% Match groups by their exact metadata and records by sourceIndex. The nested
% mapping makes repeated source indices in different directories unambiguous.
inputMatches = validateAndMatchInputs( ...
    segmentationResults, ultrasoundSequence);

% Preserve every source-directory group, including groups without records.
surfaceRecordTemplate = createSurfaceResultTemplate();
emptySurfaceData = repmat(surfaceRecordTemplate, 1, 0);
surfaceGroupTemplate = struct( ...
    'name', '', ...
    'bone', '', ...
    'path', '', ...
    'data', emptySurfaceData);
numberOfGroups = numel(segmentationResults);
surfaceResults = repmat(surfaceGroupTemplate, 1, numberOfGroups);

for groupIndex = 1:numberOfGroups
    currentSegmentationGroup = segmentationResults(groupIndex);
    currentUltrasoundGroup = ultrasoundSequence( ...
        inputMatches(groupIndex).ultrasoundGroupIndex);
    numberOfGroupResults = numel(currentSegmentationGroup.data);
    currentGroupSurfaceData = repmat( ...
        surfaceRecordTemplate, 1, numberOfGroupResults);

    % Copy the segmentation hierarchy because it defines the public output
    % order even when ultrasound groups or records arrive in another order.
    surfaceResults(groupIndex).name = currentSegmentationGroup.name;
    surfaceResults(groupIndex).bone = currentSegmentationGroup.bone;
    surfaceResults(groupIndex).path = currentSegmentationGroup.path;

    for localResultIndex = 1:numberOfGroupResults
        segmentationEntry = currentSegmentationGroup.data(localResultIndex);
        ultrasoundLocalIndex = inputMatches(groupIndex). ...
            ultrasoundLocalIndices(localResultIndex);
        ultrasoundEntry = ...
            currentUltrasoundGroup.data(ultrasoundLocalIndex);
        frameIdentity = sprintf( ...
            'group "%s", local position %d, sourceIndex %g', ...
            char(string(currentSegmentationGroup.name)), ...
            localResultIndex, double(segmentationEntry.sourceIndex));

        % Validate and align the stored packet before checking status. This
        % keeps skipped outputs correctly sized and catches corrupt files early.
        [displayedImage, candidateMask, pixelSpacingXYMm] = ...
            prepareFrameData( ...
                segmentationEntry, ultrasoundEntry, frameIdentity);

        numberOfColumns = size(displayedImage, 2);
        currentResult = createEmptySizedResult( ...
            segmentationEntry, numberOfColumns, pixelSpacingXYMm);

        if ~strcmpi(char(string(segmentationEntry.status)), 'processed')
            % Unprocessed coordinates are not evidence that no bone exists, so
            % retain that distinction instead of reporting an empty extraction.
            currentResult.status = 'skippedUnprocessed';
            currentGroupSurfaceData(localResultIndex) = currentResult;
            continue;
        end

        if ~any(candidateMask(:))
            % A processed record with no exported candidates is a valid
            % no-surface outcome. Documentation masks do not override it.
            currentResult.status = 'noSurface';
            currentGroupSurfaceData(localResultIndex) = currentResult;
            continue;
        end

        % Estimate evidence only at exported coordinates, then choose one
        % globally consistent depth from competing points in each scan line.
        candidateConfidence = computeCandidateConfidence( ...
            displayedImage, candidateMask, pixelSpacingXYMm, resolvedOptions);
        frameSurface = traceSurfacePaths( ...
            candidateConfidence, candidateMask, pixelSpacingXYMm, ...
            resolvedOptions, frameIdentity);

        currentResult.surfaceRowByColumn = ...
            frameSurface.surfaceRowByColumn;
        currentResult.rawSurfaceRowByColumn = ...
            frameSurface.rawSurfaceRowByColumn;
        currentResult.observedColumnMask = frameSurface.observedColumnMask;
        currentResult.interpolatedColumnMask = ...
            frameSurface.interpolatedColumnMask;
        currentResult.segmentIdByColumn = frameSurface.segmentIdByColumn;
        currentResult.confidenceByColumn = frameSurface.confidenceByColumn;
        currentResult.rawConfidenceByColumn = ...
            frameSurface.rawConfidenceByColumn;
        currentResult.regularizationDisplacementMmByColumn = ...
            frameSurface.regularizationDisplacementMmByColumn;
        currentResult.regularizationBoundHitColumnMask = ...
            frameSurface.regularizationBoundHitColumnMask;
        currentResult.regularizationStatus = ...
            frameSurface.regularizationStatus;
        currentResult.roughnessBeforePerMm = ...
            frameSurface.roughnessBeforePerMm;
        currentResult.roughnessAfterPerMm = ...
            frameSurface.roughnessAfterPerMm;
        currentResult.regularizationRmsDisplacementMm = ...
            frameSurface.regularizationRmsDisplacementMm;
        currentResult.regularizationMaxDisplacementMm = ...
            frameSurface.regularizationMaxDisplacementMm;
        currentResult.observedLengthMm = frameSurface.observedLengthMm;
        currentResult.interpolatedLengthMm = ...
            frameSurface.interpolatedLengthMm;
        currentResult.meanConfidence = frameSurface.meanConfidence;
        currentResult.numberOfSegments = frameSurface.numberOfSegments;

        validColumns = find(isfinite(frameSurface.surfaceRowByColumn));
        currentResult.surfaceCoordinatesXY = [ ...
            double(validColumns(:)), ...
            frameSurface.surfaceRowByColumn(validColumns).'];

        if isempty(validColumns)
            currentResult.status = 'noSurface';
        else
            currentResult.status = 'extracted';
        end

        currentGroupSurfaceData(localResultIndex) = currentResult;
    end
    surfaceResults(groupIndex).data = currentGroupSurfaceData;
end

% Record reproducibility information once rather than duplicating it in every
% per-frame result.
extractionMetadata = buildExtractionMetadata(resolvedOptions, surfaceResults);
end
