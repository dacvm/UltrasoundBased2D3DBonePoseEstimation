# Bone-likelihood map: implementation notes

Implementation reference for the bone-likelihood intensity term. Background, figures and an
interactive demo are in [`boneLikelihoodMap.html`](boneLikelihoodMap.html); keep both files in sync.

**Status (2026-11-13):** designed, not implemented, not yet tested on real images. The reflection
score `R` now uses a Gaussian along depth with a fixed, measured echo thickness (see Design history).

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
| $h$ | Bone echo thickness along depth, measured on our images (width at half height) | mm |
| $\sigma_d$ | Standard deviation of the depth Gaussian in $R$, $\sigma_d = h/\sqrt{2\pi} \approx h/2.5$ | mm |
| $g$, $L$, $L_{\min}$ | Gap below the pixel, window length, shortest usable window | mm |

Beam direction is assumed along $+v$ (image columns, linear probe).
$\operatorname{clip}(x) = \min(1, \max(0, x))$.

## Equations

Reflection score: a Gaussian average along depth only (same column, nothing sideways), then a
rescale from background to echo peak:

$$\bar I(u,v) = \frac{\sum_{j} w_j\, I(u, v+j)}{\sum_{j} w_j}, \qquad
w_j = \exp\!\left(-\frac{(j\,\Delta_v)^2}{2\sigma_d^2}\right), \qquad \sigma_d = \frac{h}{\sqrt{2\pi}}$$

$$R(u,v) = \operatorname{clip}\!\left(\frac{\bar I(u,v) - b}{p - b}\right)$$

The sums run over rows with $|j\,\Delta_v| \le 3\sigma_d$ that lie inside the image, so the top and
bottom edges are not darkened. This is exactly `blurWithGaussian` in `smoothUltrasoundImages.m`
with sigma along the image width set to 0 and sigma along the height set to $\sigma_d / \Delta_v$.

Why $\sigma_d = h/\sqrt{2\pi}$: a thin line of thickness $t \ll \sigma_d$ then gets the peak score
$R \approx t/h$, the same as with a box average of height $h$. A band of thickness $T$ peaks at
$R = \operatorname{erf}\!\bigl(T / (2\sqrt{2}\,\sigma_d)\bigr)$: about 0.8 at $T = h$ and about 1 at $T \ge 2h$.

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

## Relation to the current intensity term

`R` on its own is the current `cost_intensityLine` smoothing with different settings, not a new
idea. The new parts of this term are the nothing-below score `S` and the reach step (O2).

| Step | Smoothing | Normalization | What it adds |
|---|---|---|---|
| Current `cost_intensityLine` | Gaussian in both directions, $\sigma$ = 1.5–5 mm, sized for reach | ÷ 255 | – |
| `R` | Gaussian along depth only, $\sigma_d$ from the echo thickness $h$ | $(\bar I - b)/(p - b)$, clipped | Thick echoes score higher than thin lines; full 0–1 range |
| `B = R .* S` | as `R` | as `R` | Nothing-below clue |

The current term uses one $\sigma$ for two jobs that pull in opposite directions: reach (needs a
large $\sigma$) and telling thick echoes from thin lines (needs $\sigma_d \approx h/2.5$). A large
$\sigma$ dilutes the bone too, which is why the term barely changes during a run. `R` keeps only the
second job; reach is handled separately (O2).

## Settings

| Setting | Proposed config name | Set per | Rule or default | Status |
|---|---|---|---|---|
| $b$ | – (computed) | image | median of the image | proposed |
| $p$ | `echoPeakPercentile` | image | 99.9th percentile of the image | proposed |
| $t$ | – | image | open, see O1 | **open** |
| $h$ → $\sigma_d$ | `boneEchoThicknessMm` | probe and scanner setting | Fixed parameter, measured once by hand (O5); 2.4 mm in the demos | decided (value to measure) |
| $g$ | `belowGapMm` | dataset | just larger than bone band + trailing echoes ($\tau$); 0.8–4 mm | to measure |
| $L$ | `belowWindowMm` | dataset | 6.4 mm; must stop above the reverberation line (about one bone depth further down) | proposed |
| $L_{\min}$ | `belowWindowMinMm` | dataset | 3 mm | proposed |

Config names are proposals; follow the existing `fixedParameters` / `hyperparameters` split in
`config/optconfig_*.json`. Likely hyperparameters to sweep: `belowGapMm`, `belowWindowMm`, and the
reach width. `boneEchoThicknessMm` goes under `fixedParameters`, not `hyperparameters`.

## Decided

- Image intensity only. Never read `data.boneSurfaceMeasurements` or any segmentation output.
- Filters only, no per-image decisions: no thresholds that classify pixels, no line finding,
  no "deepest line" rule. Length/continuity and direction clues are left out: the long, smooth
  predicted line already rewards them.
- $R$ and $S$ as defined above, combined by multiplication; the window looks down the same
  column only.
