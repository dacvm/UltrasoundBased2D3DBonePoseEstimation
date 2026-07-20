# Knee Phantom Processing

## Short summary

This MATLAB project preprocesses CT-derived 3D meshes from a cadaver-leg or knee-phantom experiment. It estimates the centers of optical markers, defines the rigid bodies attached to the femur and tibia bone pins, loads the anatomical coordinate systems (ACS), stores the results in MATLAB structures, and displays all geometry and coordinate systems in the CT coordinate frame.

The recommended entry point is `preprocess_markerstls_from_config.m`. It reads the input paths and filenames from `config/preprocess_markerstls_config.json` and exports a MAT file, MATLAB FIG file, and PNG image. `preprocess_markerstls.m` is the older script with paths configured directly in the MATLAB file.

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

The exact files and their roles are configured in `config/preprocess_markerstls_config.json`.

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

1. Edit `config/preprocess_markerstls_config.json` and set the marker directory, bone directory, filenames, ACS MAT filename, and output directory.
2. Run the recommended script from MATLAB:

   ```matlab
   run('preprocess_markerstls_from_config.m')
   ```

3. Inspect the generated MAT, FIG, and PNG files. Relative paths in the JSON are resolved relative to the `config` directory; therefore, the example output directory `outputs` writes to `config/outputs`. Use `../outputs` if the output should be placed in the project-root `outputs` directory.

The scripts add the `functions` directory and its subdirectories to the MATLAB path automatically. The workflow uses MATLAB mesh and point-cloud functionality, including `stlread`, `pointCloud`, and `pcfitsphere`.
