# Bone Segmentation Process

## Short Summary

This MATLAB tool continues the workflow in [`tools/ultrasoundSpatialProcessing`](../ultrasoundSpatialProcessing/README.md). The spatial-processing tool prepares selected, tracked ultrasound images; this tool then segments the bone response in each B-mode image and extracts a thin bone-surface curve. These results provide the image-space bone surface information needed to obtain the bone surface in 3D from the tracked ultrasound data.

The workflow has two consecutive parts:

1. `boneSegmentation_semiAutomatic.m` interactively segments likely bone regions and exports their boundary pixels.
2. `boneSegmentation_extractSurface.m` selects a stable, probe-facing thin surface from those boundary candidates and saves confidence and quality information.

## Experiment Setup

Refer to [`tools/ultrasoundSpatialProcessing`](../ultrasoundSpatialProcessing/README.md) for the experiment setup, calibration, coordinate frames, tracking data, ultrasound acquisition, and preparation of the selected snapshot MAT-file used here.

<hr style="border: 0; border-top: 5px solid #333; margin: 2.5em 0;">

# (Part 1) Bone Segmentation

## Required Input Data

Part 1 requires the MAT-file exported by `tools/ultrasoundSpatialProcessing` in review mode. The file normally follows this naming pattern:

```text
validSnapshots_yyyyMMdd_HHmmss.mat
```

The MAT-file must contain exactly one variable. The expected variable is normally `validSnapshots`, with source-directory groups containing `name`, `bone`, `path`, and `data`. Each `data` record must provide the ultrasound image and plane information used by the segmentation interface.

Edit `tools/boneSegmentationProcess/configs/boneSegmentation_semiAutomatic.json`:

| Setting | Meaning |
| --- | --- |
| `input.ultrasoundImageFilePath` | Directory containing the selected ultrasound snapshot MAT-file. |
| `input.ultrasoundImageFileName` | MAT-file name only, including the `.mat` extension. |
| `output.segmentationOutputPath` | Directory suggested when the segmentation results are exported. |

Paths may be absolute or relative. Relative paths are resolved from the directory containing the JSON file. The output directory is created automatically when it does not exist.

## Processing Workflow

1. **Load the selected ultrasound images.** The script validates the JSON settings and loads the single variable from the configured MAT-file.
2. **Open the segmentation interface.** Images remain grouped by their source directory and can be selected from the tabbed tables.
3. **Adjust preprocessing.** Tune brightness and contrast while checking the live image preview.
4. **Select the foreground.** Set the intensity threshold manually or use **Auto threshold (Otsu)**. Use **Draw area** when segmentation should be limited to a region of interest, or **Use full image** to remove that limit.
5. **Clean the mask.** Adjust the opening radius, closing radius, and minimum connected-region area to remove noise and join nearby bone responses.
6. **Apply and review the settings.** Move through the images with **Previous** and **Next**. **Apply to Tab** reprocesses the active source group, while **Apply to All** reprocesses every image with the current settings.
7. **Export the segmentation.** Click **Export segmentation results**. Unprocessed images may still be exported, but they are clearly marked as `unprocessed` and contain empty boundary coordinates.

The final segmentation mask contains pixels that pass preprocessing, thresholding, morphology, hole filling, small-region removal, and the optional user-drawn area. `pixelCoordinates` stores the perimeter of that final mask as MATLAB 1-based `[row, column]` coordinates.

## Running the Project

1. Complete the snapshot selection workflow in `tools/ultrasoundSpatialProcessing`.
2. Set the input MAT-file and output directory in `tools/boneSegmentationProcess/configs/boneSegmentation_semiAutomatic.json`.
3. Start MATLAB and run:

   ```matlab
   run('tools/boneSegmentationProcess/boneSegmentation_semiAutomatic.m')
   ```

   If MATLAB is not currently in the project root, pass the absolute script path to `run`.

4. Review and process the images in the segmentation interface.
5. Click **Export segmentation results** and save the MAT-file. The default filename is:

   ```text
   boneSegmentation_yyyyMMdd_HHmmss.mat
   ```

The script locates the project `functions` directory from its own path, so it does not depend on MATLAB's current folder. Because the script requests the exported result as an output, MATLAB waits until the first successful export or until the interface is closed.

## Output Structure

The exported MATLAB v7.3 MAT-file contains one variable named `segmentationResults`. It preserves the source-directory grouping and acquisition order of the input:

```text
segmentationResults(1..G)
+-- name
+-- bone
+-- path
+-- data(1..N)
    +-- sequencePosition
    +-- sourceIndex
    +-- pixelCoordinates
    +-- segmentationMask
    +-- segmentationAreaMask
    +-- usesCustomSegmentationArea
    +-- processingParameters
    +-- status
```

