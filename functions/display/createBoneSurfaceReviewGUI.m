function reviewFigure = createBoneSurfaceReviewGUI( ...
        surfaceResults, segmentationResults, ultrasoundSequence, ...
        extractionOptions, configurationFilePath)
%CREATEBONESURFACEREVIEWGUI Open an interactive bone-surface review window.
% The GUI keeps all extraction results in one sortable table. Selecting a row
% redraws only its matching ultrasound image, segmentation, and extracted
% surface, which makes large result sets practical to inspect back and forth.
% The right-hand table documents the JSON settings without allowing edits.
%
% Inputs:
%   surfaceResults        : Extracted surface result struct vector.
%   segmentationResults   : Matching segmentation result struct vector.
%   ultrasoundSequence    : Source image struct vector matched by sourceIndex.
%   extractionOptions     : Scalar struct decoded from the extraction JSON.
%   configurationFilePath : Path of the JSON file shown in the GUI.
%
% Outputs:
%   reviewFigure          : Handle to the non-blocking review uifigure.

numberOfResults = numel(surfaceResults);

% Reject malformed direct calls early. The extraction script supplies these
% shapes, but clear messages make the display helper safe to reuse elsewhere.
if ~isstruct(surfaceResults) || ~isstruct(segmentationResults) || ...
        ~isstruct(ultrasoundSequence)
    error('createBoneSurfaceReviewGUI:InvalidReviewData', ...
        ['surfaceResults, segmentationResults, and ultrasoundSequence ' ...
         'must be struct vectors.']);
end
if ~isstruct(extractionOptions) || ~isscalar(extractionOptions)
    error('createBoneSurfaceReviewGUI:InvalidOptions', ...
        'extractionOptions must be a scalar struct decoded from JSON.');
end
if ~(ischar(configurationFilePath) || ...
        (isstring(configurationFilePath) && isscalar(configurationFilePath)))
    error('createBoneSurfaceReviewGUI:InvalidConfigurationPath', ...
        'configurationFilePath must be a character vector or string scalar.');
end

% Match every result to its image once. Row changes can then remain fast even
% when the table contains hundreds of extraction results.
if numberOfResults > 0
    requiredSurfaceFields = { ...
        'sequencePosition', 'sourceIndex', 'status', 'numberOfSegments', ...
        'observedLengthMm', 'interpolatedLengthMm', 'meanConfidence'};
    if ~all(isfield(surfaceResults, requiredSurfaceFields))
        error('createBoneSurfaceReviewGUI:InvalidSurfaceResults', ...
            'surfaceResults is missing one or more fields needed by the GUI.');
    end
    if ~isfield(ultrasoundSequence, 'sourceIndex')
        error('createBoneSurfaceReviewGUI:InvalidUltrasoundSequence', ...
            'ultrasoundSequence must contain sourceIndex.');
    end

    surfaceSourceIndices = [surfaceResults.sourceIndex];
    ultrasoundSourceIndices = [ultrasoundSequence.sourceIndex];
    [hasUltrasoundImage, ultrasoundIndexByResult] = ismember( ...
        surfaceSourceIndices, ultrasoundSourceIndices);
    if ~all(hasUltrasoundImage)
        firstMissingResult = find(~hasUltrasoundImage, 1, 'first');
        error('createBoneSurfaceReviewGUI:MissingUltrasoundImage', ...
            'No ultrasound image matches sourceIndex %g.', ...
            surfaceSourceIndices(firstMissingResult));
    end
else
    surfaceSourceIndices = zeros(1, 0);
    ultrasoundIndexByResult = zeros(1, 0);
end

% Include a permanent result index because the visible row position changes
% whenever the user sorts the table.
resultIndices = (1:numberOfResults).';
if numberOfResults > 0
    sequencePositions = [surfaceResults.sequencePosition].';
    sourceIndices = surfaceSourceIndices.';
    statusValues = string({surfaceResults.status}).';
    segmentCounts = [surfaceResults.numberOfSegments].';
    observedLengthsMm = [surfaceResults.observedLengthMm].';
    interpolatedLengthsMm = [surfaceResults.interpolatedLengthMm].';
    meanConfidences = [surfaceResults.meanConfidence].';
else
    sequencePositions = zeros(0, 1);
    sourceIndices = zeros(0, 1);
    statusValues = strings(0, 1);
    segmentCounts = zeros(0, 1);
    observedLengthsMm = zeros(0, 1);
    interpolatedLengthsMm = zeros(0, 1);
    meanConfidences = zeros(0, 1);
end

reviewTableData = table( ...
    resultIndices, sequencePositions, sourceIndices, statusValues, ...
    segmentCounts, observedLengthsMm, interpolatedLengthsMm, ...
    meanConfidences, ...
    'VariableNames', { ...
        'ResultIndex', 'SequencePosition', 'SourceIndex', 'Status', ...
        'Segments', 'ObservedLengthMm', 'InterpolatedLengthMm', ...
        'MeanConfidence'});

% Flatten the nested JSON hierarchy while retaining the algorithm group. The
% resulting display data drives the individual read-only parameter controls.
parameterDisplayData = buildProcessingParameterDisplayData(extractionOptions);

