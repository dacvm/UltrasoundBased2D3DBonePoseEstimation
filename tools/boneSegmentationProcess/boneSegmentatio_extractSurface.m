clear; clc; close all;

%% SELECT INPUTS AND CONFIGURATION

% Resolve all extraction paths from this script so it can be run from any
% MATLAB current folder without changing project-wide paths.
extractionToolDirectory = fileparts(mfilename('fullpath'));
projectDirectory = fileparts(fileparts(extractionToolDirectory));
segmentationOutputDirectory = fullfile(extractionToolDirectory, 'outputs');
segmentationFileName = 'boneSegmentation_20260722_162046.mat';
segmentationFilePath = fullfile( ...
    segmentationOutputDirectory, segmentationFileName);

snapshotOutputDirectory = fullfile( ...
    fileparts(extractionToolDirectory), 'snapshotProcess', 'outputs');
ultrasoundFileName = 'validSnapshots_20260721_145143.mat';
ultrasoundFilePath = fullfile(snapshotOutputDirectory, ultrasoundFileName);

configurationFilePath = fullfile( ...
    extractionToolDirectory, 'configs', 'boneSurfaceExtraction.json');

% Add the public extractor and its separated helpers explicitly so this tool
% also works when MATLAB starts outside the project directory.
surfaceExtractionDirectory = fullfile( ...
    projectDirectory, 'functions', 'boneSurfaceExtraction');
surfaceExtractionHelperDirectory = fullfile( ...
    surfaceExtractionDirectory, 'helpers');
if ~isfolder(surfaceExtractionDirectory) || ...
        ~isfolder(surfaceExtractionHelperDirectory)
    error('boneSegmentatio_extractSurface:MissingExtractionFunctions', ...
        'Bone-surface extraction functions were not found under: %s', ...
        surfaceExtractionDirectory);
end
addpath(surfaceExtractionDirectory, surfaceExtractionHelperDirectory);

%% LOAD THE SEGMENTATION AND MATCHING B-MODE DATA

if ~isfile(segmentationFilePath)
    error('boneSegmentatio_extractSurface:MissingSegmentationFile', ...
        'Segmentation file was not found: %s', segmentationFilePath);
end
segmentationFileData = load(segmentationFilePath, 'segmentationResults');
if ~isfield(segmentationFileData, 'segmentationResults')
    error('boneSegmentatio_extractSurface:MissingSegmentationResults', ...
        'The selected segmentation file does not contain segmentationResults.');
end
segmentationResults = segmentationFileData.segmentationResults;
clear segmentationFileData;

if ~isfile(ultrasoundFilePath)
    error('boneSegmentatio_extractSurface:MissingUltrasoundFile', ...
        'Ultrasound file was not found: %s', ultrasoundFilePath);
end
ultrasoundFileData = load(ultrasoundFilePath);
ultrasoundVariableNames = fieldnames(ultrasoundFileData);
if numel(ultrasoundVariableNames) ~= 1
    error('boneSegmentatio_extractSurface:UnexpectedUltrasoundVariables', ...
        'Expected one ultrasound variable in "%s", but found %d.', ...
        ultrasoundFileName, numel(ultrasoundVariableNames));
end
ultrasoundSequence = ultrasoundFileData.(ultrasoundVariableNames{1});
clear ultrasoundFileData ultrasoundVariableNames;

if ~isfile(configurationFilePath)
    error('boneSegmentatio_extractSurface:MissingConfigurationFile', ...
        'Extraction configuration was not found: %s', configurationFilePath);
end
try
    extractionOptions = jsondecode(fileread(configurationFilePath));
catch configurationError
    error('boneSegmentatio_extractSurface:InvalidConfigurationFile', ...
        'Could not read the extraction configuration: %s', ...
        configurationError.message);
end

%% EXTRACT AND SAVE THE THIN BONE SURFACES

[surfaceResults, extractionMetadata] = extractBoneSurfacesFromSegmentation(segmentationResults, ultrasoundSequence, extractionOptions);

% The public function receives arrays rather than file paths, so record the
% resolved provenance here before saving the result artifact.
extractionMetadata.sourceSegmentationFile = segmentationFilePath;
extractionMetadata.sourceUltrasoundFile   = ultrasoundFilePath;
extractionMetadata.configurationFile      = configurationFilePath;

runTimestamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
surfaceOutputFilePath = fullfile(segmentationOutputDirectory, ['boneSurface_', runTimestamp, '.mat']);

% Create paged review images before saving so their paths are included in the
% same metadata record as the numeric results.
[reviewFigureHandles, reviewImagePaths] = ...
    createBoneSurfaceReviewFigures(surfaceResults, segmentationResults, ...
    ultrasoundSequence, segmentationOutputDirectory, runTimestamp);

extractionMetadata.reviewImageFiles = reviewImagePaths;
extractionMetadata.outputFile       = surfaceOutputFilePath;

save(surfaceOutputFilePath, 'surfaceResults', 'extractionMetadata', '-v7.3');

fprintf('Saved %d surface result(s) to:\n%s\n', numel(surfaceResults), surfaceOutputFilePath);
fprintf('Created %d review figure page(s).\n', numel(reviewFigureHandles));





%% 
function [figureHandles, reviewImagePaths] = ...
        createBoneSurfaceReviewFigures(surfaceResults, segmentationResults, ...
        ultrasoundSequence, outputDirectory, runTimestamp)
%CREATEBONESURFACEREVIEWFIGURES Create paged extraction-review overlays.
% The figures show the accepted mask, complete selected curve, observed points,
% and interpolated points so failures and long inferred gaps remain visible.
%
% Inputs:
%   surfaceResults      : Extracted surface result struct vector.
%   segmentationResults : Matching segmentation result struct vector.
%   ultrasoundSequence  : Source image struct vector matched by sourceIndex.
%   outputDirectory     : Directory where review PNG files are saved.
%   runTimestamp        : Text timestamp shared with the surface MAT filename.
%
% Outputs:
%   figureHandles       : Column vector of generated MATLAB figure handles.
%   reviewImagePaths    : Cell vector containing the saved PNG paths.

framesPerPage = 9;
numberOfFrames = numel(surfaceResults);
numberOfPages = ceil(numberOfFrames / framesPerPage);
figureHandles = gobjects(numberOfPages, 1);
reviewImagePaths = cell(numberOfPages, 1);

% Build a sourceIndex lookup once so the review remains correct even when the
% source ultrasound array is reordered.
ultrasoundSourceIndices = [ultrasoundSequence.sourceIndex];

for pageIndex = 1:numberOfPages
    firstFrame = (pageIndex - 1) * framesPerPage + 1;
    lastFrame = min(pageIndex * framesPerPage, numberOfFrames);
    pageFrameIndices = firstFrame:lastFrame;

    currentFigure = figure( ...
        'Color', 'w', ...
        'Name', sprintf('Bone surface review %d/%d', ...
        pageIndex, numberOfPages), ...
        'Position', [50, 50, 1500, 950]);
    figureHandles(pageIndex) = currentFigure;
    reviewLayout = tiledlayout(currentFigure, 3, 3, ...
        'Padding', 'compact', 'TileSpacing', 'compact');
    title(reviewLayout, sprintf( ...
        'Bone-surface review %d/%d', pageIndex, numberOfPages));

    for frameIndex = pageFrameIndices
        currentAxes = nexttile(reviewLayout);
        sourceIndex = surfaceResults(frameIndex).sourceIndex;
        [hasSourceImage, ultrasoundIndex] = ismember( ...
            sourceIndex, ultrasoundSourceIndices);
        if ~hasSourceImage
            error('boneSegmentatio_extractSurface:MissingReviewImage', ...
                'No review image matches sourceIndex %g.', sourceIndex);
        end

        displayedImage = ultrasoundSequence(ultrasoundIndex).plane.image.';
        imagesc(currentAxes, displayedImage);
        axis(currentAxes, 'image');
        axis(currentAxes, 'off');
        colormap(currentAxes, gray(256));
        hold(currentAxes, 'on');

        % The segmentation boundary is optional documentation only. Invalid
        % or unavailable masks are skipped so they can never block a review
        % of otherwise valid pixel-coordinate surface results.
        reviewSegmentationMask = getOptionalReviewSegmentationMask( ...
            segmentationResults, frameIndex, size(displayedImage));
        if ~isempty(reviewSegmentationMask)
            plotMaskBoundary(currentAxes, reviewSegmentationMask);
        end
        plotSurfaceResult(currentAxes, surfaceResults(frameIndex));

        % Add one shared key to the page. Repeating the legend in every tile
        % would hide useful ultrasound detail in these small review panels.
        if frameIndex == firstFrame
            reviewLegend = createBoneSurfaceReviewLegend(currentAxes);
            reviewLegend.Layout.Tile = 'south';
        end

        title(currentAxes, sprintf('#%d | src %g | %s', ...
            frameIndex, sourceIndex, surfaceResults(frameIndex).status), ...
            'Interpreter', 'none', 'FontSize', 8);
    end

    reviewImagePaths{pageIndex} = fullfile(outputDirectory, sprintf( ...
        'boneSurfaceReview_%s_page%02d.png', runTimestamp, pageIndex));
    exportgraphics(currentFigure, reviewImagePaths{pageIndex}, ...
        'Resolution', 150);
