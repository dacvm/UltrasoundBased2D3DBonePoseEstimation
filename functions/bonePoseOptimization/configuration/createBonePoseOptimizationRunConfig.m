function runConfig = createBonePoseOptimizationRunConfig(experimentSpec, combinationRow, seed)
%CREATEBONEPOSEOPTIMIZATIONRUNCONFIG Create one scalar optimization config.
% This function copies fixed experiment settings, merges the selected cost
% candidates into one scalar parameter struct, and optionally adds a repeat
% seed. Candidate arrays are removed so scientific functions receive one
% simple runtime configuration shape.
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

% One row must describe one unambiguous scalar parameter combination.
if ~istable(combinationRow) || height(combinationRow) ~= 1
    error('createBonePoseOptimizationRunConfig:ExpectedOneCombinationRow', ...
          'combinationRow must be exactly one table row.');
end

% Guard against accidentally pairing a plan row with another cost model.
if ~ismember('costModel', combinationRow.Properties.VariableNames) || ...
        string(combinationRow.costModel) ~= string(experimentSpec.cost.model)
    error('createBonePoseOptimizationRunConfig:CostModelMismatch', ...
          'combinationRow must belong to experimentSpec.cost.model.');
end

% Copy the shared settings before replacing candidate groups with runtime values.
runConfig = experimentSpec;
runConfig.intersection.normalFacingToleranceDeg = combinationRow.normalFacingToleranceDeg;

% Resolve the model's ordered parameter lists instead of naming one model's fields here.
costDefinition = getBonePoseCostDefinition(experimentSpec.cost.model);

% Keep every cost value used during evaluation together as finite scalar settings.
runConfig.cost = struct();
runConfig.cost.model = experimentSpec.cost.model;
runConfig.cost.parameters = struct();

% Copy settings that stay fixed for every combination in this experiment.
for parameterIndex = 1:numel(costDefinition.fixedParameterNames)
    parameterName  = costDefinition.fixedParameterNames{parameterIndex};
    parameterValue = experimentSpec.cost.fixedParameters.(parameterName);
    validateattributes(parameterValue, {'numeric'}, {'scalar', 'real', 'finite'}, mfilename, parameterName);
    runConfig.cost.parameters.(parameterName) = parameterValue;
end

% Copy this combination's selected value for every swept cost parameter.
for parameterIndex = 1:numel(costDefinition.hyperparameterNames)
    parameterName = costDefinition.hyperparameterNames{parameterIndex};
    if ~ismember(parameterName, combinationRow.Properties.VariableNames)
        error('createBonePoseOptimizationRunConfig:MissingParameterColumn', ...
              'combinationRow is missing parameter column %s.', parameterName);
    end
    parameterValue = combinationRow.(parameterName);
    validateattributes(parameterValue, {'numeric'}, ...
        {'scalar', 'real', 'finite'}, mfilename, parameterName);
    runConfig.cost.parameters.(parameterName) = parameterValue;
end

% Add the seed only for a specific repeat run; preparation itself does not need one.
if nargin >= 3 && ~isempty(seed)
    validateattributes(seed, {'numeric'}, {'scalar', 'positive', 'finite', 'integer'}, mfilename, 'seed');
    runConfig.optimizer.seed = seed;
elseif isfield(runConfig.optimizer, 'seed')
    % Remove a copied seed so a combination-level config cannot accidentally reuse it.
    runConfig.optimizer = rmfield(runConfig.optimizer, 'seed');
end
end
