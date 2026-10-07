# Ultrasound Spatial Processing

## Short summary

This MATLAB tool combines tracked ultrasound images with CT-derived femur and tibia meshes. It places the images and bones in one reference frame, calculates the mesh intersections with the ultrasound planes, and opens an interactive browser for inspection and review.

The recommended entry point is `build_ultrasoundBone_intersectionData_poseModes.m`. Its configuration keeps file locations in `input` and `output`, while `pinSelection` and `bonePoseMode` are top-level settings. The script supports two acquisition types through `bonePoseMode`:

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
| `input.acquisitionDirectory` | Root containing the femur and tibia source folders. |
| `input.fcalConfigFilePath` | Directory containing the fCal XML file. |
| `input.fcalConfigFileName` | Filename of the fCal XML file. |
| `input.ctPostProcessedMatFilePath` | Directory containing the CT post-processing MAT file. |
| `input.ctPostProcessedMatFileName` | Filename of the CT post-processing MAT file. |
| `pinSelection.F` | Femur pin location, such as `PRO`. |
| `pinSelection.T` | Tibia pin location, such as `DIS`. |
| `bonePoseMode` | `average`, `first`, `last`, or `perDataRow`. |
| `output.ultrasoundIntersectionOutputPath` | Existing directory initially opened by the review browser's export dialog. |

The pin selections imply the required CSV names. For example, `F = PRO` and `T = DIS` require `B_N_REF`, `C_F_PRO`, and `C_T_DIS`.

| `bonePoseMode` | Behavior |
| --- | --- |
| `average` | Static. Averages valid row-wise pin-to-reference poses: arithmetic translation mean and rotation-aware orientation mean. |
| `first` | Static. Uses each bone's earliest valid pose by CSV timestamp across all source folders. |
| `last` | Static. Uses each bone's latest valid pose by CSV timestamp across all source folders. |
| `perDataRow` | Kinematic. Keeps each CSV row and matches it by source-folder, pair, and row indices. |

Directory paths may be absolute or relative. Relative paths resolve from the configuration file's directory, not MATLAB's current folder. The fCal and CT filenames are joined to their corresponding configured directories before the files and their extensions are validated. The configured output directory must already exist.

## Processing workflow

1. **Read and align pairs.** Find, sort, pair, and validate MHA/CSV files using the mode-specific rules.
2. **Place ultrasound planes.** Combine `ImageToProbe` with tracked probe and reference poses. Static mode omits unusable planes; kinematic mode preserves their rows and statuses.
3. **Load CT data.** Load `bones` and `bonepins`, then select the configured pins.
4. **Calculate bone poses.** First calculate each pin pose relative to the reference. Reduce valid poses for `average`, `first`, or `last`, or retain the aligned series for `perDataRow`.
5. **Calculate intersections.** Transform the matching CT mesh with `T_CT_ref`, intersect it with each finite image plane, and retain the raw result plus faces within 25 degrees of the probe-facing direction.
6. **Review results.** Use the established browser for static poses or the synchronized time-row browser for kinematic data.

## Running the project

1. Prepare the acquisition folders, fCal XML, and CT MAT file.
2. Edit `input`, `pinSelection`, `bonePoseMode`, and `output` in `configs/ultrasoundBone_intersectionData_poseModesConfig.json`.
3. Run from the project root:

   ```matlab
   run('tools/ultrasoundSpatialProcessing/build_ultrasoundBone_intersectionData_poseModes.m')
   ```

   From another current folder, pass the absolute script path.

4. Inspect the browser, mark acceptable records, and click **Export Selected**. MATLAB opens the save dialog in `output.ultrasoundIntersectionOutputPath` and suggests `validSnapshots_yyyyMMdd_HHmmss.mat`.

The script opens the browser in review mode and leaves `snapshotPlanes`, `intersections`, `validBonePoses`, and `figIntersectionBrowser` in the workspace. Static selections apply per snapshot. In `perDataRow`, decisions are synchronized by CSV row across source tabs, so one decision represents the same time frame wherever that row exists. The browser stays open after export.

