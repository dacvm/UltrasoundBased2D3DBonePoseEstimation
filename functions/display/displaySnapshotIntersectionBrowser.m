function [figBrowser, validSnapshots, outputFilePath] = displaySnapshotIntersectionBrowser( ...
        snapshotPlanes, intersections, boneMeshesRefByCode, varargin)
%DISPLAYSNAPSHOTINTERSECTIONBROWSER Browse or review snapshot intersections.
% This function builds one results-first browser so many ultrasound
% snapshots can be inspected without drawing every 2D image at once.
% Selecting a table row updates one large 2D overlay and rebuilds a matching
% bone, image plane, and intersection in the browser's own 3D axes. Optional
% review mode adds snapshot approval and export controls to the same browser.
%
% Inputs:
%   snapshotPlanes : Struct array grouped by source directory. Every group
%                    has name, bone, path, and data fields. Its data field is
%                    a struct array of finite image-plane geometry, source
%                    images, timestamps, and packet indices.
%   intersections  : Struct array with the same source-directory groups and
%                    metadata as snapshotPlanes. Each data field contains one
%                    raw and probe-facing intersection result for every plane
%                    at the same group and local data index.
%   boneMeshesRefByCode : Scalar struct whose fields are bone codes such as
%                         F and T. Each value is a reference-frame mesh struct
%                         with exact fields V for vertices and F for faces.
%
% Name-Value Input:
%   'Mode'          : Browser behavior, specified as 'display' or 'review'.
%                     The default 'display' mode is non-blocking and keeps
%                     the original read-only behavior. Review mode waits for
%                     the first successful export or window cancellation.
%   'OutputDirectory' : Existing directory initially shown by the review
%                       export dialog. The default empty value lets MATLAB
%                       choose the dialog's initial directory.
%
% Outputs:
%   figBrowser      : Handle to the new uifigure that contains one sortable
%                    table tab per source group, the selected 2D image, and
%                    the selected 3D scene.
%   validSnapshots  : Source-directory groups exported from review mode. Each
%                    group keeps name, bone, path, and data. Every selected
%                    data record contains its group-local sourceIndex, plane,
%                    and intersection. This is empty in display mode or when
%                    review mode is cancelled.
%   outputFilePath  : Full path of the first successful review export. This
%                    is empty in display mode or after review cancellation.

%% VALIDATE THE DISPLAY INPUTS

% Require the three data inputs before parsing the optional mode setting.
% This preserves the original direct error for incomplete public calls.
if nargin < 3
    error('displaySnapshotIntersectionBrowser:InvalidInputCount', ...
        ['Expected snapshotPlanes, intersections, boneMeshesRefByCode, ' ...
        'and optional name-value inputs.']);
end

% Parse the optional mode without allowing abbreviated parameter names.
% Exact mode values keep accidental misspellings from changing GUI behavior.
browserInputParser = inputParser;
browserInputParser.FunctionName = mfilename;
browserInputParser.PartialMatching = false;
addParameter(browserInputParser, 'Mode', 'display', ...
    @(value) (ischar(value) && isrow(value)) || ...
    (isstring(value) && isscalar(value)));
addParameter(browserInputParser, 'OutputDirectory', '', ...
    @(value) (ischar(value) && isrow(value)) || ...
    (isstring(value) && isscalar(value)));
parse(browserInputParser, varargin{:});

% Normalize text once so all later branches use one simple mode flag.
browserMode = lower(string(browserInputParser.Results.Mode));
if ~any(browserMode == ["display", "review"])
    error('displaySnapshotIntersectionBrowser:InvalidMode', ...
        'Mode must be either ''display'' or ''review''.');
end
isReviewMode = browserMode == "review";

% Keep an empty directory as MATLAB's normal dialog behavior, but require a
% supplied directory to exist so the export dialog never starts at a bad path.
outputDirectory = char(string(browserInputParser.Results.OutputDirectory));
if ~isempty(outputDirectory) && ~isfolder(outputDirectory)
    error('displaySnapshotIntersectionBrowser:OutputDirectoryNotFound', ...
        'OutputDirectory was not found: %s', outputDirectory);
end

% Initialize optional outputs before any GUI callback can run. The empty
% struct keeps the review output fields clear even when no export is made.
validSnapshots = struct( ...
    'name', {}, ...
    'bone', {}, ...
    'path', {}, ...
    'data', {});
outputFilePath = '';
hasSuccessfulExport = false;

% Check the two grouped result containers before inspecting their fields.
validateattributes(snapshotPlanes, {'struct'}, {'vector'}, ...
    mfilename, 'snapshotPlanes');
validateattributes(intersections, {'struct'}, {'vector'}, ...
    mfilename, 'intersections');

% Stop when the group counts differ because a tab could otherwise combine
% planes and intersections that came from different source directories.
if numel(snapshotPlanes) ~= numel(intersections)
    error('displaySnapshotIntersectionBrowser:InputSizeMismatch', ...
        ['snapshotPlanes contains %d group(s), but intersections contains ' ...
        '%d. The grouped arrays must stay aligned.'], ...
        numel(snapshotPlanes), numel(intersections));
end

% Reject the old flat input contract by requiring the shared group wrapper.
% Extra outer fields remain allowed for later snapshot metadata extensions.
requiredGroupFields = {'name', 'bone', 'path', 'data'};
if ~all(isfield(snapshotPlanes, requiredGroupFields)) || ...
        ~all(isfield(intersections, requiredGroupFields))
    error('displaySnapshotIntersectionBrowser:MissingGroupFields', ...
        ['snapshotPlanes and intersections must be source-directory groups ' ...
        'with name, bone, path, and data fields. Flat arrays are unsupported.']);
end

% List every child field used by the table and renderers before validating
% each group's data. Empty groups keep these fields through their templates.
requiredPlaneFields = { ...
    'p0', 'ex', 'ey', 'n', 'W', 'H', 'nRows', 'nCols', ...
    'image', 'timestamp', 'bone', 'snapshotName', ...
    'snapshotIndex', 'sequenceIndex', 'packetIndex'};

% Require the result fields used for counts, overlays, 3D synchronization,
% and clear status reporting in the table.
requiredIntersectionFields = { ...
    'pixelList', 'segments3D', 'segmentsUV', ...
    'probeFacingSegments3D', 'probeFacingPixels', 'status'};

