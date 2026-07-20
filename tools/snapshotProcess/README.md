# Ultrasound Snapshot Processing Tool

This MATLAB tool places tracked ultrasound snapshots and CT bone meshes in
the same coordinate system. It then calculates where the femur or tibia mesh
crosses each ultrasound image and opens a browser for viewing the results.
In review mode, a user can select good snapshots and export them to a MAT
file for later processing.

## Experiment context

This tool was made for a knee-phantom flexion experiment. During the
experiment, ultrasound snapshots were recorded near the femur and tibia.
The ultrasound probe, a fixed reference rigid body, and rigid bodies attached
to bone pins were tracked during acquisition.

The different measurements provide complementary information:

- The ultrasound MHA files contain the images and the tracked probe and
  reference poses.
- The matching Qualisys CSV files contain the tracked reference and bone-pin
  rigid bodies.
- The fCal XML file describes the calibration from ultrasound image
  coordinates to probe coordinates.
- The post-processed CT data contains the femur and tibia meshes, anatomical
  coordinate systems, and bone-pin coordinate systems.

Together, these inputs allow the CT bones and ultrasound images to be shown
in one reference frame.

## Supported script

The supported entry point is:

`extra_snapshotProcess_from_config.m`

Its experiment-specific paths and settings are stored in:

`config/extra_snapshotProcess_config.json`

The script finds the project root from its own location. It therefore does
not depend on MATLAB's current folder when it is started from the editor or
with an absolute path.

The `legacy/extra_snapshotProcess.m` script keeps the older hardcoded
workflow for reference. It contains dataset-specific paths and is not the
recommended entry point for a new experiment.

## Required data

### 1. Ultrasound snapshot folders

Set `snapshotDirectory` to a directory containing one or more snapshot-group
folders. A folder name should contain `femur` or `tibia` so the script can
choose the correct CT mesh.

Each snapshot-group folder must contain:

- One or more Plus sequence image files (`.mha`).
- The same number of Qualisys rigid-body snapshot files (`.csv`).

The script sorts the MHA and CSV filenames and pairs them in that order.
Use consistent names so the sorted files describe the same acquisitions.
Each CSV file must contain exactly one data row and all rigid bodies listed
in `rigidBodyNamesToAverage`.

### 2. Ultrasound probe calibration

Set `fcalConfigFile` to an fCal/PLUS XML calibration file. The file must
contain exactly one transform named `ImageToProbe`. The script uses this
transform to place every ultrasound image relative to the tracked probe.

### 3. Post-processed CT scan data

Set `ctPostProcessedMatFile` to a MAT file containing variables named
`bones` and `bonepins`. This file is produced by the sibling
[CT Knee Post-Processing Tool](../ctkneePostProcess/README.md).

Run that tool first if the post-processed CT MAT file is not available yet.

### 4. Snapshot configuration

Edit `config/extra_snapshotProcess_config.json` and check these settings:

- `snapshotDirectory`: Snapshot-group root directory.
- `fcalConfigFile`: fCal XML calibration file.
- `ctPostProcessedMatFile`: Post-processed CT MAT file.
- `pinSelection.F`: Femur pin location used in the experiment.
- `pinSelection.T`: Tibia pin location used in the experiment.
- `rigidBodyNamesToAverage`: Qualisys rigid bodies used for registration.
  This list must include `B_N_REF` and the selected femur and tibia pin
  names, such as `C_F_PRO` and `C_T_DIS`.
- `displayMode`: Use `display` to browse results only, or `review` to select
  snapshots and export them.

Paths may be absolute or relative. A relative path is resolved from the
directory containing the JSON configuration file.

## Processing workflow

The script performs these main steps:

1. It reads and pairs the MHA ultrasound snapshots and Qualisys CSV files.
2. It reads the `ImageToProbe` calibration from the fCal XML file.
3. It transforms every valid ultrasound image into the tracked reference
   coordinate system.
4. It loads the post-processed CT bone and bone-pin data.
5. It averages the configured Qualisys rigid-body measurements and uses the
   selected bone pins to place the femur and tibia in the same reference
   coordinate system as the ultrasound images.
6. It calculates the intersection between the appropriate CT mesh and each
   ultrasound image plane. It also keeps mesh segments that face the probe.
7. It opens an interactive browser showing the ultrasound image, the
   intersection overlay, and the related 3D scene.

## How to run

1. Prepare the required snapshot, calibration, and post-processed CT data.
2. Open `config/extra_snapshotProcess_config.json` and update its paths and
   settings for the experiment.
3. Start MATLAB and change to the repository root.
4. Run:

```matlab
run('tools/snapshotProcess/extra_snapshotProcess_from_config.m')
```

The script prints progress in the MATLAB Command Window and opens figures
while it processes the data.

If `displayMode` is `review`, mark the acceptable rows in the final browser
and click **Export Selected**. Choose a destination when MATLAB asks where
to save the MAT file. The saved file contains a `validSnapshots` structure
with the selected image planes and their intersection results.

If `displayMode` is `display`, the browser is read-only and no MAT file is
exported.

## Common input problems

- A snapshot folder has a different number of MHA and CSV files.
- Sorted MHA and CSV filenames do not represent the same acquisition order.
- A CSV file is missing a configured rigid body or contains more than one
  data row.
- A snapshot-group folder name does not contain `femur` or `tibia`.
- The selected pin names do not match the CT `bonepins` data and the
  Qualisys rigid-body names.
- The fCal XML file does not contain exactly one `ImageToProbe` transform.
- The CT MAT file does not contain both `bones` and `bonepins`.
