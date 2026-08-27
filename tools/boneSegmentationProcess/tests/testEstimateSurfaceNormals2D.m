function tests = testEstimateSurfaceNormals2D
%TESTESTIMATESURFACENORMALS2D Test segment-wise physical normal estimation.
% Synthetic curves make tangent direction and probe-facing polarity exact and
% easy to diagnose without depending on the full segmentation pipeline.
%
% Outputs:
%   tests : Function-based tests discovered by MATLAB's test runner.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Add the public surface-extraction helper directory for this suite.
% Input and output are supplied by MATLAB's function-test framework.

testDirectory = fileparts(mfilename('fullpath'));
helperDirectory = fullfile(fileparts(testDirectory), 'helpers', ...
    'boneSegmentation_extractSurface');
testCase.TestData.helperDirectory = helperDirectory;
pathEntries = strsplit(path, pathsep);
testCase.TestData.pathWasAdded = ~any(strcmp(pathEntries, helperDirectory));
if testCase.TestData.pathWasAdded
    addpath(helperDirectory);
end
end


function teardownOnce(testCase)
%TEARDOWNONCE Restore the MATLAB path changed by this test suite.

if testCase.TestData.pathWasAdded
    rmpath(testCase.TestData.helperDirectory);
end
end


function testHorizontalCurvePointsTowardProbe(testCase)
%TESTHORIZONTALCURVEPOINTSTOWARDPROBE Verify the simple [0,-1] convention.

coordinates = [(1:4).', 5 * ones(4, 1)];
[normals, mask] = estimateSurfaceNormals2D( ...
    coordinates, uint16(ones(1, 4)), [0.4, 0.9]);

verifyTrue(testCase, all(mask));
verifyEqual(testCase, normals, repmat([0, -1], 4, 1), ...
    'AbsTol', 1e-12);
end


function testPositiveAndNegativeSlopesUsePhysicalSpacing(testCase)
%TESTPOSITIVEANDNEGATIVESLOPESUSEPHYSICALSPACING Verify anisotropic pixels.

positiveSlope = [(1:3).', (1:3).'];
[positiveNormals, positiveMask] = estimateSurfaceNormals2D( ...
    positiveSlope, uint16(ones(1, 3)), [2, 1]);
expectedPositive = repmat([1, -2] ./ sqrt(5), 3, 1);
verifyTrue(testCase, all(positiveMask));
verifyEqual(testCase, positiveNormals, expectedPositive, 'AbsTol', 1e-12);

negativeSlope = [(1:3).', (3:-1:1).'];
[negativeNormals, negativeMask] = estimateSurfaceNormals2D( ...
    negativeSlope, uint16(ones(1, 3)), [1, 1]);
expectedNegative = repmat([-1, -1] ./ sqrt(2), 3, 1);
verifyTrue(testCase, all(negativeMask));
verifyEqual(testCase, negativeNormals, expectedNegative, 'AbsTol', 1e-12);
end


function testCentralAndEndpointDifferences(testCase)
%TESTCENTRALANDENDPOINTDIFFERENCES Verify each differentiation stencil.

coordinates = [(1:4).', [1; 2; 4; 7]];
[normals, mask] = estimateSurfaceNormals2D( ...
    coordinates, uint16(ones(1, 4)), [1, 1]);
expectedTangents = [1, 1; 2, 3; 2, 5; 1, 3];
expectedNormals = [expectedTangents(:, 2), -expectedTangents(:, 1)];
expectedNormals = expectedNormals ./ vecnorm(expectedNormals, 2, 2);

verifyTrue(testCase, all(mask));
verifyEqual(testCase, normals, expectedNormals, 'AbsTol', 1e-12);
verifyEqual(testCase, vecnorm(normals, 2, 2), ones(4, 1), ...
    'AbsTol', 1e-12);
end


function testTwoPointAndSingletonSegments(testCase)
%TESTTWOPOINTANDSINGLETONSEGMENTS Verify short-segment contracts.

coordinates = [1, 2; 2, 4; 5, 8];
segmentIds = uint16([1, 1, 0, 0, 2]);
[normals, mask] = estimateSurfaceNormals2D( ...
    coordinates, segmentIds, [1, 1]);
expectedTwoPointNormal = [2, -1] ./ sqrt(5);

verifyEqual(testCase, normals(1:2, :), ...
    repmat(expectedTwoPointNormal, 2, 1), 'AbsTol', 1e-12);
verifyEqual(testCase, mask, [true; true; false]);
verifyTrue(testCase, all(isnan(normals(3, :))));
end


function testDegenerateNonfiniteAndEmptyInputs(testCase)
%TESTDEGENERATENONFINITEANDEMPTYINPUTS Verify the mask/NaN contract.

[zeroNormals, zeroMask] = estimateSurfaceNormals2D( ...
    [2, 4; 2, 4], uint16([0, 1]), [1, 1]);
verifyFalse(testCase, any(zeroMask));
verifyTrue(testCase, all(isnan(zeroNormals), 'all'));

[nonfiniteNormals, nonfiniteMask] = estimateSurfaceNormals2D( ...
    [1, 2; 2, NaN], uint16([1, 1]), [1, 1]);
verifyFalse(testCase, any(nonfiniteMask));
verifyTrue(testCase, all(isnan(nonfiniteNormals), 'all'));

[emptyNormals, emptyMask] = estimateSurfaceNormals2D( ...
    zeros(0, 2), zeros(1, 0, 'uint16'), [1, 1]);
verifySize(testCase, emptyNormals, [0, 2]);
verifySize(testCase, emptyMask, [0, 1]);
verifyClass(testCase, emptyMask, 'logical');
end


function testDisconnectedSegmentsNeverShareTangents(testCase)
%TESTDISCONNECTEDSEGMENTSNEVERSHARETANGENTS Verify gap isolation and alignment.

coordinates = [1, 1; 2, 1; 5, 10; 6, 12];
segmentIds = uint16([1, 1, 0, 0, 2, 2]);
[normals, mask] = estimateSurfaceNormals2D( ...
    coordinates, segmentIds, [1, 1]);
expected = [repmat([0, -1], 2, 1); ...
    repmat([2, -1] ./ sqrt(5), 2, 1)];

verifySize(testCase, normals, size(coordinates));
verifyTrue(testCase, all(mask));
verifyEqual(testCase, normals, expected, 'AbsTol', 1e-12);
end
