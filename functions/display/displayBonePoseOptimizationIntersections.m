function poseEvaluation = displayBonePoseOptimizationIntersections(data, poseVector, config, figureName)
%DISPLAYBONEPOSEOPTIMIZATIONINTERSECTIONS Display mesh-plane intersections on 2D images.
% This function declaration gives the optimization script one display-only helper for image-space inspection.
%
% What this function does:
%   This function evaluates the current mesh pose against every sampled
%   ultrasound image plane, then draws the intersection results inside the
%   2D image views. This makes it easier to inspect whether the projected
%   mesh/image intersection follows the visible bone surface.
%
% Important details:
%   - This function is meant for setup/result inspection only.
%   - This function does not compute an optimization cost.
%   - This function does not run or change the optimizer.

%% HANDLE OPTIONAL INPUTS

% Use the configuration stored inside data when the caller does not pass config.
if nargin < 3 || isempty(config)
    config = data.config;
end

% Check that the configuration is a scalar struct because the geometry helper expects one configuration object.
validateattributes(config, {'struct'}, {'scalar'}, mfilename, 'config');

% Use a clear default figure name when the caller does not pass one.
if nargin < 4 || isempty(figureName)
    figureName = 'Bone Pose Optimization Intersections';
end

% Convert MATLAB string input to a character vector because figure names and titles work consistently with char values.
figureName = char(figureName);

%% EVALUATE THE CURRENT POSE FOR DISPLAY

% Convert the current state vector into the 4-by-4 mesh transform used by the geometry pipeline.
T_mesh_ref = stateVectorToTMatrix(poseVector, data.T_init_originct);

% Compute the mesh-plane intersections for this pose so the 2D overlays match the current 3D scene.
poseEvaluation = computeProbeFacingPixelsForPose( ...
    data.meshVerticesLocal, ...
    data.meshFaces, ...
    data.planes, ...
    T_mesh_ref, ...
    config);

% Read the image planes once because every tiled image uses the matching plane metadata.
planes   = data.planes;
% Count image planes once so the tiled layout can be sized before plotting begins.
n_planes = numel(planes);

%% CREATE THE 2D INTERSECTION FIGURE

% Open one named figure so the initial and final intersection views are easy to identify.
fig = figure('Name', figureName);

% Handle the empty-plane case with a simple message instead of creating an invalid tiled layout.
if n_planes == 0

    % Create one axes object so the figure still explains why no overlays are shown.
    ax_empty = axes(fig);
    % Write a centered message because there are no image planes to draw.
    text(ax_empty, 0.5, 0.5, 'No image planes available for intersection display.', ...
         'HorizontalAlignment', 'center', ...
         'Interpreter', 'none');
    % Hide axes ticks because the empty message is informational only.
    axis(ax_empty, 'off');

    % Force MATLAB to draw the empty-state figure before returning.
    drawnow;
    % Return early because there is no tiled image content to build.
    return;
end

% Choose a compact number of tile columns so many image planes still fit in one figure.
n_tile_cols = ceil(sqrt(n_planes));

% Choose the matching number of tile rows so every image plane gets one tile.
n_tile_rows = ceil(n_planes / n_tile_cols);

% Create the tiled layout with compact spacing so image details have more room.
tile_layout = tiledlayout(fig, n_tile_rows, n_tile_cols, 'TileSpacing', 'compact', 'Padding', 'compact');

%% DRAW EACH IMAGE WITH ITS INTERSECTION OVERLAYS

% Loop over every image plane so each plane gets its own 2D inspection tile.
for idx_plane = 1:n_planes
    % Read the current plane so the image and physical spacing stay matched.
    plane = planes(idx_plane);

    % Read the current evaluation result so overlays correspond to the same image plane.
    evaluation = poseEvaluation(idx_plane);

    % Create the next tile before drawing the image and overlays.
    ax_tile = nexttile(tile_layout);
    display_image = plane.image.';    % Transpose the stored image because sequence packets are stored as [width, height].
    imagesc(ax_tile, display_image);
    axis(ax_tile, 'image');
    colormap(ax_tile, gray);
    hold(ax_tile, 'on');
    xlabel(ax_tile, 'Column');
    ylabel(ax_tile, 'Row');
    title(ax_tile, sprintf('Plane %d | t = %.3f', idx_plane, double(plane.timestamp)));

    % Compute physical pixel width for converting UV segment coordinates into image columns.
    du = plane.W / max(plane.nCols, 1);
    % Compute physical pixel height for converting UV segment coordinates into image rows.
    dv = plane.H / max(plane.nRows, 1);

    % Overlay every rasterized hit pixel so the full mesh/plane contact is visible.
    if ~isempty(evaluation.pixelList)
        % Read the stored pixel rows because pixelList is returned as [row, col].
        pixel_rows = evaluation.pixelList(:, 1);
        % Read the stored pixel columns because MATLAB plot expects x-values first.
        pixel_cols = evaluation.pixelList(:, 2);

        % Plot full intersection pixels in yellow to match the validated display example.
        plot(ax_tile, pixel_cols, pixel_rows, 'y.', 'MarkerSize', 10);
    end

    % Overlay every clipped UV segment so the continuous intersection curve is visible.
    for idx_segment = 1:numel(evaluation.segmentsUV)
        % Read the current clipped UV segment from the evaluation cell array.
        current_segmentUV = evaluation.segmentsUV{idx_segment};

        % Convert local u distance into MATLAB image columns.
        cols = current_segmentUV(:, 1) ./ du + 1;
        % Convert local v distance into MATLAB image rows.
        rows = current_segmentUV(:, 2) ./ dv + 1;

        % Plot the continuous segment in red so it can be compared with discrete pixels.
        plot(ax_tile, cols, rows, 'r-', 'LineWidth', 1.5);
    end

    % Overlay selected probe-facing pixels so the surface used by the future cost is clear.
    if ~isempty(evaluation.probeFacingPixels)
        % Read selected rows because probeFacingPixels is returned as [row, col].
        selected_rows = evaluation.probeFacingPixels(:, 1);
        % Read selected columns because MATLAB plot expects x-values first.
        selected_cols = evaluation.probeFacingPixels(:, 2);

        % Plot selected probe-facing pixels in green to match the validated display example.
        plot(ax_tile, selected_cols, selected_rows, 'go', 'MarkerSize', 5, 'LineWidth', 1);
    end
end

%% FINISH THE DISPLAY STYLE

% Add one shared title so the tiled figure is easy to recognize.
title(tile_layout, figureName, 'Interpreter', 'none');

% Force MATLAB to draw the figure before the script continues.
drawnow;
end
