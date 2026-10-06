function experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec)
%CREATEBONEPOSEOPTIMIZATIONEXPERIMENTPLAN Expand candidates into run rows.
% This function creates the full Cartesian product of the explicit
% intersection tolerance and the selected cost model's hyperparameters. It
% then repeats each combination for every configured seed. Reading the
% validated parameter fields lets future cost models extend the plan without
% adding model-specific columns here.
%
% Where it fits in the framework:
%   A bone-pose experiment runs in three configuration steps, always in
%   this order (see main_bonePoseOptimization_*.m and
%   runBonePoseOptimizationExperiment.m):
%     1. createBonePoseOptimizationExperimentConfig
%        JSON file  ->  experimentSpec (candidate lists + seeds, checked)
%     2. createBonePoseOptimizationExperimentPlan (this function)
%        experimentSpec  ->  table of every combination and every run
%     3. createBonePoseOptimizationRunConfig
%        experimentSpec + one plan row  ->  config for one single run
%   It is called once, right after the spec is read and before any
%   optimization starts. The runner then simply loops over the rows of the
%   tables it returns.
%
% Why it is needed:
%   The spec only says "try these values for A, these for B, with these
%   seeds". Something has to turn that into a concrete to-do list: every
%   combination of values (A x B x ...) and, for each, one run per seed.
%   Doing this once, up front, in one table has several benefits:
%     - The runner stays a simple loop over rows; it does not need to know
%       how many parameters exist or how they are combined.
%     - Every combination and run gets a fixed number and ID, so output
%       folders, progress messages ("run 12 of 48") and saved results all
%       refer to the same names.
%     - The total number of runs is known before starting, so the user can
%       judge how long the experiment will take.
%     - The run table holds every parameter value next to its seed, so it
%       can be joined directly with results for analysis.
%   Two tables are made because some work is shared by all seeds of one
%   combination (slow input preparation, done once per combination row),
%   while CMA-ES itself is done once per run row.
%
% Input:
%   experimentSpec - Validated schemaVersion04 experiment specification.
%
% Output:
%   experimentPlan - Struct containing a combination table, a run table, and
%                    counts describing the complete planned experiment.

%% BUILD THE HYPERPARAMETER COMBINATIONS

% Read the names of the swept cost parameters from the spec instead of
% hard-coding them. That way, adding a new cost model with new parameters
% needs no change in this file. The model validator has already put these
% names in a fixed (canonical) order, so the table columns always appear in
% the same order and combination numbers mean the same thing between runs.
costHyperparameterNames = fieldnames(experimentSpec.cost.hyperparameters).';

% Each parameter becomes a table column, and the tables also have columns
% we add ourselves (IDs, seed, cost model, the tolerance). If a cost model
% ever named a parameter like one of those, it would silently overwrite the
% ID or seed column and break run bookkeeping. We refuse that case here.
reservedParameterNames = {'combinationNumber', 'combinationId', 'costModel', 'runNumber', 'runId', 'seed', 'normalFacingToleranceDeg'};
if any(ismember(costHyperparameterNames, reservedParameterNames))
    error('createBonePoseOptimizationExperimentPlan:ReservedParameterName', ...
          'A cost hyperparameter name conflicts with an experiment-table column.');
end

% The full list of swept parameters is the intersection tolerance (always
% present, independent of the cost model) followed by the cost model's own
% parameters. Putting the tolerance first keeps its column in the same
% place for every cost model. The list is stored in the plan so later code
% (e.g. analysis and plots) knows which columns are parameters.
parameterNames = [{'normalFacingToleranceDeg'}, costHyperparameterNames];
experimentPlan.parameterNames = parameterNames;

