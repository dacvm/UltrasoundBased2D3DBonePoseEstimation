function segmentationFigure = launchBoneSegmentationTools( ...
        ultrasoundSequence, outputDirectory)
%LAUNCHBONESEGMENTATIONTOOLS Open the ultrasound segmentation mock-up.
% This function builds an interactive tool for reviewing an ultrasound
% sequence, tuning a simple three-stage image-processing pipeline, and
% exporting the resulting 2D bone-boundary pixel coordinates. It is needed
% to test the intended user workflow before a validated bone-specific
% segmentation method is available.
%
% Inputs:
%   ultrasoundSequence : Struct vector whose elements contain sourceIndex
%                        and plane. Each plane supplies the stored ultrasound
%                        image and the metadata shown in the browser table.
%   outputDirectory    : Existing directory suggested by the MAT-file export
%                        dialog when the user presses Export.
%
% Output:
%   segmentationFigure : Handle to the non-blocking uifigure that owns the
%                        table, image preview, controls, and callback state.

%% VALIDATE AND PREPARE THE INPUT DATA

% Normalize the directory once so callbacks can use one simple character path.
outputDirectory = char(string(outputDirectory));

% Check every field used by the UI before creating a partially working window.
validateBoneSegmentationInputs(ultrasoundSequence, outputDirectory);

% Keep one stable sequence position for navigation even if the table is sorted.
numberOfImages = numel(ultrasoundSequence);
sequencePositions = (1:numberOfImages).';

% Build the parameter defaults from the first image. Only the threshold is
% data-dependent; all other controls use neutral processing values.
defaultParameters = createDefaultProcessingParameters( ...
    ultrasoundSequence(1).plane.image);
lastCommittedParameters = defaultParameters;
currentParameters = defaultParameters;

% Store committed results separately from the live preview. This prevents a
% slider movement from silently replacing a result until navigation or export.
committedParameters = repmat(defaultParameters, 1, numberOfImages);
committedMasks = cell(1, numberOfImages);
committedCoordinates = cell(1, numberOfImages);
isImageProcessed = false(1, numberOfImages);
pointCounts = zeros(numberOfImages, 1);
statusValues = repmat("Unprocessed", numberOfImages, 1);

% Start with the first image, matching the requested guided sequence workflow.
currentImageIndex = 1;
currentPreviewImage = uint8([]);
currentPreviewMask = false(0, 0);
currentPreviewCoordinates = zeros(0, 2);

% Track user work separately from successful exports so close warnings are
% shown only when there is something that could be lost.
currentImageHasUserEdits = false;
hasUnexportedCommittedChanges = false;
isSynchronizingTableSelection = false;

%% BUILD THE TABLE DATA

% Read only compact metadata into the table. Large images and masks stay in
% the sequence and result containers owned by this function.
sourceIndices = zeros(numberOfImages, 1);
boneCodes = strings(numberOfImages, 1);
snapshotGroups = strings(numberOfImages, 1);
for imageIndex = 1:numberOfImages
    currentPlane = ultrasoundSequence(imageIndex).plane;
    sourceIndices(imageIndex) = double(ultrasoundSequence(imageIndex).sourceIndex);
    boneCodes(imageIndex) = string(currentPlane.bone);
    snapshotGroups(imageIndex) = string(currentPlane.snapshotName);
end

% SequencePosition remains the permanent key after visual table sorting.
tableData = table( ...
    sequencePositions, sourceIndices, boneCodes, snapshotGroups, ...
    statusValues, pointCounts, ...
    'VariableNames', { ...
        'SequencePosition', 'SourceIndex', 'Bone', 'SnapshotGroup', ...
        'Status', 'PointCount'});

%% CREATE THE THREE-COLUMN USER INTERFACE

% Use a wide figure so the sequence table, image, and staged controls can be
% inspected at the same time on a normal desktop display.
segmentationFigure = uifigure( ...
    'Name', 'Semi-Automatic Bone Segmentation Tool', ...
    'Position', [20, 60, 1880, 900], ...
    'CloseRequestFcn', @handleCloseRequest, ...
    'Tag', 'bone_segmentation_tool_figure');

% Give the image the flexible center column while keeping the table and
% processing controls wide enough for readable labels.
mainGrid = uigridlayout(segmentationFigure, [1, 3], ...
    'ColumnWidth', {540, '1x', 420}, ...
    'Padding', [10, 10, 10, 10], ...
    'ColumnSpacing', 10);

