function reviewFigure = createBoneSurfaceReviewGUI( ...
        surfaceResults, segmentationResults, ultrasoundSequence, ...
        extractionOptions, configurationFilePath, extractionMetadata, ...
        outputDirectory)
%CREATEBONESURFACEREVIEWGUI Open an interactive bone-surface review window.
% The GUI keeps each source directory in its own sortable table tab. Selecting
% a row redraws only its matching ultrasound image, segmentation, and extracted
% surface. The right-hand controls document JSON settings without allowing edits
% and let the user export the reviewed grouped result when it should be retained.
%
% Inputs:
%   surfaceResults        : Grouped extracted surface result struct vector.
%   segmentationResults   : Matching grouped segmentation result struct vector.
%   ultrasoundSequence    : Grouped source images matched within each group.
%   extractionOptions     : Scalar struct decoded from the extraction JSON.
%   configurationFilePath : Path of the JSON file shown in the GUI.
%   extractionMetadata    : Scalar provenance struct saved with surfaceResults.
%   outputDirectory       : Existing directory used for the optional MAT export.
%
% Outputs:
%   reviewFigure          : Handle to the non-blocking review uifigure.

% Align all grouped inputs once. The renderer can then reuse compact flat arrays
% while tabs retain the public group/local identity and tolerate reordered input.
[flatSurfaceResults, flatSegmentationResults, flatUltrasoundSequence, ...
    groupMetadata, stateIndicesByGroup] = ...
    normalizeGroupedReviewInputs( ...
        surfaceResults, segmentationResults, ultrasoundSequence);
numberOfGroups = numel(groupMetadata);
numberOfResultsByGroup = cellfun(@numel, stateIndicesByGroup);
numberOfResults = sum(numberOfResultsByGroup);
firstNonemptyGroupIndex = find(numberOfResultsByGroup > 0, 1);

% Reject malformed configuration inputs before creating a partial figure.
if ~isstruct(extractionOptions) || ~isscalar(extractionOptions)
    error('createBoneSurfaceReviewGUI:InvalidOptions', ...
        'extractionOptions must be a scalar struct decoded from JSON.');
end
if ~(ischar(configurationFilePath) || ...
        (isstring(configurationFilePath) && isscalar(configurationFilePath)))
    error('createBoneSurfaceReviewGUI:InvalidConfigurationPath', ...
        'configurationFilePath must be a character vector or string scalar.');
end
if ~isstruct(extractionMetadata) || ~isscalar(extractionMetadata)
    error('createBoneSurfaceReviewGUI:InvalidExtractionMetadata', ...
        'extractionMetadata must be a scalar provenance struct.');
end
if ~(ischar(outputDirectory) || ...
        (isstring(outputDirectory) && isscalar(outputDirectory)))
    error('createBoneSurfaceReviewGUI:InvalidOutputDirectory', ...
        'outputDirectory must be a character vector or string scalar.');
end
outputDirectory = char(string(outputDirectory));
if ~isfolder(outputDirectory)
    error('createBoneSurfaceReviewGUI:OutputDirectoryNotFound', ...
        'The surface export directory was not found: %s', outputDirectory);
end

% Build one table per group. LocalResultIndex remains stable after sorting and
% maps through stateIndicesByGroup to the aligned internal flat record.
reviewTableDataByGroup = cell(1, numberOfGroups);
for groupIndex = 1:numberOfGroups
    groupStateIndices = stateIndicesByGroup{groupIndex};
    numberOfGroupResults = numel(groupStateIndices);
    localResultIndices = (1:numberOfGroupResults).';
    if numberOfGroupResults > 0
        groupSurfaceResults = flatSurfaceResults(groupStateIndices);
        sequencePositions = [groupSurfaceResults.sequencePosition].';
        sourceIndices = [groupSurfaceResults.sourceIndex].';
        statusValues = string({groupSurfaceResults.status}).';
        segmentCounts = [groupSurfaceResults.numberOfSegments].';
        observedLengthsMm = [groupSurfaceResults.observedLengthMm].';
        interpolatedLengthsMm = ...
            [groupSurfaceResults.interpolatedLengthMm].';
        meanConfidences = [groupSurfaceResults.meanConfidence].';
    else
        sequencePositions = zeros(0, 1);
        sourceIndices = zeros(0, 1);
        statusValues = strings(0, 1);
        segmentCounts = zeros(0, 1);
        observedLengthsMm = zeros(0, 1);
        interpolatedLengthsMm = zeros(0, 1);
        meanConfidences = zeros(0, 1);
    end

    reviewTableDataByGroup{groupIndex} = table( ...
        localResultIndices, sequencePositions, sourceIndices, ...
        statusValues, segmentCounts, observedLengthsMm, ...
        interpolatedLengthsMm, meanConfidences, ...
        'VariableNames', { ...
            'LocalResultIndex', 'SequencePosition', 'SourceIndex', ...
            'Status', 'Segments', 'ObservedLengthMm', ...
            'InterpolatedLengthMm', 'MeanConfidence'});
end

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

% The left panel separates source directories into tabs. Users can sort any
% group-local table, then click a row to redraw its stable matching result.
dataPanel = uipanel(mainGrid, ...
    'Title', 'Data Tables by Source Directory', ...
    'Tag', 'bone_surface_review_data_panel');
dataPanel.Layout.Row = 1;
dataPanel.Layout.Column = 1;
dataGrid = uigridlayout(dataPanel, [1, 1], ...
    'Padding', [5, 5, 5, 5]);

resultsTabGroup = uitabgroup(dataGrid, ...
    'Tag', 'bone_surface_review_tab_group');
