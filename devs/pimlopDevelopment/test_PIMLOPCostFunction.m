function report = test_PIMLOPCostFunction()
%TEST_PIMLOPCOSTFUNCTION Compare the new cost function with the direct workflow.
% This focused regression test verifies that cost_PIMLOP_v01 performs the
% same measurement selection, coordinate transformations, PD-tree searches,
% correspondence ordering, and total-cost calculation as the direct workflow
% demonstrated by demo_PDTreeSearch_NImageNPoints_batchProcessed.
%
% Why this test is needed
% -----------------------
% Moving candidate-dependent calculations from a readable script into one
% optimizer-facing function should change only where the calculations live,
% not their result. The test evaluates both paths with the same fixed PD-tree
% at the initial pose and at one nonzero pose.
%
% Input
% -----
% This function has no input. It loads optimization_setup.mat from the same
% folder and uses a small deterministic measurement fraction so the test
% remains practical to run during development.
%
% Output
% ------
% report : Structure array with one entry per tested pose. Each entry records
%     the scalar-cost difference, maximum per-point cost difference, maximum
%     model-position and model-normal differences, and tested point count.

%% 1. LOAD THE TEST DATA AND PREPARE ONE SHARED CT MODEL

testFolder  = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(testFolder));
addpath(genpath(fullfile(projectRoot, 'functions')));
addpath(testFolder);

loadedSetup = load(fullfile(testFolder, 'optimization_setup.mat'), 'data');
data = loadedSetup.data;

% Use enough measurements from every image to exercise the multi-image
% grouping while keeping this regression test much faster than the visual
% demonstration, which intentionally uses half of all valid measurements.
config = createTestPIMLOPConfig(0.05, [1.0;1.0;1.5], 50);

PsiCT = preparePIMLOPModel_batchedProcess(data.boneMeshCT);
PsiCT.pdTree = buildPIMLOPPDTree_batchedProcess( ...
    PsiCT.mesh, PsiCT.validFaceMask);

if ~isfield(data, 'extra')
    data.extra = struct();
end
data.extra.pimlop = struct('PsiCT', PsiCT);

%% 2. DEFINE TWO DETERMINISTIC CANDIDATE POSES

% The zero state verifies exact agreement at the coarse registration. The
% second state verifies that agreement is preserved when inverse query
% transformation and image-to-CT rotations genuinely change.
poseVectors = [ ...
    zeros(6,1), ...
    [0.5; -0.25; 0.75; deg2rad(0.30); deg2rad(-0.20); deg2rad(0.40)]];
poseNames = ["initial pose", "nonzero pose"];

emptyReport = struct( ...
    'poseName', "", ...
    'numberOfMeasurements', 0, ...
    'costFunctionValue', NaN, ...
    'referenceValue', NaN, ...
    'costDifference', NaN, ...
    'maximumMatchErrorDifference', NaN, ...
    'maximumPositionDifferenceMm', NaN, ...
    'maximumNormalDifference', NaN);
report = repmat(emptyReport, size(poseVectors,2), 1);

%% 3. COMPARE THE FUNCTION PATH WITH THE DIRECT REFERENCE PATH