% Put the table inside a titled panel so the three interface responsibilities
% remain visually clear to a first-time user.
tablePanel = uipanel(mainGrid, ...
    'Title', 'Ultrasound Sequence', ...
    'Tag', 'bone_segmentation_table_panel');
tablePanel.Layout.Row = 1;
tablePanel.Layout.Column = 1;
tableGrid = uigridlayout(tablePanel, [1, 1], ...
    'Padding', [5, 5, 5, 5]);

% Allow row selection and sorting, but keep metadata read-only.
sequenceTable = uitable(tableGrid, ...
    'Data', tableData, ...
    'ColumnName', { ...
        'Position', 'Source', 'Bone', 'Snapshot group', 'Status', 'Points'}, ...
    'ColumnWidth', {75, 65, 55, 125, 90, 60}, ...
    'ColumnEditable', false(1, width(tableData)), ...
    'ColumnSortable', true(1, width(tableData)), ...
    'SelectionType', 'row', ...
    'Multiselect', 'off', ...
    'Tag', 'bone_segmentation_sequence_table');

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
xlabel(imageAxes, 'Column');
ylabel(imageAxes, 'Row');
box(imageAxes, 'on');
colormap(imageAxes, gray(256));

% Divide the right column by processing stage so the control order mirrors
% the order in which each image operation is applied.
parametersPanel = uipanel(mainGrid, ...
    'Title', 'Processing Parameters', ...
    'Tag', 'bone_segmentation_parameters_panel');
parametersPanel.Layout.Row = 1;
parametersPanel.Layout.Column = 3;
parametersGrid = uigridlayout(parametersPanel, [4, 1], ...
    'RowHeight', {190, 140, '1x', 185}, ...
    'Padding', [5, 5, 5, 5], ...
    'RowSpacing', 6);

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
segmentationGrid = uigridlayout(segmentationPanel, [3, 3], ...
    'RowHeight', {24, 42, 30}, ...
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

%% CREATE THE POST-PROCESSING CONTROLS

postprocessingPanel = uipanel(parametersGrid, ...
    'Title', 'Post-processing', ...
    'Tag', 'bone_segmentation_postprocessing_panel');
postprocessingPanel.Layout.Row = 3;
postprocessingPanel.Layout.Column = 1;
postprocessingGrid = uigridlayout(postprocessingPanel, [7, 3], ...
    'RowHeight', {24, '1x', 24, '1x', 26, 24, '1x'}, ...
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
    'Limits', [0, 20], ...
    'Value', currentParameters.openingRadius, ...
    'ValueDisplayFormat', '%.0f', ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'openingRadius', source.Value), ...
    'Tag', 'bone_segmentation_opening_radius_field');
openingRadiusField.Layout.Row = 1;
openingRadiusField.Layout.Column = 3;
openingRadiusSlider = uislider(postprocessingGrid, ...
    'Limits', [0, 20], ...
    'Value', currentParameters.openingRadius, ...
    'MajorTicks', [0, 5, 10, 15, 20], ...
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
    'Limits', [0, 20], ...
    'Value', currentParameters.closingRadius, ...
    'ValueDisplayFormat', '%.0f', ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'closingRadius', source.Value), ...
    'Tag', 'bone_segmentation_closing_radius_field');
closingRadiusField.Layout.Row = 3;
closingRadiusField.Layout.Column = 3;
closingRadiusSlider = uislider(postprocessingGrid, ...
    'Limits', [0, 20], ...
    'Value', currentParameters.closingRadius, ...
    'MajorTicks', [0, 5, 10, 15, 20], ...
    'ValueChangingFcn', @(~, eventData) updateDiscreteParameter( ...
        'closingRadius', eventData.Value), ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'closingRadius', source.Value), ...
    'Tag', 'bone_segmentation_closing_radius_slider');
closingRadiusSlider.Layout.Row = 4;
closingRadiusSlider.Layout.Column = [1, 3];

fillHolesCheckBox = uicheckbox(postprocessingGrid, ...
    'Text', 'Fill enclosed holes', ...
    'Value', currentParameters.fillHoles, ...
    'ValueChangedFcn', @(source, ~) updateFillHoles(source.Value), ...
    'Tag', 'bone_segmentation_fill_holes_checkbox');
