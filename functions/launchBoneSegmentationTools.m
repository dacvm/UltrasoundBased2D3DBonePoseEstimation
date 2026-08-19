function [segmentationFigure, segmentationResults] = ...
        launchBoneSegmentationTools( ...
        ultrasoundSequence, outputDirectory, sourceUltrasoundFile)
%LAUNCHBONESEGMENTATIONTOOLS Open the ultrasound segmentation mock-up.
% This function builds an interactive tool for reviewing an ultrasound
% sequence, tuning a simple three-stage image-processing pipeline, optionally
% limiting the final result with a per-image freehand area, and exporting the
% resulting 2D bone-boundary pixel coordinates. It is needed to test the
% intended user workflow before a validated bone-specific segmentation method
% is available.
%
% Inputs:
%   ultrasoundSequence : Source-directory group struct vector. Every group
%                        contains name, bone, path, and data. Each data record
%                        contains sourceIndex and plane, where plane supplies
%                        the stored image, physical dimensions, and metadata.
%   outputDirectory    : Existing directory suggested by the MAT-file export
%                        dialog when the user presses Export.
%   sourceUltrasoundFile : Full path of the MAT-file that supplied
%                          ultrasoundSequence. The export stores this path so
%                          later processing can identify the source dataset.
%
% Outputs:
%   segmentationFigure : Handle to the non-blocking uifigure that owns the
%                        tabbed tables, image preview, controls, and state.
%   segmentationResults: Source-directory groups returned after the first
%                        successful export when this second output is requested.
%                        Each group retains name, bone, path, and grouped result
%                        data. Closing before export returns an empty struct.
%                        With one output, the UI stays non-blocking.

% Preserve the existing non-blocking API unless the caller explicitly requests
% final results as a second output.
shouldWaitForSegmentationResults = nargout >= 2;
segmentationResults = struct( ...
    'name', {}, ...
    'bone', {}, ...
    'path', {}, ...
    'data', {});

%% VALIDATE AND PREPARE THE INPUT DATA

% Normalize the directory once so callbacks can use one simple character path.
outputDirectory = char(string(outputDirectory));

% Check every field used by the UI before creating a partially working window.
validateBoneSegmentationInputs(ultrasoundSequence, outputDirectory);

% Keep all processing arrays flat internally so the established segmentation
% pipeline can be reused. These mappings preserve the public group and local
% identity and make repeated sourceIndex values in different groups safe.
numberOfGroups = numel(ultrasoundSequence);
numberOfImagesByGroup = arrayfun( ...
    @(sequenceGroup) numel(sequenceGroup.data), ultrasoundSequence);
numberOfImages = sum(numberOfImagesByGroup);
stateIndicesByGroup = cell(1, numberOfGroups);
groupIndexByState = zeros(1, numberOfImages);
localIndexByState = zeros(1, numberOfImages);

% Preallocate from the first real record because validation guarantees at
% least one image across all source groups.
firstNonemptyGroupIndex = find(numberOfImagesByGroup > 0, 1);
firstUltrasoundRecord = ...
    ultrasoundSequence(firstNonemptyGroupIndex).data(1);
flatRecordTemplate = struct( ...
    'sourceIndex', firstUltrasoundRecord.sourceIndex, ...
    'plane', firstUltrasoundRecord.plane);
flatUltrasoundSequence = repmat( ...
    flatRecordTemplate, 1, numberOfImages);
nextStateIndex = 1;
for groupIndex = 1:numberOfGroups
    currentGroupImageCount = numberOfImagesByGroup(groupIndex);
    currentStateIndices = ...
        nextStateIndex:(nextStateIndex + currentGroupImageCount - 1);
    stateIndicesByGroup{groupIndex} = currentStateIndices;
    if currentGroupImageCount == 0
        continue;
    end

    % Copy only the grouped public-contract fields. Input records may carry
    % unrelated extra fields, and those should not make otherwise valid groups
    % structurally incompatible with the internal flat processing array.
    currentGroupData = reshape( ...
        ultrasoundSequence(groupIndex).data, 1, []);
    for localImageIndex = 1:currentGroupImageCount
        currentStateIndex = currentStateIndices(localImageIndex);
        flatUltrasoundSequence(currentStateIndex).sourceIndex = ...
            currentGroupData(localImageIndex).sourceIndex;
        flatUltrasoundSequence(currentStateIndex).plane = ...
            currentGroupData(localImageIndex).plane;
    end
    groupIndexByState(currentStateIndices) = groupIndex;
    localIndexByState(currentStateIndices) = 1:currentGroupImageCount;
    nextStateIndex = nextStateIndex + currentGroupImageCount;
end

% Build the parameter defaults from the first image. Only the threshold is
% data-dependent; all other controls use neutral processing values.
defaultParameters = createDefaultProcessingParameters( ...
    flatUltrasoundSequence(1).plane.image);
lastCommittedParameters = defaultParameters;
currentParameters = defaultParameters;

% Store committed results separately from the live preview. This prevents a
% slider movement from silently replacing a result until navigation or export.
committedParameters = repmat(defaultParameters, 1, numberOfImages);
committedMasks = cell(1, numberOfImages);
committedCoordinates = cell(1, numberOfImages);
committedSegmentationAreaMasks = cell(1, numberOfImages);
committedUsesCustomSegmentationArea = false(1, numberOfImages);
isImageProcessed = false(1, numberOfImages);
pointCounts = zeros(numberOfImages, 1);
statusValues = repmat("Unprocessed", numberOfImages, 1);
areaStatusValues = repmat("Full", numberOfImages, 1);

% Keep quality as an ordered category so sorting places rows that need work
% before good results. Unprocessed previews use the neutral None label.
blobQualityCategoryNames = { ...
    'None', 'No blobs', 'Bad', 'Fair', 'Good'};
blobQualityValues = categorical( ...
    repmat({'None'}, numberOfImages, 1), ...
    blobQualityCategoryNames, ...
    'Ordinal', true);

% Start with the first image in the first nonempty source group. Empty groups
% remain visible as tabs but cannot supply the initial processing parameters.
currentImageIndex = 1;
activeGroupIndex = groupIndexByState(currentImageIndex);
hasActiveImage = true;
lastSelectedLocalIndexByGroup = zeros(1, numberOfGroups);
lastSelectedLocalIndexByGroup(activeGroupIndex) = ...
    localIndexByState(currentImageIndex);
