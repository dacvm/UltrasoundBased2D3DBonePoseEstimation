function tests = testExtractBoneSurfacesFromSegmentation
% TESTEXTRACTBONESURFACESFROMSEGMENTATION Test robust bone-surface extraction.
%   TESTS = TESTEXTRACTBONESURFACESFROMSEGMENTATION creates function-based
%   MATLAB tests for the public extractor. The synthetic images isolate the
%   reflection, shadow, continuity, gap, and input-matching behaviours so a
%   regression can be diagnosed without patient data.
%
%   Outputs:
%       tests - Function-based tests discovered by MATLAB's test runner.

% Return every local test function to the MATLAB unit-test framework.
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
% SETUPONCE Add the extractor folder before this test file is run.
%   SETUPONCE(TESTCASE) records and adds the tool-specific helper folder so
%   the tests can call the public extractor. MATLAB finds its private helpers
%   without adding the private folder to the path.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase for this test file.
%
%   Outputs:
%       None. The shared test data and MATLAB path are updated in place.

% Resolve the tool directory from this test file instead of assuming MATLAB's
% current folder is the project root.
testDirectory = fileparts(mfilename('fullpath'));
extractionToolDirectory = fileparts(testDirectory);
surfaceExtractionHelperDirectory = fullfile( ...
    extractionToolDirectory, 'helpers', 'boneSegmentation_extractSurface');

% Remember whether this suite added the path so teardown preserves any path
% entry that belonged to the caller before the tests started.
testCase.TestData.surfaceExtractionHelperDirectory = ...
    surfaceExtractionHelperDirectory;
pathEntries = strsplit(path, pathsep);
testCase.TestData.addedSurfaceExtractionHelperDirectory = ...
    ~any(strcmp(pathEntries, surfaceExtractionHelperDirectory));
if testCase.TestData.addedSurfaceExtractionHelperDirectory
    addpath(surfaceExtractionHelperDirectory);
end
end

function teardownOnce(testCase)
% TEARDOWNONCE Remove the extractor folder after this test file has run.
%   TEARDOWNONCE(TESTCASE) restores the MATLAB path changed by SETUPONCE.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase containing shared data.
%
%   Outputs:
%       None. The MATLAB path is restored in place.

% Remove only paths added by this suite so caller-owned path entries remain.
if testCase.TestData.addedSurfaceExtractionHelperDirectory
    rmpath(testCase.TestData.surfaceExtractionHelperDirectory);
end
end

function testGroupedOutputCompositeMatchingAndEmptyGroups(testCase)
%TESTGROUPEDOUTPUTCOMPOSITEMATCHINGANDEMPTYGROUPS Verify the public hierarchy.
% Reordered outer groups and local ultrasound records must still match by exact
% metadata and group-local sourceIndex, including a sourceIndex repeated in a
% different group. Empty input groups must remain in the grouped output.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for verification.
%
% Outputs:
%   None. Test failures are reported through testCase.

[segmentationGroups, ultrasoundGroups] = makeGroupedExtractionFixture();

% Reorder ultrasound groups and reverse group A records to prove that neither
% outer nor local array position is used as the matching identity.
ultrasoundGroups = ultrasoundGroups([3, 1, 2]);
ultrasoundGroups(3).data = ultrasoundGroups(3).data([2, 1]);
[surfaceGroups, metadata] = extractBoneSurfacesFromSegmentation( ...
    segmentationGroups, ultrasoundGroups, struct());

verifyEqual(testCase, string({surfaceGroups.name}), ...
    string({segmentationGroups.name}));
verifyEqual(testCase, string({surfaceGroups.bone}), ...
    string({segmentationGroups.bone}));
verifyEqual(testCase, string({surfaceGroups.path}), ...
    string({segmentationGroups.path}));
verifyEqual(testCase, arrayfun( ...
    @(group) numel(group.data), surfaceGroups), [0, 2, 1]);
verifyEmpty(testCase, surfaceGroups(1).data);
verifyEqual(testCase, [surfaceGroups(2).data.sourceIndex], [1, 2]);
verifyEqual(testCase, surfaceGroups(3).data.sourceIndex, 1);
verifySurfaceNearExpected(testCase, surfaceGroups(2).data(2), ...
    repmat(47.5, 1, 71), 0.1, 0.4, 0.75);
verifySurfaceNearExpected(testCase, surfaceGroups(3).data, ...
    repmat(20.5, 1, 71), 0.1, 0.4, 0.75);
verifyEqual(testCase, metadata.numberOfFrames, 3);
verifyEqual(testCase, metadata.algorithmVersion, '1.2.0');
end


function testObsoleteFlatInputsAreRejected(testCase)
%TESTOBSOLETEFLATINPUTSAREREJECTED Verify grouped-only public validation.
% Rejecting flat records prevents repeated cross-group source indices from being
% interpreted as one global namespace.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for verification.
%
% Outputs:
%   None.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(201);
verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
    segmentationResult, ultrasoundFrame, struct()), ...
    'extractBoneSurfacesFromSegmentation:InvalidSegmentationResults');
end


function testDuplicateGroupIdentityRejected(testCase)
%TESTDUPLICATEGROUPIDENTITYREJECTED Reject ambiguous outer group metadata.
% Exact metadata matching cannot choose safely when two segmentation groups
% advertise the same name, bone, and path tuple.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for verification.
%
% Outputs:
%   None.

[segmentationGroups, ultrasoundGroups] = makeGroupedExtractionFixture();
segmentationGroups(3).name = segmentationGroups(2).name;
segmentationGroups(3).bone = segmentationGroups(2).bone;
segmentationGroups(3).path = segmentationGroups(2).path;
verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
    segmentationGroups, ultrasoundGroups, struct()), ...
    ['extractBoneSurfacesFromSegmentation:' ...
    'DuplicateSegmentationGroupIdentity']);
end


function testMissingGroupIdentityRejected(testCase)
%TESTMISSINGGROUPIDENTITYREJECTED Reject artifacts from different group sets.
% Changing one ultrasound path makes its metadata tuple unrelated even though
% its source records remain numerically compatible.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for verification.
%
% Outputs:
%   None.

[segmentationGroups, ultrasoundGroups] = makeGroupedExtractionFixture();
ultrasoundGroups(3).path = 'synthetic://unrelated';
verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
    segmentationGroups, ultrasoundGroups, struct()), ...
    'extractBoneSurfacesFromSegmentation:GroupSetMismatch');
end


function testMalformedAndAllEmptyGroupsRejected(testCase)
%TESTMALFORMEDANDALLEMPTYGROUPSREJECTED Verify grouped container invariants.
% Outer metadata/data fields must exist, and extraction needs at least one
% segmentation record even though individual groups may be empty.
%
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for verification.
%
% Outputs:
%   None.

[segmentationGroups, ultrasoundGroups] = makeGroupedExtractionFixture();
malformedGroups = rmfield(segmentationGroups, 'data');
verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
    malformedGroups, ultrasoundGroups, struct()), ...
    'extractBoneSurfacesFromSegmentation:InvalidSegmentationResults');

for groupIndex = 1:numel(segmentationGroups)
    segmentationGroups(groupIndex).data = ...
        segmentationGroups(groupIndex).data([]);
    ultrasoundGroups(groupIndex).data = ...
        ultrasoundGroups(groupIndex).data([]);
end
verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
    segmentationGroups, ultrasoundGroups, struct()), ...
    'extractBoneSurfacesFromSegmentation:NoSegmentationRecords');
end

function testFlatBandSurface(testCase)
% TESTFLATBANDSURFACE Verify a flat thick echo produces one accurate surface.
%   TESTFLATBANDSURFACE(TESTCASE) extracts a horizontal bone response and
%   checks that most scan lines remain close to its gradient-to-peak centre.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

% Use 0.1 mm pixels so pixel and physical tolerances are easy to interpret.
nRows = 100;
nColumns = 101;
xSpacingMm = 0.1;
ySpacingMm = 0.1;
expectedRows = repmat(36.5, 1, nColumns);

% Build a thick mask around a narrow bright reflection and its dark shadow.
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 14, 38);
segmentationResults = makeSegmentationResult(11, 1, segmentationMask, 'processed');
ultrasoundSequence = makeUltrasoundFrame(11, displayedImage, xSpacingMm, ySpacingMm);

% Run the public API with production defaults loaded by the extractor.
surfaceResults = extractSingleGroupSurfaceData( ...
    segmentationResults, ultrasoundSequence, struct());

% Strong flat evidence should give broad coverage and sub-millimetre error.
verifyEqual(testCase, string(surfaceResults.status), "extracted");
verifySurfaceNearExpected(testCase, surfaceResults, expectedRows, ...
    ySpacingMm, 0.35, 0.85);
end

function testCurvedVariableThicknessBand(testCase)
% TESTCURVEDVARIABLETHICKNESSBAND Verify mask thickness does not bias the path.
%   TESTCURVEDVARIABLETHICKNESSBAND(TESTCASE) uses a gently curved reflection
%   inside a mask whose depth changes by column. The chosen line should follow
%   image evidence rather than the geometric centre of the mask.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 110;
nColumns = 121;
xSpacingMm = 0.1;
ySpacingMm = 0.1;
columnPhase = linspace(0, 2 * pi, nColumns);

% Round the echo entrance while retaining the expected half-pixel location.
expectedRows = round(43 + 6 * sin(columnPhase)) + 0.5;
thicknessRows = round(15 + 8 * (0.5 + 0.5 * cos(2 * columnPhase)));
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, thicknessRows, 42);
segmentationResults = makeSegmentationResult(12, 1, segmentationMask, 'processed');
ultrasoundSequence = makeUltrasoundFrame(12, displayedImage, xSpacingMm, ySpacingMm);

