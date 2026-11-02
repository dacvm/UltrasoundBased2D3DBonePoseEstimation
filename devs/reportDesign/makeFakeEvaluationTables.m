% Build a FAKE evaluation_tables.js and fake figure PNGs for the report design mock.
% Used to review the design of the /analyze-hyperparamsweep report (reportTemplate.html)
% on a shared page without uploading real results.
% Only the table layout (column names, statistic names, definitions) matches the real
% evaluation; every value, file name and experiment name is made up.

% Generated files go to output/reportDesign/ (git-ignored), like all generated results.
projectRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
outFolder = fullfile(projectRoot, 'output', 'reportDesign');
if ~isfolder(outFolder), mkdir(outFolder); end

% The statistic names and definitions are copied from one real evaluation, so they
% always match what main_bonePoseOptimization_evaluation.m writes. Set any evaluated experiment.
experimentFolderName = 'intensityPIMLOP_20261015_161737_663';
realEvaluationFolder = fullfile(projectRoot, 'output', 'bonePoseOptimization', 'experiments', experimentFolderName, 'evaluation');
rng(7);

%% Grid and start pose (fake)
costModel = "intensityPIMLOP";
parameterNames = ["normalFacingToleranceDeg", "intensitySmoothingSigmaMm", "kappa", "weight"];
[sigmaGrid, kappaGrid, weightGrid] = ndgrid([1 2 3], [10 50 200], [0.25 0.5 0.75]);
grid = [30 * ones(27, 1), sigmaGrid(:), kappaGrid(:), weightGrid(:)];
seeds = 2001:2005;
startRmse = 9.0; startTrans = 6.0; startRot = 8.6;
translationBound = 10; rotationBound = 10;

%% Runs (fake): some combinations move away from the start more often than others
rows = {};
runNumber = 0;
for c = 1:27
    sigma = grid(c, 2); kappa = grid(c, 3); weight = grid(c, 4);
    moveProbability = 0.27 + 0.25 * (sigma == 3) + 0.2 * (weight == 0.75) - 0.12 * (kappa == 10) + 0.1 * (kappa == 50);
    initialCost = 1 + 0.25 * log10(kappa) + 0.05 * randn;
    for s = seeds
        runNumber = runNumber + 1;
        moved = rand < moveProbability;
        r = struct();
        r.runNumber = runNumber;
        r.runId = sprintf("run_%06d", runNumber);
        r.combinationNumber = c;
        r.combinationId = sprintf("combination_%04d", c);
        r.costModel = costModel;
        r.seed = s;
        r.normalFacingToleranceDeg = grid(c, 1);
        r.intensitySmoothingSigmaMm = sigma;
        r.kappa = kappa;
        r.weight = weight;
        r.status = "completed";
        startTime = datetime(2026, 1, 1, 9, 0, 0) + minutes(5 * runNumber);
        r.runtimeSeconds = 260 + 80 * rand;
        r.startTime = string(startTime, 'yyyy-MM-dd HH:mm:ss.SSS');
        r.endTime = string(startTime + seconds(r.runtimeSeconds), 'yyyy-MM-dd HH:mm:ss.SSS');
        r.initialCost = initialCost;
        r.functionEvaluations = 106;
        r.stopFlag = "maxfunevals";
        r.resultFilePath = "demo\runs\" + r.combinationId + "\seed_" + s + "\runResult.mat";
        r.errorStage = ""; r.errorIdentifier = ""; r.errorMessage = "";
        r.evaluationStatus = "evaluated"; r.evaluationMessage = "";
        if moved
            improvement = 2 + 3 * (kappa == 50) + 1.8 * (sigma == 3) + 0.8 * randn;
            r.surfaceRmseMm = max(0.6, startRmse - improvement);
            r.translationErrorMm = max(0.3, 0.7 * r.surfaceRmseMm + 0.3 * randn);
            r.rotationErrorDeg = max(0.3, 0.95 * r.surfaceRmseMm + 0.6 * randn);
            r.bestCost = initialCost * (0.97 - 0.06 * rand);
            r.startToFinalTranslationMm = 1 + 5 * rand;
            r.startToFinalRotationDeg = 1 + 7 * rand;
            if rand < 0.3, r.stopFlag = "tolfun"; r.functionEvaluations = 60 + randi(40); end
        else
            r.surfaceRmseMm = startRmse; r.translationErrorMm = startTrans; r.rotationErrorDeg = startRot;
            r.bestCost = initialCost; r.startToFinalTranslationMm = 0; r.startToFinalRotationDeg = 0;
        end
        rows{end + 1} = r; %#ok<SAGROW>
    end
end
perRunTable = struct2table([rows{:}]);

