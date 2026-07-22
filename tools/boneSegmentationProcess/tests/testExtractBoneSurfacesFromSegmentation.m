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
%   SETUPONCE(TESTCASE) records and adds the parent tool folder so the public
%   extractor can be called while the tests remain in their own subfolder.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase for this test file.
%
%   Outputs:
%       None. The shared test data and MATLAB path are updated in place.

% Resolve the tool folder from this test file instead of assuming MATLAB's
% current folder is the project root.
testDirectory = fileparts(mfilename('fullpath'));
toolDirectory = fileparts(testDirectory);

% Remember whether the path was already present so teardown does not remove
% a path entry owned by the caller's project setup.
testCase.TestData.toolDirectory = toolDirectory;
pathEntries = strsplit(path, pathsep);
testCase.TestData.addedToolDirectory = ~any(strcmp(pathEntries, toolDirectory));
if testCase.TestData.addedToolDirectory
    addpath(toolDirectory);
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

% Avoid leaving a project-specific path only when this suite added it.
if testCase.TestData.addedToolDirectory
    rmpath(testCase.TestData.toolDirectory);
end
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
surfaceResults = extractBoneSurfacesFromSegmentation( ...
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

surfaceResults = extractBoneSurfacesFromSegmentation( ...
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
options = struct('shadowWeight', 2.0, ...
                 'reflectionWeight', 0.5, ...
                 'evidenceThreshold', 0.05);
surfaceResults = extractBoneSurfacesFromSegmentation( ...
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

% All missing columns in a 4.9 mm gap must be supplied only by interpolation.
verifyTrue(testCase, all(shortGapResult.interpolatedColumnMask(shortGapColumns)));
verifyFalse(testCase, any(shortGapResult.observedColumnMask(shortGapColumns)));
verifyTrue(testCase, all(isfinite(shortGapResult.surfaceRowByColumn(shortGapColumns))));

% A 5.1 mm gap remains explicit and separates the observed paths.
verifyFalse(testCase, any(longGapResult.interpolatedColumnMask(longGapColumns)));
verifyTrue(testCase, all(isnan(longGapResult.surfaceRowByColumn(longGapColumns))));
segmentIds = unique(longGapResult.segmentIdByColumn);
segmentIds(segmentIds == 0) = [];
verifyEqual(testCase, numel(segmentIds), 2);
end

function testEmptyAndUnprocessedMasks(testCase)
% TESTEMPTYANDUNPROCESSEDMASKS Verify valid empty and skipped result states.
%   TESTEMPTYANDUNPROCESSEDMASKS(TESTCASE) checks that an empty processed mask
%   becomes NOSURFACE, while any non-processed record is skipped even if its
%   mask contains pixels.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

nRows = 80;
nColumns = 81;
displayedImage = makeBackgroundImage(nRows, nColumns);
emptyMask = false(nRows, nColumns);
nonEmptyMask = false(nRows, nColumns);
nonEmptyMask(30:40, 15:65) = true;

segmentationResults(1) = makeSegmentationResult(41, 1, emptyMask, 'processed');
segmentationResults(2) = makeSegmentationResult(42, 2, nonEmptyMask, 'pending');
ultrasoundSequence(1) = makeUltrasoundFrame(41, displayedImage, 0.1, 0.1);
ultrasoundSequence(2) = makeUltrasoundFrame(42, displayedImage, 0.1, 0.1);

surfaceResults = extractBoneSurfacesFromSegmentation( ...
    segmentationResults, ultrasoundSequence, struct());

verifyEqual(testCase, string(surfaceResults(1).status), "noSurface");
verifyTrue(testCase, all(isnan(surfaceResults(1).surfaceRowByColumn)));
verifyEqual(testCase, string(surfaceResults(2).status), "skippedUnprocessed");
verifyFalse(testCase, any(surfaceResults(2).observedColumnMask));
verifyFalse(testCase, any(surfaceResults(2).interpolatedColumnMask));
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

surfaceResults = extractBoneSurfacesFromSegmentation( ...
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

verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
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

verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
    segmentationResult, ultrasoundSequence, struct()), ...
    'extractBoneSurfacesFromSegmentation:DuplicateUltrasoundSourceIndex');
end

function testMissingSourceImageRejected(testCase)
% TESTMISSINGSOURCEIMAGEREJECTED Reject segmentation without a source frame.
%   TESTMISSINGSOURCEIMAGEREJECTED(TESTCASE) uses different source indices
%   and verifies that extraction stops instead of silently pairing by order.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ~] = makeSimpleFixture(63);
[~, ultrasoundFrame] = makeSimpleFixture(64);

verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
    segmentationResult, ultrasoundFrame, struct()), ...
    'extractBoneSurfacesFromSegmentation:MissingSourceImage');
end

function testImageMaskSizeMismatchRejected(testCase)
% TESTIMAGEMASKSIZEMISMATCHREJECTED Reject incompatible image geometry.
%   TESTIMAGEMASKSIZEMISMATCHREJECTED(TESTCASE) removes one displayed image
%   row while retaining the original mask size.
%
%   Inputs:
%       testCase - matlab.unittest.FunctionTestCase used for verification.
%
%   Outputs:
%       None. Test failures are reported through TESTCASE.

[segmentationResult, ultrasoundFrame] = makeSimpleFixture(65);
displayedImage = ultrasoundFrame.plane.image.';
displayedImage = displayedImage(1:end-1, :);
ultrasoundFrame = makeUltrasoundFrame(65, displayedImage, 0.1, 0.1);

verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
    segmentationResult, ultrasoundFrame, struct()), ...
    'extractBoneSurfacesFromSegmentation:ImageMaskSizeMismatch');
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