for poseNumber = 1:size(poseVectors,2)
    poseVector = poseVectors(:,poseNumber);

    % The function path is the new implementation that CMA-ES will later use.
    [functionCost, functionDetails] = cost_PIMLOP_v01( ...
        poseVector, data, config);

    % The reference path intentionally performs the transformations and
    % per-image searches directly, following the established demonstration.
    reference = evaluateDirectReference( ...
        poseVector, data, config, PsiCT);

    costDifference = abs(functionCost - reference.cost);
    matchErrorDifference = max(abs( ...
        functionDetails.EMatchValues - reference.EMatchValues));
    positionDifferenceMm = max(vecnorm( ...
        functionDetails.YmatchesCT.position3D - ...
        reference.YmatchesCT.position3D, 2, 2));
    normalDifference = max(vecnorm( ...
        functionDetails.YmatchesCT.normal3D - ...
        reference.YmatchesCT.normal3D, 2, 2));

    % Source identities and selected mesh faces are discrete results. Require
    % exact equality rather than applying a floating-point tolerance.
    assert(isequal(functionDetails.processedImageMask, ...
        reference.processedImageMask), ...
        'Processed-image masks differ at the %s.', poseNames(poseNumber));
    assert(isequal(functionDetails.correspondenceIndex.imageIndex, ...
        reference.imageIndex), ...
        'Combined image indices differ at the %s.', poseNames(poseNumber));
    assert(isequal(functionDetails.correspondenceIndex.sourcePointIndex, ...
        reference.sourcePointIndices), ...
        'Source-point indices differ at the %s.', poseNames(poseNumber));
    assert(isequal(functionDetails.YmatchesCT.faceIndex, ...
        reference.YmatchesCT.faceIndex), ...
        'Selected mesh faces differ at the %s.', poseNames(poseNumber));

    % These tolerances are much smaller than the millimetre-scale covariance
    % and only allow ordinary floating-point arithmetic differences.
    assert(costDifference < 1e-8, ...
        'Total P-IMLOP cost differs at the %s.', poseNames(poseNumber));
    assert(matchErrorDifference < 1e-8, ...
        'Per-point P-IMLOP costs differ at the %s.', poseNames(poseNumber));
    assert(positionDifferenceMm < 1e-7, ...
        'Selected model positions differ at the %s.', poseNames(poseNumber));
    assert(normalDifference < 1e-10, ...
        'Selected model normals differ at the %s.', poseNames(poseNumber));

    report(poseNumber).poseName = poseNames(poseNumber);
    report(poseNumber).numberOfMeasurements = ...
        functionDetails.numberOfMeasurements;
    report(poseNumber).costFunctionValue = functionCost;
    report(poseNumber).referenceValue = reference.cost;
    report(poseNumber).costDifference = costDifference;
    report(poseNumber).maximumMatchErrorDifference = ...
        matchErrorDifference;
    report(poseNumber).maximumPositionDifferenceMm = ...
        positionDifferenceMm;
    report(poseNumber).maximumNormalDifference = normalDifference;

    fprintf(['P-IMLOP cost test passed for %s: %d points, ' ...
        'cost difference %.3g, position difference %.3g mm.\n'], ...
        poseNames(poseNumber), ...
        functionDetails.numberOfMeasurements, ...
        costDifference, positionDifferenceMm);
end
end


function config = createTestPIMLOPConfig( ...
    measurementSubsampleFraction, positionStandardDeviationImageMm, kappa)
%CREATETESTPIMLOPCONFIG Create the scalar runtime settings used by this test.
% Inputs:
%   measurementSubsampleFraction - Fraction of valid measurements retained
%                                  independently from every image.
%   positionStandardDeviationImageMm - Three image-axis standard deviations
%                                      [sx;sy;sz] in millimetres.
%   kappa - Nonnegative orientation concentration used by E_match.
% Output:
%   config - Minimal runtime configuration accepted by cost_PIMLOP_v01.

config = struct();
config.cost = struct();
config.cost.model = 'PIMLOP_v1';
config.cost.parameters = struct();
config.cost.parameters.measurementSubsampleFraction = ...
    measurementSubsampleFraction;
config.cost.parameters.positionStandardDeviationImageXmm = ...
    positionStandardDeviationImageMm(1);
config.cost.parameters.positionStandardDeviationImageYmm = ...
    positionStandardDeviationImageMm(2);
config.cost.parameters.positionStandardDeviationImageZmm = ...
    positionStandardDeviationImageMm(3);
config.cost.parameters.kappa = kappa;
end


function reference = evaluateDirectReference(poseVector, data, config, PsiCT)
%EVALUATEDIRECTREFERENCE Reproduce the established script workflow directly.
% Inputs:
%   poseVector - Six-value candidate correction passed to stateVectorToTMatrix.
%   data - Prepared ultrasound and bone data loaded by the test.
%   config - P-IMLOP scalar runtime settings used by both comparison paths.
%   PsiCT - Fixed CT-oriented model containing the already built PD-tree.
% Output:
%   reference - Structure containing the direct total cost, per-point errors,
%               model correspondences, source indices, and processed images.

parameters = config.cost.parameters;
measurementSubsampleFraction = ...
    parameters.measurementSubsampleFraction;
positionStandardDeviationImageMm = [ ...
    parameters.positionStandardDeviationImageXmm; ...
    parameters.positionStandardDeviationImageYmm; ...
    parameters.positionStandardDeviationImageZmm];
