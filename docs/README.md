# Documentation

These pages explain how the project works and how to use it. If you are new, read them roughly in this order.

| Page | What it covers |
| --- | --- |
| [Experiment setup](experiment-setup.md) | The physical setup: bone pins, CT scan, motion capture, probe calibration, and ultrasound acquisition. |
| [Required input data](input-data.md) | The MAT files the optimizer needs, the tools that produce them, how the optimization code is organized, and the optimizer parameters. |
| [Supported cost functions](cost-functions.md) | Every registered cost model, what it measures, and its parameters. |
| [Running the project](running.md) | Requirements, config setup, running one sweep, running and resuming a hyperparameter sweep. |
| [Output structure](output-structure.md) | Folders and files written by each run, summary tables, evaluation tables, and `runResult.mat`. |
| [Processing workflow](workflow.md) | How configuration, planning, input preparation, CMA-ES, and the cost dispatcher fit together. |
| [Adding a new cost function](adding-a-cost-function.md) | Naming rules and the step-by-step recipe for a new cost model. |

The data-preparation tools have their own documentation in [`tools/README.md`](../tools/README.md).
