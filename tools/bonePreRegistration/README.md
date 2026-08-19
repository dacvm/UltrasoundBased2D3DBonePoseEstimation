# Bone Pre-Registration

## Short Summary

This MATLAB tool prepares a coarse pose for each knee bone before later bone-pose optimization. It combines the post-processed CT meshes and their anatomical coordinate systems with bone surfaces recovered from tracked ultrasound images.

The workflow has two consecutive parts:

1. `bonePreRegistration_anatomicalLandmark.m` measures three reproducible CT-mesh landmarks for each femur and tibia: medial, lateral, and shaft.
2. `bonePreRegistration_3Dsurface.m` associates each regional ultrasound surface with its matching CT landmark and estimates a rigid CT-to-reference transformation for each bone.

Run Part 1 first. Part 2 requires the landmark MAT-file created by Part 1 and the 3D bone-surface MAT-file created by [`tools/boneSegmentationProcess`](../boneSegmentationProcess/README.md), Part 3.

## Coordinate-Frame Convention

All rigid transforms are numeric 4-by-4 matrices and act on column vectors:

```text
p_target = T_source_target * p_source
```

Part 1 stores landmark coordinates in the CT frame. Part 2 uses measured surface points already expressed in the common `ref` frame and estimates `T_CT_ref_est`, which moves CT points and mesh vertices into `ref`. The anatomical bone-frame pose is then propagated with:

```matlab
T_bone_ref_est = T_CT_ref_est * T_bone_CT;
```

<hr style="border: 0; border-top: 5px solid #333; margin: 2.5em 0;">

# (Part 1) Measurement Anatomical Landmark

## Required Input Data

Part 1 requires a post-processed CT MAT-file containing a variable named `bones`. The array must contain exactly one femur record with bone code `F` and one tibia record with bone code `T`. Array order does not matter.

Each bone record must provide the CT-frame geometry used by the measurement:

- `name` and `bone` identify the bone.
- `mesh` is a valid `triangulation` whose vertices are expressed in CT coordinates.
- `T_bone_CT` is the finite, proper 4-by-4 rigid transform from the anatomical bone frame to the CT frame.

Edit `tools/bonePreRegistration/configs/bonePreRegistration_anatomicalLandmark.json`:

| Setting | Meaning |
| --- | --- |
| `input.ctPostProcessedFilePath` | Directory containing the post-processed CT MAT-file. |
| `input.ctPostProcessedFileName` | MAT-file name only, including the `.mat` extension. |
| `output.boneLandmarkOutputPath` | Directory in which the landmark MAT-file and verification figures are saved. |
| `parameters.kneeSide` | Anatomical side, either `left` or `right`; this maps the signed local z directions to medial and lateral. |
| `parameters.femur.femur_epicondyleProximalOffset_mm` | Nonnegative distance from the femoral ACS origin along its positive y-axis before finding the condylar landmarks. |
| `parameters.femur.femur_epicondyleAnteriorAngleOffset_deg` | Anterior rotation of the two femoral condylar rays, in the range `[0, 90)` degrees. |
| `parameters.femur.femur_shaftProximalOffset_mm` | Nonnegative distance from the femoral ACS origin toward the proximal shaft. |
| `parameters.femur.femur_shaftAnteriorAngleOffset_deg` | Signed circumferential direction of the femoral shaft ray, in the range `[-180, 180]` degrees. |
| `parameters.tibia.tibia_condyleDistalOffset_mm` | Nonnegative distance from the tibial ACS origin along its negative y-axis before finding the condylar landmarks. |
| `parameters.tibia.tibia_condyleAnteriorAngleOffset_deg` | Anterior rotation of the two tibial condylar rays, in the range `[0, 90)` degrees. |
| `parameters.tibia.tibia_shaftDistalOffset_mm` | Nonnegative distance from the tibial ACS origin toward the distal shaft. |
| `parameters.tibia.tibia_shaftAnteriorAngleOffset_deg` | Signed circumferential direction of the tibial shaft ray, in the range `[-180, 180]` degrees. |
| `parameters.shaftHalfThickness_mm` | Positive half-thickness of the axial mesh band used to calculate each shaft landmark. |

