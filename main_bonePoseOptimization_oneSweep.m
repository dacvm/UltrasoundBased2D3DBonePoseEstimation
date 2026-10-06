% MAIN_BONEPOSEOPTIMIZATION_ONESWEEP Run and inspect one bone-pose optimization.
%
% What this script is for:
%   This is the entry point for a single, visible optimization run. It
%   estimates the 3D pose of a bone by moving its CT mesh until it fits the
%   tracked ultrasound images, starting from a coarse registration. It uses
%   exactly ONE combination of settings and ONE random seed, and it shows
%   figures before and after the optimization so you can see what happens.
%
%   Use it to try out a cost model or a setting, to debug, or to show the
%   method. To compare many settings unattended, use
%   main_bonePoseOptimization_hyperparamSweep.m instead.
%
% What you get after running it:
%   - Figures of the starting setup: the bone mesh at the coarse pose with
%     the ultrasound planes in 3D, and the mesh/plane intersections drawn
%     on the 2D ultrasound images.
%   - Command Window output: the bone, number of images, seed, initial
%     cost, and the optimization result.
%   - Figures of the final result: the estimated bone pose together with
%     the ground-truth pose in 3D, and the final intersections on the images.
%   - CMA-ES log files in the experiment.outputFolder given in the JSON.
%   - Workspace variables to inspect further, mainly data, validationData,
%     initialCost, initialCostDetails, and optimizationResult.
%
% How to use it:
%   1. Run it from the project root (it uses relative paths).
%   2. Pick a config file in configFilePath below. Each one-sweep JSON file
%      fixes one cost model and one value for every setting.
%   3. Run the script, look at the initial figures, wait for CMA-ES, then
%      compare the final figures with the initial ones.

% Start from a clean state so variables or figures from an earlier session
% cannot be confused with the ones made by this run.
clear; clc; close all;

% Make all project functions callable. Everything this script uses lives
% somewhere under functions/, so we add that folder and all its subfolders
% to the MATLAB path once, here at the top.
addpath(genpath('functions'));

%% STEP 1: CREATE THE CONFIGURATION

% Choose the JSON file that describes this run. It names the input data, the
% bone, the cost model and its settings, the seed, and the output folder.
% Select another cost model by choosing its file, e.g. optconfig_oneSweep_ICPLike.json,
% optconfig_oneSweep_intensityICP.json, or optconfig_oneSweep_PIMLOP.json.
configFilePath = fullfile(pwd, 'config', 'optconfig_oneSweep_PIMLOP.json');

% createBonePoseOptimizationExperimentConfig reads the JSON file and checks
% every setting, so mistakes are reported now instead of in the middle of
% the optimization. A one-sweep file uses the same format as a full sweep,
% just with one value per setting and one seed. Reusing the same reader
% means a setting tested here behaves exactly the same in a later sweep.
% Its output, experimentSpec, is what the next two functions build on.
experimentSpec = createBonePoseOptimizationExperimentConfig(configFilePath);

% createBonePoseOptimizationExperimentPlan turns the spec into a table of
% all setting combinations and all runs (combination x seed), each with an
% ID. For a sweep that table is long; here it should have exactly one row.
% We still go through the plan so this script takes the very same path as
% the sweep runner, and so we get that one row in the shape the next
% function expects.
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);

% This script is meant to show ONE run. If the JSON lists several values
% or seeds, it is really a sweep file, so we stop and say so instead of
% silently picking only the first combination.
if experimentPlan.numberOfCombinations ~= 1 || experimentPlan.numberOfSeeds ~= 1
    error('main_bonePoseOptimization_oneSweep:ExpectedOneRun', ...
          'The one-sweep configuration must define exactly one hyperparameter combination and one seed.');
end

% Take the only combination and the only run from the plan.
combinationRow = experimentPlan.combinations(1, :);
runRow         = experimentPlan.runs(1, :);

% createBonePoseOptimizationRunConfig turns that plan row into a plain
% config for one run: one value per setting, plus the seed. Input
% preparation, the cost function, and the optimizer used below all read
% their settings from this config, so from here on we pass "config" around.
config         = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow, runRow.seed);

% Tell CMA-ES where to write its log files. In a sweep every run gets its
% own folder; here we have one run, so the folder from the JSON is used.
config.optimizer.outputFolder = experimentSpec.experiment.outputFolder;

