function candidateMask = buildCandidateMask( ...
        pixelCoordinates, imageSize, resultIndex)
%BUILDCANDIDATEMASK Validate and rasterize authoritative boundary coordinates.
% The sparse raster lets existing image and dynamic-programming operations work
% efficiently without treating filled segmentation pixels as surface choices.
%
% Inputs:
%   pixelCoordinates : N-by-2 numeric [row,column] candidate coordinates.
%   imageSize        : [numberOfRows,numberOfColumns] of the displayed image.
%   resultIndex      : One-based result position used in validation messages.
%
% Output:
%   candidateMask : Image-sized logical raster containing unique candidates.

% Require the exported coordinate convention exactly. In particular, a plain
% empty array is ambiguous; exporters should preserve the documented 0-by-2
% shape when a processed frame has no candidate surface pixels.
if ~isnumeric(pixelCoordinates) || ~isreal(pixelCoordinates) || ...
        ~ismatrix(pixelCoordinates) || size(pixelCoordinates, 2) ~= 2
    error('extractBoneSurfacesFromSegmentation:InvalidPixelCoordinates', ...
        ['pixelCoordinates at result %d must be a numeric N-by-2 ' ...
        '[row,column] array.'], resultIndex);
end

coordinateValues = double(pixelCoordinates);
if any(~isfinite(coordinateValues(:))) || ...
        any(coordinateValues(:) ~= round(coordinateValues(:)))
    error('extractBoneSurfacesFromSegmentation:InvalidPixelCoordinates', ...
        ['pixelCoordinates at result %d must contain finite integer ' ...
        '[row,column] values.'], resultIndex);
end

if any(coordinateValues(:, 1) < 1) || ...
        any(coordinateValues(:, 1) > imageSize(1)) || ...
        any(coordinateValues(:, 2) < 1) || ...
        any(coordinateValues(:, 2) > imageSize(2))
    error('extractBoneSurfacesFromSegmentation:InvalidPixelCoordinates', ...
        ['pixelCoordinates at result %d must lie inside the displayed ' ...
        'image bounds.'], resultIndex);
end

candidateMask = false(imageSize);
if isempty(coordinateValues)
    return;
end

% Raster assignment naturally removes duplicates and makes extraction
% independent of the order in which boundary points were exported.
linearIndices = sub2ind(imageSize, ...
    coordinateValues(:, 1), coordinateValues(:, 2));
candidateMask(linearIndices) = true;
end
