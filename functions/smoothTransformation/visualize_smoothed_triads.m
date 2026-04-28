function visualize_smoothed_triads(T_raw, T_smooth)
    % VISUALIZE_SMOOTHED_TRIADS Animates the coordinate frames of raw vs 
    % smoothed rigid body transformations.
    %
    % Inputs:
    %   T_raw    - 4x4xn array of raw rigid body transformations
    %   T_smooth - 4x4xn array of smoothed rigid body transformations

    % 1. Extract translation data for trajectories
    num_frames = size(T_raw, 3);
    p_raw = squeeze(T_raw(1:3, 4, :));
    p_smooth = squeeze(T_smooth(1:3, 4, :));

    % Determine a good scale for the triads based on the trajectory size
    max_range = max(max(p_smooth,[], 2) - min(p_smooth,[], 2));
    if max_range == 0 || isnan(max_range)
        axis_len = 1; % Fallback scale
    else
        axis_len = max_range * 0.1; 
    end

    % 2. Setup the figure and static paths
    fig = figure('Name', 'Rigid Body Smoothing Visualization', 'Color', 'w');
    ax = axes('Parent', fig);
    hold(ax, 'on');
    grid(ax, 'on');
    axis(ax, 'equal');
    view(ax, 3);
    xlabel(ax, 'X'); ylabel(ax, 'Y'); zlabel(ax, 'Z');

    % Plot the full static trajectories
    plot3(ax, p_raw(1,:), p_raw(2,:), p_raw(3,:), 'Color',[0.7 0.7 0.7], ...
        'LineStyle', ':', 'DisplayName', 'Raw Path');
    plot3(ax, p_smooth(1,:), p_smooth(2,:), p_smooth(3,:), 'k-', ...
        'LineWidth', 1.5, 'DisplayName', 'Smoothed Path');

    % Lock axes limits so the camera doesn't jump during animation
    xlim(ax,[min(p_raw(1,:))-axis_len, max(p_raw(1,:))+axis_len]);
    ylim(ax,[min(p_raw(2,:))-axis_len, max(p_raw(2,:))+axis_len]);
    zlim(ax,[min(p_raw(3,:))-axis_len, max(p_raw(3,:))+axis_len]);

    % 3. Create Transform Objects for the Triads
    % hgtransform allows us to move complex objects simply by updating a 4x4 matrix
    t_raw = hgtransform('Parent', ax);
    t_smooth = hgtransform('Parent', ax);

    % Draw Raw Triad at origin (Attached to t_raw) - Dashed/Faded lines
    line([0 axis_len], [0 0], [0 0], 'Color', [1 0.5 0.5], 'Parent', t_raw, 'LineStyle', '--', 'LineWidth', 1);
    line([0 0], [0 axis_len], [0 0], 'Color',[0.5 1 0.5], 'Parent', t_raw, 'LineStyle', '--', 'LineWidth', 1);
    line([0 0], [0 0], [0 axis_len], 'Color',[0.5 0.5 1], 'Parent', t_raw, 'LineStyle', '--', 'LineWidth', 1);

    % Draw Smoothed Triad at origin (Attached to t_smooth) - Solid/Thick lines
    line([0 axis_len], [0 0], [0 0], 'Color', 'r', 'Parent', t_smooth, 'LineWidth', 2);
    line([0 0],[0 axis_len], [0 0], 'Color', 'g', 'Parent', t_smooth, 'LineWidth', 2);
    line([0 0], [0 0], [0 axis_len], 'Color', 'b', 'Parent', t_smooth, 'LineWidth', 2);

    legend(ax, 'Location', 'best');
    title(ax, 'Raw vs Smoothed Rigid Body Trajectory');

    % 4. Animate the Triads
    % If there are thousands of frames, skip frames to keep animation fast
    stride = max(1, floor(num_frames / 400)); 

    for i = 1:stride:num_frames
        % Check if figure was closed by user to prevent errors
        if ~isvalid(fig)
            break;
        end
        
        % Update the 4x4 matrices of the transform objects
        t_raw.Matrix = T_raw(:,:,i);
        t_smooth.Matrix = T_smooth(:,:,i);
        
        % Update the title with the current frame
        title(ax, sprintf('Raw (Dashed) vs Smoothed (Solid) - Frame %d / %d', i, num_frames));
        
        drawnow;
        pause(0.02); 
    end
end