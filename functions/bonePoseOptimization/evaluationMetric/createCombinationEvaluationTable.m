function perCombinationTable = createCombinationEvaluationTable(perRunTable)
%CREATECOMBINATIONEVALUATIONTABLE Summarize seed results by combination.
% This function groups the evaluated run table by hyperparameter
% combination, calculates robust seed statistics, and ranks combinations by
% median surface RMSE. It is needed so users can compare hyperparameters
% without reading every individual CMA-ES seed result.
%
% Input:
%   perRunTable         - One row per combination-seed run, including the
%                         calculated translation, rotation, and surface errors.
%
% Output:
%   perCombinationTable - One ranked row per hyperparameter combination.

% Keep combinations in the same stable order used by the sweep plan.
combinationNumbers   = unique(perRunTable.combinationNumber, 'stable');
numberOfCombinations = numel(combinationNumbers);

% Start with the identifiers and hyperparameters needed to interpret each row.
perCombinationTable = table(combinationNumbers, ...
    strings(numberOfCombinations, 1), ...
    nan(numberOfCombinations, 1), ...
    nan(numberOfCombinations, 1), ...
    nan(numberOfCombinations, 1), ...
    nan(numberOfCombinations, 1), ...
    'VariableNames', ...
    {'combinationNumber', ...
    'combinationId', ...
    'normalFacingToleranceDeg', ...
    'minReferencePixels', ...
    'nMinPixels', ...
    'lambdaMissing'});

% Preallocate run-count columns so failed combinations remain visible.
perCombinationTable.numberPlanned               = zeros(numberOfCombinations, 1);
perCombinationTable.numberOptimizerCompleted    = zeros(numberOfCombinations, 1);
perCombinationTable.numberOptimizerFailed       = zeros(numberOfCombinations, 1);
perCombinationTable.numberEvaluated             = zeros(numberOfCombinations, 1);
perCombinationTable.numberEvaluationFailed      = zeros(numberOfCombinations, 1);
perCombinationTable.numberSkipped               = zeros(numberOfCombinations, 1);
perCombinationTable.evaluationRate              = zeros(numberOfCombinations, 1);

% Preallocate the reported optimizer-cost statistics.
perCombinationTable.medianBestCost              = nan(numberOfCombinations, 1);
perCombinationTable.q25BestCost                 = nan(numberOfCombinations, 1);
perCombinationTable.q75BestCost                 = nan(numberOfCombinations, 1);
perCombinationTable.iqrBestCost                 = nan(numberOfCombinations, 1);

% Preallocate the reported translation-error statistics.
perCombinationTable.medianTranslationErrorMm    = nan(numberOfCombinations, 1);
perCombinationTable.q25TranslationErrorMm       = nan(numberOfCombinations, 1);
perCombinationTable.q75TranslationErrorMm       = nan(numberOfCombinations, 1);
perCombinationTable.iqrTranslationErrorMm       = nan(numberOfCombinations, 1);

% Preallocate the reported rotation-error statistics.
perCombinationTable.medianRotationErrorDeg      = nan(numberOfCombinations, 1);
perCombinationTable.q25RotationErrorDeg         = nan(numberOfCombinations, 1);
perCombinationTable.q75RotationErrorDeg         = nan(numberOfCombinations, 1);
perCombinationTable.iqrRotationErrorDeg         = nan(numberOfCombinations, 1);

% Preallocate the primary surface-RMSE ranking statistics.
perCombinationTable.medianSurfaceRmseMm         = nan(numberOfCombinations, 1);
perCombinationTable.q25SurfaceRmseMm            = nan(numberOfCombinations, 1);
perCombinationTable.q75SurfaceRmseMm            = nan(numberOfCombinations, 1);
perCombinationTable.iqrSurfaceRmseMm            = nan(numberOfCombinations, 1);

% Preallocate the runtime statistics used when accurate combinations tie.
perCombinationTable.medianRuntimeSeconds        = nan(numberOfCombinations, 1);
perCombinationTable.q25RuntimeSeconds           = nan(numberOfCombinations, 1);
perCombinationTable.q75RuntimeSeconds           = nan(numberOfCombinations, 1);
perCombinationTable.iqrRuntimeSeconds           = nan(numberOfCombinations, 1);