%% STEP 2: PREPARE THE INPUTS

% prepareBonePoseOptimizationInputs loads all input files for the chosen
% bone and gets them ready for the optimizer: the CT bone mesh, the
% ultrasound image planes in the tracker frame, optional bone-surface
% points, the coarse start pose, search structures such as the P-IMLOP
% PD-tree, and the number of visible bone pixels at the start pose. It also
% checks that all these files belong together.
% We need it because the cost function is evaluated thousands of times and
% must not reload or rebuild any of this; it simply reads it from "data".
% The ground truth goes into a separate struct, validationData, which the
% optimizer never sees. We only use it at the end to show the true pose.
[data, validationData] = prepareBonePoseOptimizationInputs(config);

% The optimizer does not search for the pose directly; it searches for a
% small 6D correction [vx vy vz wx wy wz] on top of the coarse start pose.
% A vector of zeros means "no correction", i.e. exactly the coarse pose,
% which is where we start.
initialPoseVector = zeros(6, 1);

%% STEP 3: INSPECT AND EVALUATE THE INITIAL POSE

% Before optimizing, look at the starting situation. If the start pose or
% the data is badly off, you will see it here and save the wait for CMA-ES.

% displayBonePoseOptimizationScene draws, in 3D, the bone mesh at the given
% pose together with the ultrasound image planes. Here it shows the coarse
% start pose, so you can check that the bone is roughly where the images
% are. It only draws; it does not change data or compute a cost.
displayBonePoseOptimizationScene(data, initialPoseVector, config, 'Initial Bone Pose Optimization Setup');

% displayBonePoseOptimizationIntersections cuts the bone mesh with every
% image plane at the given pose and draws the cut on each 2D ultrasound
% image. If the pose is right, the drawn cut should follow the bright bone
% edge in the image. It computes the cut itself from the start pose, not
% from the saved ground truth, so it shows what the optimizer starts with.
displayBonePoseOptimizationIntersections(data, initialPoseVector, config, 'Initial Bone Pose Optimization Intersections');

% bonePoseCostFunction scores how well the bone fits the images at a given
% pose (lower is better). It is the same function the optimizer calls for
% every candidate pose; it picks the cost model named in the config. We
% call it once here to get the starting cost, which tells us later how much
% the optimizer improved, and the optimizer also uses it as its reference.
% initialCostDetails holds the per-image breakdown, useful for debugging.
[initialCost, initialCostDetails] = bonePoseCostFunction(initialPoseVector, data, config);

% Print a short summary of what is about to be optimized, so you can check
% the bone, number of images, seed, and starting cost before the long run.
fprintf('Optimizing bone %s with %d ultrasound planes.\n', data.bone, numel(data.imagePlanesRef));
fprintf('One-sweep seed: %d\n', config.optimizer.seed);
fprintf('Initial cost: %.6f\n', initialCost);
fprintf('Loaded %d ground-truth intersections for later validation only.\n', numel(validationData.groundTruthIntersections));

%% STEP 4: RUN CMA-ES OPTIMIZATION

% runBonePoseOptimization runs the CMA-ES optimizer. Starting from the
% coarse pose, it tries many candidate corrections within the search bounds
% from the config, scores each with bonePoseCostFunction, and keeps the
% best one. It returns the best pose vector and cost, the matching
% transforms (e.g. the estimated bone pose in the tracker frame), and the
% raw CMA-ES output. This is the actual estimation step of the script.
optimizationResult = runBonePoseOptimization(initialPoseVector, data, config, initialCost);

% Print the result so the best cost and the stop reason are visible right
% away. The full struct stays in the workspace for closer inspection.
disp(optimizationResult);

%% STEP 5: DISPLAY THE FINAL ESTIMATE

% Draw the 3D scene again, now at the best pose found by CMA-ES. This time
% we also pass validationData, so the ground-truth bone is drawn next to the
% estimate and you can see directly how close the optimizer got.
displayBonePoseOptimizationScene(data, optimizationResult.result.bestPoseVector, config, ...
    'Final Bone Pose Optimization Result', validationData);

% Draw the cuts on the 2D images again at the best pose. Compare them with
% the initial intersection figure: a good result follows the bone edges in
% the images more closely than the starting pose did.
displayBonePoseOptimizationIntersections(data, optimizationResult.result.bestPoseVector, config, ...
    'Final Bone Pose Optimization Intersections');