Paths may be absolute or relative. Relative paths are resolved from the directory containing the JSON file. The output directory is created automatically when it does not exist.

## Processing Workflow

1. **Load and validate the CT bones.** The script finds the femur and tibia by bone code, checks their meshes and anatomical transforms, and validates the knee side and parameter ranges.
2. **Measure femoral condylar landmarks.** The configured proximal offset moves a line origin along the femoral anatomical y-axis. Two rays point toward the negative-z and positive-z surfaces and rotate anteriorly by the configured angle. The outer mesh intersections become the two condylar landmark candidates.
3. **Measure tibial condylar landmarks.** The same paired-ray method is applied after moving distally along the tibial negative y-axis.
4. **Assign medial and lateral names.** For a left knee, positive local z is medial; for a right knee, positive local z is lateral. This converts the signed-z intersections into stable anatomical labels.
5. **Measure each shaft landmark.** Vertices inside a band around the configured femoral or tibial shaft offset define a local shaft centroid. A ray with the configured circumferential angle intersects the mesh to place the landmark on the shaft surface.
6. **Report and visually verify the result.** MATLAB prints all six CT coordinates and measurement distances, then displays the CT meshes, anatomical axes, measurement geometry, and labelled landmarks.
7. **Save the artifacts.** The script saves the landmarks and full intersection diagnostics in a MAT-file, preserves the interactive figure as a FIG file, and exports a 300-DPI PNG preview.

The landmark row order is always `[medial; lateral; shaft]` for each bone.

## Running the Project

1. Complete the CT knee post-processing workflow so the selected MAT-file contains the femur and tibia meshes with `T_bone_CT`.
2. Set the CT input, output directory, knee side, and measurement parameters in `tools/bonePreRegistration/configs/bonePreRegistration_anatomicalLandmark.json`.
3. Start MATLAB and run:

   ```matlab
   run('tools/bonePreRegistration/bonePreRegistration_anatomicalLandmark.m')
   ```

   If MATLAB is not currently in the project root, pass the absolute script path to `run`.

4. Inspect the printed coordinate table and the verification figure. Check that medial and lateral are on the correct anatomical sides and that each shaft point lies on the intended surface.
5. If necessary, adjust the offsets or angles and rerun Part 1 before using the landmark file in Part 2.

The default output base name is:

```text
boneLandmarks_yyyyMMdd_HHmmss
```

One run creates matching `.mat`, `.fig`, and `.png` files.

## Output Structure

The MATLAB v7.3 MAT-file contains `landmarks` and `intersectionDiagnostics`:

```text
landmarks(1..2)
+-- name, bone
+-- T_bone_CT
+-- coordinateFrame, units, kneeSide, positiveZSide
+-- distalOffset_mm, proximalOffset_mm, anteriorAngleOffset_deg
+-- shaftProximalOffset_mm, shaftDistalOffset_mm
+-- shaftAnteriorAngleOffset_deg, shaftHalfThickness_mm
+-- medial, lateral, shaft
+-- pointLabels
+-- points

intersectionDiagnostics(1..2)
+-- name, bone, T_bone_CT
+-- coordinateFrame, units
+-- distalOffset_mm, proximalOffset_mm, anteriorAngleOffset_deg
+-- lineOrigin, lineDirection
+-- points, signedDistances_mm
+-- shaft
    +-- signedOffset_mm, halfThickness_mm
    +-- planePoints, planeNormal
    +-- retainedVertexIndices, retainedVertexCount, centroid
    +-- anteriorAngleOffset_deg, lineDirection
    +-- points, signedDistances_mm
    +-- selectedDistance_mm, selectedPoint
```

Important fields are:

| Field | Explanation |
| --- | --- |
| `landmarks(i).T_bone_CT` | Anatomical bone-frame pose copied from the matching CT bone. It is retained so later processing can propagate the bone frame through the estimated registration. |
| `coordinateFrame`, `units` | Declare that landmark and diagnostic coordinates are in the `CT` frame and measured in millimetres. |
| `kneeSide`, `positiveZSide` | Record the laterality rule used to assign the signed-z intersections to medial and lateral. |
| `medial`, `lateral`, `shaft` | Individual finite 1-by-3 CT-frame landmark coordinates used by Part 2. |
| `pointLabels` | Stable labels `medial`, `lateral`, and `shaft`. |
| `points` | 3-by-3 coordinate matrix in the fixed row order `[medial; lateral; shaft]`. |
| Landmark offset and angle fields | Exact parameter values used for this bone, saved with the result so the measurement is reproducible. |
| `intersectionDiagnostics(i).lineOrigin` | CT-frame origin from which the paired condylar rays were cast. |
| `intersectionDiagnostics(i).lineDirection` | Two CT-frame ray directions in the order negative-z followed by positive-z. |
| `intersectionDiagnostics(i).points` | All retained condylar mesh intersections before selecting the outer surface points. |
| `intersectionDiagnostics(i).signedDistances_mm` | Signed distances that preserve which ray produced each condylar intersection. |
| `intersectionDiagnostics(i).shaft` | Mesh-band, centroid, ray, intersection, and selected-point details used to audit the shaft landmark calculation. |

Load the result with:

```matlab
loadedLandmarks = load('boneLandmarks_yyyyMMdd_HHmmss.mat', ...
    'landmarks', 'intersectionDiagnostics');
landmarks = loadedLandmarks.landmarks;
intersectionDiagnostics = loadedLandmarks.intersectionDiagnostics;
```

## Common Input Problems

- The selected CT MAT-file does not contain exactly one femur (`F`) and one tibia (`T`) in `bones`.
- A mesh is not a valid `triangulation`, contains invalid vertices, or is expressed in a frame inconsistent with `T_bone_CT`.
- `T_bone_CT` is missing or is not a finite proper rigid 4-by-4 matrix.
- `kneeSide` is not `left` or `right`, which would make medial/lateral mapping ambiguous.
- A distance is negative, a condylar anterior angle is outside `[0, 90)`, a shaft angle is outside `[-180, 180]`, or `shaftHalfThickness_mm` is not positive.
- A configured ray misses the mesh. Reduce or correct the associated offset or angle and verify the anatomical coordinate system.
- A relative path is interpreted from the wrong location; it is resolved from the `configs` directory, not from the MATLAB current folder.

<hr style="border: 0; border-top: 5px solid #333; margin: 2.5em 0;">

# (Part 2) Coarse Registration

## Required Input Data

Part 2 requires three matching MAT-files:

- The reviewed ultrasound snapshot output from `tools/ultrasoundSpatialProcessing`. It must contain `validSnapshots` and `validBonePoses`, and its `processingMode` must currently be `snapshot`.
- The recovered 3D bone-surface output from [`tools/boneSegmentationProcess`](../boneSegmentationProcess/README.md), Part 3. It must contain `surfaceResults` and `extractionMetadata`, with every record providing `surfaceCoordinatesXYZRef`.
- The bone-landmark MAT-file produced by Part 1. It must contain `landmarks` and `intersectionDiagnostics`.

The ultrasound snapshot file also records the post-processed CT MAT-file in `validBonePoses.ctPostProcessedMatFile`. Part 2 loads `bones` from that recorded source so the CT meshes used for registration match the saved ground-truth poses.

Edit `tools/bonePreRegistration/configs/bonePreRegistration_3Dsurface.json`:

| Setting | Meaning |
| --- | --- |
| `input.ultrasoundImageFilePath` | Directory containing the reviewed ultrasound snapshot MAT-file. |
| `input.ultrasoundImageFileName` | Snapshot MAT-file name only. |
| `input.boneSurfaceFilePath` | Directory containing the recovered 3D bone-surface MAT-file. |
| `input.boneSurfaceFileName` | Recovered bone-surface MAT-file name only. |
| `input.boneLandmarksFilePath` | Directory containing the Part 1 landmark MAT-file. |
| `input.boneLandmarksFileName` | Landmark MAT-file name only. |
| `output.coarseRegistrationOutputPath` | Directory in which the coarse-registration MAT-file is saved. |

Paths may be absolute or relative. Relative paths are resolved from the directory containing `bonePreRegistration_3Dsurface.json`. Missing output directories are created automatically; missing input directories or files stop the workflow.

## Processing Workflow

1. **Load and match the workflow artifacts.** The script loads the reviewed snapshots and ground-truth poses, the recovered 3D surface results, the CT bones recorded by spatial processing, and the Part 1 landmarks.
2. **Display the recovered ultrasound geometry.** All tracked image planes and nonempty bone-surface point sets are drawn in the common `ref` frame for an initial consistency check.
3. **Group surface points by anatomy.** Surface groups are classified from names ending in `_medial`, `_lateral`, or `_shaft`; the legacy suffix `_mid` is treated as `shaft`. Groups are matched to bones by bone code, and all nonempty records in one region are combined.
4. **Build regional correspondence candidates.** Every measured surface point in a region is paired with that region's single CT landmark. The repeated landmark and surface matrices therefore have matching rows. Sampled connection lines are displayed for inspection.
5. **Prepare the comparison scene.** The script draws the ground-truth bone meshes and anatomical coordinate systems stored in `validBonePoses`, together with all measured surfaces.
6. **Estimate one rigid transform per bone.** `estgeotform3d` robustly estimates the transform from measured surface points in `ref` to their paired CT landmarks using a maximum correspondence distance of 100 mm. The inverse matrix is stored as `T_CT_ref_est` and applied to the CT mesh.
7. **Propagate and display the anatomical pose.** The estimated CT-to-reference transform moves `T_bone_CT` and the CT mesh into `ref`. Colored estimated meshes and dashed anatomical axes are overlaid on the gray ground-truth geometry.
8. **Save the coarse registration.** The complete result array is written automatically, including explicit status records for bones that could not be registered.

Each bone needs at least three unique, non-collinear points in both correspondence sets. Because CT points are repeated regional landmarks, usable measurements must cover at least three non-collinear regional landmark locations. A bone that does not meet this requirement is skipped with a warning while other bones continue.

## Running the Project

1. Run Part 1 and visually approve its CT landmarks.
2. Complete Bone Segmentation Process Part 3 so `surfaceCoordinatesXYZRef` contains recovered points in the common reference frame.
3. Select matching snapshot, surface, and landmark files in `tools/bonePreRegistration/configs/bonePreRegistration_3Dsurface.json`.
4. Start MATLAB and run:

   ```matlab
   run('tools/bonePreRegistration/bonePreRegistration_3Dsurface.m')
   ```

   If MATLAB is not currently in the project root, pass the absolute script path to `run`.

5. Inspect both figures. In the first, check that recovered surface points lie on their ultrasound image planes. In the second, compare the estimated colored meshes and dashed anatomical axes with the gray ground-truth meshes and solid axes.
6. Read the saved output path and any skipped-bone warnings in the MATLAB Command Window.

The default output filename is:

```text
coarseRegistration_yyyyMMdd_HHmmss.mat
```

## Output Structure

The MATLAB v7.3 output contains `coarseRegistration` and the small provenance structure `coarseRegistrationMetadata`:

```text
coarseRegistration(1..B)
+-- name
+-- bone
+-- status
+-- T_CT_ref_est
+-- T_bone_ref_est
+-- boneMeshRef_est

coarseRegistrationMetadata
+-- createdAt
+-- sourceUltrasoundFile
+-- sourceUltrasoundVariables
+-- sourceBoneSurfaceFile
+-- sourceBoneSurfaceVariables
+-- sourceCtFile
+-- sourceCtVariable
+-- sourceBoneLandmarksFile
+-- sourceBoneLandmarksVariables
+-- configurationFile
```

