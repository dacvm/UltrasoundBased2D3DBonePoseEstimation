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
    ultrasoundSequence, testCase.TestData.outputDirectory);
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
    ultrasoundSequence, testCase.TestData.outputDirectory);
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
    ultrasoundSequence, testCase.TestData.outputDirectory);
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

% The global callback must then process the remaining group B image as well.
applyAllButton = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_apply_parameters_all_button');
applyAllButton.ButtonPushedFcn(applyAllButton, []);
drawnow;
verifyEqual(testCase, groupATable.Data.Status, ...
    repmat("Processed", 2, 1));
verifyEqual(testCase, groupBTable.Data.Status, "Processed");

% Direct the real export callback to a unique disposable MAT file.
exportPath = [tempname(testCase.TestData.outputDirectory), '.mat'];
applicationDataKey = 'BoneSegmentationTestExportPath';
setappdata(groot, applicationDataKey, exportPath);
exportButton = findall(segmentationFigure, ...
    'Tag', 'bone_segmentation_export_button');
exportButton.ButtonPushedFcn(exportButton, []);
drawnow;
verifyTrue(testCase, isfile(exportPath));

loadedExport = load(exportPath, 'segmentationResults');
segmentationResults = loadedExport.segmentationResults;
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
    flatSequence, testCase.TestData.outputDirectory), ...
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
    ultrasoundSequence, testCase.TestData.outputDirectory), ...
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
    ultrasoundSequence, testCase.TestData.outputDirectory), ...
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
    ultrasoundSequence, testCase.TestData.outputDirectory), ...
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
    ultrasoundSequence, testCase.TestData.outputDirectory), ...
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
    ultrasoundSequence, testCase.TestData.outputDirectory), ...
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
