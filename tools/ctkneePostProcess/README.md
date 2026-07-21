# Knee Phantom Processing

## Short summary

This MATLAB project preprocesses CT-derived 3D meshes from a cadaver-leg or knee-phantom experiment. It estimates the centers of optical markers, defines the rigid bodies attached to the femur and tibia bone pins, loads the anatomical coordinate systems (ACS), stores the results in MATLAB structures, and displays all geometry and coordinate systems in the CT coordinate frame.

The recommended entry point is `preprocess_markerstls_from_config.m`. It reads the input paths and filenames from `tools/ctkneePostProcess/configs/preprocess_markerstls_config.json` and exports a MAT file, MATLAB FIG file, and PNG image to `tools/ctkneePostProcess/outputs/` by default. `preprocess_markerstls.m` is the older script with paths configured directly in the MATLAB file.

## Experiment setup

The workflow is intended for a cadaver leg or knee phantom containing:

- Femur and tibia bone pins.
- Optical markers mounted on the bone pins for motion capture.
- A CT scan of the complete setup, from which the bone and marker meshes are exported as STL files.

The CT meshes provide the reference geometry and marker locations. The same physical marker arrangement must later be recognized consistently by the optical motion-capture system.

## Required input data

### Marker meshes

Provide four spherical marker STL meshes for each bone pin. The example configuration uses:

```text
C_F_PRO_1.stl ... C_F_PRO_4.stl   % Femur pin
C_T_DIS_1.stl ... C_T_DIS_4.stl   % Tibia pin
```

The marker numbers have fixed meanings:

| Marker | Meaning in the rigid body |
| --- | --- |
| 1 | Origin of the rigid-body frame |
| 2 | Reference marker for the local X axis |
| 3 | Reference marker for the local Y axis |
| 4 | Additional marker retained for checking and diagnostics |

The exact files and their roles are configured in `tools/ctkneePostProcess/configs/preprocess_markerstls_config.json`.

### Bone meshes

Provide CT-derived STL meshes for the femur and tibia, for example:

```text
Femur_1_Smoothed_Reduced.stl
Tibia_1_Smoothed_Reduced.stl
```

The filenames and bone directory are configured in the JSON file.

### Anatomical coordinate systems (ACS)

Provide a MAT file containing one variable named `acs`. The preprocessing script expects at least:

```matlab
acs.f.R
acs.f.origin
acs.t.R
acs.t.origin
```

Here `f` is the femur and `t` is the tibia. Each `R` is a 3-by-3 rotation matrix and each `origin` contains three coordinates. The source ERC code stores the axes row-wise; this project transposes the rotations when building the column-wise 4-by-4 transforms used for display and later processing.

The ACS implementation and its supporting documentation are in `functions/ERCkneeFrames/`. This is the current repository folder corresponding to the sometimes-referenced `function/ERCframeKnee` directory. The preprocessing entry point loads a precomputed ACS MAT file; it does not calculate the ACS during the marker-processing run. To generate or review the ACS definition, start with `ERCkneeReferenceFrames.m`, the `ERCrefFrameFemur.m` and `ERCrefFrameTibia.m` help text, and `ERC knee reference frame documentation.pdf`.

## Processing workflow

1. **Load marker meshes, fit spheres, and find centroids.** Each marker STL is read with `stlread`. Its vertices are converted to a point cloud and fitted with `pcfitsphere`. The fitted sphere center is used as the marker centroid.

2. **Define the bone-pin rigid bodies.** The four centroids for each pin are arranged in the fixed marker order and passed to `functions/geometry/estimateRBfrom3Points_v2.m`. The function creates a right-handed 4-by-4 transform: marker 1 is the origin, marker 2 contributes the X direction, marker 3 contributes the Y direction, and marker 4 is kept as an additional diagnostic point.

3. **Load bone meshes and ACS data.** The femur and tibia STL meshes are loaded. The ACS MAT file is read, and each ACS is converted into a transform named `T_bone_CT` that contains the ACS origin and axes in CT coordinates.

4. **Store the processed data in structures.** The main structures are:

   - `markerstls`: one record per marker, containing its name, source path, STL mesh, point cloud, fitted sphere, radius, fitting error, and centroid. The config-driven script also stores the bone-pin index and marker number.
   - `bonepins`: one record per bone pin, containing its identity, marker names and paths, marker centroids, rigid-body transform, origin, rotation axes, and `T_pin_CT`.
   - `bones`: one record per bone, containing its identity, source path, STL mesh, and `T_bone_CT`.

   The config-driven script saves `bones` and `bonepins` to the MAT output. Marker centroids and marker provenance remain available inside `bonepins`; the full `markerstls` mesh records are used during the run but are not exported by that script.

5. **Display the result.** A shared 3D figure shows the marker meshes, fitted spheres, marker centroids, bone-pin rigid-body axes, bone meshes, and femur/tibia ACS axes. The config-driven script saves the figure as `.fig` and `.png` in addition to the processed `.mat` file.

## Rigid-body definition and motion capture

The rigid-body frame is defined by the physical arrangement and numbering of the four markers. Marker 1 fixes the origin; markers 2 and 3 define the local X and Y directions; the local Z direction is computed to complete a right-handed orthonormal frame. Marker 4 is not used to define the axes directly, but is retained for consistency checks.

