function tests = testLaunchBoneSegmentationToolsGrouped
%TESTLAUNCHBONESEGMENTATIONTOOLSGROUPED Test grouped segmentation browser behavior.
% These tests verify that directory groups remain distinct in the tabbed GUI,
% repeated local source indices are safe across groups, empty tabs have a clear
% state, scoped processing and grouped export stay aligned, and obsolete or
% ambiguous inputs are rejected before graphics open.
%
% Inputs:
%   None.
%
% Output:
%   tests - MATLAB function-based test suite for this file's local tests.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Add the project function directory for all grouped browser tests.
% Resolving paths from this test file keeps the suite independent of MATLAB's
% current working directory.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase receiving shared test data.
%
% Outputs:
%   None. The project path and output directory are stored in TestData.

testDirectory = fileparts(mfilename('fullpath'));
projectDirectory = fileparts(fileparts(fileparts(testDirectory)));
functionsDirectory = fullfile(projectDirectory, 'functions');
helpersDirectory = fullfile(testDirectory, 'helpers');
addpath(functionsDirectory);

% Put deterministic dialog replacements first on the path so confirmed GUI
% branches can run unattended in MATLAB batch mode.
addpath(helpersDirectory, '-begin');
testCase.TestData.outputDirectory = tempdir;
testCase.TestData.helpersDirectory = helpersDirectory;

% Use one readable source path in every test. The file does not need to be
% loaded because these tests provide the ultrasound fixture directly.
testCase.TestData.sourceUltrasoundFile = fullfile( ...
    tempdir, 'grouped_ultrasound_fixture.mat');
end


function teardownOnce(testCase)
%TEARDOWNONCE Remove the test-only GUI replacements from the MATLAB path.
% This cleanup prevents the confirmation, alert, and file-picker shims from
% affecting code that runs after this grouped browser suite.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase containing the helper path.
%
% Outputs:
%   None. The helper directory is removed from the active MATLAB path.

rmpath(testCase.TestData.helpersDirectory);
end


function teardown(testCase)
%TEARDOWN Remove any segmentation figures left by a failed GUI assertion.
% Deleting only the tagged tool figures prevents one test from affecting the
% next without closing unrelated MATLAB figures.
%
% Input:
%   testCase - Unused matlab.unittest.FunctionTestCase supplied by MATLAB.
%
% Outputs:
%   None. Remaining tagged test figures are deleted.

% The test case is intentionally unused, but naming it keeps the standard
% function-test teardown signature clear to junior readers.
unusedTestCase = testCase; %#ok<NASGU>
openTools = findall(groot, 'Type', 'figure', ...
    'Tag', 'bone_segmentation_tool_figure');
delete(openTools);

% Remove the temporary picker destination even when an export assertion fails.
applicationDataKey = 'BoneSegmentationTestExportPath';
if isappdata(groot, applicationDataKey)
    exportPath = char(string(getappdata(groot, applicationDataKey)));
    rmappdata(groot, applicationDataKey);
    deleteFileIfPresent(exportPath);
end
drawnow;
end


function testGroupedTabsAndLocalRows(testCase)
%TESTGROUPEDTABSANDLOCALROWS Verify one table tab per source group.
% Cross-group duplicate source indices must remain valid because table identity
% uses group and local position rather than sourceIndex alone.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

ultrasoundSequence = makeGroupedFixture();
segmentationFigure = launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile);
drawnow;

tabGroup = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_tab_group');
verifyEqual(testCase, numel(tabGroup.Children), 3);
tabTitles = string({tabGroup.Children.Title});
verifyTrue(testCase, all(ismember( ...
    ["empty_group", "group_a", "group_b"], tabTitles)));

emptyTable = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_table_1');
groupATable = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_table_2');
groupBTable = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_table_3');
verifyEqual(testCase, height(emptyTable.Data), 0);
verifyEqual(testCase, height(groupATable.Data), 2);
verifyEqual(testCase, height(groupBTable.Data), 1);
verifyEqual(testCase, groupATable.Data.SequencePosition, [1; 2]);
verifyEqual(testCase, groupATable.Data.SourceIndex, [1; 3]);
verifyEqual(testCase, groupBTable.Data.SourceIndex, 1);
verifyTrue(testCase, all(groupATable.ColumnSortable));
verifyTrue(testCase, ismember( ...
    'BlobQuality', groupATable.Data.Properties.VariableNames));