surfaceResults = extractSingleGroupSurfaceData( ...
    segmentationResults, ultrasoundSequence, struct());

% A gentle curve should survive continuity regularisation without being
% pulled toward the variable mask midpoint.
verifySurfaceNearExpected(testCase, surfaceResults, expectedRows, ...
    ySpacingMm, 0.45, 0.80);
end

function testMultipleRunsPreferBoneWithShadow(testCase)
% TESTMULTIPLERUNSPREFERBONEWITHSHADOW Reject a bright no-shadow tissue run.
%   TESTMULTIPLERUNSPREFERBONEWITHSHADOW(TESTCASE) places two segmented runs
%   on every scan line. The shallower run is a bright soft-tissue artifact,
%   while the deeper run has a distal shadow and must be selected.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 140;
nColumns = 101;
xSpacingMm = 0.1;
ySpacingMm = 0.1;
artifactRows = repmat(22.5, 1, nColumns);
boneRows = repmat(82.5, 1, nColumns);

% Start with a real bone response, then add a separate bright run without a
% dark region below it. The large separation prevents the real bone shadow
% from accidentally becoming evidence for the artifact.
[displayedImage, boneMask] = makeBoneBandImage( ...
    nRows, nColumns, boneRows, 15, 42);
[displayedImage, artifactMask] = addBrightRunWithoutShadow( ...
    displayedImage, artifactRows, 10);
segmentationMask = boneMask | artifactMask;

segmentationResults = makeSegmentationResult(13, 1, segmentationMask, 'processed');
ultrasoundSequence = makeUltrasoundFrame(13, displayedImage, xSpacingMm, ySpacingMm);

% Increase the shadow term for this focused discrimination test while all
% other production defaults remain unchanged.
options = struct();
options.imageEvidence = struct( ...
    'weights', struct('shadow', 2.0, 'reflection', 0.5));
options.surfaceTracing = struct('evidenceThreshold', 0.05);
surfaceResults = extractSingleGroupSurfaceData( ...
    segmentationResults, ultrasoundSequence, options);

% The selected path should remain near the deeper bone run, not merely the
% first or brightest mask component.
verifySurfaceNearExpected(testCase, surfaceResults, boneRows, ...
    ySpacingMm, 0.5, 0.75);
selectedRows = surfaceResults.surfaceRowByColumn( ...
    surfaceResults.observedColumnMask);
verifyGreaterThan(testCase, median(selectedRows), 60);
end

function testGapInterpolationBoundary(testCase)
% TESTGAPINTERPOLATIONBOUNDARY Verify 4.9 mm is bridged and 5.1 mm is not.
%   TESTGAPINTERPOLATIONBOUNDARY(TESTCASE) removes 49 and 51 columns from an
%   otherwise continuous response at 0.1 mm spacing. It checks the exact
%   physical gap policy and the explicit interpolation flags.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

% The surrounding observed sections are longer than the 2 mm retention gate.
[shortGapResult, shortGapColumns] = extractSyntheticGap(49, 31);
[longGapResult, longGapColumns] = extractSyntheticGap(51, 32);
disabledOptions = struct( ...
    'regularization', struct('enabled', false));
shortGapDisabled = extractSyntheticGap(49, 33, disabledOptions);
longGapDisabled = extractSyntheticGap(51, 34, disabledOptions);

% All missing columns in a 4.9 mm gap must be supplied only by interpolation.
verifyTrue(testCase, all(shortGapResult.interpolatedColumnMask(shortGapColumns)));
verifyFalse(testCase, any(shortGapResult.observedColumnMask(shortGapColumns)));
verifyTrue(testCase, all(isfinite(shortGapResult.surfaceRowByColumn(shortGapColumns))));
verifyEqual(testCase, shortGapResult.observedColumnMask, ...
    shortGapDisabled.observedColumnMask);
verifyEqual(testCase, shortGapResult.interpolatedColumnMask, ...
    shortGapDisabled.interpolatedColumnMask);
verifyEqual(testCase, shortGapResult.segmentIdByColumn, ...
    shortGapDisabled.segmentIdByColumn);

% A 5.1 mm gap remains explicit and separates the observed paths.
verifyFalse(testCase, any(longGapResult.interpolatedColumnMask(longGapColumns)));
verifyTrue(testCase, all(isnan(longGapResult.surfaceRowByColumn(longGapColumns))));
segmentIds = unique(longGapResult.segmentIdByColumn);
segmentIds(segmentIds == 0) = [];
verifyEqual(testCase, numel(segmentIds), 2);
verifyEqual(testCase, longGapResult.observedColumnMask, ...
    longGapDisabled.observedColumnMask);
verifyEqual(testCase, longGapResult.interpolatedColumnMask, ...
    longGapDisabled.interpolatedColumnMask);
verifyEqual(testCase, longGapResult.segmentIdByColumn, ...
    longGapDisabled.segmentIdByColumn);
end

function testEmptyCoordinatesAndUnprocessedRecords(testCase)
% TESTEMPTYCOORDINATESANDUNPROCESSEDRECORDS Verify empty and skipped states.
%   TESTEMPTYCOORDINATESANDUNPROCESSEDRECORDS(TESTCASE) checks that a
%   processed record with no exported boundary candidates becomes NOSURFACE,
%   even when its stored mask is nonempty. An unprocessed record remains
%   skipped even when it contains valid boundary coordinates.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 80;
nColumns = 81;
expectedRows = repmat(34.5, 1, nColumns);
[displayedImage, nonEmptyMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 10, 30);

segmentationResults(1) = makeSegmentationResult(41, 1, nonEmptyMask, 'processed');
segmentationResults(1).pixelCoordinates = zeros(0, 2);
segmentationResults(2) = makeSegmentationResult(42, 2, nonEmptyMask, 'pending');
ultrasoundSequence(1) = makeUltrasoundFrame(41, displayedImage, 0.1, 0.1);
ultrasoundSequence(2) = makeUltrasoundFrame(42, displayedImage, 0.1, 0.1);

surfaceResults = extractSingleGroupSurfaceData( ...
    segmentationResults, ultrasoundSequence, struct());

verifyEqual(testCase, string(surfaceResults(1).status), "noSurface");
verifyTrue(testCase, all(isnan(surfaceResults(1).surfaceRowByColumn)));
verifyEmpty(testCase, surfaceResults(1).surfaceCoordinatesXYZRef);
verifyEqual(testCase, string(surfaceResults(2).status), "skippedUnprocessed");
verifyFalse(testCase, any(surfaceResults(2).observedColumnMask));
verifyFalse(testCase, any(surfaceResults(2).interpolatedColumnMask));
verifyEmpty(testCase, surfaceResults(2).surfaceCoordinatesXYZRef);
end

function testShuffledSourceIndexMatching(testCase)
% TESTSHUFFLEDSOURCEINDEXMATCHING Verify frames are joined by sourceIndex.
%   TESTSHUFFLEDSOURCEINDEXMATCHING(TESTCASE) reverses the ultrasound array
%   relative to the segmentation array. Different surface depths make an
%   accidental positional match visible.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 100;
nColumns = 91;
shallowRows = repmat(28.5, 1, nColumns);
deepRows = repmat(62.5, 1, nColumns);
[shallowImage, shallowMask] = makeBoneBandImage( ...
    nRows, nColumns, shallowRows, 12, 30);
[deepImage, deepMask] = makeBoneBandImage( ...
    nRows, nColumns, deepRows, 12, 30);

segmentationResults(1) = makeSegmentationResult(51, 7, shallowMask, 'processed');
segmentationResults(2) = makeSegmentationResult(52, 8, deepMask, 'processed');

% Reverse the source-image order on purpose.
ultrasoundSequence(1) = makeUltrasoundFrame(52, deepImage, 0.1, 0.1);
ultrasoundSequence(2) = makeUltrasoundFrame(51, shallowImage, 0.1, 0.1);

surfaceResults = extractSingleGroupSurfaceData( ...
    segmentationResults, ultrasoundSequence, struct());

verifyEqual(testCase, [surfaceResults.sourceIndex], [51, 52]);
verifyEqual(testCase, [surfaceResults.sequencePosition], [7, 8]);
verifySurfaceNearExpected(testCase, surfaceResults(1), shallowRows, 0.1, 0.4, 0.75);
verifySurfaceNearExpected(testCase, surfaceResults(2), deepRows, 0.1, 0.4, 0.75);
end

function testDuplicateSegmentationSourceIndexRejected(testCase)
% TESTDUPLICATESEGMENTATIONSOURCEINDEXREJECTED Reject ambiguous masks.
%   TESTDUPLICATESEGMENTATIONSOURCEINDEXREJECTED(TESTCASE) confirms that two
%   segmentation records cannot claim the same source image.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(61);
segmentationResults = [segmentationResult, segmentationResult];
segmentationResults(2).sequencePosition = 2;

verifyError(testCase, @() extractSingleGroupSurfaceData( ...
    segmentationResults, ultrasoundFrame, struct()), ...
    'extractBoneSurfacesFromSegmentation:DuplicateSegmentationSourceIndex');
end

function testDuplicateUltrasoundSourceIndexRejected(testCase)
% TESTDUPLICATEULTRASOUNDSOURCEINDEXREJECTED Reject ambiguous source images.
%   TESTDUPLICATEULTRASOUNDSOURCEINDEXREJECTED(TESTCASE) confirms that a
%   sourceIndex must identify exactly one ultrasound frame.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(62);
ultrasoundSequence = [ultrasoundFrame, ultrasoundFrame];

verifyError(testCase, @() extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundSequence, struct()), ...
    'extractBoneSurfacesFromSegmentation:DuplicateUltrasoundSourceIndex');
end

