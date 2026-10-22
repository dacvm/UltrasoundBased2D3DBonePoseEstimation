# Running the project

## Requirements

- MATLAB R2024b with support for `triangulation`, tables, JSON decoding, and the functions used by the preparation tools.
- Prepared input MAT files from the workflows under `tools/`.

Select these MATLAB toolboxes when installing MATLAB:

| Toolbox | Needed for | Used by |
|---|---|---|
| Statistics and Machine Learning Toolbox | Required. `knnsearch` in the ICP-like cost function. | `main_bonePoseOptimization_*.m`, `cost_ICPLike.m` |
| Parallel Computing Toolbox | Optional but recommended. Parallel CMA-ES candidate evaluation (`parfor`). Without it, a configuration requesting `useParfor` falls back to serial CMA-ES with a warning, which is much slower. | `runBonePoseOptimization.m`, `functions/external/CMAES/cmaes_parfor.m` |
| Image Processing Toolbox | Bone segmentation and surface extraction (`strel`, `imfill`, `imgaussfilt`, `bwperim`, `bwconncomp`, ...). | `tools/boneSegmentationProcess/`, `createBoneSurfaceReviewGUI.m` |
| Optimization Toolbox | `quadprog` and `optimoptions` for regularizing bone surface segments. | `tools/boneSegmentationProcess/` |
| Computer Vision Toolbox | `pointCloud`, `pcregistericp`, `rigidtform3d`, `pcfitsphere`. | `tools/bonePreRegistration/`, `tools/ctkneePostProcess/` |
| Robotics System Toolbox | `quat2rotm`, `quaternion`, `meanrot` for Qualisys tracking data and pose averaging. Navigation, UAV or Aerospace Toolbox also provide these functions, so one of them is enough. | `functions/qualisys_related/`, `tools/ultrasoundSpatialProcessing/` |

Running only the `main_bonePoseOptimization_*.m` scripts needs just the first two toolboxes. The remaining four are for the preprocessing tools under `tools/`. No other toolboxes are needed.

The external CMA-ES implementation used by this project is already stored under `functions/external/`. Do not modify files in that directory when changing project-specific optimization behavior.

## Configure the input paths and settings

The files in `config/` are **templates**. They are tracked by git and hold a complete, working set of settings for each cost model. The main scripts do not read them directly. Each script reads a **local copy** whose name ends in `.local.json`. Git ignores local copies, so you can edit them freely without changing tracked files.

**First-time setup.** Copy one template to each script's local file. A script stops with a "Local config not found" error until you do this.

```matlab
copyfile('config/optconfig_oneSweep_PIMLOP.json',               'config/oneSweep.local.json')
copyfile('config/optconfig_hyperparamSweep_intensityLine.json', 'config/hyperparamSweep.local.json')
```

| Script | Reads |
|---|---|
| `main_bonePoseOptimization_oneSweep.m` | `config/oneSweep.local.json` |
| `main_bonePoseOptimization_hyperparamSweep.m` | `config/hyperparamSweep.local.json` |

**Switching cost model.** Copy a different template over the local file. You never need to edit the script. Available templates:

- `config/optconfig_oneSweep_intensityLine.json`: smoothed-intensity interactive run.
- `config/optconfig_oneSweep_ICPLike.json`: ICP-like point-cloud interactive run.
- `config/optconfig_oneSweep_intensityICP.json`: combined intensity and 3D-distance interactive run.
- `config/optconfig_oneSweep_PIMLOP.json`: P-IMLOP interactive run.
- `config/optconfig_oneSweep_intensityPIMLOP.json`: combined intensity and P-IMLOP interactive run.
- `config/optconfig_hyperparamSweep_intensityLine.json`: unattended smoothed-intensity sweep over `intensitySmoothingSigmaMm`.
- `config/optconfig_hyperparamSweep_intensityICP.json`: unattended combined sweep over `intensitySmoothingSigmaMm` and `weight`.
- `config/optconfig_hyperparamSweep_PIMLOP.json`: unattended P-IMLOP sweep over `kappa`.
- `config/optconfig_hyperparamSweep_intensityPIMLOP.json`: unattended combined sweep over `kappa` and `weight`.

**When to change a template.** Edit and commit a template only when its content should change for everyone, for example when a cost model gains a new parameter or when better default values are found. Day-to-day changes such as other input files or a quick parameter try belong in your local copy. Every experiment saves the configuration it used as `experiment_config_snapshot.json` (see [Output structure](output-structure.md)), so git does not need to record each run's settings.

The tests read the templates, not your local copies, so local edits never change test results.

Files under `config/legacy/` are retired configurations kept for reference only. The current code does not support them.

Set `project.root` relative to the configuration directory or provide an absolute path. Local copies sit next to the templates, so relative paths work the same in both. The supplied configuration files use `".."`, which resolves to this repository root. Input paths are then resolved relative to that project root.

## Start MATLAB in the repository root

Both main scripts build the configuration path from `pwd`. Change MATLAB's current folder to the repository root (the folder containing `README.md`) before running either script:

```matlab
cd('D:/path/to/bmodeimage_3dspace')
```

## Run one sweep first

```matlab
main_bonePoseOptimization_oneSweep
```

The one-sweep workflow requires exactly one hyperparameter combination and one seed. It displays the initial setup and intersections, runs CMA-ES, leaves the numeric result in the MATLAB workspace, and displays the optimized estimate alongside the separately stored validation data.

Use this workflow to confirm that:

- The intended bone and input files are selected.
- Ultrasound planes and the coarse CT mesh share the correct reference frame.
- Probe-facing intersection pixels appear in plausible image locations.
- The initial and optimized costs are finite.
- Search bounds, population size, evaluation budget, and parallel settings are practical.

## Run the hyperparameter sweep

```matlab
main_bonePoseOptimization_hyperparamSweep
```

The sweep creates a new timestamped experiment on every invocation, unless `experiment.resumeFolder` is set (see below). Before starting, MATLAB prints the number of combinations, seeds, planned runs, and maximum planned CMA-ES function evaluations. During execution, each completed or failed run is written to disk and the summary files are refreshed.

### Resuming a stopped sweep

If a sweep stops before it finishes (crash, Windows restart, Ctrl+C), it can be continued in the same experiment folder instead of starting over:

1. Leave every setting in the local JSON exactly as it was when the sweep started.
2. Set `experiment.resumeFolder` to the experiment folder, for example `"output/bonePoseOptimization/experiments/<name>_<timestamp>"`. Relative paths are resolved from the project root.
3. Run `main_bonePoseOptimization_hyperparamSweep` again.

The runner then takes the experiment specification and plan from `experiment_plan.mat` in that folder, not from the JSON. Runs with a `runResult.mat` that loads are skipped; runs whose file is missing or corrupt, and runs marked `save_failed` or stopped by a `MATLAB:save:*` error (also in older sweeps that stored them as `failed`), are run again. Other `failed` runs are kept, because their errors usually come from the settings. If the JSON differs from the folder's `experiment_config_snapshot.json` (ignoring `resumeFolder` itself), the script stops and names the changed fields, so edited settings are never silently ignored. Set `resumeFolder` back to `""` before starting a new experiment.