% One run fails while saving its result, like a real setup error.
failed = 63;
perRunTable.status(failed) = "failed";
perRunTable.stopFlag(failed) = "";
perRunTable.errorStage(failed) = "optimization";
perRunTable.errorIdentifier(failed) = "MATLAB:save:cantWriteFile";
perRunTable.errorMessage(failed) = "Unable to write file 'demo\runs\variablescmaes.mat'.";
perRunTable.evaluationStatus(failed) = "skipped";
perRunTable.evaluationMessage(failed) = "The optimizer run did not complete.";
numericColumns = ["bestCost", "functionEvaluations", "translationErrorMm", "rotationErrorDeg", "surfaceRmseMm", "startToFinalTranslationMm", "startToFinalRotationDeg"];
for name = numericColumns, perRunTable.(name)(failed) = NaN; end

% Rank runs by surface RMSE, with the rank as the first column like the real table.
[~, order] = sort(perRunTable.surfaceRmseMm);
rank = NaN(height(perRunTable), 1);
rank(order(~isnan(perRunTable.surfaceRmseMm(order)))) = 1:sum(~isnan(perRunTable.surfaceRmseMm));
perRunTable = addvars(perRunTable, rank, 'Before', 1, 'NewVariableNames', 'surfaceRmseRank');
perRunTable = movevars(perRunTable, 'runtimeSeconds', 'After', 'endTime');
perRunTable = sortrows(perRunTable, {'surfaceRmseRank', 'runNumber'});
evaluated = perRunTable(perRunTable.evaluationStatus == "evaluated", :);