function testMismatchedFrameSetRejected(testCase)
% TESTMISMATCHEDFRAMESETREJECTED Reject unequal group-local source sets.
%   TESTMISMATCHEDFRAMESETREJECTED(TESTCASE) uses different source indices
%   and verifies that exact grouped inputs cannot be silently paired by order.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ~] = makeSimpleFixture(63);
[~, ultrasoundFrame] = makeSimpleFixture(64);

verifyError(testCase, @() extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, struct()), ...
    'extractBoneSurfacesFromSegmentation:FrameSetMismatch');
end

function testSegmentationMasksAreNotRequired(testCase)
% TESTSEGMENTATIONMASKSARENOTREQUIRED Accept coordinate-only production data.
%   TESTSEGMENTATIONMASKSARENOTREQUIRED(TESTCASE) removes every stored mask
%   field while retaining exported boundary coordinates. Extraction must use
%   those coordinates without reconstructing or requesting a filled region.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(65);
segmentationResult = rmfield(segmentationResult, { ...
    'segmentationMask', 'segmentationAreaMask', ...
    'usesCustomSegmentationArea'});

surfaceResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, struct());

verifyEqual(testCase, string(surfaceResult.status), "extracted");
verifyTrue(testCase, any(surfaceResult.observedColumnMask));
end

function testPixelCoordinatesAreAuthoritative(testCase)
% TESTPIXELCOORDINATESAREAUTHORITATIVE Ignore contradictory stored masks.
%   TESTPIXELCOORDINATESAREAUTHORITATIVE(TESTCASE) extracts the same boundary
%   coordinates with their original region masks and with all-false masks.
%   Every output must remain identical, proving candidate likelihood, DP,
%   interpolation, and refinement consume only pixelCoordinates.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(67);
baselineResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, struct());

% These masks directly contradict every exported coordinate. They remain in
% the production-shaped record only to prove they cannot gate any computation.
contradictoryResult = segmentationResult;
contradictoryResult.segmentationMask(:) = false;
contradictoryResult.segmentationAreaMask(:) = false;
contradictoryResult.usesCustomSegmentationArea = true;
coordinateOnlyResult = extractSingleGroupSurfaceData( ...
    contradictoryResult, ultrasoundFrame, struct());

verifyEqual(testCase, coordinateOnlyResult, baselineResult);
end

function testCoordinateOrderAndDuplicatesDoNotChangeResult(testCase)
% TESTCOORDINATEORDERANDDUPLICATESDONOTCHANGERESULT Normalize candidate input.
%   TESTCOORDINATEORDERANDDUPLICATESDONOTCHANGERESULT(TESTCASE) reverses the
%   exported boundary order and repeats several valid pairs. Candidate-set
%   construction must be idempotent and independent of storage order.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(68);
baselineResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, struct());

coordinates = segmentationResult.pixelCoordinates;
numberRepeated = min(20, size(coordinates, 1));
reorderedResult = segmentationResult;
reorderedResult.pixelCoordinates = [ ...
    flipud(coordinates); coordinates(1:numberRepeated, :)];
actualResult = extractSingleGroupSurfaceData( ...
    reorderedResult, ultrasoundFrame, struct());

verifyEqual(testCase, actualResult, baselineResult);
end

function testInvalidPixelCoordinatesRejected(testCase)
% TESTINVALIDPIXELCOORDINATESREJECTED Reject malformed candidate arrays.
%   TESTINVALIDPIXELCOORDINATESREJECTED(TESTCASE) checks shape, numeric type,
%   finiteness, integer indexing, and image bounds. Clear rejection prevents
%   row/column swaps or corrupt exported data from becoming plausible curves.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(69);
nRows = ultrasoundFrame.plane.nRows;
nColumns = ultrasoundFrame.plane.nCols;
validCoordinate = segmentationResult.pixelCoordinates(1, :);

invalidCoordinateArrays = { ...
    zeros(0, 3), ...
    'not numeric', ...
    [nan, validCoordinate(2)], ...
    [inf, validCoordinate(2)], ...
    [validCoordinate(1) + 0.5, validCoordinate(2)], ...
    [0, validCoordinate(2)], ...
    [nRows + 1, validCoordinate(2)], ...
    [validCoordinate(1), 0], ...
    [validCoordinate(1), nColumns + 1]};

for invalidIndex = 1:numel(invalidCoordinateArrays)
    invalidResult = segmentationResult;
    invalidResult.pixelCoordinates = ...
        invalidCoordinateArrays{invalidIndex};
    verifyError(testCase, @() extractSingleGroupSurfaceData( ...
        invalidResult, ultrasoundFrame, struct()), ...
        'extractBoneSurfacesFromSegmentation:InvalidPixelCoordinates');
end

missingCoordinateResult = rmfield(segmentationResult, 'pixelCoordinates');
verifyError(testCase, @() extractSingleGroupSurfaceData( ...
    missingCoordinateResult, ultrasoundFrame, struct()), ...
    'extractBoneSurfacesFromSegmentation:InvalidSegmentationResults');
end

function testInvalidPlaneGeometryRejected(testCase)
% TESTINVALIDPLANEGEOMETRYREJECTED Reject unusable physical dimensions.
%   TESTINVALIDPLANEGEOMETRYREJECTED(TESTCASE) sets the image width to zero,
%   which would make lateral spacing invalid for the path penalty.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(66);
ultrasoundFrame.plane.W = 0;

verifyError(testCase, @() extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, struct()), ...
    'extractBoneSurfacesFromSegmentation:InvalidPlaneGeometry');
end

function testBottomTruncatedShadowWindow(testCase)
% TESTBOTTOMTRUNCATEDSHADOWWINDOW Verify safe extraction near the image bottom.
%   TESTBOTTOMTRUNCATEDSHADOWWINDOW(TESTCASE) places a bone echo close to the
%   final row, where the configured 4 mm shadow window cannot be complete.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 88;
nColumns = 101;
expectedRows = repmat(80.5, 1, nColumns);
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 8, 20);
segmentationResults = makeSegmentationResult(71, 1, segmentationMask, 'processed');
ultrasoundSequence = makeUltrasoundFrame(71, displayedImage, 0.1, 0.1);

surfaceResults = extractSingleGroupSurfaceData( ...
    segmentationResults, ultrasoundSequence, struct());

% A clipped shadow window carries less evidence but must not cause indexing
% errors or remove an otherwise strong, long reflection.
verifySurfaceNearExpected(testCase, surfaceResults, expectedRows, 0.1, 0.5, 0.70);
end

function testCustomAreaCutEdgeIsNotCandidate(testCase)
% TESTCUSTOMAREACUTEDGEISNOTCANDIDATE Honor exported boundary coordinates.
%   TESTCUSTOMAREACUTEDGEISNOTCANDIDATE(TESTCASE) clips a rectangular region
%   through its interior. The stored clipped mask gains an artificial edge,
%   while production pixelCoordinates correctly retain only the original
%   perimeter points inside the selected area. Even a bright artificial edge
%   must never become an observed surface candidate.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 100;
nColumns = 121;
xSpacingMm = 0.1;
ySpacingMm = 0.1;
expectedRows = repmat(30.5, 1, nColumns);
[displayedImage, fullWidthMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 31, 35);

% Restrict the full segmentation laterally, then cut it at row 45. The new
% row-45 mask perimeter is not part of the UI's exported coordinate list.
fullSegmentationMask = false(nRows, nColumns);
fullSegmentationMask(:, 11:111) = fullWidthMask(:, 11:111);
segmentationAreaMask = false(nRows, nColumns);
segmentationAreaMask(1:45, :) = true;
clippedSegmentationMask = ...
    fullSegmentationMask & segmentationAreaMask;

segmentationResult = makeSegmentationResult(70, 1, ...
    fullSegmentationMask, 'processed');
coordinateLinearIndices = sub2ind(size(segmentationAreaMask), ...
    segmentationResult.pixelCoordinates(:, 1), ...
    segmentationResult.pixelCoordinates(:, 2));
keepCoordinate = segmentationAreaMask(coordinateLinearIndices);
segmentationResult.pixelCoordinates = ...
    segmentationResult.pixelCoordinates(keepCoordinate, :);
segmentationResult.segmentationMask = clippedSegmentationMask;
segmentationResult.segmentationAreaMask = segmentationAreaMask;
segmentationResult.usesCustomSegmentationArea = true;

% Paint a very attractive response on the artificial cut. A mask-perimeter
% reconstruction would expose it to DP, but the exported coordinates do not.
displayedImage(45, 12:110) = 0.78;
displayedImage(46, 12:110) = 1.00;
displayedImage(47, 12:110) = 0.64;
displayedImage(48:82, 12:110) = 0.025;
ultrasoundFrame = makeUltrasoundFrame( ...
    70, displayedImage, xSpacingMm, ySpacingMm);
options = struct( ...
    'surfaceTracing', struct( ...
        'evidenceThreshold', 0.05, ...
        'minimumMeanSegmentConfidence', 0.05));

surfaceResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, options);

artificialCutPairs = [ ...
    repmat(45, 99, 1), (12:110).'];
verifyFalse(testCase, any(ismember(artificialCutPairs, ...
    segmentationResult.pixelCoordinates, 'rows')));

interiorColumns = 20:102;
interiorObserved = surfaceResult.observedColumnMask(interiorColumns);
verifyGreaterThanOrEqual(testCase, mean(interiorObserved), 0.90);
rawInteriorRows = surfaceResult.rawSurfaceRowByColumn(interiorColumns);
verifyEqual(testCase, rawInteriorRows(interiorObserved), ...
    repmat(30, 1, nnz(interiorObserved)));
end

function testMaskGapDoesNotCreateCoordinateGap(testCase)
% TESTMASKGAPDOESNOTCREATECOORDINATEGAP Ignore missing stored-mask columns.
%   TESTMASKGAPDOESNOTCREATECOORDINATEGAP(TESTCASE) deletes a 5.1 mm region
%   from both stored masks while preserving continuous pixelCoordinates. The
%   observed path and all refinement outputs must remain exactly unchanged.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 90;
nColumns = 181;
expectedRows = repmat(37.5, 1, nColumns);
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 14, 35);
segmentationResult = makeSegmentationResult(80, 1, ...
    segmentationMask, 'processed');