fillHolesCheckBox.Layout.Row = 5;
fillHolesCheckBox.Layout.Column = [1, 3];

minimumAreaLabel = uilabel(postprocessingGrid, ...
    'Text', 'Minimum region area (px)', ...
    'Tooltip', 'Remove connected foreground regions smaller than this area.');
minimumAreaLabel.Layout.Row = 6;
minimumAreaLabel.Layout.Column = [1, 2];
minimumAreaField = uieditfield(postprocessingGrid, 'numeric', ...
    'Limits', [0, minimumRegionAreaSliderMaximum], ...
    'Value', currentParameters.minimumRegionArea, ...
    'ValueDisplayFormat', '%.0f', ...
    'ValueChangedFcn', @(source, ~) updateDiscreteParameter( ...
        'minimumRegionArea', source.Value), ...
    'Tag', 'bone_segmentation_minimum_area_field');
minimumAreaField.Layout.Row = 6;
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
minimumAreaSlider.Layout.Row = 7;
minimumAreaSlider.Layout.Column = [1, 3];

%% CREATE THE NAVIGATION AND EXPORT CONTROLS

workflowPanel = uipanel(parametersGrid, ...
    'Title', 'Navigation and Export', ...
    'Tag', 'bone_segmentation_workflow_panel');
workflowPanel.Layout.Row = 4;
workflowPanel.Layout.Column = 1;
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

resetButton = uibutton(workflowGrid, 'push', ...
    'Text', 'Reset current parameters', ...
    'ButtonPushedFcn', @handleResetCurrent, ...
    'Tag', 'bone_segmentation_reset_button');
resetButton.Layout.Row = 2;
resetButton.Layout.Column = [1, 2];

previousButton = uibutton(workflowGrid, 'push', ...
    'Text', 'Previous', ...
    'ButtonPushedFcn', @handlePreviousImage, ...
    'Tag', 'bone_segmentation_previous_button');
