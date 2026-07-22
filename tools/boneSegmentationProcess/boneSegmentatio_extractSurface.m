clear; clc; close all;

%% SELECT INPUTS AND CONFIGURATION

% Resolve all extraction paths from this script so it can be run from any
% MATLAB current folder without changing project-wide paths.
extractionToolDirectory = fileparts(mfilename('fullpath'));
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

% Make the public extractor visible even when this script is launched by its
% full path from a different working directory.
addpath(extractionToolDirectory);

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

[surfaceResults, extractionMetadata] = ...
    extractBoneSurfacesFromSegmentation( ...
    segmentationResults, ultrasoundSequence, extractionOptions);

% The public function receives arrays rather than file paths, so record the
% resolved provenance here before saving the result artifact.
extractionMetadata.sourceSegmentationFile = segmentationFilePath;
extractionMetadata.sourceUltrasoundFile = ultrasoundFilePath;
extractionMetadata.configurationFile = configurationFilePath;

runTimestamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
surfaceOutputFilePath = fullfile(segmentationOutputDirectory, ...
    ['boneSurface_', runTimestamp, '.mat']);

% Create paged review images before saving so their paths are included in the
% same metadata record as the numeric results.
[reviewFigureHandles, reviewImagePaths] = ...
    createBoneSurfaceReviewFigures(surfaceResults, segmentationResults, ...
    ultrasoundSequence, segmentationOutputDirectory, runTimestamp);
extractionMetadata.reviewImageFiles = reviewImagePaths;
extractionMetadata.outputFile = surfaceOutputFilePath;

save(surfaceOutputFilePath, 'surfaceResults', 'extractionMetadata', '-v7.3');

fprintf('Saved %d surface result(s) to:\n%s\n', ...
    numel(surfaceResults), surfaceOutputFilePath);
fprintf('Created %d review figure page(s).\n', numel(reviewFigureHandles));


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

        % Match the extractor's effective mask exactly so blue outside-mask
        % markers are judged against the same reviewed search region shown in
        % yellow, including an optional segmentation-area restriction.
        segmentationEntry = segmentationResults(frameIndex);
        effectiveMask = logical(segmentationEntry.segmentationMask);
        if isfield(segmentationEntry, 'segmentationAreaMask') && ...
                ~isempty(segmentationEntry.segmentationAreaMask)
            effectiveMask = effectiveMask & ...
                logical(segmentationEntry.segmentationAreaMask);
        end
        plotMaskBoundary(currentAxes, effectiveMask);
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


function plotMaskBoundary(targetAxes, segmentationMask)
%PLOTMASKBOUNDARY Draw every accepted mask component without joining them.
% Separate boundary traces avoid the misleading diagonal connections produced
% by plotting an unordered perimeter point list directly.
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
% and interpolated locations. Blue rings flag observed points that finished
% outside the segmentation. Results saved before these audit fields existed
% remain reviewable by treating their final curve as their raw curve and by
% omitting the unavailable outside-mask markers.
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

% Older result files have no outside-mask audit field. An all-false fallback
% preserves their original display while new results gain the blue warning.
outsideSegmentationColumnMask = false(size(finalSurfaceRows));
if isfield(surfaceResult, 'outsideSegmentationColumnMask') && ...
        numel(surfaceResult.outsideSegmentationColumnMask) == ...
        numel(finalSurfaceRows)
    outsideSegmentationColumnMask = reshape(logical( ...
        surfaceResult.outsideSegmentationColumnMask), 1, []);
end
outsideColumns = find(outsideSegmentationColumnMask & observedColumnMask);
plot(targetAxes, outsideColumns, finalSurfaceRows(outsideColumns), ...
    'o', 'Color', [0.10, 0.45, 1.0], 'MarkerSize', 4.5, ...
    'LineWidth', 0.9, 'MarkerFaceColor', 'none', ...
    'HandleVisibility', 'off');
end


function legendHandle = createBoneSurfaceReviewLegend(targetAxes)
%CREATEBONESURFACEREVIEWLEGEND Add one compact key below a review page.
% The key uses placeholder graphics so the five overlay meanings stay visible
% even when the first frame has no interpolation or outside-mask points. It is
% attached to the tiled layout below all panels to avoid covering image data.
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
outsideKey = plot(targetAxes, NaN, NaN, 'o', ...
    'Color', [0.10, 0.45, 1.0], 'MarkerSize', 4.5, ...
    'LineWidth', 0.9, 'MarkerFaceColor', 'none');

legendHandle = legend(targetAxes, ...
    [maskKey, rawKey, observedKey, interpolatedKey, outsideKey], ...
    {'Segmentation', 'Raw surface', 'Final observed', ...
    'Final interpolated', 'Outside segmentation'}, ...
    'Orientation', 'horizontal', 'NumColumns', 5, ...
    'Box', 'off', 'FontSize', 7);
end
