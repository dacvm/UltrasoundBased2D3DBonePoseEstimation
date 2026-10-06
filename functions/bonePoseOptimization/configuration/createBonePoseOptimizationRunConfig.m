function runConfig = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow, seed)
%CREATEBONEPOSEOPTIMIZATIONRUNCONFIG Create one scalar optimization config.
% This function copies fixed experiment settings, merges the selected cost
% candidates into one scalar parameter struct, and optionally adds a repeat
% seed. Candidate arrays are removed so scientific functions receive one
% simple runtime configuration shape.
%
% Where it fits in the framework:
%   A bone-pose experiment runs in three configuration steps, always in
%   this order (see main_bonePoseOptimization_*.m and
%   runBonePoseOptimizationExperiment.m):
%     1. createBonePoseOptimizationExperimentConfig
%        JSON file  ->  experimentSpec (candidate lists + seeds, checked)
%     2. createBonePoseOptimizationExperimentPlan
%        experimentSpec  ->  table of every combination and every run
%     3. createBonePoseOptimizationRunConfig (this function)
%        experimentSpec + one plan row  ->  config for one single run
%   It is the LAST configuration step and, unlike the first two, it is
%   called many times, inside the runner's loop:
%     - once per combination WITHOUT a seed, to get the config used for
%       the slow input preparation shared by all seeds of that combination;
%     - once per run WITH a seed, to get the config passed to CMA-ES.
%   Its output is what the scientific code (input preparation, cost
%   functions, optimizer) actually receives.
%
% Why this is needed:
%   An experiment spec describes MANY runs at once: it holds lists of
%   candidate values for each hyperparameter (a "sweep"). The scientific
%   code (input preparation, cost functions, CMA-ES) should not have to know
%   about sweeps; it only wants "the" value of each setting for the run it
%   is doing right now. This function is the single place where one point
%   of the sweep is turned into such a plain, one-run configuration. Keeping
%   that conversion here means the downstream code stays simple and never
%   has to pick values out of candidate lists itself.
%
% Inputs:
%   experimentSpec - Validated experiment specification containing
%                    fixed settings and hyperparameter candidate lists.
%   combinationRow - One row from experimentPlan.combinations containing
%                    the scalar hyperparameter values to use.
%   seed           - Optional positive integer seed for one CMA-ES run. When
%                    omitted, the returned configuration has no seed field.
%
% Output:
%   runConfig      - Scalar configuration ready for input preparation, cost
%                    evaluation, and optimization.

%% CHECK THAT THE PLAN ROW FITS THIS EXPERIMENT

% Purpose: the rest of the function assumes it reads exactly one value per
% parameter. If the caller passed several rows (or a non-table), "the value"
% would be ambiguous and we could silently mix values from different
% combinations. Failing early gives a clear message instead.
if ~istable(combinationRow) || height(combinationRow) ~= 1
    error('createBonePoseOptimizationRunConfig:ExpectedOneCombinationRow', ...
          'combinationRow must be exactly one table row.');
end

% Purpose: plan rows are built per cost model, and different models have
% different parameter names and meanings. If a row from, say, a P-IMLOP plan
% were combined with a spec for another model, the run would use the wrong
% parameters without any visible error. Comparing the model names here
% catches that mix-up before any expensive work starts.
if ~ismember('costModel', combinationRow.Properties.VariableNames) || string(combinationRow.costModel) ~= string(experimentSpec.cost.model)
    error('createBonePoseOptimizationRunConfig:CostModelMismatch', ...
          'combinationRow must belong to experimentSpec.cost.model.');
end

%% START FROM THE SHARED EXPERIMENT SETTINGS

% Most settings (data paths, optimizer options, output folders, ...) are 
% identical for every run of the experiment. By starting from a full copy 
% we keep all of them automatically and only need to overwrite the few
% parts that change per combination.
runConfig = experimentSpec;

