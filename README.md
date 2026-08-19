# Optimization-Based Bone Registration with B-Mode Ultrasound

## Short summary

This MATLAB project supports the development of optimization-based bone registration using tracked B-mode ultrasound images. Its purpose is to explore how much information conventional B-mode ultrasound can provide for estimating the three-dimensional pose of a bone when a CT-derived bone mesh and an approximate initial registration are available.

For each candidate bone pose, the pipeline places the CT mesh in the experiment reference frame, intersects the mesh with the tracked ultrasound image planes, and keeps intersection segments whose mesh surfaces face the probe. The cost function then evaluates the brightness and coverage of the corresponding ultrasound pixels. A bounded CMA-ES optimizer searches for a six-degree-of-freedom correction to the coarse bone pose.

The project currently provides two entry points:

- `main_bonePoseOptimization_sanityCheck.m` runs one interactive configuration and displays the initial and optimized geometry. Use this first when checking a new dataset or cost-function change.
- `main_bonePoseOptimization_hyperparamSweep.m` runs every configured cost-parameter combination for every configured random seed and saves an analysis-ready experiment summary.

This repository is research and development code. The cost function, optimization settings, and validation strategy are expected to evolve while the capabilities and limitations of B-mode ultrasound for bone registration are investigated.

## Experiment setup

The workflow was developed for a knee phantom, but the same general arrangement can be used with a cadaver leg. The physical setup must connect the CT anatomy, tracked bone pins, ultrasound probe, and motion-capture reference frame without changing their geometry between calibration, CT imaging, and ultrasound acquisition.

### 1. Equip the specimen with tracked bone pins

Attach a bone pin to each bone that will be registered, such as the femur or tibia. Each pin carries an optical-marker rigid body so the bone pose can be measured by the motion-capture system. The pin must remain rigidly attached to the bone throughout CT scanning and ultrasound acquisition.

Also provide a fixed reference rigid body in the experimental workspace. This reference defines the common coordinate frame in which the tracked ultrasound images, bone-pin measurements, CT meshes, coarse estimates, and final optimization results are compared.

### 2. Acquire the CT scan before the ultrasound experiment

CT-scan the knee phantom or cadaver leg together with the attached bone pins and their optical-marker geometry. The CT scan must contain enough information to reconstruct:

- The surface mesh of each bone.
- The anatomical coordinate system of each bone.
- The CT-side coordinate system of each bone pin.
- The optical-marker geometry needed to relate the physical tracked pin to the corresponding CT geometry.

Keeping the pin and marker assembly unchanged is essential. Reattaching or moving a pin after the CT scan breaks the rigid relationship used to obtain the ground-truth bone pose.

### 3. Process the CT anatomy and tracking geometry

Segment or prepare the bone meshes, define their anatomical coordinate systems, and identify the pin-marker geometry in the CT data. The tools in [`tools/`](tools/README.md) describe the expected processing order and output structures.

The processed CT result connects the CT mesh to the tracked bone pin. During the ultrasound experiment, this relationship allows the measured pin pose to place the complete CT bone mesh in the common reference frame.

### 4. Place the specimen in the motion-capture workspace

Place the instrumented knee under the working volume of an optical motion-capture system. This project is being developed with a Qualisys system. Confirm that the reference object, bone-pin rigid bodies, and probe rigid body are simultaneously visible and use consistent rigid-body names.

Before collecting ultrasound data, check the marker definitions, axis directions, units, and coordinate-system handedness. These definitions must agree with those used during CT processing. A mismatch can create a plausible-looking but incorrect bone registration.

### 5. Track and calibrate the ultrasound probe

