function roughnessPerMm = computeSurfaceRoughness( ...
        surfaceRows, segmentIds, pixelSpacingXYMm)
%COMPUTESURFACEROUGHNESS Measure RMS physical curvature over all segments.
% The second derivative ignores absolute depth and constant slope while
% responding strongly to rapid bending and pixel-scale branch excursions.
%
% Inputs:
%   surfaceRows      : Row coordinate at retained columns, with NaN elsewhere.
%   segmentIds       : Nonzero segment label at retained columns.
%   pixelSpacingXYMm : [xSpacing,ySpacing] in millimetres.
%
% Output:
%   roughnessPerMm : RMS d2y/dx2 in inverse millimetres, or NaN when no segment
%                    contains at least three points.

xSpacingMm = pixelSpacingXYMm(1);
ySpacingMm = pixelSpacingXYMm(2);
curvatureValues = zeros(0, 1);
segmentNumbers = unique(double(segmentIds(segmentIds > 0)));

for segmentNumber = segmentNumbers(:).'
    segmentRows = surfaceRows(double(segmentIds) == segmentNumber);
    if numel(segmentRows) < 3
        continue;
    end

    segmentDepthMm = double(segmentRows(:)) * ySpacingMm;
    currentCurvature = diff(segmentDepthMm, 2) / (xSpacingMm ^ 2);
    curvatureValues = [curvatureValues; currentCurvature]; %#ok<AGROW>
end

if isempty(curvatureValues)
    roughnessPerMm = nan;
else
    roughnessPerMm = sqrt(mean(curvatureValues .^ 2));
end
end
