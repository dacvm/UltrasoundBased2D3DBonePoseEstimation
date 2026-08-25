clear; clc; close all;

% Add all reusable project functions before reading the experiment configuration.
addpath(genpath('functions'));

%% LOAD THE EXPERIMENT SPECIFICATION

% Use the sweep configuration because it defines candidate values and repeat seeds.
configFilePath = fullfile(pwd, 'config', 'optconfig_hyperparamSweep_intensityICP.json');
% Read and validate the complete experiment description before any run starts.
experimentSpec = createBonePoseOptimizationExperimentConfig(configFilePath);

%% RUN THE COMPLETE EXPERIMENT

% Execute every hyperparameter combination and seed without opening display figures.
experimentResult = runBonePoseOptimizationExperiment(experimentSpec);

% Keep a short final result visible in the workspace and Command Window.
disp(experimentResult);
