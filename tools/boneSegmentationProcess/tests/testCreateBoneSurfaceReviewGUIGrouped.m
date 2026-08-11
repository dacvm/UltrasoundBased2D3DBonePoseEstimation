function tests = testCreateBoneSurfaceReviewGUIGrouped
%TESTCREATEBONESURFACEREVIEWGUIGROUPED Test grouped review navigation and input.
% These tests verify source-directory tabs, empty states, remembered selections,
% reordered input matching, and repeated source indices across different groups.
%
% Inputs:
%   None.
%
% Output:
%   tests : Function-based test suite discovered by MATLAB.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Add the display function directory for this GUI test suite.
% Resolving the project root from the test location avoids assumptions about
% MATLAB's current working directory.
%
% Input:
%   testCase : matlab.unittest.FunctionTestCase receiving shared test data.
%
% Outputs:
%   None. The display path and compact options are stored in TestData.

testDirectory = fileparts(mfilename('fullpath'));
projectDirectory = fileparts(fileparts(fileparts(testDirectory)));
displayDirectory = fullfile(projectDirectory, 'functions', 'display');
testCase.TestData.displayDirectory = displayDirectory;
pathEntries = strsplit(path, pathsep);
testCase.TestData.addedDisplayDirectory = ...
    ~any(strcmp(pathEntries, displayDirectory));
if testCase.TestData.addedDisplayDirectory
    addpath(displayDirectory);
end
testCase.TestData.options = struct( ...
    'imageEvidence', struct('gaussianSigmaMm', 0.5));
testCase.TestData.configurationPath = 'synthetic_config.json';
end


function teardownOnce(testCase)
%TEARDOWNONCE Remove the display function directory after all GUI tests.
% This restores the MATLAB path entry added by setupOnce.
%
% Input:
%   testCase : matlab.unittest.FunctionTestCase containing the display path.
%
% Outputs:
%   None. The test-owned path entry is removed.

if testCase.TestData.addedDisplayDirectory
    rmpath(testCase.TestData.displayDirectory);
end
end


function teardown(testCase)
%TEARDOWN Delete review figures left by successful or failed assertions.
% Restricting cleanup by tag leaves unrelated MATLAB figures untouched.
%
% Input:
%   testCase : Unused test case supplied by the function-test framework.
%
% Outputs:
%   None. Open grouped review figures are deleted.

unusedTestCase = testCase; %#ok<NASGU>
reviewFigures = findall(groot, 'Type', 'figure', ...
    'Tag', 'bone_surface_review_gui');
delete(reviewFigures);
drawnow;
end


function testGroupedTabsAndLocalTableIdentity(testCase)
%TESTGROUPEDTABSANDLOCALTABLEIDENTITY Verify one table per surface group.
% Surface group order must control tab order even when segmentation and
% ultrasound outer groups and local records arrive in different orders.
%
% Input:
%   testCase : matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

[surfaceGroups, segmentationGroups, ultrasoundGroups] = makeReviewFixture();
reviewFigure = createBoneSurfaceReviewGUI( ...
    surfaceGroups, segmentationGroups, ultrasoundGroups, ...
    testCase.TestData.options, testCase.TestData.configurationPath);
drawnow;

tabGroup = findall(reviewFigure, 'Tag', 'bone_surface_review_tab_group');
verifyEqual(testCase, [tabGroup.Children.UserData], [1, 2, 3]);
verifyEqual(testCase, string({tabGroup.Children.Title}), ...
    ["empty_group", "group_a", "group_b"]);
verifyEqual(testCase, tabGroup.SelectedTab.UserData, 2);

emptyTable = findall(reviewFigure, ...
    'Tag', 'bone_surface_review_data_table_1');
groupATable = findall(reviewFigure, ...
    'Tag', 'bone_surface_review_data_table_2');
groupBTable = findall(reviewFigure, ...
    'Tag', 'bone_surface_review_data_table_3');
