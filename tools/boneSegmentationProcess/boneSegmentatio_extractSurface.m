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

        plotMaskBoundary(currentAxes, ...
            logical(segmentationResults(frameIndex).segmentationMask));
        plotSurfaceResult(currentAxes, surfaceResults(frameIndex));

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
%PLOTSURFACERESULT Draw segments and distinguish measured from inferred points.
% Green lines show the complete downstream curve, red dots mark image-supported
% observations, and cyan dots expose columns filled only by interpolation.
%
% Inputs:
%   targetAxes   : Axes that already display the source B-mode image.
%   surfaceResult: One extracted surface result record.
%
% Outputs:
%   None. The function adds surface overlays to targetAxes.

for segmentIndex = 1:surfaceResult.numberOfSegments
    segmentColumns = find( ...
        surfaceResult.segmentIdByColumn == segmentIndex);
    plot(targetAxes, segmentColumns, ...
        surfaceResult.surfaceRowByColumn(segmentColumns), ...
        '-', 'Color', [0.10, 0.90, 0.30], 'LineWidth', 1.1);
end

observedColumns = find(surfaceResult.observedColumnMask);
plot(targetAxes, observedColumns, ...
    surfaceResult.surfaceRowByColumn(observedColumns), ...
    '.', 'Color', [1.0, 0.15, 0.10], 'MarkerSize', 8);

interpolatedColumns = find(surfaceResult.interpolatedColumnMask);
plot(targetAxes, interpolatedColumns, ...
    surfaceResult.surfaceRowByColumn(interpolatedColumns), ...
    '.', 'Color', [0.0, 0.90, 1.0], 'MarkerSize', 8);
end