verifyTrue(testCase, isordinal(groupATable.Data.BlobQuality));
verifyEqual(testCase, categories(groupATable.Data.BlobQuality), { ...
    'Not checked'; 'No blobs'; 'Urgent'; 'Check'; 'Good'});
verifyEqual(testCase, string(groupATable.Data.BlobQuality), ...
    repmat("Not checked", 2, 1));
verifyEqual(testCase, height(emptyTable.StyleConfigurations), 0);

% The initial gray badge must target the quality cells, and the tooltip must
% make every count threshold discoverable without adding another UI panel.
qualityColumnIndex = find(strcmp( ...
    groupATable.Data.Properties.VariableNames, 'BlobQuality'), 1);
notCheckedStyle = findCellStyle( ...
    groupATable, 1, qualityColumnIndex);
verifyEqual(testCase, notCheckedStyle.BackgroundColor, ...
    [0.95, 0.95, 0.95], 'AbsTol', 1e-12);
verifySize(testCase, notCheckedStyle.Icon, [11, 11, 3]);
verifyTrue(testCase, contains(string(groupATable.Tooltip), '2-5'));

% Both processing scopes must be visible in the grouped browser.
verifyNotEmpty(testCase, findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_apply_parameters_tab_button'));
verifyNotEmpty(testCase, findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_apply_parameters_all_button'));
verifyEqual(testCase, tabGroup.SelectedTab.UserData, 2);
end


function testEmptyTabAndCrossGroupNavigation(testCase)
%TESTEMPTYTABANDCROSSGROUPNAVIGATION Verify empty and boundary UI states.
% Selecting an empty group must clear stale imagery, while Next must cross from
% the final row of one populated tab to the first row of the following group.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

ultrasoundSequence = makeGroupedFixture();
segmentationFigure = launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile);
drawnow;

tabGroup = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_tab_group');
emptyTab = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_tab_1');
groupATab = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_tab_2');
tabCallback = tabGroup.SelectionChangedFcn;

% Programmatic tab changes do not always emit a UI event in batch mode, so
% invoke the installed callback with the same NewValue contract as MATLAB.
tabGroup.SelectedTab = emptyTab;
tabCallback(tabGroup, struct('NewValue', emptyTab));
drawnow;
workflowPanel = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_workflow_panel');
verifyEqual(testCase, string(workflowPanel.Enable), "off");
imageAxes = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_image_axes');
verifyTrue(testCase, axesContainsText(imageAxes, 'empty_group'));

% Return to the populated tab and verify that its real preview replaces the
% empty-group message before testing direct table selection.
tabGroup.SelectedTab = groupATab;
tabCallback(tabGroup, struct('NewValue', groupATab));
drawnow;
verifyEqual(testCase, string(workflowPanel.Enable), "on");
verifyNotEmpty(testCase, findall(imageAxes, 'Type', 'image'));

% Select group A's second local row directly, visit the empty tab, and return
% to confirm that the populated tab remembers its last local selection.
groupATable = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_table_2');
tableCallback = groupATable.SelectionChangedFcn;
tableCallback(groupATable, struct('Selection', 2));
tabGroup.SelectedTab = emptyTab;
tabCallback(tabGroup, struct('NewValue', emptyTab));
tabGroup.SelectedTab = groupATab;
tabCallback(tabGroup, struct('NewValue', groupATab));
drawnow;
verifyEqual(testCase, groupATable.Selection, 2);

% One Next action from the remembered final row must cross into group B.
nextButton = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_next_button');
nextCallback = nextButton.ButtonPushedFcn;
nextCallback(nextButton, []);
drawnow;
verifyEqual(testCase, tabGroup.SelectedTab.UserData, 3);
groupBTable = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_table_3');
verifyEqual(testCase, groupBTable.Selection, 1);
end


function testApplyScopesAndGroupedExport(testCase)
%TESTAPPLYSCOPESANDGROUPEDEXPORT Verify scoped updates and saved hierarchy.
% The active-tab transaction must leave other groups unprocessed, while the
% all-tab transaction and export must preserve every group and local identity.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None. A temporary exported MAT file is loaded, checked, and removed.

ultrasoundSequence = makeGroupedFixture();
segmentationFigure = launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile);
drawnow;

