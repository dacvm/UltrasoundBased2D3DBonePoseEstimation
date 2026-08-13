# Tools

This directory contains MATLAB tools for preparing CT and tracked ultrasound data for the bone-pose optimization workflow. Each tool has its own README with detailed setup, configuration, usage, and output information.

## Tool Overview

- [`ctkneePostProcess`](ctkneePostProcess/README.md) prepares the CT reference model by combining bone meshes, anatomical coordinate systems, and bone-pin marker geometry.
- [`ultrasoundSpatialProcessing`](ultrasoundSpatialProcessing/README.md) places tracked ultrasound images and CT bone models in a shared reference frame, computes mesh-image intersections, and supports snapshot review and selection.
- [`boneSegmentationProcess`](boneSegmentationProcess/README.md) segments bone responses in selected ultrasound images, extracts thin bone-surface curves, and recovers those surfaces as 3D points in the reference frame.
- [`bonePreRegistration`](bonePreRegistration/README.md) measures CT landmarks and uses the recovered ultrasound surfaces to estimate a coarse initial pose for each bone before optimization.

These tools are generally used in the order listed above because the output of each stage provides input for a later stage.
