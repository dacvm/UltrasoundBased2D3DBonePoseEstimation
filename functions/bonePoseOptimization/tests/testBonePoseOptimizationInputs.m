function tests = testBonePoseOptimizationInputs
%TESTBONEPOSEOPTIMIZATIONINPUTS Test the standardized input boundary.
% This suite checks the real standardized tibia artifacts, transform
% conventions, initial cost evaluation, and separation of validation ground
% truth from estimation data.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

% Let MATLAB discover every local function whose name starts with test.
tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Prepare the real standardized inputs once for this test suite.
% testCase stores the project root, configuration, prepared data, validation
% data, and initial evaluation shared by all tests. This function has no output.

% Walk from this test file through tests/, bonePoseOptimization/, and functions/.
testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));

% Add reusable project functions before reading the active configuration.
addpath(genpath(fullfile(projectRoot, 'functions')));

% Prepare the current standardized tibia inputs only once because intersection work is slow.
configPath = fullfile(projectRoot, 'config', ...
    'bonePoseOptimization_sanityCheckConfig_intensityCoverageCost.json');
experimentSpec = createBonePoseOptimizationExperimentConfig(configPath);
experimentPlan = createBonePoseOptimizationExperimentPlan(experimentSpec);
config = createBonePoseOptimizationRunConfig( ...
    experimentSpec, experimentPlan.combinations(1, :), ...
    experimentPlan.runs.seed(1));
[data, validationData] = prepareBonePoseOptimizationInputs(config);
[initialCost, initialDetails] = bonePoseCostFunction(zeros(6, 1), data, config);

% Store shared values under TestData so individual tests stay short and readable.
testCase.TestData.projectRoot = projectRoot;
testCase.TestData.config = config;
testCase.TestData.data = data;
testCase.TestData.validationData = validationData;
testCase.TestData.initialCost = initialCost;
testCase.TestData.initialDetails = initialDetails;
end


function testConfigurationUsesStandardizedInputs(testCase)
%TESTCONFIGURATIONUSESSTANDARDIZEDINPUTS Check the target and resolved paths.
% testCase supplies the parsed configuration. This function has no output.

% The current standardized experiment targets the tibia.
config = testCase.TestData.config;
verifyEqual(testCase, config.input.bone, 'T');

% Every configured input should resolve to an existing tool output.
verifyTrue(testCase, isfile(config.input.validSnapshotsMatFile));
verifyTrue(testCase, isfile(config.input.boneSurfaceMatFile));
verifyTrue(testCase, isfile(config.input.ctPostProcessedMatFile));
verifyTrue(testCase, isfile(config.input.coarseRegistrationMatFile));
end


function testPreparedDataAndGroundTruthStaySeparate(testCase)
%TESTPREPAREDDATAANDGROUNDTRUTHSTAYSEPARATE Check aligned but separate outputs.
% testCase supplies estimation and validation structs. This function has no output.

data = testCase.TestData.data;
validationData = testCase.TestData.validationData;

% The real review output contains five lateral, five medial, and five shaft planes.
verifyEqual(testCase, numel(data.imagePlanesRef), 15);
verifyEqual(testCase, numel(validationData.groundTruthIntersections), 15);
verifyEqual(testCase, numel(validationData.snapshotSources), 15);

% Ground truth must not be reachable through the struct passed to the optimizer.
verifyFalse(testCase, isfield(data, 'groundTruthIntersections'));
verifyFalse(testCase, isfield(data, 'groundTruthBonePose'));
verifyFalse(testCase, isfield(data, 'validationData'));

% Source names show that grouped review order was preserved while flattening.
sourceNames = string({validationData.snapshotSources.groupName});
expectedNames = [repmat("tibia_lateral", 1, 5), ...
                 repmat("tibia_medial", 1, 5), ...
                 repmat("tibia_shaft", 1, 5)];
verifyEqual(testCase, sourceNames, expectedNames);
end