groupATable = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_table_2');
groupBTable = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_table_3');

% Confirming the tab-scoped callback must update group A's two images only.
applyTabButton = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_apply_parameters_tab_button');
applyTabButton.ButtonPushedFcn(applyTabButton, []);
drawnow;
verifyEqual(testCase, groupATable.Data.Status, ...
    repmat("Processed", 2, 1));
verifyEqual(testCase, groupBTable.Data.Status, "Unprocessed");
verifyFalse(testCase, any(string( ...
    groupATable.Data.BlobQuality) == "Not checked"));
verifyEqual(testCase, string(groupBTable.Data.BlobQuality), "Not checked");

% The global callback must then process the remaining group B image as well.
applyAllButton = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_apply_parameters_all_button');
applyAllButton.ButtonPushedFcn(applyAllButton, []);
drawnow;
verifyEqual(testCase, groupATable.Data.Status, ...
    repmat("Processed", 2, 1));
verifyEqual(testCase, groupBTable.Data.Status, "Processed");
verifyFalse(testCase, any(string( ...
    groupBTable.Data.BlobQuality) == "Not checked"));

% Direct the real export callback to a unique disposable MAT file.
exportPath = [tempname(testCase.TestData.outputDirectory), '.mat'];
applicationDataKey = 'BoneSegmentationTestExportPath';
setappdata(groot, applicationDataKey, exportPath);
exportButton = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_export_button');
exportButton.ButtonPushedFcn(exportButton, []);
drawnow;
verifyTrue(testCase, isfile(exportPath));

loadedExport = load( ...
    exportPath, 'segmentationResults', 'segmentationMetadata');
segmentationResults = loadedExport.segmentationResults;
segmentationMetadata = loadedExport.segmentationMetadata;
verifyEqual(testCase, segmentationMetadata.sourceUltrasoundFile, ...
    testCase.TestData.sourceUltrasoundFile);
verifyEqual(testCase, segmentationMetadata.sourceVariable, ...
    'validSnapshots');
verifyEqual(testCase, segmentationMetadata.numberOfFrames, 3);
verifyNotEmpty(testCase, segmentationMetadata.createdAt);
verifyEqual(testCase, numel(segmentationResults), numel(ultrasoundSequence));
verifyEqual(testCase, string({segmentationResults.name}), ...
    string({ultrasoundSequence.name}));
verifyEqual(testCase, string({segmentationResults.bone}), ...
    string({ultrasoundSequence.bone}));
verifyEqual(testCase, string({segmentationResults.path}), ...
    string({ultrasoundSequence.path}));
verifyEqual(testCase, arrayfun( ...
    @(group) numel(group.data), segmentationResults), [0, 2, 1]);

% Check local positions, source indices, masks, parameters, and statuses for
% every nonempty result group rather than relying only on outer metadata.
for groupIndex = 2:numel(segmentationResults)
    expectedSourceIndices = [ultrasoundSequence(groupIndex).data.sourceIndex];
    groupResults = segmentationResults(groupIndex).data;
    verifyEqual(testCase, [groupResults.sequencePosition], ...
        1:numel(groupResults));
    verifyEqual(testCase, [groupResults.sourceIndex], expectedSourceIndices);
    verifyEqual(testCase, string({groupResults.status}), ...
        repmat("processed", 1, numel(groupResults)));
    for localIndex = 1:numel(groupResults)
        expectedMaskSize = size( ...
            ultrasoundSequence(groupIndex).data(localIndex).plane.image.');
        verifyEqual(testCase, size( ...
            groupResults(localIndex).segmentationMask), expectedMaskSize);
        verifyEqual(testCase, size( ...
            groupResults(localIndex).segmentationAreaMask), expectedMaskSize);
        verifyEqual(testCase, size( ...
            groupResults(localIndex).pixelCoordinates, 2), 2);
        verifyEqual(testCase, ...
            groupResults(localIndex).usesCustomSegmentationArea, false);
        verifyEqual(testCase, ...
            groupResults(localIndex).processingParameters, ...
            segmentationResults(2).data(1).processingParameters);
    end
end
end


function testBlobQualityBoundariesAndStyles(testCase)
%TESTBLOBQUALITYBOUNDARIESANDSTYLES Verify every blob-count classification.
% Synthetic images with separated bright squares make 0, 1, 2, 5, and 6
% connected components deterministic after the existing segmentation pipeline.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None. The test processes the fixture and inspects table data and styles.

ultrasoundSequence = makeBlobCountFixture( ...
    [0, 1, 2, 5, 6], 'blob_quality_group');
segmentationFigure = launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile);
drawnow;

