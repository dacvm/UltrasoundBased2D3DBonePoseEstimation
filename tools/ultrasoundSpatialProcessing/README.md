# Ultrasound Spatial Processing

## Short summary

This MATLAB tool combines tracked ultrasound images with CT-derived femur and tibia meshes. It places the images and bones in one reference frame, calculates the mesh intersections with the ultrasound planes, and opens an interactive browser for inspection and review.

The recommended entry point is `build_ultrasoundBone_intersectionData_poseModes.m`. It reads `configs/ultrasoundBone_intersectionData_poseModesConfig.json` and supports two acquisition types through `bonePoseMode`:

- `average`, `first`, or `last`: static mode with one selected pose per bone.
- `perDataRow`: kinematic mode with a pose for every synchronized acquisition row.

The browser can export approved snapshots or time frames for later processing. The retired snapshot-only script and configuration remain in `legacy/` and `configs/legacy/` for reference.

## Experiment setup

This workflow was developed for static and flexion knee-phantom experiments. A similar setup can be used with a cadaver leg. It requires femur and tibia bone pins with optical markers, a fixed reference rigid body, a tracked ultrasound probe, static snapshots or kinematic sequences, and a CT scan of the bones, pins, and markers.

Each Plus sequence file stores ultrasound images with tracked probe and reference poses. Its paired Qualisys CSV stores reference and bone-pin poses. fCal connects image coordinates to probe coordinates, while the processed CT data connects each bone mesh to its pin.

Qualisys and CT preparation must use matching rigid-body definitions. Different marker order, pin names, axes, or handedness will misalign the bones and images.

## Required input data

### Ultrasound images and tracking data

Provide an acquisition root with separate source folders whose names contain `femur` or `tibia`:

```text
measurement_01/
+-- femur_medial/
|   +-- acquisition_001.mha
|   +-- acquisition_001.csv
|   +-- acquisition_002.mha   # Static mode only
|   +-- acquisition_002.csv   # Static mode only
+-- tibia_medial/
    +-- acquisition_001.mha
    +-- acquisition_001.csv
```

MHA and CSV names are sorted separately and paired by position. Every nonempty folder must contain equal numbers of both file types. Empty folders remain represented as empty result groups.

| Mode | `bonePoseMode` | Input contract per source folder |
| --- | --- | --- |
| Static | `average`, `first`, `last` | Zero or more pairs; every MHA contains exactly one packet and its CSV exactly one row. |
| Kinematic | `perDataRow` | At most one pair; the MHA packet count must equal the CSV row count. |

MHA packet `n` is coupled to CSV row `n` before validity checks. Every CSV must contain `B_N_REF` plus the selected femur and tibia pin rigid bodies.

Static mode omits packets with invalid probe or reference tracking and reduces only valid Qualisys reference/pin pairs. Kinematic mode preserves every time index; unusable images or transforms remain aligned with `isValid = false` and an explanatory status.

Normally the reference pose comes from the MHA packet. For an acquisition without a tracked reference, `T_ref_global_override` in the script can hold a finite 4-by-4 Reference-to-Tracker transform. This is not a JSON setting.