The project `functions` tree and this tool's `helpers` directory are added to the MATLAB path automatically.

## Output MAT-file structure

**Export Selected** writes a MATLAB v7.3 file once at least one record is approved. The save dialog opens in `output.ultrasoundIntersectionOutputPath`. The file contains two variables:

| Variable | What it holds |
| --- | --- |
| `validSnapshots` | The approved ultrasound records, grouped by source folder. Each record has its image plane (`plane`) and its bone intersection (`intersection`). See [section 1](#1-validsnapshots). |
| `validBonePoses` | The CT bone meshes and their poses in the `ref` frame. See [section 2](#2-validboneposes). |

Load them with:

```matlab
loadedOutput   = load('validSnapshots_yyyyMMdd_HHmmss.mat', 'validSnapshots', 'validBonePoses');
validSnapshots = loadedOutput.validSnapshots;
validBonePoses = loadedOutput.validBonePoses;
```

### Conventions used in all tables

- **Frames.** All 3D points and directions are in the tracker reference frame `ref`. Lengths use the tracker/CT unit (normally mm).
- **Transforms.** `T_<source>_<target>` is a 4-by-4 rigid matrix that maps points from `source` to `target`: `p_target = T_source_target * p_source`.
- **Plane coordinates `(u, v)`.** A point on the image plane is `x = p0 + u*ex + v*ey`, with `0 <= u <= W` and `0 <= v <= H`. `p0` is the top-left image corner, `u` runs along the columns (left to right), and `v` runs along the rows (top to bottom, which is depth). `(u, v)` are physical distances, not pixels.
- **Pixels.** With `du = W/nCols` and `dv = H/nRows`, a plane point falls in pixel `col = floor(u/du) + 1`, `row = floor(v/dv) + 1`.
- **Valid vs. empty.** Records carry `isValid` and `status`. An empty result with `isValid = true` is a real result (for example, the plane does not cross the bone). `isValid = false` means the record was skipped, and `status` says why.

### 1. `validSnapshots`

```text
validSnapshots(1..G)          one element per source folder (browser tab)
+-- name, bone, path
+-- data(1..N_selected)       one element per approved record
    +-- sourceIndex
    +-- plane                 ultrasound image placed in ref        (section 1.3)
    +-- intersection          bone mesh cut by that image plane     (section 1.4)
```

`plane` and `intersection` in the same `data(k)` always describe the same acquisition record.

#### 1.1 Source-folder group: `validSnapshots(g)`

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | char | Source-folder name; also the browser tab title. |
| `bone` | char | `F` (femur) or `T` (tibia), from the folder name. |
| `path` | char | Absolute source-folder path. |
| `data` | 1 x N struct | Approved records in acquisition order. Empty if none were approved; the group itself is always kept. |

#### 1.2 Approved record: `validSnapshots(g).data(k)`

| Field | Type | Meaning |
| --- | --- | --- |
| `sourceIndex` | scalar | Position of this record in the processed group before browser selection. |
| `plane` | struct | The image plane, see section 1.3. |
| `intersection` | struct | The bone intersection, see section 1.4. |

In `perDataRow` mode, approval is per time row: approving a row exports it from every source folder that has that row.

#### 1.3 Image plane: `validSnapshots(g).data(k).plane`

The ultrasound image placed in 3D, using the fCal `ImageToProbe` calibration and the tracked probe and reference poses.

| Field | Type / size | Meaning |
| --- | --- | --- |
| `image` | `nCols x nRows` uint8 | Ultrasound pixels as stored by the MHA reader (width x height). **Transpose it** (`image.'`) to get the `nRows x nCols` layout used by `intersection.mask`. |
| `nRows`, `nCols` | scalar | Image height and width in pixels. |
| `W`, `H` | scalar | Physical image width and height: `nCols - 1` and `nRows - 1` pixel spacings, measured between pixel centers. |
| `T_image_ref` | 4 x 4 | Image-to-`ref` transform. Its columns give `ex`, `ey`, `n`, and `p0`. |
| `p0` | 3 x 1 | Top-left image corner in `ref`. |
| `ex` | 3 x 1 | Unit direction of increasing column (`u`) in `ref`. |
| `ey` | 3 x 1 | Unit direction of increasing row (`v`), pointing deeper, away from the probe, in `ref`. |
| `n` | 3 x 1 | Plane normal in `ref`. |
| `timestamp` | scalar | MHA packet timestamp. |
| `rigidBodyTimestamp` | scalar | Timestamp of the paired Qualisys CSV row. |
| `bone` | char | `F` or `T`, from the owning folder. |
| `snapshotName` | char | Owning source-folder name. |
| `sourceIndex` | scalar | Raw packet index, counted across all MHA/CSV pairs in the folder. |
| `snapshotIndex` | scalar | Source-folder index. |
| `sequenceIndex` | scalar | MHA/CSV pair index inside the folder. |
| `packetIndex`, `rigidBodyRowIndex` | scalar | Coupled MHA packet index and CSV row index (always equal). |
| `isValid`, `status` | logical, char | Whether the plane geometry can be used, and why not. In kinematic mode, invalid geometry is `NaN`. |

#### 1.4 Bone intersection: `validSnapshots(g).data(k).intersection`

How it is computed: the matching CT bone mesh is moved into `ref` with `T_CT_ref`, and every mesh triangle is cut by the image plane. Each triangle that crosses the plane inside the image gives one short straight line, a **segment**. Together, the segments form the bone outline in the image. A segment is **probe-facing** when its triangle's outward normal points back toward the probe (`-ey`) within 25 degrees. Ultrasound mostly shows these surfaces, so they form the expected bright bone echo.

In the table, `S` is the number of raw segments.

| Field | Type / size | Meaning |
| --- | --- | --- |
| `mask` | `nRows x nCols` logical | `true` where any raw segment passes through the pixel. Overlay it on `plane.image.'`. |
| `pixelList` | K x 2 | The `true` pixels of `mask` as `[row, col]` (from `find(mask)`). Ordered by column, **not** along the contour. |
| `segments3D` | 1 x S cell, each 2 x 3 | The two 3D endpoints `[x y z]` of each segment, in `ref`. **Not clipped** to the image border, so a segment at the edge can reach slightly outside the image. |
| `segmentsUV` | 1 x S cell, each 2 x 2 | The same segments as `[u v]` plane coordinates, **clipped** to the image rectangle. Physical units; convert to pixels with `col = u/du + 1`, `row = v/dv + 1`. |
| `segmentFaceIdx` | S x 1 | For each segment, the triangle (row of `meshCT.ConnectivityList`) that produced it. |
| `segmentFacingScore` | S x 1 | `dot(unit outward face normal, -plane.ey)`, the cosine of the angle to the probe direction. `+1` = faces the probe, `0` = parallel to the beam, `-1` = faces away. `NaN` for zero-area triangles. |
| `probeFacingSegmentMask` | S x 1 logical | `segmentFacingScore >= cosd(25)` (about `0.906`). Selects the three subsets below. |
| `probeFacingSegments3D` | cell, each 2 x 3 | `segments3D(probeFacingSegmentMask)`. |
| `probeFacingSegmentsUV` | cell, each 2 x 2 | `segmentsUV(probeFacingSegmentMask)`. |
| `probeFacingPixels` | M x 2 | `[row, col]` pixels drawn from the probe-facing segments only. There is no mask version of this field. |
| `timestamp` | scalar | Copy of `plane.timestamp`. |
| `isValid`, `status` | logical, char | `true` and `'Computed'` when the geometry was calculated. Otherwise `'Skipped: <reason>'`, for example an invalid plane or a missing bone pin in that CSV row. |

Notes:

- The segments are in mesh-face order, not contour order. Draw each segment separately, or order them first; joining them into one polyline gives zigzags.
- The outward normal direction is estimated from the mesh centroid. If the probe-facing subset looks empty or flipped for a bone, check this first.

Example overlay (green = probe-facing, red = other raw segments):

```matlab
s  = validSnapshots(1).data(1);
p  = s.plane;  in = s.intersection;
du = p.W / p.nCols;  dv = p.H / p.nRows;

figure; imshow(p.image.', []); hold on
for k = 1:numel(in.segmentsUV)
    uv = in.segmentsUV{k};
    c  = 'r'; if in.probeFacingSegmentMask(k), c = 'g'; end
    plot(uv(:,1)/du + 1, uv(:,2)/dv + 1, c, 'LineWidth', 1.5);
end
```

### 2. `validBonePoses`

```text
validBonePoses
+-- processingMode, poseHandlingMode, ctPostProcessedMatFile
+-- bonePoses(1..B)           one element per bone (femur, tibia)
    +-- bone, meshCT, T_bone_CT
    +-- data(1..P)            pose records                       (section 2.3)
    +-- baselineData          perDataRow export only
```

#### 2.1 Top level: `validBonePoses`

| Field | Type | Meaning |
| --- | --- | --- |
| `processingMode` | char | `static` or `kinematic`, derived from `poseHandlingMode`. |
| `poseHandlingMode` | char | The configured `bonePoseMode`: `average`, `first`, `last`, or `perDataRow`. |
| `ctPostProcessedMatFile` | char | Absolute path of the source CT MAT file. |
| `bonePoses` | 1 x B struct | One record per processed bone, see section 2.2. |

#### 2.2 Bone: `validBonePoses.bonePoses(b)`

| Field | Type | Meaning |
| --- | --- | --- |
| `bone` | char | `F` or `T`. Matches `validSnapshots(g).bone`. |
| `meshCT` | `triangulation` | Bone surface mesh in CT coordinates. Stored once per bone. |
| `T_bone_CT` | 4 x 4 | Anatomical-bone-frame to CT transform. |
| `data` | 1 x P struct | Pose records, see section 2.3. Static modes: exactly one record. `perDataRow`: one record per approved time row in the approved source groups. |
| `baselineData` | struct | `perDataRow` export only. Pose of CSV row 1, kept as visualization context; it is **not** an approved record. |

#### 2.3 Pose record: `validBonePoses.bonePoses(b).data(p)`

| Field | Type | Meaning |
| --- | --- | --- |
| `T_CT_ref` | 4 x 4 | CT-to-`ref` transform. Apply it to `meshCT.Points` to place the mesh in the same frame as the image planes. |
| `T_bone_ref` | 4 x 4 | Anatomical-bone-frame to `ref` transform. Do **not** apply it to mesh points. |
| `T_pin_ref` | 4 x 4 | Tracked bone-pin to `ref` transform. |
| `sourceIndex` | scalar | Raw row index in its source group. An averaged pose keeps the value of its template row. |
| `snapshotIndex`, `sequenceIndex` | scalar | Source-folder and MHA/CSV pair indices. |
| `packetIndex`, `rigidBodyRowIndex` | scalar | Coupled MHA packet and CSV row indices. |
| `rigidBodyTimestamp` | scalar | CSV timestamp, used by the `first` and `last` modes. |
| `sourceSampleCount` | scalar | Number of valid rows averaged (`average`), or `1` for a single row. |
| `isValid`, `status` | logical, char | Whether the pose is usable, and why not. |

To find the pose for a snapshot record: in static modes, take the single `data` record of the bone with the same `bone` code. In `perDataRow`, match `snapshotIndex`, `sequenceIndex`, and `rigidBodyRowIndex` with the plane's values.

## Common input problems

- Unequal MHA and CSV file counts, or independently sorted names that do not describe the same order.
- A static pair has anything other than one packet and one CSV row.
- A kinematic folder has multiple pairs, or its packet and CSV row counts differ.
- A CSV is missing `B_N_REF` or a rigid body implied by `pinSelection`.
- A source-folder name lacks `femur` or `tibia`.
- `bonePoseMode` does not match the acquisition layout.
- A configured input or output directory does not exist, or a configured filename has the wrong extension.
- A selected pin does not match CT `bonepins` or Qualisys names.
- A static dataset has no valid reference/pin pose for a bone.
- The fCal XML does not contain exactly one `ImageToProbe` transform.
- The CT MAT file does not contain both `bones` and `bonepins`.
