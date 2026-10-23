# Supported cost functions

This is an ongoing list. The current framework registers the following five cost models; more models can be added through the extension process described in [Adding a new cost function](adding-a-cost-function.md). Every model returns one scalar objective to CMA-ES, and a lower value is always better.

In the tables below, a **fixed parameter** has one value for the complete experiment. A **hyperparameter** is an array of candidate values; the experiment planner includes it in the Cartesian product used to create parameter combinations.

## 1. `intensityLine`: smoothed intensity along the predicted bone

This model cuts the candidate CT mesh with every ultrasound plane and keeps the probe-facing parts of the cut, which are the surfaces ultrasound should show as a bright echo. It then reads the image along those lines:

```text
evidence_i = mean smoothed intensity at points every sampleSpacingMm along
             plane i's probe-facing intersection segments, / intensityMax
             (0 when the bone does not cross plane i)

cost = 1 - mean over all planes of evidence_i
```

The cost lies in `[0, 1]`, and lower is better. Three design choices shape it:

- **No start-pose reference.** The coarse start pose is only a rough guess. Every plane is judged only by what the image shows at the candidate pose, so the best pose of the cost does not depend on where the search started. Every plane counts equally.
- **Continuous sampling.** The image is read with bilinear interpolation at evenly spaced points along the intersection segments, instead of at whole rasterized pixels. The cost therefore changes smoothly with the pose instead of in pixel-sized steps.
- **Smoothed images.** The bone echo is only about 1 mm thick, so on the raw image a line slightly off the echo reads only background and the cost gives no direction. `prepareBonePoseOptimizationInputs` therefore blurs every image once with a Gaussian of standard deviation `intensitySmoothingSigmaMm` and stores the result in `data.extra.intensityLine.smoothedImages`. A line near the echo then still reads part of it, so the cost points toward the bone. A larger sigma reaches further but gives a shallower minimum.

On the knee-phantom data, a 0.5–1 mm blur gave a single minimum in four of six 1-D sweeps (±8 mm and ±8 degrees around the start pose). Rotation about the ref y axis stayed poorly defined, because it barely changes the intersection lines.

A pose whose intersection is short but lies on a very bright spot can score well. The model is therefore meant to be combined with a cost that uses the segmented bone surface, such as P-IMLOP, which rules such poses out.

| Parameter | Type | Meaning |
| --- | --- | --- |
| `intensityMax` | Fixed | Positive intensity that counts as full evidence, normally `255` for 8-bit images. |
| `sampleSpacingMm` | Fixed | Positive largest distance in millimetres between neighbouring sample points along an intersection segment. |
| `intensitySmoothingSigmaMm` | Hyperparameter | Nonnegative Gaussian standard deviation in millimetres used to blur the images. `0` reads the raw images. |

This model does not require `boneSurfaceMatFile`.

## 2. `ICPLike`: one-way 3D point-to-mesh distance

This model transforms the CT mesh to the candidate pose and measures the distance from every ultrasound-derived 3D bone-surface point to its closest location on the mesh triangles. The returned cost is the root-mean-square of all point-to-surface distances in millimetres. It is one-way: measured ultrasound points must agree with the mesh, but unobserved regions of the mesh do not require corresponding ultrasound points.

**CT-frame KD-tree strategy.** For each measured point, the cost only searches the triangles attached to its `nearestVertexCount` nearest mesh vertices. `prepareBonePoseOptimizationInputs` builds a KD-tree over the CT-frame vertices and a vertex-to-face table once, and stores them in `data.extra.icpLike`. For each candidate pose, the cost moves the measured points from ref into CT instead of moving the mesh, so the same tree is reused by every CMA-ES candidate. The exact closest location on the candidate triangles is then computed for many points at once with `closestPointsOnTriangles`. The original implementation, which rebuilt the search on every call and handled one point at a time, is kept for study as `devs/costFunctionDevelopment/dev_cost_ICPLike.m`. It gives the same result.

