function [surfaceNormalXY, surfaceNormalMask] = estimateSurfaceNormals2D( ...
        surfaceCoordinatesXY, segmentIdByColumn, pixelSpacingXYMm)
%ESTIMATESURFACENORMALS2D Estimate probe-facing normals along 2-D surfaces.
%   [SURFACENORMALXY, SURFACENORMALMASK] = ESTIMATESURFACENORMALS2D(...)
%   differentiates each connected surface segment independently. Performing
%   the differentiation in millimetres is important because ultrasound
%   pixels can have different lateral and axial spacing.
%
%   Inputs:
%     surfaceCoordinatesXY - N-by-2 [x,y] image pixel coordinates. The x
%                            coordinate identifies a column in
%                            segmentIdByColumn.
%     segmentIdByColumn    - Per-column segment labels. Positive labels
%                            identify connected surface segments; zero is
%                            treated as background.
%     pixelSpacingXYMm     - [xSpacing,ySpacing] in millimetres per pixel.
%
%   Outputs:
%     surfaceNormalXY      - N-by-2 unit normals in physical image x,y
%                            coordinates. Invalid rows are [NaN,NaN].
%     surfaceNormalMask    - N-by-1 logical mask indicating rows with a
%                            mathematically valid normal.

arguments
    surfaceCoordinatesXY (:,2) double
    segmentIdByColumn {mustBeNumeric, mustBeVector}
    pixelSpacingXYMm (1,2) double {mustBeFinite, mustBePositive}
end

numberOfPoints = size(surfaceCoordinatesXY, 1);
surfaceNormalXY = nan(numberOfPoints, 2);
surfaceNormalMask = false(numberOfPoints, 1);

% Empty surfaces are valid extraction results and need no special handling
% from their callers.
if numberOfPoints == 0
    return;
end

surfaceColumns = surfaceCoordinatesXY(:, 1);
numberOfColumns = numel(segmentIdByColumn);
if any(~isfinite(surfaceColumns)) || ...
        any(surfaceColumns ~= round(surfaceColumns)) || ...
        any(surfaceColumns < 1) || any(surfaceColumns > numberOfColumns)
    error('estimateSurfaceNormals2D:InvalidSurfaceColumns', ...
        ['The x coordinates must be finite integer column indices within ' ...
         'segmentIdByColumn.']);
end

% Match each compact coordinate row back to the connected-segment label of
% its image column. Normals are never estimated across different labels.
pointSegmentIds = double(segmentIdByColumn(surfaceColumns));
positiveSegmentIds = unique(pointSegmentIds(pointSegmentIds > 0), 'stable');

for segmentIndex = 1:numel(positiveSegmentIds)
    currentSegmentId = positiveSegmentIds(segmentIndex);
    pointIndices = find(pointSegmentIds == currentSegmentId);
    numberOfSegmentPoints = numel(pointIndices);

    % A single point has no curve direction, so its normal remains invalid.
    if numberOfSegmentPoints < 2
        continue;
    end

    segmentCoordinatesPixels = surfaceCoordinatesXY(pointIndices, :);
    segmentCoordinatesMm = (segmentCoordinatesPixels - 1) .* pixelSpacingXYMm;
    segmentTangents = nan(numberOfSegmentPoints, 2);

    % Endpoints use one-sided differences. A two-point segment therefore
    % gives both points the same tangent, as there is only one available
    % direction along that short segment.
    segmentTangents(1, :) = segmentCoordinatesMm(2, :) - ...
        segmentCoordinatesMm(1, :);
    segmentTangents(end, :) = segmentCoordinatesMm(end, :) - ...
        segmentCoordinatesMm(end - 1, :);

    % Interior points use their two neighbours, which is the usual central
    % difference estimate of the local curve direction.
    if numberOfSegmentPoints > 2
        segmentTangents(2:end-1, :) = ...
            segmentCoordinatesMm(3:end, :) - segmentCoordinatesMm(1:end-2, :);
    end

    tangentLengths = vecnorm(segmentTangents, 2, 2);
    validTangents = all(isfinite(segmentTangents), 2) & ...
        isfinite(tangentLengths) & tangentLengths > 0;
    if ~any(validTangents)
        continue;
    end

    % Rotating [dx,dy] clockwise gives [dy,-dx]. Flip the rare opposite
    % orientation so every valid normal points toward decreasing image y,
    % which is the probe-facing direction used by this project.
    segmentNormals = nan(numberOfSegmentPoints, 2);
    segmentNormals(validTangents, :) = ...
        [segmentTangents(validTangents, 2), ...
         -segmentTangents(validTangents, 1)] ./ tangentLengths(validTangents);
    flipMask = validTangents & segmentNormals(:, 2) > 0;
    segmentNormals(flipMask, :) = -segmentNormals(flipMask, :);

    surfaceNormalXY(pointIndices(validTangents), :) = ...
        segmentNormals(validTangents, :);
    surfaceNormalMask(pointIndices(validTangents)) = true;
end
end