function testBoneSurfacesAlignWithPreparedImages(testCase)
%TESTBONESURFACESALIGNWITHPREPAREDIMAGES Check the real Stage 6 input boundary.
% testCase supplies the prepared images, surfaces, and source identities. This
% function has no output.

data = testCase.TestData.data;
snapshotSources = testCase.TestData.validationData.snapshotSources;
boneSurfaceMeasurements = data.boneSurfaceMeasurements;

% The configured artifact should provide one surface measurement per image.
verifyTrue(testCase, data.hasBoneSurface);
verifyEqual(testCase, numel(boneSurfaceMeasurements), ...
    numel(data.imagePlanesRef));

% Group identity and sourceIndex show that flattening preserved correspondence.
verifyEqual(testCase, string({boneSurfaceMeasurements.groupName}), ...
    string({snapshotSources.groupName}));
verifyEqual(testCase, [boneSurfaceMeasurements.sourceIndex], ...
    [snapshotSources.sourceIndex]);
verifyEqual(testCase, unique(string({boneSurfaceMeasurements.status})), ...
    "extracted");

% The structured metadata removes ambiguity about image coordinates and beam direction.
metadata = data.boneSurfaceMetadata;
verifyEqual(testCase, metadata.coordinateConvention.indexBase, 1);
verifyEqual(testCase, metadata.coordinateConvention.coordinateOrder, ["x", "y"]);
verifyEqual(testCase, metadata.coordinateConvention.imageAxisByCoordinate, ...
    ["column", "row"]);
verifyEqual(testCase, metadata.coordinateConvention.origin, "topLeftPixelCenter");
verifyEqual(testCase, metadata.beamAxis.name, "row");
verifyEqual(testCase, metadata.beamAxis.matlabDimension, 1);
verifyEqual(testCase, metadata.beamDirection.name, "increasingRowIndex");
verifyEqual(testCase, metadata.beamDirection.rowIndexStep, 1);
end


function testRecoveredSurfacePointsMatchTheirImageCoordinates(testCase)
%TESTRECOVEREDSURFACEPOINTSMATCHTHEIRIMAGECOORDINATES Check 3D recovery once.
% testCase supplies aligned measurements and image planes. This function has
% no output.

data = testCase.TestData.data;
maximumPointErrorMm = 0;

for imageIndex = 1:numel(data.imagePlanesRef)
    measurement = data.boneSurfaceMeasurements(imageIndex);
    plane = data.imagePlanesRef(imageIndex);
    surfaceCoordinatesXY = double(measurement.surfaceCoordinatesXY);

    % Convert one-based image coordinates to millimetres on the local plane.
    pixelSpacingXYMm = [ ...
        double(plane.W) / (double(plane.nCols) - 1), ...
        double(plane.H) / (double(plane.nRows) - 1)];
    surfacePointsImage = [ ...
        (surfaceCoordinatesXY(:, 1) - 1) * pixelSpacingXYMm(1), ...
        (surfaceCoordinatesXY(:, 2) - 1) * pixelSpacingXYMm(2), ...
        zeros(size(surfaceCoordinatesXY, 1), 1)];

    % Recreate the reference-frame points independently from the saved 3D field.
    expectedSurfacePointsRef = applyRigidTransform( ...
        surfacePointsImage, plane.T_image_ref);
    pointErrorMm = max(abs(expectedSurfacePointsRef - ...
        double(measurement.surfaceCoordinatesXYZRef)), [], 'all');
    maximumPointErrorMm = max(maximumPointErrorMm, pointErrorMm);
end

verifyLessThanOrEqual(testCase, maximumPointErrorMm, 1e-8);
end


function testSurfaceRecordsCanBeReorderedBeforeMatching(testCase)
%TESTSURFACERECORDSCANBEREORDEREDBEFOREMATCHING Check identity-based matching.
% testCase supplies the real surface input and aligned snapshot sources. This
% function has no output.

