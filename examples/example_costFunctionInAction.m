% EXAMPLE_COSTFUNCTIONINACTION See one cost function score the bone pose.
%
% What this script is for:
%   The optimizer never "sees" the bone; it only sees one number per
%   candidate pose: the cost (lower is better). This script lets you watch
%   that number for the cost model chosen in your one-sweep config, without
%   running an optimization. It works for every cost model, because it goes
%   through the same dispatcher (bonePoseCostFunction) that CMA-ES calls.
%
% What you get after running it:
%   - The 3D scene and the 2D intersections at the coarse start pose.
%   - The start-pose cost and the names of the diagnostics the cost model
%     returns (Command Window), plus initialCostDetails in the workspace.
%   - One figure with six curves: how the cost changes when the bone is
%     shifted along, or turned about, each axis around the start pose. A
%     smooth valley around the best pose is what an optimizer needs; flat
%     stretches, steps or very steep walls explain why a search gets stuck.
%
% How to use it:
%   1. Run it from the project root (it uses relative paths).
%   2. It reads config/oneSweep.local.json, the same file as
%      main_bonePoseOptimization_oneSweep.m. To see another cost model,
%      copy another template over it, e.g.
%      config/optconfig_oneSweep_intensityPIMLOP.json.
%   3. Change the slice settings below to look wider or finer. Every slice
%      point is one cost evaluation, so more points take longer. With the
%      default 6 x 11 points, expect about 20 s for ICPLike, 2 minutes for
%      the intensity models, and about 14 minutes for the P-IMLOP models
%      (their correspondence search is the slow part).

clear; clc; close all;
addpath(genpath('functions'));

%% SETTINGS FOR THE COST SLICES

% Each slice moves the bone along one of the six optimizer axes while the
% other five stay at the start pose. Translations are in mm, rotations in
% degrees, and rotations turn the bone about its own centre
% (data.pivotPointRef), exactly as the optimizer does.
translationRangeMm = 5;     % slices go from -range to +range
rotationRangeDeg   = 5;
pointsPerSlice     = 11;    % odd, so the start pose itself is one point

%% STEP 1: READ THE CONFIGURATION

% Use the personal one-sweep config, so this example shows the same cost
% model and settings you would optimize with.
configFilePath = fullfile(pwd, 'config', 'oneSweep.local.json');
if ~isfile(configFilePath)
    error('example_costFunctionInAction:LocalConfigNotFound', ...
        ['Local config not found: %s\n' ...
         'Copy a template to this name first, e.g. ' ...
         'config/optconfig_oneSweep_PIMLOP.json -> config/oneSweep.local.json'], ...
        configFilePath);
end

% Go through the same three steps as the optimization scripts: read and
% check the JSON, plan the runs, and make the config for the first run.
% A one-sweep file has one combination, so "the first run" is the run.
experimentSpec = createBonePoseOptimizationExperimentConfig(configFilePath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig(experimentSpec, ...
    experimentPlan.combinations(1, :), experimentPlan.runs.seed(1));

%% STEP 2: PREPARE THE INPUTS

% Build everything the cost function needs once (mesh, image planes,
% search trees, smoothed images, start pose, pivot). The cost function
% only reads from "data", which is why it can be called thousands of times.
data = prepareBonePoseOptimizationInputs(config);

%% STEP 3: SCORE THE START POSE

% A zero pose vector means "no correction": exactly the coarse start pose.
startPoseVector = zeros(6, 1);

% Show where the bone sits relative to the images, in 3D and on each image.
displayBonePoseOptimizationScene(data, startPoseVector, config, 'Start pose: scene');
displayBonePoseOptimizationIntersections(data, startPoseVector, config, 'Start pose: intersections');

% The second output holds the diagnostics of the chosen cost model (for
% example per-plane evidence or per-point match errors). Their names
% differ between models, so we list them; open initialCostDetails in the
% workspace to look inside.
[initialCost, initialCostDetails] = bonePoseCostFunction(startPoseVector, data, config);
fprintf('Cost model: %s\n', config.cost.model);
fprintf('Start-pose cost: %.6g\n', initialCost);
fprintf('Diagnostics returned by the cost model:\n');
diagnosticNames = fieldnames(initialCostDetails);
fprintf('  %s\n', diagnosticNames{:});

%% STEP 4: SLICE THE COST ALONG EACH POSE AXIS

% The pose vector is [vx; vy; vz; wx; wy; wz]: shifts in mm along the ref
% axes, then a rotation vector in radians. For each axis we build a list
% of offsets, put each offset into an otherwise-zero pose vector, and
% score it.
axisNames = {'shift x (mm)', 'shift y (mm)', 'shift z (mm)', ...
             'turn about x (deg)', 'turn about y (deg)', 'turn about z (deg)'};
offsetsPerAxis = [repmat(linspace(-translationRangeMm, translationRangeMm, pointsPerSlice), 3, 1); ...
                  repmat(linspace(-rotationRangeDeg,   rotationRangeDeg,   pointsPerSlice), 3, 1)];
costPerAxis = zeros(6, pointsPerSlice);

for axisIndex = 1:6
    fprintf('Slicing %s ...\n', axisNames{axisIndex});
    for pointIndex = 1:pointsPerSlice
        poseVector = zeros(6, 1);
        offset = offsetsPerAxis(axisIndex, pointIndex);

        % The optimizer stores rotations in radians; the slice settings
        % are in degrees only because they are easier to read.
        if axisIndex <= 3
            poseVector(axisIndex) = offset;
        else
            poseVector(axisIndex) = deg2rad(offset);
        end

        costPerAxis(axisIndex, pointIndex) = bonePoseCostFunction(poseVector, data, config);
    end
end

%% STEP 5: PLOT THE SLICES

% One panel per axis. The red dot is the start pose; if it sits at the
% bottom of every curve, the optimizer has no direction to improve in.
figure('Name', 'Cost slices around the start pose', 'Color', 'w');
sliceLayout = tiledlayout(2, 3, 'TileSpacing', 'compact');
for axisIndex = 1:6
    nexttile;
    plot(offsetsPerAxis(axisIndex, :), costPerAxis(axisIndex, :), '-o', 'MarkerSize', 4);
    hold on;
    plot(0, initialCost, 'ro', 'MarkerFaceColor', 'r');
    hold off;
    grid on;
    xlabel(axisNames{axisIndex});
    ylabel('cost');
end
title(sliceLayout, sprintf('%s cost around the start pose', config.cost.model), 'Interpreter', 'none');
