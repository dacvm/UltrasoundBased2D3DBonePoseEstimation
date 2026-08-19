function experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec)
%CREATEBONEPOSEOPTIMIZATIONEXPERIMENTPLAN Expand candidates into run rows.
% This function creates the full Cartesian product of the explicit
% intersection tolerance and the selected cost model's hyperparameters. It
% then repeats each combination for every configured seed. Reading parameter
% names from the model definition lets future cost models extend the plan
% without adding model-specific columns here.
%
% Input:
%   experimentSpec - Validated schemaVersion04 experiment specification.
%
% Output:
%   experimentPlan - Struct containing a combination table, a run table, and
%                    counts describing the complete planned experiment.

%% BUILD THE HYPERPARAMETER COMBINATIONS

% Keep the geometric tolerance first, followed by the cost model's documented order.
costDefinition = getBonePoseCostDefinition(experimentSpec.cost.model);
parameterNames = [{'normalFacingToleranceDeg'}, costDefinition.hyperparameterNames];
experimentPlan.parameterNames = parameterNames;

% Collect candidate vectors in the same order as their future table columns.
candidateValues    = cell(1, numel(parameterNames));
candidateValues{1} = experimentSpec.intersection.normalFacingToleranceDeg;
for parameterIndex = 1:numel(costDefinition.hyperparameterNames)
    parameterName = costDefinition.hyperparameterNames{parameterIndex};
    candidateValues{parameterIndex + 1} = experimentSpec.cost.hyperparameters.(parameterName);
end

% Let NDGRID expand any number of declared numeric sweep parameters.
parameterGrids      = cell(size(candidateValues));
[parameterGrids{:}] = ndgrid(candidateValues{:});

% Number combinations in the stable linear order produced by ndgrid.
numberOfCombinations = numel(parameterGrids{1});
combinationNumber    = (1:numberOfCombinations).';
combinationId        = compose("combination_%04d", combinationNumber);
costModel            = repmat(string(experimentSpec.cost.model), numberOfCombinations, 1);

% Start each combination row with stable identifiers shared by every model.
experimentPlan.combinations = table(combinationNumber, combinationId, costModel);

% Add one readable scalar column for each declared swept parameter.
for parameterIndex = 1:numel(parameterNames)
    parameterName = parameterNames{parameterIndex};
    experimentPlan.combinations.(parameterName) = parameterGrids{parameterIndex}(:);
end

%% REPEAT EACH COMBINATION FOR EVERY SEED

% Keep all seeds for one combination together so the execution loop stays easy to follow.
numberOfSeeds   = numel(experimentSpec.experiment.seeds);
combinationRow  = repelem(combinationNumber, numberOfSeeds, 1);
seed            = repmat(experimentSpec.experiment.seeds(:), numberOfCombinations, 1);

% Give every combination-seed pair a stable run identifier inside this experiment.
numberOfRuns = numel(seed);
runNumber    = (1:numberOfRuns).';
runId        = compose("run_%06d", runNumber);

% Start each run row with identifiers, model identity, and its repeat seed.
experimentPlan.runs = table( ...
    runNumber, runId, combinationRow, ...
    experimentPlan.combinations.combinationId(combinationRow), ...
    experimentPlan.combinations.costModel(combinationRow), seed, ...
    'VariableNames', {'runNumber', 'runId', 'combinationNumber', ...
    'combinationId', 'costModel', 'seed'});

% Copy every scalar parameter column so the run table remains analysis friendly.
runParameterTable = experimentPlan.combinations(combinationRow, parameterNames);
experimentPlan.runs = [experimentPlan.runs, runParameterTable];

% Store simple counts for progress messages and later inspection.
experimentPlan.numberOfCombinations = numberOfCombinations;
experimentPlan.numberOfSeeds        = numberOfSeeds;
experimentPlan.numberOfRuns         = numberOfRuns;
end