config = testCase.TestData.config;
surfaceOutput = load(config.input.boneSurfaceMatFile, ...
    'surfaceResults', 'extractionMetadata');

% Reverse both group and record order to ensure array position is never identity.
surfaceOutput.surfaceResults = surfaceOutput.surfaceResults(end:-1:1);
for groupIndex = 1:numel(surfaceOutput.surfaceResults)
    surfaceOutput.surfaceResults(groupIndex).data = ...
        surfaceOutput.surfaceResults(groupIndex).data(end:-1:1);
end

collectedBoneSurface = collectBoneSurfaceMeasurements( ...
    surfaceOutput, config.input.bone);
boneSurface = alignBoneSurfacesToSnapshots( ...
    collectedBoneSurface, ...
    testCase.TestData.validationData.snapshotSources, ...
    config.input.validSnapshotsMatFile);

verifyEqual(testCase, [boneSurface.measurements.sourceIndex], ...
    [testCase.TestData.validationData.snapshotSources.sourceIndex]);
end


function testSurfaceProvenanceMustMatchSnapshots(testCase)
%TESTSURFACEPROVENANCEMUSTMATCHSNAPSHOTS Check the artifact-level relationship.
% testCase supplies the real surface and snapshot inputs. This function has
% no output.

config = testCase.TestData.config;
surfaceOutput = load(config.input.boneSurfaceMatFile, ...
    'surfaceResults', 'extractionMetadata');

% Change only the recorded source artifact so collection still succeeds and
% the explicit alignment boundary is responsible for rejecting the mismatch.
surfaceOutput.extractionMetadata.sourceUltrasoundFile = ...
    fullfile(tempdir, 'differentValidSnapshots.mat');
collectedBoneSurface = collectBoneSurfaceMeasurements( ...
    surfaceOutput, config.input.bone);

verifyError(testCase, @() alignBoneSurfacesToSnapshots( ...
    collectedBoneSurface, ...
    testCase.TestData.validationData.snapshotSources, ...
    config.input.validSnapshotsMatFile), ...
    'alignBoneSurfacesToSnapshots:SurfaceSourceMismatch');
end


function testIntensityCostDoesNotDependOnPreparedSurfaces(testCase)
%TESTINTENSITYCOSTDOESNOTDEPENDONPREPAREDSURFACES Protect the v1 objective.
% testCase supplies the configured Stage 6 data and its initial cost. This
% function has no output.

% Prepare the same inputs again after removing only the optional surface path.
configWithoutSurface = testCase.TestData.config;
configWithoutSurface.input.boneSurfaceMatFile = '';
[dataWithoutSurface, ~] = prepareBonePoseOptimizationInputs(configWithoutSurface);
[costWithoutSurface, detailsWithoutSurface] = bonePoseCostFunction( ...
    zeros(6, 1), dataWithoutSurface, configWithoutSurface);

verifyFalse(testCase, dataWithoutSurface.hasBoneSurface);
verifyEmpty(testCase, dataWithoutSurface.boneSurfaceMeasurements);
verifyEmpty(testCase, fieldnames(dataWithoutSurface.boneSurfaceMetadata));
verifyEqual(testCase, costWithoutSurface, testCase.TestData.initialCost, ...
    'AbsTol', 1e-12);
verifyEqual(testCase, detailsWithoutSurface.intensityCoverageCost, ...
    testCase.TestData.initialDetails.intensityCoverageCost, 'AbsTol', 1e-12);
verifyEqual(testCase, detailsWithoutSurface.missingPenaltyCost, ...
    testCase.TestData.initialDetails.missingPenaltyCost, 'AbsTol', 1e-12);
verifyEqual(testCase, detailsWithoutSurface.activePlaneMask, ...
    testCase.TestData.initialDetails.activePlaneMask);
end


