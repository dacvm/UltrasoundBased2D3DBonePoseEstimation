# Output structure

This page explains what lands on disk after a run and where to find what you need. The hyperparameter sweep (`main_bonePoseOptimization_hyperparamSweep.m`) writes almost everything. The evaluation script adds its tables to the same folder, and the one-sweep script saves only raw optimizer files.

One idea is enough to find your way around:

> One sweep writes one experiment folder. Inside it there is one folder per combination of settings, inside that one folder per seed, and every seed folder holds one `runResult.mat`.

A few words used on this page:

- **Experiment**: one call of the sweep script, with all its results in one folder.
- **Combination**: one set of parameter values, for example one smoothing sigma with one tolerance.
- **Seed**: one repetition of a combination with a different random start for CMA-ES.
- **Run**: one combination with one seed. It is the smallest unit: one CMA-ES search, one `runResult.mat`, one row in the summary.

**Start with `summary.csv`.** It has one row per run with its status and costs, and points to that run's `runResult.mat`.

## 1. The experiment folder at a glance

```text
output/bonePoseOptimization/experiments/
└── <experiment-name>_yyyyMMdd_HHmmss_SSS/       one sweep
    ├── summary.csv                               one row per run: start here
    ├── summary.mat                               the same table, MATLAB types kept
    ├── experiment_config_snapshot.json           the settings you used
    ├── experiment_plan.mat                       every planned combination and run
    ├── experiment_log.txt                        everything MATLAB printed
    ├── validation_context.mat                    ground truth, shared by all runs
    ├── evaluation/                               only after running the evaluation
    │   ├── per_run_evaluation.csv
    │   ├── per_combination_evaluation.csv
    │   └── evaluation_tables.mat
    └── runs/
        ├── combination_0001/                     one set of parameter values
        │   ├── seed_1001/                        one run
        │   │   ├── runResult.mat                 everything about this run
        │   │   └── cmaes/                        raw CMA-ES files
        │   │       └── run_yyyyMMdd_HHmmss/
        │   │           ├── variablescmaes.mat
        │   │           ├── outcmaes*.dat
        │   │           └── functions/optimizers/CMAES/OptData/
        │   │               └── OptSaver.mat
        │   └── seed_1002/
        │       └── ...
        └── combination_0002/
            └── ...
```

The folder name is `experiment.name` from the JSON plus a timestamp, so a new sweep never overwrites an old one.

## 2. Which file answers which question

| I want to know… | Look in |
| --- | --- |
| Which runs worked, and their costs | `summary.csv` |
| Which settings produced these results | `experiment_config_snapshot.json` |
| Which combination is the most accurate | `evaluation/per_combination_evaluation.csv` |
| The best pose found by one run | `runResult.mat` → `optimizationResult.result.T_bone_ref_best` |
| Why a run failed | `errorMessage` in `summary.csv`, then `runResult.error`, then `experiment_log.txt` |
| Why the whole sweep stopped | `experiment_log.txt` |
| How CMA-ES converged in one run | `outcmaes*.dat` in that run's `cmaes/` folder |

## 3. Experiment-level files

These files describe the experiment as a whole. They sit directly in the experiment folder.

| File | What it holds |
| --- | --- |
| `summary.csv` | One row per planned run: its identity, parameter values, status, costs, and result path. Rewritten after every run, so it also shows the progress of a running sweep. |
| `summary.mat` | The same table as `summaryTable`, with MATLAB data types kept. The evaluation script reads this one. |
| `experiment_config_snapshot.json` | A copy of the JSON that started the sweep. Your local JSON may change later; this copy does not. |
| `experiment_plan.mat` | The checked settings (`experimentSpec`), the table of every combination and run (`experimentPlan`), and the MATLAB and parallel environment (`environment`). A resumed sweep reads its plan from here. |
| `experiment_log.txt` | Everything MATLAB printed during the sweep: progress, CMA-ES output, save retries, and the full error report if the sweep stopped. |
| `validation_context.mat` | The ground-truth bone pose and mesh, plus the initial CT-to-reference and bone-to-reference transforms that every run starts from. Stored once here instead of in every run. Written after the first successful input preparation, so it is missing if every combination fails before that. |

## 4. The summary table

`summary.csv` has one row for every planned run, in plan order. When the sweep starts, every row is `pending`; after each run, its row is filled in.

| Columns | Meaning |
| --- | --- |
| `runNumber`, `runId`, `combinationNumber`, `combinationId`, `seed` | Which run this is. `combinationId` and `seed` also name its folder: `runs/<combinationId>/seed_<seed>/`. |
| `costModel` and one column per swept parameter | The settings of this run. `normalFacingToleranceDeg` comes first, then the cost model's own parameters. |
| `status` | `pending`, `completed`, `failed`, or `save_failed`. |
| `startTime`, `endTime`, `runtimeSeconds` | When the run ran and how long it took. |
| `initialCost`, `bestCost` | The cost at the starting pose and the lowest cost CMA-ES found. Lower is better. |
| `functionEvaluations`, `stopFlag` | How many times the cost was evaluated, and why CMA-ES stopped. |
| `resultFilePath` | Full path of this run's `runResult.mat`. |
| `errorStage`, `errorIdentifier`, `errorMessage` | Empty for a completed run. Otherwise, where and why it went wrong. |

