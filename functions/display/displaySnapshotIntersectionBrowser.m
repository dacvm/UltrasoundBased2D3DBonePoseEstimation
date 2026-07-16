function figBrowser = displaySnapshotIntersectionBrowser(snapshotPlanes, intersections, ax3D)
%DISPLAYSNAPSHOTINTERSECTIONBROWSER Browse precomputed snapshot intersections.
% This display-only function builds a results-first browser so many
% ultrasound snapshots can be inspected without drawing every 2D image at
% once. Selecting a table row updates one large 2D overlay and replaces the
% matching intersection highlight in the existing 3D scene.
%
% Inputs:
%   snapshotPlanes : Struct array containing finite image-plane geometry,
%                    source images, timestamps, bone codes, and snapshot
%                    indices. Its order defines the stable acquisition index.
%   intersections  : Struct array of precomputed raw and probe-facing
%                    mesh-plane intersection results. It must have one entry
%                    for every entry in snapshotPlanes.
%   ax3D            : Existing MATLAB axes that contains the 3D ultrasound
%                    and bone scene. The selected probe-facing segments are
%                    drawn here without changing the underlying scene.
%
% Output:
%   figBrowser      : Handle to the new uifigure that contains the sortable
%                    results table and selected 2D intersection display.

%% VALIDATE THE DISPLAY INPUTS

% Require the complete public interface so a missing 3D axes handle does not
% silently disable part of the results-first workflow.
if nargin ~= 3
    error('displaySnapshotIntersectionBrowser:InvalidInputCount', ...
        'Expected snapshotPlanes, intersections, and ax3D.');
end

% Check the two aligned result containers before inspecting their fields.
validateattributes(snapshotPlanes, {'struct'}, {'vector'}, ...
    mfilename, 'snapshotPlanes');
validateattributes(intersections, {'struct'}, {'vector'}, ...
    mfilename, 'intersections');

% Stop when array lengths differ because a table row could otherwise show an
% image and intersection that came from different acquisitions.
if numel(snapshotPlanes) ~= numel(intersections)
    error('displaySnapshotIntersectionBrowser:InputSizeMismatch', ...
        ['snapshotPlanes contains %d entry/entries, but intersections ' ...
        'contains %d. The arrays must stay aligned.'], ...
        numel(snapshotPlanes), numel(intersections));
end

% Require every plane field used by the image renderer, table, or UV-to-pixel
% conversion. Extra fields remain allowed for future metadata extensions.
requiredPlaneFields = { ...
    'p0', 'ex', 'ey', 'n', 'W', 'H', 'nRows', 'nCols', ...
    'image', 'timestamp', 'bone', 'snapshotName', ...
    'snapshotIndex', 'sequenceIndex', 'packetIndex'};
if ~all(isfield(snapshotPlanes, requiredPlaneFields))
    error('displaySnapshotIntersectionBrowser:MissingPlaneFields', ...
        'snapshotPlanes is missing one or more required geometry or metadata fields.');
end

% Require the result fields used for counts, overlays, 3D synchronization,
% and clear status reporting in the table.
requiredIntersectionFields = { ...
    'pixelList', 'segments3D', 'segmentsUV', ...
    'probeFacingSegments3D', 'probeFacingPixels', 'status'};
if ~all(isfield(intersections, requiredIntersectionFields))
    error('displaySnapshotIntersectionBrowser:MissingIntersectionFields', ...
        'intersections is missing one or more required display fields.');
end

% Validate the 3D axes at browser creation. The callbacks will check it again
% later because users are allowed to close the original 3D figure first.
if ~isgraphics(ax3D, 'axes')
    error('displaySnapshotIntersectionBrowser:Invalid3DAxes', ...
        'ax3D must be a valid MATLAB axes handle.');
end

%% BUILD THE RESULTS TABLE DATA

% Count aligned results once so every table column receives the same length.
nResults = numel(snapshotPlanes);

