# P-IMLOP demos

These scripts show, step by step, how the P-IMLOP cost model works: how one ultrasound point is matched to the bone mesh, how the PD-tree makes that search fast, and how the whole calculation becomes the `cost_PIMLOP` function the optimizer calls. You don't need them to run an optimization; they are here to help you understand it.

The method comes from Billings et al. (2015). [`literatures/P-IMLOP/notes.md`](../../literatures/P-IMLOP/notes.md) has the citation, the equations, and where each equation lives in the code.

## How to run them

Open a script and run it. Each one finds its own files, so it works from any MATLAB folder, and needs no local input files: every script loads `optimization_setup.mat` from this folder (see [The saved demo input](#the-saved-demo-input)).

## Reading order

Each demo builds on the one before it. Times are from one run on a 6-core laptop.

| # | Script | What it shows | Time |
|---|---|---|---|
| 1 | `demo_EmatchFunctionCall_simpleSetup.m` | The match error between one measured point (position and in-plane normal) and one model point. | ~5 s |
| 2 | `demo_PDTreeSearch_1Image1Points.m` | One measured point: build the P-IMLOP model and its PD-tree in CT, then find the most likely mesh point. | ~5 s |
| 3 | `demo_PDTreeSearch_1ImageNPoints.m` | Every valid point of one image, searched one at a time. **Slow:** about 11 minutes. | ~11 min |
| 4 | `demo_PDTreeSearch_1ImageNPoints_batchProcessed.m` | The same image with the batched search, on an evenly spread subset of points. | ~2 s |
| 5 | `demo_PDTreeSearch_NImageNPoints_batchProcessed.m` | All images: each image's points are searched with that image's own orientation. | ~15 s |
| 6 | `demo_PDTreeSearch_NImageNPoints_functionCall.m` | The same calculation through `cost_PIMLOP`, the way the optimizer uses it: slow setup once, then one cheap call per candidate pose. | ~15 s |

Demo 3 is the slow, easy-to-follow version of demo 4. If you are short on time, read its code and skip running it.

## Deeper reading: development walkthroughs

These two scripts are the original development notebooks. They go through each calculation in full detail, without the batching of the demos, with many intermediate figures and printed checks.

| Script | What it shows | Time |
|---|---|---|
| `dev_Ematch_simpleSetup.m` | The match error worked out by hand, term by term, for one point pair. | ~2 s |
| `dev_PDTreeSearch.m` | Building the PD-tree and searching it, step by step. | ~1 min |

## The saved demo input

`optimization_setup.mat` is a saved copy of the prepared optimization data, the `data` struct that the optimizer and the cost functions receive. It holds `data`, the `config` used to make it, and `initialPoseVector` (zeros: the coarse start pose). `data.extra` is left out, because the demos build the P-IMLOP model and its PD-tree themselves.

It is kept in git on purpose, even though it is a generated file:

- The recordings and tool outputs it is made from (`data/` and `tools/**/outputs/`) are not in git. Without this file, someone who only cloned the repository could not run the demos.
- It is not an optimization result. It is a fixed demo input, like a test fixture, so it lives here and not in `output/` (which git ignores).

To refresh it, run [`makePIMLOPDemoSetup.m`](makePIMLOPDemoSetup.m). It prepares the data from `config/optconfig_oneSweep_PIMLOP.json` exactly as an optimization does, and needs the local input files listed there. Refresh it after a change to `prepareBonePoseOptimizationInputs`, or when the demos should use newer recordings.

## Tests

The demos are not tests. Two suite tests in `functions/bonePoseOptimization/tests/` check the same code on every test run:

- `testPIMLOPBatchedProcess.m`: the batched functions give the same answers as their scalar references.
- `testPIMLOPCostMatchesDirectWorkflow.m`: `cost_PIMLOP` gives the same cost and matches as the step-by-step workflow of demo 5.
