function displayImageIntersections(images, intersections, figureName)
%DISPLAYIMAGEINTERSECTIONS Display precomputed intersection pixels on 2D images.
% This function declaration defines a debug-only helper for checking the
% image-space output from computeProbeFacingPixelsForPose.
%
% What this function does:
%   This function receives already-loaded 2D images and already-computed
%   intersection results. It draws every image in a tiled figure, then
%   overlays the full mesh-plane hit pixels and the probe-facing pixels.
%
% Why this function exists:
%   The cost function needs a quick visual sanity check while the
%   optimization pipeline is still being built. This helper does not compute
%   any geometry, so it shows exactly what the caller already computed.

%% HANDLE OPTIONAL INPUTS

% Use a clear default figure name when the caller does not pass one.
if nargin < 3 || isempty(figureName)
    figureName = 'Image Intersections';
end

% Convert MATLAB string input to a character vector so figure titles stay consistent.
figureName = char(figureName);

% Treat one numeric image as a one-item image list so the plotting code can stay shared.
if isnumeric(images) && ismatrix(images)
    images = {images};
end

% Convert a 3D numeric image stack into a cell list because each tile expects one matrix.
if isnumeric(images) && ndims(images) == 3
    images = squeeze(num2cell(images, [1 2])).';
end

% Check that the image list is a cell array because every image can be a separate matrix.
validateattributes(images, {'cell'}, {'vector'}, mfilename, 'images');
% Check that the intersections are a struct array because computeProbeFacingPixelsForPose returns structs.
validateattributes(intersections, {'struct'}, {'vector'}, mfilename, 'intersections');

% Count images once so the layout and input-size checks use the same value.
n_images = numel(images);
% Count intersection results once so the size check can explain mismatched inputs early.
n_intersections = numel(intersections);

% Stop early when the caller passes mismatched lists because overlays would otherwise go on the wrong images.
if n_images ~= n_intersections
    error('displayImageIntersections:InputSizeMismatch', ...
          'The number of images (%d) must match the number of intersections (%d).', ...
          n_images, n_intersections);
end

%% CREATE THE 2D DEBUG FIGURE

% Open one named figure so this debug display is easy to find among other figures.
fig = figure('Name', figureName);

% Handle the empty-input case with a simple message instead of creating an invalid tiled layout.
if n_images == 0

    % Create one axes object so the figure can explain why nothing is drawn.
    ax_empty = axes(fig);
    % Write a centered message because there are no images or intersections to inspect.
    text(ax_empty, 0.5, 0.5, 'No images available for intersection display.', ...
         'HorizontalAlignment', 'center', ...
         'Interpreter', 'none');
    % Hide axes ticks because the empty message is informational only.
    axis(ax_empty, 'off');

    % Force MATLAB to draw the empty-state figure before returning.
    drawnow;
    % Return early because there is no tiled image content to build.
    return;
end

% Choose a compact number of tile columns so many images still fit in one figure.
n_tile_cols = ceil(sqrt(n_images));
% Choose the matching number of tile rows so every image gets one tile.
n_tile_rows = ceil(n_images / n_tile_cols);

% Create the tiled layout with compact spacing so image details have more room.
tile_layout = tiledlayout(fig, n_tile_rows, n_tile_cols, 'TileSpacing', 'compact', 'Padding', 'compact');

%% DRAW EACH IMAGE WITH ITS PRECOMPUTED INTERSECTION OVERLAYS

% Loop over every image so each frame gets its own 2D inspection tile.
for idx_image = 1:n_images

    % Read the current image from the cell list so this tile uses one source frame.
    current_image = images{idx_image};

    % Read the current intersection struct so overlays correspond to the same image index.
    current_intersection = intersections(idx_image);

    % Create the next tile before drawing the image and overlays.
    ax_tile = nexttile(tile_layout);
    display_image = current_image.';  % Transpose the stored image because sequence packets are stored as [width, height].
    imagesc(ax_tile, display_image);
    axis(ax_tile, 'image');
    colormap(ax_tile, gray);
    hold(ax_tile, 'on');
    xlabel(ax_tile, 'Column');
    ylabel(ax_tile, 'Row');
    title(ax_tile, buildIntersectionTileTitle(idx_image, current_intersection), 'Interpreter', 'none');

    % Draw every rasterized hit pixel so the full mesh-plane contact is visible.
    if isfield(current_intersection, 'pixelList') && ~isempty(current_intersection.pixelList)

        % Read the stored pixel rows because pixelList is returned as [row, col].
        pixel_rows = current_intersection.pixelList(:, 1);
        % Read the stored pixel columns because MATLAB plot expects x-values first.
        pixel_cols = current_intersection.pixelList(:, 2);

        % Plot full intersection pixels in yellow so they stand out on the grayscale image.
        plot(ax_tile, pixel_cols, pixel_rows, 'y.', 'MarkerSize', 10);
    end

    % Draw selected probe-facing pixels so the future cost-function samples are clear.
    if isfield(current_intersection, 'probeFacingPixels') && ~isempty(current_intersection.probeFacingPixels)

        % Read selected rows because probeFacingPixels is returned as [row, col].
        selected_rows = current_intersection.probeFacingPixels(:, 1);
        % Read selected columns because MATLAB plot expects x-values first.
        selected_cols = current_intersection.probeFacingPixels(:, 2);

        % Plot selected probe-facing pixels in green so they are easy to compare with all hits.
        plot(ax_tile, selected_cols, selected_rows, 'go', 'MarkerSize', 5, 'LineWidth', 1);
    end
end

%% FINISH THE DISPLAY STYLE

% Add one shared title so the tiled figure is easy to recognize.
title(tile_layout, figureName, 'Interpreter', 'none');

% Force MATLAB to draw the figure before the caller continues.
drawnow;
end

function tileTitle = buildIntersectionTileTitle(idx_image, intersection)
%BUILDINTERSECTIONTILETITLE Create a readable title for one debug image tile.
% This local helper keeps title formatting out of the main plotting loop.

% Start with the image index because every intersection result should match one image.
tileTitle = sprintf('Image %d', idx_image);

% Include the timestamp when the intersection result stores one, because it helps trace the source frame.
if isfield(intersection, 'timestamp') && ~isempty(intersection.timestamp)
    tileTitle = sprintf('%s | t = %.3f', tileTitle, double(intersection.timestamp));
end
end