| Field | Explanation |
| --- | --- |
| `name`, `bone`, `path` | Identify the source group from which the images came. `name` is the source-directory name, `bone` is its bone code, and `path` is the original source directory. These fields keep results from different acquisitions or bones separate. |
| `sequencePosition` | One-based position of the image inside this output group's `data` array. It describes output order and is not necessarily the image's original acquisition index. |
| `sourceIndex` | Index copied from the matching ultrasound record. Use it together with the group metadata to find the exact source image used for this segmentation; the same value may occur in another group. |
| `pixelCoordinates` | N-by-2 list of pixels on the outside edge of the final segmented regions, stored as MATLAB 1-based `[row, column]`. These boundary pixels, rather than every filled foreground pixel, are the candidate locations used by Part 2. The array is empty when no boundary was found or the image was not processed. |
| `segmentationMask` | Image-sized logical array describing the complete filled segmentation. A `true` pixel was classified as foreground after thresholding, morphology, hole filling, small-region removal, and the optional area restriction; `false` means background. |
| `segmentationAreaMask` | Image-sized logical array describing where segmentation was allowed. Pixels outside a user-drawn area are `false` and cannot appear in `segmentationMask`; when the full image is used, every value is `true`. |
| `usesCustomSegmentationArea` | `true` when the user restricted this image with **Draw area**, and `false` when the complete image was processed. This makes it possible to distinguish an intentional region-of-interest restriction from an unrestricted result. |
| `processingParameters` | Exact settings used to create this image's result. `brightness` and `contrast` modify intensity before segmentation; `threshold` separates foreground from background; `openingRadius` removes small bright details; `closingRadius` joins nearby regions; `minimumRegionArea` removes smaller connected regions; and `fillHoles` records the always-enabled hole-filling step. |
| `status` | `processed` means a result was committed for the image, even if the final mask is empty. `unprocessed` means the image had not been accepted or batch-processed when export occurred, so its coordinates are empty and its masks contain safe default values. |

Load the result with:

```matlab
loadedSegmentation = load('boneSegmentation_yyyyMMdd_HHmmss.mat', ...
    'segmentationResults');
segmentationResults = loadedSegmentation.segmentationResults;
```

## Common Input Problems

- The configured ultrasound MAT-file does not exist at the resolved path.
- The ultrasound MAT-file contains zero variables or more than one variable.
- `input.ultrasoundImageFileName` contains a directory instead of only a `.mat` filename.
- A relative path was written as though it were relative to the project root; relative configuration paths are resolved from the `configs` directory.
- The selected snapshot structure does not contain the expected grouped image and plane data.
- Images are exported before they are reviewed, leaving records marked as `unprocessed`.
- Threshold or morphology settings retain multiple unrelated bright regions; draw a smaller area or adjust the processing controls before exporting.

<hr style="border: 0; border-top: 5px solid #333; margin: 2.5em 0;">

# (Part 2) Bone Surface Extraction

## Required Input Data

Part 2 requires three inputs:

- The MAT-file produced by Bone Segmentation (from Part 1), containing the variable `segmentationResults`.
- The same selected ultrasound snapshot MAT-file used for Bone Segmentation (from Part 1). It must contain exactly one variable.
- The algorithm configuration file `tools/boneSegmentationProcess/configs/boneSurfaceExtraction.json`.

Edit `tools/boneSegmentationProcess/configs/boneSegmentation_extractSurface.json` to select these inputs and the output location:

| Setting | Meaning |
| --- | --- |
| `input.segmentationFilePath` | Directory containing the MAT-file produced by Bone Segmentation (from Part 1). |
| `input.segmentationFileName` | Segmentation MAT-file name only. |
| `input.ultrasoundSequenceFilePath` | Directory containing the matching selected ultrasound MAT-file. |
| `input.ultrasoundSequenceFileName` | Ultrasound MAT-file name only. |
| `input.configurationFilePath` | Directory containing the extraction algorithm JSON file. |
| `input.configurationFileName` | Extraction algorithm JSON filename only. |
| `output.boneSurfaceOutputPath` | Directory in which the extracted surface MAT-file is saved. |

The algorithm JSON groups its settings into `imageEvidence`, `surfaceTracing`, `gapInterpolation`, and `regularization`. These settings control image smoothing and evidence scoring, continuity-based surface selection, short-gap interpolation, and bounded curve regularization. Relative paths are resolved from the workflow JSON directory.

## Processing Workflow