positionCovarianceImage = diag( ...
    positionStandardDeviationImageMm .^ 2);
kappa = parameters.kappa;
searchOptions = struct( ...
    'UsePruning', true, ...
    'QueryBatchSize', 64, ...
    'MaxPairsPerBatch', 8192);

T_CT_ref_candidate = stateVectorToTMatrix( ...
    poseVector, data.T_CT_ref_initial);
R_CT_ref_candidate = T_CT_ref_candidate(1:3,1:3);
t_CT_ref_candidate = T_CT_ref_candidate(1:3,4);
T_ref_CT_candidate = eye(4);
T_ref_CT_candidate(1:3,1:3) = R_CT_ref_candidate.';
T_ref_CT_candidate(1:3,4) = ...
    -R_CT_ref_candidate.' * t_CT_ref_candidate;

numberOfImages = numel(data.imagePlanesRef);
processedImageMask = false(numberOfImages,1);
matchErrorCells = cell(numberOfImages,1);
positionCells = cell(numberOfImages,1);
normalCells = cell(numberOfImages,1);
faceIndexCells = cell(numberOfImages,1);
imageIndexCells = cell(numberOfImages,1);
sourceIndexCells = cell(numberOfImages,1);

for planeIndex = 1:numberOfImages
    selectedPlane = data.imagePlanesRef(planeIndex);
    selectedMeasurement = data.boneSurfaceMeasurements(planeIndex);

    allPositionsRef = double( ...
        selectedMeasurement.surfaceCoordinatesXYZRef);
    allNormalsImage = double(selectedMeasurement.surfaceNormalXY);
    validIndices = find(selectedMeasurement.surfaceNormalMask);
    if isempty(validIndices)
        continue;
    end

    positionsRef = allPositionsRef(validIndices,:);
    normalsImage = allNormalsImage(validIndices,:);
    normalsImage = normalsImage ./ vecnorm(normalsImage,2,2);

    numberOfValidMeasurements = numel(validIndices);
    numberToKeep = max(1, round( ...
        measurementSubsampleFraction * numberOfValidMeasurements));
    if numberToKeep == 1
        retainedRows = round((numberOfValidMeasurements + 1) / 2);
    else
        retainedRows = round(linspace( ...
            1, numberOfValidMeasurements, numberToKeep)).';
    end

    positionsRef = positionsRef(retainedRows,:);
    normalsImage = normalsImage(retainedRows,:);
    sourcePointIndices = validIndices(retainedRows);

    T_image_CT = T_ref_CT_candidate * selectedPlane.T_image_ref;
    R_image_CT = T_image_CT(1:3,1:3);
    XqueriesCT = struct();
    XqueriesCT.position3D = applyRigidTransform( ...
        positionsRef, T_ref_CT_candidate);
    XqueriesCT.normal2DImage = normalsImage;

    [YmatchesCT, EMatchValues] = searchPDTree_batchedProcess( ...
        XqueriesCT, PsiCT, R_image_CT, ...
        positionCovarianceImage, kappa, searchOptions);

    numberOfRetainedMeasurements = numel(EMatchValues);
    processedImageMask(planeIndex) = true;
    matchErrorCells{planeIndex} = EMatchValues;
    positionCells{planeIndex} = YmatchesCT.position3D;
    normalCells{planeIndex} = YmatchesCT.normal3D;
    faceIndexCells{planeIndex} = YmatchesCT.faceIndex;
    imageIndexCells{planeIndex} = repmat( ...
        planeIndex, numberOfRetainedMeasurements, 1);
    sourceIndexCells{planeIndex} = sourcePointIndices;
end

reference = struct();
reference.processedImageMask = processedImageMask.';
reference.EMatchValues = vertcat(matchErrorCells{:});
reference.cost = sum(reference.EMatchValues);
reference.YmatchesCT = struct();
reference.YmatchesCT.position3D = vertcat(positionCells{:});
reference.YmatchesCT.normal3D = vertcat(normalCells{:});
reference.YmatchesCT.faceIndex = vertcat(faceIndexCells{:});
reference.imageIndex = vertcat(imageIndexCells{:});
reference.sourcePointIndices = vertcat(sourceIndexCells{:});
end