resultTabs = gobjects(1, numberOfGroups);
resultsTables = gobjects(1, numberOfGroups);
for groupIndex = 1:numberOfGroups
    resultTabs(groupIndex) = uitab(resultsTabGroup, ...
        'Title', char(string(groupMetadata(groupIndex).name)), ...
        'Tag', sprintf('bone_surface_review_tab_%d', groupIndex));
    resultTabs(groupIndex).UserData = groupIndex;
    tabGrid = uigridlayout(resultTabs(groupIndex), [1, 1], ...
        'Padding', [0, 0, 0, 0]);
    currentTableData = reviewTableDataByGroup{groupIndex};
    resultsTables(groupIndex) = uitable(tabGrid, ...
        'Data', currentTableData, ...
        'ColumnName', { ...
            '#', 'Sequence', 'Source', 'Status', 'Segments', ...
            'Observed mm', 'Filled mm', 'Confidence'}, ...
        'ColumnWidth', {40, 60, 55, 100, 60, 78, 70, 78}, ...
        'ColumnEditable', false(1, width(currentTableData)), ...
        'ColumnSortable', true(1, width(currentTableData)), ...
        'SelectionType', 'row', ...
        'Multiselect', 'off', ...
        'Tag', sprintf('bone_surface_review_data_table_%d', groupIndex));
    resultsTables(groupIndex).UserData = groupIndex;

    % Empty groups remain visible as tabs but cannot produce a row selection.
    if numberOfResultsByGroup(groupIndex) == 0
        resultsTables(groupIndex).Enable = 'off';
    end
end

% Reuse one central axes so selecting among hundreds of rows does not create
% hundreds of graphics objects or separate figure windows.
imagePanel = uipanel(mainGrid, ...
    'Title', 'Ultrasound Image (Segmentation and Surface)', ...
    'Tag', 'bone_surface_review_image_panel');