| Parameter | Type | Meaning |
| --- | --- | --- |
| `nearestVertexCount` | Fixed | Positive integer number of nearby mesh vertices used to seed the local candidate-triangle search for each measured 3D point. A larger value searches a wider mesh neighborhood but increases evaluation time. |
| `pointBatchSize` | Fixed | Positive integer number of measured points whose candidate triangles are processed together. It only changes speed and memory use, never the result. `200` was the fastest setting on the project data. |

This model requires aligned 3D bone-surface measurements from `boneSurfaceMatFile`.

## 3. `intensityICP`: combined intensity and 3D distance

This model evaluates `intensityLine` and `ICPLike` at the same candidate pose. It divides the point-to-mesh RMSE by a reference distance to make that term dimensionless, then returns the convex blend

```text
cost = weight * intensityCost
     + (1 - weight) * (pointCloudRmseMm / distanceReferenceMm)
```

A `weight` of `1` selects only the smoothed-intensity term, while `0` selects only the normalized point-to-mesh term. Every part of the equation is saved in `details.costTerms`, and the full diagnostics of both models are kept in `details.componentDetails`.

| Parameter | Type | Meaning |
| --- | --- | --- |
| `intensityMax` | Fixed | Positive intensity that counts as full evidence, normally `255` for 8-bit images. |
| `sampleSpacingMm` | Fixed | Positive largest distance in millimetres between neighbouring sample points along an intersection segment. |
| `nearestVertexCount` | Fixed | Positive integer number of nearby mesh vertices used to seed the local candidate-triangle search for each measured 3D point. A larger value searches a wider mesh neighborhood but increases evaluation time. |
| `pointBatchSize` | Fixed | Positive integer number of measured points whose candidate triangles are processed together by the `ICPLike` term. It only changes speed and memory use, never the result. |
| `distanceReferenceMm` | Fixed | Positive distance in millimetres used to normalize the point-to-mesh RMSE before it is combined with the dimensionless intensity term. |
| `intensitySmoothingSigmaMm` | Hyperparameter | Nonnegative Gaussian standard deviation in millimetres used to blur the images. `0` reads the raw images. |
| `weight` | Hyperparameter | Convex blend coefficient in the inclusive range `[0, 1]`; it weights the intensity term, while `1 - weight` weights the normalized 3D-distance term. |

This model requires aligned 3D bone-surface measurements from `boneSurfaceMatFile`.

## 4. `PIMLOP`: most-likely oriented point match

This model implements the match error of P-IMLOP (Billings et al. 2015; see [`literatures/P-IMLOP/notes.md`](../literatures/P-IMLOP/notes.md)). Every ultrasound bone-surface measurement `x` has a 3D position and a 2D in-plane normal. For each measurement, the model finds the most likely point `y` on any CT mesh triangle and sums the resulting match errors:

```text
E_match(x, y) = 1/2 * (y_3dp - x_3dp)' * inv(Sigma) * (y_3dp - x_3dp)
              + kappa * (1 - cos(angle between the projected model normal and x_2dn))

cost = sum over all retained measurements of min_y E_match(x, y)
```

`Sigma` is a diagonal position covariance built from three standard deviations along the image axes. The model normal is rotated into the image and projected onto the image plane before it is compared with the measured 2D normal. A perfect match scores `0`.

**CT-frame PD-tree strategy.** Searching every triangle for every measurement would be far too slow. `prepareBonePoseOptimizationInputs` therefore builds a principal-direction tree (PD-tree) of oriented bounding boxes once, in the CT frame, and stores it in `data.extra.pimlop.PsiCT`. For each candidate pose, the cost moves the measurements from ref into CT instead of moving the mesh, so the same tree is reused by every CMA-ES candidate. The tree search skips any box that cannot contain a better match than the best one found so far.