% Use a fixed threshold so only the 255-valued squares become foreground.
thresholdField = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_threshold_field');
thresholdField.Value = 128;
thresholdField.ValueChangedFcn(thresholdField, []);

% Process every synthetic image through the same transactional callback used
% by the real bulk workflow.
applyAllButton = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_apply_parameters_all_button');
applyAllButton.ButtonPushedFcn(applyAllButton, []);
drawnow;

sequenceTable = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_table_1');
expectedQuality = [ ...
    "No blobs"; "Good"; "Check"; "Check"; "Urgent"];
verifyEqual(testCase, string(sequenceTable.Data.BlobQuality), expectedQuality);

% Ordered categories must place the most actionable populated states first
% when users sort the quality column in ascending order.
sortedTableData = sortrows(sequenceTable.Data, 'BlobQuality');
verifyEqual(testCase, string(sortedTableData.BlobQuality), [ ...
    "No blobs"; "Urgent"; "Check"; "Check"; "Good"]);

% Confirm every row has a style attached to the quality cell and that each
% category uses the agreed soft background color.
qualityColumnIndex = find(strcmp( ...
    sequenceTable.Data.Properties.VariableNames, 'BlobQuality'), 1);
expectedBackgroundColors = [ ...
    0.88, 0.88, 0.88; ...
    0.90, 0.96, 0.91; ...
    1.00, 0.96, 0.80; ...
    1.00, 0.96, 0.80; ...
    0.99, 0.91, 0.90];
for rowIndex = 1:height(sequenceTable.Data)
    currentStyle = findCellStyle( ...
        sequenceTable, rowIndex, qualityColumnIndex);
    verifyEqual(testCase, currentStyle.BackgroundColor, ...
        expectedBackgroundColors(rowIndex, :), 'AbsTol', 1e-12);
    verifySize(testCase, currentStyle.Icon, [11, 11, 3]);
end

% The center of the zero-blob icon must be black. The gray unchecked icon is
% hollow, which makes these two neutral-background states visually distinct.
noBlobsStyle = findCellStyle(sequenceTable, 1, qualityColumnIndex);
centerPixel = reshape(noBlobsStyle.Icon(6, 6, :), 1, 3);
verifyEqual(testCase, centerPixel, [0.05, 0.05, 0.05], ...
    'AbsTol', 1e-12);
end


function testBlobQualityLiveUpdateRules(testCase)
%TESTBLOBQUALITYLIVEUPDATERULES Verify unchecked and processed preview behavior.
% An unprocessed image must stay gray even when controls change, while a
% processed image must show its new live quality before navigation commits it.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None. The test drives real parameter and bulk-processing callbacks.

ultrasoundSequence = makeBlobCountFixture([1, 1], 'live_quality_group');
segmentationFigure = launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile);
drawnow;
sequenceTable = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_sequence_table_1');

% Changing an automatically opened preview does not mean the user accepted or
% batch-processed it, so the initial row must remain Not checked.
thresholdField = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_threshold_field');
thresholdField.Value = 128;
thresholdField.ValueChangedFcn(thresholdField, []);
verifyEqual(testCase, string( ...
    sequenceTable.Data.BlobQuality(1)), "Not checked");