imagePanel.Layout.Row = 1;
imagePanel.Layout.Column = 2;
imageGrid = uigridlayout(imagePanel, [2, 1], ...
    'RowHeight', {'1x', 26}, ...
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

% Normals are useful for reviewing orientation but can obscure subtle image
% evidence. Keep them enabled by default and let the reviewer hide only the
% overlay without changing the extracted result.
showNormalsCheckbox = uicheckbox(imageGrid, ...
    'Text', 'Show probe-facing normals', ...
    'Value', true, ...
    'Tag', 'bone_surface_review_show_normals_checkbox', ...
    'ValueChangedFcn', @handleNormalVisibility);
showNormalsCheckbox.Layout.Row = 2;
showNormalsCheckbox.Layout.Column = 1;

% The right panel reports exactly the settings supplied from the JSON file.
% Each algorithm group receives its own panel in a vertically scrollable area.
parameterPanel = uipanel(mainGrid, ...
    'Title', 'Processing Parameters (Read Only)', ...
    'Tag', 'bone_surface_review_parameter_panel');
parameterPanel.Layout.Row = 1;
parameterPanel.Layout.Column = 3;
parameterGrid = uigridlayout(parameterPanel, [2, 1], ...
    'RowHeight', {'1x', 38}, ...
    'Padding', [5, 5, 5, 5], ...
    'RowSpacing', 5);

parameterScrollPanel = uipanel(parameterGrid, ...
    'BorderType', 'none', ...
    'Scrollable', 'on', ...
    'AutoResizeChildren', 'off', ...
    'Tag', 'bone_surface_review_parameter_scroll_panel');
parameterScrollPanel.Layout.Row = 1;
parameterScrollPanel.Layout.Column = 1;

% Keep the export action outside the scroll area so it remains visible while
% the reviewer inspects even a long list of processing parameters.
exportButton = uibutton(parameterGrid, 'push', ...
    'Text', 'Export Surface Results', ...
    'Tag', 'bone_surface_review_export_button', ...
    'ButtonPushedFcn', @exportSurfaceResults);
exportButton.Layout.Row = 2;
exportButton.Layout.Column = 1;

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

% Keep one remembered local selection per tab. Rendering uses an aligned flat
% result index only after resolving the active group/local composite identity.
lastSelectedLocalIndexByGroup = zeros(1, numberOfGroups);
isSynchronizingSelection = false;
if numberOfResults == 0
    activeGroupIndex = 1;
    resultsTabGroup.SelectedTab = resultTabs(activeGroupIndex);
    renderEmptyGroup(activeGroupIndex);
else
    activeGroupIndex = firstNonemptyGroupIndex;
    lastSelectedLocalIndexByGroup(activeGroupIndex) = 1;
    resultsTabGroup.SelectedTab = resultTabs(activeGroupIndex);
    resultsTables(activeGroupIndex).Selection = 1;
    renderSelectedResult( ...
        stateIndicesByGroup{activeGroupIndex}(1), activeGroupIndex, 1);
end

% Register callbacks only after initial selection so setup is not interpreted
% as user navigation.
for groupIndex = 1:numberOfGroups
    resultsTables(groupIndex).SelectionChangedFcn = @handleTableSelection;
end
resultsTabGroup.SelectionChangedFcn = @handleTabSelection;

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

    function handleTabSelection(~, eventData)
        %HANDLETABSELECTION Restore the remembered result for one source group.
        % Empty tabs deliberately clear the prior group's image so no overlay is
        % presented under the wrong source-directory label.
        %
        % Inputs:
        %   ~         : Unused tab-group source supplied by MATLAB.
        %   eventData : Tab event whose NewValue identifies the selected group.
        %
        % Outputs:
        %   None. The callback restores a table row or renders an empty state.

        if isSynchronizingSelection || isempty(eventData.NewValue)
            return;
        end
        activeGroupIndex = eventData.NewValue.UserData;
        if numberOfResultsByGroup(activeGroupIndex) == 0
            renderEmptyGroup(activeGroupIndex);
            return;
        end

        localResultIndex = ...
            lastSelectedLocalIndexByGroup(activeGroupIndex);
        if localResultIndex < 1 || ...
                localResultIndex > numberOfResultsByGroup(activeGroupIndex)
            localResultIndex = 1;
        end
        lastSelectedLocalIndexByGroup(activeGroupIndex) = localResultIndex;
        isSynchronizingSelection = true;
        resultsTables(activeGroupIndex).Selection = localResultIndex;
        isSynchronizingSelection = false;
        resultIndex = ...
            stateIndicesByGroup{activeGroupIndex}(localResultIndex);
        renderSelectedResult( ...
            resultIndex, activeGroupIndex, localResultIndex);
    end

    function handleTableSelection(sourceTable, eventData)
        %HANDLETABLESELECTION Render the stable result behind a selected row.
        % MATLAB reports the underlying Data row after visual sorting, so the
        % stored local index remains safe within its owning source group.
        %
        % Inputs:
        %   sourceTable : Table whose UserData stores its source group index.
        %   eventData   : Selection event containing the selected data row.
        %
        % Outputs:
        %   None. The callback redraws the selected image and overlays.

        if isSynchronizingSelection || isempty(eventData.Selection)
            return;
        end

        selectedDataRow = eventData.Selection(1);
        currentTableData = sourceTable.Data;
        if selectedDataRow < 1 || selectedDataRow > height(currentTableData)
            return;
        end

        targetGroupIndex = sourceTable.UserData;
        localResultIndex = ...
            currentTableData.LocalResultIndex(selectedDataRow);
        resultIndex = stateIndicesByGroup{targetGroupIndex}(localResultIndex);
        activeGroupIndex = targetGroupIndex;
        lastSelectedLocalIndexByGroup(targetGroupIndex) = localResultIndex;
        renderSelectedResult( ...
            resultIndex, targetGroupIndex, localResultIndex);
    end

    function handleNormalVisibility(sourceCheckbox, ~)
        %HANDLENORMALVISIBILITY Show or hide the current normal overlay.
        % Changing this display-only property preserves both the selected row
        % and the immutable result that will be exported later.
        %
        % Inputs:
        %   sourceCheckbox : Checkbox containing the requested visibility.
        %   ~              : Unused event data supplied by MATLAB.
        %
        % Outputs:
        %   None. Existing normal graphics change visibility in place.

        normalOverlays = findall(imageAxes, ...
            'Tag', 'bone_surface_review_normal_overlay');
        if sourceCheckbox.Value
            set(normalOverlays, 'Visible', 'on');
        else
            set(normalOverlays, 'Visible', 'off');
        end
    end

    function exportSurfaceResults(~, ~)
        %EXPORTSURFACERESULTS Save the reviewed grouped result on user request.
        % The immutable grouped result and its provenance are written together
        % only after review, so opening or closing the GUI alone creates no file.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback writes one MAT-file and updates the export button.

        % Create the timestamp at the moment of export so the filename describes
        % the user's save action rather than the earlier extraction or GUI launch.
        exportTimestamp = char(datetime('now', ...
            'Format', 'yyyyMMdd_HHmmss'));
        outputFileName = sprintf('boneSurface_%s.mat', exportTimestamp);
        outputFilePath = fullfile(outputDirectory, outputFileName);

        % Save the original grouped input, not the aligned flat arrays used only
        % for fast table navigation and rendering inside this GUI.
        try
            save(outputFilePath, ...
                'surfaceResults', 'extractionMetadata', '-v7.3');
        catch saveError
            uialert(reviewFigure, ...
                sprintf('Could not export the surface results:\n\n%s', ...
                saveError.message), ...
                'Export failed', ...
                'Icon', 'error');
            return;
        end

        % Results cannot change in this read-only GUI, so disable the action after
        % success to prevent accidental duplicate exports of identical content.
        exportButton.Text = 'Exported';
        exportButton.Enable = 'off';
        uialert(reviewFigure, ...
            sprintf('Surface results were saved to:\n\n%s', outputFilePath), ...
            'Export complete', ...
            'Icon', 'success');
    end

    function renderEmptyGroup(groupIndexToRender)
        %RENDEREMPTYGROUP Clear the image for a source group without results.
        % Keeping the empty tab selectable makes the GUI mirror the complete
        % extraction hierarchy rather than hiding source directories.
        %
        % Input:
        %   groupIndexToRender : One-based empty source group index.
        %
        % Outputs:
        %   None. The axes and summary are replaced with an empty-group message.

        delete(findall(imageAxes, ...
            'Tag', 'bone_surface_review_normal_overlay'));
        cla(imageAxes);
        legend(imageAxes, 'off');
        axis(imageAxes, 'off');
        text(imageAxes, 0.5, 0.5, sprintf( ...
            'No bone-surface results are available in "%s".', ...
            char(string(groupMetadata(groupIndexToRender).name))), ...
            'Units', 'normalized', ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'middle', ...
            'Interpreter', 'none');
        title(imageAxes, sprintf('%s: no result selected.', ...
            char(string(groupMetadata(groupIndexToRender).name))), ...
            'Interpreter', 'none');
    end

    function renderSelectedResult( ...
            resultIndex, groupIndexToRender, localResultIndex)
        %RENDERSELECTEDRESULT Draw one image, segmentation, and surface result.
        % Redrawing one shared axes keeps navigation fast and ensures overlays
        % from the previously selected row cannot remain visible.
        %
        % Inputs:
        %   resultIndex       : Permanent flat index into aligned internal data.
        %   groupIndexToRender: One-based source group owning the result.
        %   localResultIndex  : One-based result position inside that group.
        %
        % Outputs:
        %   None. The central axes and summary label are updated in place.

        currentResult = flatSurfaceResults(resultIndex);
        currentPlane = flatUltrasoundSequence(resultIndex).plane;
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

        % Quiver objects use hidden handles so the normal overlay does not
        % pollute legends. Delete them explicitly before CLA to prevent an
        % earlier selection from surviving beneath the newly rendered row.
        delete(findall(imageAxes, ...
            'Tag', 'bone_surface_review_normal_overlay'));
        cla(imageAxes);
        axis(imageAxes, 'on');
        imagesc(imageAxes, ...
            [0, imageWidthMm], [0, imageHeightMm], displayedImage);
        axis(imageAxes, 'image');
        imageAxes.YDir = 'reverse';
        imageAxes.XLim = [0, imageWidthMm];
        imageAxes.YLim = [0, imageHeightMm];
        colormap(imageAxes, gray(256));
        hold(imageAxes, 'on');

        % Normalization already aligned this segmentation record by exact group
        % metadata and group-local sourceIndex.
        segmentationEntry = flatSegmentationResults(resultIndex);
        segmentationDisplayStatus = plotSegmentationOverlay( ...
            imageAxes, segmentationEntry, size(displayedImage), ...
            pixelSpacingXYMm);

        plotSurfaceResult(imageAxes, currentResult, pixelSpacingXYMm);
        plotSurfaceNormals(imageAxes, currentResult, pixelSpacingXYMm, ...
            showNormalsCheckbox.Value);
        createReviewOverlayLegend(imageAxes);
        hold(imageAxes, 'off');

        identityText = sprintf( ...
            ['%s: %d/%d | Overall %d/%d | sequence %g | ' ...
            'source %g | %s'], ...
            char(string(groupMetadata(groupIndexToRender).name)), ...
            localResultIndex, ...
            numberOfResultsByGroup(groupIndexToRender), ...
            resultIndex, numberOfResults, currentResult.sequencePosition, ...
            currentResult.sourceIndex, currentResult.status);

        % Place the extraction summary immediately below the record identity.
        % Keeping both lines in the axes title visually groups all information
        % about the selected result instead of separating metrics below the image.
        extractionSummaryText = sprintf( ...
            ['Segmentation: %s | Segments: %d | Observed: %.3g mm | ' ...
             'Interpolated: %.3g mm | Mean confidence: %.3g | %s'], ...
            char(segmentationDisplayStatus), currentResult.numberOfSegments, ...
            currentResult.observedLengthMm, ...
            currentResult.interpolatedLengthMm, ...
            currentResult.meanConfidence, ...
            describeSurfaceNormals(currentResult));
        title(imageAxes, {identityText; extractionSummaryText}, ...
            'Interpreter', 'none');
        drawnow limitrate;
    end
end


function [flatSurfaceResults, flatSegmentationResults, ...
        flatUltrasoundSequence, groupMetadata, stateIndicesByGroup] = ...
        normalizeGroupedReviewInputs( ...
            surfaceResults, segmentationResults, ultrasoundSequence)
%NORMALIZEGROUPEDREVIEWINPUTS Validate groups and align records for rendering.
% The GUI retains group tabs publicly but uses three identically ordered flat
% arrays internally so row selection does not repeat metadata searches.
%
% Inputs:
%   surfaceResults      : Grouped extracted surface results.
%   segmentationResults : Grouped segmentation results.
%   ultrasoundSequence  : Grouped source ultrasound records.
%
% Outputs:
%   flatSurfaceResults      : Surface records in group/local display order.
%   flatSegmentationResults : Segmentation records aligned to surface records.
%   flatUltrasoundSequence  : Ultrasound records aligned to surface records.
%   groupMetadata           : Surface group name, bone, and path metadata.
%   stateIndicesByGroup     : Flat record indices for every surface group.

requiredGroupFields = {'name', 'bone', 'path', 'data'};
validateReviewGroupedArray( ...
    surfaceResults, requiredGroupFields, ...
    'createBoneSurfaceReviewGUI:InvalidSurfaceResults', 'surfaceResults');
validateReviewGroupedArray( ...
    segmentationResults, requiredGroupFields, ...
    'createBoneSurfaceReviewGUI:InvalidSegmentationResults', ...
    'segmentationResults');
validateReviewGroupedArray( ...
    ultrasoundSequence, requiredGroupFields, ...
    'createBoneSurfaceReviewGUI:InvalidUltrasoundSequence', ...
    'ultrasoundSequence');

numberOfGroups = numel(surfaceResults);
if numel(segmentationResults) ~= numberOfGroups || ...
        numel(ultrasoundSequence) ~= numberOfGroups
    error('createBoneSurfaceReviewGUI:GroupSetMismatch', ...
        'All review inputs must contain the same source-directory group set.');
end

[surfaceNames, surfaceBones, surfacePaths] = readReviewGroupMetadata( ...
    surfaceResults, 'createBoneSurfaceReviewGUI:InvalidSurfaceResults', ...
    'surfaceResults');
[segmentationNames, segmentationBones, segmentationPaths] = ...
    readReviewGroupMetadata( ...
        segmentationResults, ...
        'createBoneSurfaceReviewGUI:InvalidSegmentationResults', ...
        'segmentationResults');
[ultrasoundNames, ultrasoundBones, ultrasoundPaths] = ...
    readReviewGroupMetadata( ...
        ultrasoundSequence, ...
        'createBoneSurfaceReviewGUI:InvalidUltrasoundSequence', ...
        'ultrasoundSequence');

validateUniqueReviewGroupIdentities( ...
    surfaceNames, surfaceBones, surfacePaths, 'surfaceResults');
validateUniqueReviewGroupIdentities( ...
    segmentationNames, segmentationBones, segmentationPaths, ...
    'segmentationResults');
validateUniqueReviewGroupIdentities( ...
    ultrasoundNames, ultrasoundBones, ultrasoundPaths, ...
    'ultrasoundSequence');

% Preserve only outer metadata here; aligned record data is stored separately.
groupMetadataTemplate = struct('name', '', 'bone', '', 'path', '');
groupMetadata = repmat(groupMetadataTemplate, 1, numberOfGroups);
stateIndicesByGroup = cell(1, numberOfGroups);
flatSurfaceResults = struct([]);
flatSegmentationResults = struct([]);
flatUltrasoundSequence = struct([]);
nextStateIndex = 1;
usedSegmentationGroups = false(1, numberOfGroups);
usedUltrasoundGroups = false(1, numberOfGroups);

requiredSurfaceFields = { ...
    'sequencePosition', 'sourceIndex', 'status', 'numberOfSegments', ...
    'observedLengthMm', 'interpolatedLengthMm', 'meanConfidence', ...
    'surfaceRowByColumn', 'observedColumnMask', ...
    'interpolatedColumnMask', 'segmentIdByColumn'};
requiredSegmentationFields = {'sourceIndex', 'pixelCoordinates'};
requiredUltrasoundFields = {'sourceIndex', 'plane'};

for surfaceGroupIndex = 1:numberOfGroups
    matchingSegmentationGroup = find( ...
        segmentationNames == surfaceNames(surfaceGroupIndex) & ...
        segmentationBones == surfaceBones(surfaceGroupIndex) & ...
        segmentationPaths == surfacePaths(surfaceGroupIndex));
    matchingUltrasoundGroup = find( ...
        ultrasoundNames == surfaceNames(surfaceGroupIndex) & ...
        ultrasoundBones == surfaceBones(surfaceGroupIndex) & ...
        ultrasoundPaths == surfacePaths(surfaceGroupIndex));
    if numel(matchingSegmentationGroup) ~= 1 || ...
            numel(matchingUltrasoundGroup) ~= 1
        error('createBoneSurfaceReviewGUI:GroupSetMismatch', ...
            'No unique input groups match surfaceResults group %d.', ...
            surfaceGroupIndex);
    end
    usedSegmentationGroups(matchingSegmentationGroup) = true;
    usedUltrasoundGroups(matchingUltrasoundGroup) = true;

    surfaceGroupData = surfaceResults(surfaceGroupIndex).data;
    segmentationGroupData = ...
        segmentationResults(matchingSegmentationGroup).data;
    ultrasoundGroupData = ultrasoundSequence(matchingUltrasoundGroup).data;
    surfaceSourceIndices = validateReviewGroupRecords( ...
        surfaceGroupData, requiredSurfaceFields, ...
        'createBoneSurfaceReviewGUI:InvalidSurfaceResults', ...
        'surfaceResults', surfaceGroupIndex);
    segmentationSourceIndices = validateReviewGroupRecords( ...
        segmentationGroupData, requiredSegmentationFields, ...
        'createBoneSurfaceReviewGUI:InvalidSegmentationResults', ...
        'segmentationResults', matchingSegmentationGroup);
    ultrasoundSourceIndices = validateReviewGroupRecords( ...
        ultrasoundGroupData, requiredUltrasoundFields, ...
        'createBoneSurfaceReviewGUI:InvalidUltrasoundSequence', ...
        'ultrasoundSequence', matchingUltrasoundGroup);

    [hasSegmentation, segmentationLocalIndices] = ismember( ...
        surfaceSourceIndices, segmentationSourceIndices);
    [hasUltrasound, ultrasoundLocalIndices] = ismember( ...
        surfaceSourceIndices, ultrasoundSourceIndices);
    hasExactRecordSets = ...
        numel(surfaceSourceIndices) == numel(segmentationSourceIndices) && ...
        numel(surfaceSourceIndices) == numel(ultrasoundSourceIndices) && ...
        all(hasSegmentation) && all(hasUltrasound) && ...
        all(ismember(segmentationSourceIndices, surfaceSourceIndices)) && ...
        all(ismember(ultrasoundSourceIndices, surfaceSourceIndices));
    if ~hasExactRecordSets
        error('createBoneSurfaceReviewGUI:FrameSetMismatch', ...
            ['Surface, segmentation, and ultrasound records in group "%s" ' ...
            'must contain identical sourceIndex sets.'], ...
            surfaceNames(surfaceGroupIndex));
    end

    numberOfGroupResults = numel(surfaceGroupData);
    currentStateIndices = ...
        nextStateIndex:(nextStateIndex + numberOfGroupResults - 1);
    stateIndicesByGroup{surfaceGroupIndex} = currentStateIndices;
    groupMetadata(surfaceGroupIndex).name = ...
        surfaceResults(surfaceGroupIndex).name;
    groupMetadata(surfaceGroupIndex).bone = ...
        surfaceResults(surfaceGroupIndex).bone;
    groupMetadata(surfaceGroupIndex).path = ...
        surfaceResults(surfaceGroupIndex).path;
    if numberOfGroupResults == 0
        continue;
    end

    % Reorder matching records into surface local order before appending. The
    % producer-owned record structs retain their complete optional fields.
    surfaceDataRow = reshape(surfaceGroupData, 1, []);
    segmentationDataRow = reshape( ...
        segmentationGroupData(segmentationLocalIndices), 1, []);
    ultrasoundDataRow = reshape( ...
        ultrasoundGroupData(ultrasoundLocalIndices), 1, []);
    if isempty(flatSurfaceResults)
        flatSurfaceResults = surfaceDataRow;
        flatSegmentationResults = segmentationDataRow;
        flatUltrasoundSequence = ultrasoundDataRow;
    else
        flatSurfaceResults = [flatSurfaceResults, surfaceDataRow]; %#ok<AGROW>
        flatSegmentationResults = ...
            [flatSegmentationResults, segmentationDataRow]; %#ok<AGROW>
        flatUltrasoundSequence = ...
            [flatUltrasoundSequence, ultrasoundDataRow]; %#ok<AGROW>
    end
    nextStateIndex = nextStateIndex + numberOfGroupResults;
end

if ~all(usedSegmentationGroups) || ~all(usedUltrasoundGroups)
    error('createBoneSurfaceReviewGUI:GroupSetMismatch', ...
        'All review inputs must contain the same source-directory group set.');
end
end


function validateReviewGroupedArray( ...
        groupedData, requiredFields, errorIdentifier, inputName)
%VALIDATEREVIEWGROUPEDARRAY Require a nonempty grouped outer struct vector.
% Flat legacy arrays are rejected before any sourceIndex can be treated as a
% global key.
%
% Inputs:
%   groupedData     : Candidate grouped review input.
%   requiredFields  : Required outer group field names.
%   errorIdentifier : Public error identifier for this input.
%   inputName       : Input name used in the validation message.
%
% Outputs:
%   None. The function throws for malformed or flat input.

if ~isstruct(groupedData) || ~isvector(groupedData) || ...
        isempty(groupedData) || ~all(isfield(groupedData, requiredFields))
    error(errorIdentifier, ...
        ['%s must be a non-empty grouped struct vector containing name, ' ...
        'bone, path, and data. Flat input is unsupported.'], inputName);
end
end


function [groupNames, groupBones, groupPaths] = readReviewGroupMetadata( ...
        groupedData, errorIdentifier, inputName)
%READREVIEWGROUPMETADATA Validate and normalize exact group identity fields.
% Normalization supports character vectors and scalar strings without changing
% the original metadata shown in tabs or returned by extraction.
%
% Inputs:
%   groupedData     : Grouped review input whose metadata is being read.
%   errorIdentifier : Public error identifier for malformed metadata.
%   inputName       : Input name used in validation messages.
%
% Outputs:
%   groupNames : Row string vector of group names.
%   groupBones : Row string vector of bone labels.
%   groupPaths : Row string vector of source paths.

numberOfGroups = numel(groupedData);
groupNames = strings(1, numberOfGroups);
groupBones = strings(1, numberOfGroups);
groupPaths = strings(1, numberOfGroups);
for groupIndex = 1:numberOfGroups
    metadataValues = { ...
        groupedData(groupIndex).name, groupedData(groupIndex).bone, ...
        groupedData(groupIndex).path};
    if ~all(cellfun(@isReviewTextScalar, metadataValues))
        error(errorIdentifier, ...
            '%s group %d has invalid name, bone, or path metadata.', ...
            inputName, groupIndex);
    end
    normalizedMetadata = string(metadataValues);
    if any(ismissing(normalizedMetadata)) || ...
            strlength(string(groupedData(groupIndex).name)) == 0 || ...
            strlength(string(groupedData(groupIndex).bone)) == 0
        error(errorIdentifier, ...
            '%s group %d has invalid name, bone, or path metadata.', ...
            inputName, groupIndex);
    end
    groupNames(groupIndex) = string(groupedData(groupIndex).name);
    groupBones(groupIndex) = string(groupedData(groupIndex).bone);
    groupPaths(groupIndex) = string(groupedData(groupIndex).path);
end
end


function validateUniqueReviewGroupIdentities( ...
        groupNames, groupBones, groupPaths, inputName)
%VALIDATEUNIQUEREVIEWGROUPIDENTITIES Reject duplicate metadata tuples.
% A unique `(name,bone,path)` tuple is required to align reordered outer groups.
%
% Inputs:
%   groupNames : Normalized group-name string vector.
%   groupBones : Normalized bone-label string vector.
%   groupPaths : Normalized source-path string vector.
%   inputName  : Input name used in the validation message.
%
% Outputs:
%   None. The function throws when a duplicate identity is found.

for groupIndex = 1:numel(groupNames)
    duplicateMask = groupNames == groupNames(groupIndex) & ...
        groupBones == groupBones(groupIndex) & ...
        groupPaths == groupPaths(groupIndex);
    if nnz(duplicateMask) > 1
        error('createBoneSurfaceReviewGUI:DuplicateGroupIdentity', ...
            '%s contains a duplicate group identity at position %d.', ...
            inputName, groupIndex);
    end
end
end


function sourceIndices = validateReviewGroupRecords( ...
        groupData, requiredFields, errorIdentifier, inputName, groupIndex)
%VALIDATEREVIEWGROUPRECORDS Validate one group and its local source keys.
% Duplicate source indices are rejected only within the group, allowing the
% same sourceIndex to appear safely in another source-directory tab.
%
% Inputs:
%   groupData      : Candidate group-local record struct vector.
%   requiredFields : Fields needed from every record by the review GUI.
%   errorIdentifier: Public error identifier for this input type.
%   inputName      : Input name used in validation messages.
%   groupIndex     : One-based input group index used in messages.
%
% Output:
%   sourceIndices : Row vector of validated group-local source indices.

if ~isstruct(groupData) || (~isempty(groupData) && ~isvector(groupData)) || ...
        (~isempty(groupData) && ~all(isfield(groupData, requiredFields)))
    error(errorIdentifier, ...
        '%s group %d data records are missing required review fields.', ...
        inputName, groupIndex);
end

sourceIndices = zeros(1, numel(groupData));
for localIndex = 1:numel(groupData)
    sourceIndex = groupData(localIndex).sourceIndex;
    if ~isnumeric(sourceIndex) || ~isscalar(sourceIndex) || ...
            ~isreal(sourceIndex) || ~isfinite(sourceIndex)
        error(errorIdentifier, ...
            '%s group %d local sourceIndex %d must be finite and scalar.', ...
            inputName, groupIndex, localIndex);
    end
    sourceIndices(localIndex) = double(sourceIndex);
    validateReviewRecordDetails( ...
        groupData(localIndex), inputName, groupIndex, localIndex, ...
        errorIdentifier);
end
if numel(unique(sourceIndices)) ~= numel(sourceIndices)
    error(errorIdentifier, ...
        '%s group %d contains duplicate sourceIndex values.', ...
        inputName, groupIndex);
end
end


function validateReviewRecordDetails( ...
        record, inputName, groupIndex, localIndex, errorIdentifier)
%VALIDATEREVIEWRECORDDETAILS Check fields consumed after group matching.
% Running these checks during normalization prevents malformed image or surface
% values from creating a figure that fails only when its row is selected.
%
% Inputs:
%   record          : One surface, segmentation, or ultrasound record.
%   inputName       : Input category selecting the relevant validation branch.
%   groupIndex      : One-based outer input group index used in messages.
%   localIndex      : One-based local record index used in messages.
%   errorIdentifier : Public error identifier for this input category.
%
% Outputs:
%   None. The function throws when display data is malformed.

switch inputName
    case 'surfaceResults'
        hasValidSequencePosition = ...
            isnumeric(record.sequencePosition) && ...
            isscalar(record.sequencePosition) && ...
            isreal(record.sequencePosition) && ...
            isfinite(record.sequencePosition);
        hasValidStatus = isReviewTextScalar(record.status) && ...
            ~ismissing(string(record.status));
        scalarSummaryValues = [ ...
            record.numberOfSegments, record.observedLengthMm, ...
            record.interpolatedLengthMm, record.meanConfidence];
        hasValidSummaries = isnumeric(scalarSummaryValues) && ...
            isreal(scalarSummaryValues) && numel(scalarSummaryValues) == 4 && ...
            all(~isinf(scalarSummaryValues));
        surfaceRows = record.surfaceRowByColumn;
        observedMask = record.observedColumnMask;
        interpolatedMask = record.interpolatedColumnMask;
        segmentIds = record.segmentIdByColumn;
        hasValidColumnData = ...
            isnumeric(surfaceRows) && isvector(surfaceRows) && ...
            isreal(surfaceRows) && ...
            (islogical(observedMask) || isnumeric(observedMask)) && ...
            isvector(observedMask) && ...
            (islogical(interpolatedMask) || ...
            isnumeric(interpolatedMask)) && ...
            isvector(interpolatedMask) && isnumeric(segmentIds) && ...
            isvector(segmentIds) && ...
            numel(observedMask) == numel(surfaceRows) && ...
            numel(interpolatedMask) == numel(surfaceRows) && ...
            numel(segmentIds) == numel(surfaceRows);
        if ~(hasValidSequencePosition && hasValidStatus && ...
                hasValidSummaries && hasValidColumnData)
            error(errorIdentifier, ...
                ['surfaceResults group %d, local position %d contains ' ...
                'invalid table or surface-overlay values.'], ...
                groupIndex, localIndex);
        end

    case 'segmentationResults'
        pixelCoordinates = record.pixelCoordinates;
        if ~isnumeric(pixelCoordinates) || ~isreal(pixelCoordinates) || ...
                ~ismatrix(pixelCoordinates) || ...
                size(pixelCoordinates, 2) ~= 2 || ...
                any(~isfinite(pixelCoordinates(:)))
            error(errorIdentifier, ...
                ['segmentationResults group %d, local position %d must ' ...
                'contain finite N-by-2 pixelCoordinates.'], ...
                groupIndex, localIndex);
        end

    case 'ultrasoundSequence'
        plane = record.plane;
        requiredPlaneFields = {'image', 'W', 'H', 'nRows', 'nCols'};
        if ~isstruct(plane) || ~isscalar(plane) || ...
                ~all(isfield(plane, requiredPlaneFields))
            error(errorIdentifier, ...
                ['ultrasoundSequence group %d, local position %d has an ' ...
                'invalid plane.'], groupIndex, localIndex);
        end
        hasValidImage = isnumeric(plane.image) && ismatrix(plane.image) && ...
            ~isempty(plane.image) && isreal(plane.image) && ...
            all(isfinite(double(plane.image(:))));
        if hasValidImage
            displayedImageSize = size(plane.image.');
        else
            displayedImageSize = [nan, nan];
        end
        hasValidGeometry = ...
            isnumeric(plane.W) && isscalar(plane.W) && isreal(plane.W) && ...
            isfinite(plane.W) && plane.W > 0 && ...
            isnumeric(plane.H) && isscalar(plane.H) && isreal(plane.H) && ...
            isfinite(plane.H) && plane.H > 0 && ...
            isnumeric(plane.nRows) && isscalar(plane.nRows) && ...
            isnumeric(plane.nCols) && isscalar(plane.nCols) && ...
            isequal(displayedImageSize, [plane.nRows, plane.nCols]) && ...
            plane.nRows > 1 && plane.nCols > 1;
        if ~(hasValidImage && hasValidGeometry)
            error(errorIdentifier, ...
                ['ultrasoundSequence group %d, local position %d has ' ...
                'invalid image geometry.'], groupIndex, localIndex);
        end
end
end


function isScalarText = isReviewTextScalar(value)
%ISREVIEWTEXTSCALAR Return whether a value is one text scalar.
% This helper prevents vector strings from reaching exact group comparisons.
%
% Input:
%   value : Candidate character or string value.
%
% Output:
%   isScalarText : True for a character row or scalar string.

isScalarText = ...
    (ischar(value) && (isrow(value) || isempty(value))) || ...
    (isstring(value) && isscalar(value));
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


function plotSurfaceNormals( ...
        targetAxes, surfaceResult, pixelSpacingXYMm, normalsAreVisible)
%PLOTSURFACENORMALS Draw a sparse physical-length normal overlay.
% The saved normals stay row-aligned with the dense final curve. Displaying
% roughly one arrow every 3 mm keeps the review legible without changing or
% downsampling the stored result.
%
% Inputs:
%   targetAxes       : Axes that already display the source B-mode image.
%   surfaceResult    : Extracted surface result, possibly historical.
%   pixelSpacingXYMm : Horizontal and vertical pixel spacing in millimetres.
%   normalsAreVisible: Logical display state from the review checkbox.
%
% Outputs:
%   None. A green quiver overlay is added when compatible normals exist.

[normalDataAreAvailable, validNormalMask] = ...
    inspectSurfaceNormalData(surfaceResult);
if ~normalDataAreAvailable || ~any(validNormalMask)
    return;
end

surfaceCoordinatesXY = double(surfaceResult.surfaceCoordinatesXY);
surfaceColumns = surfaceCoordinatesXY(:, 1);
segmentIdByColumn = reshape(surfaceResult.segmentIdByColumn, 1, []);
if any(surfaceColumns ~= round(surfaceColumns)) || ...
        any(surfaceColumns < 1) || ...
        any(surfaceColumns > numel(segmentIdByColumn))
    return;
end
pointSegmentIds = double(segmentIdByColumn(surfaceColumns));

displayRows = selectNormalDisplayRows( ...
    surfaceCoordinatesXY, pointSegmentIds, validNormalMask, ...
    pixelSpacingXYMm, 3);
if isempty(displayRows)
    return;
end

basePointsMm = (surfaceCoordinatesXY(displayRows, :) - 1) .* ...
    pixelSpacingXYMm;
arrowVectorsMm = 2 .* double(surfaceResult.surfaceNormalXY(displayRows, :));
if normalsAreVisible
    overlayVisibility = 'on';
else
    overlayVisibility = 'off';
end

quiver(targetAxes, basePointsMm(:, 1), basePointsMm(:, 2), ...
    arrowVectorsMm(:, 1), arrowVectorsMm(:, 2), 0, ...
    'AutoScale', 'off', ...
    'Color', [0.10, 0.80, 0.20], ...
    'LineWidth', 1.1, ...
    'MaxHeadSize', 0.7, ...
    'Tag', 'bone_surface_review_normal_overlay', ...
    'Visible', overlayVisibility, ...
    'HandleVisibility', 'off');
end


function createReviewOverlayLegend(targetAxes)
%CREATEREVIEWOVERLAYLEGEND Create a stable MATLAB legend for review overlays.
% Some selected records legitimately contain no segmentation or surface.
% NaN-valued proxy graphics keep the legend complete and visually consistent
% without adding marks to the ultrasound image or altering stored results.
%
% Input:
%   targetAxes : Axes containing the ultrasound review visualization.
%
% Outputs:
%   None. A standard MATLAB legend is attached to targetAxes.

segmentationProxy = plot(targetAxes, NaN, NaN, '-', ...
    'Color', [1.00, 0.80, 0.05], ...
    'LineWidth', 1.2, ...
    'DisplayName', 'Segmentation');
rawSurfaceProxy = plot(targetAxes, NaN, NaN, '-', ...
    'Color', [0.90, 0.10, 0.80], ...
    'LineWidth', 0.9, ...
    'DisplayName', 'Raw surface');
observedSurfaceProxy = plot(targetAxes, NaN, NaN, '.', ...
    'Color', [1.00, 0.15, 0.10], ...
    'MarkerSize', 10, ...
    'DisplayName', 'Final observed');
interpolatedSurfaceProxy = plot(targetAxes, NaN, NaN, '.', ...
    'Color', [0.00, 0.90, 1.00], ...
    'MarkerSize', 10, ...
    'DisplayName', 'Final interpolated');
normalProxy = plot(targetAxes, NaN, NaN, '-', ...
    'Color', [0.10, 0.80, 0.20], ...
    'LineWidth', 1.1, ...
    'Marker', '>', ...
    'MarkerSize', 5, ...
    'DisplayName', 'Probe-facing normal');

reviewLegend = legend(targetAxes, ...
    [segmentationProxy, rawSurfaceProxy, observedSurfaceProxy, ...
     interpolatedSurfaceProxy, normalProxy], ...
    'Location', 'northeast', ...
    'AutoUpdate', 'off', ...
    'Interpreter', 'none');
reviewLegend.Tag = 'bone_surface_review_overlay_legend';
reviewLegend.Box = 'on';
end


function displayRows = selectNormalDisplayRows( ...
        surfaceCoordinatesXY, pointSegmentIds, validNormalMask, ...
        pixelSpacingXYMm, displaySpacingMm)
%SELECTNORMALDISPLAYROWS Select arrows by cumulative within-segment distance.
% Using cumulative curve distance, rather than a fixed column interval,
% gives comparable visual spacing on steep and shallow surfaces.
%
% Inputs:
%   surfaceCoordinatesXY : N-by-2 dense curve coordinates in pixels.
%   pointSegmentIds      : N-by-1 segment label aligned with the coordinates.
%   validNormalMask      : N-by-1 rows eligible for display.
%   pixelSpacingXYMm     : [x,y] millimetres per pixel.
%   displaySpacingMm     : Approximate cumulative distance between arrows.
%
% Outputs:
%   displayRows : Coordinate-row indices selected for quiver display.

displayRows = zeros(0, 1);
positiveSegmentIds = unique(pointSegmentIds(pointSegmentIds > 0), 'stable');
for segmentIndex = 1:numel(positiveSegmentIds)
    segmentRows = find(pointSegmentIds == positiveSegmentIds(segmentIndex));
    if isempty(segmentRows)
        continue;
    end

    segmentPointsMm = (surfaceCoordinatesXY(segmentRows, :) - 1) .* ...
        pixelSpacingXYMm;
    cumulativeDistanceMm = [0; cumsum(vecnorm(diff(segmentPointsMm), 2, 2))];
    validLocalRows = find(validNormalMask(segmentRows));
    if isempty(validLocalRows)
        continue;
    end

    selectedLocalRows = validLocalRows(1);
    lastSelectedDistanceMm = cumulativeDistanceMm(selectedLocalRows);
    for candidateIndex = 2:numel(validLocalRows)
        candidateLocalRow = validLocalRows(candidateIndex);
        if cumulativeDistanceMm(candidateLocalRow) - ...
                lastSelectedDistanceMm >= displaySpacingMm
            selectedLocalRows(end + 1, 1) = candidateLocalRow; %#ok<AGROW>
            lastSelectedDistanceMm = cumulativeDistanceMm(candidateLocalRow);
        end
    end
    displayRows = [displayRows; segmentRows(selectedLocalRows)]; %#ok<AGROW>
end
end


function description = describeSurfaceNormals(surfaceResult)
%DESCRIBESURFACENORMALS Build the compact normal-availability summary.
% Historical records intentionally report an unavailable state rather than
% preventing the rest of the review GUI from opening.
%
% Inputs:
%   surfaceResult : One current or historical extracted-surface record.
%
% Outputs:
%   description : Character vector suitable for the result summary label.

[normalDataAreAvailable, validNormalMask] = ...
    inspectSurfaceNormalData(surfaceResult);
if ~normalDataAreAvailable
    description = 'Normals: unavailable';
    return;
end
description = sprintf('Valid normals: %d/%d', ...
    nnz(validNormalMask), size(surfaceResult.surfaceCoordinatesXY, 1));
end


function [normalDataAreAvailable, validNormalMask] = ...
        inspectSurfaceNormalData(surfaceResult)
%INSPECTSURFACENORMALDATA Safely inspect optional current-schema fields.
% This lenient display check protects review of old files while omitting any
% malformed or nonfinite vectors from the overlay.
%
% Inputs:
%   surfaceResult : One extracted-surface result record.
%
% Outputs:
%   normalDataAreAvailable : True when both fields have row-aligned shapes.
%   validNormalMask        : Logical rows that are masked valid and finite.

normalDataAreAvailable = false;
validNormalMask = false(0, 1);
if ~isfield(surfaceResult, 'surfaceNormalXY') || ...
        ~isfield(surfaceResult, 'surfaceNormalMask') || ...
        ~isfield(surfaceResult, 'surfaceCoordinatesXY')
    return;
end

numberOfPoints = size(surfaceResult.surfaceCoordinatesXY, 1);
surfaceNormalXY = surfaceResult.surfaceNormalXY;
surfaceNormalMask = surfaceResult.surfaceNormalMask;
if ~isnumeric(surfaceNormalXY) || ...
        ~isequal(size(surfaceNormalXY), [numberOfPoints, 2]) || ...
        ~islogical(surfaceNormalMask) || ...
        ~isequal(size(surfaceNormalMask), [numberOfPoints, 1])
    return;
end

normalDataAreAvailable = true;
validNormalMask = surfaceNormalMask & all(isfinite(surfaceNormalXY), 2);
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