currentPreviewImage = uint8([]);
currentPreviewMask = false(0, 0);
currentPreviewCoordinates = zeros(0, 2);
currentSegmentationAreaMask = true(size( ...
    flatUltrasoundSequence(1).plane.image.'));
currentUsesCustomSegmentationArea = false;

% Track user work separately from successful exports so close warnings are
% shown only when there is something that could be lost.
currentImageHasUserEdits = false;
hasUnexportedCommittedChanges = false;
isSynchronizingTableSelection = false;
isDrawingSegmentationArea = false;
isApplyingParameters = false;

%% BUILD THE GROUPED TABLE DATA

% Read only compact metadata into one table per source group. Large images and
% masks stay in the flat internal sequence and committed result containers.
tableDataByGroup = cell(1, numberOfGroups);
for groupIndex = 1:numberOfGroups
    currentStateIndices = stateIndicesByGroup{groupIndex};
    currentImageCount = numel(currentStateIndices);
    sequencePositions = (1:currentImageCount).';
    sourceIndices = zeros(currentImageCount, 1);
    boneCodes = strings(currentImageCount, 1);
    snapshotGroups = strings(currentImageCount, 1);

    for localImageIndex = 1:currentImageCount
        currentRecord = ultrasoundSequence(groupIndex).data(localImageIndex);
        currentPlane = currentRecord.plane;
        sourceIndices(localImageIndex) = double(currentRecord.sourceIndex);
        boneCodes(localImageIndex) = string(currentPlane.bone);
        snapshotGroups(localImageIndex) = string(currentPlane.snapshotName);
    end

    % SequencePosition is local to the group and remains stable after sorting.
    tableDataByGroup{groupIndex} = table( ...
        sequencePositions, sourceIndices, boneCodes, snapshotGroups, ...
        statusValues(currentStateIndices), blobQualityValues(currentStateIndices), ...
        areaStatusValues(currentStateIndices), pointCounts(currentStateIndices), ...
        'VariableNames', { ...
            'SequencePosition', 'SourceIndex', 'Bone', 'SnapshotGroup', ...
            'Status', 'BlobQuality', 'Area', 'PointCount'});
end

%% CREATE THE THREE-COLUMN USER INTERFACE

% Use a wide figure so the sequence table, image, and staged controls can be
% inspected at the same time on a normal desktop display.
segmentationFigure = uifigure( ...
    'Name', 'Semi-Automatic Bone Segmentation Tool', ...
    'Position', [20, 60, 1880, 900], ...
    'WindowKeyPressFcn', @handleKeyboardShortcut, ...
    'CloseRequestFcn', @handleCloseRequest, ...
    'Tag', 'bone_segmentation_tool_figure');

% Give the image the flexible center column while keeping the table and
% processing controls wide enough for readable labels.
mainGrid = uigridlayout(segmentationFigure, [1, 3], ...
    'ColumnWidth', {650, '1x', 420}, ...
    'Padding', [10, 10, 10, 10], ...
    'ColumnSpacing', 10);

% Put the directory tabs inside a titled panel so the three interface
% responsibilities remain visually clear to a first-time user.
tablePanel = uipanel(mainGrid, ...
    'Title', 'Ultrasound Sequence by Source Directory', ...
    'Tag', 'bone_segmentation_table_panel');
tablePanel.Layout.Row = 1;
tablePanel.Layout.Column = 1;
tableGrid = uigridlayout(tablePanel, [1, 1], ...
    'Padding', [5, 5, 5, 5]);

% Create one independently sortable table tab for every source directory.
% Group indices stored on tabs and tables give callbacks the first part of the
% composite image identity without relying on visible titles.
sequenceTabGroup = uitabgroup(tableGrid, ...
    'Tag', 'bone_segmentation_sequence_tab_group');
sequenceTabs = gobjects(1, numberOfGroups);
sequenceTables = gobjects(1, numberOfGroups);

% Reuse one style object per quality level so every table presents the same
% soft colors and marker meanings without loading external icon files.
blobQualityStyles = createBlobQualityStyles();
blobQualityTooltip = sprintf([ ...
    'Blob quality uses 8-connected regions in the final segmentation mask.\n' ...
    'Good: 1 | Fair: 2-5 | Bad: more than 5 | ' ...
    'No blobs: 0 | None: unprocessed']);
for groupIndex = 1:numberOfGroups
    sequenceTabs(groupIndex) = uitab(sequenceTabGroup, ...
        'Title', char(string(ultrasoundSequence(groupIndex).name)), ...
        'Tag', sprintf('bone_segmentation_sequence_tab_%d', groupIndex));
    sequenceTabs(groupIndex).UserData = groupIndex;

    % A one-cell grid makes each table fill its tab when the figure resizes.
    currentTabGrid = uigridlayout(sequenceTabs(groupIndex), [1, 1], ...
        'Padding', [0, 0, 0, 0]);
    currentTableData = tableDataByGroup{groupIndex};
    sequenceTables(groupIndex) = uitable(currentTabGrid, ...
        'Data', currentTableData, ...
        'ColumnName', { ...
            'Position', 'Source', 'Bone', 'Snapshot group', ...
            'Status', 'Blob quality', 'Area', 'Points'}, ...
        'ColumnWidth', {65, 60, 45, 110, 80, 115, 65, 55}, ...
        'ColumnEditable', false(1, width(currentTableData)), ...
        'ColumnSortable', true(1, width(currentTableData)), ...
        'SelectionType', 'row', ...
        'Multiselect', 'off', ...
        'Tooltip', blobQualityTooltip, ...
        'Tag', sprintf('bone_segmentation_sequence_table_%d', groupIndex));
    sequenceTables(groupIndex).UserData = groupIndex;

    % Apply the initial gray badges, including the valid empty-table case.
    applyBlobQualityTableStyles( ...
        sequenceTables(groupIndex), blobQualityStyles);

    % Empty groups keep a visible tab and table, but the table itself has no
    % meaningful selection until the user returns to a populated group.
    if numberOfImagesByGroup(groupIndex) == 0
        sequenceTables(groupIndex).Enable = 'off';
    end
end

% The center panel owns one reusable axes so navigation does not create a new
% graphics tree for every ultrasound image.
imagePanel = uipanel(mainGrid, ...
    'Title', 'Ultrasound Image', ...
    'Tag', 'bone_segmentation_image_panel');
imagePanel.Layout.Row = 1;
imagePanel.Layout.Column = 2;
imageGrid = uigridlayout(imagePanel, [1, 1], ...
    'Padding', [5, 5, 5, 5]);
imageAxes = uiaxes(imageGrid, ...
    'Tag', 'bone_segmentation_image_axes');
xlabel(imageAxes, 'Width (mm)');
ylabel(imageAxes, 'Height (mm)');
box(imageAxes, 'on');
colormap(imageAxes, gray(256));

% Place the four processing stages directly in the right column. Avoiding an
% outer panel leaves its former title, border, and padding space available to
% the controls inside each stage.
% Let the workflow panel use only the height required by its controls so no
% unused space remains below the export button when the window is resized.
parametersGrid = uigridlayout(mainGrid, [4, 1], ...
    'RowHeight', {190, 220, '1x', 'fit'}, ...
    'Padding', [0, 0, 0, 0], ...
    'RowSpacing', 6);
parametersGrid.Layout.Row = 1;
parametersGrid.Layout.Column = 3;

%% CREATE THE PREPROCESSING CONTROLS

preprocessingPanel = uipanel(parametersGrid, ...
    'Title', 'Preprocessing', ...
    'Tag', 'bone_segmentation_preprocessing_panel');
preprocessingPanel.Layout.Row = 1;
preprocessingPanel.Layout.Column = 1;
preprocessingGrid = uigridlayout(preprocessingPanel, [4, 3], ...
    'RowHeight', {24, 42, 24, 42}, ...
    'ColumnWidth', {95, '1x', 75}, ...
    'Padding', [8, 8, 8, 8], ...
    'RowSpacing', 4);

brightnessLabel = uilabel(preprocessingGrid, ...
    'Text', 'Brightness', ...
    'Tooltip', 'Add an intensity offset before thresholding.');
brightnessLabel.Layout.Row = 1;
brightnessLabel.Layout.Column = [1, 2];
brightnessField = uieditfield(preprocessingGrid, 'numeric', ...
    'Limits', [-100, 100], ...
    'Value', currentParameters.brightness, ...
    'ValueDisplayFormat', '%.0f', ...
    'ValueChangedFcn', @(source, ~) updateContinuousParameter( ...
        'brightness', source.Value), ...
    'Tag', 'bone_segmentation_brightness_field');
brightnessField.Layout.Row = 1;
brightnessField.Layout.Column = 3;
brightnessSlider = uislider(preprocessingGrid, ...
    'Limits', [-100, 100], ...
    'Value', currentParameters.brightness, ...
    'MajorTicks', [-100, -50, 0, 50, 100], ...
    'ValueChangingFcn', @(~, eventData) updateContinuousParameter( ...
        'brightness', eventData.Value), ...
    'ValueChangedFcn', @(source, ~) updateContinuousParameter( ...
        'brightness', source.Value), ...
    'Tag', 'bone_segmentation_brightness_slider');
brightnessSlider.Layout.Row = 2;
brightnessSlider.Layout.Column = [1, 3];

contrastLabel = uilabel(preprocessingGrid, ...
    'Text', 'Contrast', ...
    'Tooltip', 'Scale intensities around mid-gray before thresholding.');
contrastLabel.Layout.Row = 3;
contrastLabel.Layout.Column = [1, 2];
contrastField = uieditfield(preprocessingGrid, 'numeric', ...
    'Limits', [0.25, 3.00], ...
    'Value', currentParameters.contrast, ...
    'ValueDisplayFormat', '%.2f', ...
    'ValueChangedFcn', @(source, ~) updateContinuousParameter( ...
        'contrast', source.Value), ...
    'Tag', 'bone_segmentation_contrast_field');
contrastField.Layout.Row = 3;
contrastField.Layout.Column = 3;
contrastSlider = uislider(preprocessingGrid, ...
    'Limits', [0.25, 3.00], ...
    'Value', currentParameters.contrast, ...
    'MajorTicks', [0.25, 1.00, 2.00, 3.00], ...
    'ValueChangingFcn', @(~, eventData) updateContinuousParameter( ...
        'contrast', eventData.Value), ...
    'ValueChangedFcn', @(source, ~) updateContinuousParameter( ...
        'contrast', source.Value), ...
    'Tag', 'bone_segmentation_contrast_slider');
contrastSlider.Layout.Row = 4;
contrastSlider.Layout.Column = [1, 3];

%% CREATE THE SEGMENTATION CONTROLS

segmentationPanel = uipanel(parametersGrid, ...
    'Title', 'Segmentation', ...
    'Tag', 'bone_segmentation_threshold_panel');
segmentationPanel.Layout.Row = 2;
segmentationPanel.Layout.Column = 1;
segmentationGrid = uigridlayout(segmentationPanel, [5, 3], ...
    'RowHeight', {24, 42, 30, 24, 30}, ...
    'ColumnWidth', {95, '1x', 75}, ...
    'Padding', [8, 8, 8, 8], ...
    'RowSpacing', 4);

thresholdLabel = uilabel(segmentationGrid, ...
    'Text', 'Threshold', ...
    'Tooltip', 'Keep preprocessed pixels at or above this value.');
thresholdLabel.Layout.Row = 1;
thresholdLabel.Layout.Column = [1, 2];
thresholdField = uieditfield(segmentationGrid, 'numeric', ...
    'Limits', [0, 255], ...
    'Value', currentParameters.threshold, ...
    'ValueDisplayFormat', '%.0f', ...
    'ValueChangedFcn', @(source, ~) updateContinuousParameter( ...
        'threshold', source.Value), ...
    'Tag', 'bone_segmentation_threshold_field');
thresholdField.Layout.Row = 1;
thresholdField.Layout.Column = 3;
thresholdSlider = uislider(segmentationGrid, ...
    'Limits', [0, 255], ...
    'Value', currentParameters.threshold, ...
    'MajorTicks', [0, 64, 128, 192, 255], ...
    'ValueChangingFcn', @(~, eventData) updateContinuousParameter( ...
        'threshold', eventData.Value), ...
    'ValueChangedFcn', @(source, ~) updateContinuousParameter( ...
        'threshold', source.Value), ...
    'Tag', 'bone_segmentation_threshold_slider');
thresholdSlider.Layout.Row = 2;
thresholdSlider.Layout.Column = [1, 3];
autoThresholdButton = uibutton(segmentationGrid, 'push', ...
    'Text', 'Auto threshold (Otsu)', ...
    'ButtonPushedFcn', @handleAutoThreshold, ...
    'Tag', 'bone_segmentation_auto_threshold_button');
autoThresholdButton.Layout.Row = 3;
autoThresholdButton.Layout.Column = [1, 3];

% Keep spatial filtering controls inside the segmentation stage while the
% image axes remain dedicated to drawing and previewing the selected area.
areaStatusLabel = uilabel(segmentationGrid, ...
    'Text', 'Area: Full image', ...
    'FontWeight', 'bold', ...
    'VerticalAlignment', 'center', ...
    'Tag', 'bone_segmentation_area_status_label');
areaStatusLabel.Layout.Row = 4;
areaStatusLabel.Layout.Column = [1, 3];

areaButtonsGrid = uigridlayout(segmentationGrid, [1, 2], ...
    'RowHeight', {'1x'}, ...
    'ColumnWidth', {'1x', '1x'}, ...
    'Padding', [0, 0, 0, 0], ...
    'ColumnSpacing', 6);
areaButtonsGrid.Layout.Row = 5;
areaButtonsGrid.Layout.Column = [1, 3];

drawAreaButton = uibutton(areaButtonsGrid, 'push', ...
    'Text', 'Draw area', ...
    'Tooltip', 'Draw or replace the segmentation area (D).', ...
    'ButtonPushedFcn', @handleDrawSegmentationArea, ...
    'Tag', 'bone_segmentation_draw_area_button');
drawAreaButton.Layout.Row = 1;
drawAreaButton.Layout.Column = 1;

useFullImageButton = uibutton(areaButtonsGrid, 'push', ...
    'Text', 'Use full image', ...
    'Enable', 'off', ...
    'ButtonPushedFcn', @handleUseFullImage, ...
    'Tag', 'bone_segmentation_use_full_image_button');
useFullImageButton.Layout.Row = 1;
useFullImageButton.Layout.Column = 2;

%% CREATE THE POST-PROCESSING CONTROLS

postprocessingPanel = uipanel(parametersGrid, ...
    'Title', 'Post-processing', ...
    'Tag', 'bone_segmentation_postprocessing_panel');
postprocessingPanel.Layout.Row = 3;
postprocessingPanel.Layout.Column = 1;
postprocessingGrid = uigridlayout(postprocessingPanel, [6, 3], ...
    'RowHeight', {24, '1x', 24, '1x', 24, '1x'}, ...
    'ColumnWidth', {150, '1x', 85}, ...
    'Padding', [8, 8, 8, 8], ...
    'RowSpacing', 4);

% A finite area range keeps the slider useful for interactive tuning. The
% paired numeric field still lets the user select exact values within it.
minimumRegionAreaSliderMaximum = 1000;

openingRadiusLabel = uilabel(postprocessingGrid, ...
    'Text', 'Opening radius (px)', ...
    'Tooltip', 'Remove small protrusions and isolated foreground details.');
openingRadiusLabel.Layout.Row = 1;
openingRadiusLabel.Layout.Column = [1, 2];
openingRadiusField = uieditfield(postprocessingGrid, 'numeric', ...
    'Limits', [0, 10], ...
    'Value', currentParameters.openingRadius, ...
    'ValueDisplayFormat', '%.0f', ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'openingRadius', source.Value), ...
    'Tag', 'bone_segmentation_opening_radius_field');
openingRadiusField.Layout.Row = 1;
openingRadiusField.Layout.Column = 3;
openingRadiusSlider = uislider(postprocessingGrid, ...
    'Limits', [0, 10], ...
    'Value', currentParameters.openingRadius, ...
    'MajorTicks', [0, 5, 10], ...
    'ValueChangingFcn', @(~, eventData) updateDiscreteParameter( ...
        'openingRadius', eventData.Value), ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'openingRadius', source.Value), ...
    'Tag', 'bone_segmentation_opening_radius_slider');
openingRadiusSlider.Layout.Row = 2;
openingRadiusSlider.Layout.Column = [1, 3];

closingRadiusLabel = uilabel(postprocessingGrid, ...
    'Text', 'Closing radius (px)', ...
    'Tooltip', 'Join nearby foreground details and close narrow gaps.');
closingRadiusLabel.Layout.Row = 3;
closingRadiusLabel.Layout.Column = [1, 2];
closingRadiusField = uieditfield(postprocessingGrid, 'numeric', ...
    'Limits', [0, 10], ...
    'Value', currentParameters.closingRadius, ...
    'ValueDisplayFormat', '%.0f', ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'closingRadius', source.Value), ...
    'Tag', 'bone_segmentation_closing_radius_field');
closingRadiusField.Layout.Row = 3;
closingRadiusField.Layout.Column = 3;
closingRadiusSlider = uislider(postprocessingGrid, ...
    'Limits', [0, 10], ...
    'Value', currentParameters.closingRadius, ...
    'MajorTicks', [0, 5, 10], ...
    'ValueChangingFcn', @(~, eventData) updateDiscreteParameter( ...
        'closingRadius', eventData.Value), ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'closingRadius', source.Value), ...
    'Tag', 'bone_segmentation_closing_radius_slider');
closingRadiusSlider.Layout.Row = 4;
closingRadiusSlider.Layout.Column = [1, 3];

minimumAreaLabel = uilabel(postprocessingGrid, ...
    'Text', 'Minimum region area (px)', ...
    'Tooltip', 'Remove connected foreground regions smaller than this area.');
minimumAreaLabel.Layout.Row = 5;
minimumAreaLabel.Layout.Column = [1, 2];
minimumAreaField = uieditfield(postprocessingGrid, 'numeric', ...
    'Limits', [0, minimumRegionAreaSliderMaximum], ...
    'Value', currentParameters.minimumRegionArea, ...
    'ValueDisplayFormat', '%.0f', ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'minimumRegionArea', source.Value), ...
    'Tag', 'bone_segmentation_minimum_area_field');
minimumAreaField.Layout.Row = 5;
minimumAreaField.Layout.Column = 3;
minimumAreaSlider = uislider(postprocessingGrid, ...
    'Limits', [0, minimumRegionAreaSliderMaximum], ...
    'Value', currentParameters.minimumRegionArea, ...
    'MajorTicks', [0, 1000, 2000, 3000, 4000, 5000], ...
    'ValueChangingFcn', @(~, eventData) updateDiscreteParameter( ...
        'minimumRegionArea', eventData.Value), ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'minimumRegionArea', source.Value), ...
    'Tag', 'bone_segmentation_minimum_area_slider');
minimumAreaSlider.Layout.Row = 6;
minimumAreaSlider.Layout.Column = [1, 3];

