% MAIN_BONEPOSEOPTIMIZATION_HYPERPARAMSWEEP Run a full hyperparameter sweep.
%
% What this script is for:
%   This is the entry point for a hyperparameter sweep. It estimates the 3D
%   pose of a bone by registering its CT mesh to tracked ultrasound images,
%   and it does so many times: once for every combination of cost settings
%   listed in the JSON config, and several times per combination with
%   different random seeds. Comparing the runs tells you which settings find
%   the bone pose best and how reliably.
%
%   Use it when you want to compare settings unattended (it can run for
%   hours and opens no figures). To look at ONE run in detail, with
%   figures, use main_bonePoseOptimization_oneSweep.m instead.
%
% What you get after running it:
%   A new folder <experiment.outputFolder>/<experiment.name>_<timestamp>/
%   containing:
%     - experiment_config_snapshot.json : copy of the JSON that was used;
%     - experiment_plan.mat             : the full plan of combinations and runs;
%     - validation_context.mat          : ground truth, saved once;
%     - summary.csv / summary.mat       : one row per run with status,
%                                         initial and best cost, run time,
%                                         and error text for failed runs;
%     - runs/<combinationId>/seed_<n>/  : runResult.mat and CMA-ES logs of
%                                         each single run.
%   In MATLAB, the workspace variable experimentResult holds the folder
%   path, the plan, and the final summary table.
%
% How to use it:
%   1. Run it from the project root (it uses relative paths).
%   2. Edit the JSON file named in configFilePath below (or point to another
%      one) to choose the bone, input files, cost model, candidate values,
%      seeds, and output folder.
%   3. Run the script and follow the progress messages in the Command Window.

% Start from a clean state so variables or figures from an earlier session
% cannot influence this run.
clear; clc; close all;

% Make all project functions callable. Everything this script uses lives
% somewhere under functions/, so we add that folder and all its subfolders
% to the MATLAB path once, here at the top.
addpath(genpath('functions'));

%% STEP 1: LOAD THE EXPERIMENT SPECIFICATION

% Choose the JSON file that describes the sweep. Such a file lists the input
% data, the cost model, the candidate values to try for each setting, the
% seeds to repeat each combination with, and where to save results.
configFilePath = fullfile(pwd, 'config', 'optconfig_hyperparamSweep_intensityLine.json');

% createBonePoseOptimizationExperimentConfig reads that JSON file, checks
% every setting (paths exist, values are valid, no duplicate candidates or
% seeds, ...), and turns relative paths into absolute ones. It returns the
% result as one struct, experimentSpec.
% We need it because the sweep can take hours: a typo in the JSON should
% stop us now, within seconds, not halfway through the night. The checked
% experimentSpec is exactly what the runner in step 2 expects as input.
experimentSpec = createBonePoseOptimizationExperimentConfig(configFilePath);

%% STEP 2: RUN THE COMPLETE EXPERIMENT

% runBonePoseOptimizationExperiment does the whole sweep for us. It:
%   - expands the candidate lists into a plan of combinations and runs,
%   - creates the timestamped output folder and saves the plan,
%   - for each combination, prepares the inputs once (bone mesh, ultrasound
%     planes, search trees, ...) and computes the cost at the start pose,
%   - for each seed, runs the CMA-ES optimizer and saves the result
%     immediately,
%   - keeps summary.csv up to date after every run.
% A failing combination or seed is recorded as "failed" and the sweep
% continues, so one bad setting does not waste the rest of the experiment.
% We call it here because this single call is the whole experiment; after it
% returns, every result is already on disk.
experimentResult = runBonePoseOptimizationExperiment(experimentSpec);

% Show where the results are and the final summary, so you can see at once
% where to look next. Open summary.csv in the experiment folder to compare
% the combinations.
disp(experimentResult);