verifyEqual(testCase, height(emptyTable.Data), 0);
verifyEqual(testCase, height(groupATable.Data), 2);
verifyEqual(testCase, height(groupBTable.Data), 1);
verifyEqual(testCase, groupATable.Data.LocalResultIndex, [1; 2]);
verifyEqual(testCase, groupATable.Data.SourceIndex, [1; 3]);
verifyEqual(testCase, groupBTable.Data.SourceIndex, 1);
verifyTrue(testCase, all(groupATable.ColumnSortable));

% The first rendered image must come from group A rather than group B's
% record with the same sourceIndex value.
verifyEqual(testCase, getDisplayedImageData(reviewFigure), ...
    uint8(20 * ones(6, 8)));
end


function testEmptyTabRememberedSelectionAndRepeatedSource(testCase)
%TESTEMPTYTABREMEMBEREDSELECTIONANDREPEATEDSOURCE Verify navigation state.
% Direct table selection must be remembered across an empty tab, and selecting
% group B must render its own sourceIndex 1 image instead of group A's image.
%
% Input:
%   testCase : matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

[surfaceGroups, segmentationGroups, ultrasoundGroups] = makeReviewFixture();
reviewFigure = createBoneSurfaceReviewGUI( ...
    surfaceGroups, segmentationGroups, ultrasoundGroups, ...
    testCase.TestData.options, testCase.TestData.configurationPath);
drawnow;

tabGroup = findall(reviewFigure, 'Tag', 'bone_surface_review_tab_group');
emptyTab = findall(reviewFigure, 'Tag', 'bone_surface_review_tab_1');
groupATab = findall(reviewFigure, 'Tag', 'bone_surface_review_tab_2');
groupBTab = findall(reviewFigure, 'Tag', 'bone_surface_review_tab_3');
groupATable = findall(reviewFigure, ...
    'Tag', 'bone_surface_review_data_table_2');
tabCallback = tabGroup.SelectionChangedFcn;
tableCallback = groupATable.SelectionChangedFcn;

% Select group A's second local record through the same event contract emitted
% by a real table click.
tableCallback(groupATable, struct('Selection', 2));
drawnow;
verifyEqual(testCase, getDisplayedImageData(reviewFigure), ...
    uint8(40 * ones(6, 8)));

tabGroup.SelectedTab = emptyTab;
tabCallback(tabGroup, struct('NewValue', emptyTab));
drawnow;
imageAxes = findall(reviewFigure, 'Tag', 'bone_surface_review_image_axes');
verifyTrue(testCase, axesContainsText(imageAxes, 'empty_group'));

tabGroup.SelectedTab = groupATab;
tabCallback(tabGroup, struct('NewValue', groupATab));
drawnow;
verifyEqual(testCase, groupATable.Selection, 2);
verifyEqual(testCase, getDisplayedImageData(reviewFigure), ...
    uint8(40 * ones(6, 8)));

% Group B deliberately repeats sourceIndex 1 but stores a distinct image.
tabGroup.SelectedTab = groupBTab;
tabCallback(tabGroup, struct('NewValue', groupBTab));
drawnow;
verifyEqual(testCase, getDisplayedImageData(reviewFigure), ...
    uint8(180 * ones(6, 8)));
end


function testFlatAndDuplicateGroupInputsAreRejected(testCase)
%TESTFLATANDDUPLICATEGROUPINPUTSAREREJECTED Verify grouped-only GUI validation.
% Flat surfaces and ambiguous group metadata must fail before a partial review
% figure is created.
%
% Input:
%   testCase : matlab.unittest.FunctionTestCase used for assertions.
%
% Outputs:
%   None.

[surfaceGroups, segmentationGroups, ultrasoundGroups] = makeReviewFixture();
verifyError(testCase, @() createBoneSurfaceReviewGUI( ...
    surfaceGroups(2).data, segmentationGroups, ultrasoundGroups, ...
    testCase.TestData.options, testCase.TestData.configurationPath), ...
    'createBoneSurfaceReviewGUI:InvalidSurfaceResults');