The three final statuses, in short:

- `completed`: the run finished and was saved.
- `failed`: an error was thrown during preparation or optimization.
- `save_failed`: a file could not be written, during the run or when saving `runResult.mat`.

[Bookkeeping](bookkeeping.md) explains when each status is used, and which runs a resumed sweep runs again.

## 5. One run: `runResult.mat`

Each seed folder holds one `runResult.mat`, also for a failed run. It contains one struct, `runResult`, with everything needed to understand that run on its own:

```text
runResult
├── run                   who and when
│   ├── runNumber, runId
│   ├── combinationNumber, combinationId
│   ├── seed, status
│   ├── startTime, endTime, runtimeSeconds
│   └── resultFilePath
├── configuration         the full one-run config, including the seed
├── initial               the starting point
│   ├── poseVector
│   └── cost
├── optimizationResult    what CMA-ES found
│   ├── result            initial and best pose vectors, costs and transforms
│   ├── cmaes             bounds, sigma, raw CMA-ES outputs and options
│   └── run               CMA-ES output folder, seed, status
├── final                 the best pose, evaluated once more
│   ├── cost
│   └── costDetails       candidate mesh, plane intersections, cost diagnostics
├── validationReference   ground-truth transforms of the bone
└── error                 empty for a completed run
    ├── stage
    ├── identifier
    ├── message
    └── stack
```

The fields you will use most:

- `optimizationResult.result.T_bone_ref_best` and `T_CT_ref_best`: the estimated bone pose.
- `final.costDetails.boneMeshRefCandidate`: the bone mesh at that pose, in the `ref` frame. The evaluation compares it with the ground-truth mesh.
- `final.costDetails` also holds the diagnostics of the cost model, for example the per-plane evidence and sample points of the intensity cost, or the separate terms of a combined cost.

A failed run keeps the same shape where it can. Values that do not exist are `NaN` or empty structs, and `error` records the stage (`preparation` or `optimization`) and the full MATLAB exception.

## 6. Raw CMA-ES files

Each run's `cmaes/run_yyyyMMdd_HHmmss/` folder holds what the bundled CMA-ES code writes by itself. You rarely need it; `runResult.mat` already contains the important results.

- `variablescmaes.mat`: the optimizer state at the end of the search.
- `outcmaes*.dat`: the history per generation (costs, step sizes, axis lengths). Read these to see how the search converged.
- `functions/optimizers/CMAES/OptData/OptSaver.mat`: a progress file. The external CMA-ES code loads it from a fixed path relative to its current folder, so the run folder recreates that path. Its odd location is expected, not a bug.

## 7. Evaluation output

`main_bonePoseOptimization_evaluation.m` writes its tables to an `evaluation/` folder inside the experiment folder. Running it again overwrites them. How to run and configure it is in [Running the project](running.md#6-evaluate-a-finished-sweep).

| File | What it holds |
| --- | --- |
| `per_run_evaluation.csv` | The summary table plus the errors of each run against the ground truth: `translationErrorMm`, `rotationErrorDeg`, and `surfaceRmseMm`. `evaluationStatus` is `evaluated`, `skipped` (the run did not complete), or `failed`. Sorted by `surfaceRmseRank`, best run first. |
| `per_combination_evaluation.csv` | One row per combination: its parameter values, how many seeds completed and were evaluated, and the median, 25th and 75th percentile, and IQR of the cost, the three errors, and the runtime over its seeds. Sorted by `combinationRank`, which ranks the median surface RMSE. **This is the table for choosing hyperparameters.** |
| `evaluation_tables.mat` | Both tables (`perRunTable`, `perCombinationTable`) plus `evaluationMetadata`: the schema version, cost model, and parameter names needed to read the parameter columns later. |

The figures are only shown, not saved.

## 8. One-sweep output

`main_bonePoseOptimization_oneSweep.m` is for checking one setup interactively. Its results (`optimizationResult`, the initial details, the prepared data, and the validation data) stay in the MATLAB workspace. Save them yourself if you need them.

Only the raw CMA-ES files go to disk, in the folder set by `optimizer.outputFolder`, which is one folder per cost model in the templates:

```text
output/bonePoseOptimization/oneSweeps/<cost-model>/
└── run_yyyyMMdd_HHmmss/
    ├── variablescmaes.mat
    ├── outcmaes*.dat
    └── functions/optimizers/CMAES/OptData/
        └── OptSaver.mat
```

These are the same files as in [Raw CMA-ES files](#6-raw-cma-es-files).

## 9. Where to look next

- To run a sweep and evaluate it: [Running the project](running.md).
- To understand a status other than `completed`, or to resume a stopped sweep: [Bookkeeping](bookkeeping.md).
- To see which code writes these files: [Processing workflow](workflow.md).