% Summarize all seed results that belong to each hyperparameter combination.
for combinationIndex = 1:numberOfCombinations

    combinationNumber = combinationNumbers(combinationIndex);
    combinationRows   = perRunTable.combinationNumber == combinationNumber;
    currentRuns       = perRunTable(combinationRows, :);
    firstRun          = currentRuns(1, :);

    % Copy identifiers and scalar hyperparameters from the first seed row.
    perCombinationTable.combinationId(combinationIndex)             = string(firstRun.combinationId);
    perCombinationTable.normalFacingToleranceDeg(combinationIndex)  = firstRun.normalFacingToleranceDeg;
    perCombinationTable.minReferencePixels(combinationIndex)        = firstRun.minReferencePixels;
    perCombinationTable.nMinPixels(combinationIndex)                = firstRun.nMinPixels;
    perCombinationTable.lambdaMissing(combinationIndex)             = firstRun.lambdaMissing;

    % Count optimizer outcomes separately from later evaluation outcomes.
    optimizerStatus   = string(currentRuns.status);
    evaluationStatus = string(currentRuns.evaluationStatus);
    perCombinationTable.numberPlanned(combinationIndex)             = height(currentRuns);
    perCombinationTable.numberOptimizerCompleted(combinationIndex)  = sum(optimizerStatus == "completed");
    perCombinationTable.numberOptimizerFailed(combinationIndex)     = sum(optimizerStatus == "failed");
    perCombinationTable.numberEvaluated(combinationIndex)           = sum(evaluationStatus == "evaluated");
    perCombinationTable.numberEvaluationFailed(combinationIndex)    = sum(evaluationStatus == "failed");
    perCombinationTable.numberSkipped(combinationIndex)             = sum(evaluationStatus == "skipped");
    perCombinationTable.evaluationRate(combinationIndex)            = perCombinationTable.numberEvaluated(combinationIndex) / height(currentRuns);

    % Use the same evaluated seeds for cost, accuracy, and runtime summaries.
    evaluatedRows = evaluationStatus == "evaluated";

    % Calculate optimizer-cost statistics across this combination's seeds.
    [perCombinationTable.medianBestCost(combinationIndex), ...
     perCombinationTable.q25BestCost(combinationIndex), ...
     perCombinationTable.q75BestCost(combinationIndex), ...
     perCombinationTable.iqrBestCost(combinationIndex)] = ...
        summarizeMetric(currentRuns.bestCost(evaluatedRows));

    % Calculate translation-error statistics across the same evaluated seeds.
    [perCombinationTable.medianTranslationErrorMm(combinationIndex), ...
     perCombinationTable.q25TranslationErrorMm(combinationIndex), ...
     perCombinationTable.q75TranslationErrorMm(combinationIndex), ...
     perCombinationTable.iqrTranslationErrorMm(combinationIndex)] = ...
        summarizeMetric(currentRuns.translationErrorMm(evaluatedRows));

    % Calculate rotation-error statistics across the same evaluated seeds.
    [perCombinationTable.medianRotationErrorDeg(combinationIndex), ...
     perCombinationTable.q25RotationErrorDeg(combinationIndex), ...
     perCombinationTable.q75RotationErrorDeg(combinationIndex), ...
     perCombinationTable.iqrRotationErrorDeg(combinationIndex)] = ...
        summarizeMetric(currentRuns.rotationErrorDeg(evaluatedRows));

    % Calculate surface-RMSE statistics used to rank the combinations.
    [perCombinationTable.medianSurfaceRmseMm(combinationIndex), ...
     perCombinationTable.q25SurfaceRmseMm(combinationIndex), ...
     perCombinationTable.q75SurfaceRmseMm(combinationIndex), ...
     perCombinationTable.iqrSurfaceRmseMm(combinationIndex)] = ...
        summarizeMetric(currentRuns.surfaceRmseMm(evaluatedRows));

    % Calculate runtime statistics for practical comparison after accuracy.
    [perCombinationTable.medianRuntimeSeconds(combinationIndex), ...
     perCombinationTable.q25RuntimeSeconds(combinationIndex), ...
     perCombinationTable.q75RuntimeSeconds(combinationIndex), ...
     perCombinationTable.iqrRuntimeSeconds(combinationIndex)] = ...
        summarizeMetric(currentRuns.runtimeSeconds(evaluatedRows));
end

% Rank only combinations that have a valid median surface error.
perCombinationTable.combinationRank = nan(numberOfCombinations, 1);
validCombinationRows = isfinite(perCombinationTable.medianSurfaceRmseMm);
[~, validOrder] = sort(perCombinationTable.medianSurfaceRmseMm(validCombinationRows));
validIndexes = find(validCombinationRows);
perCombinationTable.combinationRank(validIndexes(validOrder)) = (1:numel(validIndexes)).';

% Put the best combinations first while retaining failed combinations at the end.
sortRank = perCombinationTable.combinationRank;
sortRank(~isfinite(sortRank)) = inf;
[~, tableOrder] = sortrows([sortRank, perCombinationTable.combinationNumber], [1 2]);
perCombinationTable = perCombinationTable(tableOrder, :);

% Keep the rank beside the identifiers because it is the main selection result.
perCombinationTable = movevars(perCombinationTable, 'combinationRank', 'Before', 'combinationNumber');
end


function [medianValue, q25Value, q75Value, iqrValue] = summarizeMetric(values)
%SUMMARIZEMETRIC Calculate robust summary values for one seed metric.
% values contains one scalar metric per evaluated seed. The four outputs
% contain its median, lower quartile, upper quartile, and interquartile range.

% Ignore unavailable values so one failed seed does not erase valid results.
values = values(isfinite(values));
if isempty(values)
    medianValue = NaN;
    q25Value = NaN;
    q75Value = NaN;
    iqrValue = NaN;
    return;
end

medianValue = median(values);
quartiles   = prctile(values, [25 75]);
q25Value    = quartiles(1);
q75Value    = quartiles(2);
iqrValue    = q75Value - q25Value;
end
