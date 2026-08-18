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

% Copy the shared settings before replacing candidate groups with runtime values.
runConfig = experimentSpec;
runConfig.intersection.normalFacingToleranceDeg = combinationRow.normalFacingToleranceDeg;

% Keep every cost value used during evaluation together as finite scalar settings.
runConfig.cost = struct();
runConfig.cost.model = experimentSpec.cost.model;
runConfig.cost.parameters.intensityMax = ...
    experimentSpec.cost.fixedParameters.intensityMax;
runConfig.cost.parameters.minReferencePixels = ...
    combinationRow.minReferencePixels;
runConfig.cost.parameters.nMinPixels = combinationRow.nMinPixels;
runConfig.cost.parameters.lambdaMissing = combinationRow.lambdaMissing;

% Add the seed only for a specific repeat run; preparation itself does not need one.
if nargin >= 3 && ~isempty(seed)
    validateattributes(seed, {'numeric'}, {'scalar', 'positive', 'finite', 'integer'}, mfilename, 'seed');
    runConfig.optimizer.seed = seed;
elseif isfield(runConfig.optimizer, 'seed')
    % Remove a copied seed so a combination-level config cannot accidentally reuse it.
    runConfig.optimizer = rmfield(runConfig.optimizer, 'seed');
end
end
