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
| `name`, `bone`, `path` | Metadata copied from the matching ultrasound source group. |
| `sequencePosition` | Record position inside its source group. |
| `sourceIndex` | Index that links the record to the matching ultrasound input record. |
| `pixelCoordinates` | N-by-2 final boundary coordinates stored as `[row, column]`. Empty for an unprocessed image or a processed image with no segmented boundary. |
| `segmentationMask` | Logical image-sized final foreground mask. |
| `segmentationAreaMask` | Logical image-sized user-selected area; all pixels are true when the full image is used. |
| `usesCustomSegmentationArea` | Logical value indicating whether a custom area limits the result. |
| `processingParameters` | Brightness, contrast, threshold, opening radius, closing radius, and minimum-region-area settings used for the image. |
| `status` | `processed` or `unprocessed`. |

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

- The Part 1 MAT-file containing the variable `segmentationResults`.
- The same selected ultrasound snapshot MAT-file used in Part 1. It must contain exactly one variable.
- The algorithm configuration file `tools/boneSegmentationProcess/configs/boneSurfaceExtraction.json`.

Edit `tools/boneSegmentationProcess/configs/boneSegmentation_extractSurface.json` to select these inputs and the output location:

| Setting | Meaning |
| --- | --- |
| `input.segmentationFilePath` | Directory containing the Part 1 segmentation MAT-file. |
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

Unprocessed Part 1 records are preserved with status `skippedUnprocessed`. A processed record with no candidate coordinates is preserved with status `noSurface`.

## Running the Project

1. Export the Part 1 segmentation results.
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
    +-- surfacePixelCoordinatesXY
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
| `surfacePixelCoordinatesXY` | Final surface points in MATLAB 1-based `[x, y] = [column, row]` image coordinates. |
| `surfaceRowByColumn` | Final subpixel surface row for each image column; unavailable columns contain `NaN`. |
| `rawSurfaceRowByColumn` | Image-supported surface before bounded regularization. |
| `observedColumnMask` | Columns supported directly by exported segmentation boundary coordinates. |
| `interpolatedColumnMask` | Columns inferred across accepted short gaps. |
| `segmentIdByColumn` | Identifier connecting columns that belong to the same retained surface segment. |
| `confidenceByColumn` | Final confidence after displacement and interpolation adjustments. |
| `regularizationStatus` | Whether regularization was applied, disabled, not applicable, or required a fallback. |
| `pixelSpacingXYMm` | Lateral and axial pixel spacing as `[xSpacing, ySpacing]` in millimetres. |
| `observedLengthMm`, `interpolatedLengthMm` | Physical lengths supported by observations and added by interpolation. |
| `meanConfidence` | Mean confidence for the extracted observed surface. |
| `numberOfSegments` | Number of retained surface segments in the frame. |
| `status` | `extracted`, `noSurface`, or `skippedUnprocessed`. |

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
- Part 1 and Part 2 use different ultrasound snapshot files, so group metadata or `sourceIndex` values do not match.
- A configured filename contains directory components or has the wrong `.mat` or `.json` extension.
- A relative input path is interpreted from the wrong location; it is resolved from the directory containing `boneSegmentation_extractSurface.json`.
- A Part 1 record is still marked `unprocessed`, so extraction correctly returns `skippedUnprocessed`.
- A processed segmentation has no boundary coordinates, so extraction returns `noSurface`.
- Surface segments disappear because the configured minimum length, confidence threshold, or evidence settings are too strict for the dataset.
- Pixel spacing or plane dimensions in the ultrasound input are missing or inconsistent with the stored image size.
