function figBrowser = displaySnapshotIntersectionBrowser(snapshotPlanes, intersections, boneMeshesRefByCode)
%DISPLAYSNAPSHOTINTERSECTIONBROWSER Browse precomputed snapshot intersections.
% This display-only function builds a results-first browser so many
% ultrasound snapshots can be inspected without drawing every 2D image at
% once. Selecting a table row updates one large 2D overlay and rebuilds a
% matching bone, image plane, and intersection in the browser's own 3D axes.
%
% Inputs:
%   snapshotPlanes : Struct array containing finite image-plane geometry,
%                    source images, timestamps, bone codes, and snapshot
%                    indices. Its order defines the stable acquisition index.
%   intersections  : Struct array of precomputed raw and probe-facing
%                    mesh-plane intersection results. It must have one entry
%                    for every entry in snapshotPlanes.
%   boneMeshesRefByCode : Scalar struct whose fields are bone codes such as
%                         F and T. Each value is a reference-frame mesh struct
%                         with exact fields V for vertices and F for faces.
%
% Output:
%   figBrowser      : Handle to the new uifigure that contains the sortable
%                    results table, selected 2D image, and selected 3D scene.

%% VALIDATE THE DISPLAY INPUTS

% Require the complete public interface so a missing mesh lookup does not
% silently disable the selected 3D anatomy display.
if nargin ~= 3
    error('displaySnapshotIntersectionBrowser:InvalidInputCount', ...
        'Expected snapshotPlanes, intersections, and boneMeshesRefByCode.');
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
    'Multiselect', 'off', ...
    'Tag', 'snapshot_intersection_results_table');
resultsTable.Layout.Row = 1;
resultsTable.Layout.Column = 1;

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
    resultsTable.Enable = 'off';
    axis(imageAxes, 'off');
    text(imageAxes, 0.5, 0.5, ...
        'No valid tracked snapshots are available for intersection display.', ...
        'Units', 'normalized', ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle', ...
        'Interpreter', 'none');

    % Give the 3D column its own empty message so the complete layout remains
    % understandable even when no tracked plane can be selected.
    axis(sceneAxes, 'off');
    text(sceneAxes, 0.5, 0.5, ...
        'No selected 3D scene is available.', ...
        'Units', 'normalized', ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle', ...
        'Interpreter', 'none');
    return;
end

% Select and render the first acquisition without changing the requested
% acquisition-order default. Later sorting is resolved through DisplayData.
resultsTable.Selection = 1;
resultsTable.SelectionChangedFcn = @handleSelectionChanged;
renderSnapshot(resultIndex(1));

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

        % End a stale drag before replacing graphics or preserving its camera.
        stopSceneRotation([], []);

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
            sprintf('Acquisition %d | Sequence %d | Packet %d | t = %.3f', ...
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
        %CLOSEBROWSER Close the self-contained snapshot browser.
        % All selected 3D graphics now belong to sourceFigure, so deleting the
        % browser also cleans its mesh, plane, and intersection without ever
        % changing the separate static overview figure.
        %
        % Inputs:
        %   sourceFigure : Browser uifigure supplied by its CloseRequestFcn.
        %   ~            : Unused close event supplied by MATLAB.
        %
        % Outputs:
        %   None. The function deletes the browser and all child graphics.

        % Delete only the browser; ax1 is intentionally outside this ownership boundary.
        delete(sourceFigure);
    end

end
