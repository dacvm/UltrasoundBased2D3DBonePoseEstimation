# Optimization-Based Bone Registration with B-Mode Ultrasound

This MATLAB project supports the development of optimization-based bone registration using tracked B-mode ultrasound images. Its purpose is to explore how much information conventional B-mode ultrasound can provide for estimating the three-dimensional pose of a bone when a CT-derived bone mesh and an approximate initial registration are available.

For each candidate bone pose, the pipeline places the CT mesh in the experiment reference frame, intersects the mesh with the tracked ultrasound image planes, and keeps intersection segments whose mesh surfaces face the probe. The cost function then evaluates how well those predicted bone surfaces agree with the ultrasound data, for example how bright the images are along them. A bounded CMA-ES optimizer searches for a six-degree-of-freedom correction to the coarse bone pose.

This repository is research and development code. The cost function, optimization settings, and validation strategy are expected to evolve while the capabilities and limitations of B-mode ultrasound for bone registration are investigated.

## Quick start

1. Prepare the input MAT files with the tools in [`tools/`](tools/README.md) (see [Required input data](docs/input-data.md)).
2. Copy a config template to the local config each script reads:

   ```matlab
   copyfile('config/optconfig_oneSweep_PIMLOP.json',               'config/oneSweep.local.json')
   copyfile('config/optconfig_hyperparamSweep_intensityLine.json', 'config/hyperparamSweep.local.json')
   ```

3. Start MATLAB in the repository root and run one interactive optimization first:

   ```matlab
   main_bonePoseOptimization_oneSweep
   ```

4. When that looks right, run the full hyperparameter sweep:

   ```matlab
   main_bonePoseOptimization_hyperparamSweep
   ```

See [Running the project](docs/running.md) for the required toolboxes and full details.

## Documentation

| Page | What it covers |
| --- | --- |
| [Experiment setup](docs/experiment-setup.md) | Bone pins, CT scan, motion capture, probe calibration, and ultrasound acquisition. |
| [Required input data](docs/input-data.md) | Input MAT files, preparation tools, code organization, and optimizer parameters. |
| [Supported cost functions](docs/cost-functions.md) | Every registered cost model and its parameters. |
| [Running the project](docs/running.md) | Preparation checklist, requirements, configuration, one sweep, hyperparameter sweep, resuming, evaluation. |
| [Output structure](docs/output-structure.md) | Output folders, summary and evaluation tables, `runResult.mat`. |
| [Processing workflow](docs/workflow.md) | How configuration, planning, CMA-ES, and cost dispatch fit together. |
| [Bookkeeping](docs/bookkeeping.md) | Saving results, failure cases, and resuming a stopped sweep. |
| [Adding a new cost function](docs/adding-a-cost-function.md) | Naming rules and the recipe for a new cost model. |
