% Create a sample noisy trajectory (e.g., a simple rotation + translation)
num_points = 100;
T_noisy = zeros(4, 4, num_points);
T_noisy(:,:,1) = eye(4);
noise_level_trans = 0.05; % Translational noise
noise_level_rot = 0.02;  % Rotational noise (in radians)

% Define a smooth motion
angle_step = 2*pi / num_points;
translation_step = [0.1; 0; 0];

for i = 2:num_points
    % Ideal smooth motion
    rot_z = [cos(angle_step) -sin(angle_step) 0; sin(angle_step) cos(angle_step) 0; 0 0 1];
    T_step = [rot_z, translation_step; 0 0 0 1];
    T_ideal = T_noisy(:,:,i-1) * T_step;

    % Add noise
    trans_noise = noise_level_trans * (rand(3,1) - 0.5);
    rot_noise_vec = noise_level_rot * (rand(3,1) - 0.5);
    rot_noise_mat = expm(twist_to_se3([zeros(3,1); rot_noise_vec])); % Small random rotation
    
    T_noisy(:,:,i) = T_ideal;
    T_noisy(1:3, 4, i) = T_noisy(1:3, 4, i) + trans_noise;
    T_noisy(1:3, 1:3, i) = T_noisy(1:3, 1:3, i) * rot_noise_mat(1:3, 1:3);
end

% --- Perform the smoothing ---
T_smooth = smoothTransformations(T_noisy, 'method', 'sgolay', 'window', 15);

% % --- Visualization (requires Robotics System Toolbox for plotTrajectory) ---
% figure;
% hold on;
% plotTrajectory(permute(T_noisy(1:3,4,:), [3,1,2]), 'r-'); % Plot noisy path
% plotTrajectory(permute(T_smooth(1:3,4,:), [3,1,2]), 'b-', 'LineWidth', 2); % Plot smoothed path
% title('Noisy vs. Smoothed Trajectory');
% xlabel('X'); ylabel('Y'); zlabel('Z');
% legend('Noisy', 'Smoothed');
% grid on;
% axis equal;
% view(3);

% % ------------- helper: convert the SE(3) stacks to XYZ paths ----------
coordsNoisy  = squeeze(T_noisy (1:3,4,:)).';    % N×3
coordsSmooth = squeeze(T_smooth(1:3,4,:)).';

% % ------------- create a theaterPlot with two trajectoryPlotters -------
tp   = theaterPlot('ZLimits',[-1 2]);           % nicer default Z-range
pNoisy  = trajectoryPlotter(tp,'DisplayName','Noisy',   ...
                                'Color','r','LineStyle','-');
pSmooth = trajectoryPlotter(tp,'DisplayName','Smoothed',...
                                'Color','b','LineWidth',2);

plotTrajectory(pNoisy,  {coordsNoisy});
plotTrajectory(pSmooth,{coordsSmooth});

title('Noisy vs. Smoothed Trajectory');
xlabel('X'); ylabel('Y'); zlabel('Z');
legend show; grid on; view(3); axis equal