segmentationGroups(2).name = segmentationGroups(1).name;
segmentationGroups(2).bone = segmentationGroups(1).bone;
segmentationGroups(2).path = segmentationGroups(1).path;
verifyError(testCase, @() createBoneSurfaceReviewGUI( ...
    surfaceGroups, segmentationGroups, ultrasoundGroups, ...
    testCase.TestData.options, testCase.TestData.configurationPath), ...
    'createBoneSurfaceReviewGUI:DuplicateGroupIdentity');
end


function [surfaceGroups, segmentationGroups, ultrasoundGroups] = ...
        makeReviewFixture()
%MAKEREVIEWFIXTURE Build reordered grouped review inputs with repeated keys.
% The surface order is empty, group A, group B. The other inputs are reordered,
% and group A local records are reversed to exercise both matching levels.
%
% Inputs:
%   None.
%
% Outputs:
%   surfaceGroups      : Grouped surface records with counts 0, 2, and 1.
%   segmentationGroups : Matching segmentation groups in another order.
%   ultrasoundGroups  : Matching ultrasound groups in another order.

surfaceA1 = makeSurfaceRecord(1, 1, 8);
surfaceA2 = makeSurfaceRecord(3, 2, 8);
surfaceB1 = makeSurfaceRecord(1, 1, 8);
segmentationA1 = makeSegmentationRecord(1, [6, 8]);
segmentationA2 = makeSegmentationRecord(3, [6, 8]);
segmentationB1 = makeSegmentationRecord(1, [6, 8]);
ultrasoundA1 = makeUltrasoundRecord(1, 20);
ultrasoundA2 = makeUltrasoundRecord(3, 40);
ultrasoundB1 = makeUltrasoundRecord(1, 180);

surfaceGroups = makeOuterGroups(surfaceA1([]));
segmentationGroups = makeOuterGroups(segmentationA1([]));
ultrasoundGroups = makeOuterGroups(ultrasoundA1([]));
surfaceGroups(2).data = [surfaceA1, surfaceA2];
surfaceGroups(3).data = surfaceB1;
segmentationGroups(2).data = [segmentationA1, segmentationA2];
segmentationGroups(3).data = segmentationB1;
ultrasoundGroups(2).data = [ultrasoundA1, ultrasoundA2];
ultrasoundGroups(3).data = ultrasoundB1;

% Deliberately reorder both matching inputs and reverse group A's local data.
segmentationGroups = segmentationGroups([3, 1, 2]);
segmentationGroups(3).data = segmentationGroups(3).data([2, 1]);
ultrasoundGroups = ultrasoundGroups([2, 3, 1]);
ultrasoundGroups(1).data = ultrasoundGroups(1).data([2, 1]);
end


function groups = makeOuterGroups(emptyData)
%MAKEOUTERGROUPS Build three source-directory groups around typed empty data.
% Consistent metadata is shared across surface, segmentation, and ultrasound
% fixtures so only their outer ordering differs.
%
% Input:
%   emptyData : Empty typed struct array for this grouped input category.
%
% Output:
%   groups : Three groups named empty_group, group_a, and group_b.

groupTemplate = struct( ...
    'name', '', 'bone', '', 'path', '', 'data', emptyData);
groups = repmat(groupTemplate, 1, 3);
groupNames = {'empty_group', 'group_a', 'group_b'};
groupBones = {'F', 'T', 'T'};
groupPaths = {'fixture://empty', 'fixture://group_a', 'fixture://group_b'};
for groupIndex = 1:3
    groups(groupIndex).name = groupNames{groupIndex};
    groups(groupIndex).bone = groupBones{groupIndex};
    groups(groupIndex).path = groupPaths{groupIndex};
end
end