%% CREATE THE THREE-COLUMN REVIEW INTERFACE

reviewFigure = uifigure( ...
    'Name', 'Bone Surface Extraction Review', ...
    'Position', [20, 60, 1880, 900], ...
    'Tag', 'bone_surface_review_gui');

% Give the image more room and keep the parameter column intentionally narrow.
% Its longer descriptions wrap vertically inside a scrollable area.
mainGrid = uigridlayout(reviewFigure, [1, 3], ...
    'ColumnWidth', {'1x', '1.55x', '0.72x'}, ...
    'Padding', [10, 10, 10, 10], ...
    'ColumnSpacing', 10);

% The left panel contains only navigation and result summaries. Users can sort
% any column, then click a row to redraw the permanent matching result index.
dataPanel = uipanel(mainGrid, ...
    'Title', 'Data Table', ...
    'Tag', 'bone_surface_review_data_panel');
dataPanel.Layout.Row = 1;
dataPanel.Layout.Column = 1;
dataGrid = uigridlayout(dataPanel, [1, 1], ...
    'Padding', [5, 5, 5, 5]);

resultsTable = uitable(dataGrid, ...
    'Data', reviewTableData, ...
    'ColumnName', { ...
        '#', 'Sequence', 'Source', 'Status', 'Segments', ...
        'Observed mm', 'Filled mm', 'Confidence'}, ...
    'ColumnWidth', {40, 60, 55, 100, 60, 78, 70, 78}, ...
    'ColumnEditable', false(1, width(reviewTableData)), ...
    'ColumnSortable', true(1, width(reviewTableData)), ...
    'SelectionType', 'row', ...
    'Multiselect', 'off', ...
    'Tag', 'bone_surface_review_data_table');
resultsTable.Layout.Row = 1;
resultsTable.Layout.Column = 1;

% Reuse one central axes so selecting among hundreds of rows does not create
% hundreds of graphics objects or separate figure windows.
imagePanel = uipanel(mainGrid, ...
    'Title', 'Ultrasound Image (Segmentation and Surface)', ...
    'Tag', 'bone_surface_review_image_panel');
imagePanel.Layout.Row = 1;
imagePanel.Layout.Column = 2;
imageGrid = uigridlayout(imagePanel, [3, 1], ...
    'RowHeight', {'1x', 26, 26}, ...
    'Padding', [5, 5, 5, 5], ...
    'RowSpacing', 2);

imageAxes = uiaxes(imageGrid, ...
    'Tag', 'bone_surface_review_image_axes');
imageAxes.Layout.Row = 1;
imageAxes.Layout.Column = 1;
% Label both directions with physical units because the image and every
% overlay below are positioned from plane.W and plane.H.
xlabel(imageAxes, 'Image width (mm)');
ylabel(imageAxes, 'Image height (mm)');
box(imageAxes, 'on');
colormap(imageAxes, gray(256));

% A changing summary below the image exposes key metrics without requiring
% the reviewer to find the corresponding columns in a wide sorted table.
resultSummaryLabel = uilabel(imageGrid, ...
    'HorizontalAlignment', 'center', ...
    'Text', '', ...
    'Tag', 'bone_surface_review_result_summary');
resultSummaryLabel.Layout.Row = 2;
resultSummaryLabel.Layout.Column = 1;

% Keep a color key permanently visible instead of rebuilding a legend that
% could cover anatomy in the selected ultrasound image.
legendGrid = uigridlayout(imageGrid, [1, 4], ...
    'ColumnWidth', {'1x', '1x', '1x', '1x'}, ...
    'Padding', [0, 0, 0, 0], ...
    'ColumnSpacing', 3);
legendGrid.Layout.Row = 3;
legendGrid.Layout.Column = 1;

segmentationLegendLabel = uilabel(legendGrid, ...
    'Text', '--- Segmentation', ...
    'FontColor', [0.68, 0.50, 0.00], ...
    'HorizontalAlignment', 'center');
segmentationLegendLabel.Layout.Column = 1;
rawLegendLabel = uilabel(legendGrid, ...
    'Text', '--- Raw surface', ...
    'FontColor', [0.90, 0.10, 0.80], ...
    'HorizontalAlignment', 'center');
rawLegendLabel.Layout.Column = 2;
observedLegendLabel = uilabel(legendGrid, ...
    'Text', '* Final observed', ...
    'FontColor', [0.85, 0.10, 0.05], ...
    'HorizontalAlignment', 'center');
observedLegendLabel.Layout.Column = 3;
interpolatedLegendLabel = uilabel(legendGrid, ...
    'Text', '* Final interpolated', ...
    'FontColor', [0.00, 0.65, 0.75], ...
    'HorizontalAlignment', 'center');
interpolatedLegendLabel.Layout.Column = 4;

% The right panel reports exactly the settings supplied from the JSON file.
% Each algorithm group receives its own panel in a vertically scrollable area.
parameterPanel = uipanel(mainGrid, ...
    'Title', 'Processing Parameters (Read Only)', ...
    'Tag', 'bone_surface_review_parameter_panel');
parameterPanel.Layout.Row = 1;
parameterPanel.Layout.Column = 3;
parameterGrid = uigridlayout(parameterPanel, [1, 1], ...
    'Padding', [5, 5, 5, 5]);