This definition must be identical in the user's motion-capture system. The marker labels, marker order, origin, axis directions, and handedness all need to match the CT-side definition. If the motion-capture software uses a different marker order or frame orientation, the resulting bone-pose transforms will not be compatible with the CT reference transforms.

## Running the project

1. Edit `tools/ctkneePostProcess/configs/preprocess_markerstls_config.json` and set the marker directory, bone directory, filenames, ACS MAT filename, and output directory.
2. Run the recommended script from MATLAB:

   ```matlab
   run('tools/ctkneePostProcess/preprocess_markerstls_from_config.m')
   ```

3. Inspect the generated MAT, FIG, and PNG files in `tools/ctkneePostProcess/outputs/`. Relative paths in the JSON are resolved from `tools/ctkneePostProcess/configs/`; therefore, the default `../outputs` setting selects the tool-local output folder.

The scripts add the `functions` directory and its subdirectories to the MATLAB path automatically. The workflow uses MATLAB mesh and point-cloud functionality, including `stlread`, `pointCloud`, and `pcfitsphere`.

## Output MAT-file structure

The script writes a MATLAB v7.3 MAT-file to the configured `output.directory`. With the supplied configuration, the output is `tools/ctkneePostProcess/outputs/kneephantom_bones_and_bonepins.mat`; the filename comes from `output.base_name`.

The MAT-file contains two struct arrays:

```text
bones(1..N)
+-- name
+-- bone
+-- path
+-- mesh
+-- T_bone_CT

bonepins(1..M)
+-- name
+-- bone
+-- place
+-- marker_indices
+-- marker_names
+-- marker_paths
+-- marker_centroids
+-- transform
+-- origin
+-- base_axes
+-- T_pin_CT
```

Load the output with:

```matlab
processedCT = load('kneephantom_bones_and_bonepins.mat', ...
    'bones', 'bonepins');
bones = processedCT.bones;
bonepins = processedCT.bonepins;
```

### Fields in `bones`

Each element represents one processed bone, normally the femur or tibia.

| Field | Explanation |
| --- | --- |
| `name` | Human-readable bone name from the configuration, such as `Femur` or `Tibia`. |
| `bone` | Short bone code: `F` for femur or `T` for tibia. This code is also used to match bones with bone pins in later processing. |
| `path` | Absolute path of the source bone STL file. It is retained for provenance and input checks. |
| `mesh` | MATLAB `triangulation` object loaded from the STL file. Its `Points` property contains the CT-space vertices, and `ConnectivityList` contains the triangular faces. |
| `T_bone_CT` | 4-by-4 homogeneous transform describing the bone anatomical coordinate system in CT coordinates. The first three columns are the local bone axes expressed in CT coordinates, and the fourth column is the ACS origin. |

### Fields in `bonepins`

Each element represents one bone-pin rigid body constructed from four spherical marker centroids.

| Field | Explanation |
| --- | --- |
| `name` | Rigid-body name, such as `C_F_PRO` or `C_T_DIS`. This should match the corresponding rigid-body name used by the motion-capture system. |
| `bone` | Code of the attached bone: `F` for femur or `T` for tibia. |
| `place` | Configured pin placement label, such as `PRO` for proximal or `DIS` for distal. |
| `marker_indices` | Indices of the four markers in the processing-time `markerstls` array, in marker-number order. The `markerstls` array itself is not included in the MAT-file. |
| `marker_names` | 1-by-4 cell array containing the configured marker names in the fixed order marker 1 through marker 4. |
| `marker_paths` | 1-by-4 cell array containing the absolute source STL path for each marker. |
| `marker_centroids` | 3-by-4 matrix of fitted marker centers in CT coordinates. Each column corresponds to the same position in `marker_names` and `marker_paths`. |
| `transform` | 4-by-4 bone-pin rigid-body transform calculated from markers 1, 2, and 3. This is the same matrix stored in `T_pin_CT` and is retained for compatibility with existing code. |
| `origin` | 3-by-1 position of the bone-pin origin in CT coordinates. It is marker 1's fitted centroid and equals `T_pin_CT(1:3,4)`. |
| `base_axes` | 3-by-3 rotation matrix whose columns are the bone-pin frame's local X, Y, and Z axes expressed in CT coordinates. It equals `T_pin_CT(1:3,1:3)`. |
| `T_pin_CT` | 4-by-4 homogeneous transform describing the bone-pin frame in CT coordinates. It maps points from local pin coordinates into CT coordinates. |

For each bone pin, marker 1 defines the origin, marker 3 defines the Y direction, and the part of the marker 1-to-2 direction perpendicular to Y defines X. Z completes a right-handed frame. Marker 4 is retained as provenance and for consistency checks but does not define the exported transform.

All mesh points, centroids, transform translations, and ACS origins use the coordinate unit of the source CT/STL data. The MAT-file does not contain the internal `markerstls` array, fitted sphere objects, or point clouds. Those values are used during processing and visualization; the exported `marker_names`, `marker_paths`, and `marker_centroids` preserve the marker information needed by later workflows.