function testGroundTruthBonePoseIsPreparedForValidation(testCase)
%TESTGROUNDTRUTHBONEPOSEISPREPAREDFORVALIDATION Check the selected saved pose.
% testCase supplies the CT model and validation-only pose. This function has
% no output.

% The validation pose must describe the same tibia selected for estimation.
data = testCase.TestData.data;
groundTruthBonePose = testCase.TestData.validationData.groundTruthBonePose;
verifyEqual(testCase, groundTruthBonePose.bone, 'T');
verifyTrue(testCase, isa(groundTruthBonePose.boneMeshRef, 'triangulation'));

% Both saved transforms use the project 4-by-4 column-vector convention.
verifySize(testCase, groundTruthBonePose.T_CT_ref, [4 4]);
verifySize(testCase, groundTruthBonePose.T_bone_ref, [4 4]);
verifyEqual(testCase, groundTruthBonePose.T_bone_ref, ...
    groundTruthBonePose.T_CT_ref * data.T_bone_CT, 'AbsTol', 1e-8);
end


function testInitialPoseProducesUsableCoverage(testCase)
%TESTINITIALPOSEPRODUCESUSABLECOVERAGE Check preparation and initial scoring.
% testCase supplies prepared counts and cost details. This function has no output.

data = testCase.TestData.data;
details = testCase.TestData.initialDetails;
minimumPixels = ...
    testCase.TestData.config.cost.parameters.minReferencePixels;

% Preparation must create one finite nonnegative reference count per plane.
verifyEqual(testCase, numel(data.nInitialIntersectionPixels), ...
    numel(data.imagePlanesRef));
verifyTrue(testCase, all(isfinite(data.nInitialIntersectionPixels)));
verifyTrue(testCase, all(data.nInitialIntersectionPixels >= 0));

% The cost must activate exactly the planes that meet its configured threshold.
expectedActivePlaneMask = ...
    data.nInitialIntersectionPixels >= minimumPixels;
verifyEqual(testCase, details.activePlaneMask, expectedActivePlaneMask);
verifyTrue(testCase, any(details.activePlaneMask));
verifyTrue(testCase, isfinite(testCase.TestData.initialCost));
verifyEqual(testCase, details.status, 'intensity_coverage_cost_computed');
end


function testFrameExplicitTransformConvention(testCase)
%TESTFRAMEEXPLICITTRANSFORMCONVENTION Check state conversion and composition.
% testCase supplies the initial transforms. This function has no output.

data = testCase.TestData.data;

% A zero state must reproduce the coarse CT-to-reference pose exactly.
T_CT_ref_zero = stateVectorToTMatrix(zeros(6, 1), data.T_CT_ref_initial);
verifyEqual(testCase, T_CT_ref_zero, data.T_CT_ref_initial, 'AbsTol', 1e-12);

% A small candidate state must survive a state-to-transform round trip.
stateVector = [1; -2; 0.5; deg2rad(1); deg2rad(-0.5); deg2rad(0.25)];
T_CT_ref_candidate = stateVectorToTMatrix(stateVector, data.T_CT_ref_initial);
recoveredStateVector = TMatrixToStateVector( ...
    T_CT_ref_candidate, data.T_CT_ref_initial);
verifyEqual(testCase, recoveredStateVector, stateVector, 'AbsTol', 1e-10);

% The stored initial anatomical frame must use the project composition rule.
verifyEqual(testCase, data.T_bone_ref_initial, ...
    data.T_CT_ref_initial * data.T_bone_CT, 'AbsTol', 1e-12);
end


function testSceneWithoutValidationShowsOnlyEstimate(testCase)
%TESTSCENEWITHOUTVALIDATIONSHOWSONLYESTIMATE Check the optional display path.
% testCase supplies prepared estimation data. This function has no output.

% Hide the smoke-test figure and restore the user's graphics default afterward.
previousFigureVisibility = get(groot, 'defaultFigureVisible');
visibilityCleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', previousFigureVisibility));
set(groot, 'defaultFigureVisible', 'off');