parameterScrollPanel = uipanel(parameterGrid, ...
    'BorderType', 'none', ...
    'Scrollable', 'on', ...
    'AutoResizeChildren', 'off', ...
    'Tag', 'bone_surface_review_parameter_scroll_panel');
parameterScrollPanel.Layout.Row = 1;
parameterScrollPanel.Layout.Column = 1;

% Build the grouped controls inside one tall content panel. The outer panel
% provides vertical scrolling while descriptions use their full wrapped text.
parameterContentPanel = createProcessingParameterPanels( ...
    parameterScrollPanel, parameterDisplayData);
parameterScrollPanel.SizeChangedFcn = @resizeParameterContent;

%% CONNECT TABLE NAVIGATION TO THE SELECTED IMAGE

% Lay out the scrollable parameter content after the figure has received its
% real on-screen size, then begin at the first parameter group.
drawnow;
resizeParameterContent([], []);
drawnow;
scroll(parameterScrollPanel, 'top');
drawnow limitrate;

if numberOfResults == 0
    % An empty extraction still gets a clear GUI state instead of failing while
    % trying to select the first row.
    resultsTable.Enable = 'off';
    axis(imageAxes, 'off');
    text(imageAxes, 0.5, 0.5, ...
        'No bone-surface results are available for review.', ...
        'Units', 'normalized', ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle', ...
        'Interpreter', 'none');
    resultSummaryLabel.Text = 'No result selected.';
else
    % Render the first result before registering the callback so initial setup
    % is not treated as a user-generated table selection.
    resultsTable.Selection = 1;
    renderSelectedResult(1);
    resultsTable.SelectionChangedFcn = @handleTableSelection;
end

    function resizeParameterContent(~, ~)
        %RESIZEPARAMETERCONTENT Fit grouped controls to the narrow viewport.
        % Keeping the content slightly narrower than the scroll panel prevents
        % a horizontal scrollbar while the vertical scrollbar remains available.
        %
        % Inputs:
        %   ~ : Unused source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. The content panel width is updated in place.

        if ~isvalid(parameterScrollPanel) || ...
                ~isvalid(parameterContentPanel)
            return;
        end

        viewportWidth = parameterScrollPanel.InnerPosition(3);
        contentPosition = parameterContentPanel.Position;
        contentPosition(3) = max(260, viewportWidth - 18);
        parameterContentPanel.Position = contentPosition;
    end

    function handleTableSelection(~, eventData)
        %HANDLETABLESELECTION Render the permanent result behind a selected row.
        % MATLAB reports a row in the table Data even after visual sorting. The
        % stored ResultIndex therefore remains a safe key into surfaceResults.
        %
        % Inputs:
        %   ~         : Unused table source supplied by MATLAB.
        %   eventData : Selection event containing the selected data row.
        %
        % Outputs:
        %   None. The callback redraws the selected image and overlays.

        if isempty(eventData.Selection)
            return;
        end

        selectedDataRow = eventData.Selection(1);
        currentTableData = resultsTable.Data;
        if selectedDataRow < 1 || selectedDataRow > height(currentTableData)
            return;
        end

        stableResultIndex = currentTableData.ResultIndex(selectedDataRow);
        renderSelectedResult(stableResultIndex);
    end

    function renderSelectedResult(resultIndex)
        %RENDERSELECTEDRESULT Draw one image, segmentation, and surface result.
        % Redrawing one shared axes keeps navigation fast and ensures overlays
        % from the previously selected row cannot remain visible.
        %
        % Inputs:
        %   resultIndex : Permanent positive index into surfaceResults.
        %
        % Outputs:
        %   None. The central axes and summary label are updated in place.

        currentResult = surfaceResults(resultIndex);
        ultrasoundIndex = ultrasoundIndexByResult(resultIndex);
        currentPlane = ultrasoundSequence(ultrasoundIndex).plane;
        displayedImage = currentPlane.image.';

        % plane.W and plane.H describe the distances between the first and
        % last pixel centres. Use the same convention as the extraction code
        % so displayed measurements agree with the saved millimetre results.
        imageWidthMm = double(currentPlane.W);
        imageHeightMm = double(currentPlane.H);
        numberOfImageRows = size(displayedImage, 1);
        numberOfImageColumns = size(displayedImage, 2);
        pixelSpacingXYMm = [ ...
            imageWidthMm / (numberOfImageColumns - 1), ...
            imageHeightMm / (numberOfImageRows - 1)];

        cla(imageAxes);
        imagesc(imageAxes, ...
            [0, imageWidthMm], [0, imageHeightMm], displayedImage);
        axis(imageAxes, 'image');
        imageAxes.YDir = 'reverse';
        imageAxes.XLim = [0, imageWidthMm];
        imageAxes.YLim = [0, imageHeightMm];
        colormap(imageAxes, gray(256));
        hold(imageAxes, 'on');

        % Match segmentation independently by sourceIndex because stored result
        % arrays may be reordered before this reusable display helper is called.
        [segmentationEntry, hasSegmentationEntry] = ...
            getMatchingSegmentationEntry( ...
                segmentationResults, currentResult.sourceIndex);
        if hasSegmentationEntry
            segmentationDisplayStatus = plotSegmentationOverlay( ...
                imageAxes, segmentationEntry, size(displayedImage), ...
                pixelSpacingXYMm);
        else
            segmentationDisplayStatus = "unavailable";
        end

        plotSurfaceResult(imageAxes, currentResult, pixelSpacingXYMm);
        hold(imageAxes, 'off');

        title(imageAxes, sprintf( ...
            'Result %d of %d | sequence %g | source %g | %s', ...
            resultIndex, numberOfResults, currentResult.sequencePosition, ...
            currentResult.sourceIndex, currentResult.status), ...
            'Interpreter', 'none');

        % Keep the summary concise enough to remain readable under the image.
        resultSummaryLabel.Text = sprintf( ...
            ['Segmentation: %s | Segments: %d | Observed: %.3g mm | ' ...
             'Interpolated: %.3g mm | Mean confidence: %.3g'], ...
            char(segmentationDisplayStatus), currentResult.numberOfSegments, ...
            currentResult.observedLengthMm, ...
            currentResult.interpolatedLengthMm, ...
            currentResult.meanConfidence);
        drawnow limitrate;
    end