end
end


function segmentationMask = getOptionalReviewSegmentationMask( ...
        segmentationResults, frameIndex, expectedImageSize)
%GETOPTIONALREVIEWSEGMENTATIONMASK Return a safe display-only mask if present.
% The surface coordinates do not depend on segmentation during review. This
% helper therefore accepts a segmentation mask only when it is a finite binary
% 2-D array with the same size as the displayed image. Returning an empty array
% tells the caller to omit the optional yellow boundary without failing.
%
% Inputs:
%   segmentationResults : Segmentation result struct vector, which may be old
%                         or may omit segmentationMask entirely.
%   frameIndex          : Position of the surface frame on the review page.
%   expectedImageSize   : Size vector of the displayed B-mode image.
%
% Outputs:
%   segmentationMask   : Logical mask matching the image, or [] when no valid
%                        optional documentation mask is available.

segmentationMask = [];

% Some historical or independently generated result sets may have no matching
% segmentation entry. That must not prevent their surfaces from being shown.
if ~isstruct(segmentationResults) || frameIndex > numel(segmentationResults)
    return;
end

segmentationEntry = segmentationResults(frameIndex);
if ~isfield(segmentationEntry, 'segmentationMask')
    return;
end

candidateMask = segmentationEntry.segmentationMask;
if isempty(candidateMask) || ~ismatrix(candidateMask) || ...
        ~(islogical(candidateMask) || isnumeric(candidateMask)) || ...
        ~isreal(candidateMask) || ...
        ~isequal(size(candidateMask), expectedImageSize)
    return;
end

% Numeric masks must contain only finite zeros and ones. Rejecting other
% values avoids drawing a misleading boundary from corrupt or soft-mask data.
if isnumeric(candidateMask) && ...
        (~all(isfinite(candidateMask(:))) || ...
        ~all(candidateMask(:) == 0 | candidateMask(:) == 1))
    return;
end

segmentationMask = logical(candidateMask);
if ~any(segmentationMask(:))
    % An all-background mask has no boundary to document, so omit it just as
    % an empty array would be omitted.
    segmentationMask = [];
end
end


function plotMaskBoundary(targetAxes, segmentationMask)
%PLOTMASKBOUNDARY Draw an optional segmentation boundary for documentation.
% Separate boundary traces avoid the misleading diagonal connections produced
% by plotting an unordered perimeter point list directly. The caller validates
% the mask first because this overlay must never affect surface extraction or
% prevent older pixel-coordinate results from being reviewed.
%
% Inputs:
%   targetAxes      : Axes that already display the source B-mode image.
%   segmentationMask: Logical accepted segmentation mask.
%
% Outputs:
%   None. The function adds yellow boundary lines to targetAxes.

boundaries = bwboundaries(segmentationMask, 8, 'noholes');
for boundaryIndex = 1:numel(boundaries)
    currentBoundary = boundaries{boundaryIndex};
    plot(targetAxes, currentBoundary(:, 2), currentBoundary(:, 1), ...
        '-', 'Color', [1.0, 0.80, 0.05], 'LineWidth', 0.75);
end
end