% Keep ResultIndex as an explicit column because the visible rows can move
% when users sort by any intersection count.
resultIndex = (1:nResults).';
boneCode = strings(nResults, 1);
snapshotName = strings(nResults, 1);
sequenceIndex = zeros(nResults, 1);
packetIndex = zeros(nResults, 1);
timestamp = zeros(nResults, 1);
rawSegmentCount = zeros(nResults, 1);
rawPixelCount = zeros(nResults, 1);
facingSegmentCount = zeros(nResults, 1);
facingPixelCount = zeros(nResults, 1);
resultStatus = strings(nResults, 1);

% Convert the aligned struct arrays into simple table values so sorting does
% not copy large image matrices or segment cell arrays into the UI control.
for resultIndexToRead = 1:nResults
    currentPlane = snapshotPlanes(resultIndexToRead);
    currentIntersection = intersections(resultIndexToRead);

    boneCode(resultIndexToRead) = string(currentPlane.bone);
    snapshotName(resultIndexToRead) = string(currentPlane.snapshotName);
    sequenceIndex(resultIndexToRead) = double(currentPlane.sequenceIndex);
    packetIndex(resultIndexToRead) = double(currentPlane.packetIndex);
    timestamp(resultIndexToRead) = double(currentPlane.timestamp);
    rawSegmentCount(resultIndexToRead) = numel(currentIntersection.segments3D);
    rawPixelCount(resultIndexToRead) = size(currentIntersection.pixelList, 1);
    facingSegmentCount(resultIndexToRead) = ...
        numel(currentIntersection.probeFacingSegments3D);
    facingPixelCount(resultIndexToRead) = ...
        size(currentIntersection.probeFacingPixels, 1);
    resultStatus(resultIndexToRead) = string(currentIntersection.status);
end

% Preserve acquisition order in the initial table. Column sorting remains a
% view operation because ResultIndex always points back to the original data.
resultsData = table( ...
    resultIndex, boneCode, snapshotName, sequenceIndex, packetIndex, ...
    timestamp, rawSegmentCount, rawPixelCount, facingSegmentCount, ...
    facingPixelCount, resultStatus, ...
    'VariableNames', { ...
        'ResultIndex', 'Bone', 'SnapshotGroup', 'Sequence', 'Packet', ...
        'Timestamp', 'RawSegments', 'RawPixels', 'FacingSegments', ...
        'FacingPixels', 'Status'});

%% CREATE THE RESULTS-FIRST USER INTERFACE

% Use one responsive figure so the table stays readable while the selected
% image receives most of the remaining screen area.
figBrowser = uifigure( ...
    'Name', 'Snapshot Mesh-Plane Intersection Browser', ...
    'Position', [80, 80, 1500, 850], ...
    'CloseRequestFcn', @closeBrowser);

% Reserve the full left side for the table and use the lower-right area for
% selected-result metadata and the fixed overlay color key.
mainGrid = uigridlayout(figBrowser, [2, 2], ...
    'RowHeight', {'1x', 115}, ...
    'ColumnWidth', {650, '1x'}, ...
    'Padding', [10, 10, 10, 10], ...
    'RowSpacing', 8, ...
    'ColumnSpacing', 10);

% Keep all rows visible and make every column sortable. Row selection makes
% it clear that all columns describe one shared snapshot result.
resultsTable = uitable(mainGrid, ...
    'Data', resultsData, ...
    'ColumnName', { ...
        'Index', 'Bone', 'Snapshot group', 'Sequence', 'Packet', ...
        'Timestamp', 'Raw segments', 'Raw pixels', 'Facing segments', ...
        'Facing pixels', 'Status'}, ...
    'ColumnWidth', {65, 50, 135, 70, 60, 90, 90, 75, 100, 90, 'auto'}, ...
    'ColumnEditable', false(1, width(resultsData)), ...
    'ColumnSortable', true(1, width(resultsData)), ...
    'SelectionType', 'row', ...
    'Multiselect', 'off');