ultrasoundFrame = makeUltrasoundFrame( ...
    80, displayedImage, 0.1, 0.1);
baselineResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, struct());

maskGapColumns = 61:111;
maskedResult = segmentationResult;
maskedResult.segmentationMask(:, maskGapColumns) = false;
maskedResult.segmentationAreaMask(:, maskGapColumns) = false;
actualResult = extractSingleGroupSurfaceData( ...
    maskedResult, ultrasoundFrame, struct());

verifyEqual(testCase, actualResult, baselineResult);
verifyTrue(testCase, ...
    all(actualResult.observedColumnMask(maskGapColumns)));
verifyFalse(testCase, ...
    any(actualResult.interpolatedColumnMask(maskGapColumns)));
end

function testBranchingDeepValleyRegularization(testCase)
% TESTBRANCHINGDEEPVALLEYREGULARIZATION Smooth erratic mask-supported paths.
%   TESTBRANCHINGDEEPVALLEYREGULARIZATION(TESTCASE) builds a narrow,
%   rapidly changing response with an extra downward valley and disconnected
%   segmentation branches. The raw trace must retain that image-supported
%   evidence, while the final trace should recover the smooth underlying
%   surface without violating the configured displacement bound.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame, expectedRows, ySpacingMm] = ...
    makeErraticRefinementFixture(72, 0.1);
options = makeRefinementTestOptions();

surfaceResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, options);

% This fixture is intentionally rough enough that a skipped or ineffective
% second stage cannot pass merely because the original DP already smoothed it.
verifyEqual(testCase, string(surfaceResult.regularizationStatus), "applied");
verifyGreaterThan(testCase, surfaceResult.roughnessBeforePerMm, 0);
verifyLessThanOrEqual(testCase, surfaceResult.roughnessAfterPerMm, ...
    0.30 * surfaceResult.roughnessBeforePerMm);

validMask = isfinite(surfaceResult.surfaceRowByColumn);
finalErrorMm = (surfaceResult.surfaceRowByColumn(validMask) - ...
    expectedRows(validMask)) * ySpacingMm;
verifyLessThanOrEqual(testCase, sqrt(mean(finalErrorMm .^ 2)), 0.25);
verifyLessThanOrEqual(testCase, ...
    surfaceResult.regularizationMaxDisplacementMm, 0.75 + 1e-8);
end

function testDiagonalSlopePreserved(testCase)
% TESTDIAGONALSLOPEPRESERVED Preserve a legitimate inclined bone surface.
%   TESTDIAGONALSLOPEPRESERVED(TESTCASE) extracts a long diagonal response
%   and verifies that curvature regularization does not confuse constant
%   slope with high-frequency roughness.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 120;
nColumns = 161;
xSpacingMm = 0.1;
ySpacingMm = 0.1;
xCoordinatesMm = (0:(nColumns - 1)) * xSpacingMm;

% Quantization creates a realistic staircase while the physical trend stays
% linear. A second-derivative penalty should remove the staircase, not tilt it.
expectedRows = round(34 + 2.2 * xCoordinatesMm) + 0.5;
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 12, 38);
segmentationResult = makeSegmentationResult(73, 1, ...
    segmentationMask, 'processed');
ultrasoundFrame = makeUltrasoundFrame(73, displayedImage, ...
    xSpacingMm, ySpacingMm);

surfaceResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, struct());
validMask = isfinite(surfaceResult.surfaceRowByColumn);
rawDepthMm = surfaceResult.rawSurfaceRowByColumn(validMask) * ySpacingMm;
finalDepthMm = surfaceResult.surfaceRowByColumn(validMask) * ySpacingMm;
validXCoordinatesMm = xCoordinatesMm(validMask);
rawLine = polyfit(validXCoordinatesMm, rawDepthMm, 1);
finalLine = polyfit(validXCoordinatesMm, finalDepthMm, 1);

verifyEqual(testCase, string(surfaceResult.regularizationStatus), "applied");
verifyGreaterThan(testCase, abs(rawLine(1)), 0.05);
verifyLessThanOrEqual(testCase, ...
    abs(finalLine(1) - rawLine(1)) / abs(rawLine(1)), 0.05);
end

function testBroadCurvaturePreserved(testCase)
% TESTBROADCURVATUREPRESERVED Retain anatomy wider than the smoothing scale.
%   TESTBROADCURVATUREPRESERVED(TESTCASE) uses a sinusoidal response whose
%   wavelength is much wider than 2.5 mm. The final fit may remove pixel
%   stair-steps but must retain at least 90 percent of the broad curvature.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 110;
nColumns = 181;
xSpacingMm = 0.1;
ySpacingMm = 0.1;
xCoordinatesMm = (0:(nColumns - 1)) * xSpacingMm;
curvatureWavelengthMm = 12;
expectedRows = round(48 + 6 * sin( ...
    2 * pi * xCoordinatesMm / curvatureWavelengthMm)) + 0.5;
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 14, 38);
segmentationResult = makeSegmentationResult(74, 1, ...
    segmentationMask, 'processed');
ultrasoundFrame = makeUltrasoundFrame(74, displayedImage, ...
    xSpacingMm, ySpacingMm);

surfaceResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, struct());
validMask = isfinite(surfaceResult.surfaceRowByColumn);
rawAmplitudeMm = estimatePeriodicAmplitude( ...
    xCoordinatesMm(validMask), ...
    surfaceResult.rawSurfaceRowByColumn(validMask) * ySpacingMm, ...
    curvatureWavelengthMm);
finalAmplitudeMm = estimatePeriodicAmplitude( ...
    xCoordinatesMm(validMask), ...
    surfaceResult.surfaceRowByColumn(validMask) * ySpacingMm, ...
    curvatureWavelengthMm);

verifyGreaterThan(testCase, rawAmplitudeMm, 0.4);
verifyGreaterThanOrEqual(testCase, finalAmplitudeMm, ...
    0.90 * rawAmplitudeMm);
end

function testRegularizationUsesPhysicalLateralSpacing(testCase)
% TESTREGULARIZATIONUSESPHYSICALLATERALSPACING Check resolution invariance.
%   TESTREGULARIZATIONUSESPHYSICALLATERALSPACING(TESTCASE) samples the same
%   physical response at 0.1 and 0.2 mm lateral spacing. The two refined
%   depths should agree at their shared physical positions.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[fineResult, fineXCoordinatesMm, ySpacingMm] = ...
    extractPhysicalSpacingFixture(75, 0.1);
[coarseResult, coarseXCoordinatesMm] = ...
    extractPhysicalSpacingFixture(76, 0.2);

% Coarse coordinates are an exact subset of the fine grid. Interpolation is
% still used here to express the comparison in physical rather than index space.
fineDepthMm = fineResult.surfaceRowByColumn * ySpacingMm;
coarseDepthMm = coarseResult.surfaceRowByColumn * ySpacingMm;
fineDepthAtCoarseMm = interp1(fineXCoordinatesMm, fineDepthMm, ...
    coarseXCoordinatesMm, 'linear');
sharedMask = isfinite(fineDepthAtCoarseMm) & isfinite(coarseDepthMm);
spacingDifferenceMm = fineDepthAtCoarseMm(sharedMask) - ...
    coarseDepthMm(sharedMask);

verifyGreaterThanOrEqual(testCase, mean(sharedMask), 0.90);
verifyLessThanOrEqual(testCase, ...
    sqrt(mean(spacingDifferenceMm .^ 2)), 0.10);
end

function testDisabledRegularizationMatchesRawStageExactly(testCase)
% TESTDISABLEDREGULARIZATIONMATCHESRAWSTAGEEXACTLY Preserve legacy output.
%   TESTDISABLEDREGULARIZATIONMATCHESRAWSTAGEEXACTLY(TESTCASE) compares an
%   explicitly disabled run with the raw DP/PCHIP audit fields from an
%   enabled run. This verifies that refinement does not alter the first stage
%   and that disabling it reproduces that legacy result without rounding.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = ...
    makeErraticRefinementFixture(77, 0.1);
enabledOptions = makeRefinementTestOptions();
disabledOptions = enabledOptions;
disabledOptions.regularization.enabled = false;

enabledResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, enabledOptions);
[disabledResult, ~] = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, disabledOptions);

verifyEqual(testCase, string(disabledResult.regularizationStatus), "disabled");
verifyTrue(testCase, isequaln(disabledResult.surfaceRowByColumn, ...
    enabledResult.rawSurfaceRowByColumn));
verifyTrue(testCase, isequaln(disabledResult.confidenceByColumn, ...
    enabledResult.rawConfidenceByColumn));
verifyTrue(testCase, isequaln(disabledResult.surfaceRowByColumn, ...
    disabledResult.rawSurfaceRowByColumn));
verifyTrue(testCase, isequaln(disabledResult.confidenceByColumn, ...
    disabledResult.rawConfidenceByColumn));
verifyEqual(testCase, disabledResult.observedColumnMask, ...
    enabledResult.observedColumnMask);
verifyEqual(testCase, disabledResult.interpolatedColumnMask, ...
    enabledResult.interpolatedColumnMask);
verifyEqual(testCase, disabledResult.segmentIdByColumn, ...
    enabledResult.segmentIdByColumn);
