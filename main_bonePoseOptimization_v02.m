clear; clc; close all;

% Add the reusable project functions before loading or evaluating any data.
addpath(genpath('functions'));

%% CREATE CONFIGURATION

% Use the v02 configuration because it points directly to standardized tool outputs.
configFilePath = fullfile(pwd, 'config', 'bonePoseOptimizationConfig_v02.json');
% Parse file paths and optimization settings into one configuration struct.
config = createBonePoseOptimizationConfig(configFilePath);

%% PREPARE STANDARDIZED INPUTS

% Load fixed estimation inputs once and keep ground truth in a separate validation struct.
[data, validationData] = prepareBonePoseOptimizationInputs(config);

% Start at zero perturbation, which means the coarse CT-to-reference pose is unchanged.
initialPoseVector = zeros(6, 1);

%% INSPECT AND EVALUATE THE INITIAL POSE

% Display the coarse-registered mesh together with the selected ultrasound planes.
displayBonePoseOptimizationScene(data, initialPoseVector, config, 'Initial Bone Pose Optimization Setup');
% Recompute candidate intersections for display without using the saved ground-truth intersections.
displayBonePoseOptimizationIntersections(data, initialPoseVector, config, 'Initial Bone Pose Optimization Intersections');

% Evaluate the initial pose once so its cost and geometry remain available in the workspace.
[initialCost, initialCostDetails] = bonePoseCostFunction(initialPoseVector, data, config);
initialEvaluation = initialCostDetails.poseEvaluation;

% Print a short input summary before the longer optimization starts.
fprintf('Optimizing bone %s with %d ultrasound planes.\n', data.bone, numel(data.imagePlanesRef));
fprintf('Initial cost: %.6f\n', initialCost);
fprintf('Loaded %d ground-truth intersections for later validation only.\n', numel(validationData.groundTruthIntersections));

%% RUN CMA-ES OPTIMIZATION

% Minimize the existing cost around the coarse-registration pose.
optimizationResult = runBonePoseOptimization(initialPoseVector, data, config, initialCost);

% Keep the complete numeric result visible for inspection after the script finishes.
disp(optimizationResult);

%% DISPLAY THE FINAL ESTIMATE

% Display the best estimated pose in the same reference frame as the input planes.
displayBonePoseOptimizationScene(data, optimizationResult.result.bestPoseVector, config, ...
    'Final Bone Pose Optimization Result', validationData);
% Recompute final intersections for visual inspection of the optimized estimate.
displayBonePoseOptimizationIntersections(data, optimizationResult.result.bestPoseVector, config, ...
    'Final Bone Pose Optimization Intersections');