%% CREATE THE NAVIGATION AND EXPORT CONTROLS

workflowPanel = uipanel(parametersGrid, ...
    'Title', 'Navigation and Export', ...
    'Tag', 'bone_segmentation_workflow_panel');
workflowPanel.Layout.Row = 4;
workflowPanel.Layout.Column = 1;

% Keep the four stage panels together so callbacks can disable or enable the
% complete right column without relying on the removed outer panel.
parameterStagePanels = [ ...
    preprocessingPanel, segmentationPanel, ...
    postprocessingPanel, workflowPanel];

workflowGrid = uigridlayout(workflowPanel, [4, 2], ...
    'RowHeight', {22, 30, 32, 38}, ...
    'ColumnWidth', {'1x', '1x'}, ...
    'Padding', [8, 8, 8, 8], ...
    'RowSpacing', 6, ...
    'ColumnSpacing', 6);

workflowStatusLabel = uilabel(workflowGrid, ...
    'Text', '', ...
    'HorizontalAlignment', 'center', ...
    'FontWeight', 'bold', ...
    'Tag', 'bone_segmentation_workflow_status_label');
workflowStatusLabel.Layout.Row = 1;
workflowStatusLabel.Layout.Column = [1, 2];

% Keep the three parameter actions together in one evenly spaced row without
% changing the layout or behavior of the navigation and export buttons.
parameterActionGrid = uigridlayout(workflowGrid, [1, 3], ...
    'ColumnWidth', {'1x', '1x', '1x'}, ...
    'Padding', [0, 0, 0, 0], ...
    'ColumnSpacing', 6);
parameterActionGrid.Layout.Row = 2;
parameterActionGrid.Layout.Column = [1, 2];

resetButton = uibutton(parameterActionGrid, 'push', ...
    'Text', 'Reset', ...
    'ButtonPushedFcn', @handleResetCurrent, ...
    'Tag', 'bone_segmentation_reset_button');
resetButton.Layout.Row = 1;
resetButton.Layout.Column = 1;

applyParametersToTabButton = uibutton(parameterActionGrid, 'push', ...
    'Text', 'Apply to Tab', ...
    'Tooltip', 'Reprocess every image in the active source-directory tab.', ...
    'ButtonPushedFcn', @handleApplyParametersToTab, ...
    'Tag', 'bone_segmentation_apply_parameters_tab_button');
applyParametersToTabButton.Layout.Row = 1;
applyParametersToTabButton.Layout.Column = 2;

applyParametersToAllButton = uibutton(parameterActionGrid, 'push', ...
    'Text', 'Apply to All', ...
    'Tooltip', 'Reprocess every image using the current parameter values.', ...
    'ButtonPushedFcn', @handleApplyParametersToAll, ...
    'Tag', 'bone_segmentation_apply_parameters_all_button');
applyParametersToAllButton.Layout.Row = 1;
applyParametersToAllButton.Layout.Column = 3;

previousButton = uibutton(workflowGrid, 'push', ...
    'Text', 'Previous', ...
    'Tooltip', 'Show the previous image (A).', ...
    'ButtonPushedFcn', @handlePreviousImage, ...
    'Tag', 'bone_segmentation_previous_button');
previousButton.Layout.Row = 3;
previousButton.Layout.Column = 1;
nextButton = uibutton(workflowGrid, 'push', ...
    'Text', 'Next', ...
    'Tooltip', 'Show the next image (S).', ...
    'ButtonPushedFcn', @handleNextImage, ...
    'Tag', 'bone_segmentation_next_button');
nextButton.Layout.Row = 3;
nextButton.Layout.Column = 2;

exportButton = uibutton(workflowGrid, 'push', ...
    'Text', 'Export segmentation results', ...
    'FontWeight', 'bold', ...
    'ButtonPushedFcn', @handleExport, ...
    'Tag', 'bone_segmentation_export_button');
exportButton.Layout.Row = 4;
exportButton.Layout.Column = [1, 2];

%% SELECT AND DISPLAY THE FIRST IMAGE

% Set the initial nonempty tab and local row before registering the tab
% callback so setup cannot be mistaken for user navigation.
sequenceTabGroup.SelectedTab = sequenceTabs(activeGroupIndex);
sequenceTables(activeGroupIndex).Selection = ...
    localIndexByState(currentImageIndex);
loadCurrentImage();
for groupIndex = 1:numberOfGroups
    sequenceTables(groupIndex).SelectionChangedFcn = @handleTableSelection;
end
sequenceTabGroup.SelectionChangedFcn = @handleTabSelection;

% A caller requesting results waits for either a successful export or a close.
% One-output callers return immediately and retain the original UI behavior.
if shouldWaitForSegmentationResults && isvalid(segmentationFigure)
    uiwait(segmentationFigure);