See the [Plus File Sequence documentation](https://pluslib.readthedocs.io/en/latest/file-formats/FileSequenceFile.html) for the MHA format.

### Ultrasound probe calibration

Provide an fCal/PLUS XML file containing exactly one `ImageToProbe` transform. The script uses its closest proper rotation for the rigid transform and its original column lengths for physical pixel spacing.

### Post-processed CT scan data

Provide a MAT file containing `bones` and `bonepins`, produced by the sibling [Knee Phantom Processing tool](../ctkneePostProcess/README.md). It supplies the CT meshes, anatomical bone frames, and CT-side pin frames. Use data from the same physical pins and markers as the ultrasound experiment.

### Pose-mode configuration

Edit `configs/ultrasoundBone_intersectionData_poseModesConfig.json`:

| Setting | Meaning |
| --- | --- |
| `acquisitionDirectory` | Root containing the femur and tibia source folders. |
| `fcalConfigFile` | fCal XML path. |
| `ctPostProcessedMatFile` | CT post-processing MAT-file path. |
| `pinSelection.F` | Femur pin location, such as `PRO`. |
| `pinSelection.T` | Tibia pin location, such as `DIS`. |
| `bonePoseMode` | `average`, `first`, `last`, or `perDataRow`. |

The pin selections imply the required CSV names. For example, `F = PRO` and `T = DIS` require `B_N_REF`, `C_F_PRO`, and `C_T_DIS`.

| `bonePoseMode` | Behavior |
| --- | --- |
| `average` | Static. Averages valid row-wise pin-to-reference poses: arithmetic translation mean and rotation-aware orientation mean. |
| `first` | Static. Uses each bone's earliest valid pose by CSV timestamp across all source folders. |
| `last` | Static. Uses each bone's latest valid pose by CSV timestamp across all source folders. |
| `perDataRow` | Kinematic. Keeps each CSV row and matches it by source-folder, pair, and row indices. |

Paths may be absolute or relative. Relative paths resolve from the configuration file's directory, not MATLAB's current folder.

## Processing workflow

1. **Read and align pairs.** Find, sort, pair, and validate MHA/CSV files using the mode-specific rules.
2. **Place ultrasound planes.** Combine `ImageToProbe` with tracked probe and reference poses. Static mode omits unusable planes; kinematic mode preserves their rows and statuses.
3. **Load CT data.** Load `bones` and `bonepins`, then select the configured pins.
4. **Calculate bone poses.** First calculate each pin pose relative to the reference. Reduce valid poses for `average`, `first`, or `last`, or retain the aligned series for `perDataRow`.
5. **Calculate intersections.** Transform the matching CT mesh with `T_CT_ref`, intersect it with each finite image plane, and retain the raw result plus faces within 25 degrees of the probe-facing direction.
6. **Review results.** Use the established browser for static poses or the synchronized time-row browser for kinematic data.

## Running the project

1. Prepare the acquisition folders, fCal XML, and CT MAT file.
2. Edit `configs/ultrasoundBone_intersectionData_poseModesConfig.json`.
3. Run from the project root:

   ```matlab
   run('tools/ultrasoundSpatialProcessing/build_ultrasoundBone_intersectionData_poseModes.m')
   ```

   From another current folder, pass the absolute script path.

4. Inspect the browser, mark acceptable records, and click **Export Selected**. MATLAB asks for a destination and suggests `validSnapshots_yyyyMMdd_HHmmss.mat`.

The script opens the browser in review mode and leaves `snapshotPlanes`, `intersections`, `validBonePoses`, and `figIntersectionBrowser` in the workspace. Static selections apply per snapshot. In `perDataRow`, decisions are synchronized by CSV row across source tabs, so one decision represents the same time frame wherever that row exists. The browser stays open after export.

The project `functions` tree and this tool's `helpers` directory are added to the MATLAB path automatically.

## Output MAT-file structure

**Export Selected** writes a MATLAB v7.3 file after at least one record is approved. The in-memory arrays remain aligned by group and local index:

```text
snapshotPlanes(1..G)                 intersections(1..G)
+-- name, bone, path                 +-- name, bone, path
+-- data(1..N)                       +-- data(1..N)
```

The exported file contains `validSnapshots` and `validBonePoses`:

```text
validSnapshots(1..G)
+-- name, bone, path
+-- data(1..N_selected)
    +-- sourceIndex
    +-- plane
    +-- intersection

validBonePoses
+-- processingMode
+-- poseHandlingMode
+-- ctPostProcessedMatFile
+-- bonePoses(1..B)
    +-- bone
    +-- meshCT
    +-- T_bone_CT
    +-- data(1..P)
    +-- baselineData       # perDataRow export only
```

Every source group is preserved even if its exported `data` is empty. Static pose `data` has one record per bone. A `perDataRow` export filters pose `data` to the approved source groups and time rows; `baselineData` separately retains row 1 as visualization context without approving it.

```matlab
loadedOutput = load('validSnapshots_yyyyMMdd_HHmmss.mat', ...
    'validSnapshots', 'validBonePoses');
validSnapshots = loadedOutput.validSnapshots;
validBonePoses = loadedOutput.validBonePoses;
```

### Fields in each source-directory group

| Field | Explanation |
| --- | --- |
| `name` | Source-directory name and browser tab title. |
| `bone` | `F` or `T`, assigned from the directory name. |
| `path` | Absolute source-directory path. |
| `data` | Approved records in original acquisition order; empty if none were selected. |

### Fields in each selected `data` record

| Field | Explanation |
| --- | --- |
| `sourceIndex` | Local index in the retained processed group before browser selection. |
| `plane` | Ultrasound image, finite-plane geometry, validity, and provenance. |
| `intersection` | Processing status, raw intersection, and probe-facing subset. |

### Fields in `validBonePoses`

| Field | Explanation |
| --- | --- |
| `processingMode` | `static` or `kinematic`, derived from `poseHandlingMode`. |
| `poseHandlingMode` | `average`, `first`, `last`, or `perDataRow`. |
| `ctPostProcessedMatFile` | Absolute path of the source CT MAT file. |
| `bonePoses` | One record per processed bone. |

Each bone record contains `bone`, the CT-coordinate `triangulation` `meshCT`, `T_bone_CT`, and pose `data`. A kinematic export also has `baselineData`. Pose records contain:

| Field | Explanation |
| --- | --- |
| `sourceIndex` | Raw row index in its source group; the averaged pose keeps its template value. |
| `snapshotIndex`, `sequenceIndex` | Source-folder and MHA/CSV-pair indices. |
| `packetIndex`, `rigidBodyRowIndex` | Coupled MHA packet and CSV row indices. |
| `rigidBodyTimestamp` | CSV timestamp used by endpoint modes. |
| `sourceSampleCount` | Valid source count for an average, or `1` for a valid unreduced row. |
| `isValid`, `status` | Pose usability and explanation. |
| `T_pin_ref` | Pin-to-reference 4-by-4 transform. |
| `T_CT_ref` | CT-to-reference transform applied to `meshCT.Points`. |
| `T_bone_ref` | Anatomical-bone-to-reference transform. |

### Fields in `plane`

| Field | Explanation |
| --- | --- |
| `sourceIndex` | Raw packet index across the source group's pairs. |
| `T_image_ref` | Image-to-reference 4-by-4 transform. |
| `p0`, `ex`, `ey`, `n` | Plane origin, image-axis directions, and normal in the reference frame. |
| `W`, `H` | Physical image width and height across pixel-center intervals. |
| `nRows`, `nCols`, `image` | Raster dimensions and ultrasound pixels. |
| `timestamp`, `rigidBodyTimestamp` | MHA and paired CSV timestamps. |
| `bone`, `snapshotName` | Bone code and owning source folder. |
| `snapshotIndex`, `sequenceIndex` | Source-folder and pair indices. |
| `packetIndex`, `rigidBodyRowIndex` | Coupled packet and CSV row indices. |
| `isValid`, `status` | Plane usability and explanation. Invalid kinematic geometry is `NaN`. |

The plane uses `x = p0 + u*ex + v*ey`, with `0 <= u <= W` and `0 <= v <= H`.

### Fields in `intersection`

| Field | Explanation |
| --- | --- |
| `mask`, `pixelList` | Rasterized raw intersection mask and `[row, column]` pixels. |
| `segments3D`, `segmentsUV` | Raw segments in reference coordinates and finite-plane coordinates. |
| `segmentFaceIdx` | CT mesh-face index for each raw segment. |
| `probeFacingSegmentMask` | Raw segments passing the 25-degree facing test. |
| `probeFacingSegments3D`, `probeFacingSegmentsUV` | Facing segment subsets. |
| `probeFacingPixels` | Rasterized `[row, column]` pixels from facing segments. |
| `segmentFacingScore` | Dot product of each source face normal with `-plane.ey`. |
| `timestamp` | Copy of the MHA timestamp. |
| `isValid`, `status` | Whether geometry was computed and, if skipped, why. |

Empty geometry can mean a valid calculation found no crossing. Use `isValid` and `status` to distinguish that from a skipped row.

## Common input problems

- Unequal MHA and CSV file counts, or independently sorted names that do not describe the same order.
- A static pair has anything other than one packet and one CSV row.
- A kinematic folder has multiple pairs, or its packet and CSV row counts differ.
- A CSV is missing `B_N_REF` or a rigid body implied by `pinSelection`.
- A source-folder name lacks `femur` or `tibia`.
- `bonePoseMode` does not match the acquisition layout.
- A selected pin does not match CT `bonepins` or Qualisys names.
- A static dataset has no valid reference/pin pose for a bone.
- The fCal XML does not contain exactly one `ImageToProbe` transform.
- The CT MAT file does not contain both `bones` and `bonepins`.