previousButton.Layout.Row = 3;
previousButton.Layout.Column = 1;
nextButton = uibutton(workflowGrid, 'push', ...
    'Text', 'Next', ...
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

% Set the initial selection before registering the callback so setup cannot
% be mistaken for user navigation.
sequenceTable.Selection = 1;
loadCurrentImage();
sequenceTable.SelectionChangedFcn = @handleTableSelection;

    function handleTableSelection(~, eventData)
        %HANDLETABLESELECTION Commit the old image and open the selected row.
        % This callback is needed so direct table navigation follows the same
        % save-on-leave behavior as the Previous and Next buttons.
        %
        % Inputs:
        %   ~         : Unused table source supplied by MATLAB.
        %   eventData : Selection event containing the selected data row.
        %
        % Outputs:
        %   None. The callback updates the current image and UI state.

        % Ignore programmatic selection updates made during navigation.
        if isSynchronizingTableSelection || isempty(eventData.Selection)
            return;
        end

        % MATLAB reports the original Data row even when the table is sorted.
        selectedDataRow = eventData.Selection(1);
        currentTableData = sequenceTable.Data;
        if selectedDataRow < 1 || selectedDataRow > height(currentTableData)
            return;
        end

        % Resolve the permanent sequence position stored in the selected row.
        targetImageIndex = currentTableData.SequencePosition(selectedDataRow);
        navigateToImage(targetImageIndex);
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
                newValue = round(min(max(double(requestedValue), 0), 20));
                currentParameters.openingRadius = newValue;
                openingRadiusSlider.Value = newValue;
                openingRadiusField.Value = newValue;
            case 'closingRadius'
                newValue = round(min(max(double(requestedValue), 0), 20));
                currentParameters.closingRadius = newValue;
                closingRadiusSlider.Value = newValue;
                closingRadiusField.Value = newValue;
            case 'minimumRegionArea'
                % Keep the value meaningful for both the current image and the
                % finite slider range used for interactive tuning.
                maximumArea = min( ...
                    numel(ultrasoundSequence(currentImageIndex).plane.image), ...
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

    function updateFillHoles(requestedValue)
        %UPDATEFILLHOLES Enable or disable filling enclosed mask holes.
        % This callback is needed to connect the checkbox to the fixed
        % post-processing pipeline and immediate preview.
        %
        % Input:
        %   requestedValue : Logical-like checkbox value supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback updates currentParameters and the preview.

        currentParameters.fillHoles = logical(requestedValue);
        fillHolesCheckBox.Value = currentParameters.fillHoles;
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

        currentStoredImage = ultrasoundSequence(currentImageIndex).plane.image;
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

        currentStoredImage = ultrasoundSequence(currentImageIndex).plane.image;
        currentParameters = createDefaultProcessingParameters(currentStoredImage);
        currentImageHasUserEdits = true;
        writeControlsFromCurrentParameters();
        renderCurrentPreview();
        refreshCurrentTableRow();
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

        navigateToImage(currentImageIndex - 1);
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

        navigateToImage(currentImageIndex + 1);
    end

    function navigateToImage(targetImageIndex)
        %NAVIGATETOIMAGE Commit the current result and display a target image.
        % This helper centralizes navigation so table selection and both buttons
        % apply identical state and parameter-inheritance rules.
        %
        % Input:
        %   targetImageIndex : Stable sequence position to display next.
        %
        % Outputs:
        %   None. The helper updates committed state, table selection, and preview.

        % Ignore invalid or no-op requests. Boundary buttons are disabled too,
        % but this check protects programmatic callback calls.
        if targetImageIndex < 1 || targetImageIndex > numberOfImages || ...
                targetImageIndex == currentImageIndex
            return;
        end

        % Prevent the programmatic selection assignment from starting a second
        % navigation while this one is still updating shared state.
        isSynchronizingTableSelection = true;
        try
            commitCurrentImage();
            currentImageIndex = targetImageIndex;
            sequenceTable.Selection = targetImageIndex;
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
        % set, cleaned mask, and boundary coordinates together.
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
                currentPreviewCoordinates);

        committedParameters(currentImageIndex) = currentParameters;
        committedMasks{currentImageIndex} = currentPreviewMask;
        committedCoordinates{currentImageIndex} = currentPreviewCoordinates;
        isImageProcessed(currentImageIndex) = true;
        pointCounts(currentImageIndex) = size(currentPreviewCoordinates, 1);
        statusValues(currentImageIndex) = "Processed";

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
        else
            currentParameters = lastCommittedParameters;
        end
        currentImageHasUserEdits = false;

        writeControlsFromCurrentParameters();
        renderCurrentPreview();
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
        %   None. The helper writes values to sliders, fields, and checkbox.

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
        fillHolesCheckBox.Value = currentParameters.fillHoles;
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

        currentPlane = ultrasoundSequence(currentImageIndex).plane;
        [currentPreviewImage, currentPreviewMask, ...
            currentPreviewCoordinates] = applyBoneSegmentationPipeline( ...
            currentPlane.image, currentParameters);

        % Replace the previous image and overlay while preserving fixed uint8
        % display limits so brightness and contrast changes remain visible.
        cla(imageAxes);
        imagesc(imageAxes, currentPreviewImage, [0, 255]);
        axis(imageAxes, 'image');
        xlim(imageAxes, [0.5, size(currentPreviewImage, 2) + 0.5]);
        ylim(imageAxes, [0.5, size(currentPreviewImage, 1) + 0.5]);
        colormap(imageAxes, gray(256));
        hold(imageAxes, 'on');

        % Draw boundary pixels last so they remain visible over bright echoes.
        if ~isempty(currentPreviewCoordinates)
            plot(imageAxes, ...
                currentPreviewCoordinates(:, 2), ...
                currentPreviewCoordinates(:, 1), ...
                'r.', ...
                'MarkerSize', 7, ...
                'Tag', 'bone_segmentation_boundary_overlay');
        end
        hold(imageAxes, 'off');

        title(imageAxes, { ...
            sprintf('%s | Bone %s', ...
                char(string(currentPlane.snapshotName)), ...
                char(string(currentPlane.bone))), ...
            sprintf('Position %d of %d | Source %g | Boundary points: %d', ...
                currentImageIndex, numberOfImages, ...
                double(ultrasoundSequence(currentImageIndex).sourceIndex), ...
                size(currentPreviewCoordinates, 1))}, ...
            'Interpreter', 'none');
        xlabel(imageAxes, 'Column');
        ylabel(imageAxes, 'Row');
        drawnow limitrate;
    end

    function refreshCurrentTableRow()
        %REFRESHCURRENTTABLEROW Update status and point count for one image.
        % This helper keeps the compact table synchronized without copying image
        % or mask arrays into the UI control.
        %
        % Inputs:
        %   None. The helper reads the current processing and preview state.
        %
        % Outputs:
        %   None. It updates sequenceTable.Data and preserves row selection.

        currentTableData = sequenceTable.Data;

        % Mark a processed result as modified while its preview differs from the
        % last commit. A new image remains explicitly unprocessed until leaving.
        if isImageProcessed(currentImageIndex) && currentImageHasUserEdits
            displayedStatus = "Modified";
        elseif isImageProcessed(currentImageIndex)
            displayedStatus = "Processed";
        else
            displayedStatus = "Unprocessed";
        end

        statusValues(currentImageIndex) = displayedStatus;
        currentTableData.Status(currentImageIndex) = displayedStatus;
        currentTableData.PointCount(currentImageIndex) = ...
            size(currentPreviewCoordinates, 1);
        sequenceTable.Data = currentTableData;

        % Reapply the stable data-row selection in case table data assignment
        % caused MATLAB to rebuild its sorted display view.
        sequenceTable.Selection = currentImageIndex;
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

        % Keep current position and completion progress on one compact line so
        % the fixed-height workflow panel leaves more room for processing.
        workflowStatusLabel.Text = sprintf( ...
            'Image %d of %d  |  Processed: %d / %d', ...
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

        % Save one wrapper variable so schema metadata and per-image records
        % always travel together.
        boneSegmentationExport = buildExportStructure();
        outputFilePath = fullfile(selectedDirectory, selectedFileName);
        try
            save(outputFilePath, 'boneSegmentationExport', '-v7.3');
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
    end

    function boneSegmentationExport = buildExportStructure()
        %BUILDEXPORTSTRUCTURE Package metadata and all per-image results.
        % This helper gives the MAT-file one documented schema and guarantees
        % that results remain aligned with the original ultrasound sequence.
        %
        % Inputs:
        %   None. Data is read from the nested committed state.
        %
        % Output:
        %   boneSegmentationExport : Scalar struct containing schema metadata
        %                            and an ordered result struct array.

        resultTemplate = struct( ...
            'sequencePosition', [], ...
            'sourceIndex', [], ...
            'pixelCoordinates', zeros(0, 2), ...
            'segmentationMask', false(0, 0), ...
            'processingParameters', defaultParameters, ...
            'status', 'unprocessed');
        exportResults = repmat(resultTemplate, 1, numberOfImages);

        for resultIndex = 1:numberOfImages
            displayedImageSize = size( ...
                ultrasoundSequence(resultIndex).plane.image.');
            exportResults(resultIndex).sequencePosition = resultIndex;
            exportResults(resultIndex).sourceIndex = ...
                ultrasoundSequence(resultIndex).sourceIndex;
            exportResults(resultIndex).processingParameters = ...
                committedParameters(resultIndex);

            if isImageProcessed(resultIndex)
                exportResults(resultIndex).pixelCoordinates = ...
                    committedCoordinates{resultIndex};
                exportResults(resultIndex).segmentationMask = ...
                    committedMasks{resultIndex};
                exportResults(resultIndex).status = 'processed';
            else
                % A correctly sized false mask preserves array conventions while
                % status prevents it from being mistaken for an accepted empty result.
                exportResults(resultIndex).pixelCoordinates = zeros(0, 2);
                exportResults(resultIndex).segmentationMask = ...
                    false(displayedImageSize);
                exportResults(resultIndex).status = 'unprocessed';
            end
        end

        boneSegmentationExport = struct();
        boneSegmentationExport.schemaVersion = 1;
        boneSegmentationExport.createdAt = char(datetime( ...
            'now', 'Format', "yyyy-MM-dd'T'HH:mm:ssXXX"));
        boneSegmentationExport.coordinateConvention = [ ...
            'pixelCoordinates is an N-by-2 [row, column] array indexing ' ...
            'the displayed plane.image transpose; segmentationMask uses ' ...
            'the same row and column layout.'];
        boneSegmentationExport.results = exportResults;
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

        % Delete only this tool figure; unrelated project figures stay open.
        delete(sourceFigure);
    end
end


function validateBoneSegmentationInputs(ultrasoundSequence, outputDirectory)
%VALIDATEBONESEGMENTATIONINPUTS Check data required by the segmentation UI.
% This function rejects malformed sequence records before graphics and callback
% state are created, producing clear errors close to the actual input problem.
%
% Inputs:
%   ultrasoundSequence : Candidate struct vector containing sourceIndex and plane.
%   outputDirectory    : Candidate existing directory for export suggestions.
%
% Outputs:
%   None. The function returns silently for valid inputs and throws otherwise.

% Require a non-empty vector because the workflow always selects a first image.
validateattributes(ultrasoundSequence, {'struct'}, ...
    {'vector', 'nonempty'}, mfilename, 'ultrasoundSequence');

requiredSequenceFields = {'sourceIndex', 'plane'};
if ~all(isfield(ultrasoundSequence, requiredSequenceFields))
    error('launchBoneSegmentationTools:MissingSequenceFields', ...
        'Each ultrasoundSequence entry must contain sourceIndex and plane.');
end

requiredPlaneFields = {'image', 'nRows', 'nCols', 'bone', 'snapshotName'};
for imageIndex = 1:numel(ultrasoundSequence)
    sourceIndex = ultrasoundSequence(imageIndex).sourceIndex;
    if ~isnumeric(sourceIndex) || ~isscalar(sourceIndex) || ...
            ~isreal(sourceIndex) || ~isfinite(sourceIndex)
        error('launchBoneSegmentationTools:InvalidSourceIndex', ...
            'sourceIndex at sequence position %d must be a finite numeric scalar.', ...
            imageIndex);
    end

    currentPlane = ultrasoundSequence(imageIndex).plane;
    if ~isstruct(currentPlane) || ~isscalar(currentPlane) || ...
            ~all(isfield(currentPlane, requiredPlaneFields))
        error('launchBoneSegmentationTools:InvalidPlane', ...
            ['plane at sequence position %d must be a scalar struct with ' ...
                'image, nRows, nCols, bone, and snapshotName fields.'], ...
            imageIndex);
    end

    currentImage = currentPlane.image;
    if ~isnumeric(currentImage) || ~ismatrix(currentImage) || ...
            isempty(currentImage) || ~isreal(currentImage) || ...
            any(~isfinite(double(currentImage(:)))) || ...
            any(double(currentImage(:)) < 0) || ...
            any(double(currentImage(:)) > 255)
        error('launchBoneSegmentationTools:InvalidImage', ...
            ['plane.image at sequence position %d must be a non-empty, ' ...
                'finite 2D numeric image with values from 0 through 255.'], ...
            imageIndex);
    end

    % The project stores packets as [width, height], while nRows and nCols
    % describe the transposed display image used by segmentation coordinates.
    displayedImageSize = size(currentImage.');
    if ~isnumeric(currentPlane.nRows) || ~isscalar(currentPlane.nRows) || ...
            ~isfinite(currentPlane.nRows) || ...
            currentPlane.nRows ~= displayedImageSize(1) || ...
            ~isnumeric(currentPlane.nCols) || ~isscalar(currentPlane.nCols) || ...
            ~isfinite(currentPlane.nCols) || ...
            currentPlane.nCols ~= displayedImageSize(2)
        error('launchBoneSegmentationTools:ImageSizeMismatch', ...
            ['plane.nRows and plane.nCols at sequence position %d must match ' ...
                'the size of plane.image transpose.'], imageIndex);
    end
end

% Fail early when the export dialog would otherwise open at an invalid path.
if isempty(outputDirectory) || ~isfolder(outputDirectory)
    error('launchBoneSegmentationTools:OutputDirectoryNotFound', ...
        'The output directory does not exist: %s', outputDirectory);
end
end


function parameters = createDefaultProcessingParameters(storedImage)
%CREATEDEFAULTPROCESSINGPARAMETERS Build neutral defaults for one image.
% This function centralizes the reset state and calculates an image-specific
% Otsu threshold while leaving brightness, contrast, and morphology neutral.
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
    'fillHoles', false, ...
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

% Hole filling is optional because not every bright bone echo should become a
% solid region during this early workflow mock-up.
if parameters.fillHoles
    segmentationMask = imfill(segmentationMask, 'holes');
end

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
