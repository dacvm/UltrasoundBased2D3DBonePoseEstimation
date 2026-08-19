function perCombinationTable = createCombinationEvaluationTable(perRunTable, parameterNames)
%CREATECOMBINATIONEVALUATIONTABLE Summarize seed results by combination.
% This function groups the evaluated run table by parameter combination,
% keeps the parameter columns declared by the experiment plan, calculates
% robust seed statistics, and ranks combinations by median surface RMSE. It
% is needed so future cost models can add parameters without changing this
% evaluation function.
%
% Inputs:
%   perRunTable         - One row per combination-seed run, including the
%                         calculated translation, rotation, and surface errors.
%   parameterNames      - Row cell array containing the swept parameter names
%                         in the canonical order defined by the experiment plan.
%
% Output:
%   perCombinationTable - One ranked row per hyperparameter combination.

%% CHECK THE TABLE INTERFACE

% Confirm that the parameter list has the exact shape produced by the experiment
% plan: one row cell array containing valid MATLAB column names. The function
% uses these names to create table columns, so other input shapes cannot be used.
if ~iscell(parameterNames) || ~isrow(parameterNames) || ...
        ~all(cellfun(@(name) ischar(name) && isrow(name) && isvarname(name), parameterNames))
    error('createCombinationEvaluationTable:InvalidParameterNames', ...
          'parameterNames must be a row cell array of valid MATLAB variable names.');
end

% Confirm that every parameter name appears only once. A duplicate would ask
% the function to create and fill the same output-table column more than once.
if numel(unique(parameterNames, 'stable')) ~= numel(parameterNames)
    error('createCombinationEvaluationTable:DuplicateParameterName', ...
          'parameterNames must not contain duplicate names.');
end

% List the run identifiers, declared parameters, optimizer results, and
% evaluation metrics used later in this function. Report any missing columns
% together so the caller can see exactly which input data is incomplete.
requiredColumns = [{'runNumber', 'combinationNumber', 'combinationId', 'costModel', 'seed'}, parameterNames, ...
                   {'status', 'runtimeSeconds', 'bestCost', 'evaluationStatus', ...
                    'translationErrorMm', 'rotationErrorDeg', 'surfaceRmseMm'}];
missingColumns = setdiff(requiredColumns, perRunTable.Properties.VariableNames, 'stable');
if ~isempty(missingColumns)
    error('createCombinationEvaluationTable:MissingColumn', ...
          'perRunTable is missing required column(s): %s.', strjoin(missingColumns, ', '));
end

% At least one run is needed to form a parameter combination and calculate its
% seed statistics. Stop here instead of returning an empty, misleading table.
if isempty(perRunTable)
    error('createCombinationEvaluationTable:EmptyRunTable', ...
          'perRunTable must contain at least one planned run.');
end

% Keep combinations in the same stable order used by the sweep plan.
combinationNumbers   = unique(perRunTable.combinationNumber, 'stable');
numberOfCombinations = numel(combinationNumbers);

% Start with identifiers that have the same meaning for every cost model.
perCombinationTable = table(combinationNumbers, ...
    strings(numberOfCombinations, 1), ...
    strings(numberOfCombinations, 1), ...
    'VariableNames', ...
    {'combinationNumber', ...
    'combinationId', ...
    'costModel'});

% Add the experiment's numeric parameter columns in validator-defined order.
for parameterIndex = 1:numel(parameterNames)
    parameterName = parameterNames{parameterIndex};
    perCombinationTable.(parameterName) = nan(numberOfCombinations, 1);
end

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

    % Get the first run (first seed) of each combination
    combinationNumber = combinationNumbers(combinationIndex);
    combinationRows   = perRunTable.combinationNumber == combinationNumber;
    currentRuns       = perRunTable(combinationRows, :);
    firstRun          = currentRuns(1, :);

    % Seed rows for one combination must describe the same model and parameters.
    if any(string(currentRuns.combinationId) ~= string(firstRun.combinationId)) || ...
            any(string(currentRuns.costModel) ~= string(firstRun.costModel))
        error('createCombinationEvaluationTable:InconsistentCombinationMetadata', ...
              'Combination %d has inconsistent identifiers or cost models.', combinationNumber);
    end

    % Visit every parameter declared by the experiment plan instead of 
    % naming model-specific fields for perCombinationTable explicitely. 
    % For each parameter, confirm that all seeds in this combination used 
    % the same value, then store that one value in the combination table so 
    % the aggregated metrics remain tied to their settings.
    for parameterIndex = 1:numel(parameterNames)
        parameterName  = parameterNames{parameterIndex};
        parameterValue = firstRun.(parameterName);
        if ~isnumeric(parameterValue) || ~isscalar(parameterValue) || any(currentRuns.(parameterName) ~= parameterValue)
            error('createCombinationEvaluationTable:InconsistentCombinationMetadata', ...
                  'Combination %d has inconsistent values for %s.', combinationNumber, parameterName);
        end
        perCombinationTable.(parameterName)(combinationIndex) = parameterValue;
    end

    % Copy the shared identity after confirming that every seed row agrees.
    perCombinationTable.combinationId(combinationIndex) = string(firstRun.combinationId);
    perCombinationTable.costModel(combinationIndex)     = string(firstRun.costModel);

    % Count optimizer outcomes separately from later evaluation outcomes.
    optimizerStatus  = string(currentRuns.status);
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