resultsTable.Layout.Row = [1, 2];
resultsTable.Layout.Column = 1;

% Create one large image axes because only the selected row should be drawn.
imageAxes = uiaxes(mainGrid);
imageAxes.Layout.Row = 1;
imageAxes.Layout.Column = 2;
xlabel(imageAxes, 'Column');
ylabel(imageAxes, 'Row');
box(imageAxes, 'on');
colormap(imageAxes, gray(256));

% Place result details and the color explanation below the image so users do
% not need to infer overlay meaning from marker shapes alone.
infoPanel = uipanel(mainGrid, 'Title', 'Selected snapshot');
infoPanel.Layout.Row = 2;
infoPanel.Layout.Column = 2;
infoGrid = uigridlayout(infoPanel, [2, 1], ...
    'RowHeight', {'1x', '1x'}, ...
    'Padding', [8, 4, 8, 4], ...
    'RowSpacing', 2);

% This label changes with every selection and reports both provenance and
% result counts, including an explanation for skipped unknown bone groups.
statusLabel = uilabel(infoGrid, ...
    'Text', 'Select a snapshot result.', ...
    'FontWeight', 'bold', ...
    'WordWrap', 'on');
statusLabel.Layout.Row = 1;

% Keep the overlay key fixed because the same colors are used for every row.
overlayLegendLabel = uilabel(infoGrid, ...
    'Text', ['Red line: full UV intersection   |   ' ...
        'Yellow dot: full rasterized hit   |   ' ...
        'Green circle: probe-facing hit'], ...
    'WordWrap', 'on');
overlayLegendLabel.Layout.Row = 2;

%% CONNECT TABLE SELECTION TO THE TWO DISPLAYS

% Show a readable empty state instead of attempting to select a row that does
% not exist when every packet was rejected by the tracking checks.
if nResults == 0
    resultsTable.Enable = 'off';
    axis(imageAxes, 'off');
    text(imageAxes, 0.5, 0.5, ...
        'No valid tracked snapshots are available for intersection display.', ...
        'Units', 'normalized', ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle', ...
        'Interpreter', 'none');
    statusLabel.Text = 'No valid tracked snapshots were collected.';
    return;
end