end

function testConfidenceDecayAndDisplacementBound(testCase)
% TESTCONFIDENCEDECAYANDDISPLACEMENTBOUND Audit bounded path movement.
%   TESTCONFIDENCEDECAYANDDISPLACEMENTBOUND(TESTCASE) uses a narrow zig-zag
%   candidate boundary that forces the raw path away from a flat surface. The
%   refined curve must reduce confidence according to physical displacement
%   and stop at the configured raw-path bound when necessary.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 100;
nColumns = 141;
xSpacingMm = 0.1;
ySpacingMm = 0.1;
columnIndices = 1:nColumns;
rawOffsetsRows = 10 * sign(sin(2 * pi * columnIndices / 10));
rawOffsetsRows(rawOffsetsRows == 0) = 10;
rawTargetRows = 48.5 + rawOffsetsRows;
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, rawTargetRows, 3, 35);
segmentationResult = makeSegmentationResult(78, 1, ...
    segmentationMask, 'processed');
ultrasoundFrame = makeUltrasoundFrame(78, displayedImage, ...
    xSpacingMm, ySpacingMm);
options = makeRefinementTestOptions();

surfaceResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, options);
observedMask = logical(surfaceResult.observedColumnMask);

observedDisplacementMm = abs( ...
    surfaceResult.regularizationDisplacementMmByColumn(observedMask));
expectedConfidence = surfaceResult.rawConfidenceByColumn(observedMask) .* ...
    exp(-observedDisplacementMm / ...
        options.regularization.maximumDisplacementMm);
verifyEqual(testCase, surfaceResult.confidenceByColumn(observedMask), ...
    expectedConfidence, 'AbsTol', 1e-10);
verifyLessThanOrEqual(testCase, observedDisplacementMm, ...
    options.regularization.maximumDisplacementMm + 1e-8);

% The deliberately incompatible alternating corridors require some points
% to stop at the raw-displacement cap, exercising the bound-hit audit field.
observedBoundHits = surfaceResult. ...
    regularizationBoundHitColumnMask(observedMask);
verifyTrue(testCase, any(observedBoundHits));
verifyEqual(testCase, observedDisplacementMm(observedBoundHits), ...
    repmat(options.regularization.maximumDisplacementMm, ...
    1, nnz(observedBoundHits)), ...
    'AbsTol', options.regularization.convergenceMm);
end

function testSolverFailureRetainsRawSegment(testCase)
% TESTSOLVERFAILURERETAINSRAWSEGMENT Verify safe numerical fallback.
%   TESTSOLVERFAILURERETAINSRAWSEGMENT(TESTCASE) temporarily places a
%   deliberately failing QUADPROG shim first on the MATLAB path. The public
%   extractor must warn, mark the frame as a fallback, and preserve every raw
%   surface and confidence value instead of returning a partial curve.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(79);
temporaryDirectory = tempname;
mkdir(temporaryDirectory);
writeFailingQuadprogShim(temporaryDirectory);

% Cleanup also clears MATLAB's function cache so later tests resolve the real
% Optimization Toolbox implementation even when this verification fails.
cleanupTemporaryShim = onCleanup( ...
    @() removeFailingQuadprogShim(temporaryDirectory));
addpath(temporaryDirectory, '-begin');
rehash path;
clear quadprog;

lastwarn('');
surfaceResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, struct());
[warningMessage, warningIdentifier] = lastwarn;

verifyEqual(testCase, warningIdentifier, ...
    'extractBoneSurfacesFromSegmentation:RegularizationFallback');
verifyThat(testCase, warningMessage, ...
    matlab.unittest.constraints.ContainsSubstring('sourceIndex 79'));
verifyEqual(testCase, string(surfaceResult.regularizationStatus), "fallback");
verifyTrue(testCase, isequaln(surfaceResult.surfaceRowByColumn, ...
    surfaceResult.rawSurfaceRowByColumn));
verifyTrue(testCase, isequaln(surfaceResult.confidenceByColumn, ...
    surfaceResult.rawConfidenceByColumn));
fallbackDisplacementMm = ...
    surfaceResult.regularizationDisplacementMmByColumn( ...
    isfinite(surfaceResult.surfaceRowByColumn));
verifyTrue(testCase, all(fallbackDisplacementMm == 0));
verifyFalse(testCase, ...
    any(surfaceResult.regularizationBoundHitColumnMask));
end

function testOutputInterfaceAndInvariants(testCase)
% TESTOUTPUTINTERFACEANDINVARIANTS Verify the documented result contract.
%   TESTOUTPUTINTERFACEANDINVARIANTS(TESTCASE) checks coordinates, flags,
%   confidences, segment labels, diagnostics, and metadata on a path with a
%   short interpolated gap.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 100;
nColumns = 121;
expectedRows = round(42 + 4 * sin(linspace(0, pi, nColumns))) + 0.5;
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 16, 38);
gapColumns = 52:60;
segmentationResults = makeSegmentationResult(81, 3, segmentationMask, 'processed');
keepCoordinate = ~ismember( ...
    segmentationResults.pixelCoordinates(:, 2), gapColumns);
segmentationResults.pixelCoordinates = ...
    segmentationResults.pixelCoordinates(keepCoordinate, :);
segmentationResultsBeforeExtraction = segmentationResults;
ultrasoundSequence = makeUltrasoundFrame(81, displayedImage, 0.1, 0.1);
options = makeRefinementTestOptions();

[surfaceResults, extractionMetadata] = extractSingleGroupSurfaceData( ...
    segmentationResults, ultrasoundSequence, options);

% The second-stage extractor must not rewrite the semi-automatic result.
verifyEqual(testCase, segmentationResults, segmentationResultsBeforeExtraction);

requiredFields = {'sequencePosition', 'sourceIndex', 'status', ...
    'surfaceCoordinatesXY', 'surfaceCoordinatesXYZRef', ...
    'surfaceRowByColumn', ...
    'rawSurfaceRowByColumn', 'rawConfidenceByColumn', ...
    'observedColumnMask', 'interpolatedColumnMask', ...
    'segmentIdByColumn', 'confidenceByColumn', 'pixelSpacingXYMm', ...
    'regularizationDisplacementMmByColumn', ...
    'regularizationBoundHitColumnMask', ...
    'regularizationStatus', 'roughnessBeforePerMm', ...
    'roughnessAfterPerMm', 'regularizationRmsDisplacementMm', ...
    'regularizationMaxDisplacementMm', ...
    'observedLengthMm', 'interpolatedLengthMm', 'meanConfidence', ...
    'numberOfSegments'};
verifyTrue(testCase, all(isfield(surfaceResults, requiredFields)));

% Extraction reserves the field without inventing a coordinate. Recovery will
% replace this empty value with an N-by-3 array in the reference frame.
verifyEmpty(testCase, surfaceResults.surfaceCoordinatesXYZRef);

% Keep the 2D and 3D coordinate fields next to each other in the public schema
% so their relationship remains clear when records are inspected or saved.
resultFieldNames = fieldnames(surfaceResults);
surfaceCoordinateFieldIndex = find( ...
    strcmp(resultFieldNames, 'surfaceCoordinatesXY'), 1);
verifyEqual(testCase, ...
    resultFieldNames{surfaceCoordinateFieldIndex + 1}, ...
    'surfaceCoordinatesXYZRef');
removedMaskAuditFields = {'outsideSegmentationColumnMask', ...
    'outsideSegmentationFraction'};
verifyFalse(testCase, any(isfield(surfaceResults, removedMaskAuditFields)));

