# Required input data

Raw B-mode ultrasound and motion-capture data can be recorded with the acquisition software in [BmodeMocapIntegration](https://github.com/dacvm/BmodeMocapIntegration). Before running the optimizer, follow the instructions in [`tools/README.md`](../tools/README.md) and the README inside each relevant tool directory. The preparation tools are generally used in this order:

1. [`tools/ctkneePostProcess/`](../tools/ctkneePostProcess/README.md) prepares the CT bone meshes, anatomical frames, and bone-pin geometry.
2. [`tools/ultrasoundSpatialProcessing/`](../tools/ultrasoundSpatialProcessing/README.md) combines ultrasound snapshots, PLUS calibration, Qualisys tracking, and CT data; it also supports review and export of accepted snapshots.
3. [`tools/boneSegmentationProcess/`](../tools/boneSegmentationProcess/README.md) extracts candidate bone-surface responses from the selected ultrasound images.
4. [`tools/bonePreRegistration/`](../tools/bonePreRegistration/README.md) estimates the coarse CT-to-reference pose used as the center of the optimization search.

The optimization configuration points to three required MAT files and one optional bone-surface file:

| Configuration field | High-level purpose |
| --- | --- |
| `validSnapshotsMatFile` | MAT file exported by the ultrasound spatial-processing review. It contains accepted, tracked B-mode image planes and separate ground-truth bone poses and intersections. The optimizer uses the image planes but does not use the ground-truth intersections in its cost. |
| `boneSurfaceMatFile` | Optional MAT file produced by bone-surface extraction and 3D recovery. Input preparation aligns its 2D and 3D measurements with the selected ultrasound snapshots. A cost model only requires this file when its definition sets `requiresBoneSurface` to `true`. |
| `ctPostProcessedMatFile` | MAT file produced by CT knee post-processing. It contains the CT bone meshes, anatomical coordinate systems, and the rigid relationship between each bone and its selected pin. |
| `coarseRegistrationMatFile` | MAT file produced by bone pre-registration. It contains the approximate CT-to-reference transform that initializes the optimizer and the matching coarse bone mesh in the reference frame. |

The prepared files must describe the same specimen, bone, pin selection, marker geometry, units, and coordinate-frame conventions. The `input.bone` setting selects the target bone code, such as `F` for femur or `T` for tibia.

## 1. Optimization code organization

The three stable workflow entry points remain directly under
`functions/bonePoseOptimization/`: cost evaluation, one optimization run, and
one experiment run. Supporting functions are grouped one level below:

- `configuration/` reads JSON and builds experiment and scalar run settings.
- `costModels/` contains model registration, cost functions, and validators. Its `legacy/` subfolder keeps retired models for reference only; active code does not use them.
- `inputPreparation/` loads and prepares reusable optimization inputs.
- `poseEvaluation/` converts optimizer states and evaluates candidate-pose geometry.
- `evaluationMetric/` and `evaluationPlot/` analyze saved results.
- `tests/` test codes that verifies the active pipeline.

## 2. Optimizer parameters

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

The `experiment.seeds` array controls repeated stochastic runs. A one-sweep configuration must contain exactly one parameter combination and one seed. The sweep configuration can contain several values and seeds.