% Validate the two-dimensional alignment once so GUI callbacks can read a
% group and local index without repeating defensive checks during interaction.
nGroups = numel(snapshotPlanes);
for groupIndex = 1:nGroups
    currentPlaneGroup = snapshotPlanes(groupIndex);
    currentIntersectionGroup = intersections(groupIndex);

    % Require simple text metadata because tab titles and mesh selection use
    % these values directly. Paths may be empty but must still be text.
    groupMetadataValues = { ...
        currentPlaneGroup.name, currentPlaneGroup.bone, currentPlaneGroup.path, ...
        currentIntersectionGroup.name, currentIntersectionGroup.bone, ...
        currentIntersectionGroup.path};
    for metadataIndex = 1:numel(groupMetadataValues)
        currentMetadataValue = groupMetadataValues{metadataIndex};
        isTextScalar = (ischar(currentMetadataValue) && ...
            (isrow(currentMetadataValue) || isempty(currentMetadataValue))) || ...
            (isstring(currentMetadataValue) && isscalar(currentMetadataValue));
        if ~isTextScalar
            error('displaySnapshotIntersectionBrowser:InvalidGroupMetadata', ...
                'Group %d metadata fields name, bone, and path must be text scalars.', ...
                groupIndex);
        end
    end

    % Matching metadata prevents tabs from pairing arrays that merely happen
    % to have the same number of records.
    if string(currentPlaneGroup.name) ~= string(currentIntersectionGroup.name) || ...
            string(currentPlaneGroup.bone) ~= string(currentIntersectionGroup.bone) || ...
            string(currentPlaneGroup.path) ~= string(currentIntersectionGroup.path)
        error('displaySnapshotIntersectionBrowser:GroupMetadataMismatch', ...
            'snapshotPlanes and intersections metadata differs for group %d.', ...
            groupIndex);
    end

    currentPlanes = currentPlaneGroup.data;
    currentIntersections = currentIntersectionGroup.data;
    if ~isstruct(currentPlanes) || (~isempty(currentPlanes) && ~isvector(currentPlanes))
        error('displaySnapshotIntersectionBrowser:InvalidPlaneGroupData', ...
            'snapshotPlanes(%d).data must be a struct vector.', groupIndex);
    end
    if ~isstruct(currentIntersections) || ...
            (~isempty(currentIntersections) && ~isvector(currentIntersections))
        error('displaySnapshotIntersectionBrowser:InvalidIntersectionGroupData', ...
            'intersections(%d).data must be a struct vector.', groupIndex);
    end
    if numel(currentPlanes) ~= numel(currentIntersections)
        error('displaySnapshotIntersectionBrowser:GroupDataSizeMismatch', ...
            ['Group %d contains %d plane(s) but %d intersection result(s). ' ...
            'Local data arrays must stay aligned.'], ...
            groupIndex, numel(currentPlanes), numel(currentIntersections));
    end
    if ~all(isfield(currentPlanes, requiredPlaneFields))
        error('displaySnapshotIntersectionBrowser:MissingPlaneFields', ...
            'snapshotPlanes(%d).data is missing required fields.', groupIndex);
    end
    if ~all(isfield(currentIntersections, requiredIntersectionFields))
        error('displaySnapshotIntersectionBrowser:MissingIntersectionFields', ...
            'intersections(%d).data is missing required fields.', groupIndex);
    end

    % Confirm repeated plane metadata still points to its owning outer group.
    % This catches accidental regrouping before an incorrect image is shown.
    for localResultIndex = 1:numel(currentPlanes)
        currentPlane = currentPlanes(localResultIndex);
        if string(currentPlane.snapshotName) ~= string(currentPlaneGroup.name) || ...
                string(currentPlane.bone) ~= string(currentPlaneGroup.bone) || ...
                double(currentPlane.snapshotIndex) ~= groupIndex
            error('displaySnapshotIntersectionBrowser:PlaneGroupMetadataMismatch', ...
                ['snapshotPlanes(%d).data(%d) metadata does not identify its ' ...
                'owning source-directory group.'], ...
                groupIndex, localResultIndex);
        end
    end
end

% Require one mesh lookup struct because row selection uses the plane's bone
% code to choose the correct anatomy without reading graphics from ax1.
if ~isstruct(boneMeshesRefByCode) || ~isscalar(boneMeshesRefByCode)
    error('displaySnapshotIntersectionBrowser:InvalidBoneMeshMap', ...
        'boneMeshesRefByCode must be a scalar struct keyed by bone code.');
end

% Validate every available mesh once so callbacks can focus only on display
% work and never fail halfway through a row update.
boneMeshCodes = fieldnames(boneMeshesRefByCode);
expectedMeshFields = sort({'V', 'F'});
for boneMeshIndex = 1:numel(boneMeshCodes)
    currentBoneMeshCode = boneMeshCodes{boneMeshIndex};
    currentBoneMesh = boneMeshesRefByCode.(currentBoneMeshCode);

    % Enforce the same exact V/F mesh interface used by the geometry helper.
    if ~isstruct(currentBoneMesh) || ~isscalar(currentBoneMesh) || ...
            ~isequal(sort(fieldnames(currentBoneMesh)), expectedMeshFields(:))
        error('displaySnapshotIntersectionBrowser:InvalidBoneMeshFields', ...
            'Mesh "%s" must be a scalar struct with exact fields V and F.', ...
            currentBoneMeshCode);
    end

    % Check the numeric shapes needed by patch before the browser is created.
    if ~isnumeric(currentBoneMesh.V) || size(currentBoneMesh.V, 2) ~= 3 || ...
            isempty(currentBoneMesh.V) || any(~isfinite(currentBoneMesh.V(:)))
        error('displaySnapshotIntersectionBrowser:InvalidBoneMeshVertices', ...
            'Mesh "%s" field V must be a non-empty finite Nv-by-3 array.', ...
            currentBoneMeshCode);
    end
    if ~isnumeric(currentBoneMesh.F) || size(currentBoneMesh.F, 2) ~= 3 || ...
            any(~isfinite(currentBoneMesh.F(:)))
        error('displaySnapshotIntersectionBrowser:InvalidBoneMeshFaces', ...
            'Mesh "%s" field F must be a finite Nf-by-3 array.', ...
            currentBoneMeshCode);
    end
end

%% BUILD THE GROUPED RESULTS TABLE DATA

% Keep one lightweight table and one review-decision vector per source
% directory. Large image matrices and intersection geometry stay outside the
% UI controls and are read only when a row is selected.
nResultsByGroup = zeros(1, nGroups);
resultsDataByGroup = cell(1, nGroups);
reviewDecisions = cell(1, nGroups);

for groupIndex = 1:nGroups
    currentPlanes = snapshotPlanes(groupIndex).data;
    currentIntersections = intersections(groupIndex).data;
    currentResultCount = numel(currentPlanes);
    nResultsByGroup(groupIndex) = currentResultCount;

    % ResultIndex is local to this group and remains the permanent key when a
    % user sorts the visible rows inside the directory's tab.
    resultIndex = (1:currentResultCount).';
    boneCode = strings(currentResultCount, 1);
    snapshotName = strings(currentResultCount, 1);
    sequenceIndex = zeros(currentResultCount, 1);
    packetIndex = zeros(currentResultCount, 1);
    timestamp = zeros(currentResultCount, 1);
    rawSegmentCount = zeros(currentResultCount, 1);
    rawPixelCount = zeros(currentResultCount, 1);
    facingSegmentCount = zeros(currentResultCount, 1);
    facingPixelCount = zeros(currentResultCount, 1);
    resultStatus = strings(currentResultCount, 1);

    % Convert this group's aligned records into simple scalar table values.
    for localResultIndex = 1:currentResultCount
        currentPlane = currentPlanes(localResultIndex);
        currentIntersection = currentIntersections(localResultIndex);

        boneCode(localResultIndex) = string(currentPlane.bone);
        snapshotName(localResultIndex) = string(currentPlane.snapshotName);
        sequenceIndex(localResultIndex) = double(currentPlane.sequenceIndex);
        packetIndex(localResultIndex) = double(currentPlane.packetIndex);
        timestamp(localResultIndex) = double(currentPlane.timestamp);
        rawSegmentCount(localResultIndex) = ...
            numel(currentIntersection.segments3D);
        rawPixelCount(localResultIndex) = ...
            size(currentIntersection.pixelList, 1);
        facingSegmentCount(localResultIndex) = ...
            numel(currentIntersection.probeFacingSegments3D);
        facingPixelCount(localResultIndex) = ...
            size(currentIntersection.probeFacingPixels, 1);
        resultStatus(localResultIndex) = string(currentIntersection.status);
    end

    % Preserve local acquisition order initially while allowing independent
    % sorting inside every source-directory tab.
    currentResultsData = table( ...
        resultIndex, boneCode, snapshotName, sequenceIndex, packetIndex, ...
        timestamp, rawSegmentCount, rawPixelCount, facingSegmentCount, ...
        facingPixelCount, resultStatus, ...
        'VariableNames', { ...
            'ResultIndex', 'Bone', 'SnapshotGroup', 'Sequence', 'Packet', ...
            'Timestamp', 'RawSegments', 'RawPixels', 'FacingSegments', ...
            'FacingPixels', 'Status'});

    % Keep review decisions separate from sortable table rows. Each logical
    % value uses the group's stable local ResultIndex.
    reviewDecisions{groupIndex} = false(currentResultCount, 1);
    if isReviewMode
        currentResultsData = addvars( ...
            currentResultsData, reviewDecisions{groupIndex}, ...
            'Before', 'ResultIndex', ...
            'NewVariableNames', 'Valid');
    end
    resultsDataByGroup{groupIndex} = currentResultsData;