% A column can be observed, interpolated, or absent, but never two at once.
observedMask = logical(surfaceResults.observedColumnMask(:).');
interpolatedMask = logical(surfaceResults.interpolatedColumnMask(:).');
surfaceRows = surfaceResults.surfaceRowByColumn(:).';
rawSurfaceRows = surfaceResults.rawSurfaceRowByColumn(:).';
confidence = surfaceResults.confidenceByColumn(:).';
rawConfidence = surfaceResults.rawConfidenceByColumn(:).';
displacementMm = ...
    surfaceResults.regularizationDisplacementMmByColumn(:).';
boundHitMask = logical( ...
    surfaceResults.regularizationBoundHitColumnMask(:).');
segmentIds = surfaceResults.segmentIdByColumn(:).';
verifyEqual(testCase, numel(surfaceRows), nColumns);
verifyFalse(testCase, any(observedMask & interpolatedMask));
verifyEqual(testCase, isfinite(surfaceRows), observedMask | interpolatedMask);
verifyEqual(testCase, isfinite(rawSurfaceRows), observedMask | interpolatedMask);
verifyTrue(testCase, all(segmentIds(~isfinite(surfaceRows)) == 0));
verifyTrue(testCase, all(isnan(confidence(~isfinite(surfaceRows)))));
verifyTrue(testCase, all(isnan(rawConfidence(~isfinite(rawSurfaceRows)))));
verifyGreaterThanOrEqual(testCase, confidence(isfinite(surfaceRows)), 0);
verifyLessThanOrEqual(testCase, confidence(isfinite(surfaceRows)), 1);
verifyGreaterThanOrEqual(testCase, rawConfidence(isfinite(rawSurfaceRows)), 0);
verifyLessThanOrEqual(testCase, rawConfidence(isfinite(rawSurfaceRows)), 1);

% Displacement is expressed in axial millimetres and is bounded for every
% finite point. Diagnostic masks must never label an absent surface column.
expectedDisplacementMm = (surfaceRows - rawSurfaceRows) * ...
    surfaceResults.pixelSpacingXYMm(2);
verifyEqual(testCase, displacementMm, expectedDisplacementMm, ...
    'AbsTol', 1e-10);
verifyFalse(testCase, any(boundHitMask & ~isfinite(surfaceRows)));
verifyLessThanOrEqual(testCase, abs(displacementMm(isfinite(surfaceRows))), ...
    options.regularization.maximumDisplacementMm + 1e-8);

% Every raw observed point must be one of the exported boundary candidates.
% This is stronger than mask membership and catches accidental use of filled
% segmentation regions or artificial custom-area cut edges.
observedColumns = find(observedMask);
rawObservedRows = rawSurfaceRows(observedMask).';
verifyEqual(testCase, rawObservedRows, round(rawObservedRows));
rawObservedPairs = [rawObservedRows, observedColumns(:)];
verifyTrue(testCase, all(ismember(rawObservedPairs, ...
    segmentationResults.pixelCoordinates, 'rows')));

% Final observed confidence decays from its raw value based only on the
% bounded physical movement made by regularization.
maximumDisplacementMm = options.regularization.maximumDisplacementMm;
expectedObservedConfidence = rawConfidence(observedMask) .* exp( ...
    -abs(displacementMm(observedMask)) / maximumDisplacementMm);
verifyEqual(testCase, confidence(observedMask), ...
    expectedObservedConfidence, 'AbsTol', 1e-10);

% The compact coordinate array must be ordered, one point per finite column,
% and use MATLAB [column,row] pixel coordinates.
coordinates = surfaceResults.surfaceCoordinatesXY;
finiteColumns = find(isfinite(surfaceRows));
finiteColumns = finiteColumns(:);
expectedCoordinateRows = surfaceRows(finiteColumns);
expectedCoordinateRows = expectedCoordinateRows(:);
verifyEqual(testCase, coordinates(:, 1), finiteColumns);
verifyEqual(testCase, coordinates(:, 2), expectedCoordinateRows, ...
    'AbsTol', 10 * eps);
verifyTrue(testCase, all(diff(coordinates(:, 1)) > 0));

% The short gap must be visibly distinguished from measured points.
verifyTrue(testCase, all(interpolatedMask(gapColumns)));
verifyFalse(testCase, any(observedMask(gapColumns)));
verifyGreaterThan(testCase, surfaceResults.interpolatedLengthMm, 0);
verifyGreaterThan(testCase, surfaceResults.observedLengthMm, 0);
verifyEqual(testCase, surfaceResults.numberOfSegments, 1);

% The public extractor returns only the small metadata fields it can know
% without receiving file paths from the orchestration script.
metadataFields = sort([ ...
    "createdAt"; "algorithmVersion"; "numberOfFrames"]);
verifyEqual(testCase, sort(string(fieldnames(extractionMetadata))), ...
    metadataFields);
verifyNotEmpty(testCase, extractionMetadata.createdAt);
verifyEqual(testCase, string(extractionMetadata.algorithmVersion), "1.2.0");
verifyEqual(testCase, extractionMetadata.numberOfFrames, 1);
end

function writeFailingQuadprogShim(temporaryDirectory)
% WRITEFAILINGQUADPROGSHIM Create a temporary solver failure injector.
%   WRITEFAILINGQUADPROGSHIM(TEMPORARYDIRECTORY) writes a minimal QUADPROG
%   function that always throws. Keeping this shim outside the repository
%   lets the fallback test exercise the public numerical-error path without
%   changing production code or Optimization Toolbox files.
%
%   Inputs:
%       temporaryDirectory - Existing writable folder used only by the test.
%
%   Outputs:
%       None. The temporary quadprog.m file is written into the folder.

shimPath = fullfile(temporaryDirectory, 'quadprog.m');
fileIdentifier = fopen(shimPath, 'w');
if fileIdentifier < 0
    error('testExtractBoneSurfaces:TemporaryFileFailure', ...
        'Could not create the temporary quadprog failure shim.');
end
closeFile = onCleanup(@() fclose(fileIdentifier));

shimLines = { ...
    'function varargout = quadprog(varargin)', ...
    '% QUADPROG Test-only shim that injects a deterministic solver error.', ...
    'error(''testExtractBoneSurfaces:InjectedSolverFailure'', ...', ...
    '    ''Injected quadprog failure for fallback verification.'');', ...
    'end'};
for lineIndex = 1:numel(shimLines)
    fprintf(fileIdentifier, '%s\n', shimLines{lineIndex});
end
end

function removeFailingQuadprogShim(temporaryDirectory)
% REMOVEFAILINGQUADPROGSHIM Restore solver lookup and delete test files.
%   REMOVEFAILINGQUADPROGSHIM(TEMPORARYDIRECTORY) removes the temporary path,
%   clears the shadowed function from MATLAB's cache, and deletes the exact
%   temporary directory created by TESTSOLVERFAILURERETAINSRAWSEGMENT.
%
%   Inputs:
%       temporaryDirectory - Exact test-owned folder containing the shim.
%
%   Outputs:
%       None. MATLAB path and temporary files are restored in place.

pathEntries = strsplit(path, pathsep);
if any(strcmp(pathEntries, temporaryDirectory))
    rmpath(temporaryDirectory);
end
clear quadprog;
rehash path;

% TEMPORARYDIRECTORY comes directly from TEMPNAME and is never inferred from
% a broad parent directory, so recursive cleanup cannot affect project data.
if isfolder(temporaryDirectory)
    rmdir(temporaryDirectory, 's');
end
end

function [segmentationResult, ultrasoundFrame, expectedRows, ySpacingMm] = ...
        makeErraticRefinementFixture(sourceIndex, xSpacingMm)
% MAKEERRATICREFINEMENTFIXTURE Build a rough path around a flat truth.
%   [SEGMENTATIONRESULT,ULTRASOUNDFRAME,EXPECTEDROWS,YSPACINGMM] =
%   MAKEERRATICREFINEMENTFIXTURE(SOURCEINDEX,XSPACINGMM) creates strong
%   alternating first echoes, one narrow deep valley, and extra distal mask
%   runs. It is used to isolate the post-DP curvature refinement from normal
%   first-stage smoothness.
%
%   Inputs:
%       sourceIndex - Unique scalar identifier used to match the test frame.
%       xSpacingMm - Positive lateral pixel spacing in millimetres.
%
%   Outputs:
%       segmentationResult - Processed synthetic segmentation structure.
%       ultrasoundFrame - Matching synthetic ultrasound frame structure.
%       expectedRows - Flat anatomical approximation for every column.
%       ySpacingMm - Axial pixel spacing in millimetres.

nRows = 110;
nColumns = 161;
ySpacingMm = 0.1;
xCoordinatesMm = (0:(nColumns - 1)) * xSpacingMm;
expectedRows = repmat(52.5, 1, nColumns);

% Alternating 0.8 mm blocks model jagged branches. The central 0.6 mm
% downward excursion models the implausible narrow valley seen in hard cases.
blockIndices = floor(xCoordinatesMm / 0.4);
alternatingOffsetsRows = 3 * (2 * mod(blockIndices, 2) - 1);
rawTargetRows = expectedRows + alternatingOffsetsRows;
valleyMask = abs(xCoordinatesMm - 8.0) <= 0.3;
rawTargetRows(valleyMask) = expectedRows(valleyMask) + 7;
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, rawTargetRows, 5, 35);

% Add dark distal runs in selected regions. They create amoeba-like
% competing branches without replacing the strong probe-facing reflection.
branchColumns = [24:42, 70:88, 118:137];
for columnIndex = branchColumns
    branchStartRow = round(rawTargetRows(columnIndex)) + 9;
    branchEndRow = min(nRows, branchStartRow + 4);
    segmentationMask(branchStartRow:branchEndRow, columnIndex) = true;
end

segmentationResult = makeSegmentationResult( ...
    sourceIndex, 1, segmentationMask, 'processed');
ultrasoundFrame = makeUltrasoundFrame( ...
    sourceIndex, displayedImage, xSpacingMm, ySpacingMm);
end

function options = makeRefinementTestOptions()
% MAKEREFINEMENTTESTOPTIONS Configure tests to expose the raw rough path.
%   OPTIONS = MAKEREFINEMENTTESTOPTIONS() returns explicit production
%   refinement settings while reducing only the first-stage slope penalty.
%   This makes synthetic pixel-scale perturbations visible in the raw audit
%   trace so tests measure the new stage instead of the existing DP prior.
%
%   Inputs:
%       None.
%
%   Outputs:
%       options - Scalar extractor-options structure.

% Keep tracing and regularization overrides in the same groups used by the
% production JSON so tests exercise the public hierarchical option format.
options = struct();
options.surfaceTracing = struct( ...
    'smoothnessWeight', 0.005, ...
    'evidenceThreshold', 0.05, ...
    'minimumMeanSegmentConfidence', 0.05);
options.regularization = struct( ...
    'enabled', true, ...
    'halfResponseWavelengthMm', 2.5, ...
    'huberDeltaMm', 0.15, ...
    'maximumDisplacementMm', 0.75, ...
    'minimumDataWeight', 0.10, ...
    'maximumIterations', 10, ...
    'convergenceMm', 0.001);
end

function amplitudeMm = estimatePeriodicAmplitude( ...
        xCoordinatesMm, depthMm, wavelengthMm)
% ESTIMATEPERIODICAMPLITUDE Measure one known sinusoidal component.
%   AMPLITUDEMM = ESTIMATEPERIODICAMPLITUDE(XCOORDINATESMM,DEPTHMM,
%   WAVELENGTHMM) fits offset, sine, and cosine terms at the requested
%   wavelength. Combining the two periodic coefficients avoids sensitivity
%   to a small phase shift introduced by smoothing.
%
%   Inputs:
%       xCoordinatesMm - Physical lateral sample coordinates in millimetres.
%       depthMm - Surface depths at the matching coordinates in millimetres.
%       wavelengthMm - Positive wavelength of the component to measure.
%
%   Outputs:
%       amplitudeMm - Nonnegative fitted sinusoidal amplitude in millimetres.

xCoordinatesMm = double(xCoordinatesMm(:));
depthMm = double(depthMm(:));
phaseRadians = 2 * pi * xCoordinatesMm / wavelengthMm;
designMatrix = [ones(size(phaseRadians)), ...
    sin(phaseRadians), cos(phaseRadians)];
coefficients = designMatrix \ depthMm;
amplitudeMm = hypot(coefficients(2), coefficients(3));
end

function [surfaceResult, xCoordinatesMm, ySpacingMm] = ...
        extractPhysicalSpacingFixture(sourceIndex, xSpacingMm)
% EXTRACTPHYSICALSPACINGFIXTURE Extract one resolution-controlled response.
%   [SURFACERESULT,XCOORDINATESMM,YSPACINGMM] =
%   EXTRACTPHYSICALSPACINGFIXTURE(SOURCEINDEX,XSPACINGMM) samples the same
%   16 mm physical mixture of broad curvature and short roughness using the
%   requested lateral spacing, then runs the public extractor.
%
%   Inputs:
%       sourceIndex - Unique scalar identifier used to match the test frame.
%       xSpacingMm - Positive lateral pixel spacing in millimetres.
%
%   Outputs:
%       surfaceResult - One surface result returned by the extractor.
%       xCoordinatesMm - Lateral coordinate for every result column.
%       ySpacingMm - Axial pixel spacing in millimetres.

physicalWidthMm = 16;
nColumns = round(physicalWidthMm / xSpacingMm) + 1;
nRows = 110;
ySpacingMm = 0.1;
xCoordinatesMm = (0:(nColumns - 1)) * xSpacingMm;

% Both samplings share these physical wavelengths. Rounding only represents
% the unavoidable pixel quantization of the synthetic ultrasound image.
rawTargetRows = round(50 + ...
    2 * sin(2 * pi * xCoordinatesMm / 10) + ...
    3 * sin(2 * pi * xCoordinatesMm / 0.8)) + 0.5;
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, rawTargetRows, 8, 35);
segmentationResult = makeSegmentationResult( ...
    sourceIndex, 1, segmentationMask, 'processed');
ultrasoundFrame = makeUltrasoundFrame( ...
    sourceIndex, displayedImage, xSpacingMm, ySpacingMm);

surfaceResult = extractSingleGroupSurfaceData( ...
    segmentationResult, ultrasoundFrame, makeRefinementTestOptions());
end

function [surfaceResult, gapColumns] = extractSyntheticGap( ...
        numberOfMissingColumns, sourceIndex, options)
% EXTRACTSYNTHETICGAP Extract one flat response with a coordinate gap.
%   [SURFACERESULT,GAPCOLUMNS] = EXTRACTSYNTHETICGAP(NUMBEROFMISSINGCOLUMNS,
%   SOURCEINDEX) creates a 0.1 mm-spaced image, removes the requested number
%   of exported boundary-coordinate columns, and calls the public extractor.
%   The filled mask stays continuous so only pixelCoordinates can create the
%   4.9/5.1 mm gap decision.
%
%   Inputs:
%       numberOfMissingColumns - Positive integer number of empty columns.
%       sourceIndex - Unique scalar identifier used to match the test frame.
%       options - Optional scalar extractor-options structure.
%
%   Outputs:
%       surfaceResult - One result structure returned by the extractor.
%       gapColumns - Column indices intentionally removed from coordinates.

if nargin < 3
    options = struct();
end

nRows = 90;
nColumns = 181;
expectedRows = repmat(37.5, 1, nColumns);
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 14, 35);