end


function [segmentationEntry, hasMatch] = getMatchingSegmentationEntry( ...
        segmentationResults, sourceIndex)
%GETMATCHINGSEGMENTATIONENTRY Find display data with the requested source key.
% Matching by sourceIndex prevents an image from being paired with a different
% segmentation when either input struct vector has been reordered.
%
% Inputs:
%   segmentationResults : Segmentation result struct vector.
%   sourceIndex         : Scalar source identifier requested for display.
%
% Outputs:
%   segmentationEntry   : Matching scalar struct, or an empty struct.
%   hasMatch            : True when exactly one usable entry was found.

segmentationEntry = struct([]);
hasMatch = false;

if isempty(segmentationResults) || ...
        ~isfield(segmentationResults, 'sourceIndex')
    return;
end

segmentationSourceIndices = [segmentationResults.sourceIndex];
matchingIndex = find(segmentationSourceIndices == sourceIndex, 1, 'first');
if isempty(matchingIndex)
    return;
end

segmentationEntry = segmentationResults(matchingIndex);
hasMatch = true;
end


function displayStatus = plotSegmentationOverlay( ...
        targetAxes, segmentationEntry, expectedImageSize, pixelSpacingXYMm)
%PLOTSEGMENTATIONOVERLAY Draw the selected bone segmentation over B-mode.
% A valid mask is shown with a light fill and separate boundary curves. Older
% results that contain only boundary coordinates still receive a point overlay.
%
% Inputs:
%   targetAxes        : Axes that already display the selected B-mode image.
%   segmentationEntry : One matching segmentation result record.
%   expectedImageSize : Size vector of the displayed B-mode image.
%   pixelSpacingXYMm  : Horizontal and vertical pixel spacing in millimetres.
%
% Outputs:
%   displayStatus     : Text describing whether a mask, coordinates, or no
%                       segmentation could be displayed.

displayStatus = "unavailable";
segmentationColor = [1.00, 0.80, 0.05];

if isfield(segmentationEntry, 'segmentationMask')
    candidateMask = segmentationEntry.segmentationMask;
    isValidMask = ~isempty(candidateMask) && ismatrix(candidateMask) && ...
        (islogical(candidateMask) || isnumeric(candidateMask)) && ...
        isreal(candidateMask) && ...
        isequal(size(candidateMask), expectedImageSize(1:2));

    % Numeric masks must be finite binary data. This avoids presenting a soft
    % or corrupt array as if it were an accepted segmentation.
    if isValidMask && isnumeric(candidateMask)
        isValidMask = all(isfinite(candidateMask(:))) && ...
            all(candidateMask(:) == 0 | candidateMask(:) == 1);
    end

    if isValidMask && any(candidateMask(:))
        segmentationMask = logical(candidateMask);

        % Use an RGB overlay so the axes grayscale colormap remains unchanged.
        colorOverlay = zeros( ...
            [expectedImageSize(1:2), 3], 'double');
        colorOverlay(:, :, 1) = segmentationColor(1);
        colorOverlay(:, :, 2) = segmentationColor(2);
        colorOverlay(:, :, 3) = segmentationColor(3);
        image(targetAxes, colorOverlay, ...
            'XData', [0, (expectedImageSize(2) - 1) * pixelSpacingXYMm(1)], ...
            'YData', [0, (expectedImageSize(1) - 1) * pixelSpacingXYMm(2)], ...
            'AlphaData', 0.12 * double(segmentationMask), ...
            'HitTest', 'off');

        % Draw connected boundaries separately so disjoint regions are never
        % joined by misleading diagonal lines. Subtract one because MATLAB
        % pixel indices start at one while the physical image origin is zero.
        boundaries = bwboundaries(segmentationMask, 8, 'noholes');
        for boundaryIndex = 1:numel(boundaries)
            currentBoundary = boundaries{boundaryIndex};
            boundaryXMm = ...
                (currentBoundary(:, 2) - 1) * pixelSpacingXYMm(1);
            boundaryYMm = ...
                (currentBoundary(:, 1) - 1) * pixelSpacingXYMm(2);
            plot(targetAxes, ...
                boundaryXMm, boundaryYMm, ...
                '-', 'Color', segmentationColor, 'LineWidth', 1.1, ...
                'HandleVisibility', 'off');
        end

        displayStatus = "mask";
        return;
    end