end

% Use the total only for global review controls and the overall empty state;
% the result records themselves remain separated by group.
nResults = sum(nResultsByGroup);
lastSelectedResultIndexByGroup = zeros(1, nGroups);

%% CREATE THE RESULTS-FIRST USER INTERFACE

% Use a wide responsive figure so the table, 2D image, and 3D scene can remain
% readable beside each other on a standard desktop display.
figBrowser = uifigure( ...
    'Name', 'Snapshot Mesh-Plane Intersection Browser', ...
    'Position', [20, 60, 1880, 880], ...
    'CloseRequestFcn', @closeBrowser);

% Place the three primary views from left to right as requested. The table
% keeps a fixed width while both plot columns share the remaining space.
mainGrid = uigridlayout(figBrowser, [1, 3], ...
    'ColumnWidth', {650, '1x', '1x'}, ...
    'Padding', [10, 10, 10, 10], ...
    'ColumnSpacing', 10);

% Define empty handles before the review-only branch so the later empty-data
% state can disable controls without needing separate browser implementations.
selectAllButton = gobjects(0);
clearAllButton = gobjects(0);
selectionCountLabel = gobjects(0);
exportSelectedButton = gobjects(0);

% Review mode uses a small second row under the tabbed tables. Display mode
% places the same tab group directly in the main three-column grid.
if isReviewMode
    tableGrid = uigridlayout(mainGrid, [2, 1], ...
        'RowHeight', {'1x', 34}, ...
        'Padding', [0, 0, 0, 0], ...
        'RowSpacing', 6);
    tableGrid.Layout.Row = 1;
    tableGrid.Layout.Column = 1;
    resultsTableParent = tableGrid;
else
    resultsTableParent = mainGrid;
end

% Configure column labels and edit permissions once because every directory
% tab exposes the same record fields. Only Valid can be edited in review mode.
if isReviewMode
    resultsColumnNames = { ...
        'Valid', 'Index', 'Bone', 'Snapshot group', 'Sequence', 'Packet', ...
        'Timestamp', 'Raw segments', 'Raw pixels', 'Facing segments', ...
        'Facing pixels', 'Status'};
    resultsColumnWidths = {55, 65, 50, 135, 70, 60, 90, 90, 75, 100, 90, 'auto'};
    resultsColumnEditable = [true, false(1, 11)];
else
    resultsColumnNames = { ...
        'Index', 'Bone', 'Snapshot group', 'Sequence', 'Packet', ...
        'Timestamp', 'Raw segments', 'Raw pixels', 'Facing segments', ...
        'Facing pixels', 'Status'};
    resultsColumnWidths = {65, 50, 135, 70, 60, 90, 90, 75, 100, 90, 'auto'};
    resultsColumnEditable = false(1, 11);
end

% Create one tab and table per source directory. The table and tab store their
% group index so callbacks can recover the first part of the grouped identity.
resultsTabGroup = gobjects(0);
resultsTabs = gobjects(1, nGroups);
resultsTables = gobjects(1, nGroups);
if nGroups > 0
    resultsTabGroup = uitabgroup(resultsTableParent, ...
        'Tag', 'snapshot_intersection_results_tab_group');
    resultsTabGroup.Layout.Row = 1;
    resultsTabGroup.Layout.Column = 1;

    for groupIndex = 1:nGroups
        currentGroupName = char(string(snapshotPlanes(groupIndex).name));
        resultsTabs(groupIndex) = uitab(resultsTabGroup, ...
            'Title', currentGroupName, ...
            'Tag', sprintf('snapshot_intersection_group_tab_%d', groupIndex));
        resultsTabs(groupIndex).UserData = groupIndex;

        % A one-cell grid makes the table fill its tab as the browser resizes.
        currentTabGrid = uigridlayout(resultsTabs(groupIndex), [1, 1], ...
            'Padding', [0, 0, 0, 0]);
        currentResultsData = resultsDataByGroup{groupIndex};
        resultsTables(groupIndex) = uitable(currentTabGrid, ...
            'Data', currentResultsData, ...
            'ColumnName', resultsColumnNames, ...
            'ColumnWidth', resultsColumnWidths, ...
            'ColumnEditable', resultsColumnEditable, ...
            'ColumnSortable', true(1, width(currentResultsData)), ...
            'SelectionType', 'row', ...
            'Multiselect', 'off', ...
            'Tag', sprintf( ...
                'snapshot_intersection_results_table_%d', groupIndex));
        resultsTables(groupIndex).Layout.Row = 1;
        resultsTables(groupIndex).Layout.Column = 1;
        resultsTables(groupIndex).UserData = groupIndex;
        resultsTables(groupIndex).SelectionChangedFcn = ...
            @handleSelectionChanged;

        % Empty source groups stay visible as tabs but cannot emit row events.
        if nResultsByGroup(groupIndex) == 0
            resultsTables(groupIndex).Enable = 'off';
        end
        if isReviewMode
            resultsTables(groupIndex).CellEditCallback = @handleValidEdit;
        end
    end
else
    % Explain a root directory with no source groups in the same left column
    % where directory tabs would normally be created.
    noGroupsLabel = uilabel(resultsTableParent, ...
        'Text', 'No snapshot source directories are available.', ...
        'HorizontalAlignment', 'center', ...
        'Tag', 'snapshot_intersection_no_groups_label');
    noGroupsLabel.Layout.Row = 1;
    noGroupsLabel.Layout.Column = 1;
end