% Keep both observed sides comfortably longer than the 2 mm segment gate.
gapStartColumn = 61;
gapColumns = gapStartColumn:(gapStartColumn + numberOfMissingColumns - 1);

segmentationResults = makeSegmentationResult( ...
    sourceIndex, 1, segmentationMask, 'processed');
keepCoordinate = ~ismember( ...
    segmentationResults.pixelCoordinates(:, 2), gapColumns);
segmentationResults.pixelCoordinates = ...
    segmentationResults.pixelCoordinates(keepCoordinate, :);
ultrasoundSequence = makeUltrasoundFrame( ...
    sourceIndex, displayedImage, 0.1, 0.1);
surfaceResult = extractSingleGroupSurfaceData( ...
    segmentationResults, ultrasoundSequence, options);
end

function [segmentationGroups, ultrasoundGroups] = ...
        makeGroupedExtractionFixture()
%MAKEGROUPEDEXTRACTIONFIXTURE Build empty and repeated-index source groups.
% The fixture contains group counts 0, 2, and 1. Source index 1 appears in both
% populated groups so tests exercise composite identity rather than global keys.
%
% Inputs:
%   None.
%
% Outputs:
%   segmentationGroups : Three grouped synthetic segmentation inputs.
%   ultrasoundGroups   : Three matching grouped ultrasound inputs.

[segmentationA1, ultrasoundA1] = makeSimpleFixture(1);

% Use distinct depths for the reordered local record and repeated cross-group
% source index so positional or global matching errors change the result.
nRows = 70;
nColumns = 71;
deepRows = repmat(47.5, 1, nColumns);
[deepImage, deepMask] = makeBoneBandImage( ...
    nRows, nColumns, deepRows, 12, 18);
segmentationA2 = makeSegmentationResult(2, 2, deepMask, 'processed');
ultrasoundA2 = makeUltrasoundFrame(2, deepImage, 0.1, 0.1);
shallowRows = repmat(20.5, 1, nColumns);
[shallowImage, shallowMask] = makeBoneBandImage( ...
    nRows, nColumns, shallowRows, 12, 38);
segmentationB1 = makeSegmentationResult(1, 1, shallowMask, 'processed');
ultrasoundB1 = makeUltrasoundFrame(1, shallowImage, 0.1, 0.1);

segmentationTemplate = struct( ...
    'name', '', 'bone', '', 'path', '', ...
    'data', segmentationA1([]));
ultrasoundTemplate = struct( ...
    'name', '', 'bone', '', 'path', '', ...
    'data', ultrasoundA1([]));
segmentationGroups = repmat(segmentationTemplate, 1, 3);
ultrasoundGroups = repmat(ultrasoundTemplate, 1, 3);

groupNames = {'empty_group', 'group_a', 'group_b'};
groupBones = {'F', 'T', 'T'};
groupPaths = { ...
    'synthetic://empty', 'synthetic://group_a', 'synthetic://group_b'};
for groupIndex = 1:3
    segmentationGroups(groupIndex).name = groupNames{groupIndex};
    segmentationGroups(groupIndex).bone = groupBones{groupIndex};
    segmentationGroups(groupIndex).path = groupPaths{groupIndex};
    ultrasoundGroups(groupIndex).name = groupNames{groupIndex};
    ultrasoundGroups(groupIndex).bone = groupBones{groupIndex};
    ultrasoundGroups(groupIndex).path = groupPaths{groupIndex};
end

segmentationGroups(2).data = [segmentationA1, segmentationA2];
ultrasoundGroups(2).data = [ultrasoundA1, ultrasoundA2];
segmentationGroups(3).data = segmentationB1;
ultrasoundGroups(3).data = ultrasoundB1;
end


function [surfaceData, extractionMetadata] = extractSingleGroupSurfaceData( ...
        segmentationData, ultrasoundData, options)
%EXTRACTSINGLEGROUPSURFACEDATA Exercise grouped extraction for algorithm tests.
% Existing numerical tests work with scalar or flat per-frame records. Wrapping
% them in one source group keeps those assertions focused on the algorithm while
% the public extractor is exercised through its grouped-only contract.
%
% Inputs:
%   segmentationData : Scalar or vector of synthetic segmentation records.
%   ultrasoundData   : Scalar or vector of matching ultrasound records.
%   options          : Extraction configuration overrides used by the test.
%
% Outputs:
%   surfaceData       : Unwrapped per-frame records from the one output group.
%   extractionMetadata: Metadata returned by the grouped public extractor.

groupMetadata = struct( ...
    'name', 'synthetic_group', ...
    'bone', 'T', ...
    'path', 'synthetic://group');
segmentationGroup = groupMetadata;
segmentationGroup.data = segmentationData;
ultrasoundGroup = groupMetadata;
ultrasoundGroup.data = ultrasoundData;

[groupedSurfaceResults, extractionMetadata] = ...
    extractBoneSurfacesFromSegmentation( ...
        segmentationGroup, ultrasoundGroup, options);
surfaceData = groupedSurfaceResults.data;
end


function [segmentationResult, ultrasoundFrame] = makeSimpleFixture(sourceIndex)
% MAKESIMPLEFIXTURE Create one valid extraction input pair for error tests.
%   [SEGMENTATIONRESULT,ULTRASOUNDFRAME] = MAKESIMPLEFIXTURE(SOURCEINDEX)
%   builds a compact flat bone response. Validation tests change one property
%   at a time so the expected error has a single cause.
%
%   Inputs:
%       sourceIndex - Scalar identifier shared by the two returned records.
%
%   Outputs:
%       segmentationResult - One processed synthetic segmentation structure.
%       ultrasoundFrame - Its matching synthetic ultrasound frame structure.

nRows = 70;
nColumns = 71;
expectedRows = repmat(31.5, 1, nColumns);
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 12, 28);
segmentationResult = makeSegmentationResult( ...
    sourceIndex, 1, segmentationMask, 'processed');
ultrasoundFrame = makeUltrasoundFrame( ...
    sourceIndex, displayedImage, 0.1, 0.1);
end