end

    function handleKeyboardShortcut(~, eventData)
        %HANDLEKEYBOARDSHORTCUT Route unmodified keys to workflow actions.
        % This figure-level callback makes sequence review and area selection
        % available without moving focus away from the image or parameter panel.
        %
        % Inputs:
        %   ~         : Unused figure source supplied by MATLAB.
        %   eventData : Key event containing Key and Modifier values.
        %
        % Outputs:
        %   None. Recognized keys invoke the existing guarded callbacks.

        % Ignore shortcuts while an ROI is being drawn and preserve standard
        % operating-system combinations such as Ctrl+A and Alt+D.
        if ~hasActiveImage || isDrawingSegmentationArea || ...
                isApplyingParameters || ...
                ~isempty(eventData.Modifier)
            return;
        end

        switch lower(eventData.Key)
            case 'a'
                handlePreviousImage([], []);
            case 's'
                handleNextImage([], []);
            case 'd'
                handleDrawSegmentationArea([], []);
        end
    end

    function handleTabSelection(~, eventData)
        %HANDLETABSELECTION Open the remembered image for a source-directory tab.
        % This callback commits the image being left and handles empty groups
        % without allowing controls to edit an image from another directory.
        %
        % Inputs:
        %   ~         : Unused tab-group handle supplied by MATLAB.
        %   eventData : Tab event whose NewValue stores the selected group index.
        %
        % Outputs:
        %   None. The callback changes active group, preview, and control state.

        if isSynchronizingTableSelection || isempty(eventData.NewValue)
            return;
        end
        targetGroupIndex = eventData.NewValue.UserData;

        % A tab change during a modal operation would separate controls from
        % their active image, so immediately restore the prior group tab.
        if isDrawingSegmentationArea || isApplyingParameters
            isSynchronizingTableSelection = true;
            sequenceTabGroup.SelectedTab = sequenceTabs(activeGroupIndex);
            isSynchronizingTableSelection = false;
            return;
        end
        if targetGroupIndex == activeGroupIndex && hasActiveImage
            return;
        end

        isSynchronizingTableSelection = true;
        try
            % Save the live preview before leaving a populated group.
            if hasActiveImage
                commitCurrentImage();
            end
            activeGroupIndex = targetGroupIndex;

            if numberOfImagesByGroup(activeGroupIndex) == 0
                hasActiveImage = false;
                renderEmptyGroup();
                set(parameterStagePanels, 'Enable', 'off');
                refreshProgressAndNavigation();
            else
                % Restore the last local row visited in this group, or start at
                % its first acquisition on the initial visit.
                targetLocalIndex = ...
                    lastSelectedLocalIndexByGroup(activeGroupIndex);
                if targetLocalIndex < 1 || ...
                        targetLocalIndex > numberOfImagesByGroup(activeGroupIndex)
                    targetLocalIndex = 1;
                end
                currentImageIndex = ...
                    stateIndicesByGroup{activeGroupIndex}(targetLocalIndex);
                lastSelectedLocalIndexByGroup(activeGroupIndex) = ...
                    targetLocalIndex;
                hasActiveImage = true;
                set(parameterStagePanels, 'Enable', 'on');
                sequenceTables(activeGroupIndex).Selection = targetLocalIndex;
                loadCurrentImage();
            end
        catch tabChangeError
            isSynchronizingTableSelection = false;
            rethrow(tabChangeError);
        end
        isSynchronizingTableSelection = false;
    end

    function handleTableSelection(sourceTable, eventData)
        %HANDLETABLESELECTION Commit the old image and open the selected row.
        % This callback is needed so direct table navigation follows the same
        % save-on-leave behavior as the Previous and Next buttons.
        %
        % Inputs:
        %   sourceTable : Table whose UserData contains its source group index.
        %   eventData : Selection event containing the selected data row.
        %
        % Outputs:
        %   None. The callback updates the current image and UI state.

        % Ignore programmatic selection updates made during navigation.
        if isSynchronizingTableSelection || isDrawingSegmentationArea || ...
                isApplyingParameters || ...
                isempty(eventData.Selection)
            return;
        end

        % MATLAB reports the original Data row even when the table is sorted.
        selectedDataRow = eventData.Selection(1);
        currentTableData = sourceTable.Data;
        if selectedDataRow < 1 || selectedDataRow > height(currentTableData)
            return;
        end

        % Resolve the stable local position, then map the composite identity to
        % the flat processing-state index used by the established pipeline.
        targetGroupIndex = sourceTable.UserData;
        targetLocalIndex = ...
            currentTableData.SequencePosition(selectedDataRow);
        lastSelectedLocalIndexByGroup(targetGroupIndex) = targetLocalIndex;
        targetImageIndex = ...
            stateIndicesByGroup{targetGroupIndex}(targetLocalIndex);
        navigateToImage(targetImageIndex);
    end

    function renderEmptyGroup()
        %RENDEREMPTYGROUP Show a clear state for a group without selected images.
        % This helper prevents stale imagery and controls from appearing to
        % belong to an empty source-directory tab.
        %
        % Inputs:
        %   None. The active empty group is read from nested callback state.
        %
        % Outputs:
        %   None. The image axes are cleared and replaced with a message.

        cla(imageAxes);
        axis(imageAxes, 'off');
        text(imageAxes, 0.5, 0.5, sprintf( ...
            'No selected ultrasound images are available in "%s".', ...
            char(string(ultrasoundSequence(activeGroupIndex).name))), ...
            'Units', 'normalized', ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'middle', ...
            'Interpreter', 'none');
    end

    function setSequenceTablesEnabled(shouldEnable)
        %SETSEQUENCETABLESENABLED Update all populated table interaction states.
        % Centralizing this operation keeps modal drawing and batch processing
        % from leaving one directory tab interactive by mistake.
        %
        % Input:
        %   shouldEnable : Logical scalar requesting populated tables on or off.
        %
        % Outputs:
        %   None. Every populated table is updated; empty tables remain disabled.

        for groupIndexToUpdate = 1:numberOfGroups
            if shouldEnable && numberOfImagesByGroup(groupIndexToUpdate) > 0
                sequenceTables(groupIndexToUpdate).Enable = 'on';
            else
                sequenceTables(groupIndexToUpdate).Enable = 'off';
            end
        end
    end

    function handleDrawSegmentationArea(~, ~)
        %HANDLEDRAWSEGMENTATIONAREA Draw and store one enclosed freehand area.
        % This callback lets the user constrain only the final segmentation
        % result while leaving every image-processing stage full-frame.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback updates the current logical area mask and preview.

        if ~hasActiveImage || isDrawingSegmentationArea || ...
                isApplyingParameters
            return;
        end

        % Disable state-changing controls until drawfreehand completes or is
        % cancelled, preventing navigation to a different image mid-draw.
        isDrawingSegmentationArea = true;
        setSequenceTablesEnabled(false);
        set(parameterStagePanels, 'Enable', 'off');
        areaStatusLabel.Text = 'Area: Draw an enclosed region on the image';
        drawnow;

        freehandRoi = [];

        try
            numberOfRows = size(currentPreviewImage, 1);
            numberOfColumns = size(currentPreviewImage, 2);
            currentPlane = flatUltrasoundSequence(currentImageIndex).plane;
            imageWidthMillimeters = double(currentPlane.W);
            imageHeightMillimeters = double(currentPlane.H);
            pixelWidthMillimeters = ...
                imageWidthMillimeters / numberOfColumns;
            pixelHeightMillimeters = ...
                imageHeightMillimeters / numberOfRows;

            % Bound drawing to the physical image edges and use cyan so the
            % selected area remains distinct from the red result coordinates.
            freehandRoi = drawfreehand(imageAxes, ...
                'Closed', true, ...
                'Color', [0.00, 0.75, 1.00], ...
                'FaceAlpha', 0.10, ...
                'LineWidth', 1.5, ...
                'DrawingArea', [0, 0, ...
                    imageWidthMillimeters, imageHeightMillimeters], ...
                'LabelVisible', 'off', ...
                'Tag', 'bone_segmentation_freehand_area_roi');

            % Escape can return no usable ROI. Do not change the active mask
            % until a valid, nonempty replacement has been rasterized.
            hasUsableRoi = ~isempty(freehandRoi) && ...
                isvalid(freehandRoi) && size(freehandRoi.Position, 1) >= 3;
            if hasUsableRoi
                % Convert the millimeter ROI vertices back to one-based pixel
                % centers because the processing masks remain pixel arrays.
                roiColumns = ...
                    freehandRoi.Position(:, 1) / pixelWidthMillimeters + 0.5;
                roiRows = ...
                    freehandRoi.Position(:, 2) / pixelHeightMillimeters + 0.5;
                newAreaMask = poly2mask( ...
                    roiColumns, roiRows, numberOfRows, numberOfColumns);
                delete(freehandRoi);
                freehandRoi = [];

                if any(newAreaMask(:))
                    currentSegmentationAreaMask = logical(newAreaMask);
                    currentUsesCustomSegmentationArea = true;
                    currentImageHasUserEdits = true;
                    renderCurrentPreview();
                    refreshCurrentTableRow();
                else
                    uialert(segmentationFigure, ...
                        'The drawn area did not contain any image pixels.', ...
                        'Empty segmentation area', ...
                        'Icon', 'warning');
                end
            elseif ~isempty(freehandRoi) && isvalid(freehandRoi)
                % Remove a cancelled or underspecified ROI while retaining the
                % full-image or custom area that was active before drawing.
                delete(freehandRoi);
            end
        catch drawError
            % Remove any unfinished graphics object before reporting a failure.
            if ~isempty(freehandRoi) && isvalid(freehandRoi)
                delete(freehandRoi);
            end
            uialert(segmentationFigure, ...
                sprintf('Could not create the segmentation area:\n\n%s', ...
                    drawError.message), ...
                'Area drawing failed', ...
                'Icon', 'error');
        end

        % Restore controls after success, cancellation, or a handled error.
        finishSegmentationAreaDrawing();
    end

    function finishSegmentationAreaDrawing()
        %FINISHSEGMENTATIONAREADRAWING Restore controls after freehand drawing.
        % This cleanup helper prevents cancellation or errors from leaving the
        % table and processing controls disabled.
        %
        % Inputs:
        %   None. The helper uses handles from the parent function workspace.
        %
        % Outputs:
        %   None. It restores controls and refreshes area/navigation labels.

        isDrawingSegmentationArea = false;
        if isvalid(segmentationFigure)
            setSequenceTablesEnabled(true);
            set(parameterStagePanels, 'Enable', 'on');
            refreshSegmentationAreaControls();
            refreshProgressAndNavigation();
        end
    end

    function handleUseFullImage(~, ~)
        %HANDLEUSEFULLIMAGE Remove the custom area from the current image.
        % This callback restores an all-true mask without changing processing
        % parameters or area masks committed for other images.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback updates the current area state and preview.

        if isDrawingSegmentationArea || isApplyingParameters || ...
                ~currentUsesCustomSegmentationArea
            return;
        end

        currentSegmentationAreaMask = true(size(currentPreviewImage));
        currentUsesCustomSegmentationArea = false;
        currentImageHasUserEdits = true;
        renderCurrentPreview();
        refreshSegmentationAreaControls();
        refreshCurrentTableRow();
    end

    function refreshSegmentationAreaControls()
        %REFRESHSEGMENTATIONAREACONTROLS Show the current area mode and actions.
        % This helper keeps the Segmentation-panel controls synchronized after
        % drawing, clearing, navigation, or drawing cancellation.
        %
        % Inputs:
        %   None. Values come from the current per-image area state.
        %
        % Outputs:
        %   None. It updates the status label and area-action buttons.

        if currentUsesCustomSegmentationArea
            areaStatusLabel.Text = sprintf( ...
                'Area: Custom (%d pixels)', nnz(currentSegmentationAreaMask));
            drawAreaButton.Text = 'Replace area';
            useFullImageButton.Enable = 'on';
        else
            areaStatusLabel.Text = 'Area: Full image';
            drawAreaButton.Text = 'Draw area';
            useFullImageButton.Enable = 'off';
        end
        drawAreaButton.Enable = 'on';
    end

    function updateContinuousParameter(parameterName, requestedValue)
        %UPDATECONTINUOUSPARAMETER Synchronize a slider/field parameter pair.
        % This helper keeps the live preview and paired controls consistent for
        % brightness, contrast, and threshold updates.
        %
        % Inputs:
        %   parameterName : Character vector naming brightness, contrast, or
        %                   threshold.
        %   requestedValue: Numeric value requested by a slider or edit field.
        %
        % Outputs:
        %   None. The helper updates currentParameters and redraws the preview.

        switch parameterName
            case 'brightness'
                % Brightness uses whole intensity units for predictable tuning.
                newValue = round(min(max(double(requestedValue), -100), 100));
                currentParameters.brightness = newValue;
                brightnessSlider.Value = newValue;
                brightnessField.Value = newValue;
            case 'contrast'
                % Contrast remains continuous because small scale changes are useful.
                newValue = min(max(double(requestedValue), 0.25), 3.00);
                currentParameters.contrast = newValue;
                contrastSlider.Value = newValue;
                contrastField.Value = newValue;
            case 'threshold'
                % Thresholding operates on uint8 values, so fractional values
                % do not describe a different segmentation result.
                newValue = round(min(max(double(requestedValue), 0), 255));
                currentParameters.threshold = newValue;
                thresholdSlider.Value = newValue;
                thresholdField.Value = newValue;
            otherwise
                error('launchBoneSegmentationTools:UnknownContinuousParameter', ...
                    'Unknown continuous parameter: %s', parameterName);
        end

        % Remember that this preview differs from the last loaded state until
        % it is committed by navigation or export.
        currentImageHasUserEdits = true;
        renderCurrentPreview();
        refreshCurrentTableRow();
    end

    function updateDiscreteParameter(parameterName, requestedValue)
        %UPDATEDISCRETEPARAMETER Store an integer post-processing parameter.
        % This helper applies safe limits to morphology radii and region area
        % before recalculating the live segmentation preview.
        %
        % Inputs:
        %   parameterName : Character vector naming openingRadius,
        %                   closingRadius, or minimumRegionArea.
        %   requestedValue: Numeric value entered in a field or selected with
        %                   its paired slider.
        %
        % Outputs:
        %   None. The helper updates currentParameters and redraws the preview.

        switch parameterName
            case 'openingRadius'
                newValue = round(min(max(double(requestedValue), 0), 10));
                currentParameters.openingRadius = newValue;
                openingRadiusSlider.Value = newValue;
                openingRadiusField.Value = newValue;
            case 'closingRadius'
                newValue = round(min(max(double(requestedValue), 0), 10));
                currentParameters.closingRadius = newValue;
                closingRadiusSlider.Value = newValue;
                closingRadiusField.Value = newValue;
            case 'minimumRegionArea'
                % Keep the value meaningful for both the current image and the
                % finite slider range used for interactive tuning.
                maximumArea = min( ...
                    numel(flatUltrasoundSequence(currentImageIndex).plane.image), ...
                    minimumRegionAreaSliderMaximum);
                newValue = round(min(max(double(requestedValue), 0), maximumArea));
                currentParameters.minimumRegionArea = newValue;
                minimumAreaSlider.Value = newValue;
                minimumAreaField.Value = newValue;
            otherwise
                error('launchBoneSegmentationTools:UnknownDiscreteParameter', ...
                    'Unknown discrete parameter: %s', parameterName);
        end

        currentImageHasUserEdits = true;
        renderCurrentPreview();
        refreshCurrentTableRow();
    end

    function handleAutoThreshold(~, ~)
        %HANDLEAUTOTHRESHOLD Calculate an Otsu threshold for the current image.
        % The explicit button prevents brightness or contrast changes from
        % unexpectedly replacing a threshold that the user chose manually.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback updates the threshold controls and preview.

        currentStoredImage = ...
            flatUltrasoundSequence(currentImageIndex).plane.image;
        displayedImage = currentStoredImage.';
        preprocessedImage = applyBrightnessAndContrast( ...
            displayedImage, currentParameters.brightness, ...
            currentParameters.contrast);
        automaticThreshold = calculateAutomaticThreshold(preprocessedImage);
        updateContinuousParameter('threshold', automaticThreshold);
    end

    function handleResetCurrent(~, ~)
        %HANDLERESETCURRENT Restore neutral processing for the current image.
        % This callback provides a reliable way to recover from an unhelpful
        % parameter combination without affecting other committed images.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback resets controls and redraws the current image.

        currentStoredImage = ...
            flatUltrasoundSequence(currentImageIndex).plane.image;
        currentParameters = createDefaultProcessingParameters(currentStoredImage);
        currentImageHasUserEdits = true;
        writeControlsFromCurrentParameters();
        renderCurrentPreview();
        refreshCurrentTableRow();
    end

    function handleApplyParametersToTab(~, ~)
        %HANDLEAPPLYPARAMETERSTOTAB Reprocess the active directory group.
        % This callback gives users a local alternative to the existing global
        % operation while preserving each target image's segmentation area.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. A confirmed operation updates only the active tab's images.

        if ~hasActiveImage || isDrawingSegmentationArea || ...
                isApplyingParameters
            return;
        end
        targetStateIndices = stateIndicesByGroup{activeGroupIndex};
        activeGroupName = ...
            char(string(ultrasoundSequence(activeGroupIndex).name));
        confirmation = uiconfirm(segmentationFigure, ...
            sprintf([ ...
                'Apply the current processing parameters to all %d images ' ...
                'in tab "%s"?\n\nPer-image custom segmentation areas ' ...
                'will be preserved.'], ...
                numel(targetStateIndices), activeGroupName), ...
            'Apply parameters to active tab?', ...
            'Options', {'Apply to tab', 'Cancel'}, ...
            'DefaultOption', 2, ...
            'CancelOption', 2, ...
            'Icon', 'warning');
        if strcmp(confirmation, 'Cancel')
            return;
        end
        applyParametersToStateIndices( ...
            targetStateIndices, sprintf('tab "%s"', activeGroupName));
    end

    function handleApplyParametersToAll(~, ~)
        %HANDLEAPPLYPARAMETERSTOALL Reprocess every group with current settings.
        % This callback retains the original global operation while routing it
        % through the same transaction used by the tab-scoped action.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. A confirmed operation updates every internal image state.

        if ~hasActiveImage || isDrawingSegmentationArea || ...
                isApplyingParameters
            return;
        end
        confirmation = uiconfirm(segmentationFigure, ...
            sprintf([ ...
                'Apply the current processing parameters to all %d images ' ...
                'across every tab?\n\nPer-image custom segmentation areas ' ...
                'will be preserved.'], numberOfImages), ...
            'Apply parameters to all images?', ...
            'Options', {'Apply to all', 'Cancel'}, ...
            'DefaultOption', 2, ...
            'CancelOption', 2, ...
            'Icon', 'warning');
        if strcmp(confirmation, 'Cancel')
            return;
        end
        applyParametersToStateIndices(1:numberOfImages, 'all tabs');
    end

    function applyParametersToStateIndices(targetStateIndices, scopeText)
        %APPLYPARAMETERSTOSTATEINDICES Reprocess a target set transactionally.
        % All replacement masks are calculated before committed state changes,
        % so a failure cannot leave only part of a tab or dataset updated.
        %
        % Inputs:
        %   targetStateIndices : Internal flat indices selected for processing.
        %   scopeText          : Human-readable scope used in progress messages.
        %
        % Outputs:
        %   None. Successful processing replaces committed target records.

        parametersToApply = currentParameters;
        numberOfTargets = numel(targetStateIndices);
        replacementParameters = repmat( ...
            parametersToApply, 1, numberOfTargets);
        replacementMasks = cell(1, numberOfTargets);
        replacementCoordinates = cell(1, numberOfTargets);
        replacementAreaMasks = cell(1, numberOfTargets);
        replacementUsesCustomArea = false(1, numberOfTargets);
        replacementPointCounts = zeros(numberOfTargets, 1);
        replacementAreaStatus = repmat("Full", numberOfTargets, 1);
        replacementBlobQuality = blobQualityValues(targetStateIndices);

        % Resolve target areas before processing. The current image may contain
        % a live uncommitted area, while other images use committed or full areas.
        for targetPosition = 1:numberOfTargets
            targetStateIndex = targetStateIndices(targetPosition);
            displayedImageSize = size( ...
                flatUltrasoundSequence(targetStateIndex).plane.image.');
            if targetStateIndex == currentImageIndex
                replacementAreaMasks{targetPosition} = ...
                    currentSegmentationAreaMask;
                replacementUsesCustomArea(targetPosition) = ...
                    currentUsesCustomSegmentationArea;
            elseif isImageProcessed(targetStateIndex)
                replacementAreaMasks{targetPosition} = ...
                    committedSegmentationAreaMasks{targetStateIndex};
                replacementUsesCustomArea(targetPosition) = ...
                    committedUsesCustomSegmentationArea(targetStateIndex);
            else
                replacementAreaMasks{targetPosition} = true(displayedImageSize);
            end
            if replacementUsesCustomArea(targetPosition)
                replacementAreaStatus(targetPosition) = "Custom";
            end
        end

        % Block all state-changing table and parameter actions until every
        % replacement result succeeds or the transaction rolls back.
        isApplyingParameters = true;
        setSequenceTablesEnabled(false);
        set(parameterStagePanels, 'Enable', 'off');
        drawnow;

        progressDialog = [];
        try
            progressDialog = uiprogressdlg(segmentationFigure, ...
                'Title', 'Applying Segmentation Parameters', ...
                'Message', sprintf( ...
                    'Processing image 1 of %d in %s...', ...
                    numberOfTargets, scopeText), ...
                'Value', 0, ...
                'Cancelable', 'off', ...
                'Indeterminate', 'off');

            for targetPosition = 1:numberOfTargets
                targetStateIndex = targetStateIndices(targetPosition);
                progressDialog.Message = sprintf( ...
                    'Processing image %d of %d in %s...', ...
                    targetPosition, numberOfTargets, scopeText);
                [~, fullSegmentationMask, fullBoundaryCoordinates] = ...
                    applyBoneSegmentationPipeline( ...
                        flatUltrasoundSequence(targetStateIndex).plane.image, ...
                        parametersToApply);
                [replacementMasks{targetPosition}, ...
                    replacementCoordinates{targetPosition}] = ...
                    applySegmentationAreaMask( ...
                        fullSegmentationMask, fullBoundaryCoordinates, ...
                        replacementAreaMasks{targetPosition});
                replacementPointCounts(targetPosition) = size( ...
                    replacementCoordinates{targetPosition}, 1);
                replacementBlobQuality(targetPosition) = ...
                    classifySegmentationBlobQuality( ...
                    replacementMasks{targetPosition});
                progressDialog.Value = targetPosition / numberOfTargets;
                drawnow limitrate;
            end
        catch processingError
            if ~isempty(progressDialog) && isvalid(progressDialog)
                close(progressDialog);
            end
            isApplyingParameters = false;
            if isvalid(segmentationFigure)
                setSequenceTablesEnabled(true);
                set(parameterStagePanels, 'Enable', 'on');
                refreshSegmentationAreaControls();
                refreshProgressAndNavigation();
                uialert(segmentationFigure, ...
                    sprintf( ...
                        'No images were updated because processing failed:\n\n%s', ...
                        processingError.message), ...
                    'Could not apply parameters', ...
                    'Icon', 'error');
            end
            return;
        end
        if ~isempty(progressDialog) && isvalid(progressDialog)
            close(progressDialog);
        end

        % Commit only the fully calculated target records as one state change.
        committedParameters(targetStateIndices) = replacementParameters;
        committedMasks(targetStateIndices) = replacementMasks;
        committedCoordinates(targetStateIndices) = replacementCoordinates;
        committedSegmentationAreaMasks(targetStateIndices) = replacementAreaMasks;
        committedUsesCustomSegmentationArea(targetStateIndices) = ...
            replacementUsesCustomArea;
        isImageProcessed(targetStateIndices) = true;
        pointCounts(targetStateIndices) = replacementPointCounts;
        statusValues(targetStateIndices) = "Processed";
        areaStatusValues(targetStateIndices) = replacementAreaStatus;
        blobQualityValues(targetStateIndices) = replacementBlobQuality;
        lastCommittedParameters = parametersToApply;
        currentParameters = parametersToApply;
        currentSegmentationAreaMask = ...
            committedSegmentationAreaMasks{currentImageIndex};
        currentUsesCustomSegmentationArea = ...
            committedUsesCustomSegmentationArea(currentImageIndex);
        currentImageHasUserEdits = false;
        hasUnexportedCommittedChanges = true;

        refreshAllGroupTables();
        writeControlsFromCurrentParameters();
        renderCurrentPreview();

        isApplyingParameters = false;
        setSequenceTablesEnabled(true);
        set(parameterStagePanels, 'Enable', 'on');
        refreshSegmentationAreaControls();
        refreshProgressAndNavigation();
        uialert(segmentationFigure, ...
            sprintf('Applied the current parameters to %d image(s) in %s.', ...
                numberOfTargets, scopeText), ...
            'Parameters applied', ...
            'Icon', 'success');
    end

    function handlePreviousImage(~, ~)
        %HANDLEPREVIOUSIMAGE Move to the preceding ultrasound image.
        % This callback is needed for reviewing or correcting earlier committed
        % results without relying on direct table selection.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback commits and navigates when a previous image exists.

        if hasActiveImage
            navigateToImage(currentImageIndex - 1);
        end
    end

    function handleNextImage(~, ~)
        %HANDLENEXTIMAGE Move to the following ultrasound image.
        % This callback implements the main guided workflow and commits the
        % current segmentation before the next image is shown.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback commits and navigates when a next image exists.

        if hasActiveImage
            navigateToImage(currentImageIndex + 1);
        end
    end

    function navigateToImage(targetImageIndex)
        %NAVIGATETOIMAGE Commit the current result and display a target image.
        % This helper centralizes navigation so table selection and both buttons
        % apply identical state and parameter-inheritance rules.
        %
        % Input:
        %   targetImageIndex : Stable flat state position to display next.
        %
        % Outputs:
        %   None. The helper updates committed state, table selection, and preview.

        % Ignore invalid or no-op requests. Boundary buttons are disabled too,
        % but this check protects programmatic callback calls.
        if ~hasActiveImage || isDrawingSegmentationArea || ...
                isApplyingParameters || ...
                targetImageIndex < 1 || targetImageIndex > numberOfImages || ...
                targetImageIndex == currentImageIndex
            return;
        end

        % Prevent the programmatic selection assignment from starting a second
        % navigation while this one is still updating shared state.
        isSynchronizingTableSelection = true;
        try
            commitCurrentImage();
            currentImageIndex = targetImageIndex;
            activeGroupIndex = groupIndexByState(currentImageIndex);
            targetLocalIndex = localIndexByState(currentImageIndex);
            lastSelectedLocalIndexByGroup(activeGroupIndex) = targetLocalIndex;
            hasActiveImage = true;
            sequenceTabGroup.SelectedTab = sequenceTabs(activeGroupIndex);
            sequenceTables(activeGroupIndex).Selection = targetLocalIndex;
            set(parameterStagePanels, 'Enable', 'on');
            loadCurrentImage();
        catch navigationError
            isSynchronizingTableSelection = false;
            rethrow(navigationError);
        end
        isSynchronizingTableSelection = false;
    end

    function commitCurrentImage()
        %COMMITCURRENTIMAGE Save the live preview as the current image result.
        % This helper makes navigation safe by storing the complete parameter
        % set, selected area, clipped mask, and boundary coordinates together.
        %
        % Inputs:
        %   None. Values are read from the current nested callback state.
        %
        % Outputs:
        %   None. The helper updates all committed result containers.

        wasAlreadyProcessed = isImageProcessed(currentImageIndex);

        % Compare against the prior committed record so revisiting an unchanged
        % image does not create a false unexported-change warning.
        resultChanged = ~wasAlreadyProcessed || ...
            ~isequaln(committedParameters(currentImageIndex), currentParameters) || ...
            ~isequaln(committedMasks{currentImageIndex}, currentPreviewMask) || ...
            ~isequaln(committedCoordinates{currentImageIndex}, ...
                currentPreviewCoordinates) || ...
            ~isequaln(committedSegmentationAreaMasks{currentImageIndex}, ...
                currentSegmentationAreaMask) || ...
            committedUsesCustomSegmentationArea(currentImageIndex) ~= ...
                currentUsesCustomSegmentationArea;

        committedParameters(currentImageIndex) = currentParameters;
        committedMasks{currentImageIndex} = currentPreviewMask;
        committedCoordinates{currentImageIndex} = currentPreviewCoordinates;
        committedSegmentationAreaMasks{currentImageIndex} = ...
            currentSegmentationAreaMask;
        committedUsesCustomSegmentationArea(currentImageIndex) = ...
            currentUsesCustomSegmentationArea;
        isImageProcessed(currentImageIndex) = true;
        pointCounts(currentImageIndex) = size(currentPreviewCoordinates, 1);
        statusValues(currentImageIndex) = "Processed";
        if currentUsesCustomSegmentationArea
            areaStatusValues(currentImageIndex) = "Custom";
        else
            areaStatusValues(currentImageIndex) = "Full";
        end

        % The most recently committed settings become the starting point for
        % the next image that has not yet been processed.
        lastCommittedParameters = currentParameters;
        currentImageHasUserEdits = false;
        hasUnexportedCommittedChanges = ...
            hasUnexportedCommittedChanges || resultChanged;

        refreshCurrentTableRow();
        refreshProgressAndNavigation();
    end

    function loadCurrentImage()
        %LOADCURRENTIMAGE Restore saved parameters or inherit the latest settings.
        % This helper ensures processed images retain independent state while a
        % new image starts with the previous image's committed parameters.
        %
        % Inputs:
        %   None. The target is selected through currentImageIndex.
        %
        % Outputs:
        %   None. The helper updates controls, preview, table, and navigation.

        if isImageProcessed(currentImageIndex)
            currentParameters = committedParameters(currentImageIndex);
            currentSegmentationAreaMask = ...
                committedSegmentationAreaMasks{currentImageIndex};
            currentUsesCustomSegmentationArea = ...
                committedUsesCustomSegmentationArea(currentImageIndex);
        else
            currentParameters = lastCommittedParameters;
            currentSegmentationAreaMask = true(size( ...
                flatUltrasoundSequence(currentImageIndex).plane.image.'));
            currentUsesCustomSegmentationArea = false;
        end
        currentImageHasUserEdits = false;

        writeControlsFromCurrentParameters();
        renderCurrentPreview();
        refreshSegmentationAreaControls();
        refreshCurrentTableRow();
        refreshProgressAndNavigation();
    end

    function writeControlsFromCurrentParameters()
        %WRITECONTROLSFROMCURRENTPARAMETERS Synchronize all visible controls.
        % This helper is needed when navigation or reset replaces the full
        % parameter set instead of changing one individual control.
        %
        % Inputs:
        %   None. Values are read from currentParameters.
        %
        % Outputs:
        %   None. The helper writes values to sliders and numeric fields.

        brightnessSlider.Value = currentParameters.brightness;
        brightnessField.Value = currentParameters.brightness;
        contrastSlider.Value = currentParameters.contrast;
        contrastField.Value = currentParameters.contrast;
        thresholdSlider.Value = currentParameters.threshold;
        thresholdField.Value = currentParameters.threshold;
        openingRadiusSlider.Value = currentParameters.openingRadius;
        openingRadiusField.Value = currentParameters.openingRadius;
        closingRadiusSlider.Value = currentParameters.closingRadius;
        closingRadiusField.Value = currentParameters.closingRadius;
        minimumAreaSlider.Value = currentParameters.minimumRegionArea;
        minimumAreaField.Value = currentParameters.minimumRegionArea;
    end

    function renderCurrentPreview()
        %RENDERCURRENTPREVIEW Apply the pipeline and redraw the selected image.
        % This helper provides immediate visual feedback while keeping the
        % final committed result unchanged until save-on-leave or export.
        %
        % Inputs:
        %   None. The helper reads the selected image and current parameters.
        %
        % Outputs:
        %   None. It updates preview arrays and graphics in imageAxes.

        currentPlane = flatUltrasoundSequence(currentImageIndex).plane;
        [currentPreviewImage, fullSegmentationMask, ...
            fullBoundaryCoordinates] = applyBoneSegmentationPipeline( ...
            currentPlane.image, currentParameters);
        [currentPreviewMask, currentPreviewCoordinates] = ...
            applySegmentationAreaMask( ...
                fullSegmentationMask, fullBoundaryCoordinates, ...
                currentSegmentationAreaMask);

        % Place every pixel center in physical ultrasound-plane coordinates.
        % Half-pixel offsets make the outer image edges land at 0, W, and H.
        numberOfRows = size(currentPreviewImage, 1);
        numberOfColumns = size(currentPreviewImage, 2);
        imageWidthMillimeters = double(currentPlane.W);
        imageHeightMillimeters = double(currentPlane.H);
        pixelWidthMillimeters = imageWidthMillimeters / numberOfColumns;
        pixelHeightMillimeters = imageHeightMillimeters / numberOfRows;
        columnCentersMillimeters = ...
            ((1:numberOfColumns) - 0.5) * pixelWidthMillimeters;
        rowCentersMillimeters = ...
            ((1:numberOfRows) - 0.5) * pixelHeightMillimeters;

        % Replace the previous image and overlay while preserving fixed uint8
        % display limits so brightness and contrast changes remain visible.
        % Turn the axes back on because an empty tab hides them while showing
        % its explanatory message.
        cla(imageAxes);
        axis(imageAxes, 'on');
        imageHandle = imagesc(imageAxes, ...
            columnCentersMillimeters, rowCentersMillimeters, ...
            currentPreviewImage, [0, 255]);
        imageHandle.HitTest = 'off';
        imageHandle.PickableParts = 'none';
        axis(imageAxes, 'image');
        xlim(imageAxes, [0, imageWidthMillimeters]);
        ylim(imageAxes, [0, imageHeightMillimeters]);
        colormap(imageAxes, gray(256));
        hold(imageAxes, 'on');

        % Show the selected area separately from the result. Cyan marks the
        % custom area, while red remains reserved for bone-boundary points.
        if currentUsesCustomSegmentationArea
            [~, areaContour] = contour(imageAxes, ...
                columnCentersMillimeters, rowCentersMillimeters, ...
                double(currentSegmentationAreaMask), ...
                [0.5, 0.5], ...
                'Color', [0.00, 0.75, 1.00], ...
                'LineWidth', 1.5);
            areaContour.Tag = 'bone_segmentation_area_boundary_overlay';
            areaContour.HitTest = 'off';
            areaContour.PickableParts = 'none';
        end

        % Draw boundary pixels last so they remain visible over bright echoes.
        if ~isempty(currentPreviewCoordinates)
            boundaryColumnsMillimeters = ...
                (currentPreviewCoordinates(:, 2) - 0.5) * ...
                pixelWidthMillimeters;
            boundaryRowsMillimeters = ...
                (currentPreviewCoordinates(:, 1) - 0.5) * ...
                pixelHeightMillimeters;
            segmentationOverlay = plot(imageAxes, ...
                boundaryColumnsMillimeters, ...
                boundaryRowsMillimeters, ...
                'r.', ...
                'MarkerSize', 7, ...
                'Tag', 'bone_segmentation_boundary_overlay');
            segmentationOverlay.HitTest = 'off';
            segmentationOverlay.PickableParts = 'none';
        end
        hold(imageAxes, 'off');

        title(imageAxes, { ...
            sprintf('%s | Bone %s', ...
                char(string(currentPlane.snapshotName)), ...
                char(string(currentPlane.bone))), ...
            sprintf(['Tab image %d of %d | Overall %d of %d | ' ...
                'Source %g | Boundary points: %d'], ...
                localIndexByState(currentImageIndex), ...
                numberOfImagesByGroup(activeGroupIndex), ...
                currentImageIndex, numberOfImages, ...
                double(flatUltrasoundSequence(currentImageIndex).sourceIndex), ...
                size(currentPreviewCoordinates, 1))}, ...
            'Interpreter', 'none');
        xlabel(imageAxes, 'Width (mm)');
        ylabel(imageAxes, 'Height (mm)');
        drawnow limitrate;
    end

    function refreshCurrentTableRow()
        %REFRESHCURRENTTABLEROW Update status, quality, and points for one image.
        % This helper keeps the compact table synchronized without copying image
        % or mask arrays into the UI control.
        %
        % Inputs:
        %   None. The helper reads the current processing and preview state.
        %
        % Outputs:
        %   None. It updates the owning group table and preserves selection.

        currentGroupIndex = groupIndexByState(currentImageIndex);
        currentLocalIndex = localIndexByState(currentImageIndex);
        currentSequenceTable = sequenceTables(currentGroupIndex);
        currentTableData = currentSequenceTable.Data;

        % Mark a processed result as modified while its preview differs from the
        % last commit. A new image remains explicitly unprocessed until leaving.
        if isImageProcessed(currentImageIndex) && currentImageHasUserEdits
            displayedStatus = "Modified";
        elseif isImageProcessed(currentImageIndex)
            displayedStatus = "Processed";
        else
            displayedStatus = "Unprocessed";
        end

        % Do not treat an automatically rendered preview as reviewed. Once an
        % image is processed, show quality from its live preview immediately.
        if isImageProcessed(currentImageIndex)
            blobQualityValues(currentImageIndex) = ...
                classifySegmentationBlobQuality(currentPreviewMask);
        else
            blobQualityValues(currentImageIndex) = 'None';
        end

        statusValues(currentImageIndex) = displayedStatus;
        if currentUsesCustomSegmentationArea
            displayedAreaStatus = "Custom";
        else
            displayedAreaStatus = "Full";
        end
        areaStatusValues(currentImageIndex) = displayedAreaStatus;
        currentTableData.Status(currentLocalIndex) = displayedStatus;
        currentTableData.BlobQuality(currentLocalIndex) = ...
            blobQualityValues(currentImageIndex);
        currentTableData.Area(currentLocalIndex) = displayedAreaStatus;
        currentTableData.PointCount(currentLocalIndex) = ...
            size(currentPreviewCoordinates, 1);
        currentSequenceTable.Data = currentTableData;

        % Data assignment can rebuild the table's display, so restore the badge
        % targets before restoring the stable row selection.
        applyBlobQualityTableStyles(currentSequenceTable, blobQualityStyles);

        % Reapply the stable data-row selection in case table data assignment
        % caused MATLAB to rebuild its sorted display view.
        currentSequenceTable.Selection = currentLocalIndex;
    end

    function refreshAllGroupTables()
        %REFRESHALLGROUPTABLES Synchronize every table from flat result state.
        % Batch processing can affect one or many groups, so this helper maps
        % global status arrays back into each directory's local table rows.
        %
        % Inputs:
        %   None. Values come from the internal mappings and committed state.
        %
        % Outputs:
        %   None. Populated tables are refreshed and selections are restored.

        for groupIndexToRefresh = 1:numberOfGroups
            currentStateIndices = stateIndicesByGroup{groupIndexToRefresh};
            if isempty(currentStateIndices)
                continue;
            end
            currentSequenceTable = sequenceTables(groupIndexToRefresh);
            currentTableData = currentSequenceTable.Data;
            currentTableData.Status = statusValues(currentStateIndices);
            currentTableData.BlobQuality = ...
                blobQualityValues(currentStateIndices);
            currentTableData.Area = areaStatusValues(currentStateIndices);
            currentTableData.PointCount = pointCounts(currentStateIndices);
            currentSequenceTable.Data = currentTableData;

            % Batch updates can change several quality groups at once, so rebuild
            % the compact set of styled cell targets for this source table.
            applyBlobQualityTableStyles( ...
                currentSequenceTable, blobQualityStyles);

            % Restore the last stable local result rather than a visually
            % sorted row position.
            selectedLocalIndex = ...
                lastSelectedLocalIndexByGroup(groupIndexToRefresh);
            if selectedLocalIndex >= 1 && ...
                    selectedLocalIndex <= numel(currentStateIndices)
                currentSequenceTable.Selection = selectedLocalIndex;
            end
        end
    end

    function refreshProgressAndNavigation()
        %REFRESHPROGRESSANDNAVIGATION Update labels and boundary button states.
        % This helper gives users clear sequence progress and prevents navigation
        % callbacks from requesting positions outside the available data.
        %
        % Inputs:
        %   None. Values come from currentImageIndex and isImageProcessed.
        %
        % Outputs:
        %   None. It updates labels and button Enable properties.

        % Empty tabs have no active image and keep all processing controls off.
        if ~hasActiveImage
            workflowStatusLabel.Text = sprintf( ...
                '%s: no images  |  Processed: %d / %d', ...
                char(string(ultrasoundSequence(activeGroupIndex).name)), ...
                nnz(isImageProcessed), numberOfImages);
            previousButton.Enable = 'off';
            nextButton.Enable = 'off';
            return;
        end

        % Show both local group position and global guided-sequence progress.
        currentLocalIndex = localIndexByState(currentImageIndex);
        workflowStatusLabel.Text = sprintf( ...
            '%s: %d/%d  |  Overall: %d/%d  |  Processed: %d/%d', ...
            char(string(ultrasoundSequence(activeGroupIndex).name)), ...
            currentLocalIndex, numberOfImagesByGroup(activeGroupIndex), ...
            currentImageIndex, numberOfImages, ...
            nnz(isImageProcessed), numberOfImages);

        if currentImageIndex > 1
            previousButton.Enable = 'on';
        else
            previousButton.Enable = 'off';
        end
        if currentImageIndex < numberOfImages
            nextButton.Enable = 'on';
        else
            nextButton.Enable = 'off';
        end
    end

    function handleExport(~, ~)
        %HANDLEEXPORT Commit the preview and save all sequence result records.
        % This callback preserves acquisition order and explicitly retains
        % unprocessed images so downstream code can distinguish missing work.
        %
        % Inputs:
        %   ~ : Unused button source and event values supplied by MATLAB.
        %
        % Outputs:
        %   None. It writes a selected MAT-file and updates export state.

        if ~hasActiveImage || isDrawingSegmentationArea || ...
                isApplyingParameters
            return;
        end

        % Include the preview currently visible to the user before building the file.
        commitCurrentImage();

        numberUnprocessed = nnz(~isImageProcessed);
        if numberUnprocessed > 0
            confirmation = uiconfirm(segmentationFigure, ...
                sprintf(['%d image(s) are still unprocessed. They will be ' ...
                    'included with empty coordinates and status "unprocessed".'], ...
                    numberUnprocessed), ...
                'Export incomplete segmentation', ...
                'Options', {'Export all', 'Cancel'}, ...
                'DefaultOption', 1, ...
                'CancelOption', 2, ...
                'Icon', 'warning');
            if strcmp(confirmation, 'Cancel')
                return;
            end
        end

        exportTimestamp = char(datetime('now', ...
            'Format', 'yyyyMMdd_HHmmss'));
        defaultFileName = sprintf( ...
            'boneSegmentation_%s.mat', exportTimestamp);
        defaultExportPath = fullfile(outputDirectory, defaultFileName);

        [selectedFileName, selectedDirectory] = uiputfile( ...
            {'*.mat', 'MAT-files (*.mat)'}, ...
            'Export bone segmentation results', ...
            defaultExportPath);
        if isequal(selectedFileName, 0) || isequal(selectedDirectory, 0)
            return;
        end

        % Build grouped output so repeated local source indices stay scoped by
        % their source directory in both the return value and MAT-file.
        segmentationResults = buildSegmentationResults();

        % Keep the provenance metadata short and readable. These fields tell a
        % later workflow where the ultrasound data came from and how many
        % frames were included in this export.
        segmentationMetadata = struct( ...
            'createdAt', char(datetime('now')), ...
            'sourceUltrasoundFile', char(string(sourceUltrasoundFile)), ...
            'sourceVariable', 'validSnapshots', ...
            'numberOfFrames', numberOfImages);
        outputFilePath = fullfile(selectedDirectory, selectedFileName);
        try
            save(outputFilePath, ...
                'segmentationResults', 'segmentationMetadata', '-v7.3');
        catch saveError
            uialert(segmentationFigure, ...
                sprintf('Could not export segmentation results:\n\n%s', ...
                    saveError.message), ...
                'Export failed', ...
                'Icon', 'error');
            return;
        end

        hasUnexportedCommittedChanges = false;
        uialert(segmentationFigure, ...
            sprintf('Exported %d image record(s).\n\nSaved to:\n%s', ...
                numberOfImages, outputFilePath), ...
            'Export complete', ...
            'Icon', 'success');

        % Release a two-output caller only after the saved results are complete.
        if shouldWaitForSegmentationResults
            shouldWaitForSegmentationResults = false;
            uiresume(segmentationFigure);
        end
    end

    function builtResults = buildSegmentationResults()
        %BUILDSEGMENTATIONRESULTS Package results under source-directory groups.
        % This helper mirrors the ultrasound input hierarchy so each local source
        % index remains unambiguous and empty input groups remain represented.
        %
        % Inputs:
        %   None. Data is read from the nested committed state.
        %
        % Output:
        %   builtResults : Group struct array with name, bone, path, and data.
        %                  Each data array aligns with its ultrasound input group.

        resultTemplate = struct( ...
            'sequencePosition', [], ...
            'sourceIndex', [], ...
            'pixelCoordinates', zeros(0, 2), ...
            'segmentationMask', false(0, 0), ...
            'segmentationAreaMask', true(0, 0), ...
            'usesCustomSegmentationArea', false, ...
            'processingParameters', defaultParameters, ...
            'status', 'unprocessed');
        emptyResultData = repmat(resultTemplate, 1, 0);
        resultGroupTemplate = struct( ...
            'name', '', ...
            'bone', 'U', ...
            'path', '', ...
            'data', emptyResultData);
        builtResults = repmat( ...
            resultGroupTemplate, 1, numberOfGroups);

        for resultGroupIndex = 1:numberOfGroups
            builtResults(resultGroupIndex).name = ...
                ultrasoundSequence(resultGroupIndex).name;
            builtResults(resultGroupIndex).bone = ...
                ultrasoundSequence(resultGroupIndex).bone;
            builtResults(resultGroupIndex).path = ...
                ultrasoundSequence(resultGroupIndex).path;
            currentStateIndices = stateIndicesByGroup{resultGroupIndex};
            currentGroupResults = repmat( ...
                resultTemplate, 1, numel(currentStateIndices));

            for localResultIndex = 1:numel(currentStateIndices)
                resultStateIndex = currentStateIndices(localResultIndex);
                displayedImageSize = size( ...
                    flatUltrasoundSequence(resultStateIndex).plane.image.');
                currentGroupResults(localResultIndex).sequencePosition = ...
                    localResultIndex;
                currentGroupResults(localResultIndex).sourceIndex = ...
                    ultrasoundSequence(resultGroupIndex).data( ...
                    localResultIndex).sourceIndex;
                currentGroupResults(localResultIndex).processingParameters = ...
                    committedParameters(resultStateIndex);

                if isImageProcessed(resultStateIndex)
                    currentGroupResults(localResultIndex).pixelCoordinates = ...
                        committedCoordinates{resultStateIndex};
                    currentGroupResults(localResultIndex).segmentationMask = ...
                        committedMasks{resultStateIndex};
                    currentGroupResults(localResultIndex).segmentationAreaMask = ...
                        committedSegmentationAreaMasks{resultStateIndex};
                    currentGroupResults(localResultIndex).usesCustomSegmentationArea = ...
                        committedUsesCustomSegmentationArea(resultStateIndex);
                    currentGroupResults(localResultIndex).status = 'processed';
                else
                    % Correctly sized default masks preserve array conventions
                    % while status distinguishes work that was not accepted.
                    currentGroupResults(localResultIndex).pixelCoordinates = ...
                        zeros(0, 2);
                    currentGroupResults(localResultIndex).segmentationMask = ...
                        false(displayedImageSize);
                    currentGroupResults(localResultIndex).segmentationAreaMask = ...
                        true(displayedImageSize);
                    currentGroupResults(localResultIndex).usesCustomSegmentationArea = ...
                        false;
                    currentGroupResults(localResultIndex).status = 'unprocessed';
                end
            end
            builtResults(resultGroupIndex).data = currentGroupResults;
        end
    end

    function handleCloseRequest(sourceFigure, ~)
        %HANDLECLOSEREQUEST Warn before discarding work not included in an export.
        % This callback protects long manual review sessions while allowing an
        % untouched or fully exported tool to close immediately.
        %
        % Inputs:
        %   sourceFigure : uifigure requesting deletion.
        %   ~            : Unused close event supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback either keeps the UI open or deletes it.

        % Keep the axes alive until drawfreehand returns or is cancelled.
        if isDrawingSegmentationArea
            uialert(sourceFigure, ...
                'Finish or cancel the freehand area before closing the tool.', ...
                'Area drawing in progress', ...
                'Icon', 'warning');
            return;
        end

        if isApplyingParameters
            uialert(sourceFigure, ...
                'Wait for the parameter update to finish.', ...
                'Applying parameters', ...
                'Icon', 'warning');
            return;
        end

        hasWorkToProtect = hasUnexportedCommittedChanges || ...
            currentImageHasUserEdits;
        if hasWorkToProtect
            confirmation = uiconfirm(sourceFigure, ...
                ['Some segmentation work has not been exported. ' ...
                    'Closing now will discard those changes.'], ...
                'Discard unexported changes?', ...
                'Options', {'Discard changes', 'Cancel'}, ...
                'DefaultOption', 2, ...
                'CancelOption', 2, ...
                'Icon', 'warning');
            if strcmp(confirmation, 'Cancel')
                return;
            end
        end

        % A two-output caller closing before export receives the initialized
        % empty struct array rather than a misleading partial result snapshot.
        if shouldWaitForSegmentationResults
            shouldWaitForSegmentationResults = false;
            uiresume(sourceFigure);
        end

        % Delete only this tool figure; unrelated project figures stay open.
        delete(sourceFigure);
    end
end


function validateBoneSegmentationInputs(ultrasoundSequence, outputDirectory)
%VALIDATEBONESEGMENTATIONINPUTS Check data required by the segmentation UI.
% This function validates the grouped snapshot contract before graphics and
% callback state are created, producing errors close to the malformed group.
%
% Inputs:
%   ultrasoundSequence : Candidate source-directory group struct vector.
%   outputDirectory    : Candidate existing directory for export suggestions.
%
% Outputs:
%   None. The function returns silently for valid inputs and throws otherwise.

% Require at least one outer group before checking the grouped-only contract.
validateattributes(ultrasoundSequence, {'struct'}, ...
    {'vector', 'nonempty'}, mfilename, 'ultrasoundSequence');

requiredGroupFields = {'name', 'bone', 'path', 'data'};
if ~all(isfield(ultrasoundSequence, requiredGroupFields))
    error('launchBoneSegmentationTools:MissingGroupFields', ...
        ['ultrasoundSequence must contain source-directory groups with name, ' ...
        'bone, path, and data fields. Flat sequence input is unsupported.']);
end

requiredPlaneFields = { ...
    'image', 'nRows', 'nCols', 'W', 'H', 'bone', 'snapshotName'};
requiredDataFields = {'sourceIndex', 'plane'};
totalImageCount = 0;
for groupIndex = 1:numel(ultrasoundSequence)
    currentGroup = ultrasoundSequence(groupIndex);

    % Tab labels and grouped output metadata require scalar text values.
    metadataValues = {currentGroup.name, currentGroup.bone, currentGroup.path};
    for metadataIndex = 1:numel(metadataValues)
        currentMetadata = metadataValues{metadataIndex};
        isTextScalar = (ischar(currentMetadata) && ...
            (isrow(currentMetadata) || isempty(currentMetadata))) || ...
            (isstring(currentMetadata) && isscalar(currentMetadata));
        if ~isTextScalar
            error('launchBoneSegmentationTools:InvalidGroupMetadata', ...
                'Group %d name, bone, and path must be text scalars.', groupIndex);
        end
    end
    if strlength(string(currentGroup.name)) == 0 || ...
            strlength(string(currentGroup.bone)) == 0
        error('launchBoneSegmentationTools:EmptyGroupMetadata', ...
            'Group %d name and bone must not be empty.', groupIndex);
    end

    currentGroupData = currentGroup.data;
    if ~isstruct(currentGroupData) || ...
            (~isempty(currentGroupData) && ~isvector(currentGroupData))
        error('launchBoneSegmentationTools:InvalidGroupData', ...
            'ultrasoundSequence(%d).data must be a struct vector.', groupIndex);
    end
    if isempty(currentGroupData)
        continue;
    end
    if ~all(isfield(currentGroupData, requiredDataFields))
        error('launchBoneSegmentationTools:MissingDataFields', ...
            ['Every record in ultrasoundSequence(%d).data must contain ' ...
            'sourceIndex and plane.'], groupIndex);
    end

    totalImageCount = totalImageCount + numel(currentGroupData);
    groupSourceIndices = zeros(1, numel(currentGroupData));
    for localImageIndex = 1:numel(currentGroupData)
        currentRecord = currentGroupData(localImageIndex);
        sourceIndex = currentRecord.sourceIndex;
        if ~isnumeric(sourceIndex) || ~isscalar(sourceIndex) || ...
                ~isreal(sourceIndex) || ~isfinite(sourceIndex)
            error('launchBoneSegmentationTools:InvalidSourceIndex', ...
                ['sourceIndex at group %d, local position %d must be a ' ...
                'finite numeric scalar.'], groupIndex, localImageIndex);
        end
        groupSourceIndices(localImageIndex) = double(sourceIndex);

        currentPlane = currentRecord.plane;
        if ~isstruct(currentPlane) || ~isscalar(currentPlane) || ...
                ~all(isfield(currentPlane, requiredPlaneFields))
            error('launchBoneSegmentationTools:InvalidPlane', ...
                ['plane at group %d, local position %d must contain image, ' ...
                'nRows, nCols, W, H, bone, and snapshotName fields.'], ...
                groupIndex, localImageIndex);
        end

        % Require scalar text before comparing record metadata with the outer
        % group. This produces a clear validation error for malformed labels
        % instead of letting a vector string fail inside an if expression.
        planeMetadataValues = {currentPlane.bone, currentPlane.snapshotName};
        for planeMetadataIndex = 1:numel(planeMetadataValues)
            currentPlaneMetadata = planeMetadataValues{planeMetadataIndex};
            isPlaneTextScalar = (ischar(currentPlaneMetadata) && ...
                (isrow(currentPlaneMetadata) || isempty(currentPlaneMetadata))) || ...
                (isstring(currentPlaneMetadata) && ...
                isscalar(currentPlaneMetadata));
            if ~isPlaneTextScalar
                error('launchBoneSegmentationTools:InvalidPlaneMetadata', ...
                    ['plane.bone and plane.snapshotName at group %d, local ' ...
                    'position %d must be text scalars.'], ...
                    groupIndex, localImageIndex);
            end
        end
        if string(currentPlane.bone) ~= string(currentGroup.bone) || ...
                string(currentPlane.snapshotName) ~= string(currentGroup.name)
            error('launchBoneSegmentationTools:PlaneGroupMetadataMismatch', ...
                ['plane metadata at group %d, local position %d does not ' ...
                'match its owning source-directory group.'], ...
                groupIndex, localImageIndex);
        end

        % Physical dimensions label the displayed image axes in millimeters.
        if ~isnumeric(currentPlane.W) || ~isscalar(currentPlane.W) || ...
                ~isreal(currentPlane.W) || ~isfinite(currentPlane.W) || ...
                currentPlane.W <= 0 || ...
                ~isnumeric(currentPlane.H) || ~isscalar(currentPlane.H) || ...
                ~isreal(currentPlane.H) || ~isfinite(currentPlane.H) || ...
                currentPlane.H <= 0
            error('launchBoneSegmentationTools:InvalidPhysicalImageSize', ...
                ['plane.W and plane.H at group %d, local position %d must ' ...
                'be positive finite numeric scalars in millimeters.'], ...
                groupIndex, localImageIndex);
        end

        currentImage = currentPlane.image;
        if ~isnumeric(currentImage) || ~ismatrix(currentImage) || ...
                isempty(currentImage) || ~isreal(currentImage) || ...
                any(~isfinite(double(currentImage(:)))) || ...
                any(double(currentImage(:)) < 0) || ...
                any(double(currentImage(:)) > 255)
            error('launchBoneSegmentationTools:InvalidImage', ...
                ['plane.image at group %d, local position %d must be a ' ...
                'non-empty finite 2D numeric image from 0 through 255.'], ...
                groupIndex, localImageIndex);
        end

        % Stored packets use [width, height], while the segmentation display
        % uses the transposed [nRows, nCols] image.
        displayedImageSize = size(currentImage.');
        if ~isnumeric(currentPlane.nRows) || ...
                ~isscalar(currentPlane.nRows) || ...
                ~isfinite(currentPlane.nRows) || ...
                currentPlane.nRows ~= displayedImageSize(1) || ...
                ~isnumeric(currentPlane.nCols) || ...
                ~isscalar(currentPlane.nCols) || ...
                ~isfinite(currentPlane.nCols) || ...
                currentPlane.nCols ~= displayedImageSize(2)
            error('launchBoneSegmentationTools:ImageSizeMismatch', ...
                ['plane.nRows and plane.nCols at group %d, local position ' ...
                '%d must match the size of plane.image transpose.'], ...
                groupIndex, localImageIndex);
        end
    end

    % sourceIndex is local to a group but must uniquely identify one selected
    % input record inside that directory.
    if numel(unique(groupSourceIndices)) ~= numel(groupSourceIndices)
        error('launchBoneSegmentationTools:DuplicateGroupSourceIndex', ...
            'ultrasoundSequence(%d).data contains duplicate sourceIndex values.', ...
            groupIndex);
    end
end

if totalImageCount == 0
    error('launchBoneSegmentationTools:NoImages', ...
        'At least one ultrasoundSequence group must contain image data.');
end

% Fail early when the export dialog would otherwise open at an invalid path.
if isempty(outputDirectory) || ~isfolder(outputDirectory)
    error('launchBoneSegmentationTools:OutputDirectoryNotFound', ...
        'The output directory does not exist: %s', outputDirectory);
end
end


function blobQualityLabel = classifySegmentationBlobQuality(segmentationMask)
%CLASSIFYSEGMENTATIONBLOBQUALITY Classify connected segmentation regions.
% This function counts 8-connected blobs in the final clipped mask and maps
% that count to the review labels shown in the sequence table. It is needed so
% live previews, committed images, and batch processing use identical rules.
%
% Input:
%   segmentationMask : Logical 2D final segmentation mask after any custom
%                      segmentation-area mask has been applied.
%
% Output:
%   blobQualityLabel : String scalar containing No blobs, Good, Fair, or Bad.
%                      None is assigned by workflow state.

% Match the 8-connectivity already used by the morphology and boundary steps.
connectedComponents = bwconncomp(segmentationMask, 8);
numberOfBlobs = connectedComponents.NumObjects;

% Keep zero separate because a missing segmentation needs a distinct black
% marker, while excessive regions use the red Bad state.
if numberOfBlobs == 0
    blobQualityLabel = "No blobs";
elseif numberOfBlobs == 1
    blobQualityLabel = "Good";
elseif numberOfBlobs <= 5
    blobQualityLabel = "Fair";
else
    blobQualityLabel = "Bad";
end
end


function blobQualityStyles = createBlobQualityStyles()
%CREATEBLOBQUALITYSTYLES Build reusable soft table-cell badge styles.
% This function creates one MATLAB UI style for every blob-quality state. It is
% needed to keep colors, text alignment, and generated dot icons consistent
% across all source-directory tables without relying on external image files.
%
% Inputs:
%   None.
%
% Output:
%   blobQualityStyles : Scalar struct whose fields contain the uistyle objects
%                       for None, No blobs, Bad, Fair, and Good.

% Use pale backgrounds so the indicator remains readable without overpowering
% the row selection highlight or the ultrasound image beside the table.
notCheckedBackground = [0.95, 0.95, 0.95];
noBlobsBackground = [0.88, 0.88, 0.88];
urgentBackground = [0.99, 0.91, 0.90];
checkBackground = [1.00, 0.96, 0.80];
goodBackground = [0.90, 0.96, 0.91];

% Generate each marker in MATLAB. The unchecked marker is hollow so it remains
% visually different from the filled black marker used for an empty result.
notCheckedIcon = createBlobQualityDotIcon( ...
    [0.55, 0.55, 0.55], notCheckedBackground, false);
noBlobsIcon = createBlobQualityDotIcon( ...
    [0.05, 0.05, 0.05], noBlobsBackground, true);
urgentIcon = createBlobQualityDotIcon( ...
    [0.75, 0.18, 0.16], urgentBackground, true);
checkIcon = createBlobQualityDotIcon( ...
    [0.78, 0.56, 0.04], checkBackground, true);
goodIcon = createBlobQualityDotIcon( ...
    [0.18, 0.55, 0.28], goodBackground, true);

% Center the readable label while leaving the visual marker at the cell margin.
blobQualityStyles.notChecked = uistyle( ...
    'BackgroundColor', notCheckedBackground, ...
    'FontColor', [0.35, 0.35, 0.35], ...
    'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center', ...
    'Icon', notCheckedIcon, ...
    'IconAlignment', 'leftmargin');
blobQualityStyles.noBlobs = uistyle( ...
    'BackgroundColor', noBlobsBackground, ...
    'FontColor', [0.08, 0.08, 0.08], ...
    'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center', ...
    'Icon', noBlobsIcon, ...
    'IconAlignment', 'leftmargin');
blobQualityStyles.urgent = uistyle( ...
    'BackgroundColor', urgentBackground, ...
    'FontColor', [0.50, 0.10, 0.08], ...
    'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center', ...
    'Icon', urgentIcon, ...
    'IconAlignment', 'leftmargin');
blobQualityStyles.check = uistyle( ...
    'BackgroundColor', checkBackground, ...
    'FontColor', [0.42, 0.30, 0.02], ...
    'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center', ...
    'Icon', checkIcon, ...
    'IconAlignment', 'leftmargin');
blobQualityStyles.good = uistyle( ...
    'BackgroundColor', goodBackground, ...
    'FontColor', [0.10, 0.38, 0.18], ...
    'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center', ...
    'Icon', goodIcon, ...
    'IconAlignment', 'leftmargin');
end


function iconImage = createBlobQualityDotIcon( ...
        markerColor, backgroundColor, isFilled)
%CREATEBLOBQUALITYDOTICON Draw a small filled or hollow quality marker.
% This function creates a truecolor icon whose corners match the cell background.
% It is needed because MATLAB table styles accept in-memory icons and the tool
% should not depend on separate image assets for its quality badges.
%
% Inputs:
%   markerColor     : 1-by-3 RGB color used for the marker pixels.
%   backgroundColor : 1-by-3 RGB color matching the table-cell background.
%   isFilled        : Logical scalar selecting a filled dot when true or a
%                     hollow ring when false.
%
% Output:
%   iconImage : 11-by-11-by-3 double truecolor image in the range 0 through 1.

% Start with a small square that disappears into the styled cell background.
iconSize = 11;
iconImage = repmat(reshape(backgroundColor, 1, 1, 3), ...
    iconSize, iconSize, 1);

% Build a circular pixel mask around the exact center of the odd-sized icon.
iconCenter = (iconSize + 1) / 2;
[columnGrid, rowGrid] = meshgrid(1:iconSize, 1:iconSize);
distanceFromCenter = hypot( ...
    rowGrid - iconCenter, columnGrid - iconCenter);
if isFilled
    markerMask = distanceFromCenter <= 3.5;
else
    markerMask = distanceFromCenter >= 2.5 & ...
        distanceFromCenter <= 3.5;
end

% Write each RGB channel through the same circular mask.
for colorChannel = 1:3
    currentChannel = iconImage(:, :, colorChannel);
    currentChannel(markerMask) = markerColor(colorChannel);
    iconImage(:, :, colorChannel) = currentChannel;
end
end


function applyBlobQualityTableStyles(sequenceTable, blobQualityStyles)
%APPLYBLOBQUALITYTABLESTYLES Style each blob-quality table cell by its state.
% This function rebuilds the style targets after table Data changes. It is
% needed because individual edits and bulk processing can move rows between
% quality categories while the table remains independently sortable.
%
% Inputs:
%   sequenceTable     : MATLAB uitable containing a BlobQuality data variable.
%   blobQualityStyles : Struct of reusable styles returned by
%                       createBlobQualityStyles.
%
% Outputs:
%   None. Existing table styles are replaced with current quality-cell styles.

% This table currently owns only blob-quality styles, so clearing them avoids
% stale target rows after its Data property is reassigned.
removeStyle(sequenceTable);

% Empty source groups have the correct schema but no cells that can be styled.
currentTableData = sequenceTable.Data;
if height(currentTableData) == 0
    return;
end

% Resolve the column from its stable variable name rather than a hard-coded
% number, which keeps styling safe if metadata columns are rearranged later.
qualityColumnIndex = find(strcmp( ...
    currentTableData.Properties.VariableNames, 'BlobQuality'), 1);
qualityLabels = ["None", "No blobs", "Bad", "Fair", "Good"];
stylesInLabelOrder = { ...
    blobQualityStyles.notChecked, ...
    blobQualityStyles.noBlobs, ...
    blobQualityStyles.urgent, ...
    blobQualityStyles.check, ...
    blobQualityStyles.good};
displayedQualityValues = string(currentTableData.BlobQuality);

% Add one style target per populated quality group instead of one object per
% cell, which keeps refreshes fast for sequences containing hundreds of images.
for qualityIndex = 1:numel(qualityLabels)
    matchingRows = find( ...
        displayedQualityValues == qualityLabels(qualityIndex));
    if isempty(matchingRows)
        continue;
    end
    matchingCells = [matchingRows, ...
        repmat(qualityColumnIndex, numel(matchingRows), 1)];
    addStyle(sequenceTable, stylesInLabelOrder{qualityIndex}, ...
        'cell', matchingCells);
end
end


function parameters = createDefaultProcessingParameters(storedImage)
%CREATEDEFAULTPROCESSINGPARAMETERS Build neutral defaults for one image.
% This function centralizes the reset state and calculates an image-specific
% Otsu threshold while leaving adjustable brightness, contrast, and morphology
% controls neutral. Enclosed-hole filling is a fixed active processing step.
%
% Input:
%   storedImage : Numeric ultrasound packet stored as [width, height].
%
% Output:
%   parameters  : Scalar struct containing every processing control value.

parameters = struct( ...
    'brightness', 0, ...
    'contrast', 1, ...
    'threshold', 0, ...
    'openingRadius', 0, ...
    'closingRadius', 0, ...
    'fillHoles', true, ...
    'minimumRegionArea', 25);

% Calculate the threshold from the correctly oriented neutral image.
displayedImage = storedImage.';
preprocessedImage = applyBrightnessAndContrast( ...
    displayedImage, parameters.brightness, parameters.contrast);
parameters.threshold = calculateAutomaticThreshold(preprocessedImage);
end


function [preprocessedImage, segmentationMask, pixelCoordinates] = ...
        applyBoneSegmentationPipeline(storedImage, parameters)
%APPLYBONESEGMENTATIONPIPELINE Run the complete mock-up image pipeline.
% This function converts one stored packet into a display image, applies global
% thresholding and fixed-order morphology, and returns boundary coordinates for
% preview and export.
%
% Inputs:
%   storedImage : Numeric ultrasound packet stored as [width, height].
%   parameters  : Scalar struct containing preprocessing, thresholding, and
%                 post-processing control values.
%
% Outputs:
%   preprocessedImage : Transposed uint8 image after brightness and contrast.
%   segmentationMask  : Final logical foreground mask after post-processing.
%   pixelCoordinates  : N-by-2 [row, column] coordinates of the mask boundary.

% Transpose once so every later mask and coordinate uses MATLAB image row/column
% conventions rather than the acquisition packet's [width, height] storage.
displayedImage = storedImage.';
preprocessedImage = applyBrightnessAndContrast( ...
    displayedImage, parameters.brightness, parameters.contrast);

% Keep pixels at or above the global uint8 threshold.
segmentationMask = preprocessedImage >= parameters.threshold;

% Opening removes small foreground details before closing joins nearby regions.
if parameters.openingRadius > 0
    openingElement = strel('disk', parameters.openingRadius, 0);
    segmentationMask = imopen(segmentationMask, openingElement);
end
if parameters.closingRadius > 0
    closingElement = strel('disk', parameters.closingRadius, 0);
    segmentationMask = imclose(segmentationMask, closingElement);
end

% Always fill enclosed foreground holes before removing small regions. The
% exported fillHoles parameter remains true to document this fixed step.
segmentationMask = imfill(segmentationMask, 'holes');

% Treat zero as a documented no-op and otherwise remove eight-connected regions.
if parameters.minimumRegionArea > 0
    segmentationMask = bwareaopen( ...
        segmentationMask, parameters.minimumRegionArea, 8);
end

% Boundary pixels are the primary segmentation result requested for downstream use.
boundaryMask = bwperim(segmentationMask, 8);
[boundaryRows, boundaryColumns] = find(boundaryMask);
pixelCoordinates = [boundaryRows, boundaryColumns];
end


function preprocessedImage = applyBrightnessAndContrast( ...
        displayedImage, brightness, contrast)
%APPLYBRIGHTNESSANDCONTRAST Adjust uint8-like ultrasound intensities.
% This function applies the agreed offset-and-scale model around mid-gray and
% clamps the result so display and threshold values remain in the 0-255 range.
%
% Inputs:
%   displayedImage : Correctly oriented numeric ultrasound image.
%   brightness     : Additive intensity offset.
%   contrast       : Multiplicative scale applied around intensity 127.5.
%
% Output:
%   preprocessedImage : Rounded and clamped uint8 adjusted image.

adjustedImage = ...
    (double(displayedImage) - 127.5) .* double(contrast) + ...
    127.5 + double(brightness);
adjustedImage = min(max(round(adjustedImage), 0), 255);
preprocessedImage = uint8(adjustedImage);
end


function threshold = calculateAutomaticThreshold(preprocessedImage)
%CALCULATEAUTOMATICTHRESHOLD Calculate an integer Otsu threshold.
% This function converts MATLAB's normalized graythresh result into the same
% 0-255 units used by the threshold slider and processed uint8 image.
%
% Input:
%   preprocessedImage : Uint8 image after brightness and contrast adjustment.
%
% Output:
%   threshold         : Integer scalar from 0 through 255.

threshold = round(255 * graythresh(preprocessedImage));
threshold = min(max(threshold, 0), 255);
end