- $R$ smooths along depth only, with a Gaussian rather than a box. Reasons: the cost changes
  smoothly as a predicted line moves (a box gives a flat bottom inside a thick band and kinks at
  its edges), its lowest point sits at the band centre, and `blurWithGaussian` already does it.
  Telling thick from thin works about equally well with both.
- $h$ (`boneEchoThicknessMm`) is a fixed parameter set from our own measurement of the images,
  not a swept hyperparameter. It describes the probe and scanner setting, not the optimization.
  Reasons not to sweep it now: judging a sweep needs accurate ground truth, which we don't have
  yet; seed scatter in the last sweep (about 0.7 mm) is likely larger than its effect; and its
  effect is tangled with the reach choice (O2). A small check sweep (0.5×, 1×, 2× the measured
  value) can follow once new ground truth exists.

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
- **O5 Measuring the echo thickness $h$.** Proposed procedure: pick several images per probe
  setting where the bone is clearly visible; take depth profiles across the bone echo (as in
  Figure 4 of the HTML); measure the depth range where the brightness is above
  $b + (\text{peak} - b)/2$; use the median over images. A one-off measurement by a person, not a
  pipeline step. Known risk: in the tibia images the echo is under 1 mm thick, about as thin as
  the layer lines, so `R` barely separates them there ($\sigma_d \approx 0.3$ mm). In the phantom
  femur image the bone band looks clearly thicker than the layer lines. A sloped surface also
  looks thicker along the column than it is.

## Where the code goes

| Piece | Location | Notes |
|---|---|---|
| Map computation | new function in `functions/bonePoseOptimization/inputPreparation/` (for example `computeBoneLikelihoodMaps.m`) | Takes `imagePlanesRef` and the settings only; returns one map per plane, `[column, row]` layout like the images |
| Depth Gaussian for $\bar I$ | reuse `blurWithGaussian` (now a local function inside `smoothUltrasoundImages.m`) | Either let `smoothUltrasoundImages` accept separate sigmas per axis, or move `blurWithGaussian` to its own file so both callers share it |
| Call during preparation | `prepareBonePoseOptimizationInputs.m`, next to the `smoothUltrasoundImages` call | Store under `data.extra.<modelName>`, e.g. `data.extra.boneLikelihood.maps`. Preparation runs once per hyperparameter combination, so the maps can depend on hyperparameters |
| Evaluator | `functions/bonePoseOptimization/costModels/cost_<modelName>.m` | Reuse the sampling from `cost_intensityLine.m`; return the same top-level `details` fields |
| Validator | `costModels/validate_cost_<modelName>.m` | Added together with the evaluator |
| Registration | `costModels/getBonePoseCostDefinition.m` | One new `case` |
| Config templates | `config/optconfig_oneSweep_<modelName>.json`, `config/optconfig_hyperparamSweep_<modelName>.json` | Scripts read the `.local.json` copies |
| Tests | `functions/bonePoseOptimization/tests/testBonePoseCost<ModelName>.m` | Function-based, like `testBonePoseCostDispatcher.m` |

## Test plan

Synthetic images with known answers, so the tests need no ground truth:

1. **Single column, exact values.** Background 16 with one bright band: check $R$, $\mu$, $S$, $B$ by hand.
   A thin line ($t \ll \sigma_d$) peaks at $R \approx t/h$; a band with $T \ge 2h$ peaks at $R \approx 1$.
   Smoothing is along depth only: an image that varies only sideways is unchanged by $\bar I$.
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
- Bone echo thickness along depth: under 1 mm in the tibia depth profiles (Figure 4 of the HTML);
  visibly thicker than the layer lines in the phantom femur image. Not yet measured with the O5
  procedure.

## References

Literature behind the clues and the "read a bone-enhanced image under the predicted surface"
approach: see section 11 of `boneLikelihoodMap.html` (Jain 2004; Foroughi 2007; Jia 2016;
Pandey 2018; Brendel 2002/2003; Tümer 2018; Penney 2006; Karamalis 2012; Hacihaliloglu 2009/2011).

Related code: `functions/bonePoseOptimization/costModels/cost_intensityLine.m`,
`functions/bonePoseOptimization/inputPreparation/smoothUltrasoundImages.m`,
`functions/bonePoseOptimization/inputPreparation/prepareBonePoseOptimizationInputs.m`.

## Design history

Short record of how the design got here, so later readers see the reasoning, not only the result.

- **2026-11-11.** The literature report listed "reflection at bone thickness" (smoothing at the
  bone echo thickness, so thin layer lines respond less) as a separate approach "B", next to the
  bone-likelihood map "A".
- **2026-11-13.** "B" turned out to be the reflection score `R` inside `B = R .* S`, not a separate
  term. It also turned out to be the current `cost_intensityLine` smoothing with different settings
  (see Relation to the current intensity term). It is therefore documented here and gets no folder
  of its own.
- **2026-11-13.** Box versus Gaussian compared with an interactive demo (section 3.3 of the HTML):
  Gaussian chosen. The echo thickness $h$ made a fixed, measured parameter rather than a
  hyperparameter.