%% Combinations (fake, computed from the fake runs)
q = @(x, p) quantile(x, p);
comboRows = {};
for c = 1:27
    runs = evaluated(evaluated.combinationNumber == c, :);
    k = struct();
    k.combinationNumber = c; k.combinationId = sprintf("combination_%04d", c); k.costModel = costModel;
    for p = 1:4, k.(parameterNames(p)) = grid(c, p); end
    k.numberPlanned = 5;
    k.numberOptimizerCompleted = height(runs); k.numberOptimizerFailed = 5 - height(runs);
    k.numberEvaluated = height(runs); k.numberEvaluationFailed = 0; k.numberSkipped = 5 - height(runs);
    k.evaluationRate = height(runs) / 5;
    for name = ["BestCost", "TranslationErrorMm", "RotationErrorDeg", "SurfaceRmseMm", "StartToFinalTranslationMm", "StartToFinalRotationDeg", "RuntimeSeconds"]
        x = runs.(lower(extractBefore(name, 2)) + extractAfter(name, 1));
        k.("median" + name) = median(x); k.("q25" + name) = q(x, 0.25);
        k.("q75" + name) = q(x, 0.75); k.("iqr" + name) = iqr(x);
    end
    k.medianSeedPairTranslationMm = median(abs(runs.startToFinalTranslationMm - runs.startToFinalTranslationMm'), 'all');
    k.medianSeedPairRotationDeg = median(abs(runs.startToFinalRotationDeg - runs.startToFinalRotationDeg'), 'all');
    comboRows{end + 1} = k; %#ok<SAGROW>
end
perCombinationTable = sortrows(struct2table([comboRows{:}]), {'medianSurfaceRmseMm', 'iqrSurfaceRmseMm'});
perCombinationTable = addvars(perCombinationTable, (1:27)', 'Before', 1, 'NewVariableNames', 'combinationRank');

%% Derived statistics (fake values, real statistic names and definitions)
opts = detectImportOptions(fullfile(realEvaluationFolder, 'derived_statistics.csv'), 'Delimiter', ','); opts.DataLines = [2 Inf]; opts = setvartype(opts, 'string');
realDerived = readtable(fullfile(realEvaluationFolder, 'derived_statistics.csv'), opts);
derivedStatisticsTable = realDerived;
derivedStatisticsTable.value = strings(height(realDerived), 1);
moved = evaluated.startToFinalTranslationMm > 1e-3 | evaluated.startToFinalRotationDeg > 1e-3;
costDecreased = evaluated.bestCost < evaluated.initialCost;
fakeValues = dictionary( ...
    "metadata|costModel|", costModel, "metadata|numberOfCombinations|", "27", "metadata|numberOfSeeds|", "5", ...
    "metadata|input|bone", "DEMO", "metadata|input|validSnapshotsMatFile", "demo_validSnapshots.mat", ...
    "metadata|input|boneSurfaceMatFile", "demo_boneSurface.mat", "metadata|input|ctPostProcessedMatFile", "demo_ctBones.mat", ...
    "metadata|input|coarseRegistrationMatFile", "demo_coarseRegistration.mat", ...
    "metadata|sweptValues|normalFacingToleranceDeg", "30", "metadata|sweptValues|intensitySmoothingSigmaMm", "1 2 3", ...
    "metadata|sweptValues|kappa", "10 50 200", "metadata|sweptValues|weight", "0.25 0.5 0.75", ...
    "metadata|optimizer|maxFunctionEvaluations", "100", "metadata|optimizer|populationSize", "8", ...
    "metadata|optimizer|translationBoundMm", string(translationBound), "metadata|optimizer|rotationBoundDeg", string(rotationBound), ...
    "startPose|initialSurfaceRmseMm|", string(startRmse), "startPose|initialTranslationErrorMm|", string(startTrans), ...
    "startPose|initialRotationErrorDeg|", string(startRot), ...
    "optimizerHealth|numberOfRuns|", "135", "optimizerHealth|numberOptimizerCompleted|", "134", "optimizerHealth|numberEvaluated|", "134", ...
    "costValidity|spearmanBestCostVsSurfaceRmse|", string(corr(evaluated.bestCost, evaluated.surfaceRmseMm, 'Type', 'Spearman')), ...
    "costValidity|fractionRunsCostDecreased|", string(mean(costDecreased)), ...
    "costValidity|medianRelativeCostDecrease|", string(median((evaluated.initialCost - evaluated.bestCost) ./ evaluated.initialCost)), ...
    "costValidity|fractionRunsSurfaceRmseImproved|", string(mean(evaluated.surfaceRmseMm < startRmse)), ...
    "costValidity|medianSurfaceRmseImprovementMm|", string(median(startRmse - evaluated.surfaceRmseMm)), ...
    "movement|fractionRunsMoved|", string(mean(moved)), ...
    "movement|medianStartToFinalTranslationMm|", string(median(evaluated.startToFinalTranslationMm)), ...
    "movement|medianStartToFinalRotationDeg|", string(median(evaluated.startToFinalRotationDeg)), ...
    "accuracy|successSurfaceRmseThresholdMm|", "1", "accuracy|successRate|", string(mean(evaluated.surfaceRmseMm <= 1)), ...
    "accuracy|clinicalTranslationThresholdMm|", "1", "accuracy|clinicalRotationThresholdDeg|", "1", ...
    "accuracy|clinicalRate|", string(mean(evaluated.translationErrorMm <= 1 & evaluated.rotationErrorDeg <= 1)), ...
    "accuracy|bestRunSurfaceRmseMm|", string(min(evaluated.surfaceRmseMm)), ...
    "seedSpread|medianIqrSurfaceRmseMm|", string(median(perCombinationTable.iqrSurfaceRmseMm)), ...
    "seedSpread|medianSeedPairTranslationMm|", string(median(perCombinationTable.medianSeedPairTranslationMm)), ...
    "seedSpread|medianSeedPairRotationDeg|", string(median(perCombinationTable.medianSeedPairRotationDeg)));
for i = 1:height(derivedStatisticsTable)
    g = derivedStatisticsTable.group(i); s = derivedStatisticsTable.statistic(i); d = derivedStatisticsTable.detail(i);
    if ismissing(d), d = ""; end
    key = g + "|" + s + "|" + d;
    if isKey(fakeValues, key)
        derivedStatisticsTable.value(i) = fakeValues(key);
    elseif s == "fractionRunsStoppedBy"
        derivedStatisticsTable.value(i) = string(mean(evaluated.stopFlag == d));
    elseif s == "bestMedianSurfaceRmseMm"
        derivedStatisticsTable.detail(i) = perCombinationTable.combinationId(1);
        derivedStatisticsTable.value(i) = string(perCombinationTable.medianSurfaceRmseMm(1));
    elseif g == "parameterEffect" && s == "medianSurfaceRmseMm"
        parts = split(d, " = ");
        derivedStatisticsTable.value(i) = string(median(evaluated.surfaceRmseMm(evaluated.(parts(1)) == str2double(parts(2)))));
    end
end
% The real experiment had one stop reason; add the second one the fake runs use.
stopRow = derivedStatisticsTable(derivedStatisticsTable.statistic == "fractionRunsStoppedBy", :);
stopRow.detail = "tolfun"; stopRow.value = string(mean(evaluated.stopFlag == "tolfun"));
derivedStatisticsTable = [derivedStatisticsTable(1:find(derivedStatisticsTable.statistic == "fractionRunsStoppedBy"), :); stopRow; ...
                          derivedStatisticsTable(find(derivedStatisticsTable.statistic == "fractionRunsStoppedBy") + 1:end, :)];
% Range and grid-edge rows follow from the per-value medians.
for p = parameterNames(2:4)
    perValue = derivedStatisticsTable(derivedStatisticsTable.statistic == "medianSurfaceRmseMm" & startsWith(derivedStatisticsTable.detail, p + " ="), :);
    values = str2double(perValue.value);
    derivedStatisticsTable.value(derivedStatisticsTable.statistic == "surfaceRmseRangeMm" & derivedStatisticsTable.detail == p) = string(max(values) - min(values));
    [~, best] = min(values);
    position = ["lowest", "interior", "highest"];
    derivedStatisticsTable.value(derivedStatisticsTable.statistic == "bestValuePosition" & derivedStatisticsTable.detail == p) = position(best);
end
% Numbers as numbers (like the real file), text as text.
valueCell = cellstr(derivedStatisticsTable.value);
asNumber = str2double(derivedStatisticsTable.value);
isNumber = ~isnan(asNumber) & ~contains(derivedStatisticsTable.value, " ");
valueCell(isNumber) = num2cell(asNumber(isNumber));
derivedStatisticsTable.value = valueCell;

%% Write evaluation_tables.js exactly like the evaluation script does
evaluationTables.experimentName         = "DEMO_fakeData_20260101_090000_000";
evaluationTables.perRunTable            = perRunTable;
evaluationTables.perCombinationTable    = perCombinationTable;
evaluationTables.derivedStatisticsTable = derivedStatisticsTable;
evaluationTables.evaluationMetadata     = struct('schemaVersion', 4, 'costModel', costModel, 'parameterNames', parameterNames);
writelines("window.EVALUATION_TABLES = " + jsonencode(evaluationTables) + ";", fullfile(outFolder, 'evaluation_tables.js'));

%% Fake figures, roughly like the real MATLAB figures
stamp = @(ax) text(ax, 0.99, 0.02, 'FAKE DATA', 'Units', 'normalized', 'HorizontalAlignment', 'right', 'Color', [0.8 0.2 0.2], 'FontWeight', 'bold');

f = figure('Visible', 'off', 'Position', [0 0 1100 500]);
top = perCombinationTable.combinationId(1:10);
inTop = ismember(evaluated.combinationId, top);
ax = axes(f); boxchart(ax, categorical(evaluated.combinationId(inTop), top), evaluated.surfaceRmseMm(inTop));
yline(ax, startRmse, '--', 'start pose'); ylabel(ax, 'Surface RMSE (mm)'); title(ax, 'Surface RMSE for the 10 best combinations'); stamp(ax);
exportgraphics(f, fullfile(outFolder, 'surfaceRmseBoxplot.png'), 'Resolution', 110); close(f);

f = figure('Visible', 'off', 'Position', [0 0 900 500]);
ax = axes(f); scatter(ax, evaluated.translationErrorMm, evaluated.rotationErrorDeg, 25, evaluated.surfaceRmseMm, 'filled');
colorbar(ax); xlabel(ax, 'Translation error (mm)'); ylabel(ax, 'Rotation error (deg)'); title(ax, 'Final pose error per run'); stamp(ax);
exportgraphics(f, fullfile(outFolder, 'translationRotationErrors.png'), 'Resolution', 110); close(f);

f = figure('Visible', 'off', 'Position', [0 0 1200 420]);
t = tiledlayout(f, 1, 3);
for w = 1:3
    ax = nexttile(t);
    weightValue = [0.25 0.5 0.75]; kappaValue = [10 50 200];
    m = NaN(3);
    for i = 1:3, for j = 1:3
        sel = perCombinationTable.intensitySmoothingSigmaMm == i & perCombinationTable.kappa == kappaValue(j) & perCombinationTable.weight == weightValue(w);
        m(i, j) = perCombinationTable.medianSurfaceRmseMm(sel);
    end, end
    imagesc(ax, m); clim(ax, [min(perCombinationTable.medianSurfaceRmseMm) startRmse]); colorbar(ax);
    xticks(ax, 1:3); xticklabels(ax, {'10', '50', '200'}); yticks(ax, 1:3); xlabel(ax, 'kappa'); ylabel(ax, 'intensitySmoothingSigmaMm');
    title(ax, sprintf('weight = %.2f', weightValue(w))); stamp(ax);
end
title(t, 'Median surface RMSE (mm) per combination');
exportgraphics(f, fullfile(outFolder, 'hyperparameterHeatmaps.png'), 'Resolution', 110); close(f);

f = figure('Visible', 'off', 'Position', [0 0 900 500]);
ax = axes(f); scatter(ax, evaluated.bestCost, evaluated.surfaceRmseMm, 25, 'filled');
xlabel(ax, 'Final cost'); ylabel(ax, 'Surface RMSE (mm)'); title(ax, 'Optimizer cost vs surface RMSE'); stamp(ax);
exportgraphics(f, fullfile(outFolder, 'optimizerCostVsSurfaceRmse.png'), 'Resolution', 110); close(f);

fprintf('cost decreased %.3f, moved %.3f, best median %.2f, success %.3f\n', mean(costDecreased), mean(moved), perCombinationTable.medianSurfaceRmseMm(1), mean(evaluated.surfaceRmseMm <= 1));