% Select and render the first acquisition without changing the requested
% acquisition-order default. Later sorting is resolved through DisplayData.
resultsTable.Selection = 1;
resultsTable.SelectionChangedFcn = @handleSelectionChanged;
renderSnapshot(resultIndex(1));

    function handleSelectionChanged(~, eventData)
        %HANDLESELECTIONCHANGED Render the snapshot represented by a selected row.
        % This callback is needed because table sorting changes visible row
        % positions. It reads ResultIndex from DisplayData so the image and
        % intersection always remain paired after sorting.
        %
        % Inputs:
        %   ~         : Unused source table handle supplied by MATLAB.
        %   eventData : Table selection event containing selected display rows.
        %
        % Outputs:
        %   None. The callback updates the 2D axes, metadata, and 3D axes.

        % Ignore deselection events because there is no replacement result to draw.
        if isempty(eventData.Selection)
            return;
        end

        % Use the first row defensively even though Multiselect is disabled.
        selectedDisplayRow = eventData.Selection(1);
        displayedResults = resultsTable.DisplayData;

        % Stop if a stale UI event refers to a row outside the latest sorted view.
        if selectedDisplayRow < 1 || selectedDisplayRow > height(displayedResults)
            return;
        end

        % Recover the immutable acquisition index from the selected visible row.
        selectedResultIndex = displayedResults.ResultIndex(selectedDisplayRow);
        renderSnapshot(selectedResultIndex);
    end

    function renderSnapshot(selectedResultIndex)
        %RENDERSNAPSHOT Draw one result in 2D and synchronize its 3D highlight.
        % This renderer keeps heavy image and geometry arrays outside the
        % table. It is needed so row changes redraw only one snapshot instead
        % of creating hundreds of axes and graphics objects.
        %
        % Input:
        %   selectedResultIndex : Stable index into snapshotPlanes and
        %                         intersections for the selected acquisition.
        %
        % Outputs:
        %   None. The function updates existing UI and 3D graphics objects.

        % Read the aligned records once so all display elements use one acquisition.
        currentPlane = snapshotPlanes(selectedResultIndex);
        currentIntersection = intersections(selectedResultIndex);

        % Replace the previous 2D content before drawing the selected raw image.
        cla(imageAxes);
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
        hold(imageAxes, 'off');

        % Use two title lines so long snapshot group names do not crowd the axes.
        title(imageAxes, { ...
            sprintf('%s | Bone %s', ...
                char(string(currentPlane.snapshotName)), ...
                char(string(currentPlane.bone))), ...
            sprintf('Acquisition %d | Sequence %d | Packet %d | t = %.3f', ...
                selectedResultIndex, currentPlane.sequenceIndex, ...
                currentPlane.packetIndex, double(currentPlane.timestamp))}, ...
            'Interpreter', 'none');
        xlabel(imageAxes, 'Column');
        ylabel(imageAxes, 'Row');

        % Report the exact counts shown in the selected table row plus the
        % computation status for successful, empty, or skipped results.
        statusLabel.Text = sprintf([ ...
            'Index %d | %s | Sequence %d, Packet %d | ' ...
            'Raw: %d segment(s), %d pixel(s) | ' ...
            'Probe-facing: %d segment(s), %d pixel(s) | Status: %s'], ...
            selectedResultIndex, char(string(currentPlane.snapshotName)), ...
            currentPlane.sequenceIndex, currentPlane.packetIndex, ...
            numel(currentIntersection.segments3D), ...
            size(currentIntersection.pixelList, 1), ...
            numel(currentIntersection.probeFacingSegments3D), ...
            size(currentIntersection.probeFacingPixels, 1), ...
            char(string(currentIntersection.status)));

        % Skip 3D updates when the original figure was closed after the browser opened.
        if ~isgraphics(ax3D, 'axes')
            return;
        end

        % Remove the old selected result so repeated navigation never stacks
        % stale 3D intersection curves.
        delete(findobj(ax3D, 'Tag', 'plot_snapshot_mesh_plane_intersection'));

        % Preserve the axes hold state because adding a line to axes with hold
        % disabled would otherwise replace the complete 3D overview scene.
        previousHoldState = ishold(ax3D);
        hold(ax3D, 'on');

        % Match the example by drawing only probe-facing 3D segments in red.
        for segmentIndex = 1:numel(currentIntersection.probeFacingSegments3D)
            currentSegment3D = ...
                currentIntersection.probeFacingSegments3D{segmentIndex};
            plot3(ax3D, ...
                currentSegment3D(:, 1), ...
                currentSegment3D(:, 2), ...
                currentSegment3D(:, 3), ...
                'r-', ...
                'LineWidth', 2, ...
                'Tag', 'plot_snapshot_mesh_plane_intersection');
        end

        % Restore the caller's graphics behavior after the selected lines exist.
        if ~previousHoldState
            hold(ax3D, 'off');
        end
        drawnow limitrate;
    end

    function closeBrowser(sourceFigure, ~)
        %CLOSEBROWSER Remove the selected 3D overlay and close the browser.
        % The cleanup is needed so closing the inspection UI does not leave a
        % red curve in the independent 3D overview figure.
        %
        % Inputs:
        %   sourceFigure : Browser uifigure supplied by its CloseRequestFcn.
        %   ~            : Unused close event supplied by MATLAB.
        %
        % Outputs:
        %   None. The function deletes tagged highlights and the browser figure.

        % Delete the browser-owned 3D lines only when the original axes still exists.
        if isgraphics(ax3D, 'axes')
            delete(findobj(ax3D, ...
                'Tag', 'plot_snapshot_mesh_plane_intersection'));
        end

        % Finish the normal close operation after associated graphics are clean.
        delete(sourceFigure);
    end

end