% The face-toward-probe angle tolerance is swept like a hyperparameter, but
% it is used by the intersection step, not by the cost function. So its
% chosen value is written back into the "intersection" group, where the
% intersection code expects to find a single number.
runConfig.intersection.normalFacingToleranceDeg = combinationRow.normalFacingToleranceDeg;

%% REBUILD THE COST GROUP IN ITS RUNTIME SHAPE

% Ask the spec which parameter names exist. The model-specific validator has
% already put these fields in a fixed (canonical) order, so iterating over
% them keeps the output struct in the same order for every run, which makes
% saved configs easy to compare side by side.
fixedParameterNames = fieldnames(experimentSpec.cost.fixedParameters).';
hyperparameterNames = fieldnames(experimentSpec.cost.hyperparameters).';

% Why start from an empty struct? the spec's cost group still contains the
% candidate lists ("fixedParameters" and "hyperparameters"). If we kept
% them, a cost function could accidentally read a whole candidate list
% instead of the chosen value. Replacing the group with a clean struct
% guarantees the run only sees one merged "parameters" struct.
runConfig.cost = struct();
runConfig.cost.model = experimentSpec.cost.model;
runConfig.cost.parameters = struct();

%% COPY THE FIXED COST PARAMETERS

% Copy settings that stay fixed for every combination in this experiment.
% Why merge them with the swept values? The cost function should not care
% whether a value was swept or fixed; it just reads cost.parameters.<name>.
% A fixed setting may be a short vector (for example the three P-IMLOP image
% standard deviations), because it never becomes a plan-table column.
for parameterIndex = 1:numel(fixedParameterNames)
    parameterName  = fixedParameterNames{parameterIndex};
    parameterValue = experimentSpec.cost.fixedParameters.(parameterName);
    
    % A NaN or Inf here would only show up much later as a broken cost value,
    % so we stop now with a message that names the bad parameter.
    validateattributes(parameterValue, {'numeric'}, {'vector', 'real', 'finite'}, mfilename, parameterName);
    runConfig.cost.parameters.(parameterName) = parameterValue;
    
end

%% COPY THE SWEPT COST PARAMETERS OF THIS COMBINATION

% Copy this combination's selected value for every swept cost parameter.
% Each swept parameter is one column in the plan table, and this row holds
% the value chosen for this particular run.
for parameterIndex = 1:numel(hyperparameterNames)
    parameterName = hyperparameterNames{parameterIndex};

    % A missing column means the plan was built from a different spec. We
    % stop instead of silently leaving the parameter out of the run.
    if ~ismember(parameterName, combinationRow.Properties.VariableNames)
        error('createBonePoseOptimizationRunConfig:MissingParameterColumn', ...
              'combinationRow is missing parameter column %s.', parameterName);
    end
    parameterValue = combinationRow.(parameterName);

    % Swept values must be single numbers: each plan cell is one point of
    % the sweep, so anything else means the plan table was built wrongly.
    validateattributes(parameterValue, {'numeric'}, ...
        {'scalar', 'real', 'finite'}, mfilename, parameterName);
    runConfig.cost.parameters.(parameterName) = parameterValue;

end

%% ATTACH (OR CLEAR) THE RANDOM SEED

% Why the seed is optional? The same combination is usually run several
% times with different seeds to measure how stable CMA-ES is. The
% combination-level config (no seed) is used for the slow, shared input
% preparation, which does not involve randomness. Each repeat run then gets
% its own config with its own seed, so every result can be reproduced
% exactly later.
if nargin >= 3 && ~isempty(seed)
    validateattributes(seed, {'numeric'}, {'scalar', 'positive', 'finite', 'integer'}, mfilename, 'seed');
    runConfig.optimizer.seed = seed;
elseif isfield(runConfig.optimizer, 'seed')
    % The spec copy may already carry a seed. Remove it so a config meant
    % for "no specific repeat" cannot secretly reuse that seed and make
    % different repeats produce identical results.
    runConfig.optimizer = rmfield(runConfig.optimizer, 'seed');
end
end
