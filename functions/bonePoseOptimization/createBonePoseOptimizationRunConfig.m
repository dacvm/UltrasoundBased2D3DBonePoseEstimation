function runConfig = createBonePoseOptimizationRunConfig( ...
        experimentSpec, combinationRow, seed)
%CREATEBONEPOSEOPTIMIZATIONRUNCONFIG Create one scalar optimization config.
% This function copies the fixed v03 experiment settings, selects the four
% scalar hyperparameter values stored in one combination row, and optionally
% adds one repeat seed. Both the sanity-check and experiment workflows use
% this helper so existing preparation, cost, and optimizer functions always
% receive the same scalar configuration shape.
%
% Inputs:
%   experimentSpec - Validated v03 experiment specification containing
%                    fixed settings and hyperparameter candidate lists.
%   combinationRow - One row from experimentPlan.combinations containing
%                    the four scalar hyperparameter values to use.
%   seed           - Optional positive integer seed for one CMA-ES run. When
%                    omitted, the returned configuration has no seed field.
%
% Output:
%   runConfig      - Scalar configuration ready for input preparation, cost
%                    evaluation, and optimization.

% Copy fixed configuration fields, then replace candidate arrays with scalars.
runConfig = experimentSpec;
runConfig.intersection.normalFacingToleranceDeg = ...
    combinationRow.normalFacingToleranceDeg;
runConfig.cost.minReferencePixels = combinationRow.minReferencePixels;
runConfig.cost.nMinPixels = combinationRow.nMinPixels;
runConfig.cost.lambdaMissing = combinationRow.lambdaMissing;

% Add the seed only for a specific repeat run; preparation itself does not need one.
if nargin >= 3 && ~isempty(seed)
    validateattributes(seed, {'numeric'}, ...
        {'scalar', 'positive', 'finite', 'integer'}, mfilename, 'seed');
    runConfig.optimizer.seed = seed;
elseif isfield(runConfig.optimizer, 'seed')
    % Remove a copied seed so a combination-level config cannot accidentally reuse it.
    runConfig.optimizer = rmfield(runConfig.optimizer, 'seed');
end
end