verifyError(testCase, @() extractBoneSurfacesFromSegmentation( ...
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

surfaceResults = extractBoneSurfacesFromSegmentation( ...
    segmentationResults, ultrasoundSequence, struct());

% A clipped shadow window carries less evidence but must not cause indexing
% errors or remove an otherwise strong, long reflection.
verifySurfaceNearExpected(testCase, surfaceResults, expectedRows, 0.1, 0.5, 0.70);
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
segmentationMask(:, gapColumns) = false;
segmentationResults = makeSegmentationResult(81, 3, segmentationMask, 'processed');
segmentationResultsBeforeExtraction = segmentationResults;
ultrasoundSequence = makeUltrasoundFrame(81, displayedImage, 0.1, 0.1);

[surfaceResults, extractionMetadata] = extractBoneSurfacesFromSegmentation( ...
    segmentationResults, ultrasoundSequence, struct());

% The second-stage extractor must not rewrite the semi-automatic result.
verifyEqual(testCase, segmentationResults, segmentationResultsBeforeExtraction);

requiredFields = {'sequencePosition', 'sourceIndex', 'status', ...
    'surfacePixelCoordinatesXY', 'surfaceRowByColumn', ...
    'observedColumnMask', 'interpolatedColumnMask', ...
    'segmentIdByColumn', 'confidenceByColumn', 'pixelSpacingXYMm', ...
    'observedLengthMm', 'interpolatedLengthMm', 'meanConfidence', ...
    'numberOfSegments'};
verifyTrue(testCase, all(isfield(surfaceResults, requiredFields)));

% A column can be observed, interpolated, or absent, but never two at once.
observedMask = logical(surfaceResults.observedColumnMask(:).');
interpolatedMask = logical(surfaceResults.interpolatedColumnMask(:).');
surfaceRows = surfaceResults.surfaceRowByColumn(:).';
confidence = surfaceResults.confidenceByColumn(:).';
segmentIds = surfaceResults.segmentIdByColumn(:).';
verifyEqual(testCase, numel(surfaceRows), nColumns);
verifyFalse(testCase, any(observedMask & interpolatedMask));
verifyEqual(testCase, isfinite(surfaceRows), observedMask | interpolatedMask);
verifyTrue(testCase, all(segmentIds(~isfinite(surfaceRows)) == 0));
verifyTrue(testCase, all(isnan(confidence(~isfinite(surfaceRows)))));
verifyGreaterThanOrEqual(testCase, confidence(isfinite(surfaceRows)), 0);
verifyLessThanOrEqual(testCase, confidence(isfinite(surfaceRows)), 1);

% Every observed point must remain inside the original candidate mask.
observedColumns = find(observedMask);
observedRows = round(surfaceRows(observedMask));
linearIndices = sub2ind(size(segmentationMask), observedRows, observedColumns);
verifyTrue(testCase, all(segmentationMask(linearIndices)));

% The compact coordinate array must be ordered, one point per finite column,
% and use MATLAB [column,row] pixel coordinates.
coordinates = surfaceResults.surfacePixelCoordinatesXY;
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

metadataFields = {'algorithmVersion', 'coordinateConvention', ...
    'beamDirection', 'resolvedConfiguration'};
verifyTrue(testCase, all(isfield(extractionMetadata, metadataFields)));
end

function [surfaceResult, gapColumns] = extractSyntheticGap(numberOfMissingColumns, sourceIndex)
% EXTRACTSYNTHETICGAP Extract one flat response with a controlled mask gap.
%   [SURFACERESULT,GAPCOLUMNS] = EXTRACTSYNTHETICGAP(NUMBEROFMISSINGCOLUMNS,
%   SOURCEINDEX) creates a 0.1 mm-spaced image, removes the requested number
%   of candidate columns, and calls the public extractor. This helper keeps
%   the 4.9/5.1 mm boundary fixtures identical apart from gap size.
%
%   Inputs:
%       numberOfMissingColumns - Positive integer number of empty columns.
%       sourceIndex - Unique scalar identifier used to match the test frame.
%
%   Outputs:
%       surfaceResult - One result structure returned by the extractor.
%       gapColumns - Column indices intentionally removed from the mask.

nRows = 90;
nColumns = 181;
expectedRows = repmat(37.5, 1, nColumns);
[displayedImage, segmentationMask] = makeBoneBandImage( ...
    nRows, nColumns, expectedRows, 14, 35);

% Keep both observed sides comfortably longer than the 2 mm segment gate.
gapStartColumn = 61;
gapColumns = gapStartColumn:(gapStartColumn + numberOfMissingColumns - 1);
segmentationMask(:, gapColumns) = false;

segmentationResults = makeSegmentationResult( ...
    sourceIndex, 1, segmentationMask, 'processed');
ultrasoundSequence = makeUltrasoundFrame( ...
    sourceIndex, displayedImage, 0.1, 0.1);
surfaceResult = extractBoneSurfacesFromSegmentation( ...
    segmentationResults, ultrasoundSequence, struct());
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
%   segmentation tool. Keeping the real shape catches public-input regressions.
%
%   Inputs:
%       sourceIndex - Scalar identifier of the matching ultrasound frame.
%       sequencePosition - Scalar position stored in the segmentation result.
%       segmentationMask - Logical [row,column] candidate-region mask.
%       status - Character vector describing segmentation processing state.
%
%   Outputs:
%       segmentationResult - Scalar structure accepted by the extractor.

% Store all foreground pixels as coordinates because the extractor must use
% the mask as its authoritative candidate region, not coordinate ordering.
[pixelRows, pixelColumns] = find(segmentationMask);

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
