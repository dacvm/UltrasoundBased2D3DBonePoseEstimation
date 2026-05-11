clear; clc; close all;

% Add every helper folder so the main script can call the reusable pipeline functions.
addpath(genpath('functions'));

% CREATE CONFIGURATION
% Build one configuration struct so filenames, sampling, and geometry options live in one place.
config = createBonePoseOptimizationConfig();

% PREPARE DATA FOR OPTIMIZATION
% Load calibration, image planes, mesh data, and the initial bone pose once before optimization starts.
data = prepareBonePoseOptimizationInputs(config);

% CREATE INITIAL POSE PARAMETER
% Start the optimizer at zero SE(3) perturbation, which means "use data.T_init_originct unchanged".
initialPoseVector = zeros(6, 1);

% DISPLAY THE INITIAL SETUP
% Show the starting mesh pose and sampled image-plane poses before any optimization step runs.
displayBonePoseOptimizationScene(data, initialPoseVector, config, 'Initial Bone Pose Optimization Setup');
% Show the starting mesh-plane intersection overlays inside each 2D image for closer inspection.
displayBonePoseOptimizationIntersections(data, initialPoseVector, config, 'Initial Bone Pose Optimization Intersections');

% EVALUATE THE INITIAL POSE
% Evaluate the initial pose once so the cost-function path already has probe-facing pixels available.
[initialCost, initialCostDetails] = bonePoseCostFunction(initialPoseVector, data, config);

% Keep the initial geometry evaluation visible in the workspace for inspection after the script finishes.
initialEvaluation = initialCostDetails.poseEvaluation;

% Print a compact summary so the user knows the cost-function pipeline reached the geometry stage.
fprintf('Initial cost: %.6f\n', initialCost);
fprintf('Computed probe-facing pixels for %d image planes.\n', numel(initialEvaluation));

%% RUN CMA-ES OPTIMIZATION

% Call the optimizer wrapper so CMA-ES can minimize bonePoseCostFunction around the manual pose.
optimizationResult = runBonePoseOptimization(initialPoseVector, data, config, initialCost);

% Display the optimizer result so the run has a clear numeric summary before visual inspection.
disp(optimizationResult);

% DISPLAY THE FINAL RESULT
% Show the best pose returned by the optimizer wrapper so future optimizer output can be inspected visually.
displayBonePoseOptimizationScene(data, optimizationResult.bestPoseVector, config, 'Final Bone Pose Optimization Result');
% Show the final best-pose intersection overlays inside each 2D image for closer inspection.
displayBonePoseOptimizationIntersections(data, optimizationResult.bestPoseVector, config, 'Final Bone Pose Optimization Intersections');