| Field | Explanation |
| --- | --- |
| `name`, `bone` | Identify the bone and preserve the association with the CT, landmark, surface, and ground-truth records. |
| `status` | `registered` means a rigid transform was estimated successfully. A value beginning with `skipped:` explains why the bone was retained without a transform, currently because it had fewer than three non-collinear correspondence points. |
| `T_CT_ref_est` | Estimated 4-by-4 rigid transform from CT coordinates to the common reference frame. Apply it as `p_ref = T_CT_ref_est * p_CT` for homogeneous column-vector points. |
| `T_bone_ref_est` | Estimated anatomical bone-frame pose in `ref`, calculated as `T_CT_ref_est * T_bone_CT`. |
| `boneMeshRef_est` | `triangulation` made from the original CT connectivity and vertices transformed into `ref` by `T_CT_ref_est`. |

Skipped entries keep `T_CT_ref_est`, `T_bone_ref_est`, and `boneMeshRef_est` empty. This allows downstream code to inspect `status` without losing the bone's identity.

The metadata fields identify every input used by the coarse-registration workflow:

| Metadata field | Explanation |
| --- | --- |
| `createdAt` | Date and time when the coarse-registration output was saved. |
| `sourceUltrasoundFile` | Full path of the reviewed ultrasound snapshot MAT-file. |
| `sourceUltrasoundVariables` | Loaded ultrasound variables: `validSnapshots` and `validBonePoses`. |
| `sourceBoneSurfaceFile` | Full path of the recovered 3D bone-surface MAT-file. |
| `sourceBoneSurfaceVariables` | Loaded surface variables: `surfaceResults` and `extractionMetadata`. |
| `sourceCtFile` | Full path of the CT MAT-file recorded by `validBonePoses`. |
| `sourceCtVariable` | Loaded CT variable, currently `bones`. |
| `sourceBoneLandmarksFile` | Full path of the bone-landmark MAT-file. |
| `sourceBoneLandmarksVariables` | Loaded landmark variables: `landmarks` and `intersectionDiagnostics`. |
| `configurationFile` | Full path of `bonePreRegistration_3Dsurface.json`. Its contents are not copied into the metadata. |

Load the result with:

```matlab
loadedRegistration = load('coarseRegistration_yyyyMMdd_HHmmss.mat', ...
    'coarseRegistration', 'coarseRegistrationMetadata');
coarseRegistration = loadedRegistration.coarseRegistration;
coarseRegistrationMetadata = ...
    loadedRegistration.coarseRegistrationMetadata;
```

## Common Input Problems

- The selected snapshot MAT-file does not contain both `validSnapshots` and `validBonePoses`.
- The snapshot and recovered surface files come from different runs, causing group, record, or identity ordering to disagree.
- The recovered surface file is an older or Part 2 artifact whose `surfaceCoordinatesXYZRef` values are absent or still empty. Run Bone Segmentation Process Part 3.
- A surface group name does not end in `_medial`, `_lateral`, `_shaft`, or the supported legacy suffix `_mid`.
- Bone codes do not uniquely match across the CT meshes, landmarks, surface groups, and ground-truth poses.
- A Part 1 landmark is not one finite 1-by-3 CT coordinate, or a recovered surface is not a finite N-by-3 `ref` coordinate matrix.
- Fewer than three non-collinear regional correspondences are available for a bone, so its registration is skipped.
- `validBonePoses.processingMode` is `kinematic`; kinematic pre-registration is not implemented in this script yet.
- `validBonePoses.ctPostProcessedMatFile` points to a missing or moved CT MAT-file.
- A relative path is interpreted from the wrong location; it is resolved from the `configs` directory.
