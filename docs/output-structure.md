# Output structure

## One-sweep output

The one-sweep workflow stores raw CMA-ES files below the configured output folder. Its main `optimizationResult`, initial details, prepared data, and validation data remain in the MATLAB workspace unless the user saves them separately.

```text
output/bonePoseOptimization/oneSweeps/
+-- run_yyyyMMdd_HHmmss/
    +-- variablescmaes.mat
    +-- outcmaes*.dat
    +-- functions/optimizers/CMAES/OptData/
        +-- OptSaver.mat
```

`variablescmaes.mat` and the `outcmaes*.dat` files contain the raw optimizer state, history, and diagnostics produced by the bundled CMA-ES implementation. `OptSaver.mat` is the progress file expected by that implementation.

## Hyperparameter-sweep output

Every sweep creates a separate experiment folder. Its name combines `experiment.name` with a timestamp:

```text
output/bonePoseOptimization/experiments/
+-- <experiment-name>_yyyyMMdd_HHmmss_SSS/
    +-- experiment_config_snapshot.json
    +-- experiment_plan.mat
    +-- experiment_log.txt
    +-- validation_context.mat
    +-- summary.csv
    +-- summary.mat
    +-- runs/
        +-- combination_0001/
        |   +-- seed_1001/
        |   |   +-- runResult.mat
        |   |   +-- cmaes/
        |   |       +-- run_yyyyMMdd_HHmmss/
        |   |           +-- variablescmaes.mat
        |   |           +-- outcmaes*.dat
        |   |           +-- functions/optimizers/CMAES/OptData/
        |   |               +-- OptSaver.mat
        |   +-- seed_1002/
        |       +-- ...
        +-- combination_0002/
            +-- ...
```

`validation_context.mat` is written after the first successful input preparation. It may be absent if every combination fails before validation data can be saved.

## Experiment-level files

| File | Contents |
| --- | --- |
| `experiment_config_snapshot.json` | Copy of the original JSON used to start the experiment. |
| `experiment_plan.mat` | Resolved experiment specification, complete combination and run tables, and MATLAB/parallel-environment metadata. |
| `experiment_log.txt` | Copy of everything MATLAB printed during the sweep (progress, CMA-ES output, save retries, and the full error report if the sweep stopped). |
| `validation_context.mat` | Ground-truth validation packet plus the shared initial CT-to-reference and bone-to-reference transforms. |
| `summary.csv` | Flat, analysis-friendly row for every planned combination-seed run. |
| `summary.mat` | MATLAB version of the same summary table with MATLAB data types preserved. |

The summary begins with every run marked `pending`. After each attempt, its row is updated with identifiers, cost-model name, scalar hyperparameters, seed, status, timestamps, runtime, initial and best costs, function-evaluation count, CMA-ES stop reason, result path, and any error information.

A run's status is `completed`, `failed` (an error was thrown during preparation or optimization), or `save_failed`. `save_failed` means the run itself finished but its `runResult.mat` could not be written, even after retrying (for example because antivirus or a sync client locked the file). Its costs remain in the summary, `errorStage` is `save`, `errorIdentifier` holds the identifier of the last save error, and the sweep continues with the next run. A run is also `save_failed` when the optimizer itself stopped on a MATLAB save error (`MATLAB:save:*`, for example CMA-ES failing to write `variablescmaes.mat` on a full or locked disk); its `errorStage` is then `optimization`, its costs are `NaN`, and `errorIdentifier` keeps the save error.

## Evaluation tables

`main_bonePoseOptimization_evaluation.m` loads the schema-version-4 experiment
plan together with the summary and validation context. The saved
`experimentPlan.parameterNames` list defines which summary columns are swept
parameters and keeps them in the order chosen by the cost-model validator.

The evaluation output contains one CSV row per run and one ranked CSV row per
parameter combination. Both tables retain the cost-model name and all declared
parameter columns. The MAT output also stores the schema version, cost model,
and parameter-name list in `evaluationMetadata`.

The active evaluator requires a schema-version-4 experiment plan containing
`parameterNames`. Older experiment plans that do not contain this metadata are
not inferred automatically and should be inspected with the code version that
created them.

The evaluator's `heatmapSettings` block controls one paneled heatmap figure.
`xParameter` and `yParameter` form the cells inside each heatmap, while
`panelRowParameter` and `panelColumnParameter` arrange the remaining parameter
values as rows and columns of small heatmaps. A parameter can instead be given
one value in `parametersToHold` when the figure should show only that slice.
Every swept parameter must have exactly one of these roles, which prevents a
new cost-model parameter from being hidden accidentally. To inspect a second
arrangement, copy the settings block under a new name and call
`plotHyperparameterPaneledHeatmaps` again.

## Per-run `runResult.mat`

Each seed folder contains one `runResult.mat`, including failed runs. Its top-level structure is:

```text
runResult
+-- run
|   +-- runNumber, runId
|   +-- combinationNumber, combinationId
|   +-- seed, status
|   +-- startTime, endTime, runtimeSeconds
|   +-- resultFilePath
+-- configuration
+-- initial
|   +-- poseVector
|   +-- cost
+-- optimizationResult
+-- final
|   +-- cost
|   +-- costDetails
+-- validationReference
+-- error
    +-- stage
    +-- identifier
    +-- message
    +-- stack
```

For a completed run, `optimizationResult` contains the initial and best pose vectors, initial and best rigid transforms, search bounds, sigma, raw CMA-ES outputs, seed, and optimizer output paths. `final.costDetails` contains the final candidate mesh, per-plane intersection geometry, and the diagnostics of the selected cost model, for example the per-plane evidence and sample points of the intensity cost, or the separated cost terms of a combined model.

For a failed run, the same overall shape is retained where practical, while unavailable numeric values are stored as `NaN` or empty structs. The `error` group records whether the failure occurred during preparation or optimization and preserves the MATLAB exception information.
