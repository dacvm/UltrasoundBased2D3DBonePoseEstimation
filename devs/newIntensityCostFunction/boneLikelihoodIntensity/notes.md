# Bone-likelihood map: implementation notes

Implementation reference for the bone-likelihood intensity term. Background, figures and an
interactive demo are in [`boneLikelihoodMap.html`](boneLikelihoodMap.html); keep both files in sync.

**Status (2026-11-12):** designed, not implemented, not yet tested on real images.

## Idea in one paragraph

For every pixel of every ultrasound image, compute a score in [0, 1] for how much it looks like a
bone surface: bright here (reflection score `R`) and empty in the same column just below
(nothing-below score `S`). Their product is the bone-likelihood map `B`. The map depends only on
the image, so it is computed once during preparation. The cost reads `B` along the predicted
probe-facing bone lines, exactly where `cost_intensityLine` reads blurred brightness today.
No segmentation output is used anywhere.

## Notation

| Symbol | Meaning | Unit |
|---|---|---|
| $I(u,v)$ | Image brightness; column $u$, row $v$ (row grows with depth). Code: `plane.image(u, v)`, stored `[column, row]` | 0–255 |
| $N_v$, $\Delta_v$ | Number of rows; pixel height $H / N_v$ | –, mm |
| $b$, $p$, $t$ | Background, echo peak and tissue levels of one image | 0–255 |
| $k$ | Half-width (rows) of the depth smoothing in $R$, with $(2k+1)\Delta_v \approx h$ | rows |
| $h$ | Expected bone echo thickness | mm |
| $g$, $L$, $L_{\min}$ | Gap below the pixel, window length, shortest usable window | mm |

Beam direction is assumed along $+v$ (image columns, linear probe).
$\operatorname{clip}(x) = \min(1, \max(0, x))$.

## Equations

Reflection score:

$$\bar I(u,v) = \frac{1}{2k+1}\sum_{j=-k}^{k} I(u, v+j), \qquad
R(u,v) = \operatorname{clip}\!\left(\frac{\bar I(u,v) - b}{p - b}\right)$$

Rows of $\bar I$ that fall outside the image are left out of the average.

Nothing-below score, with window rows
$\mathcal{W}(u,v) = \{\, v' \in \{1,\dots,N_v\} : g < (v'-v)\Delta_v \le g + L \,\}$:

$$\mu(u,v) = \frac{1}{|\mathcal{W}|}\sum_{v' \in \mathcal{W}} I(u, v'), \qquad
S(u,v) = \begin{cases}
\operatorname{clip}\!\left(1 - \dfrac{\mu(u,v) - b}{t - b}\right) & |\mathcal{W}|\,\Delta_v \ge L_{\min} \\
1 & \text{otherwise}
\end{cases}$$

Bone-likelihood, element-wise (`B = R .* S`, same size as the image):

$$B(u,v) = R(u,v)\, S(u,v)$$

Cost, using the same sample points $\mathbf{s}_{im}$ as `cost_intensityLine` (every
`sampleSpacingMm` along the probe-facing intersection segments of plane $i$; a plane with no
visible bone contributes 0):

$$C_B = 1 - \frac{1}{N_{\text{planes}}}\sum_{i=1}^{N_{\text{planes}}}\frac{1}{M_i}\sum_{m=1}^{M_i} \hat B_i(\mathbf{s}_{im})$$

where $\hat B_i$ is $B_i$ after the reach step (open choice O2 below). Read it with `interp2`
exactly as `cost_intensityLine` reads the blurred image (same mm-to-pixel conversion and edge
clamping).

## Settings

| Setting | Proposed config name | Set per | Rule or default | Status |
|---|---|---|---|---|
| $b$ | – (computed) | image | median of the image | proposed |
| $p$ | `echoPeakPercentile` | image | 99.9th percentile of the image | proposed |
| $t$ | – | image | open, see O1 | **open** |
| $h$ → $k$ | `boneEchoThicknessMm` | dataset | about 2.4 mm in the demo; measure on our images | proposed |
| $g$ | `belowGapMm` | dataset | just larger than bone band + trailing echoes ($\tau$); 0.8–4 mm | to measure |
| $L$ | `belowWindowMm` | dataset | 6.4 mm; must stop above the reverberation line (about one bone depth further down) | proposed |
| $L_{\min}$ | `belowWindowMinMm` | dataset | 3 mm | proposed |

Config names are proposals; follow the existing `fixedParameters` / `hyperparameters` split in
`config/optconfig_*.json`. Likely hyperparameters to sweep: `belowGapMm`, `belowWindowMm`, and the
reach width.

## Decided

- Image intensity only. Never read `data.boneSurfaceMeasurements` or any segmentation output.
- Filters only, no per-image decisions: no thresholds that classify pixels, no line finding,
  no "deepest line" rule. Length/continuity and direction clues are left out: the long, smooth
  predicted line already rewards them.