% Bulk processing commits both one-blob masks and establishes the live-update
% rule for later edits to the selected processed row.
applyAllButton = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_apply_parameters_all_button');
applyAllButton.ButtonPushedFcn(applyAllButton, []);
drawnow;
verifyEqual(testCase, string(sequenceTable.Data.BlobQuality), ...
    repmat("Good", 2, 1));

% At threshold 255 the original white square remains. Lowering brightness then
% removes it from the live mask and must immediately show No blobs/Modified.
thresholdField.Value = 255;
thresholdField.ValueChangedFcn(thresholdField, []);
brightnessField = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_brightness_field');
brightnessField.Value = -100;
brightnessField.ValueChangedFcn(brightnessField, []);
drawnow;
verifyEqual(testCase, string( ...
    sequenceTable.Data.BlobQuality(1)), "No blobs");
verifyEqual(testCase, sequenceTable.Data.Status(1), "Modified");
end


function testFlatInputIsRejected(testCase)
%TESTFLATINPUTISREJECTED Verify the obsolete sequence vector is unsupported.
% The grouped-only error prevents duplicate source indices from being silently
% interpreted as global identifiers.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

groupedFixture = makeGroupedFixture();
flatSequence = groupedFixture(2).data;
verifyError(testCase, @() launchBoneSegmentationTools( ...
    flatSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile), ...
    'launchBoneSegmentationTools:MissingGroupFields');
end


function testDuplicateSourceIndexWithinGroupIsRejected(testCase)
%TESTDUPLICATESOURCEINDEXWITHINGROUPISREJECTED Verify local identity uniqueness.
% Repetition between groups is valid, but two records in one directory cannot
% share a sourceIndex because exported local matching would be ambiguous.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

ultrasoundSequence = makeGroupedFixture();
ultrasoundSequence(2).data(2).sourceIndex = ...
    ultrasoundSequence(2).data(1).sourceIndex;
verifyError(testCase, @() launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile), ...
    'launchBoneSegmentationTools:DuplicateGroupSourceIndex');
end


function testMalformedGroupMetadataIsRejected(testCase)
%TESTMALFORMEDGROUPMETADATAISREJECTED Verify scalar group metadata is required.
% A vector-valued tab name cannot safely label one source directory or be
% mirrored as one output group, so validation must fail before graphics open.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

ultrasoundSequence = makeGroupedFixture();
ultrasoundSequence(2).name = ["group_a", "ambiguous_name"];
verifyError(testCase, @() launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile), ...
    'launchBoneSegmentationTools:InvalidGroupMetadata');
end


function testPlaneGroupMetadataMismatchIsRejected(testCase)
%TESTPLANEGROUPMETADATAMISMATCHISREJECTED Verify records belong to their group.
% Matching plane and outer metadata protects grouped export from silently
% assigning an image to a different source directory or bone segment.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

ultrasoundSequence = makeGroupedFixture();
ultrasoundSequence(2).data(1).plane.snapshotName = 'wrong_group';
verifyError(testCase, @() launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile), ...
    'launchBoneSegmentationTools:PlaneGroupMetadataMismatch');
end


function testMalformedPlaneMetadataIsRejected(testCase)
%TESTMALFORMEDPLANEMETADATAISREJECTED Verify plane labels are scalar text.
% Explicit validation gives malformed group-local records a useful error before
% their metadata is compared with the owning group.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

ultrasoundSequence = makeGroupedFixture();
ultrasoundSequence(2).data(1).plane.bone = ["T", "F"];
verifyError(testCase, @() launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile), ...
    'launchBoneSegmentationTools:InvalidPlaneMetadata');
end


function testAllEmptyGroupsAreRejected(testCase)
%TESTALLEMPTYGROUPSAREREJECTED Verify the UI always has an initial image.
% Empty groups are supported around populated groups, but an entirely empty
% dataset cannot initialize processing defaults or an image preview.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

ultrasoundSequence = makeGroupedFixture();
for groupIndex = 1:numel(ultrasoundSequence)
    ultrasoundSequence(groupIndex).data = ...
        ultrasoundSequence(groupIndex).data([]);