| Parameter | Type | Meaning |
| --- | --- | --- |
| `measurementSubsampleFraction` | Fixed | Fraction in `(0, 1]` of the valid surface points kept from every image, spread evenly along each surface curve. Smaller values make every evaluation faster. |
| `positionXStandardDeviationImage` | Fixed | Positive position standard deviation in millimetres along the image x axis. |
| `positionYStandardDeviationImage` | Fixed | Positive position standard deviation in millimetres along the image y axis. |
| `positionZStandardDeviationImage` | Fixed | Positive position standard deviation in millimetres along the out-of-plane (image z) axis. |
| `kappa` | Hyperparameter | Nonnegative orientation concentration. `0` switches the orientation term off; `50` corresponds to roughly 8 degrees of angular spread. Bigger values give a narrower spread (roughly `1/sqrt(kappa)` radians). |

This model requires aligned 3D bone-surface measurements with 2D normals (`surfaceNormalXY` and `surfaceNormalMask`) from `boneSurfaceMatFile`. One evaluation takes several seconds, so keep `populationSize` and `maxFunctionEvaluations` small for first runs. The reference demos and regression tests in `devs/pimlopDevelopment/` still run independently.

## 5. `intensityPIMLOP`: combined intensity and P-IMLOP

This model evaluates `intensityLine` and `PIMLOP` at the same candidate pose and blends them with one weight, in the same way `intensityICP` blends intensity with the 3D point-to-mesh distance. The P-IMLOP total is a sum over all retained measurements, so it grows with the number of segmented points. It is therefore averaged over the measurements before it is blended:

```text
pimlopMeanMatchError = pimlopTotalMatchError / numberOfMeasurements

cost = weight * intensityCost
     + (1 - weight) * pimlopMeanMatchError
```

The same measurements are used for every candidate pose, so averaging divides by a fixed number and does not change the P-IMLOP best pose. A `weight` of `1` selects only the smoothed-intensity term, while `0` selects only the mean P-IMLOP term. Every part of the equation is saved in `details.costTerms`, and the full diagnostics of both models are kept in `details.componentDetails`.

**The two terms have different scales.** With 1/1/1.5 mm standard deviations and `kappa = 50`, the mean match error was about `2` at the coarse start pose of the knee-phantom data, about `4` after a 3 mm translation, and about `50` after a 5 degree rotation. The smoothed-intensity term lies in `[0, 1]` and changed by less than `0.1` over ±8 mm translations around the start pose, so the P-IMLOP term dominates unless `weight` is close to `1`. Because the orientation term is `kappa * (1 - cos)`, a larger `kappa` also raises the mean match error.

| Parameter | Type | Meaning |
| --- | --- | --- |
| `intensityMax` | Fixed | Positive intensity that counts as full evidence, normally `255` for 8-bit images. |
| `sampleSpacingMm` | Fixed | Positive largest distance in millimetres between neighbouring sample points along an intersection segment. |
| `measurementSubsampleFraction` | Fixed | Fraction in `(0, 1]` of the valid surface points kept from every image, spread evenly along each surface curve. |
| `positionXStandardDeviationImage` | Fixed | Positive position standard deviation in millimetres along the image x axis. |
| `positionYStandardDeviationImage` | Fixed | Positive position standard deviation in millimetres along the image y axis. |
| `positionZStandardDeviationImage` | Fixed | Positive position standard deviation in millimetres along the out-of-plane (image z) axis. |
| `intensitySmoothingSigmaMm` | Hyperparameter | Nonnegative Gaussian standard deviation in millimetres used to blur the images. `0` reads the raw images. |
| `kappa` | Hyperparameter | Nonnegative P-IMLOP orientation concentration. `0` switches the orientation term off. |
| `weight` | Hyperparameter | Convex blend coefficient in the inclusive range `[0, 1]`; it weights the intensity term, while `1 - weight` weights the mean P-IMLOP match error. |

This model requires aligned 3D bone-surface measurements with 2D normals from `boneSurfaceMatFile`. Every evaluation runs the P-IMLOP search, so it is at least as slow as `PIMLOP`.