% Add compact review actions below the table without reducing either image
% axes. The buttons all operate on stable ResultIndex values, not visible rows.
if isReviewMode
    reviewControlGrid = uigridlayout(tableGrid, [1, 4], ...
        'ColumnWidth', {85, 85, '1x', 120}, ...
        'Padding', [0, 0, 0, 0], ...
        'ColumnSpacing', 6);
    reviewControlGrid.Layout.Row = 2;
    reviewControlGrid.Layout.Column = 1;

    selectAllButton = uibutton(reviewControlGrid, 'push', ...
        'Text', 'Select all', ...
        'ButtonPushedFcn', @selectAllSnapshots, ...
        'Tag', 'snapshot_intersection_select_all_button');
    selectAllButton.Layout.Row = 1;
    selectAllButton.Layout.Column = 1;

    clearAllButton = uibutton(reviewControlGrid, 'push', ...
        'Text', 'Clear all', ...
        'ButtonPushedFcn', @clearAllSnapshots, ...
        'Tag', 'snapshot_intersection_clear_all_button');
    clearAllButton.Layout.Row = 1;
    clearAllButton.Layout.Column = 2;

    selectionCountLabel = uilabel(reviewControlGrid, ...
        'Text', sprintf('Selected: 0 / %d', nResults), ...
        'HorizontalAlignment', 'center', ...
        'Tag', 'snapshot_intersection_selection_count_label');
    selectionCountLabel.Layout.Row = 1;
    selectionCountLabel.Layout.Column = 3;

    exportSelectedButton = uibutton(reviewControlGrid, 'push', ...
        'Text', 'Export selected', ...
        'FontWeight', 'bold', ...
        'ButtonPushedFcn', @exportSelectedSnapshots, ...
        'Tag', 'snapshot_intersection_export_button');
    exportSelectedButton.Layout.Row = 1;
    exportSelectedButton.Layout.Column = 4;

end

% Create one large image axes because only the selected row should be drawn.
imageAxes = uiaxes(mainGrid, 'Tag', 'snapshot_intersection_image_axes');
imageAxes.Layout.Row = 1;
imageAxes.Layout.Column = 2;
xlabel(imageAxes, 'Column');
ylabel(imageAxes, 'Row');
box(imageAxes, 'on');
colormap(imageAxes, gray(256));

% Create a separate 3D axes owned by this browser. The static ax1 overview is
% intentionally not passed into or modified by this function.
sceneAxes = uiaxes(mainGrid, 'Tag', 'snapshot_intersection_3d_axes');
sceneAxes.Layout.Row = 1;
sceneAxes.Layout.Column = 3;
xlabel(sceneAxes, 'X');
ylabel(sceneAxes, 'Y');
zlabel(sceneAxes, 'Z');
grid(sceneAxes, 'on');
box(sceneAxes, 'on');
axis(sceneAxes, 'equal');
view(sceneAxes, 35, 40);
title(sceneAxes, 'Selected 3D scene', 'Interpreter', 'none');

% Keep the supported toolbar modes that do not need the default left-drag
% rotation. Rotation is handled below so MATLAB does not enter its fast
% uifigure interaction state and hide the neighboring ultrasound axes.
sceneToolbar = axtoolbar( ...
    sceneAxes, {'pan', 'zoomin', 'zoomout', 'restoreview'});

% Remove the built-in gestures from only the 3D axes. A custom left-drag
% callback provides rotation, while the explicit toolbar still provides
% pan, zoom, and restore-view controls.
disableDefaultInteractivity(sceneAxes);
sceneAxes.Interactions = [];
sceneAxes.ButtonDownFcn = @startSceneRotation;

% Track an active mouse drag at figure level so rotation continues when the
% pointer moves quickly between motion events inside the 3D axes.
figBrowser.WindowButtonMotionFcn = @continueSceneRotation;
figBrowser.WindowButtonUpFcn = @stopSceneRotation;

% Track whether a selected 3D scene has already been rendered. This lets row
% changes preserve a user-adjusted view angle while the first row uses the
% standard project view.
hasRendered3DScene = false;

% Store the small amount of state needed by the custom left-drag rotation.
% The start values make each redraw independent of skipped motion events.
isSceneRotationActive = false;
sceneRotationStartPointer = [NaN, NaN];
sceneRotationStartView = [NaN, NaN];
sceneRotationAxesSize = [1, 1];
scenePointerBeforeRotation = 'arrow';
sceneHeadlight = gobjects(0);

%% CONNECT TABLE SELECTION TO THE TWO DISPLAYS

% Show a readable empty state instead of attempting to select a row that does
% not exist when every packet was rejected by the tracking checks.
if nResults == 0
    % No review action is meaningful without results. Keep the controls
    % visible so the layout remains understandable, but prevent empty exports.
    if isReviewMode
        selectAllButton.Enable = 'off';
        clearAllButton.Enable = 'off';
        exportSelectedButton.Enable = 'off';
    end

    if nGroups == 0
        renderEmptyGroup([]);
    else
        renderEmptyGroup(1);
    end
else
    % Start on the first group that contains a valid plane. Empty groups remain
    % available as tabs and show their own message when selected later.
    firstNonemptyGroupIndex = find(nResultsByGroup > 0, 1);
    resultsTabGroup.SelectedTab = resultsTabs(firstNonemptyGroupIndex);
    resultsTables(firstNonemptyGroupIndex).Selection = 1;
    lastSelectedResultIndexByGroup(firstNonemptyGroupIndex) = 1;
    renderSnapshot(firstNonemptyGroupIndex, 1);
end

% Connect tab changes only after the initial axes state exists. This avoids a
% partially created callback trying to render while the UI is still building.
if nGroups > 0
    resultsTabGroup.SelectionChangedFcn = @handleTabChanged;
end

% Review mode returns its data only after the first completed export or a
% close cancellation. Display mode skips this wait and remains non-blocking.
if isReviewMode && isvalid(figBrowser)
    uiwait(figBrowser);