function surfaceRecord = makeSurfaceRecord( ...
        sourceIndex, sequencePosition, numberOfColumns)
%MAKESURFACERECORD Build one display-safe empty surface result record.
% NaN surface rows and false masks represent a valid no-surface extraction while
% retaining every field consumed by the review table and overlay renderer.
%
% Inputs:
%   sourceIndex     : Group-local source identifier.
%   sequencePosition: Group-local sequence position.
%   numberOfColumns : Width of the matching displayed image.
%
% Output:
%   surfaceRecord : Scalar surface result accepted by the review GUI.

surfaceRecord = struct( ...
    'sequencePosition', sequencePosition, ...
    'sourceIndex', sourceIndex, ...
    'status', 'noSurface', ...
    'surfaceCoordinatesXY', zeros(0, 2), ...
    'surfaceRowByColumn', nan(1, numberOfColumns), ...
    'rawSurfaceRowByColumn', nan(1, numberOfColumns), ...
    'observedColumnMask', false(1, numberOfColumns), ...
    'interpolatedColumnMask', false(1, numberOfColumns), ...
    'segmentIdByColumn', zeros(1, numberOfColumns, 'uint16'), ...
    'confidenceByColumn', nan(1, numberOfColumns), ...
    'numberOfSegments', 0, ...
    'observedLengthMm', 0, ...
    'interpolatedLengthMm', 0, ...
    'meanConfidence', nan);
end


function segmentationRecord = makeSegmentationRecord(sourceIndex, imageSize)
%MAKESEGMENTATIONRECORD Build one empty segmentation overlay record.
% Empty candidates avoid adding another image object, making source-image CData
% assertions deterministic while preserving the grouped matching fields.
%
% Inputs:
%   sourceIndex : Group-local source identifier.
%   imageSize   : [rows,columns] size of the displayed image.
%
% Output:
%   segmentationRecord : Scalar record accepted by the review GUI.

segmentationRecord = struct( ...
    'sourceIndex', sourceIndex, ...
    'pixelCoordinates', zeros(0, 2), ...
    'segmentationMask', false(imageSize));
end


function ultrasoundRecord = makeUltrasoundRecord(sourceIndex, intensity)
%MAKEULTRASOUNDRECORD Build one constant source image with valid geometry.
% Distinct intensities make accidental cross-group sourceIndex matching visible
% through the rendered image CData.
%
% Inputs:
%   sourceIndex : Group-local source identifier.
%   intensity   : Uint8-compatible constant displayed image intensity.
%
% Output:
%   ultrasoundRecord : Scalar sourceIndex/plane record for the review GUI.

displayedImage = uint8(intensity * ones(6, 8));
plane = struct( ...
    'image', displayedImage.', ...
    'W', 7, ...
    'H', 5, ...
    'nRows', 6, ...
    'nCols', 8);
ultrasoundRecord = struct('sourceIndex', sourceIndex, 'plane', plane);
end


function displayedImage = getDisplayedImageData(reviewFigure)
%GETDISPLAYEDIMAGEDATA Read the one B-mode image shown in the review axes.
% Empty segmentation fixtures ensure the only image object is the source image.
%
% Input:
%   reviewFigure : Grouped bone-surface review figure handle.
%
% Output:
%   displayedImage : CData matrix from the currently rendered source image.

imageAxes = findall(reviewFigure, 'Tag', 'bone_surface_review_image_axes');
imageHandles = findall(imageAxes, 'Type', 'image');
displayedImage = imageHandles(1).CData;
end


function containsRequestedText = axesContainsText(imageAxes, requestedText)
%AXESCONTAINSTEXT Check whether any axes text contains requested content.
% Inspecting each text object supports both scalar and cell-array String values.
%
% Inputs:
%   imageAxes     : Axes whose text objects should be inspected.
%   requestedText : Character or string content expected in one object.
%
% Output:
%   containsRequestedText : True when at least one text object contains it.

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
