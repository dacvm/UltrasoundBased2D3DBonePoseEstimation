% MAKEPIMLOPDEMOSETUP Refresh optimization_setup.mat, the input of the P-IMLOP demos.
%
% What this script is for:
%   Every demo in examples/pimlop/ loads optimization_setup.mat instead of
%   preparing the data itself. That file is a saved copy of the prepared
%   optimization data (the "data" struct that the optimizer and the cost
%   functions receive). It is kept in git on purpose:
%     - The recordings and tool outputs it is made from (data/ and
%       tools/**/outputs/) are not in git, so a user who only cloned the
%       repository could not prepare anything. With this file the demos
%       still run.
%     - It is not an optimization result. It is a fixed demo input, like a
%       test fixture, and only changes when this script is run again. That
%       is why it lives here and not in output/ (which git ignores).
%
% When to run it:
%   After a change to prepareBonePoseOptimizationInputs (for example a new
%   field in "data"), or when the demos should use newer recordings. It
%   needs the local input files listed in the P-IMLOP template config.
%
% What it writes:
%   examples/pimlop/optimization_setup.mat with three variables:
%     data              - prepared data, without data.extra (see below);
%     config            - the one-run configuration used to prepare it;
%     initialPoseVector - zeros(6, 1), the coarse start pose.
%
% Run it from any folder; all paths are resolved from this script.

clear; clc;

%% FIND THE PROJECT AND THE CONFIG

% This script lives in examples/pimlop/, two folders below the project root.
demoFolder  = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(demoFolder));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Use the tracked P-IMLOP template, not a personal .local.json copy, so
% everyone who refreshes the file gets the same inputs.
configPath = fullfile(projectRoot, 'config', 'optconfig_oneSweep_PIMLOP.json');

%% PREPARE THE DATA EXACTLY AS AN OPTIMIZATION DOES

experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :), experimentPlan.runs.seed(1));
data = prepareBonePoseOptimizationInputs(config);

% Drop the precomputed cost-model helpers (P-IMLOP PD-tree, ICP KD-tree).
% Building the P-IMLOP model and its PD-tree is exactly what the demos
% teach, so they build it themselves; leaving it out also keeps the file
% small.
data = rmfield(data, 'extra');

% Zero means "no correction": the coarse-registration start pose.
initialPoseVector = zeros(6, 1);

%% SAVE THE DEMO INPUT

setupFilePath = fullfile(demoFolder, 'optimization_setup.mat');
save(setupFilePath, 'data', 'config', 'initialPoseVector');
fprintf('Saved %s (%d images, %d mesh vertices).\n', ...
    setupFilePath, numel(data.imagePlanesRef), size(data.boneMeshCT.Points, 1));