end

% Fall back to exported [row,column] coordinates for historical results that
% do not retain a filled segmentation mask.
if ~isfield(segmentationEntry, 'pixelCoordinates')
    return;
end

pixelCoordinates = segmentationEntry.pixelCoordinates;
isValidCoordinates = isnumeric(pixelCoordinates) && isreal(pixelCoordinates) && ...
    ismatrix(pixelCoordinates) && size(pixelCoordinates, 2) == 2 && ...
    all(isfinite(pixelCoordinates(:)));
if ~isValidCoordinates || isempty(pixelCoordinates)
    return;
end

insideImage = pixelCoordinates(:, 1) >= 1 & ...
    pixelCoordinates(:, 1) <= expectedImageSize(1) & ...
    pixelCoordinates(:, 2) >= 1 & ...
    pixelCoordinates(:, 2) <= expectedImageSize(2);
pixelCoordinates = pixelCoordinates(insideImage, :);
if isempty(pixelCoordinates)
    return;
end

% Convert the historical [row,column] coordinates into the same millimetre
% coordinate system used by the image and mask overlay.
coordinateXMm = (pixelCoordinates(:, 2) - 1) * pixelSpacingXYMm(1);
coordinateYMm = (pixelCoordinates(:, 1) - 1) * pixelSpacingXYMm(2);
plot(targetAxes, coordinateXMm, coordinateYMm, ...
    '.', 'Color', segmentationColor, 'MarkerSize', 5, ...
    'HandleVisibility', 'off');
displayStatus = "boundary coordinates";
end


function plotSurfaceResult(targetAxes, surfaceResult, pixelSpacingXYMm)
%PLOTSURFACERESULT Draw raw and refined bone-surface review overlays.
% Raw segments remain thin magenta lines. Final observed and interpolated
% columns use separate red and cyan points so inferred gaps stay obvious.
%
% Inputs:
%   targetAxes        : Axes that already display the source B-mode image.
%   surfaceResult     : One extracted surface result record.
%   pixelSpacingXYMm  : Horizontal and vertical pixel spacing in millimetres.
%
% Outputs:
%   None. The function adds surface overlays to targetAxes.

finalSurfaceRows = reshape(surfaceResult.surfaceRowByColumn, 1, []);

% Result files created before the raw-path audit field existed can still be
% reviewed by treating their final curve as the raw curve.
if isfield(surfaceResult, 'rawSurfaceRowByColumn') && ...
        numel(surfaceResult.rawSurfaceRowByColumn) == numel(finalSurfaceRows)
    rawSurfaceRows = reshape(surfaceResult.rawSurfaceRowByColumn, 1, []);
else
    rawSurfaceRows = finalSurfaceRows;
end

% Plot each accepted segment independently so a rejected long gap never looks
% like one continuous raw surface.
segmentIds = unique(surfaceResult.segmentIdByColumn);
segmentIds = segmentIds(isfinite(segmentIds) & segmentIds > 0);
for segmentId = reshape(segmentIds, 1, [])
    segmentColumns = find(surfaceResult.segmentIdByColumn == segmentId);
    segmentXMm = (segmentColumns - 1) * pixelSpacingXYMm(1);
    segmentYMm = ...
        (rawSurfaceRows(segmentColumns) - 1) * pixelSpacingXYMm(2);
    plot(targetAxes, segmentXMm, segmentYMm, ...
        '-', 'Color', [0.90, 0.10, 0.80], 'LineWidth', 0.9, ...
        'HandleVisibility', 'off');
end

observedColumnMask = reshape( ...
    logical(surfaceResult.observedColumnMask), 1, []);
interpolatedColumnMask = reshape( ...
    logical(surfaceResult.interpolatedColumnMask), 1, []);

observedColumns = find(observedColumnMask);
observedXMm = (observedColumns - 1) * pixelSpacingXYMm(1);
observedYMm = ...
    (finalSurfaceRows(observedColumns) - 1) * pixelSpacingXYMm(2);
plot(targetAxes, observedXMm, observedYMm, ...
    '.', 'Color', [1.00, 0.15, 0.10], 'MarkerSize', 10, ...
    'HandleVisibility', 'off');

interpolatedColumns = find(interpolatedColumnMask);
interpolatedXMm = ...
    (interpolatedColumns - 1) * pixelSpacingXYMm(1);
interpolatedYMm = ...
    (finalSurfaceRows(interpolatedColumns) - 1) * pixelSpacingXYMm(2);
plot(targetAxes, interpolatedXMm, interpolatedYMm, ...
    '.', 'Color', [0.00, 0.90, 1.00], 'MarkerSize', 10, ...
    'HandleVisibility', 'off');
end


function parameterDisplayData = ...
        buildProcessingParameterDisplayData(extractionOptions)
