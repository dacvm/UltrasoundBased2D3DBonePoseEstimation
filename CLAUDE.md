# CLAUDE.md

MATLAB project: estimate 3D bone pose by registering CT bone meshes to tracked 2D ultrasound (B-mode) images.

## Core rules
- Write everything in MATLAB, including one-off helpers in `tools/` and `devs/`. No Python.
- Never modify `functions/external/` (third-party code, used as-is).
- Never modify or delete files in `data/` (source recordings, calibrations, meshes).
- Never use `functions/bonePoseOptimization/legacy/` in active code.
- Write generated results only to `output/`; don't edit them by hand.

## Setup and verification
- MATLAB version: `R2024b`.
- Toolboxes: not pinned; the list changes over time. To see what a file needs, run `[~, p] = matlab.codetools.requiredFilesAndProducts('file.m'); {p.Name}'`.
- Prefer base MATLAB and toolboxes the code already uses. Ask before adding a dependency on a new toolbox.
- Path setup: `addpath(genpath('functions'))` from the project root.
- Run the tests:
  ```
  matlab -batch "addpath(genpath('functions')); assertSuccess(runtests('functions/bonePoseOptimization/tests'))"
  ```
- Tests depend on local files in `data/` and `config/` (not in git). If they are missing, say so instead of faking data.
- A change is done when the tests pass and any affected `main_*.m` or `examples/` script runs without error.

## Code style
- One public function per file, camelCase names, file name = function name.
- New functions MUST have a help block right below `function`: what it does, why it is needed, and every input and output. Copy the style of `functions/geometry/applyRigidTransform.m`.
- Comments are for a junior reader: comment each logical block with its intent (the *why*) in simple words. Comment a single line only when its purpose is not obvious.
- Tests are function-based (`functiontests(localfunctions)`); follow `functions/bonePoseOptimization/tests/testBonePoseCostDispatcher.m`.

## Geometry conventions
- Rigid transforms are numeric 4x4 matrices with column vectors: `p_target = T_source_target * p_source`.
- Name transforms `T_<source>_<target>` and compose right to left: `T_image_ref = T_probe_ref * T_image_probe`.
- Frame names in use: `CT` (CT/mesh model), `ref` (tracker reference), `bone`, `probe`, `image`. Keep this capitalization; don't invent synonyms.
- Name points and meshes by the frame of their coordinates (`bonePointsCT`, `boneMeshRef`), not by what the object is.
- Transform Nx3 arrays with `applyRigidTransform`; rebuild `triangulation` with the original connectivity.
- Use MATLAB transform objects only when an API requires them, and convert back to 4x4 immediately (`rigidtform3d.A` already matches).
- Derive inverses from the primary transform; validate important transforms as finite, proper rigid matrices.

## Optimization pipeline
- `functions/bonePoseOptimization/` owns orchestration. Root holds only stable entry points (cost dispatcher `bonePoseCostFunction.m`, one run, one experiment).
- Optimizer state is a 6D perturbation `[vx; vy; vz; wx; wy; wz]` around `data.T_init_originct`; convert with the paired functions in `poseEvaluation/`.
- Do slow setup once in `inputPreparation/`; never load files inside a cost function.
- New cost model: add the evaluator and its config validator together in `costModels/` and register it.
- No plotting inside cost functions or optimizers.

## Where code goes
- `functions/2D3Dintersection/`: mesh/image-plane intersection, rasterization, face-toward-probe filtering, UV segment ordering.
- `functions/geometry/`: generic mesh I/O and transform helpers.
- `functions/fcal_related/`: fCal XML and Plus `.mha` file reading only ([format spec](https://pluslib.readthedocs.io/en/latest/file-formats/FileSequenceFile.html)).
- `functions/smoothTransformation/`: temporal smoothing of SE(3) sequences.
- `functions/display/`: visualization only; must not compute costs or change optimizer state.
- `functions/bonePoseOptimization/configuration/`, `evaluationMetric/`, `evaluationPlot/`, `tests/`: config flow, metrics, result plots, tests.
- `functions/` top level: only helpers shared across several areas.
- `config/`: JSON run configs. `examples/`: small demo scripts. `devs/<feature>/`: in-progress feature work. `tools/`: data-preparation tools.
- `literatures/<paper>/`: one reference paper per folder. `notes.md` is committed (citation, key equations, code mapping); the PDF is local only (gitignored, copyright). Read `notes.md` first and open the PDF only for details. Keep `notes.md` in sync when the related code changes.