Attach an optical-marker rigid body to the B-mode ultrasound probe. Calibrate the relationship between the image and probe coordinate systems beforehand. This workflow uses the [PLUS Toolkit](https://plustoolkit.github.io/) and expects an fCal/PLUS calibration containing the `ImageToProbe` transform.

The calibration connects an ultrasound pixel to a physical location relative to the tracked probe. Together with the measured probe and reference poses, it allows each B-mode image to be represented as a finite plane in the common three-dimensional reference frame.

### 6. Acquire tracked B-mode ultrasound snapshots

Move the tracked probe over the bone surface and record B-mode ultrasound snapshots. Save the ultrasound image data together with the corresponding probe, reference, and bone-pin tracking measurements. The acquisition software used for this work is maintained in the separate [BmodeMocapIntegration repository](https://github.com/dacvm/BmodeMocapIntegration).

Each accepted snapshot ultimately provides:

- A B-mode image.
- A calibrated image plane in three-dimensional reference coordinates.
- A timestamp and source record that connect the image to its tracking data.

### 7. Build the estimation and ground-truth data

The tracked and calibrated probe provides the estimated position of each ultrasound image in 3D space. The CT mesh and the optically tracked bone pin provide an independent ground-truth bone pose. These two information paths serve different purposes:

- The optimizer receives the CT mesh, tracked ultrasound planes, image intensities, and a coarse initial pose.
- The ground-truth bone pose and ground-truth intersections are kept separate and are used only for validation after estimation.

This separation prevents the optimization cost from using the answer that it is intended to estimate.

## Required input data

Raw B-mode ultrasound and motion-capture data can be recorded with the acquisition software in [BmodeMocapIntegration](https://github.com/dacvm/BmodeMocapIntegration). Before running the optimizer, follow the instructions in [`tools/README.md`](tools/README.md) and the README inside each relevant tool directory. The preparation tools are generally used in this order:

1. [`tools/ctkneePostProcess/`](tools/ctkneePostProcess/README.md) prepares the CT bone meshes, anatomical frames, and bone-pin geometry.
2. [`tools/ultrasoundSpatialProcessing/`](tools/ultrasoundSpatialProcessing/README.md) combines ultrasound snapshots, PLUS calibration, Qualisys tracking, and CT data; it also supports review and export of accepted snapshots.
3. [`tools/boneSegmentationProcess/`](tools/boneSegmentationProcess/README.md) extracts candidate bone-surface responses from the selected ultrasound images.
4. [`tools/bonePreRegistration/`](tools/bonePreRegistration/README.md) estimates the coarse CT-to-reference pose used as the center of the optimization search.

The optimization configuration points to three prepared MAT files:

| Configuration field | High-level purpose |
| --- | --- |
| `validSnapshotsMatFile` | MAT file exported by the ultrasound spatial-processing review. It contains accepted, tracked B-mode image planes and separate ground-truth bone poses and intersections. The optimizer uses the image planes but does not use the ground-truth intersections in its cost. |
| `ctPostProcessedMatFile` | MAT file produced by CT knee post-processing. It contains the CT bone meshes, anatomical coordinate systems, and the rigid relationship between each bone and its selected pin. |
| `coarseRegistrationMatFile` | MAT file produced by bone pre-registration. It contains the approximate CT-to-reference transform that initializes the optimizer and the matching coarse bone mesh in the reference frame. |

All three files must describe the same specimen, bone, pin selection, marker geometry, units, and coordinate-frame conventions. The `input.bone` setting selects the target bone code, such as `F` for femur or `T` for tibia.

### Optimization code organization

The three stable workflow entry points remain directly under
`functions/bonePoseOptimization/`: cost evaluation, one optimization run, and
one experiment run. Supporting functions are grouped one level below:

- `configuration/` reads JSON and builds experiment and scalar run settings.
- `costModels/` contains model registration, versioned cost functions, and validators.
- `inputPreparation/` loads and prepares reusable optimization inputs.
- `poseEvaluation/` converts optimizer states and evaluates candidate-pose geometry.
- `evaluationMetric/` and `evaluationPlot/` analyze saved results.
- `tests/` verifies the active pipeline, while `legacy/` stores inactive historical code.

### Cost-function parameters

The cost function rewards bright, well-covered probe-facing mesh intersections and penalizes active ultrasound planes that have too few current intersection pixels.

The two active JSON files use `schemaVersion: 4`. Each experiment selects one
cost model explicitly and separates fixed settings from values that participate
in the hyperparameter sweep.

| Setting | Meaning |
| --- | --- |
| `intersection.normalFacingToleranceDeg` | Maximum angular difference used when deciding whether an intersected mesh face points toward the ultrasound probe. In a sweep configuration this may contain several candidate values. |
| `cost.model` | Versioned cost-model name. The current model is `intensityCoverage_v1`. |
| `cost.fixedParameters.intensityMax` | Intensity used to normalize sampled ultrasound brightness, for example `255` for an 8-bit image. This remains fixed during the complete experiment. |
| `cost.hyperparameters.minReferencePixels` | Minimum number of probe-facing pixels at the coarse initial pose for an image plane to participate in the final cost average. |
| `cost.hyperparameters.nMinPixels` | Minimum number of probe-facing pixels required at the current candidate pose before an active plane is marked as missing. |
| `cost.hyperparameters.lambdaMissing` | Weight applied to the fraction of active planes marked as missing. A larger value discourages candidate poses that explain only a small subset of the images. |

The minimized scalar objective has the high-level form:

```text
cost = negative mean intensity-and-coverage score
       + lambdaMissing * mean missing-plane penalty
```

`normalFacingToleranceDeg` and the fields under `cost.hyperparameters` may be
arrays in the sweep configuration. The experiment specification retains these
candidate arrays. Before preparation or optimization, the selected values are
merged with the fixed settings under `runConfig.cost.parameters`, where every
value is scalar.

`bonePoseCostFunction` is the stable function called by scripts and CMA-ES.
It resolves `cost.model` through `getBonePoseCostDefinition` and forwards the
evaluation to the approved versioned implementation. The current
`bonePoseCostIntensityCoverageV1` function owns the original calculation and
its local helpers. New models can therefore be registered without changing
scripts or optimizer code.

Each model-specific validator checks its fixed and swept settings, then returns
those parameter groups in a documented field order. The planner reads these
validated fields to create sweep columns, and the runtime-config builder merges
the selected scalar values without model-specific edits. To add a model, create
its evaluator and validator, add one registry case, and update the active JSON.
Combination-level evaluation reads the validator-ordered parameter names from
the saved experiment plan. This lets new numeric cost hyperparameters flow into
the evaluation tables without adding model-specific table columns. Heatmap
choices remain explicit until their later refactoring stage.

### Optimizer parameters

The optimizer represents a candidate as a local six-value perturbation `[vx; vy; vz; wx; wy; wz]` around the coarse CT-to-reference transform. Translation is expressed in the mesh length unit, normally millimetres, and rotation is configured in degrees before conversion to radians.

| Setting | Meaning |
| --- | --- |
| `translationBoundMm` | Symmetric translation limit for each of the three translation components. |
| `rotationBoundDeg` | Symmetric rotation-vector limit for each of the three rotation components. |
| `translationSigmaMm` | Initial CMA-ES search spread for the translation components. |
| `rotationSigmaDeg` | Initial CMA-ES search spread for the rotation components. |
| `populationSize` | Number of CMA-ES candidate solutions evaluated in a population. |
| `maxFunctionEvaluations` | Function-evaluation budget for each optimization run. |
| `useParfor` | Requests parallel candidate evaluation when the Parallel Computing Toolbox and a valid license are available. |
| `parforWorkers` | Worker limit passed to the bundled parallel CMA-ES implementation. |

The `experiment.seeds` array controls repeated stochastic runs. The sanity-check configuration must contain exactly one parameter combination and one seed. The sweep configuration can contain several values and seeds.

## Processing workflow

1. **Read and validate the experiment configuration.** The selected JSON file defines the target bone, prepared input files, intersection and cost settings, CMA-ES settings, repeat seeds, and output location. Relative input and output paths are resolved against the configured project root.

2. **Create the experiment plan.** For a hyperparameter sweep, the runner builds the Cartesian product of all candidate cost settings and repeats every combination for every configured seed.

3. **Prepare one parameter combination.** The pipeline loads the accepted ultrasound snapshots, CT mesh, and coarse registration; matches them by bone code; validates the image planes and rigid transforms; and calculates the initial probe-facing intersection-pixel counts. Prepared estimation data is reused for every seed belonging to that combination.

4. **Evaluate a candidate pose.** A six-value optimizer state is converted to a rigid CT-to-reference transform. The CT mesh is moved into the reference frame and intersected with every finite ultrasound image plane. Only segments produced by probe-facing mesh faces are retained and rasterized to image pixels.

5. **Calculate the objective value.** Ultrasound intensities are sampled at the selected pixels. Each active plane receives a normalized brightness-and-coverage score, while planes with too few current pixels receive a missing-intersection penalty. Lower total cost is better.

6. **Optimize the bone pose.** Bounded CMA-ES repeatedly proposes candidate perturbations and calls the cost function. The best candidate found during the run is converted into final CT-to-reference and bone-to-reference transforms.

7. **Validate and save the results.** Successful sweep runs re-evaluate the best pose to save detailed per-plane geometry and cost terms. Ground truth remains separate for later comparison. Every attempted run and the experiment summary are saved immediately so completed work remains available if a later run fails.

## Running the project

### Requirements

- MATLAB with support for `triangulation`, tables, JSON decoding, and the functions used by the preparation tools.
- Parallel Computing Toolbox is optional. When it is unavailable, a configuration requesting `useParfor` falls back to serial CMA-ES with a warning.
- Prepared input MAT files from the workflows under `tools/`.

The external CMA-ES implementation used by this project is already stored under `functions/external/`. Do not modify files in that directory when changing project-specific optimization behavior.

### 1. Configure the input paths and settings

Edit one of the following files:

- `config/bonePoseOptimizationSanityCheckConfig.json` for one interactive test run.
- `config/bonePoseOptimizationHyperparamSweepConfig.json` for an unattended multi-parameter, multi-seed experiment.

The file under `config/legacy/` records the former schemaVersion02 layout for historical
reference only. Active readers do not execute schema-less legacy configs.

Set `project.root` relative to the configuration directory or provide an absolute path. The supplied configuration files use `".."`, which resolves to this repository root. Input paths are then resolved relative to that project root.

### 2. Start MATLAB in the repository root

Both main scripts build the configuration path from `pwd`. Change MATLAB's current folder to the directory containing this README before running either script:

```matlab
cd('D:/path/to/bmodeimage_3dspace')
```

### 3. Run the sanity check first

```matlab
main_bonePoseOptimization_sanityCheck
```

The sanity check requires exactly one hyperparameter combination and one seed. It displays the initial setup and intersections, runs CMA-ES, leaves the numeric result in the MATLAB workspace, and displays the optimized estimate alongside the separately stored validation data.

Use this workflow to confirm that:

- The intended bone and input files are selected.
- Ultrasound planes and the coarse CT mesh share the correct reference frame.
- Probe-facing intersection pixels appear in plausible image locations.
- The initial and optimized costs are finite.
- Search bounds, population size, evaluation budget, and parallel settings are practical.

### 4. Run the hyperparameter sweep

```matlab
main_bonePoseOptimization_hyperparamSweep
```

The sweep creates a new timestamped experiment on every invocation. It does not resume an older experiment. Before starting, MATLAB prints the number of combinations, seeds, planned runs, and maximum planned CMA-ES function evaluations. During execution, each completed or failed run is written to disk and the summary files are refreshed.

## Output structure

### Sanity-check output

The sanity check stores raw CMA-ES files below the configured output folder. Its main `optimizationResult`, initial details, prepared data, and validation data remain in the MATLAB workspace unless the user saves them separately.

```text
output/bonePoseOptimization/sanityChecks/
+-- run_yyyyMMdd_HHmmss/
    +-- variablescmaes.mat
    +-- outcmaes*.dat
    +-- functions/optimizers/CMAES/OptData/
        +-- OptSaver.mat
```

`variablescmaes.mat` and the `outcmaes*.dat` files contain the raw optimizer state, history, and diagnostics produced by the bundled CMA-ES implementation. `OptSaver.mat` is the progress file expected by that implementation.

### Hyperparameter-sweep output

Every sweep creates a separate experiment folder. Its name combines `experiment.name` with a timestamp:

```text
output/bonePoseOptimization/experiments/
+-- <experiment-name>_yyyyMMdd_HHmmss_SSS/
    +-- experiment_config_snapshot.json
    +-- experiment_plan.mat
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

### Experiment-level files

| File | Contents |
| --- | --- |
| `experiment_config_snapshot.json` | Copy of the original JSON used to start the experiment. |
| `experiment_plan.mat` | Resolved experiment specification, complete combination and run tables, and MATLAB/parallel-environment metadata. |
| `validation_context.mat` | Ground-truth validation packet plus the shared initial CT-to-reference and bone-to-reference transforms. |
| `summary.csv` | Flat, analysis-friendly row for every planned combination-seed run. |
| `summary.mat` | MATLAB version of the same summary table with MATLAB data types preserved. |

The summary begins with every run marked `pending`. After each attempt, its row is updated with identifiers, cost-model name, scalar hyperparameters, seed, status, timestamps, runtime, initial and best costs, function-evaluation count, CMA-ES stop reason, result path, and any error information.

### Evaluation tables

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

### Per-run `runResult.mat`

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

For a completed run, `optimizationResult` contains the initial and best pose vectors, initial and best rigid transforms, search bounds, sigma, raw CMA-ES outputs, seed, and optimizer output paths. `final.costDetails` contains the final candidate mesh, per-plane intersection geometry, sampled-pixel counts, brightness and coverage values, missing-plane flags, and separated cost terms.

For a failed run, the same overall shape is retained where practical, while unavailable numeric values are stored as `NaN` or empty structs. The `error` group records whether the failure occurred during preparation or optimization and preserves the MATLAB exception information.
