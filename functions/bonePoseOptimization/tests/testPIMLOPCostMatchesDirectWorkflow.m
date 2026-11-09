function tests = testPIMLOPCostMatchesDirectWorkflow
%TESTPIMLOPCOSTMATCHESDIRECTWORKFLOW Compare cost_PIMLOP with the direct workflow.
% cost_PIMLOP moved the candidate-dependent P-IMLOP steps out of a readable
% demo script (examples/pimlop/demo_PDTreeSearch_NImageNPoints_batchProcessed)
% into one optimizer-facing function. That move should change only where
% the calculations live, not their result. This suite repeats the demo's
% steps directly (measurement selection, ref -> CT transform, per-image
% PD-tree search, summing) and checks that cost_PIMLOP gives the same
% total cost and the same correspondences, at the start pose and at one
% moved pose.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

% Let MATLAB discover every local function whose name starts with test.
tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Prepare the P-IMLOP one-sweep inputs once for this suite.
% testCase stores the prepared data and a reduced-measurement config. This
% function has no output.

% Walk from this test file through tests/, bonePoseOptimization/, and functions/.
testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Use the P-IMLOP template, so the data (including the PD-tree in
% data.extra.pimlop.PsiCT) is prepared exactly as for an optimization.
configPath = fullfile(projectRoot, 'config', 'optconfig_oneSweep_PIMLOP.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :), ...
    experimentPlan.runs.seed(1));
data = prepareBonePoseOptimizationInputs(config);

% Keep 5% of the measurements of every image: enough to cover all images,
% while keeping the two searches per pose fast.
config.cost.parameters.measurementSubsampleFraction = 0.05;

testCase.TestData.data   = data;
testCase.TestData.config = config;
end


function testCostMatchesAtInitialPose(testCase)
%TESTCOSTMATCHESATINITIALPOSE Check both paths agree at the coarse start pose.
% testCase supplies the prepared data. This function has no output.

verifyCostMatchesDirectWorkflow(testCase, zeros(6, 1));
end


function testCostMatchesAtMovedPose(testCase)
%TESTCOSTMATCHESATMOVEDPOSE Check both paths agree away from the start pose.
% A moved pose changes the ref -> CT transform and every image-to-CT
% rotation, so it checks that both paths apply them the same way.
% testCase supplies the prepared data. This function has no output.

movedPoseVector = [0.5; -0.25; 0.75; deg2rad(0.30); deg2rad(-0.20); deg2rad(0.40)];
verifyCostMatchesDirectWorkflow(testCase, movedPoseVector);
end


function verifyCostMatchesDirectWorkflow(testCase, poseVector)
%VERIFYCOSTMATCHESDIRECTWORKFLOW Compare cost_PIMLOP with the direct steps.
% testCase supplies the prepared data and config; poseVector is the
% candidate pose. This function has no output.

data   = testCase.TestData.data;
config = testCase.TestData.config;

[functionCost, functionDetails] = cost_PIMLOP(poseVector, data, config);
reference = evaluateDirectReference(poseVector, data, config);

% Which images were used, which source points were kept, and which mesh
% faces won are discrete results, so they must be exactly equal.
verifyEqual(testCase, functionDetails.processedImageMask, reference.processedImageMask);
verifyEqual(testCase, functionDetails.correspondenceIndex.imageIndex, reference.imageIndex);
verifyEqual(testCase, functionDetails.correspondenceIndex.sourcePointIndex, reference.sourcePointIndices);
verifyEqual(testCase, functionDetails.YmatchesCT.faceIndex, reference.YmatchesCT.faceIndex);

% The numbers only allow ordinary floating-point differences, far below
% the millimetre-scale position noise of the model.
verifyEqual(testCase, functionCost, reference.cost, 'AbsTol', 1e-8);
verifyEqual(testCase, functionDetails.EMatchValues, reference.EMatchValues, 'AbsTol', 1e-8);
verifyEqual(testCase, functionDetails.YmatchesCT.position3D, reference.YmatchesCT.position3D, 'AbsTol', 1e-7);
verifyEqual(testCase, functionDetails.YmatchesCT.normal3D, reference.YmatchesCT.normal3D, 'AbsTol', 1e-10);
end


function reference = evaluateDirectReference(poseVector, data, config)
%EVALUATEDIRECTREFERENCE Repeat the demo's P-IMLOP steps one by one.
% Inputs:
%   poseVector - Six-value candidate correction passed to stateVectorToTMatrix.
%   data       - Prepared data, including the PD-tree in data.extra.pimlop.PsiCT.
%   config     - Runtime configuration with the P-IMLOP cost parameters.
% Output:
%   reference  - Structure with the total cost, per-point errors, model
%                correspondences, source indices, and processed images.

