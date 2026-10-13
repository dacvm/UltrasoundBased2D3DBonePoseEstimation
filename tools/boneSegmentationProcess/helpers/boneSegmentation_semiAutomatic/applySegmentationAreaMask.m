function [segmentationMask, pixelCoordinates] = ...
        applySegmentationAreaMask( ...
            fullSegmentationMask, fullBoundaryCoordinates, segmentationAreaMask)
%APPLYSEGMENTATIONAREAMASK Restrict only the final segmentation result.
% This function clips the completed full-image region mask and filters its
% existing boundary coordinates. It is needed to exclude results outside a
% user-selected area without introducing artificial points along the freehand
% cut edge.
%
% Inputs:
%   fullSegmentationMask     : Logical full-image result after all processing.
%   fullBoundaryCoordinates : N-by-2 [row, column] boundary pixels calculated
%                             before applying the selected area.
%   segmentationAreaMask    : Logical mask whose true pixels are allowed in
%                             the final segmentation result.
%
% Outputs:
%   segmentationMask : Logical full-image result clipped by the selected area.
%   pixelCoordinates : Subset of the original boundary coordinates located
%                      inside the selected area.

% Require matching logical arrays so row/column indices describe both masks
% without resizing or coordinate conversion.
if ~islogical(fullSegmentationMask) || ...
        ~islogical(segmentationAreaMask) || ...
        ~isequal(size(fullSegmentationMask), size(segmentationAreaMask))
    error('applySegmentationAreaMask:InvalidSegmentationAreaMask', ...
        'The segmentation result and area mask must be equal-size logical arrays.');
end

% Clip the region mask only after all full-image processing has completed.
segmentationMask = fullSegmentationMask & segmentationAreaMask;

% Preserve a stable empty N-by-2 coordinate shape when no boundary exists.
if isempty(fullBoundaryCoordinates)
    pixelCoordinates = zeros(0, 2);
    return;
end

% Check coordinates before converting them to linear indices in the area mask.
if ~isnumeric(fullBoundaryCoordinates) || ...
        size(fullBoundaryCoordinates, 2) ~= 2 || ...
        any(~isfinite(fullBoundaryCoordinates(:))) || ...
        any(fullBoundaryCoordinates(:) ~= round(fullBoundaryCoordinates(:))) || ...
        any(fullBoundaryCoordinates(:, 1) < 1) || ...
        any(fullBoundaryCoordinates(:, 1) > size(segmentationAreaMask, 1)) || ...
        any(fullBoundaryCoordinates(:, 2) < 1) || ...
        any(fullBoundaryCoordinates(:, 2) > size(segmentationAreaMask, 2))
    error('applySegmentationAreaMask:InvalidBoundaryCoordinates', ...
        'Boundary coordinates must be finite in-bounds integer [row, column] pairs.');
end

% Convert boundary coordinates once and keep only points permitted by the area.
boundaryLinearIndices = sub2ind( ...
    size(segmentationAreaMask), ...
    fullBoundaryCoordinates(:, 1), ...
    fullBoundaryCoordinates(:, 2));
keepBoundaryPoint = segmentationAreaMask(boundaryLinearIndices);
pixelCoordinates = fullBoundaryCoordinates(keepBoundaryPoint, :);
end
