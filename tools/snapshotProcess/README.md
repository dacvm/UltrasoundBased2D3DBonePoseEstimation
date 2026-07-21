# Ultrasound Snapshot Processing

## Short summary

This MATLAB tool combines tracked ultrasound snapshots with CT-derived femur and tibia meshes. It places the ultrasound images and CT bones in the same reference coordinate system, calculates where each bone mesh crosses its ultrasound image plane, and opens an interactive browser for inspecting the results.

The recommended entry point is `extra_snapshotProcess_from_config.m`. It reads experiment paths and settings from `tools/snapshotProcess/configs/extra_snapshotProcess_config.json`. In review mode, the browser also lets the user select useful snapshots and export them to a MAT file for later processing. The export dialog starts in `tools/snapshotProcess/outputs/`.

The `legacy/extra_snapshotProcess.m` script is the older version with experiment-specific paths written directly in the MATLAB file. It is kept for reference, but the config-driven script is easier to reuse with a new dataset.

## Experiment setup

This workflow was developed for a knee-phantom flexion experiment. A similar setup can also be used with a cadaver leg. The experiment contains:

- Femur and tibia bone pins with optical marker rigid bodies.
- A fixed reference rigid body used as the common experiment coordinate frame.
- A tracked ultrasound probe.
- Ultrasound snapshots recorded near the femur and tibia.
- A CT scan of the bones, bone pins, and optical markers.

The ultrasound acquisition stores the image together with the tracked probe and reference poses in a Plus sequence image file. A matching Qualisys CSV file stores the reference and bone-pin rigid-body poses. Probe calibration from fCal connects ultrasound image coordinates to probe coordinates. The processed CT data connects each CT bone mesh to the corresponding bone-pin coordinate system.

The rigid-body names and coordinate-frame definitions used by Qualisys must match the definitions used when the CT data is prepared. If the marker order, pin name, axis direction, or handedness is different, the CT bones will not align correctly with the ultrasound images.

## Required input data

### Ultrasound snapshots and tracking data

Provide one root directory containing separate snapshot-group folders. Each folder name should contain `femur` or `tibia`, because the script uses this text to select the matching CT bone mesh. For example:

```text
measurement_02/
+-- femur_snapshot_01/
|   +-- snapshot_001.mha
|   +-- snapshot_001.csv
|   +-- snapshot_002.mha
|   +-- snapshot_002.csv
+-- tibia_snapshot_01/
    +-- snapshot_001.mha
    +-- snapshot_001.csv
```

Each snapshot-group folder must contain:

- One or more Plus sequence image files (`.mha`).
- The same number of Qualisys rigid-body snapshot files (`.csv`).

The script sorts the MHA and CSV filenames separately and pairs files at the same position. Use consistent filenames so both sorted lists describe the same acquisition order. Each CSV file must contain exactly one data row and every rigid body listed in `rigidBodyNamesToAverage`.

