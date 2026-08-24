clear; clc; close all;

% Add the reusable project functions before loading or evaluating any data.
addpath(genpath('functions'));

%% CREATE CONFIGURATION

% Use the same active configuration schema as the unattended experiment workflow.
configFilePath = fullfile(pwd, 'config', 'optconfig_oneSweep_intensityCov.json');
% Read the single parameter combination and repeat seed from the one-sweep file.
experimentSpec = createBonePoseOptimizationExperimentConfig(configFilePath);
% Expand the specification through the same plan builder used by the experiment.
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);

% Keep this interactive workflow focused on exactly one visible optimization run.
if experimentPlan.numberOfCombinations ~= 1 || experimentPlan.numberOfSeeds ~= 1
    error('main_bonePoseOptimization_oneSweep:ExpectedOneRun', ...
          'The one-sweep configuration must define exactly one hyperparameter combination and one seed.');
end

% Convert the only planned row into the scalar configuration used by existing functions.
combinationRow = experimentPlan.combinations(1, :);
runRow         = experimentPlan.runs(1, :);
config         = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow, runRow.seed);

% Store the one-sweep CMA-ES logs below their dedicated output folder.
config.optimizer.outputFolder = experimentSpec.experiment.outputFolder;

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

% Print a short input summary before the longer optimization starts.
fprintf('Optimizing bone %s with %d ultrasound planes.\n', data.bone, numel(data.imagePlanesRef));
fprintf('One-sweep seed: %d\n', config.optimizer.seed);
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