function segmentationResult = makeSegmentationResult(sourceIndex, sequencePosition, segmentationMask, status)
% MAKESEGMENTATIONRESULT Build one production-shaped segmentation record.
%   SEGMENTATIONRESULT = MAKESEGMENTATIONRESULT(SOURCEINDEX,SEQUENCEPOSITION,
%   SEGMENTATIONMASK,STATUS) creates the fields emitted by the semi-automatic
%   segmentation tool. Its pixelCoordinates contain only eight-connected
%   perimeter pixels, matching the real exported candidate contract.
%
%   Inputs:
%       sourceIndex - Scalar identifier of the matching ultrasound frame.
%       sequencePosition - Scalar position stored in the segmentation result.
%       segmentationMask - Logical [row,column] candidate-region mask.
%       status - Character vector describing segmentation processing state.
%
%   Outputs:
%       segmentationResult - Scalar structure accepted by the extractor.

% The segmentation UI exports the boundary before any custom-area clipping.
% Using BWPERIM here prevents synthetic tests from silently supplying filled
% region pixels that never occur in production pixelCoordinates.
boundaryMask = bwperim(logical(segmentationMask), 8);
[pixelRows, pixelColumns] = find(boundaryMask);

segmentationResult = struct( ...
    'sequencePosition', sequencePosition, ...
    'sourceIndex', sourceIndex, ...
    'pixelCoordinates', [pixelRows, pixelColumns], ...
    'segmentationMask', logical(segmentationMask), ...
    'segmentationAreaMask', true(size(segmentationMask)), ...
    'usesCustomSegmentationArea', false, ...
    'processingParameters', struct(), ...
    'status', status);
end

function ultrasoundFrame = makeUltrasoundFrame(sourceIndex, displayedImage, xSpacingMm, ySpacingMm)
% MAKEULTRASOUNDFRAME Build one production-shaped ultrasound source record.
%   ULTRASOUNDFRAME = MAKEULTRASOUNDFRAME(SOURCEINDEX,DISPLAYEDIMAGE,
%   XSPACINGMM,YSPACINGMM) stores the image transposed, matching the real
%   validSnapshots plane convention used by the extraction script.
%
%   Inputs:
%       sourceIndex - Scalar identifier shared with the segmentation record.
%       displayedImage - Normalized double [row,column] B-mode image.
%       xSpacingMm - Positive lateral pixel spacing in millimetres.
%       ySpacingMm - Positive axial pixel spacing in millimetres.
%
%   Outputs:
%       ultrasoundFrame - Scalar source frame with sourceIndex and plane data.

[nRows, nColumns] = size(displayedImage);

% Convert to raw uint8 pixels before transposing to the acquisition layout.
rawImage = uint8(round(255 * min(max(displayedImage, 0), 1))).';
plane = struct( ...
    'W', xSpacingMm * (nColumns - 1), ...
    'H', ySpacingMm * (nRows - 1), ...
    'nRows', nRows, ...
    'nCols', nColumns, ...
    'image', rawImage);
ultrasoundFrame = struct('sourceIndex', sourceIndex, 'plane', plane);
end

function [displayedImage, segmentationMask] = makeBoneBandImage(nRows, nColumns, expectedRows, thicknessRows, shadowRows)
% MAKEBONEBANDIMAGE Create a segmented reflection followed by a dark shadow.
%   [DISPLAYEDIMAGE,SEGMENTATIONMASK] = MAKEBONEBANDIMAGE(NROWS,NCOLUMNS,
%   EXPECTEDROWS,THICKNESSROWS,SHADOWROWS) paints a gradient at the mask
%   entrance, a first bright peak one row later, and a distal shadow. The
%   expected surface lies halfway between that gradient and peak.
%
%   Inputs:
%       nRows - Positive integer number of displayed image rows.
%       nColumns - Positive integer number of displayed image columns.
%       expectedRows - Scalar or 1-by-N expected half-pixel surface rows.
%       thicknessRows - Scalar or 1-by-N segmentation-run thickness in rows.
%       shadowRows - Positive integer desired distal-shadow depth in rows.
%
%   Outputs:
%       displayedImage - Normalized double [row,column] synthetic B-mode image.
%       segmentationMask - Logical thick bone-response region.

% Expand scalar controls so each scan line can be painted independently.
if isscalar(expectedRows)
    expectedRows = repmat(expectedRows, 1, nColumns);
end
if isscalar(thicknessRows)
    thicknessRows = repmat(thicknessRows, 1, nColumns);
end

displayedImage = makeBackgroundImage(nRows, nColumns);
segmentationMask = false(nRows, nColumns);

for columnIndex = 1:nColumns
    % The expected row is half-way between the entrance gradient and peak.
    entranceRow = round(expectedRows(columnIndex) - 0.5);
    peakRow = entranceRow + 1;
    runEndRow = min(nRows, entranceRow + thicknessRows(columnIndex) - 1);

    % Keep the entire thick segmented response available as candidates.
    segmentationMask(entranceRow:runEndRow, columnIndex) = true;

    % Paint a strong entrance, first local maximum, and falling response.
    displayedImage(entranceRow, columnIndex) = 0.76;
    displayedImage(peakRow, columnIndex) = 1.00;
    if peakRow + 1 <= nRows
        displayedImage(peakRow + 1, columnIndex) = 0.64;
    end

    % The shadow begins after the reflected pulse and clips safely at the
    % image bottom for the truncated-window test.
    firstShadowRow = peakRow + 2;
    lastShadowRow = min(nRows, firstShadowRow + shadowRows - 1);
    if firstShadowRow <= lastShadowRow
        displayedImage(firstShadowRow:lastShadowRow, columnIndex) = 0.035;
    end
end
end

function [displayedImage, artifactMask] = addBrightRunWithoutShadow(displayedImage, expectedRows, thicknessRows)
% ADDBRIGHTRUNWITHOUTSHADOW Add a competing bright segmented tissue response.
%   [DISPLAYEDIMAGE,ARTIFACTMASK] = ADDBRIGHTRUNWITHOUTSHADOW(DISPLAYEDIMAGE,
%   EXPECTEDROWS,THICKNESSROWS) paints a reflection but deliberately leaves
%   normal-intensity tissue below it. It tests whether shadow evidence can
%   distinguish bone from a bright soft-tissue interface.
%
%   Inputs:
%       displayedImage - Existing normalized double [row,column] image.
%       expectedRows - Scalar or 1-by-N half-pixel artifact surface rows.
%       thicknessRows - Scalar or 1-by-N artifact-mask thickness in rows.
%
%   Outputs:
%       displayedImage - Input image with the bright artifact added.
%       artifactMask - Logical mask containing only the artifact runs.

[nRows, nColumns] = size(displayedImage);
if isscalar(expectedRows)
    expectedRows = repmat(expectedRows, 1, nColumns);
end
if isscalar(thicknessRows)
    thicknessRows = repmat(thicknessRows, 1, nColumns);
end
artifactMask = false(nRows, nColumns);

for columnIndex = 1:nColumns
    entranceRow = round(expectedRows(columnIndex) - 0.5);
    peakRow = entranceRow + 1;
    runEndRow = min(nRows, entranceRow + thicknessRows(columnIndex) - 1);
    artifactMask(entranceRow:runEndRow, columnIndex) = true;

    % Keep the artifact bright but do not overwrite distal tissue with a
    % shadow, which is the important distinction from the bone fixture.
    displayedImage(entranceRow, columnIndex) = 0.78;
    displayedImage(peakRow, columnIndex) = 0.96;
    if peakRow + 1 <= nRows
        displayedImage(peakRow + 1, columnIndex) = 0.68;
    end
end
end

function displayedImage = makeBackgroundImage(nRows, nColumns)
% MAKEBACKGROUNDIMAGE Create deterministic, mildly textured B-mode tissue.
%   DISPLAYEDIMAGE = MAKEBACKGROUNDIMAGE(NROWS,NCOLUMNS) returns a repeatable
%   nonuniform background. Texture prevents percentile normalization tests
%   from depending on a mathematically constant image.
%
%   Inputs:
%       nRows - Positive integer number of image rows.
%       nColumns - Positive integer number of image columns.
%
%   Outputs:
%       displayedImage - Normalized double [row,column] background image.

[rowGrid, columnGrid] = ndgrid(1:nRows, 1:nColumns);
displayedImage = 0.42 + 0.018 * sin(rowGrid / 7) + ...
    0.014 * cos(columnGrid / 11);
end

function verifySurfaceNearExpected(testCase, surfaceResult, expectedRows, ySpacingMm, toleranceMm, minimumCoverage)
% VERIFYSURFACENEAREXPECTED Check observed coverage and median axial error.
%   VERIFYSURFACENEAREXPECTED(TESTCASE,SURFACERESULT,EXPECTEDROWS,YSPACINGMM,
%   TOLERANCEMM,MINIMUMCOVERAGE) centralizes accuracy checks used by several
%   fixtures while measuring error only at genuinely observed columns.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%       surfaceResult - Scalar output structure from the public extractor.
%       expectedRows - Expected surface row for every image column.
%       ySpacingMm - Positive axial pixel spacing in millimetres.
%       toleranceMm - Maximum allowed median observed error in millimetres.
%       minimumCoverage - Minimum observed fraction in the interval [0,1].
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

observedMask = logical(surfaceResult.observedColumnMask(:).');
verifyGreaterThanOrEqual(testCase, mean(observedMask), minimumCoverage);

% Stop the helper from indexing an empty vector if coverage already failed.
if ~any(observedMask)
    return;
end

surfaceRows = surfaceResult.surfaceRowByColumn(:).';
axialErrorMm = abs(surfaceRows(observedMask) - expectedRows(observedMask)) ...
    * ySpacingMm;
verifyLessThanOrEqual(testCase, median(axialErrorMm), toleranceMm);
end