1. **Load and match the inputs.** The script loads `segmentationResults`, loads the matching ultrasound sequence, and matches groups by metadata and records by `sourceIndex`.
2. **Build surface candidates.** Only exported `pixelCoordinates` are treated as candidate bone-surface locations. The filled `segmentationMask` is retained for documentation but is not used as extraction evidence.
3. **Score image evidence.** Candidate coordinates are scored from the matching B-mode image using local axial gradient, bright reflection, and acoustic-shadow evidence.
4. **Trace a consistent surface.** Dynamic programming selects a laterally consistent probe-facing path when multiple boundary candidates occur in the same image column.
5. **Filter and bridge segments.** Short or weak segments are rejected. Accepted short gaps can be interpolated with the configured method.
6. **Regularize the curve.** Optional bounded regularization reduces pixel-scale roughness while limiting how far the final curve may move from the image-supported path.
7. **Save and review.** The script saves `surfaceResults` and `extractionMetadata`, then opens an interactive review interface showing the ultrasound image, segmentation overlay, observed surface points, interpolated points, and extraction settings.

Records left unprocessed during Bone Segmentation (from Part 1) are preserved with status `skippedUnprocessed`. A processed record with no candidate coordinates is preserved with status `noSurface`.

## Running the Project

1. Export the results from Bone Segmentation (from Part 1).
2. Set the segmentation file, matching ultrasound file, extraction settings file, and output directory in `tools/boneSegmentationProcess/configs/boneSegmentation_extractSurface.json`.
3. Review algorithm parameters in `tools/boneSegmentationProcess/configs/boneSurfaceExtraction.json`.
4. Start MATLAB and run:

   ```matlab
   run('tools/boneSegmentationProcess/boneSegmentation_extractSurface.m')
   ```

   If MATLAB is not currently in the project root, pass the absolute script path to `run`.

5. Read the saved file path in the MATLAB Command Window and inspect the interactive review interface.

The output is saved automatically before the review interface opens. Its default filename is:

```text
boneSurface_yyyyMMdd_HHmmss.mat
```

## Output Structure

The MATLAB v7.3 output contains `surfaceResults` and `extractionMetadata`:

```text
surfaceResults(1..G)
+-- name
+-- bone
+-- path
+-- data(1..N)
    +-- sequencePosition, sourceIndex, status
    +-- surfaceCoordinatesXY
    +-- surfaceCoordinatesXYZRef
    +-- surfaceRowByColumn, rawSurfaceRowByColumn
    +-- observedColumnMask, interpolatedColumnMask
    +-- segmentIdByColumn
    +-- confidenceByColumn, rawConfidenceByColumn
    +-- regularization diagnostics
    +-- pixelSpacingXYMm
    +-- observedLengthMm, interpolatedLengthMm
    +-- meanConfidence, numberOfSegments

extractionMetadata
+-- algorithm name, version, and creation time
+-- coordinate and candidate conventions
+-- resolvedConfiguration
+-- status counts and frame totals
+-- source and output file paths
```

Important result fields are:

| Field | Explanation |
| --- | --- |
| `sequencePosition` | One-based position copied from the matching Bone Segmentation (from Part 1) record. It preserves the image order within the source group. |
| `sourceIndex` | Identifier copied from the matching Bone Segmentation (from Part 1) and ultrasound records. Use it with the group metadata to trace the surface back to the exact source image. |
| `surfaceCoordinatesXY` | Final retained surface points in MATLAB 1-based `[x, y] = [column, row]` image coordinates. Unlike ordinary integer pixel coordinates, the final `y` values may be fractional because regularization can place the curve between pixel centres. |
| `surfaceCoordinatesXYZRef` | Reserved for the extracted surface points after they are transformed into 3D coordinates in the common reference frame. Part 2 does not perform that assignment, so this field is intentionally empty (`[]`) in the output produced here. It is included now to keep the `surfaceResults` structure ready for the upcoming processing part. |
| `surfaceRowByColumn` | Final surface depth for every image column, expressed as a possibly subpixel row number. A finite value means that column belongs to an extracted surface; `NaN` means no surface was retained there. |
| `rawSurfaceRowByColumn` | Surface depth before regularization. Directly observed values come from boundary pixels exported by Bone Segmentation (from Part 1) and selected by dynamic programming, while accepted gaps are interpolated. Comparing this field with `surfaceRowByColumn` shows how much smoothing changed the curve. |
| `observedColumnMask` | Logical vector marking columns whose raw surface point is an actual boundary coordinate exported by Bone Segmentation (from Part 1). These are the columns with direct segmentation and image support. |
| `interpolatedColumnMask` | Logical vector marking columns filled across an accepted short gap between observed points. These points maintain continuity but were not directly present in the boundary coordinates from Bone Segmentation (from Part 1). |
| `segmentIdByColumn` | Integer label for each retained column. Columns with the same nonzero label belong to one continuous surface segment; zero means that no surface is present in that column. |
| `rawConfidenceByColumn` | Confidence before regularization, on a scale from 0 to 1. At observed candidates it combines first-echo position, bright reflection/ridge, and acoustic-shadow evidence; interpolated gaps receive a reduced value based on their endpoints and gap length. Higher values mean stronger image support. |
| `confidenceByColumn` | Final 0–1 confidence after regularization. Observed-point confidence decreases when the final curve moves away from its raw image-supported location; gap confidence is based on the weaker adjusted endpoint and decreases for longer gaps. `NaN` means no retained surface at that column. |
| `regularizationDisplacementMmByColumn` | Signed axial distance, in millimetres, from each raw surface point to its final regularized position. The magnitude shows how much the curve moved; the sign shows the row-direction of that movement. |
| `regularizationBoundHitColumnMask` | Logical vector marking points that reached the configured maximum allowed displacement or an image boundary during regularization. Many `true` values can indicate that the requested smooth curve was strongly constrained by the safety bounds. |
| `regularizationStatus` | Summary of the smoothing outcome: `applied`, `disabled`, or `notApplicable`, with `partialFallback` or `fallback` indicating that some or all segments kept safer unsmoothed values after refinement could not be completed reliably. |
| `roughnessBeforePerMm`, `roughnessAfterPerMm` | Root-mean-square curvature before and after regularization, in inverse millimetres. Lower `roughnessAfterPerMm` usually means a smoother curve; straight depth and constant slope do not increase this measure. `NaN` is used when no segment has enough points to measure curvature. |
| `regularizationRmsDisplacementMm` | Typical regularization movement over the retained surface, calculated as the root mean square of the per-column displacement. It summarizes overall adjustment without preserving movement direction. |
| `regularizationMaxDisplacementMm` | Largest absolute regularization movement anywhere on the retained surface. Compare it with the configured `maximumDisplacementMm` to see whether smoothing approached its allowed limit. |
| `pixelSpacingXYMm` | Physical distance between adjacent pixel centres as `[lateral spacing, axial spacing]` in millimetres. It converts image columns and rows into physical distances and makes thresholds independent of image resolution. |
| `observedLengthMm` | Lateral support length calculated as the number of directly observed columns multiplied by the lateral pixel spacing. It measures how much of the result is backed by boundary coordinates from Bone Segmentation (from Part 1), not the curved arc length. |
| `interpolatedLengthMm` | Lateral length added across accepted gaps, calculated from the number of interpolated columns and lateral pixel spacing. A large value relative to `observedLengthMm` means more of the curve was inferred rather than directly observed. |
| `meanConfidence` | Arithmetic mean of `confidenceByColumn` over directly observed columns only; interpolated columns are excluded. Each included 0–1 score summarizes first-echo position, bright reflection/ridge, and shadow evidence, then decreases if regularization moves the point away from its raw location. A value near 1 indicates consistently strong image support with little movement, while a value near 0 indicates weak support or substantial adjustment; `NaN` means there are no observed surface points. |
| `numberOfSegments` | Number of separate continuous surface pieces retained in the image. A value greater than one means the extractor found disconnected pieces rather than one uninterrupted curve. |
| `status` | `extracted` means at least one surface segment passed the configured checks. `noSurface` means the image was processed but no usable surface remained. `skippedUnprocessed` means the matching Bone Segmentation (from Part 1) record was not processed, so absence of a surface was not inferred. |

`extractionMetadata` records the resolved algorithm settings, coordinate conventions, input provenance, output filename, processing counts, and creation time so the extraction can be reproduced.

Load the result with:

```matlab
loadedSurface = load('boneSurface_yyyyMMdd_HHmmss.mat', ...
    'surfaceResults', 'extractionMetadata');
surfaceResults = loadedSurface.surfaceResults;
extractionMetadata = loadedSurface.extractionMetadata;
```

## Common Input Problems

- The segmentation MAT-file does not contain a variable named `segmentationResults`.
- The ultrasound MAT-file contains zero variables or more than one variable.
- Bone Segmentation (from Part 1) and Bone Surface Extraction (from Part 2) use different ultrasound snapshot files, so group metadata or `sourceIndex` values do not match.
- A configured filename contains directory components or has the wrong `.mat` or `.json` extension.
- A relative input path is interpreted from the wrong location; it is resolved from the directory containing `boneSegmentation_extractSurface.json`.
- A Bone Segmentation (from Part 1) record is still marked `unprocessed`, so extraction correctly returns `skippedUnprocessed`.
- A processed segmentation has no boundary coordinates, so extraction returns `noSurface`.
- Surface segments disappear because the configured minimum length, confidence threshold, or evidence settings are too strict for the dataset.
- Pixel spacing or plane dimensions in the ultrasound input are missing or inconsistent with the stored image size.