end
verifyError(testCase, @() launchBoneSegmentationTools( ...
    ultrasoundSequence, testCase.TestData.outputDirectory, ...
    testCase.TestData.sourceUltrasoundFile), ...
    'launchBoneSegmentationTools:NoImages');
end


function ultrasoundSequence = makeGroupedFixture()
%MAKEGROUPEDFIXTURE Build empty and populated source-directory groups.
% The fixture deliberately repeats sourceIndex 1 across two groups to exercise
% the composite group/local identity required by the new public contract.
%
% Inputs:
%   None.
%
% Output:
%   ultrasoundSequence - Three grouped source directories containing 0, 2,
%                        and 1 ultrasound records respectively.

baseImage = uint8(repmat(0:7, 6, 1) * 20);
emptyRecord = makeUltrasoundRecord(1, 'empty_group', 'F', baseImage);
groupTemplate = struct( ...
    'name', '', ...
    'bone', 'U', ...
    'path', '', ...
    'data', emptyRecord([]));
ultrasoundSequence = repmat(groupTemplate, 1, 3);

ultrasoundSequence(1).name = 'empty_group';
ultrasoundSequence(1).bone = 'F';
ultrasoundSequence(1).path = 'C:\fixture\empty_group';

ultrasoundSequence(2).name = 'group_a';
ultrasoundSequence(2).bone = 'T';
ultrasoundSequence(2).path = 'C:\fixture\group_a';
ultrasoundSequence(2).data = [ ...
    makeUltrasoundRecord(1, 'group_a', 'T', baseImage), ...
    makeUltrasoundRecord(3, 'group_a', 'T', baseImage + 10)];

% Give one group's records an unrelated field to confirm that flattening reads
% only sourceIndex and plane instead of requiring identical extra payloads.
ultrasoundSequence(2).data(1).optionalGroupPayload = 'ignored';

ultrasoundSequence(3).name = 'group_b';
ultrasoundSequence(3).bone = 'T';
ultrasoundSequence(3).path = 'C:\fixture\group_b';
ultrasoundSequence(3).data = ...
    makeUltrasoundRecord(1, 'group_b', 'T', baseImage + 20);
end


function ultrasoundSequence = makeBlobCountFixture(blobCounts, groupName)
%MAKEBLOBCOUNTFIXTURE Build images with known connected-component counts.
% This helper draws separated 6-by-6 white squares on black images. It is needed
% to exercise blob-quality boundaries through the real segmentation pipeline
% without relying on noisy acquisition data or fragile automatic thresholds.
%
% Inputs:
%   blobCounts : Numeric row vector containing counts from 0 through 6.
%   groupName  : Text scalar used for matching group and plane metadata.
%
% Output:
%   ultrasoundSequence : Scalar grouped sequence whose records contain the
%                        requested numbers of 8-connected bright regions.

% Six fixed positions leave black gaps between every square, including along
% diagonals, so 8-connectivity cannot join neighboring test blobs.
blobStartPositions = [ ...
    5, 5; ...
    5, 25; ...
    5, 45; ...
    25, 5; ...
    25, 25; ...
    25, 45];
displayedImageSize = [40, 60];

