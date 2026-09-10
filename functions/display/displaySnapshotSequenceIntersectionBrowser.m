function [figBrowser, validSnapshots, outputFilePath] = displaySnapshotSequenceIntersectionBrowser( ...
        snapshotPlanes, intersections, validBonePoses, varargin)
%DISPLAYSNAPSHOTSEQUENCEINTERSECTIONBROWSER Browse static or kinematic intersections.
% This function extends the working snapshot browser with row-specific bone
% poses for a kinematic ultrasound recording. Static pose modes are forwarded
% to displaySnapshotIntersectionBrowser after their one mesh is reconstructed,
% so their established display and review behavior stays unchanged.
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
%   validBonePoses : Bone-pose preparation output. Each bone stores its CT
%                    mesh once and either one static pose or one pose per row.
%
% Name-Value Input:
%   'Mode'          : Browser behavior, specified as 'display' or 'review'.
%                     The default 'display' mode is non-blocking and keeps
%                     the original read-only behavior. Review mode waits for
%                     the first successful export or window cancellation.
%   'OutputDirectory' : Existing directory initially shown by the review
%                       export dialog. The default empty value lets MATLAB
%                       choose the dialog's initial directory.
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
    error('displaySnapshotSequenceIntersectionBrowser:InvalidInputCount', ...
        ['Expected snapshotPlanes, intersections, validBonePoses, ' ...
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
    error('displaySnapshotSequenceIntersectionBrowser:InvalidMode', ...
        'Mode must be either ''display'' or ''review''.');
end
isReviewMode = browserMode == "review";

% Keep an empty directory as MATLAB's normal dialog behavior, but require a
% supplied directory to exist so the export dialog never starts at a bad path.
outputDirectory = char(string(browserInputParser.Results.OutputDirectory));
if ~isempty(outputDirectory) && ~isfolder(outputDirectory)
    error('displaySnapshotSequenceIntersectionBrowser:OutputDirectoryNotFound', ...
        'OutputDirectory was not found: %s', outputDirectory);
end

% The pose handling mode decides whether this call needs the sequence-aware
% browser or can reuse the proven static browser unchanged.
if ~isstruct(validBonePoses) || ~isscalar(validBonePoses) || ...
        ~isfield(validBonePoses, 'poseHandlingMode') || ...
        ~isfield(validBonePoses, 'bonePoses')
    error('displaySnapshotSequenceIntersectionBrowser:InvalidBonePoses', ...
        'validBonePoses must contain poseHandlingMode and bonePoses.');
end
if ~((ischar(validBonePoses.poseHandlingMode) && ...
        isrow(validBonePoses.poseHandlingMode)) || ...
        (isstring(validBonePoses.poseHandlingMode) && ...
        isscalar(validBonePoses.poseHandlingMode)))
    error('displaySnapshotSequenceIntersectionBrowser:InvalidPoseHandlingMode', ...
        'poseHandlingMode must be one text scalar.');
end
poseHandlingMode = string(validBonePoses.poseHandlingMode);
validPoseHandlingModes = ["average", "first", "last", "perDataRow"];
if ~any(poseHandlingMode == validPoseHandlingModes)
    error('displaySnapshotSequenceIntersectionBrowser:InvalidPoseHandlingMode', ...
        'poseHandlingMode must be average, first, last, or perDataRow.');
end
isPerDataRowMode = poseHandlingMode == "perDataRow";

% Validate the compact pose container before either browser creates a GUI.
% The mesh and anatomical transform belong to the bone, while each data
% record supplies the CT-to-reference transform used for display.
requiredBonePoseFields = {'bone', 'meshCT', 'T_bone_CT', 'data'};
requiredPoseDataFields = { ...
    'snapshotIndex', 'sequenceIndex', 'rigidBodyRowIndex', ...
    'isValid', 'status', 'T_CT_ref'};
if ~isstruct(validBonePoses.bonePoses) || ...
        (~isempty(validBonePoses.bonePoses) && ...
        ~isvector(validBonePoses.bonePoses)) || ...
        ~all(isfield(validBonePoses.bonePoses, requiredBonePoseFields))
    error('displaySnapshotSequenceIntersectionBrowser:MissingBonePoseFields', ...
        'Every bone pose must contain bone, meshCT, T_bone_CT, and data.');
end

bonePoseCodes = strings(1, numel(validBonePoses.bonePoses));
for boneIndex = 1:numel(validBonePoses.bonePoses)
    currentBonePose = validBonePoses.bonePoses(boneIndex);
    currentBoneCode = string(currentBonePose.bone);
    if ~isscalar(currentBoneCode) || ismissing(currentBoneCode) || ...
            strlength(currentBoneCode) == 0 || ...
            ~isvarname(char(currentBoneCode))
        error('displaySnapshotSequenceIntersectionBrowser:InvalidBoneCode', ...
            'Every bone must have one nonempty MATLAB-compatible text code.');
    end
    bonePoseCodes(boneIndex) = currentBoneCode;

    % A triangulation keeps connectivity and CT-frame vertices together. All
    % vertices must be finite before any row-specific transform is applied.
    if ~isa(currentBonePose.meshCT, 'triangulation') || ...
            any(~isfinite(currentBonePose.meshCT.Points), 'all')
        error('displaySnapshotSequenceIntersectionBrowser:InvalidCtMesh', ...
            'Bone %s meshCT must be a finite triangulation.', currentBoneCode);
    end
    if ~isProperRigidTransform(currentBonePose.T_bone_CT)
        error('displaySnapshotSequenceIntersectionBrowser:InvalidBoneTransform', ...
            'Bone %s T_bone_CT must be a finite proper 4-by-4 rigid transform.', ...
            currentBoneCode);
    end
    if ~isstruct(currentBonePose.data) || ...
            (~isempty(currentBonePose.data) && ...
            ~isvector(currentBonePose.data)) || ...
            ~all(isfield(currentBonePose.data, requiredPoseDataFields))
        error('displaySnapshotSequenceIntersectionBrowser:InvalidPoseData', ...
            'Bone %s data does not contain the required pose fields.', ...
            currentBoneCode);
    end

    % Invalid kinematic rows may contain NaN transforms and remain useful for
    % status reporting. Only records marked valid must contain a rigid transform.
    for poseIndex = 1:numel(currentBonePose.data)
        currentPoseData = currentBonePose.data(poseIndex);
        if ~islogical(currentPoseData.isValid) || ...
                ~isscalar(currentPoseData.isValid)
            error('displaySnapshotSequenceIntersectionBrowser:InvalidPoseValidity', ...
                'Bone %s pose %d isValid must be one logical value.', ...
                currentBoneCode, poseIndex);
        end
        if ~((ischar(currentPoseData.status) && isrow(currentPoseData.status)) || ...
                (isstring(currentPoseData.status) && ...
                isscalar(currentPoseData.status)))
            error('displaySnapshotSequenceIntersectionBrowser:InvalidPoseStatus', ...
                'Bone %s pose %d status must be one text value.', ...
                currentBoneCode, poseIndex);
        end
        if currentPoseData.isValid && ...
                ~isProperRigidTransform(currentPoseData.T_CT_ref)
            error('displaySnapshotSequenceIntersectionBrowser:InvalidPoseTransform', ...
                ['Bone %s pose %d is marked valid, but T_CT_ref is not a ' ...
                'finite proper rigid transform.'], currentBoneCode, poseIndex);
        end

        % Kinematic lookup depends on three positive integer indices. Static
        % averaged records may intentionally keep zero-valued source indices.
        if isPerDataRowMode
            poseIdentity = double([ ...
                currentPoseData.snapshotIndex, ...
                currentPoseData.sequenceIndex, ...
                currentPoseData.rigidBodyRowIndex]);
            if any(~isfinite(poseIdentity)) || any(poseIdentity < 1) || ...
                    any(poseIdentity ~= fix(poseIdentity))
                error('displaySnapshotSequenceIntersectionBrowser:InvalidPoseIdentity', ...
                    ['Bone %s pose %d must have positive integer snapshot, ' ...
                    'sequence, and rigid-body row indices.'], ...
                    currentBoneCode, poseIndex);
            end
        end
    end
end
if numel(unique(bonePoseCodes)) ~= numel(bonePoseCodes)
    error('displaySnapshotSequenceIntersectionBrowser:DuplicateBoneCode', ...
        'validBonePoses must contain only one entry for each bone code.');
end

% Reconstruct one reference-frame mesh per bone, then delegate static modes
% to the existing browser. This is the simplest way to guarantee that table,
% camera, review, and export behavior stays identical for static data.
if ~isPerDataRowMode
    boneMeshesRefByCode = struct();
    for boneIndex = 1:numel(validBonePoses.bonePoses)
        currentBonePose = validBonePoses.bonePoses(boneIndex);
        if numel(currentBonePose.data) ~= 1 || ...
                ~currentBonePose.data.isValid
            error('displaySnapshotSequenceIntersectionBrowser:InvalidStaticBonePose', ...
                'Every static bone must contain one valid pose and one CT mesh.');
        end
        boneCode = char(string(currentBonePose.bone));
        bonePointsRef = applyRigidTransform( ...
            currentBonePose.meshCT.Points, currentBonePose.data.T_CT_ref);
        boneMeshesRefByCode.(boneCode) = struct( ...
            'V', bonePointsRef, ...
            'F', currentBonePose.meshCT.ConnectivityList);
    end
    [figBrowser, validSnapshots, outputFilePath] = ...
        displaySnapshotIntersectionBrowser( ...
            snapshotPlanes, intersections, boneMeshesRefByCode, ...
            'Mode', browserMode, ...
            'OutputDirectory', string(outputDirectory), ...
            'ValidBonePoses', validBonePoses);
    return;
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
    error('displaySnapshotSequenceIntersectionBrowser:InputSizeMismatch', ...
        ['snapshotPlanes contains %d group(s), but intersections contains ' ...
        '%d. The grouped arrays must stay aligned.'], ...
        numel(snapshotPlanes), numel(intersections));
end

% Reject the old flat input contract by requiring the shared group wrapper.
% Extra outer fields remain allowed for later snapshot metadata extensions.
requiredGroupFields = {'name', 'bone', 'path', 'data'};
if ~all(isfield(snapshotPlanes, requiredGroupFields)) || ...
        ~all(isfield(intersections, requiredGroupFields))
    error('displaySnapshotSequenceIntersectionBrowser:MissingGroupFields', ...
        ['snapshotPlanes and intersections must be source-directory groups ' ...
        'with name, bone, path, and data fields. Flat arrays are unsupported.']);
end

% List every child field used by the table and renderers before validating
% each group's data. Empty groups keep these fields through their templates.
requiredPlaneFields = { ...
    'p0', 'ex', 'ey', 'n', 'W', 'H', 'nRows', 'nCols', ...
    'image', 'timestamp', 'bone', 'snapshotName', ...
    'snapshotIndex', 'sequenceIndex', 'packetIndex', ...
    'rigidBodyRowIndex', 'isValid', 'status'};

% Require the result fields used for counts, overlays, 3D synchronization,
% and clear status reporting in the table.
requiredIntersectionFields = { ...
    'pixelList', 'segments3D', 'segmentsUV', ...
    'probeFacingSegments3D', 'probeFacingPixels', 'isValid', 'status'};

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
            error('displaySnapshotSequenceIntersectionBrowser:InvalidGroupMetadata', ...
                'Group %d metadata fields name, bone, and path must be text scalars.', ...
                groupIndex);
        end
    end

    % Matching metadata prevents tabs from pairing arrays that merely happen
    % to have the same number of records.
    if string(currentPlaneGroup.name) ~= string(currentIntersectionGroup.name) || ...
            string(currentPlaneGroup.bone) ~= string(currentIntersectionGroup.bone) || ...
            string(currentPlaneGroup.path) ~= string(currentIntersectionGroup.path)
        error('displaySnapshotSequenceIntersectionBrowser:GroupMetadataMismatch', ...
            'snapshotPlanes and intersections metadata differs for group %d.', ...
            groupIndex);
    end
    if nnz(bonePoseCodes == string(currentPlaneGroup.bone)) ~= 1
        error('displaySnapshotSequenceIntersectionBrowser:UnknownGroupBone', ...
            ['Source group %d uses bone code %s, but validBonePoses does not ' ...
            'contain exactly one matching bone.'], ...
            groupIndex, string(currentPlaneGroup.bone));
    end

    currentPlanes = currentPlaneGroup.data;
    currentIntersections = currentIntersectionGroup.data;
    if ~isstruct(currentPlanes) || (~isempty(currentPlanes) && ~isvector(currentPlanes))
        error('displaySnapshotSequenceIntersectionBrowser:InvalidPlaneGroupData', ...
            'snapshotPlanes(%d).data must be a struct vector.', groupIndex);
    end
    if ~isstruct(currentIntersections) || ...
            (~isempty(currentIntersections) && ~isvector(currentIntersections))
        error('displaySnapshotSequenceIntersectionBrowser:InvalidIntersectionGroupData', ...
            'intersections(%d).data must be a struct vector.', groupIndex);
    end
    if numel(currentPlanes) ~= numel(currentIntersections)
        error('displaySnapshotSequenceIntersectionBrowser:GroupDataSizeMismatch', ...
            ['Group %d contains %d plane(s) but %d intersection result(s). ' ...
            'Local data arrays must stay aligned.'], ...
            groupIndex, numel(currentPlanes), numel(currentIntersections));
    end
    if ~all(isfield(currentPlanes, requiredPlaneFields))
        error('displaySnapshotSequenceIntersectionBrowser:MissingPlaneFields', ...
            'snapshotPlanes(%d).data is missing required fields.', groupIndex);
    end
    if ~all(isfield(currentIntersections, requiredIntersectionFields))
        error('displaySnapshotSequenceIntersectionBrowser:MissingIntersectionFields', ...
            'intersections(%d).data is missing required fields.', groupIndex);
    end

    % Confirm repeated plane metadata still points to its owning outer group.
    % This catches accidental regrouping before an incorrect image is shown.
    for localResultIndex = 1:numel(currentPlanes)
        currentPlane = currentPlanes(localResultIndex);
        currentIntersection = currentIntersections(localResultIndex);
        if string(currentPlane.snapshotName) ~= string(currentPlaneGroup.name) || ...
                string(currentPlane.bone) ~= string(currentPlaneGroup.bone) || ...
                double(currentPlane.snapshotIndex) ~= groupIndex
            error('displaySnapshotSequenceIntersectionBrowser:PlaneGroupMetadataMismatch', ...
                ['snapshotPlanes(%d).data(%d) metadata does not identify its ' ...
                'owning source-directory group.'], ...
                groupIndex, localResultIndex);
        end

        % Renderability uses one logical flag from each aligned record. Require
        % those exact scalar values now so a malformed row cannot fail later in
        % a GUI callback after the browser has already opened.
        if ~islogical(currentPlane.isValid) || ...
                ~isscalar(currentPlane.isValid) || ...
                ~islogical(currentIntersection.isValid) || ...
                ~isscalar(currentIntersection.isValid)
            error('displaySnapshotSequenceIntersectionBrowser:InvalidRowValidity', ...
                ['Plane and intersection isValid values must be scalar logicals ' ...
                'in group %d, row %d.'], groupIndex, localResultIndex);
        end

        % The row identity is used as the shared kinematic time value. A
        % positive integer keeps time-set synchronization unambiguous.
        if ~isnumeric(currentPlane.rigidBodyRowIndex) || ...
                ~isscalar(currentPlane.rigidBodyRowIndex) || ...
                ~isfinite(currentPlane.rigidBodyRowIndex) || ...
                currentPlane.rigidBodyRowIndex < 1 || ...
                currentPlane.rigidBodyRowIndex ~= ...
                    fix(currentPlane.rigidBodyRowIndex)
            error('displaySnapshotSequenceIntersectionBrowser:InvalidTimeRow', ...
                ['rigidBodyRowIndex must be a positive integer in group %d, ' ...
                'row %d.'], groupIndex, localResultIndex);
        end
    end
end

%% BUILD THE GROUPED RESULTS TABLE DATA

% Keep one lightweight table and one review-decision vector per source
% directory. Large image matrices and intersection geometry stay outside the
% UI controls and are read only when a row is selected.
nResultsByGroup = zeros(1, nGroups);
resultsDataByGroup = cell(1, nGroups);
reviewDecisions = cell(1, nGroups);
renderableByGroup = cell(1, nGroups);

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
    timeRow = zeros(currentResultCount, 1);
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
        timeRow(localResultIndex) = double(currentPlane.rigidBodyRowIndex);
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
        resultIndex, boneCode, snapshotName, sequenceIndex, packetIndex, timeRow, ...
        timestamp, rawSegmentCount, rawPixelCount, facingSegmentCount, ...
        facingPixelCount, resultStatus, ...
        'VariableNames', { ...
            'ResultIndex', 'Bone', 'SnapshotGroup', 'Sequence', 'Packet', 'TimeRow', ...
            'Timestamp', 'RawSegments', 'RawPixels', 'FacingSegments', ...
            'FacingPixels', 'Status'});

    % Keep review decisions separate from sortable table rows. Each logical
    % value uses the group's stable local ResultIndex.
    reviewDecisions{groupIndex} = false(currentResultCount, 1);
    renderableByGroup{groupIndex} = false(currentResultCount, 1);
    for localResultIndex = 1:currentResultCount
        currentPlane = currentPlanes(localResultIndex);
        currentIntersection = currentIntersections(localResultIndex);
        [matchingPose, poseWasFound] = findMatchingPoseData(currentPlane);
        renderableByGroup{groupIndex}(localResultIndex) = ...
            currentPlane.isValid && currentIntersection.isValid && ...
            poseWasFound && matchingPose.isValid;

        % Show the first reason that prevents rendering. This makes blocked
        % rows understandable even though they remain visible in the table.
        if ~currentPlane.isValid
            resultStatus(localResultIndex) = string(currentPlane.status);
        elseif ~poseWasFound
            resultStatus(localResultIndex) = ...
                "Unavailable: no unique matching bone pose.";
        elseif ~matchingPose.isValid
            resultStatus(localResultIndex) = string(matchingPose.status);
        elseif ~currentIntersection.isValid
            resultStatus(localResultIndex) = ...
                string(currentIntersection.status);
        end
    end
    currentResultsData.Status = resultStatus;
    if isReviewMode
        currentResultsData = addvars( ...
            currentResultsData, reviewDecisions{groupIndex}, ...
            'Before', 'ResultIndex', ...
            'NewVariableNames', 'Valid');
    end
    resultsDataByGroup{groupIndex} = currentResultsData;
end

lastSelectedResultIndexByGroup = zeros(1, nGroups);

% A review decision in kinematic mode belongs to a complete time set. Build
% that set once so checkbox callbacks only need a small, readable lookup.
timeRowsByGroup = cell(1, nGroups);
for groupIndex = 1:nGroups
    if nResultsByGroup(groupIndex) > 0
        timeRowsByGroup{groupIndex} = ...
            [snapshotPlanes(groupIndex).data.rigidBodyRowIndex];
    end
end
allTimeRows = [timeRowsByGroup{:}];
allTimeRows = unique(allTimeRows, 'sorted');
reviewableTimeRows = false(size(allTimeRows));
nonemptyGroupIndices = find(nResultsByGroup > 0);
for timeSetIndex = 1:numel(allTimeRows)
    currentTimeRow = allTimeRows(timeSetIndex);
    isCompleteTimeSet = true;
    for groupIndex = nonemptyGroupIndices
        groupTimeRows = [snapshotPlanes(groupIndex).data.rigidBodyRowIndex];
        matchingResultIndices = find(groupTimeRows == currentTimeRow);
        if numel(matchingResultIndices) ~= 1 || ...
                ~renderableByGroup{groupIndex}(matchingResultIndices)
            isCompleteTimeSet = false;
            break;
        end
    end
    reviewableTimeRows(timeSetIndex) = isCompleteTimeSet;
end

%% CREATE THE RESULTS-FIRST USER INTERFACE

% Use a wide responsive figure so the table, 2D image, and 3D scene can remain
% readable beside each other on a standard desktop display.
figBrowser = uifigure( ...
    'Name', 'Snapshot Sequence Mesh-Plane Intersection Browser', ...
    'Position', [20, 60, 1880, 880], ...
    'CloseRequestFcn', @closeBrowser);

% Place the three primary views from left to right as requested. The table
% keeps a fixed width while both plot columns share the remaining space.
mainGrid = uigridlayout(figBrowser, [1, 3], ...
    'ColumnWidth', {650, '1x', '1x'}, ...
    'Padding', [10, 10, 10, 10], ...
    'ColumnSpacing', 10);

% Enclose each primary view in a titled panel so users can quickly see where
% the data controls, 2D image, and 3D scene begin and end.
dataPanel = uipanel(mainGrid, ...
    'Title', 'Ultrasound Data', ...
    'FontWeight', 'bold', ...
    'BorderType', 'line', ...
    'Tag', 'snapshot_intersection_data_panel');
dataPanel.Layout.Row = 1;
dataPanel.Layout.Column = 1;

imagePanel = uipanel(mainGrid, ...
    'Title', 'Ultrasound Image (Intersection in 2D Space)', ...
    'FontWeight', 'bold', ...
    'BorderType', 'line', ...
    'Tag', 'snapshot_intersection_image_panel');
imagePanel.Layout.Row = 1;
imagePanel.Layout.Column = 2;

scenePanel = uipanel(mainGrid, ...
    'Title', 'Bone Mesh (Intersection in 3D Space)', ...
    'FontWeight', 'bold', ...
    'BorderType', 'line', ...
    'Tag', 'snapshot_intersection_3d_panel');
scenePanel.Layout.Row = 1;
scenePanel.Layout.Column = 3;

% Use a one-cell grid inside each panel so its content stays responsive and
% leaves a small, even gap between the panel border and the child controls.
dataPanelGrid = uigridlayout(dataPanel, [1, 1], ...
    'Padding', [8, 8, 8, 8]);
imagePanelGrid = uigridlayout(imagePanel, [1, 1], ...
    'Padding', [8, 8, 8, 8]);
scenePanelGrid = uigridlayout(scenePanel, [1, 1], ...
    'Padding', [8, 8, 8, 8]);

% Define empty handles before the review-only branch so the later empty-data
% state can disable controls without needing separate browser implementations.
selectAllButton = gobjects(0);
clearAllButton = gobjects(0);
selectionCountLabel = gobjects(0);
exportSelectedButton = gobjects(0);

% Review mode uses a small second row under the tabbed tables. Display mode
% places the same tab group directly in the data panel grid.
if isReviewMode
    tableGrid = uigridlayout(dataPanelGrid, [2, 1], ...
        'RowHeight', {'1x', 34}, ...
        'Padding', [0, 0, 0, 0], ...
        'RowSpacing', 6);
    tableGrid.Layout.Row = 1;
    tableGrid.Layout.Column = 1;
    resultsTableParent = tableGrid;
else
    resultsTableParent = dataPanelGrid;
end

% Configure column labels and edit permissions once because every directory
% tab exposes the same record fields. Only Valid can be edited in review mode.
if isReviewMode
    resultsColumnNames = { ...
        'Valid', 'Index', 'Bone', 'Snapshot group', 'Sequence', 'Packet', 'Time row', ...
        'Timestamp', 'Raw segments', 'Raw pixels', 'Facing segments', ...
        'Facing pixels', 'Status'};
    resultsColumnWidths = {55, 65, 50, 135, 70, 60, 70, 90, 90, 75, 100, 90, 'auto'};
    resultsColumnEditable = [true, false(1, 12)];
else
    resultsColumnNames = { ...
        'Index', 'Bone', 'Snapshot group', 'Sequence', 'Packet', 'Time row', ...
        'Timestamp', 'Raw segments', 'Raw pixels', 'Facing segments', ...
        'Facing pixels', 'Status'};
    resultsColumnWidths = {65, 50, 135, 70, 60, 70, 90, 90, 75, 100, 90, 'auto'};
    resultsColumnEditable = false(1, 12);
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
        'Text', sprintf('Selected time frames: 0 / %d available (%d total)', ...
            nnz(reviewableTimeRows), numel(allTimeRows)), ...
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

% Create one large image axes inside the 2D panel because only the selected
% row should be drawn at a time.
imageAxes = uiaxes(imagePanelGrid, 'Tag', 'snapshot_intersection_image_axes');
imageAxes.Layout.Row = 1;
imageAxes.Layout.Column = 1;
xlabel(imageAxes, 'Column');
ylabel(imageAxes, 'Row');
box(imageAxes, 'on');
colormap(imageAxes, gray(256));

% Create a separate 3D axes inside the mesh panel. The static ax1 overview is
% intentionally not passed into or modified by this function.
sceneAxes = uiaxes(scenePanelGrid, 'Tag', 'snapshot_intersection_3d_axes');
sceneAxes.Layout.Row = 1;
sceneAxes.Layout.Column = 1;
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

% Start only from a row that has a valid plane, matching bone pose, and
% computed intersection. Invalid kinematic rows remain in the tables, but are
% deliberately not allowed to replace the current scene.
nRenderableResults = sum(cellfun(@nnz, renderableByGroup));
if nRenderableResults == 0
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
    % Find the first renderable acquisition without assuming row one is valid.
    firstRenderableGroupIndex = find(cellfun(@any, renderableByGroup), 1);
    firstRenderableResultIndex = find( ...
        renderableByGroup{firstRenderableGroupIndex}, 1);
    resultsTabGroup.SelectedTab = resultsTabs(firstRenderableGroupIndex);
    resultsTables(firstRenderableGroupIndex).Selection = ...
        firstRenderableResultIndex;
    lastSelectedResultIndexByGroup(firstRenderableGroupIndex) = ...
        firstRenderableResultIndex;
    renderSnapshot(firstRenderableGroupIndex, firstRenderableResultIndex);
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

        % Resolve the acquisition time from the permanent result identity.
        % Review decisions belong to a whole time set, not to one sensor tab.
        editedResultIndex = currentTableData.ResultIndex(editedDataRow);
        editedTimeRow = snapshotPlanes(editedGroupIndex).data( ...
            editedResultIndex).rigidBodyRowIndex;
        editedTimeSetIndex = find(allTimeRows == editedTimeRow, 1);
        requestedDecision = logical(eventData.NewData);

        % A missing or invalid member makes the full synchronized set
        % unavailable. Restore all matching checkboxes to false immediately.
        if isempty(editedTimeSetIndex) || ...
                ~reviewableTimeRows(editedTimeSetIndex)
            requestedDecision = false;
        end
        for groupIndexToUpdate = nonemptyGroupIndices
            groupTimeRows = ...
                [snapshotPlanes(groupIndexToUpdate).data.rigidBodyRowIndex];
            matchingResultIndices = find(groupTimeRows == editedTimeRow);
            reviewDecisions{groupIndexToUpdate}(matchingResultIndices) = ...
                requestedDecision;
        end
        synchronizeValidColumn();
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
            groupTimeRows = ...
                [snapshotPlanes(groupIndexToUpdate).data.rigidBodyRowIndex];
            reviewDecisions{groupIndexToUpdate}(:) = false;
            for selectableTimeIndex = find(reviewableTimeRows)
                matchingResultIndices = find( ...
                    groupTimeRows == allTimeRows(selectableTimeIndex));
                reviewDecisions{groupIndexToUpdate}(matchingResultIndices) = true;
            end
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
            selectedTimeFrameCount = 0;
            for selectedTimeIndex = find(reviewableTimeRows)
                currentTimeRow = allTimeRows(selectedTimeIndex);
                firstGroupIndex = nonemptyGroupIndices(1);
                firstGroupTimeRows = ...
                    [snapshotPlanes(firstGroupIndex).data.rigidBodyRowIndex];
                firstGroupResultIndex = find( ...
                    firstGroupTimeRows == currentTimeRow, 1);
                if ~isempty(firstGroupResultIndex) && ...
                        reviewDecisions{firstGroupIndex}(firstGroupResultIndex)
                    selectedTimeFrameCount = selectedTimeFrameCount + 1;
                end
            end
            selectionCountLabel.Text = sprintf( ...
                'Selected time frames: %d / %d available (%d total)', ...
                selectedTimeFrameCount, nnz(reviewableTimeRows), ...
                numel(allTimeRows));
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
        if nResultsByGroup(selectedGroupIndex) == 0 || ...
                ~any(renderableByGroup{selectedGroupIndex})
            renderEmptyGroup(selectedGroupIndex);
            return;
        end

        % Use the group's previous stable local index, or its first acquisition
        % when the tab has not been visited before.
        selectedResultIndex = ...
            lastSelectedResultIndexByGroup(selectedGroupIndex);
        if selectedResultIndex < 1 || ...
                selectedResultIndex > nResultsByGroup(selectedGroupIndex) || ...
                ~renderableByGroup{selectedGroupIndex}(selectedResultIndex)
            selectedResultIndex = find( ...
                renderableByGroup{selectedGroupIndex}, 1);
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
                'No renderable sequence rows are available in "%s".', ...
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
                ['No time frames are selected. Check at least one Valid box ' ...
                'before exporting.'], ...
                'No time frames selected', ...
                'Icon', 'warning');
            return;
        end

        % Read approved time identities from one nonempty group. Checkbox edits
        % are synchronized, so the same time rows are selected in every group.
        % Keeping this list separate from table-record count makes the exported
        % review result describe kinematic time rather than the number of tabs.
        selectedTimeRows = [];
        firstGroupIndex = nonemptyGroupIndices(1);
        firstGroupTimeRows = ...
            [snapshotPlanes(firstGroupIndex).data.rigidBodyRowIndex];
        for exportTimeIndex = find(reviewableTimeRows)
            currentTimeRow = allTimeRows(exportTimeIndex);
            firstGroupResultIndex = find( ...
                firstGroupTimeRows == currentTimeRow, 1);
            if ~isempty(firstGroupResultIndex) && ...
                    reviewDecisions{firstGroupIndex}(firstGroupResultIndex)
                selectedTimeRows(end + 1) = currentTimeRow; %#ok<AGROW>
            end
        end
        selectedTimeFrameCount = numel(selectedTimeRows);

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
            'Export selected time frames', ...
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
        % Prepare a separate pose structure for export. The browser continues
        % using the original complete validBonePoses, so another export from the
        % same open browser can choose a different set of time frames.
        exportValidBonePoses = validBonePoses;
        for boneIndexToExport = 1:numel(validBonePoses.bonePoses)
            sourcePoseData = validBonePoses.bonePoses(boneIndexToExport).data;
            sourceGroupIndices = [sourcePoseData.snapshotIndex];
            sourceTimeRows = [sourcePoseData.rigidBodyRowIndex];

            % Selected data contains only approved group/time pairs. Logical
            % indexing keeps the original chronological order and all source
            % identifiers already stored in each pose record.
            selectedPoseMask = ...
                ismember(sourceGroupIndices, nonemptyGroupIndices) & ...
                ismember(sourceTimeRows, selectedTimeRows);
            exportValidBonePoses.bonePoses(boneIndexToExport).data = ...
                sourcePoseData(selectedPoseMask);

            % Keep row 1 separately as visualization context. Invalid row-1
            % records are intentionally preserved with their status metadata,
            % and row 1 is not added back to the approved data selection.
            baselinePoseMask = ...
                ismember(sourceGroupIndices, nonemptyGroupIndices) & ...
                sourceTimeRows == 1;
            exportValidBonePoses.bonePoses(boneIndexToExport).baselineData = ...
                sourcePoseData(baselinePoseMask);
        end

        outputFilePath = fullfile(selectedDirectory, selectedFileName);

        % Use -struct so the filtered pose container keeps the established
        % MAT-file variable name validBonePoses without replacing the browser's
        % complete in-memory input variable.
        try
            exportVariables = struct( ...
                'validSnapshots', validSnapshots, ...
                'validBonePoses', exportValidBonePoses);
            save(outputFilePath, '-struct', 'exportVariables', '-v7.3');
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
            sprintf(['Exported %d selected time frame(s) across %d table ' ...
                'record(s).\n\nSaved to:\n%s'], ...
                selectedTimeFrameCount, selectedResultCount, outputFilePath), ...
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
        if ~renderableByGroup{selectedGroupIndex}(selectedResultIndex)
            % Put the highlight back on the last valid row. The existing plots
            % remain untouched so an invalid record never replaces good data.
            previousResultIndex = ...
                lastSelectedResultIndexByGroup(selectedGroupIndex);
            previousDataRow = find( ...
                storedResults.ResultIndex == previousResultIndex, 1);
            if isempty(previousDataRow)
                sourceTable.Selection = [];
            else
                sourceTable.Selection = previousDataRow;
            end
            return;
        end
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
        % The rigid-body row is shown explicitly because that value is the
        % kinematic time identity shared by the tables and bone-pose records.
        title(imageAxes, { ...
            sprintf('%s | Bone %s', ...
                char(string(currentPlane.snapshotName)), ...
                char(string(currentPlane.bone))), ...
            sprintf('Data row %d | Sequence %d | Packet %d | timestamp = %.3f', ...
                currentPlane.rigidBodyRowIndex, currentPlane.sequenceIndex, ...
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

        % Find the exact current bone pose using acquisition identity stored in
        % the selected plane. The visible table row is deliberately not used,
        % because sorting can move that row without changing the underlying data.
        currentBoneCode = char(string(currentPlane.bone));
        [currentPoseData, currentPoseWasFound, currentBonePoseIndex] = ...
            findMatchingPoseData(currentPlane);
        if ~currentPoseWasFound || ~currentPoseData.isValid
            error('displaySnapshotSequenceIntersectionBrowser:PoseLookupFailed', ...
                ['The selected row passed renderability checks, but its bone ' ...
                'pose can no longer be found.']);
        end

        % Row 1 is the reference pose for this source recording. A direct if
        % block intentionally skips the baseline at row 1, where drawing two
        % identical transparent surfaces would create depth-buffer artifacts.
        baselineBoneMeshHandle = gobjects(0);
        baselineStatusMessage = '';
        if currentPlane.rigidBodyRowIndex > 1
            baselinePlane = currentPlane;
            baselinePlane.rigidBodyRowIndex = 1;
            [baselinePoseData, baselinePoseWasFound, baselineBonePoseIndex] = ...
                findMatchingPoseData(baselinePlane);

            % Do not replace a missing row-1 pose with another time row. The
            % baseline has a specific physical meaning, so omission is clearer
            % than displaying a different pose as if it were the reference.
            if baselinePoseWasFound && baselinePoseData.isValid
                baselineBonePose = validBonePoses.bonePoses( ...
                    baselineBonePoseIndex);
                baselineBonePointsRef = applyRigidTransform( ...
                    baselineBonePose.meshCT.Points, ...
                    baselinePoseData.T_CT_ref);
                baselineBoneMeshHandle = patch(sceneAxes, ...
                    'Faces', baselineBonePose.meshCT.ConnectivityList, ...
                    'Vertices', baselineBonePointsRef, ...
                    'FaceColor', [0.70, 0.84, 0.96], ...
                    'EdgeColor', 'none', ...
                    'FaceAlpha', 0.15, ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none', ...
                    'Tag', 'plot_browser_baseline_bone_mesh');
            else
                baselineStatusMessage = 'Baseline pose at data row 1 is unavailable.';
            end
        end

        % Reconstruct only the selected mesh. The original CT mesh remains
        % stored once in validBonePoses, while this temporary vertex array is
        % expressed in the same ref frame as the ultrasound image and segments.
        currentBonePose = validBonePoses.bonePoses(currentBonePoseIndex);
        currentBonePointsRef = applyRigidTransform( ...
            currentBonePose.meshCT.Points, currentPoseData.T_CT_ref);
        currentBoneMeshHandle = patch(sceneAxes, ...
            'Faces', currentBonePose.meshCT.ConnectivityList, ...
            'Vertices', currentBonePointsRef, ...
            'FaceColor', [0.92, 0.83, 0.74], ...
            'EdgeColor', 'none', ...
            'FaceAlpha', 0.40, ...
            'HitTest', 'off', ...
            'PickableParts', 'none', ...
            'Tag', 'plot_browser_bone_mesh');

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

        % Describe the pose layers only in this sequence-aware browser. Row 1
        % has no baseline entry because its duplicate surface was not drawn.
        sceneLegendHandles = currentBoneMeshHandle;
        sceneLegendLabels = {sprintf( ...
            'Current bone pose (row %d)', currentPlane.rigidBodyRowIndex)};
        if ~isempty(baselineBoneMeshHandle)
            sceneLegendHandles(end + 1) = baselineBoneMeshHandle;
            sceneLegendLabels{end + 1} = 'Baseline bone pose (row 1)';
        end
        sceneLegendHandles(end + 1) = intersectionLegendHandle;
        sceneLegendLabels{end + 1} = 'Probe-facing 3D intersection';
        sceneLegend = legend( ...
            sceneAxes, sceneLegendHandles, sceneLegendLabels, ...
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

        % The current mesh is always present for a renderable row, so give both
        % current and optional baseline surfaces the established mesh lighting.
        sceneHeadlight = camlight(sceneAxes, 'headlight');
        lighting(sceneAxes, 'gouraud');
        material(sceneAxes, 'dull');

        % Identify the exact current time row. If row 1 is unavailable, add a
        % second title line so the missing context is visible beside the scene.
        sceneTitle = {sprintf('%s | Bone %s | Current data row %d', ...
            char(string(currentPlane.snapshotName)), currentBoneCode, ...
            currentPlane.rigidBodyRowIndex)};
        if ~isempty(baselineStatusMessage)
            sceneTitle{end + 1} = baselineStatusMessage;
        end
        title(sceneAxes, sceneTitle, 'Interpreter', 'none');
        hasRendered3DScene = true;
        drawnow limitrate;
    end

    function transformIsValid = isProperRigidTransform(transformMatrix)
        %ISPROPERRIGIDTRANSFORM Check one project-format rigid transform.
        % Mesh reconstruction assumes a numeric 4-by-4 matrix that maps column
        % vectors, has a proper rotation, and has the homogeneous last row.
        % Checking that contract once before GUI creation gives later rendering
        % code a clear and readable transform assumption.
        %
        % Input:
        %   transformMatrix : Candidate numeric 4-by-4 rigid transform.
        %
        % Output:
        %   transformIsValid : True when the matrix is finite and contains a
        %                      proper rotation and homogeneous final row.

        transformIsValid = isnumeric(transformMatrix) && ...
            isreal(transformMatrix) && ...
            isequal(size(transformMatrix), [4, 4]) && ...
            all(isfinite(transformMatrix), 'all');
        if ~transformIsValid
            return;
        end

        rotationMatrix = double(transformMatrix(1:3, 1:3));
        rigidTolerance = 1e-6;
        transformIsValid = ...
            norm(double(transformMatrix(4, :)) - [0, 0, 0, 1], 2) <= ...
                rigidTolerance && ...
            norm(rotationMatrix.' * rotationMatrix - eye(3), 'fro') <= ...
                rigidTolerance && ...
            abs(det(rotationMatrix) - 1) <= rigidTolerance;
    end

    function [poseData, poseWasFound, bonePoseIndex] = ...
            findMatchingPoseData(planeData)
        %FINDMATCHINGPOSEDATA Find the bone pose belonging to one plane row.
        % The kinematic preparation output stores poses separately from image
        % planes to avoid duplicating a full mesh at every time. This helper
        % reconnects the two records using their stable acquisition identity,
        % which remains correct even when a user sorts the visible table.
        %
        % Input:
        %   planeData : One snapshotPlanes data record. Its bone code,
        %               snapshotIndex, sequenceIndex, and rigidBodyRowIndex
        %               identify the required pose record.
        %
        % Outputs:
        %   poseData      : Matching pose record, or an empty struct when no
        %                   unique match exists.
        %   poseWasFound : True only when exactly one pose record matches all
        %                   four identity values.
        %   bonePoseIndex : Index of the matching bone in validBonePoses, or
        %                   empty when the bone code is absent or duplicated.

        poseData = struct();
        poseWasFound = false;
        bonePoseIndex = find(bonePoseCodes == string(planeData.bone));
        if numel(bonePoseIndex) ~= 1
            bonePoseIndex = [];
            return;
        end

        % Match the complete provenance key. rigidBodyRowIndex alone can repeat
        % in another source group, while sequenceIndex keeps future multi-file
        % groups from silently using a pose from the wrong acquisition pair.
        availablePoseData = validBonePoses.bonePoses(bonePoseIndex).data;
        matchingPoseIndices = find( ...
            [availablePoseData.snapshotIndex] == planeData.snapshotIndex & ...
            [availablePoseData.sequenceIndex] == planeData.sequenceIndex & ...
            [availablePoseData.rigidBodyRowIndex] == ...
                planeData.rigidBodyRowIndex);
        if numel(matchingPoseIndices) ~= 1
            return;
        end

        poseData = availablePoseData(matchingPoseIndices);
        poseWasFound = true;
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