% Use the initial pose because this test checks graphics structure, not optimization.
displayBonePoseOptimizationScene( ...
    testCase.TestData.data, zeros(6, 1), testCase.TestData.config, ...
    'Estimated Pose Test');
fig = gcf;
figureCleanup = onCleanup(@() close(fig));

% The four-argument interface should keep the original estimate-only behavior.
verifyEqual(testCase, numel(findobj( ...
    fig, 'Tag', 'plot_bone_pose_estimated_mesh')), 1);
verifyEqual(testCase, numel(findobj( ...
    fig, 'Tag', 'plot_bone_pose_estimated_acs')), 4);
verifyEmpty(testCase, findobj( ...
    fig, 'Tag', 'plot_bone_pose_ground_truth_mesh'));
verifyEmpty(testCase, findobj( ...
    fig, 'Tag', 'plot_bone_pose_ground_truth_acs'));

% Trigger both cleanup objects before the next display test starts.
clear figureCleanup visibilityCleanup;
end


function testSceneWithValidationOverlaysGroundTruth(testCase)
%TESTSCENEWITHVALIDATIONOVERLAYSGROUNDTRUTH Check the comparison display path.
% testCase supplies aligned estimation and validation data. This function
% has no output.

% Hide the smoke-test figure and restore the user's graphics default afterward.
previousFigureVisibility = get(groot, 'defaultFigureVisible');
visibilityCleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', previousFigureVisibility));
set(groot, 'defaultFigureVisible', 'off');

% Pass validation data through the new fifth input to request the overlay.
displayBonePoseOptimizationScene( ...
    testCase.TestData.data, zeros(6, 1), testCase.TestData.config, ...
    'Ground-Truth Overlay Test', testCase.TestData.validationData);
fig = gcf;
figureCleanup = onCleanup(@() close(fig));

% The comparison scene should contain one mesh and one ACS group for each pose.
verifyEqual(testCase, numel(findobj( ...
    fig, 'Tag', 'plot_bone_pose_estimated_mesh')), 1);
verifyEqual(testCase, numel(findobj( ...
    fig, 'Tag', 'plot_bone_pose_ground_truth_mesh')), 1);
verifyEqual(testCase, numel(findobj( ...
    fig, 'Tag', 'plot_bone_pose_estimated_acs')), 4);
verifyEqual(testCase, numel(findobj( ...
    fig, 'Tag', 'plot_bone_pose_ground_truth_acs')), 4);

% Trigger both cleanup objects before returning from the test.
clear figureCleanup visibilityCleanup;
end


function testMissingInputFileReportsItsRole(testCase)
%TESTMISSINGINPUTFILEREPORTSITSROLE Check the simplest input failure message.
% testCase supplies a valid config that is copied and changed. This function has no output.

% Point only the snapshot input at a path that does not exist.
config = testCase.TestData.config;
config.input.validSnapshotsMatFile = fullfile( ...
    tempdir, 'missing_validSnapshots_for_bone_pose_test.mat');

% Preparation should stop at the missing standardized artifact.
verifyError(testCase, @() prepareBonePoseOptimizationInputs(config), ...
    'prepareBonePoseOptimizationInputs:MissingInputFile');
end


function testSkippedCoarseRegistrationCannotStartOptimization(testCase)
%TESTSKIPPEDCOARSEREGISTRATIONCANNOTSTARTOPTIMIZATION Check skipped-bone handling.
% testCase supplies the current files, whose femur registration is skipped.
% This function has no output.

% Select femur to confirm that a retained but skipped record is not used as a pose.
config = testCase.TestData.config;
config.input.bone = 'F';
verifyError(testCase, @() prepareBonePoseOptimizationInputs(config), ...
    'prepareBonePoseOptimizationInputs:BoneNotRegistered');
end