function plotSurfaceResult(targetAxes, surfaceResult)
%PLOTSURFACERESULT Draw raw and refined bone-surface review overlays.
% The raw extraction is drawn as a thin magenta line so reviewers can see how
% far regularization moved it. Red and cyan points distinguish final observed
% and interpolated locations. Results saved before raw-path audit fields existed
% remain reviewable by treating their final curve as their raw curve. Obsolete
% mask-relative audit fields are intentionally ignored.
%
% Inputs:
%   targetAxes   : Axes that already display the source B-mode image.
%   surfaceResult: One extracted surface result record.
%
% Outputs:
%   None. The function adds surface overlays to targetAxes.

finalSurfaceRows = reshape(surfaceResult.surfaceRowByColumn, 1, []);

% New result files retain the pre-regularization path explicitly. Falling
% back to the final path lets older MAT files use this review code unchanged.
if isfield(surfaceResult, 'rawSurfaceRowByColumn') && ...
        numel(surfaceResult.rawSurfaceRowByColumn) == numel(finalSurfaceRows)
    rawSurfaceRows = reshape(surfaceResult.rawSurfaceRowByColumn, 1, []);
else
    rawSurfaceRows = finalSurfaceRows;
end

% Draw each segment separately so a long rejected gap is never represented
% by a misleading magenta connection between two accepted surface pieces.
segmentIds = unique(surfaceResult.segmentIdByColumn);
segmentIds = segmentIds(isfinite(segmentIds) & segmentIds > 0);
for segmentId = reshape(segmentIds, 1, [])
    segmentColumns = find(surfaceResult.segmentIdByColumn == segmentId);
    plot(targetAxes, segmentColumns, rawSurfaceRows(segmentColumns), ...
        '-', 'Color', [0.90, 0.10, 0.80], 'LineWidth', 0.65, ...
        'HandleVisibility', 'off');
end

observedColumnMask = reshape(logical( ...
    surfaceResult.observedColumnMask), 1, []);
interpolatedColumnMask = reshape(logical( ...
    surfaceResult.interpolatedColumnMask), 1, []);

% Point markers intentionally do not connect across classification changes.
% This keeps short inferred gaps visibly cyan instead of hiding them under a
% red line joining the observations on either side.
observedColumns = find(observedColumnMask);
plot(targetAxes, observedColumns, finalSurfaceRows(observedColumns), ...
    '.', 'Color', [1.0, 0.15, 0.10], 'MarkerSize', 8, ...
    'HandleVisibility', 'off');

interpolatedColumns = find(interpolatedColumnMask);
plot(targetAxes, interpolatedColumns, ...
    finalSurfaceRows(interpolatedColumns), ...
    '.', 'Color', [0.0, 0.90, 1.0], 'MarkerSize', 8, ...
    'HandleVisibility', 'off');
end


function legendHandle = createBoneSurfaceReviewLegend(targetAxes)
%CREATEBONESURFACEREVIEWLEGEND Add one compact key below a review page.
% The key uses placeholder graphics so the four overlay meanings stay visible
% even when the first frame has no mask or interpolated points. It is attached
% to the tiled layout below all panels to avoid covering image data.
%
% Inputs:
%   targetAxes : Axes belonging to the tiled review layout.
%
% Outputs:
%   legendHandle : MATLAB legend object that the caller places in the layout.

% NaN coordinates create legend samples without adding visible data marks to
% the ultrasound panel. Their styles exactly match the real review overlays.
maskKey = plot(targetAxes, NaN, NaN, '-', ...
    'Color', [1.0, 0.80, 0.05], 'LineWidth', 0.75);
rawKey = plot(targetAxes, NaN, NaN, '-', ...
    'Color', [0.90, 0.10, 0.80], 'LineWidth', 0.65);
observedKey = plot(targetAxes, NaN, NaN, '.', ...
    'Color', [1.0, 0.15, 0.10], 'MarkerSize', 8);
interpolatedKey = plot(targetAxes, NaN, NaN, '.', ...
    'Color', [0.0, 0.90, 1.0], 'MarkerSize', 8);

legendHandle = legend(targetAxes, ...
    [maskKey, rawKey, observedKey, interpolatedKey], ...
    {'Segmentation', 'Raw surface', 'Final observed', ...
    'Final interpolated'}, ...
    'Orientation', 'horizontal', 'NumColumns', 4, ...
    'Box', 'off', 'FontSize', 7);
end