% Preallocate records from one valid image so the fixture matches the grouped
% public input contract used by launchBoneSegmentationTools.
blankDisplayedImage = zeros(displayedImageSize, 'uint8');
recordTemplate = makeUltrasoundRecord( ...
    1, groupName, 'T', blankDisplayedImage.');
groupRecords = repmat(recordTemplate, 1, numel(blobCounts));

for imageIndex = 1:numel(blobCounts)
    displayedImage = blankDisplayedImage;
    for blobIndex = 1:blobCounts(imageIndex)
        startRow = blobStartPositions(blobIndex, 1);
        startColumn = blobStartPositions(blobIndex, 2);
        displayedImage(startRow:(startRow + 5), ...
            startColumn:(startColumn + 5)) = 255;
    end

    % Store the transpose because project acquisition packets use [width, height]
    % while segmentation masks use the displayed [row, column] orientation.
    groupRecords(imageIndex) = makeUltrasoundRecord( ...
        imageIndex, groupName, 'T', displayedImage.');
end

% Assign fields after creating the scalar group so its record vector remains one
% nested data field rather than expanding the outer struct array.
ultrasoundSequence = struct( ...
    'name', '', ...
    'bone', 'T', ...
    'path', '', ...
    'data', groupRecords([]));
ultrasoundSequence.name = groupName;
ultrasoundSequence.path = fullfile('C:\fixture', groupName);
ultrasoundSequence.data = groupRecords;
end


function ultrasoundRecord = makeUltrasoundRecord( ...
        sourceIndex, groupName, boneCode, storedImage)
%MAKEULTRASOUNDRECORD Build one valid grouped snapshot data record.
% The plane follows the project's stored [width, height] convention so the
% segmentation browser displays its transpose with matching nRows and nCols.
%
% Inputs:
%   sourceIndex : Numeric identifier local to the source directory.
%   groupName   : Source-directory name repeated in plane.snapshotName.
%   boneCode    : Bone code repeated in the outer group and plane.
%   storedImage : Numeric ultrasound packet stored as [width, height].
%
% Output:
%   ultrasoundRecord - Scalar struct containing sourceIndex and plane.

displayedSize = size(storedImage.');
plane = struct( ...
    'image', storedImage, ...
    'nRows', displayedSize(1), ...
    'nCols', displayedSize(2), ...
    'W', double(displayedSize(2)), ...
    'H', double(displayedSize(1)), ...
    'bone', boneCode, ...
    'snapshotName', groupName);
ultrasoundRecord = struct( ...
    'sourceIndex', sourceIndex, ...
    'plane', plane);
end


function matchingStyle = findCellStyle(sequenceTable, rowIndex, columnIndex)
%FINDCELLSTYLE Find the style configuration targeting one table cell.
% This helper inspects MATLAB's compact style-configuration table. It is needed
% to verify that grouped style targets include the requested quality cell even
% when one style object is shared by several rows.
%
% Inputs:
%   sequenceTable : MATLAB uitable whose StyleConfigurations are inspected.
%   rowIndex      : Positive data-row index of the requested cell.
%   columnIndex   : Positive data-column index of the requested cell.
%
% Output:
%   matchingStyle : matlab.ui.style.Style object applied to the requested cell.

styleConfigurations = sequenceTable.StyleConfigurations;
for configurationIndex = 1:height(styleConfigurations)
    if string(styleConfigurations.Target(configurationIndex)) ~= "cell"
        continue;
    end

    targetCells = styleConfigurations.TargetIndex{configurationIndex};
    requestedCell = [rowIndex, columnIndex];
    if any(all(targetCells == requestedCell, 2))
        matchingStyle = styleConfigurations.Style(configurationIndex);
        return;
    end
end

% A missing target means the visual indicator was not applied as required.
error('testLaunchBoneSegmentationToolsGrouped:MissingCellStyle', ...
    'No style targets table cell at row %d, column %d.', ...
    rowIndex, columnIndex);
end


function containsRequestedText = axesContainsText(imageAxes, requestedText)
%AXESCONTAINSTEXT Check whether any axes text contains requested content.
% Handling each text object separately supports scalar strings and cell-array
% title strings without relying on one fragile concatenation conversion.
%
% Inputs:
%   imageAxes    : Axes whose text objects should be inspected.
%   requestedText: Character or string content expected in one text object.
%
% Output:
%   containsRequestedText - True when at least one axes text contains content.

containsRequestedText = false;
textHandles = findall(imageAxes, 'Type', 'text');
for textIndex = 1:numel(textHandles)
    currentText = string(textHandles(textIndex).String);
    if any(contains(currentText, string(requestedText)))
        containsRequestedText = true;
        return;
    end
end
end


function deleteFileIfPresent(filePath)
%DELETEFILEIFPRESENT Remove one temporary export created by this test suite.
% Checking the exact configured path first makes cleanup safe after both
% successful exports and callbacks that fail before writing a file.
%
% Input:
%   filePath : Exact temporary MAT-file path configured by the test.
%
% Outputs:
%   None. The file is deleted only when it exists.

if isfile(filePath)
    delete(filePath);
end
end
