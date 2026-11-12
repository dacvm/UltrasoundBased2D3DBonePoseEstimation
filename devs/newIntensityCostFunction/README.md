# New intensity cost function

In-progress design work for a new intensity term in the bone-pose cost, on branch
`feature/newIntensityCostFunction`. The current intensity term (`intensityLine`) changes about
140 times less than the P-IMLOP term during a run, so in `intensityPIMLOP` it barely acts.
The new term must use only the ultrasound images, never the bone segmentation or anything
derived from it, so that it stays independent of the P-IMLOP term.

Nothing in this folder is implemented in `functions/` yet.

## Contents

| Folder | Term | Status |
|---|---|---|
| `boneLikelihoodIntensity/` | Bone-likelihood map: reflection score × nothing-below score per pixel, read along the predicted bone lines | Designed, not implemented |
| `assets/katex/` | Local copy of KaTeX 0.16.11 (MIT) so the HTML documents render their equations offline | Shared by all documents here |

Further terms get their own sub-folder next to `boneLikelihoodIntensity/`, with the same two files.

## How to read this folder

Each term folder holds two documents with the same content for two readers:

- **`notes.md`**: the implementation reference. Read this first. It holds the final
  equations, the settings, which choices are decided and which are open, where each piece goes
  in the code, and the test plan.
- **`<name>.html`**: the explainer for people, with background, figures and an interactive demo.
  Open it in a browser; it works offline as long as `assets/` stays next to it.

When the method changes, update both files in the same commit. If they disagree, `notes.md` is
the reference and the HTML must be corrected.

## Rules that apply to every term here

- Use image intensity only. No input from `tools/boneSegmentationProcess` or from
  `data.boneSurfaceMeasurements`.
- Follow `CLAUDE.md`: per-image work that does not depend on the pose is done once in
  `functions/bonePoseOptimization/inputPreparation/`; the evaluator and its config validator are
  added together in `functions/bonePoseOptimization/costModels/` and registered in
  `getBonePoseCostDefinition.m`; no file loading or plotting inside the cost function.
- Proposed, not yet decided: add each new term as its own cost model instead of changing
  `cost_intensityLine.m`, so that old and new can be compared on the same sweep.