The standard Plus sequence file format is described in the [Plus File Sequence documentation](https://pluslib.readthedocs.io/en/latest/file-formats/FileSequenceFile.html).

### Ultrasound probe calibration

Provide an fCal/PLUS XML calibration file containing exactly one transform named `ImageToProbe`. The script uses this transform to place the ultrasound image relative to the tracked probe. The scale stored in this transform is also used to convert image pixels to physical image-plane dimensions.

### Post-processed CT scan data

Provide a MAT file containing variables named `bones` and `bonepins`. This file is produced by the sibling [Knee Phantom Processing tool](../ctkneePostProcess/README.md) in `tools/ctkneePostProcess/`.

Run the CT knee post-processing tool first if this MAT file is not available. Its output supplies:

- The femur and tibia CT meshes.
- The anatomical coordinate system of each bone.
- The CT-side coordinate system of each femur and tibia bone pin.

Use CT data from the same physical pin and marker setup as the ultrasound experiment. The selected femur and tibia pins must exist in both the CT output and the Qualisys tracking data.

### Snapshot configuration

Edit `tools/snapshotProcess/configs/extra_snapshotProcess_config.json`. It contains these settings:

| Setting | Meaning |
| --- | --- |
| `snapshotDirectory` | Root directory containing the femur and tibia snapshot-group folders. |
| `fcalConfigFile` | Path to the fCal XML calibration file. |
| `ctPostProcessedMatFile` | Path to the MAT file produced by `tools/ctkneePostProcess/`. |
| `pinSelection.F` | Femur pin location used in the experiment, such as `PRO`. |
| `pinSelection.T` | Tibia pin location used in the experiment, such as `DIS`. |
| `rigidBodyNamesToAverage` | Qualisys rigid bodies used to register the CT data to the experiment. |
| `displayMode` | Browser mode: `display` or `review`. |

`rigidBodyNamesToAverage` must include the fixed reference rigid body `B_N_REF` and the selected femur and tibia pin names. For example, femur pin `PRO` and tibia pin `DIS` require:

```json
"rigidBodyNamesToAverage": [
  "B_N_REF",
  "C_F_PRO",
  "C_T_DIS"
]
```

Configuration paths may be absolute or relative. Relative paths are resolved from the directory containing `extra_snapshotProcess_config.json`, not from MATLAB's current folder.

## Processing workflow

1. **Read and pair the snapshot files.** The script finds the femur and tibia snapshot-group folders, sorts their MHA and CSV files, checks that each MHA file has one CSV partner, and reads the ultrasound images and tracking data.

2. **Calibrate and place the ultrasound images.** The `ImageToProbe` transform from the fCal XML file connects each image to the tracked probe. The tracked probe and reference poses are then used to place every valid image plane in the reference coordinate system.

3. **Load the processed CT data.** The script loads the `bones` and `bonepins` structures created by the CT knee post-processing tool and selects the configured femur and tibia pins.

4. **Register the CT bones to the reference frame.** The configured Qualisys rigid-body measurements are averaged. The tracked bone-pin poses are matched with their CT-side pin poses so the femur and tibia meshes can be transformed from CT coordinates into the same reference frame as the ultrasound images.

5. **Calculate mesh-image intersections.** For each snapshot, the script intersects the correct bone mesh with the finite ultrasound image plane. It records the intersection pixels and keeps the mesh segments whose surface orientation faces the ultrasound probe.

6. **Display and review the results.** An interactive browser shows each ultrasound image, its intersection overlay, and the related 3D geometry. Review mode allows accepted snapshots to be selected and exported.

## Running the project

1. Prepare the ultrasound snapshot folders, fCal XML file, and post-processed CT MAT file.
2. Edit `tools/snapshotProcess/configs/extra_snapshotProcess_config.json` and set the paths, selected pins, rigid-body names, and display mode.
3. Start MATLAB. The script can be launched from any current folder because it locates the project and its `functions` directory from its own file path.
4. Run the recommended script:

   ```matlab
   run('tools/snapshotProcess/extra_snapshotProcess_from_config.m')
   ```

   If MATLAB is not currently in the project root, pass the absolute script path to `run` instead.

5. Follow the progress messages in the MATLAB Command Window and inspect the figures and final snapshot browser.

Set `displayMode` to `display` when the results only need to be inspected. Set it to `review` to mark acceptable snapshots and export them. In review mode, click **Export Selected** and choose an output filename when MATLAB asks. The save dialog starts in `tools/snapshotProcess/outputs/`. The exported MAT file contains a `validSnapshots` structure with the selected image planes and their mesh-intersection results.

The script adds the project `functions` directory and its subdirectories to the MATLAB path automatically.

## Output MAT-file structure

In `review` mode, the **Export Selected** button writes a MATLAB v7.3 MAT-file to the chosen location. The suggested destination is `tools/snapshotProcess/outputs/`, and the default filename follows `validSnapshots_yyyyMMdd_HHmmss.mat`.

The file contains one variable named `validSnapshots`. It is a struct array with one element for each snapshot selected as valid in the browser:

```text
validSnapshots(1..N)
+-- sourceIndex
+-- plane
|   +-- p0, ex, ey, n, W, H
|   +-- nRows, nCols, image
|   +-- timestamp, bone, snapshotName
|   +-- snapshotIndex, sequenceIndex, packetIndex
+-- intersection
    +-- mask, pixelList
    +-- segments3D, segmentsUV, segmentFaceIdx
    +-- probeFacingSegmentMask
    +-- probeFacingSegments3D, probeFacingSegmentsUV
    +-- probeFacingPixels, segmentFacingScore
    +-- timestamp, status
```

Load the output with:

```matlab
loadedOutput = load('validSnapshots_yyyyMMdd_HHmmss.mat', 'validSnapshots');
validSnapshots = loadedOutput.validSnapshots;
```

### Fields in each selected snapshot

| Field | Explanation |
| --- | --- |
| `sourceIndex` | Index of this result in the complete `snapshotPlanes` and `intersections` arrays before the browser selection is applied. It can be used to trace an exported item back to the original processing result. |
| `plane` | Struct containing the ultrasound image, its finite-plane geometry, and source metadata. |
| `intersection` | Struct containing the raw mesh-plane intersection and the subset produced by probe-facing mesh faces. |

### Fields in `plane`

| Field | Explanation |
| --- | --- |
| `p0` | 3D position of the image plane's top-left corner in the common reference coordinate system. |
| `ex` | 3D unit direction in which image column numbers increase. |
| `ey` | 3D unit direction in which image row numbers increase. |
| `n` | 3D normal direction of the image plane. |
| `W` | Physical width of the image plane. Its unit follows the calibration and mesh coordinate units. |
| `H` | Physical height of the image plane. Its unit follows the calibration and mesh coordinate units. |
| `nRows` | Number of rows in `image`. |
| `nCols` | Number of columns in `image`. |
| `image` | Ultrasound image pixel array for this plane. |
| `timestamp` | Acquisition timestamp read from the source ultrasound packet. |
| `bone` | Bone code assigned from the snapshot folder name: `F` for femur, `T` for tibia, or `U` when unknown. |
| `snapshotName` | Name of the source snapshot-group folder. |
| `snapshotIndex` | Position of that snapshot group in the script's sorted snapshot-directory list. |
| `sequenceIndex` | Position of the source MHA sequence within its snapshot group. |
| `packetIndex` | Position of the source image packet within its MHA sequence. |

The plane uses the parameterization `x = p0 + u*ex + v*ey`, with `0 <= u <= W` and `0 <= v <= H`.

### Fields in `intersection`

| Field | Explanation |
| --- | --- |
| `mask` | `nRows`-by-`nCols` logical mask. A true pixel is touched by the rasterized raw mesh-plane intersection. |
| `pixelList` | K-by-2 array of raw intersection pixels stored as `[row, column]`. |
| `segments3D` | Cell array of raw intersection segments. Each cell contains a 2-by-3 array holding the two segment endpoints in the common 3D reference coordinate system. |
| `segmentsUV` | Cell array aligned with `segments3D`. Each cell contains a 2-by-2 array of `[u, v]` endpoints clipped to the finite image plane. |
| `segmentFaceIdx` | Numeric vector aligned with the raw segment arrays. Each value is the mesh-face index that produced that segment. |
| `probeFacingSegmentMask` | Logical vector aligned with the raw segments. A true value marks a segment whose source mesh face passes the probe-facing angle test. |
| `probeFacingSegments3D` | Subset of `segments3D` that passes the probe-facing test. |
| `probeFacingSegmentsUV` | Corresponding subset of `segmentsUV` that passes the probe-facing test. |
| `probeFacingPixels` | P-by-2 array of `[row, column]` pixels rasterized from the probe-facing segments. |
| `segmentFacingScore` | Score for every raw segment, calculated as the dot product of its mesh-face normal with `-plane.ey`. Larger values point more strongly in the selected probe-facing direction. |
| `timestamp` | Copy of the source ultrasound image timestamp, included to keep the intersection linked to its plane. |
| `status` | Processing result text, normally `Computed`; skipped records contain a message explaining why no intersection was calculated. |

The raw fields retain every finite mesh-plane intersection. The `probeFacing...` fields retain only the surface-facing subset used for the filtered overlay. Empty arrays or cell arrays mean that no matching intersection was found. The output does not include the complete bone mesh; it contains only the geometry needed for each selected snapshot.

## Common input problems

- A snapshot folder contains different numbers of MHA and CSV files.
- The sorted MHA and CSV filenames do not represent the same acquisition order.
- A CSV file contains more than one row or is missing a configured rigid body.
- A snapshot-group folder name does not contain `femur` or `tibia`.
- A selected pin name does not match the CT `bonepins` data or the Qualisys rigid-body name.
- The fCal XML file does not contain exactly one `ImageToProbe` transform.
- The CT MAT file does not contain both `bones` and `bonepins`.