%BUILDPROCESSINGPARAMETERDISPLAYDATA Prepare nested JSON settings for the GUI.
% Flattening the hierarchy lets grouped controls include every current and
% future JSON leaf while retaining readable names and descriptions.
%
% Inputs:
%   extractionOptions : Scalar struct decoded from boneSurfaceExtraction.json.
%
% Outputs:
%   parameterDisplayData : Table containing group, name, value, and help text.

[groupNames, parameterNames, valueTexts, descriptions] = ...
    flattenParameterStruct(extractionOptions, '');
parameterDisplayData = table( ...
    groupNames, parameterNames, valueTexts, descriptions, ...
    'VariableNames', {'Group', 'Parameter', 'Value', 'Description'});
end


function parameterContentPanel = createProcessingParameterPanels( ...
        parameterScrollPanel, parameterDisplayData)
%CREATEPROCESSINGPARAMETERPANELS Build grouped read-only parameter controls.
% Each JSON group gets a titled panel. Every parameter uses a label beside a
% disabled value field, followed by a wrapped explanation on the next row.
%
% Inputs:
%   parameterScrollPanel : Scrollable parent panel in the GUI right column.
%   parameterDisplayData : Table containing grouped parameter display text.
%
% Outputs:
%   parameterContentPanel: Tall child panel that contains all group panels.

groupNames = unique(parameterDisplayData.Group, 'stable');
numberOfGroups = numel(groupNames);

% Fixed pixel heights make every description readable and give the outer
% panel a concrete content height from which to calculate vertical scrolling.
parameterRowHeight = 28;
descriptionRowHeight = 52;
innerRowSpacing = 2;
groupTitleAndPaddingHeight = 34;
outerGroupSpacing = 8;
groupPanelHeights = zeros(1, numberOfGroups);

for groupIndex = 1:numberOfGroups
    numberOfGroupParameters = nnz( ...
        parameterDisplayData.Group == groupNames(groupIndex));
    numberOfInnerRows = 2 * numberOfGroupParameters;
    groupPanelHeights(groupIndex) = groupTitleAndPaddingHeight + ...
        numberOfGroupParameters * ...
            (parameterRowHeight + descriptionRowHeight) + ...
        max(0, numberOfInnerRows - 1) * innerRowSpacing;
end

totalContentHeight = sum(groupPanelHeights) + ...
    max(0, numberOfGroups - 1) * outerGroupSpacing + 2;
initialContentWidth = max(260, parameterScrollPanel.Position(3) - 18);

% This absolute-size child extends beyond the visible parent height. MATLAB's
% scrollable panel then exposes all groups through one vertical scrollbar.
parameterContentPanel = uipanel(parameterScrollPanel, ...
    'BorderType', 'none', ...
    'Units', 'pixels', ...
    'Position', [1, 1, initialContentWidth, totalContentHeight], ...
    'Tag', 'bone_surface_review_parameter_content_panel');

contentGrid = uigridlayout(parameterContentPanel, [numberOfGroups, 1], ...
    'RowHeight', num2cell(groupPanelHeights), ...
    'Padding', [0, 0, 0, 0], ...
    'RowSpacing', outerGroupSpacing);

for groupIndex = 1:numberOfGroups
    currentGroupName = groupNames(groupIndex);
    currentGroupRows = parameterDisplayData.Group == currentGroupName;
    currentGroupData = parameterDisplayData(currentGroupRows, :);
    numberOfGroupParameters = height(currentGroupData);

    groupPanel = uipanel(contentGrid, ...
        'Title', char(currentGroupName), ...
        'FontWeight', 'bold', ...
        'Tag', 'bone_surface_review_parameter_group_panel');
    groupPanel.Layout.Row = groupIndex;
    groupPanel.Layout.Column = 1;

    % Two rows per parameter keep its explanation directly below the matching
    % name and disabled value field.
    groupRowHeights = repmat( ...
        {parameterRowHeight, descriptionRowHeight}, ...
        1, numberOfGroupParameters);
    groupGrid = uigridlayout(groupPanel, ...
        [2 * numberOfGroupParameters, 2], ...
        'RowHeight', groupRowHeights, ...
        'ColumnWidth', {'1x', 100}, ...
        'Padding', [8, 6, 8, 6], ...
        'RowSpacing', innerRowSpacing, ...
        'ColumnSpacing', 8);

    for parameterIndex = 1:numberOfGroupParameters
        valueRow = 2 * parameterIndex - 1;
        descriptionRow = valueRow + 1;

        parameterLabel = uilabel(groupGrid, ...
            'Text', char(currentGroupData.Parameter(parameterIndex)), ...
            'FontWeight', 'bold', ...
            'Tag', 'bone_surface_review_parameter_name_label');
        parameterLabel.Layout.Row = valueRow;
        parameterLabel.Layout.Column = 1;

        % Disable the value field so MATLAB renders it gray and clearly shows
        % that extraction settings cannot be changed from this review window.
        valueField = uieditfield(groupGrid, 'text', ...
            'Value', char(currentGroupData.Value(parameterIndex)), ...
            'Editable', 'off', ...
            'Enable', 'off', ...
            'HorizontalAlignment', 'center', ...
            'Tag', 'bone_surface_review_parameter_value_field');
        valueField.Layout.Row = valueRow;
        valueField.Layout.Column = 2;

        descriptionLabel = uilabel(groupGrid, ...
            'Text', char(currentGroupData.Description(parameterIndex)), ...
            'WordWrap', 'on', ...
            'VerticalAlignment', 'top', ...
            'FontColor', [0.32, 0.32, 0.32], ...
            'Tag', 'bone_surface_review_parameter_description_label');
        descriptionLabel.Layout.Row = descriptionRow;
        descriptionLabel.Layout.Column = [1, 2];
    end