- $R$ and $S$ as defined above, combined by multiplication; the window looks down the same
  column only.

Proposed defaults (recommended, not yet confirmed): the bottom-edge rule ($L_{\min}$, otherwise
$S = 1$), and measuring $b$, $p$ (and $t$) automatically per image so that nothing is tuned by
hand per image.

## Open choices

- **O1 Tissue level $t$.** Needs a rule that uses no segmentation. Candidate: a percentile of the
  pixels above background. Check on femur and tibia images before deciding.
- **O2 Reach.** $B$ is sharp, so a predicted line a few mm off the bone gets no hint. Options:
  (a) blur $B$ and rescale per image, $\hat B_i = (G_\sigma * B_i)/\max(G_\sigma * B_i)$, which keeps
  reach and restores the 0–1 range lost by plain blurring; (b) distance-based score
  $\tfrac12 (d/\sigma)^2$ with a cap, in the same unit as the P-IMLOP position term. Compare both.
- **O3 Uneven bone brightness** (dim stretches between saturated spots). Possible later step:
  weight sample points by how squarely the beam hits the predicted surface (mesh normal).
- **O4 Cost model name and how it combines with P-IMLOP** (stand-alone model, and/or a combined
  model like `intensityPIMLOP`).

## Where the code goes

| Piece | Location | Notes |
|---|---|---|
| Map computation | new function in `functions/bonePoseOptimization/inputPreparation/` (for example `computeBoneLikelihoodMaps.m`) | Takes `imagePlanesRef` and the settings only; returns one map per plane, `[column, row]` layout like the images |
| Call during preparation | `prepareBonePoseOptimizationInputs.m`, next to the `smoothUltrasoundImages` call | Store under `data.extra.<modelName>`, e.g. `data.extra.boneLikelihood.maps`. Preparation runs once per hyperparameter combination, so the maps can depend on hyperparameters |
| Evaluator | `functions/bonePoseOptimization/costModels/cost_<modelName>.m` | Reuse the sampling from `cost_intensityLine.m`; return the same top-level `details` fields |
| Validator | `costModels/validate_cost_<modelName>.m` | Added together with the evaluator |
| Registration | `costModels/getBonePoseCostDefinition.m` | One new `case` |
| Config templates | `config/optconfig_oneSweep_<modelName>.json`, `config/optconfig_hyperparamSweep_<modelName>.json` | Scripts read the `.local.json` copies |
| Tests | `functions/bonePoseOptimization/tests/testBonePoseCost<ModelName>.m` | Function-based, like `testBonePoseCostDispatcher.m` |

## Test plan

Synthetic images with known answers, so the tests need no ground truth:

1. **Single column, exact values.** Background 16 with one bright band: check $R$, $\mu$, $S$, $B$ by hand.
2. **Layer vs bone.** Bright line with speckle below versus bright band with background below: $B$ of the bone is clearly higher.
3. **Trailing echoes.** Faint echoes 2–4 mm under the bone: small $g$ lowers the bone's $S$; $g \ge \tau$ restores it.
4. **Bottom edge.** Pixel whose window is shorter than $L_{\min}$ gets $S = 1$; partial window uses only rows inside the image.
5. **Shapes and ranges.** $R$, $S$, $B$ have the image size and lie in [0, 1].
6. **Independence from segmentation.** The map function's inputs contain no segmentation fields; the cost runs on `data` without `boneSurfaceMeasurements`.
7. **Cost direction.** On a synthetic plane, a pose whose predicted line lies on the band gives a lower cost than a pose 2 mm off.

Then, on real data: compute $R$, $S$, $B$ for the femur and tibia images and check by eye that the
bone stays bright and the layer lines fade.

## Evidence so far

- Sweep `intensityPIMLOP_20261106_144439_500`: median change during a run 0.0017 for the intensity
  term versus 0.35 for P-IMLOP; equal contribution only at weight ≈ 0.992.
- Tibia images (`validSnapshots_20260910_172849.mat`): blurred echo peak ÷ 255 is 0.24 / 0.16 / 0.12 at
  σ = 1.5 / 3 / 5 mm, background 0.06. Level 3–10 mm below the echo ≈ 16 (background) in most
  images; above 16–31. Lateral images #1–3 show texture on both sides.
- Phantom femur (frontal): thin layer lines as bright as the bone above it, trailing echoes under the bone.

## References

Literature behind the clues and the "read a bone-enhanced image under the predicted surface"
approach: see section 11 of `boneLikelihoodMap.html` (Jain 2004; Foroughi 2007; Jia 2016;
Pandey 2018; Brendel 2002/2003; Tümer 2018; Penney 2006; Karamalis 2012; Hacihaliloglu 2009/2011).

Related code: `functions/bonePoseOptimization/costModels/cost_intensityLine.m`,
`functions/bonePoseOptimization/inputPreparation/smoothUltrasoundImages.m`,
`functions/bonePoseOptimization/inputPreparation/prepareBonePoseOptimizationInputs.m`.
