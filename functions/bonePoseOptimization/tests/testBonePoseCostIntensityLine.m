function tests = testBonePoseCostIntensityLine
%TESTBONEPOSECOSTINTENSITYLINE Test the smoothed-intensity cost model.
% This suite checks that intensityLine is registered and validated, that
% the image blur behaves like a Gaussian in mm, that preparation stores the
% blurred images, and that the cost reads them at the right image positions.
% Preparation is slow, so the suite prepares the real data only once.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Prepare the intensityLine one-sweep inputs once for this suite.
% testCase stores the resolved scalar configuration and prepared data for
% all tests in this suite. This function has no output.

testFilePath = mfilename('fullpath');
projectRoot  = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Use the same selectable configuration a user would choose for this model.
configPath     = fullfile(projectRoot, 'config', 'optconfig_oneSweep_intensityLine.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config         = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :), experimentPlan.runs.seed(1));

testCase.TestData.config = config;
testCase.TestData.data   = prepareBonePoseOptimizationInputs(config);
end


function testModelIsRegistered(testCase)
%TESTMODELISREGISTERED Check the registry connection.
% testCase provides MATLAB verification methods. This function has no output.

definition = getBonePoseCostDefinition('intensityLine');

verifyEqual(testCase, definition.modelName, 'intensityLine');
verifyEqual(testCase, definition.evaluateFcn, @cost_intensityLine);
verifyEqual(testCase, definition.validateExperimentConfigFcn, @validate_cost_intensityLine);
verifyFalse(testCase, definition.requiresBoneSurface);
end


function testValidatorReturnsCanonicalSettings(testCase)
%TESTVALIDATORRETURNSCANONICALSETTINGS Check one accepted configuration.
% testCase provides MATLAB verification methods. This function has no output.

% Single precision, a column list, and a shuffled field order show that the
% validator normalizes them.
fixedParameters = struct('sampleSpacingMm', single(0.1), 'intensityMax', 255);
hyperparameters = struct('intensitySmoothingSigmaMm', [0; 0.5; 1]);
[fixedParameters, hyperparameters] = ...
    validate_cost_intensityLine(fixedParameters, hyperparameters);

verifyEqual(testCase, fieldnames(fixedParameters).', {'intensityMax', 'sampleSpacingMm'});
verifyClass(testCase, fixedParameters.sampleSpacingMm, 'double');
verifyEqual(testCase, hyperparameters.intensitySmoothingSigmaMm, [0 0.5 1]);
end


function testValidatorRejectsInvalidSettings(testCase)
%TESTVALIDATORREJECTSINVALIDSETTINGS Check field names and value ranges.
% testCase provides MATLAB verification methods. This function has no output.

validFixed = struct('intensityMax', 255, 'sampleSpacingMm', 0.1);
validHyper = struct('intensitySmoothingSigmaMm', [0.5 1]);

verifyError(testCase, @() validate_cost_intensityLine( ...
    rmfield(validFixed, 'sampleSpacingMm'), validHyper), ...
    'validate_cost_intensityLine:MissingParameter');

% A setting this model does not have must not be accepted silently.
unknownHyper = validHyper;
unknownHyper.misspelledParameter = 1;
verifyError(testCase, @() validate_cost_intensityLine(validFixed, unknownHyper), ...
    'validate_cost_intensityLine:UnexpectedParameter');

negativeSigma = struct('intensitySmoothingSigmaMm', -0.5);
verifyError(testCase, @() validate_cost_intensityLine(validFixed, negativeSigma), ...
    'MATLAB:validate_cost_intensityLine:expectedNonnegative');

duplicateSigma = struct('intensitySmoothingSigmaMm', [1 1]);
verifyError(testCase, @() validate_cost_intensityLine(validFixed, duplicateSigma), ...
    'validate_cost_intensityLine:DuplicateCandidate');

zeroSpacing = validFixed;
zeroSpacing.sampleSpacingMm = 0;
verifyError(testCase, @() validate_cost_intensityLine(zeroSpacing, validHyper), ...
    'MATLAB:validate_cost_intensityLine:expectedPositive');
end


function testSmoothingIsGaussianInMillimetres(testCase)
%TESTSMOOTHINGISGAUSSIANINMILLIMETRES Check the blur on synthetic images.
% testCase provides MATLAB verification methods. This function has no output.

% A synthetic plane with non-square pixels: 0.2 mm wide and 0.1 mm high.
% Stored as [column, row], so the image array is nCols-by-nRows.
plane = struct('W', 10, 'H', 10, 'nCols', 50, 'nRows', 100, ...
               'image', uint8(7 * ones(50, 100)));

% A constant image must stay constant everywhere, also at the border.
smoothed = smoothUltrasoundImages(plane, 1);
verifyEqual(testCase, smoothed{1}, 7 * ones(50, 100), 'AbsTol', 1e-12);

% Sigma 0 returns the original image as double.
unsmoothed = smoothUltrasoundImages(plane, 0);
verifyEqual(testCase, unsmoothed{1}, double(plane.image));

% A single bright pixel must spread with a standard deviation of 1 mm along
% both axes, which is 5 pixels along the width and 10 along the height.
plane.image = zeros(50, 100);
plane.image(25, 50) = 1;
smoothed = smoothUltrasoundImages(plane, 1);
spreadAlongWidth  = sum(smoothed{1}, 2);
spreadAlongHeight = sum(smoothed{1}, 1).';
verifyEqual(testCase, weightedStandardDeviation(spreadAlongWidth),  5,  'RelTol', 0.02);
verifyEqual(testCase, weightedStandardDeviation(spreadAlongHeight), 10, 'RelTol', 0.02);
end


function testPreparationStoresSmoothedImages(testCase)
%TESTPREPARATIONSTORESSMOOTHEDIMAGES Check the prepared blurred images.
% testCase supplies the prepared data. This function has no output.

data           = testCase.TestData.data;
smoothedImages = data.extra.intensityLine.smoothedImages;

verifyEqual(testCase, numel(smoothedImages), numel(data.imagePlanesRef));
verifyEqual(testCase, size(smoothedImages{1}), size(data.imagePlanesRef(1).image));

% The blur must use the configured sigma.
expected = smoothUltrasoundImages(data.imagePlanesRef(1), ...
    testCase.TestData.config.cost.parameters.intensitySmoothingSigmaMm);
verifyEqual(testCase, smoothedImages{1}, expected{1});
end


function testCostIsOneMinusMeanPlaneEvidence(testCase)
%TESTCOSTISONEMINUSMEANPLANEEVIDENCE Check the cost equation.
% testCase supplies prepared real data. Every blurred image is replaced by a
% constant image, so each plane with visible bone must read exactly that
% constant, and each plane without visible bone must count as zero.

data   = testCase.TestData.data;
config = testCase.TestData.config;

constantIntensity = 51;   % 51 / 255 = 0.2 evidence
for planeIndex = 1:numel(data.imagePlanesRef)
    data.extra.intensityLine.smoothedImages{planeIndex} = ...
        constantIntensity * ones(size(data.imagePlanesRef(planeIndex).image));
end

[cost, details] = bonePoseCostFunction(zeros(6, 1), data, config);

planeHasBone     = details.perPlaneSampleCount > 0;
expectedEvidence = 0.2 * planeHasBone;
verifyGreaterThan(testCase, nnz(planeHasBone), 0);
verifyEqual(testCase, details.perPlaneEvidence, expectedEvidence, 'AbsTol', 1e-12);
verifyEqual(testCase, cost, 1 - mean(expectedEvidence), 'AbsTol', 1e-12);
verifyEqual(testCase, details.meanEvidence, 1 - cost, 'AbsTol', 1e-12);
end


function testPoseWithoutVisibleBoneHasMaximumCost(testCase)
%TESTPOSEWITHOUTVISIBLEBONEHASMAXIMUMCOST Check the worst case.
% Moving the bone half a metre away leaves no bone in any image, so no
% plane has evidence and the cost must be exactly 1.

[cost, details] = cost_intensityLine([500; 500; 500; 0; 0; 0], ...
    testCase.TestData.data, testCase.TestData.config);

verifyEqual(testCase, details.perPlaneSampleCount, zeros(size(details.perPlaneSampleCount)));
verifyEqual(testCase, cost, 1);
end


function testSamplingFollowsImagePixelConvention(testCase)
%TESTSAMPLINGFOLLOWSIMAGEPIXELCONVENTION Check where the image is read.
% Ramp images whose value equals the pixel's column (or row) number are
% read along the predicted lines. Linear interpolation reproduces a ramp
% exactly, so the mean read value is the mean continuous column (or row)
% position of the sample points. The established rasterizer puts a point at
% u mm into column floor(u / pixelWidth) + 1 (rows likewise). That pixel's
% number differs from the continuous position by at most half a pixel, so
% the two means must agree within 0.5. A swapped axis or a wrong scale
% would differ by tens to hundreds of pixels.

data   = testCase.TestData.data;
config = testCase.TestData.config;
config.cost.parameters.intensityMax = 1;   % Read values directly, not normalized.

for rampAxis = ["column", "row"]
    rampData = data;
    for planeIndex = 1:numel(data.imagePlanesRef)
        imageSize = size(data.imagePlanesRef(planeIndex).image);   % [nCols, nRows]
        [columnNumber, rowNumber] = ndgrid(1:imageSize(1), 1:imageSize(2));
        if rampAxis == "column"
            rampData.extra.intensityLine.smoothedImages{planeIndex} = columnNumber;
        else
            rampData.extra.intensityLine.smoothedImages{planeIndex} = rowNumber;
        end
    end

    [~, details] = cost_intensityLine(zeros(6, 1), rampData, config);

    for planeIndex = find(details.perPlaneSampleCount > 0)
        plane    = data.imagePlanesRef(planeIndex);
        sampleUV = details.perPlaneSampleUV{planeIndex};

        % Same rule as rasterizeSegment in selectProbeFacingIntersectionSegments.
        if rampAxis == "column"
            pixelNumber = min(max(floor(sampleUV(:, 1) / (plane.W / plane.nCols)) + 1, 1), plane.nCols);
        else
            pixelNumber = min(max(floor(sampleUV(:, 2) / (plane.H / plane.nRows)) + 1, 1), plane.nRows);
        end

        verifyEqual(testCase, details.perPlaneEvidence(planeIndex), mean(pixelNumber), 'AbsTol', 0.5, ...
            sprintf('%s ramp, plane %d', rampAxis, planeIndex));
    end
end
end


%%

function standardDeviation = weightedStandardDeviation(weights)
%WEIGHTEDSTANDARDDEVIATION Spread of a 1D weight profile around its mean.
% weights is a vector of nonnegative weights indexed 1..N; the result is the
% standard deviation of that index, in index units.

positions         = (1:numel(weights)).';
weights           = weights(:) / sum(weights);
meanPosition      = sum(positions .* weights);
standardDeviation = sqrt(sum((positions - meanPosition).^2 .* weights));
end
