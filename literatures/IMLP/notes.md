# IMLP — Iterative Most-Likely Point Registration

**Citation:** Billings SD, Boctor EM, Taylor RH. *Iterative Most-Likely Point Registration (IMLP): A Robust Algorithm for Computing Optimal Shape Alignment.* PLoS ONE 10(3): e0117688 (2015).
**DOI:** [10.1371/journal.pone.0117688](https://doi.org/10.1371/journal.pone.0117688)
**Access:** Open access (CC-BY), free to read at the DOI link.
**Authors' code:** https://github.com/sbillin/IMLP

## Why it matters for this project
This is the foundation of [P-IMLOP](../P-IMLOP/notes.md). P-IMLOP reuses two things from this paper:
- the anisotropic Gaussian match likelihood
- the PD-tree search with ellipsoid–OBB pruning

## Key idea
- ICP picks the **closest** point. IMLP picks the **most likely** point under anisotropic Gaussian noise on both the source and the target.
- The algorithm alternates between a correspondence phase (PD-tree search) and a registration phase (generalized total least squares, GTLS).
- Robustness tools:
  - a match-uncertainty term σ², the average squared residual of the inliers
  - a chi-square outlier test

## Equations we use
**Match error (Eq. 9).** Minimizing this is the same as maximizing the match likelihood (Eq. 3):

```
E_match = log|R M_x Rᵀ + M_y| + (y − R x − t)ᵀ (R M_x Rᵀ + M_y)⁻¹ (y − R x − t)
```

Keep the log term when the target covariances vary over the surface.

**Outlier test (Eqs. 5–6):** a match is an outlier if its squared Mahalanobis distance is greater than `chi2inv(p, 3)`. The default is 7.81 (p = 0.95).

**Registration, GTLS (Eq. 20):** minimize the sum of squared Mahalanobis distances. The paper solves it with Gauss–Newton and a small-angle skew linearization (Eqs. 21–25).

## PD-tree (correspondence phase)
- **Building the tree:** each node gets its own frame from the PCA of the datum positions, and an oriented bounding box (OBB).
- **Splitting:** each node is split along its largest-variance axis.
- **Pruning:** a node is skipped when the ellipsoid of possibly better matches does not intersect the node's OBB.
  - The ellipsoid is defined by: Mahalanobis term < `E_best − log_min` (Eq. 10).
  - The paper bounds the covariance in three ways, from loosest to tightest: spherical (Eq. 14), simple ellipsoidal (Eq. 15), compact ellipsoidal (Eqs. 16–17).

## Where it lives in this repo
IMLP itself is not implemented. Its PD-tree concepts are reused in the P-IMLOP code in `devs/pimlopDevelopment/`: see `buildPIMLOPPDTree.m`, `searchPDTree.m` and `ellipsoidIntersectsOBB.m`.

P-IMLOP drops the log term (its covariance is fixed for every match) and has no outlier test.