end

    function handleValidEdit(sourceTable, eventData)
        %HANDLEVALIDEDIT Store one checkbox decision by original result index.
        % This callback reads its group from the source table because identical
        % local result indices can exist in several directory tabs.
        %
        % Inputs:
        %   sourceTable : Table whose UserData stores its source-group index.
        %   eventData : Cell edit event containing original data indices and
        %               the logical value written to the Valid cell.
        %
        % Outputs:
        %   None. The callback updates reviewDecisions and the count label.

        % Ignore rejected edits. MATLAB leaves NewData empty when it cannot
        % store the user's value in the logical checkbox column.
        if ~isempty(eventData.Error) || isempty(eventData.NewData)
            return;
        end

        % Cell edit indices refer to the original Data array even after the
        % visible rows have been sorted, which makes this lookup stable.
        editedDataRow = eventData.Indices(1);
        editedDataColumn = eventData.Indices(2);
        currentTableData = sourceTable.Data;
        editedGroupIndex = sourceTable.UserData;

        % Defend against stale UI events that refer to data no longer present.
        if editedDataRow < 1 || editedDataRow > height(currentTableData) || ...
                editedDataColumn < 1 || editedDataColumn > width(currentTableData)
            return;
        end

        % Only the named Valid variable is allowed to modify review state.
        % This remains correct if a future metadata column is inserted.
        editedVariableName = ...
            currentTableData.Properties.VariableNames{editedDataColumn};
        if ~strcmp(editedVariableName, 'Valid')
            return;
        end

        % Resolve the permanent result identity before updating the logical
        % vector. No table refresh is needed because MATLAB already wrote the cell.
        editedResultIndex = currentTableData.ResultIndex(editedDataRow);
        reviewDecisions{editedGroupIndex}(editedResultIndex) = ...
            logical(eventData.NewData);
        updateSelectionCount();
    end

    function selectAllSnapshots(~, ~)
        %SELECTALLSNAPSHOTS Mark every original snapshot result as valid.
        % This bulk action ignores the current visible sort order so every
        % underlying result is selected exactly once.
        %
        % Inputs:
        %   ~ : Unused button source and event inputs supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback updates review state and displayed checkboxes.

        for groupIndexToUpdate = 1:nGroups
            reviewDecisions{groupIndexToUpdate}(:) = true;
        end
        synchronizeValidColumn();
    end

    function clearAllSnapshots(~, ~)
        %CLEARALLSNAPSHOTS Clear every original snapshot review decision.
        % This provides a direct inverse of Select all without depending on
        % the current table sorting or selection.
        %
        % Inputs:
        %   ~ : Unused button source and event inputs supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback updates review state and displayed checkboxes.

        for groupIndexToUpdate = 1:nGroups
            reviewDecisions{groupIndexToUpdate}(:) = false;
        end
        synchronizeValidColumn();
    end

    function synchronizeValidColumn()
        %SYNCHRONIZEVALIDCOLUMN Refresh checkboxes from stable review state.
        % This helper is needed after bulk changes because programmatic vector
        % updates do not automatically edit each logical table cell.
        %
        % Inputs:
        %   None.
        %
        % Outputs:
        %   None. The helper refreshes Valid cells and preserves selection.

        % Refresh each directory table independently because its ResultIndex is
        % local to that group. Empty tables need no checkbox synchronization.
        for groupIndexToUpdate = 1:nGroups
            currentResultsTable = resultsTables(groupIndexToUpdate);
            currentTableData = currentResultsTable.Data;
            if height(currentTableData) == 0
                continue;
            end
            selectedResultIndex = [];

            % Remember the selected local identity before replacing table data.
            selectedDataRows = currentResultsTable.Selection;
            if ~isempty(selectedDataRows) && ...
                    selectedDataRows(1) >= 1 && ...
                    selectedDataRows(1) <= height(currentTableData)
                selectedResultIndex = ...
                    currentTableData.ResultIndex(selectedDataRows(1));
            end

            % Map checkbox values by stable local ResultIndex so sorting does
            % not move review decisions to another acquisition.
            currentTableData.Valid = reviewDecisions{groupIndexToUpdate}( ...
                currentTableData.ResultIndex);
            currentResultsTable.Data = currentTableData;

            % Restore the selected record if MATLAB rebuilt the table view.
            if ~isempty(selectedResultIndex)
                refreshedTableData = currentResultsTable.Data;
                selectedDataRow = find( ...
                    refreshedTableData.ResultIndex == selectedResultIndex, 1);
                if ~isempty(selectedDataRow)
                    currentResultsTable.Selection = selectedDataRow;
                end
            end
        end

        updateSelectionCount();
    end

    function updateSelectionCount()
        %UPDATESELECTIONCOUNT Show how many original results are selected.
        % The count comes from reviewDecisions so sorting and scrolling cannot
        % change the displayed review total.
        %
        % Inputs:
        %   None.
        %
        % Outputs:
        %   None. The helper updates the review count label text.

        if ~isempty(selectionCountLabel) && isvalid(selectionCountLabel)
            selectedResultCount = sum(cellfun(@nnz, reviewDecisions));
            selectionCountLabel.Text = sprintf( ...
                'Selected: %d / %d', selectedResultCount, nResults);
        end
    end

    function handleTabChanged(~, eventData)
        %HANDLETABCHANGED Show the remembered acquisition for the active group.
        % Directory tabs own independent tables, so switching tabs must restore
        % that group's local selection or show a group-specific empty message.
        %
        % Inputs:
        %   ~         : Unused tab-group handle supplied by MATLAB.
        %   eventData : Tab selection event whose NewValue stores group index.
        %
        % Outputs:
        %   None. The callback updates table selection and both display axes.

        if isempty(eventData.NewValue) || ~isvalid(eventData.NewValue)
            return;
        end
        selectedGroupIndex = eventData.NewValue.UserData;
        if nResultsByGroup(selectedGroupIndex) == 0
            renderEmptyGroup(selectedGroupIndex);
            return;
        end

        % Use the group's previous stable local index, or its first acquisition
        % when the tab has not been visited before.
        selectedResultIndex = ...
            lastSelectedResultIndexByGroup(selectedGroupIndex);
        if selectedResultIndex < 1 || ...
                selectedResultIndex > nResultsByGroup(selectedGroupIndex)
            selectedResultIndex = 1;
        end
        currentTableData = resultsTables(selectedGroupIndex).Data;
        selectedDataRow = find( ...
            currentTableData.ResultIndex == selectedResultIndex, 1);
        if ~isempty(selectedDataRow)
            resultsTables(selectedGroupIndex).Selection = selectedDataRow;
        end
        lastSelectedResultIndexByGroup(selectedGroupIndex) = ...
            selectedResultIndex;
        renderSnapshot(selectedGroupIndex, selectedResultIndex);
    end

    function renderEmptyGroup(groupIndexToRender)
        %RENDEREMPTYGROUP Clear both views when a group has no valid planes.
        % This state keeps empty source directories visible without leaving an
        % image or 3D scene from a different directory on screen.
        %
        % Input:
        %   groupIndexToRender : Empty when no groups exist, or the index of an
        %                        existing source group whose data is empty.
        %
        % Outputs:
        %   None. The helper replaces both axes with explanatory text.

        stopSceneRotation([], []);
        hasRendered3DScene = false;
        sceneHeadlight = gobjects(0);
        cla(imageAxes);
        cla(sceneAxes);

        if isempty(groupIndexToRender)
            imageMessage = 'No snapshot source directories are available.';
        else
            imageMessage = sprintf( ...
                'No valid tracked snapshots are available in "%s".', ...
                char(string(snapshotPlanes(groupIndexToRender).name)));
        end
        axis(imageAxes, 'off');
        text(imageAxes, 0.5, 0.5, imageMessage, ...
            'Units', 'normalized', ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'middle', ...
            'Interpreter', 'none');

        % Give the 3D column a separate message so both views clearly describe
        % why no geometry is currently rendered.
        axis(sceneAxes, 'off');
        text(sceneAxes, 0.5, 0.5, ...
            'No selected 3D scene is available.', ...
            'Units', 'normalized', ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'middle', ...
            'Interpreter', 'none');
    end

    function exportSelectedSnapshots(~, ~)
        %EXPORTSELECTEDSNAPSHOTS Save complete records chosen during review.
        % This callback copies stored plane and intersection records without
        % recalculating geometry, then saves the result using MAT-file v7.3.
        %
        % Inputs:
        %   ~ : Unused button source and event inputs supplied by MATLAB.
        %
        % Outputs:
        %   None. The callback updates the parent function outputs, writes the
        %   MAT-file, reports success, and releases the first review wait.

        % Collect selected local indices independently for every source group.
        % find preserves original acquisition order regardless of table sorting.
        selectedResultIndicesByGroup = cellfun( ...
            @find, reviewDecisions, 'UniformOutput', false);
        selectedResultCount = sum(cellfun( ...
            @numel, selectedResultIndicesByGroup));
        if selectedResultCount == 0
            uialert(figBrowser, ...
                ['No snapshots are selected. Check at least one Valid box ' ...
                'before exporting.'], ...
                'No snapshots selected', ...
                'Icon', 'warning');
            return;
        end

        % Build the default name when Export selected is pressed so its
        % timestamp describes this export attempt rather than browser startup.
        exportTimestamp = char(datetime('now', ...
            'Format', 'yyyyMMdd_HHmmss'));
        defaultExportFileName = sprintf( ...
            'validSnapshots_%s.mat', exportTimestamp);

        % Prefix the suggested file with the caller's output directory. An
        % empty directory preserves MATLAB's default current-folder behavior.
        if isempty(outputDirectory)
            defaultExportPath = defaultExportFileName;
        else
            defaultExportPath = fullfile( ...
                outputDirectory, defaultExportFileName);
        end

        % Ask for a MAT-file destination only after confirming that the export
        % has content. Cancelling this dialog intentionally leaves review state.
        [selectedFileName, selectedDirectory] = uiputfile( ...
            {'*.mat', 'MAT-files (*.mat)'}, ...
            'Export selected snapshots', ...
            defaultExportPath);
        if isequal(selectedFileName, 0) || isequal(selectedDirectory, 0)
            return;
        end

        % Preserve the previous completed export so a later save failure does
        % not replace good callback state while the open browser remains usable.
        previousValidSnapshots = validSnapshots;
        previousOutputFilePath = outputFilePath;

        % Build one selected-record template, then keep every outer source group
        % even when the reviewer did not select a record from that directory.
        validSnapshotDataTemplate = struct( ...
            'sourceIndex', [], ...
            'plane', [], ...
            'intersection', []);
        emptyValidSnapshotData = repmat( ...
            validSnapshotDataTemplate, 1, 0);
        validSnapshotGroupTemplate = struct( ...
            'name', '', ...
            'bone', 'U', ...
            'path', '', ...
            'data', emptyValidSnapshotData);
        validSnapshots = repmat( ...
            validSnapshotGroupTemplate, 1, nGroups);

        % Copy complete plane and intersection records without recalculating
        % geometry. sourceIndex remains local to the surrounding source group.
        for groupIndexToExport = 1:nGroups
            validSnapshots(groupIndexToExport).name = ...
                snapshotPlanes(groupIndexToExport).name;
            validSnapshots(groupIndexToExport).bone = ...
                snapshotPlanes(groupIndexToExport).bone;
            validSnapshots(groupIndexToExport).path = ...
                snapshotPlanes(groupIndexToExport).path;

            currentSelectedResultIndices = ...
                selectedResultIndicesByGroup{groupIndexToExport};
            currentSelectedData = repmat( ...
                validSnapshotDataTemplate, ...
                1, numel(currentSelectedResultIndices));
            for outputIndex = 1:numel(currentSelectedResultIndices)
                selectedResultIndex = ...
                    currentSelectedResultIndices(outputIndex);
                currentSelectedData(outputIndex).sourceIndex = ...
                    selectedResultIndex;
                currentSelectedData(outputIndex).plane = ...
                    snapshotPlanes(groupIndexToExport).data(selectedResultIndex);
                currentSelectedData(outputIndex).intersection = ...
                    intersections(groupIndexToExport).data(selectedResultIndex);
            end
            validSnapshots(groupIndexToExport).data = currentSelectedData;
        end
        outputFilePath = fullfile(selectedDirectory, selectedFileName);

        % Keep the required variable name and v7.3 format because ultrasound
        % image payloads can make the exported dataset larger than 2 GB.
        try
            save(outputFilePath, 'validSnapshots', '-v7.3');
        catch saveError
            validSnapshots = previousValidSnapshots;
            outputFilePath = previousOutputFilePath;
            uialert(figBrowser, ...
                sprintf('Could not save the selected snapshots:\n\n%s', ...
                saveError.message), ...
                'Export failed', ...
                'Icon', 'error');
            return;
        end

        % Mark success before releasing uiwait so a later close is not treated
        % as cancellation. The browser intentionally stays open and editable.
        hasSuccessfulExport = true;
        uialert(figBrowser, ...
            sprintf('Exported %d snapshot(s).\n\nSaved to:\n%s', ...
            selectedResultCount, outputFilePath), ...
            'Export complete', ...
            'Icon', 'success');
        if strcmp(figBrowser.WaitStatus, 'waiting')
            uiresume(figBrowser);
        end
    end

    function startSceneRotation(~, ~)
        %STARTSCENEROTATION Begin a custom left-button rotation gesture.
        % This callback replaces MATLAB's built-in UIAxes rotation because
        % that interaction can hide sibling axes while the pointer moves.

        % Do not rotate before a scene exists or for any non-left click.
        if ~hasRendered3DScene || ...
                ~strcmp(figBrowser.SelectionType, 'normal')
            return;
        end

        % Let an explicitly selected pan or zoom toolbar mode own the drag.
        if isSceneToolbarModeActive()
            return;
        end

        % Record the drag origin so skipped motion events cannot accumulate error.
        isSceneRotationActive = true;
        sceneRotationStartPointer = figBrowser.CurrentPoint;
        sceneRotationStartView = sceneAxes.View;
        sceneRotationAxesSize = max(sceneAxes.Position(3:4), 1);
        scenePointerBeforeRotation = figBrowser.Pointer;

        % Keep the table enabled during rotation. Changing its Enable state
        % rebuilds MATLAB's table view and resets a scrolled table to the top.
        % The figure-level mouse callbacks already own the active drag, so the
        % table does not need to be disabled while the 3D view is rotating.
        figBrowser.Pointer = 'fleur';
    end

    function continueSceneRotation(~, ~)
        %CONTINUESCENEROTATION Update the 3D view during an active mouse drag.
        % Direct view updates avoid the figure-wide fast interaction renderer,
        % so the independent middle ultrasound axes remains on screen.

        % Mouse movement outside an active rotation should have no effect.
        if ~isSceneRotationActive
            return;
        end

        % Convert total pointer movement into azimuth and elevation changes.
        currentPointerPosition = figBrowser.CurrentPoint;
        pointerDelta = currentPointerPosition - sceneRotationStartPointer;

        % Ignore repeated motion events that report the same pixel location.
        if all(pointerDelta == 0)
            return;
        end

        % A full-width or full-height drag corresponds to half a revolution.
        newAzimuth = sceneRotationStartView(1) - ...
            180 * pointerDelta(1) / sceneRotationAxesSize(1);
        % Reverse the screen-space vertical delta so an upward drag produces
        % an upward apparent rotation and a downward drag does the opposite.
        newElevation = sceneRotationStartView(2) - ...
            180 * pointerDelta(2) / sceneRotationAxesSize(2);

        % Keep azimuth in MATLAB's conventional signed-degree range.
        newAzimuth = mod(newAzimuth + 180, 360) - 180;

        % Avoid the singular camera direction at exactly either vertical pole.
        newElevation = min(max(newElevation, -89.9), 89.9);
        view(sceneAxes, newAzimuth, newElevation);

        % Move the existing light with the camera so mesh shading stays stable.
        if ~isempty(sceneHeadlight) && isgraphics(sceneHeadlight, 'light')
            camlight(sceneHeadlight, 'headlight');
        end

        % Process only the latest pending redraw to keep mouse motion responsive.
        drawnow limitrate nocallbacks;
    end

    function stopSceneRotation(~, ~)
        %STOPSCENEROTATION Finish the custom rotation after mouse release.
        % Resetting the state ensures later pointer movement cannot alter the view.

        % A release without a matching start has no state to restore.
        if ~isSceneRotationActive
            return;
        end

        isSceneRotationActive = false;
        sceneRotationStartPointer = [NaN, NaN];
        sceneRotationStartView = [NaN, NaN];

        % Restore the pointer changed only for the duration of the drag.
        figBrowser.Pointer = scenePointerBeforeRotation;
    end

    function isActive = isSceneToolbarModeActive()
        %ISSCENETOOLBARMODEACTIVE Check whether pan or zoom owns left-drag.
        % The restore-view control is a push button and has no active state.

        isActive = false;
        toolbarButtons = sceneToolbar.Children;
        for toolbarButtonIndex = 1:numel(toolbarButtons)
            currentToolbarButton = toolbarButtons(toolbarButtonIndex);
            if isprop(currentToolbarButton, 'Value') && ...
                    strcmp(currentToolbarButton.Value, 'on')
                isActive = true;
                return;
            end
        end
    end

    function handleSelectionChanged(sourceTable, eventData)
        %HANDLESELECTIONCHANGED Render the snapshot represented by a selected row.
        % The source table identifies the directory group, while its immutable
        % local ResultIndex keeps the image and intersection paired after sorting.
        %
        % Inputs:
        %   sourceTable : Selected table whose UserData stores group index.
        %   eventData : Table selection event containing selected display rows.
        %
        % Outputs:
        %   None. The callback updates the 2D axes, metadata, and 3D axes.

        % Ignore deselection events because there is no replacement result to draw.
        if isempty(eventData.Selection)
            return;
        end

        % Use the first row defensively even though Multiselect is disabled.
        % Selection refers to the original Data array, not the sorted display.
        selectedDataRow = eventData.Selection(1);
        storedResults = sourceTable.Data;
        selectedGroupIndex = sourceTable.UserData;

        % Stop if a stale UI event refers to a row outside the stored data.
        if selectedDataRow < 1 || selectedDataRow > height(storedResults)
            return;
        end

        % Recover and remember the group-local acquisition index before drawing.
        selectedResultIndex = storedResults.ResultIndex(selectedDataRow);
        lastSelectedResultIndexByGroup(selectedGroupIndex) = ...
            selectedResultIndex;
        renderSnapshot(selectedGroupIndex, selectedResultIndex);
    end

    function renderSnapshot(selectedGroupIndex, selectedResultIndex)
        %RENDERSNAPSHOT Draw one result in 2D and synchronize its 3D highlight.
        % This renderer keeps heavy image and geometry arrays outside the
        % table. It is needed so row changes redraw only one snapshot instead
        % of creating hundreds of axes and graphics objects.
        %
        % Inputs:
        %   selectedGroupIndex  : Stable source-directory group index.
        %   selectedResultIndex : Stable local data index within that group.
        %
        % Outputs:
        %   None. The function updates existing UI and 3D graphics objects.

        % End a stale drag before replacing graphics or preserving its camera.
        stopSceneRotation([], []);

        % Read the aligned grouped records once so all display elements use the
        % same source directory and local acquisition.
        currentPlane = ...
            snapshotPlanes(selectedGroupIndex).data(selectedResultIndex);
        currentIntersection = ...
            intersections(selectedGroupIndex).data(selectedResultIndex);

        % Replace the previous 2D content before drawing the selected raw image.
        cla(imageAxes);
        axis(imageAxes, 'on');
        displayImage = currentPlane.image.';
        imagesc(imageAxes, displayImage);
        axis(imageAxes, 'image');
        colormap(imageAxes, gray(256));
        hold(imageAxes, 'on');

        % Convert physical UV distances with the same convention used during
        % intersection rasterization, then draw every raw segment in red.
        if ~isempty(currentIntersection.segmentsUV)
            du = currentPlane.W / currentPlane.nCols;
            dv = currentPlane.H / currentPlane.nRows;
            for segmentIndex = 1:numel(currentIntersection.segmentsUV)
                currentSegmentUV = currentIntersection.segmentsUV{segmentIndex};
                segmentColumns = currentSegmentUV(:, 1) ./ du + 1;
                segmentRows = currentSegmentUV(:, 2) ./ dv + 1;
                plot(imageAxes, segmentColumns, segmentRows, 'r-', ...
                    'LineWidth', 1.5);
            end
        end

        % Draw all rasterized mesh-plane pixels in yellow for comparison with
        % the continuous UV segments.
        if ~isempty(currentIntersection.pixelList)
            rawRows = currentIntersection.pixelList(:, 1);
            rawColumns = currentIntersection.pixelList(:, 2);
            plot(imageAxes, rawColumns, rawRows, 'y.', 'MarkerSize', 10);
        end

        % Draw the probe-facing subset last so green markers remain visible on
        % top of both the raw pixels and grayscale ultrasound image.
        if ~isempty(currentIntersection.probeFacingPixels)
            facingRows = currentIntersection.probeFacingPixels(:, 1);
            facingColumns = currentIntersection.probeFacingPixels(:, 2);
            plot(imageAxes, facingColumns, facingRows, 'go', ...
                'MarkerSize', 5, ...
                'LineWidth', 1);
        end

        % Create stable marker samples for the legend. NaN coordinates keep
        % these samples out of the image while preserving both legend entries
        % for rows whose selected intersection set is empty.
        rawPixelLegendHandle = plot(imageAxes, NaN, NaN, 'y.', ...
            'MarkerSize', 10, ...
            'HitTest', 'off', ...
            'PickableParts', 'none', ...
            'Tag', 'plot_browser_raw_pixel_legend_proxy');
        facingPixelLegendHandle = plot(imageAxes, NaN, NaN, 'go', ...
            'MarkerSize', 5, ...
            'LineWidth', 1, ...
            'HitTest', 'off', ...
            'PickableParts', 'none', ...
            'Tag', 'plot_browser_facing_pixel_legend_proxy');
        hold(imageAxes, 'off');

        % Put the yellow and green explanations beside their 2D graphics.
        imageLegend = legend( ...
            imageAxes, ...
            [rawPixelLegendHandle, facingPixelLegendHandle], ...
            {'Full rasterized hit', 'Probe-facing hit'}, ...
            'Location', 'northwest', ...
            'Interpreter', 'none', ...
            'Tag', 'snapshot_intersection_image_legend');
        imageLegend.AutoUpdate = 'off';

        % Use two title lines so long snapshot group names do not crowd the axes.
        title(imageAxes, { ...
            sprintf('%s | Bone %s', ...
                char(string(currentPlane.snapshotName)), ...
                char(string(currentPlane.bone))), ...
            sprintf('Group acquisition %d | Sequence %d | Packet %d | t = %.3f', ...
                selectedResultIndex, currentPlane.sequenceIndex, ...
                currentPlane.packetIndex, double(currentPlane.timestamp))}, ...
            'Interpreter', 'none');
        xlabel(imageAxes, 'Column');
        ylabel(imageAxes, 'Row');

        % Save the current camera orientation before clearing graphics so a
        % user-adjusted view survives selection of another table row.
        previousSceneView = sceneAxes.View;
        sceneHeadlight = gobjects(0);
        cla(sceneAxes);
        axis(sceneAxes, 'on');
        hold(sceneAxes, 'on');

        % Select only the anatomical mesh identified by this snapshot's bone
        % code. Unknown codes intentionally leave the mesh absent.
        currentBoneCode = char(string(currentPlane.bone));
        hasMatchingBoneMesh = ~isempty(currentBoneCode) && ...
            isvarname(currentBoneCode) && ...
            isfield(boneMeshesRefByCode, currentBoneCode);
        if hasMatchingBoneMesh
            currentBoneMesh = boneMeshesRefByCode.(currentBoneCode);

            % Draw the selected reference-frame mesh with the same appearance
            % used by the static overview figure.
            patch(sceneAxes, ...
                'Faces', currentBoneMesh.F, ...
                'Vertices', currentBoneMesh.V, ...
                'FaceColor', [0.92, 0.83, 0.74], ...
                'EdgeColor', 'none', ...
                'FaceAlpha', 0.40, ...
                'HitTest', 'off', ...
                'PickableParts', 'none', ...
                'Tag', 'plot_browser_bone_mesh');
        end

        % Reconstruct the image-to-reference transform from the stored plane
        % origin and unit directions so no external graphics object is needed.
        T_image_ref = eye(4);
        T_image_ref(1:3, 1) = reshape(currentPlane.ex, 3, 1);
        T_image_ref(1:3, 2) = reshape(currentPlane.ey, 3, 1);
        T_image_ref(1:3, 3) = reshape(currentPlane.n, 3, 1);
        T_image_ref(1:3, 4) = reshape(currentPlane.p0, 3, 1);

        % Recover physical pixel spacing from the finite plane dimensions.
        % Single-pixel dimensions use unit spacing because their extent is zero.
        if currentPlane.nCols > 1
            pixelSpacingX = currentPlane.W / (currentPlane.nCols - 1);
        else
            pixelSpacingX = 1;
        end
        if currentPlane.nRows > 1
            pixelSpacingY = currentPlane.H / (currentPlane.nRows - 1);
        else
            pixelSpacingY = 1;
        end

        % Draw only the selected ultrasound plane so the browser 3D view stays
        % lightweight even though the static overview contains every snapshot.
        selectedImageSurface = display_image3D( ...
            sceneAxes, currentPlane.image, T_image_ref, ...
            'SwapXY', true, ...
            'PixelSpacing', [pixelSpacingX, pixelSpacingY], ...
            'Tag', 'plot_browser_usimage', ...
            'Colormap', 'gray', ...
            'FaceAlpha', 0.55);

        % Send clicks through the textured plane to the 3D axes callback.
        selectedImageSurface.HitTest = 'off';
        selectedImageSurface.PickableParts = 'none';

        % Scale the coordinate arrows from the physical image dimensions so
        % the frame remains readable for both small and large image planes.
        imageAxisScale = 0.20 * max([currentPlane.W, currentPlane.H]);

        % Draw the image origin and its local X, Y, and Z directions. The
        % red and green arrows lie in the image plane, while blue shows the
        % plane normal used by the mesh-intersection calculation.
        display_axis_v2( ...
            sceneAxes, ...
            currentPlane.p0, ...
            [currentPlane.ex, currentPlane.ey, currentPlane.n], ...
            imageAxisScale, ...
            'Image origin', ...
            'Tag', 'plot_browser_usimage_axis', ...
            'Mode', 'default');

        % Keep the new triad from intercepting mouse input intended for the
        % browser's custom 3D rotation controls.
        imageAxisGraphics = findobj(sceneAxes, ...
            'Tag', 'plot_browser_usimage_axis');
        set(imageAxisGraphics, 'HitTest', 'off', 'PickableParts', 'none');

        % Match the previous interaction by highlighting only probe-facing 3D
        % segments. A zero-hit row simply leaves this object group empty.
        for segmentIndex = 1:numel(currentIntersection.probeFacingSegments3D)
            currentSegment3D = ...
                currentIntersection.probeFacingSegments3D{segmentIndex};
            plot3(sceneAxes, ...
                currentSegment3D(:, 1), ...
                currentSegment3D(:, 2), ...
                currentSegment3D(:, 3), ...
                'r-', ...
                'LineWidth', 2, ...
                'HitTest', 'off', ...
                'PickableParts', 'none', ...
                'Tag', 'plot_browser_mesh_plane_intersection');
        end

        % Create one stable red-line sample even when this row has no
        % probe-facing 3D segments, then use it only as the legend glyph.
        intersectionLegendHandle = plot3( ...
            sceneAxes, NaN, NaN, NaN, 'r-', ...
            'LineWidth', 2, ...
            'HitTest', 'off', ...
            'PickableParts', 'none', ...
            'Tag', 'plot_browser_intersection_legend_proxy');
        hold(sceneAxes, 'off');

        % Put the red-line explanation inside the corresponding 3D axes.
        sceneLegend = legend( ...
            sceneAxes, intersectionLegendHandle, ...
            {'Probe-facing 3D intersection'}, ...
            'Location', 'northwest', ...
            'Interpreter', 'none', ...
            'Tag', 'snapshot_intersection_scene_legend');
        sceneLegend.AutoUpdate = 'off';

        % Reapply scene styling because cla removes titles and labels together
        % with the previous selected graphics objects.
        xlabel(sceneAxes, 'X');
        ylabel(sceneAxes, 'Y');
        zlabel(sceneAxes, 'Z');
        grid(sceneAxes, 'on');
        box(sceneAxes, 'on');
        axis(sceneAxes, 'tight');
        daspect(sceneAxes, [1, 1, 1]);

        % Use the standard view for the first scene, then preserve any view
        % angle chosen through the 3D toolbar on later selections.
        if hasRendered3DScene
            view(sceneAxes, previousSceneView);
        else
            view(sceneAxes, 35, 40);
        end

        % Add lighting only when a mesh is present because the textured image
        % plane and intersection lines do not need surface shading.
        if hasMatchingBoneMesh
            sceneHeadlight = camlight(sceneAxes, 'headlight');
            lighting(sceneAxes, 'gouraud');
            material(sceneAxes, 'dull');
        end

        % Identify the selected anatomy directly above the independent 3D axes.
        title(sceneAxes, sprintf('%s | Bone %s', ...
            char(string(currentPlane.snapshotName)), currentBoneCode), ...
            'Interpreter', 'none');
        hasRendered3DScene = true;
        drawnow limitrate;
    end

    function closeBrowser(sourceFigure, ~)
        %CLOSEBROWSER Close the browser and cancel an unfinished review.
        % All selected graphics belong to sourceFigure, so deleting the browser
        % cleans its scene. Review cancellation also releases uiwait so MATLAB
        % cannot remain blocked after the user closes the window.
        %
        % Inputs:
        %   sourceFigure : Browser uifigure supplied by its CloseRequestFcn.
        %   ~            : Unused close event supplied by MATLAB.
        %
        % Outputs:
        %   None. The function updates cancellation outputs when needed,
        %   releases an active review wait, and deletes the browser.

        % Closing before the first successful review export is an explicit
        % cancellation, so return the documented empty values to the caller.
        if isReviewMode && ~hasSuccessfulExport
            validSnapshots = struct( ...
                'name', {}, ...
                'bone', {}, ...
                'path', {}, ...
                'data', {});
            outputFilePath = '';
        end

        % Resume before deletion because uiwait otherwise has no remaining
        % figure callback that could return control to the calling script.
        if strcmp(sourceFigure.WaitStatus, 'waiting')
            uiresume(sourceFigure);
        end

        % Delete only the browser; ax1 is intentionally outside this ownership boundary.
        delete(sourceFigure);
    end

end
