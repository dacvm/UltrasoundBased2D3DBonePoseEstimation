function display_origindot(ax_handle, origin, idx_packet, origin_window_size, plot_tag)
%DISPLAY_ORIGINDOT Draw probe-origin trail dots with red fade by recency.
% This helper stores its own history, so the caller only passes current origin data.

    % Keep origin history inside this function so the main loop stays clean.
    persistent origin_history;

    % Reset history at the first packet so repeated script runs start fresh.
    if idx_packet == 1
        % Start a new empty history buffer with no stored columns yet.
        origin_history = nan(3, 0);
    end

    % Grow history storage if the current packet index exceeds current capacity.
    if size(origin_history, 2) < idx_packet
        % Add enough empty columns so we can write the current packet safely.
        origin_history(:, end + 1:idx_packet) = nan(3, idx_packet - size(origin_history, 2));
    end

    % Save current probe origin at the index that matches the packet number.
    origin_history(:, idx_packet) = origin;

    % Compute the first packet index that is still inside the rolling time window.
    window_start_idx = max(1, idx_packet - origin_window_size + 1);
    % Slice only the recent origins that should stay visible.
    origin_window = origin_history(:, window_start_idx:idx_packet);

    % Count how many points are currently inside the active time window.
    n_window_points = size(origin_window, 2);

    % Build recency values from oldest (0) to newest (1).
    if n_window_points == 1
        % Use full intensity for a single point and avoid divide-by-zero cases.
        recency = 1;
    else
        % Use linear spacing so each newer point is slightly more vibrant.
        recency = linspace(0, 1, n_window_points);
    end

    % Define faded red for old points so the trail softly disappears.
    old_red = [1.0, 0.8, 0.8];
    % Define vivid red for recent points so current motion is easy to track.
    new_red = [1.0, 0.0, 0.0];

    % Interpolate RGB values for each point based on recency.
    point_colors = old_red + (new_red - old_red) .* recency';

    % Draw each point with its own color and keep tag for per-frame cleanup.
    scatter3(ax_handle, ...
        origin_window(1, :), ...
        origin_window(2, :), ...
        origin_window(3, :), ...
        20, ...
        point_colors, ...
        'filled', ...
        'Tag', plot_tag);
end
