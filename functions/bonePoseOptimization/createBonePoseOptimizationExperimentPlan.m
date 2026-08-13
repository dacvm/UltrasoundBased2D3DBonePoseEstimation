function experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec)
%CREATEBONEPOSEOPTIMIZATIONEXPERIMENTPLAN Expand v03 candidates into run rows.
% This function creates the full Cartesian product of the four swept
% hyperparameters, then repeats each combination for every configured seed.
% Keeping this work separate makes the planned workload easy to inspect and test.
%
% Input:
%   experimentSpec - Validated v03 experiment specification.
%
% Output:
%   experimentPlan - Struct containing a combination table, a run table, and
%                    counts describing the complete planned experiment.

%% BUILD THE HYPERPARAMETER COMBINATIONS

% Create one grid entry for every possible candidate combination.
[normalToleranceGrid, minReferenceGrid, nMinGrid, lambdaGrid] = ndgrid( ...
    experimentSpec.intersection.normalFacingToleranceDeg, ...
    experimentSpec.cost.minReferencePixels, ...
    experimentSpec.cost.nMinPixels, ...
    experimentSpec.cost.lambdaMissing);

% Number combinations in the stable linear order produced by ndgrid.
numberOfCombinations = numel(normalToleranceGrid);
combinationNumber = (1:numberOfCombinations).';
combinationId = compose("combination_%04d", combinationNumber);

% Store one readable row for every scalar runtime configuration.
experimentPlan.combinations = table( ...
    combinationNumber, combinationId, ...
    normalToleranceGrid(:), minReferenceGrid(:), nMinGrid(:), lambdaGrid(:), ...
    'VariableNames', {'combinationNumber', 'combinationId', ...
    'normalFacingToleranceDeg', 'minReferencePixels', ...
    'nMinPixels', 'lambdaMissing'});

%% REPEAT EACH COMBINATION FOR EVERY SEED

% Keep all seeds for one combination together so the execution loop stays easy to follow.
numberOfSeeds = numel(experimentSpec.experiment.seeds);
combinationRow = repelem(combinationNumber, numberOfSeeds, 1);
seed = repmat(experimentSpec.experiment.seeds(:), numberOfCombinations, 1);

% Give every combination-seed pair a stable run identifier inside this experiment.
numberOfRuns = numel(seed);
runNumber = (1:numberOfRuns).';
runId = compose("run_%06d", runNumber);

% Copy the scalar candidate values into each run row for direct CSV analysis.
experimentPlan.runs = table( ...
    runNumber, runId, combinationRow, ...
    experimentPlan.combinations.combinationId(combinationRow), seed, ...
    experimentPlan.combinations.normalFacingToleranceDeg(combinationRow), ...
    experimentPlan.combinations.minReferencePixels(combinationRow), ...
    experimentPlan.combinations.nMinPixels(combinationRow), ...
    experimentPlan.combinations.lambdaMissing(combinationRow), ...
    'VariableNames', {'runNumber', 'runId', 'combinationNumber', ...
    'combinationId', 'seed', 'normalFacingToleranceDeg', ...
    'minReferencePixels', 'nMinPixels', 'lambdaMissing'});

% Store simple counts for progress messages and later inspection.
experimentPlan.numberOfCombinations = numberOfCombinations;
experimentPlan.numberOfSeeds = numberOfSeeds;
experimentPlan.numberOfRuns = numberOfRuns;
end