end
end


function [groupNames, parameterNames, valueTexts, descriptions] = ...
        flattenParameterStruct(parameterStruct, parentPath)
%FLATTENPARAMETERSTRUCT Recursively collect configuration leaf values.
% Recursion preserves the JSON field order and automatically includes new
% settings that may be added after this GUI is created.
%
% Inputs:
%   parameterStruct : Scalar configuration struct at the current hierarchy.
%   parentPath      : Dot-separated path of its parent group.
%
% Outputs:
%   groupNames      : String vector of readable algorithm group names.
%   parameterNames  : String vector of readable parameter names.
%   valueTexts      : String vector of compact formatted values.
%   descriptions    : String vector explaining each parameter's purpose.

groupNames = strings(0, 1);
parameterNames = strings(0, 1);
valueTexts = strings(0, 1);
descriptions = strings(0, 1);

fieldNames = fieldnames(parameterStruct);
for fieldIndex = 1:numel(fieldNames)
    currentFieldName = fieldNames{fieldIndex};
    if isempty(parentPath)
        currentPath = currentFieldName;
    else
        currentPath = [parentPath, '.', currentFieldName];
    end

    currentValue = parameterStruct.(currentFieldName);
    if isstruct(currentValue) && isscalar(currentValue)
        [childGroups, childNames, childValues, childDescriptions] = ...
            flattenParameterStruct(currentValue, currentPath);
        groupNames = [groupNames; childGroups]; %#ok<AGROW>
        parameterNames = [parameterNames; childNames]; %#ok<AGROW>
        valueTexts = [valueTexts; childValues]; %#ok<AGROW>
        descriptions = [descriptions; childDescriptions]; %#ok<AGROW>
        continue;
    end

    [groupName, parameterName, description] = ...
        describeExtractionParameter(currentPath);
    groupNames(end + 1, 1) = groupName; %#ok<AGROW>
    parameterNames(end + 1, 1) = parameterName; %#ok<AGROW>
    valueTexts(end + 1, 1) = formatParameterValue(currentValue); %#ok<AGROW>
    descriptions(end + 1, 1) = description; %#ok<AGROW>
end
end


function [groupName, parameterName, description] = ...
        describeExtractionParameter(parameterPath)
%DESCRIBEEXTRACTIONPARAMETER Provide readable JSON labels and short help.
% Known production settings receive specific junior-friendly descriptions.
% Unknown future leaves remain visible with a clear generic description.
%
% Inputs:
%   parameterPath : Dot-separated path of one JSON leaf value.
%
% Outputs:
%   groupName     : Readable algorithm-stage name.
%   parameterName : Readable setting name including units where applicable.
%   description   : Short statement of what the setting controls.

pathParts = strsplit(parameterPath, '.');
groupName = makeFriendlyGroupName(pathParts{1});
parameterName = makeFriendlyParameterName(pathParts{end});
description = "Additional setting loaded from the JSON file.";