% Read the noise model and search settings the same way cost_PIMLOP does.
parameters = config.cost.parameters;
positionStandardDeviationImageMm = [ ...
    parameters.positionXStandardDeviationImage; ...
    parameters.positionYStandardDeviationImage; ...
    parameters.positionZStandardDeviationImage];
positionCovarianceImage = diag(positionStandardDeviationImageMm .^ 2);
searchOptions = struct('UsePruning', true, 'QueryBatchSize', 64, 'MaxPairsPerBatch', 8192);
PsiCT = data.extra.pimlop.PsiCT;

% The PD-tree lives in CT, so the measured points move ref -> CT with the
% inverse of the candidate pose.
T_CT_ref_candidate = stateVectorToTMatrix(poseVector, data.T_CT_ref_initial, data.pivotPointRef);
R_CT_ref_candidate = T_CT_ref_candidate(1:3, 1:3);
t_CT_ref_candidate = T_CT_ref_candidate(1:3, 4);
T_ref_CT_candidate = [R_CT_ref_candidate.', -R_CT_ref_candidate.' * t_CT_ref_candidate; 0 0 0 1];

numberOfImages     = numel(data.imagePlanesRef);
processedImageMask = false(numberOfImages, 1);
matchErrorCells    = cell(numberOfImages, 1);
positionCells      = cell(numberOfImages, 1);
normalCells        = cell(numberOfImages, 1);
faceIndexCells     = cell(numberOfImages, 1);
imageIndexCells    = cell(numberOfImages, 1);
sourceIndexCells   = cell(numberOfImages, 1);

for planeIndex = 1:numberOfImages
    selectedPlane       = data.imagePlanesRef(planeIndex);
    selectedMeasurement = data.boneSurfaceMeasurements(planeIndex);

    % Keep only points with a valid normal; an image without any is skipped.
    validIndices = find(selectedMeasurement.surfaceNormalMask);
    if isempty(validIndices)
        continue;
    end
    positionsRef = double(selectedMeasurement.surfaceCoordinatesXYZRef(validIndices, :));
    normalsImage = double(selectedMeasurement.surfaceNormalXY(validIndices, :));
    normalsImage = normalsImage ./ vecnorm(normalsImage, 2, 2);

    % Keep an evenly spread subset along the curve, both ends included.
    numberOfValidMeasurements = numel(validIndices);
    numberToKeep = max(1, round(parameters.measurementSubsampleFraction * numberOfValidMeasurements));
    if numberToKeep == 1
        retainedRows = round((numberOfValidMeasurements + 1) / 2);
    else
        retainedRows = round(linspace(1, numberOfValidMeasurements, numberToKeep)).';
    end

    % Search this image's points in CT with this image's own rotation.
    T_image_CT = T_ref_CT_candidate * selectedPlane.T_image_ref;
    XqueriesCT = struct();
    XqueriesCT.position3D    = applyRigidTransform(positionsRef(retainedRows, :), T_ref_CT_candidate);
    XqueriesCT.normal2DImage = normalsImage(retainedRows, :);
    [YmatchesCT, EMatchValues] = searchPDTree_batchedProcess( ...
        XqueriesCT, PsiCT, T_image_CT(1:3, 1:3), ...
        positionCovarianceImage, parameters.kappa, searchOptions);

    processedImageMask(planeIndex) = true;
    matchErrorCells{planeIndex}  = EMatchValues;
    positionCells{planeIndex}    = YmatchesCT.position3D;
    normalCells{planeIndex}      = YmatchesCT.normal3D;
    faceIndexCells{planeIndex}   = YmatchesCT.faceIndex;
    imageIndexCells{planeIndex}  = repmat(planeIndex, numel(EMatchValues), 1);
    sourceIndexCells{planeIndex} = validIndices(retainedRows);
end

reference = struct();
reference.processedImageMask    = processedImageMask.';
reference.EMatchValues          = vertcat(matchErrorCells{:});
reference.cost                  = sum(reference.EMatchValues);
reference.YmatchesCT.position3D = vertcat(positionCells{:});
reference.YmatchesCT.normal3D   = vertcat(normalCells{:});
reference.YmatchesCT.faceIndex  = vertcat(faceIndexCells{:});
reference.imageIndex            = vertcat(imageIndexCells{:});
reference.sourcePointIndices    = vertcat(sourceIndexCells{:});
end