% Gather the candidate value list for each parameter into one cell array,
% in exactly the same order as parameterNames. ndgrid below needs them in
% one list, and keeping the order aligned lets us later match grid i with
% parameter name i without any lookup.
candidateValues    = cell(1, numel(parameterNames));
candidateValues{1} = experimentSpec.intersection.normalFacingToleranceDeg;
for parameterIndex = 1:numel(costHyperparameterNames)
    parameterName = costHyperparameterNames{parameterIndex};
    candidateValues{parameterIndex + 1} = experimentSpec.cost.hyperparameters.(parameterName);
end

% Build every combination of candidate values (the Cartesian product).
% ndgrid does this for any number of parameters in one call: grid i holds
% the value of parameter i for each combination. This avoids writing one
% nested loop per parameter, which would need changing for every new model.
parameterGrids      = cell(size(candidateValues));
[parameterGrids{:}] = ndgrid(candidateValues{:});

% Give each combination a number and a readable ID. The order follows
% ndgrid's output, which is deterministic, so the same spec always gives
% the same numbering; this keeps output folder names stable when an
% experiment is rerun. The cost model name is repeated on every row so a
% row on its own is enough to know which model it belongs to (the run-
% config step checks this to avoid mixing plans and specs).
numberOfCombinations = numel(parameterGrids{1});
combinationNumber    = (1:numberOfCombinations).';
combinationId        = compose("combination_%04d", combinationNumber);
costModel            = repmat(string(experimentSpec.cost.model), numberOfCombinations, 1);

% Start the combination table with the ID columns that every cost model has.
experimentPlan.combinations = table(combinationNumber, combinationId, costModel);

% Add one column per swept parameter, with one plain number per row. A
% flat table of scalars is easy to read, print, filter, and save, and it is
% exactly the shape createBonePoseOptimizationRunConfig expects.
for parameterIndex = 1:numel(parameterNames)
    parameterName = parameterNames{parameterIndex};
    experimentPlan.combinations.(parameterName) = parameterGrids{parameterIndex}(:);
end

%% REPEAT EACH COMBINATION FOR EVERY SEED

% Each combination is run once per seed to see how much the result depends
% on CMA-ES randomness. The rows are ordered combination by combination
% (all seeds of combination 1, then all seeds of combination 2, ...). This
% matches how the runner works: it prepares the inputs for one combination
% once and then runs all its seeds, so this order avoids repeating the slow
% preparation and keeps progress output easy to follow.
numberOfSeeds   = numel(experimentSpec.experiment.seeds);
combinationRow  = repelem(combinationNumber, numberOfSeeds, 1);
seed            = repmat(experimentSpec.experiment.seeds(:), numberOfCombinations, 1);

% Give every (combination, seed) pair its own run number and ID. The ID is
% used to name the output of that single run, so it must be unique within
% the experiment and stay the same if the same spec is planned again.
numberOfRuns = numel(seed);
runNumber    = (1:numberOfRuns).';
runId        = compose("run_%06d", runNumber);

% Build the run table. Besides its own IDs, each run row also stores the
% combination it belongs to, the cost model and its seed, so a single row
% is enough to rebuild its config and to find its results again.
experimentPlan.runs = table( ...
    runNumber, runId, combinationRow, ...
    experimentPlan.combinations.combinationId(combinationRow), ...
    experimentPlan.combinations.costModel(combinationRow), seed, ...
    'VariableNames', {'runNumber', 'runId', 'combinationNumber', ...
    'combinationId', 'costModel', 'seed'});

% Also copy the parameter values onto each run row. This duplicates data
% from the combination table on purpose: during analysis one can then
% group or plot results by any parameter directly from the run table,
% without first joining it with the combination table.
runParameterTable = experimentPlan.combinations(combinationRow, parameterNames);
experimentPlan.runs = [experimentPlan.runs, runParameterTable];

% Store the totals so the runner can print progress ("run 12 of 48") and so
% the size of the experiment can be checked before and after running it.
experimentPlan.numberOfCombinations = numberOfCombinations;
experimentPlan.numberOfSeeds        = numberOfSeeds;
experimentPlan.numberOfRuns         = numberOfRuns;
end
