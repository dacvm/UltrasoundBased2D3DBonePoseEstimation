# CT Knee Post-Processing Tool

This MATLAB tool preprocesses CT-derived femur, tibia, and optical-marker
meshes. It estimates the bone-pin rigid-body frames, combines them with
precomputed anatomical coordinate systems, and writes data used by the main
bone-pose workflow.

## Supported entry point

Edit `config/preprocess_markerstls_config.json` in the repository root, then
run:

```matlab
run('tools/ctkneePostProcess/preprocess_markerstls_from_config.m')
```

The script locates the repository from its own file path, so it can also be
run from the MATLAB editor when another folder is current.

The configured inputs are eight marker STL meshes, femur and tibia STL
meshes, and a MAT file containing an `acs` structure. The workflow requires
MATLAB functionality for STL meshes, `pointCloud`, and `pcfitsphere`.

Generated MAT, FIG, and PNG files are written to
`output/ctkneePostProcess/` by the provided configuration. The `output/`
folder is ignored by Git.

## Shared functions

The tool intentionally uses the parent project's shared functions instead
of keeping duplicate copies:

- `functions/geometry/estimateRBfrom3Points_v2.m` defines each bone-pin
  frame from four marker centers.
- `functions/display/display_axis_v2.m` draws the bone-pin and anatomical
  coordinate axes.

The ERC knee-frame source under `functions/external/ERCkneeFrames/` is
third-party code. Do not modify it. The supported preprocessing entry point
loads a precomputed ACS MAT file and does not run that external code.

## Legacy script

`legacy/preprocess_markerstls.m` preserves the former hard-coded workflow
for reference. It is not the supported entry point and still contains
dataset-specific absolute paths.