switch parameterPath
    case 'imageEvidence.gaussianSigmaMm'
        parameterName = "Gaussian sigma (mm)";
        description = "Smooths small image noise before evidence is measured, reducing unstable responses from isolated bright pixels.";
    case 'imageEvidence.ridgeSigmaMm'
        parameterName = "Ridge sigma (mm)";
        description = "Sets the physical scale used to emphasize thin, ridge-like echoes that may represent a bone surface.";
    case 'imageEvidence.gradientSearchMarginMm'
        parameterName = "Gradient margin (mm)";
        description = "Defines how far around each segmentation candidate the algorithm may search for the strongest reflection edge.";
    case 'imageEvidence.shadowStartMm'
        parameterName = "Shadow start (mm)";
        description = "Moves the start of shadow measurement below the candidate so the bright bone echo itself is not treated as shadow.";
    case 'imageEvidence.shadowLengthMm'
        parameterName = "Shadow length (mm)";
        description = "Sets how much tissue below a candidate is inspected for the dark acoustic shadow expected behind bone.";
    case 'imageEvidence.normalizationPercentiles'
        parameterName = "Normalization percentiles";
        description = "Uses these low and high image percentiles as robust intensity limits before reflection evidence is compared.";
    case 'imageEvidence.fallbackConfidenceScale'
        parameterName = "Fallback confidence scale";
        description = "Reduces the confidence of weak candidates that remain available only as a fallback for continuous tracing.";
    case 'imageEvidence.weights.position'
        parameterName = "Position weight";
        description = "Controls how strongly the probe-facing location of a candidate contributes to its combined evidence score.";
    case 'imageEvidence.weights.reflection'
        parameterName = "Reflection weight";
        description = "Controls how strongly a bright ultrasound reflection contributes to the combined evidence score.";
    case 'imageEvidence.weights.shadow'
        parameterName = "Shadow weight";
        description = "Controls how strongly a dark region below the candidate contributes to the combined evidence score.";
    case 'surfaceTracing.evidenceThreshold'
        parameterName = "Evidence threshold";
        description = "Separates strong candidates from weak fallback candidates before the continuous surface path is traced.";
    case 'surfaceTracing.smoothnessWeight'
        parameterName = "Smoothness weight";
        description = "Penalizes sudden depth changes between neighboring image columns so the traced surface stays anatomically plausible.";
    case 'surfaceTracing.minimumObservedSegmentLengthMm'
        parameterName = "Minimum segment length (mm)";
        description = "Rejects observed surface segments shorter than this physical length because they are more likely to be noise.";
    case 'surfaceTracing.minimumMeanSegmentConfidence'
        parameterName = "Minimum mean confidence";
        description = "Rejects a traced segment when its average image-evidence confidence falls below this value.";
    case 'gapInterpolation.maximumGapMm'
        parameterName = "Maximum gap (mm)";
        description = "Allows interpolation only when the missing distance between two observed surface segments is no larger than this.";
    case 'gapInterpolation.method'
        parameterName = "Interpolation method";
        description = "Selects the curve-fitting method used to estimate surface positions inside an accepted short gap.";
    case 'regularization.enabled'
        parameterName = "Enabled";
        description = "Determines whether the raw traced surface is refined to reduce small, implausible curvature changes.";
    case 'regularization.halfResponseWavelengthMm'
        parameterName = "Half-response wavelength (mm)";
        description = "Sets the curve wavelength where regularization has half strength, linking smoothing to physical anatomy size.";
    case 'regularization.huberDeltaMm'
        parameterName = "Huber delta (mm)";
        description = "Sets the displacement where robust fitting becomes less sensitive to large residuals and possible outliers.";
    case 'regularization.maximumDisplacementMm'
        parameterName = "Maximum displacement (mm)";
        description = "Limits how far regularization may move a point away from the raw image-supported surface.";
    case 'regularization.minimumDataWeight'
        parameterName = "Minimum data weight";
        description = "Keeps even low-confidence observed points connected to their image evidence during regularization.";
    case 'regularization.maximumIterations'
        parameterName = "Maximum iterations";
        description = "Stops the regularization solver after this many refinement steps if convergence has not happened sooner.";
    case 'regularization.convergenceMm'
        parameterName = "Convergence (mm)";
        description = "Stops regularization when the change between successive surface estimates is smaller than this distance.";
end
end


function groupName = makeFriendlyGroupName(rawGroupName)
%MAKEFRIENDLYGROUPNAME Convert a JSON group key into a display label.
% Known group names use consistent terminology; future camel-case group names
% are split automatically so their parameters remain readable.
%
% Inputs:
%   rawGroupName : Top-level JSON group field name.
%
% Outputs:
%   groupName    : Readable string used in the parameter table.

switch rawGroupName
    case 'imageEvidence'
        groupName = "Image evidence";
    case 'surfaceTracing'
        groupName = "Surface tracing";
    case 'gapInterpolation'
        groupName = "Gap interpolation";
    case 'regularization'
        groupName = "Regularization";
    otherwise
        groupName = makeFriendlyParameterName(rawGroupName);
end
end


function parameterName = makeFriendlyParameterName(rawParameterName)
%MAKEFRIENDLYPARAMETERNAME Split a camel-case JSON key for fallback display.
% This helper is needed so newly added settings remain understandable before
% a more specific description is added to the GUI mapping.
%
% Inputs:
%   rawParameterName : JSON field name at a configuration leaf.
%
% Outputs:
%   parameterName    : Readable string with spaces between words.

spacedName = regexprep(rawParameterName, ...
    '([a-z0-9])([A-Z])', '$1 $2');
parameterName = string([upper(spacedName(1)), spacedName(2:end)]);
end


function valueText = formatParameterValue(parameterValue)
%FORMATPARAMETERVALUE Convert one JSON leaf value into compact display text.
% Numeric arrays, logical switches, and text settings receive stable formats
% so the read-only table shows values without MATLAB type decorations.
%
% Inputs:
%   parameterValue : One non-struct value decoded from JSON.
%
% Outputs:
%   valueText      : Scalar string used in the parameter table.

if islogical(parameterValue) && isscalar(parameterValue)
    if parameterValue
        valueText = "true";
    else
        valueText = "false";
    end
elseif isnumeric(parameterValue)
    formattedNumbers = compose('%.6g', double(parameterValue(:).'));
    if isscalar(parameterValue)
        valueText = formattedNumbers;
    else
        valueText = "[" + strjoin(formattedNumbers, ", ") + "]";
    end
elseif ischar(parameterValue) || ...
        (isstring(parameterValue) && isscalar(parameterValue))
    valueText = string(parameterValue);
else
    % JSONENCODE provides a useful last-resort representation for any future
    % leaf type that JSONDECODE can return.
    valueText = string(jsonencode(parameterValue));
end
end
