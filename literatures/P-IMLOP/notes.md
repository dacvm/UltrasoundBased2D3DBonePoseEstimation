# P-IMLOP — Projected Iterative Most-Likely Oriented Point

**Citation:** Billings S, Kang HJ, Cheng A, Boctor E, Kazanzides P, Taylor R. *Minimally invasive registration for computer-assisted orthopedic surgery: combining tracked ultrasound and bone surface points via the P-IMLOP algorithm.* Int J CARS 10:761–771 (2015).
**DOI:** [10.1007/s11548-015-1188-z](https://doi.org/10.1007/s11548-015-1188-z)
**Access:** Springer, not open access. The PDF is kept locally only (gitignored).
**Builds on:** [IMLP](../IMLP/notes.md) (same authors), which supplies the PD-tree search and the anisotropic noise model.

## Why it matters for this project
This is the main reference for the P-IMLOP cost model under development. It registers a bone mesh (from CT) to points and **in-plane surface normals** segmented from tracked 2D ultrasound images, which is the same problem this repo solves.

## Key idea
- A surface normal seen in a 2D ultrasound image is only the **projection** of the true 3D normal onto the image plane. So the model normal is rotated into the image frame and projected to 2D before it is compared with the measured 2D normal.
- **Position noise:** anisotropic 3D Gaussian (covariance Σ), which reflects the different axial, lateral and elevational resolution of ultrasound.
- **Orientation noise:** 2D von Mises distribution with concentration κ.
- ICP-style loop: a correspondence phase (most-likely match on the mesh for each data point) alternating with a registration phase (rigid update).

## Notation
| Paper | Meaning |
|---|---|
| `x = (x_3dp, x_2dn)` | Measured data point: 3D position + 2D in-plane unit normal |
| `y = (y_3dp, y_3dn)` | Model point on the mesh: 3D position + 3D unit normal |
| `R_p` | Rotation of the image plane (2D image x–y → 3D) |
| `P(·)` | Projection to the x–y plane (drop z) |
| `Σ`, `κ` | Position covariance, orientation concentration |

## Equations we use
**Match error (Eq. 3).** Minimizing this is the same as maximizing the match likelihood:

```
E_match = ½ (y_3dp − x_3dp)ᵀ Σ⁻¹ (y_3dp − x_3dp)  −  κ · ( P(R_pᵀ y_3dn) / ‖P(R_pᵀ y_3dn)‖ )ᵀ x_2dn
```

**Non-negative form used during the PD-tree search (Eq. 7):** replace `−κ·cos` with `κ·(1 − cos)`. A perfect match then scores 0.

**Pruning a node during the search (Eqs. 5–8):**
- Assume the orientation inside the node matches perfectly. Then `E_p,max = E_best`.
- Skip the node if the ellipsoid `(z − x_3dp)ᵀ Σ⁻¹ (z − x_3dp) ≤ 2·E_p,max` does not intersect the node's oriented bounding box (OBB).

**Registration phase (Eqs. 4, 9–21):** BFGS quasi-Newton over a Rodrigues-vector rotation and a translation increment, with analytic gradients.

## Parameters reported in the paper
- κ = 50 (about 8° angular standard deviation).
- Position standard deviation: 1 mm in-plane, 1.5 mm out-of-plane, relative to the image.
- Pointer-sampled points: isotropic 1 mm, with κ = 0 (orientation term turned off).
- Convergence/success thresholds: 1 mm and 4° average residual.

## Limitations stated by the authors
- Not robust to outliers. Unlike IMLP, there is no chi-square outlier test.
- Speed of sound and segmentation uncertainty are not modelled.

## Where it lives in this repo
The reusable functions are in `functions/PIMLOP/` (each with a scalar reference version and a `*_batchedProcess.m` version where listed). The cost model and its config validator are in `functions/bonePoseOptimization/costModels/`. Demos, development scripts, regression tests (`test_PIMLOP_batchedProcess.m`, `test_PIMLOPCostFunction.m`) and the `optimization_setup.mat` fixture stay in `devs/pimlopDevelopment/`.

| Paper step | File |
|---|---|
| Model preparation (face normals, areas, valid faces) | `preparePIMLOPModel.m` |
| PD-tree construction | `buildPIMLOPPDTree.m` |
| Match error, Eq. 7 | `calculatePIMLOPMatchError.m` |
| Most-likely point on one triangle (Mahalanobis) | `findMostLikelyPointOnTriangle.m` |
| Ellipsoid–OBB pruning test, Eq. 8 | `ellipsoidIntersectsOBB.m` |
| PD-tree search, Algorithm 2 | `searchPDTree.m` (and `*_batchedProcess.m` versions) |
| Exhaustive reference used to check the tree search | `searchPIMLOPBruteForce.m` |
| Cost for the bone-pose optimizer | `cost_PIMLOP_v01.m`, `validate_cost_PIMLOP_v01.m` (costModels) |

## How this repo differs from the paper
- **Registration phase:** not reimplemented. `cost_PIMLOP_v01.m` exposes the summed match error as a cost over the project's 6D pose vector. The pose optimizer does the registration step, and correspondences are searched again for every candidate pose.
- **Frames:** the search runs in the **CT** frame. Ultrasound queries are moved into CT, so the PD-tree is built only once.
- **Model point:** may lie anywhere on a triangle, not only at its centre (`findMostLikelyPointOnTriangle.m`). Triangle centres are used only to organize the tree.
