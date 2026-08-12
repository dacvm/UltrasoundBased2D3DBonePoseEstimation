function tests = testBonePoseOptimizationV02
%TESTBONEPOSEOPTIMIZATIONV02 Test the standardized v02 input boundary.
% This test suite checks the real standardized tibia artifacts, transform
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

% Add project helpers exactly as the v02 main script does.
addpath(genpath(fullfile(projectRoot, 'functions')));

% Prepare the current standardized tibia inputs only once because intersection work is slow.
configPath = fullfile(projectRoot, 'config', 'bonePoseOptimizationConfig_v02.json');
config = createBonePoseOptimizationConfig(configPath);
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
%TESTCONFIGURATIONUSESSTANDARDIZEDINPUTS Check the v02 target and resolved paths.
% testCase supplies the parsed configuration. This function has no output.

% The current standardized experiment targets the tibia.
config = testCase.TestData.config;
verifyEqual(testCase, config.input.bone, 'T');

% Every configured input should resolve to an existing tool output.
verifyTrue(testCase, isfile(config.input.validSnapshotsMatFile));
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
verifyFalse(testCase, isfield(data, 'validationData'));

% Source names show that grouped review order was preserved while flattening.
sourceNames = string({validationData.snapshotSources.groupName});
expectedNames = [repmat("tibia_lateral", 1, 5), ...
                 repmat("tibia_medial", 1, 5), ...
                 repmat("tibia_shaft", 1, 5)];
verifyEqual(testCase, sourceNames, expectedNames);
end


function testInitialPoseProducesUsableCoverage(testCase)
%TESTINITIALPOSEPRODUCESUSABLECOVERAGE Check preparation and initial scoring.
% testCase supplies prepared counts and cost details. This function has no output.

data = testCase.TestData.data;
details = testCase.TestData.initialDetails;
minimumPixels = testCase.TestData.config.cost.minReferencePixels;

% Preparation must create one finite nonnegative reference count per plane.
verifyEqual(testCase, numel(data.nInitialIntersectionPixels), ...
    numel(data.imagePlanesRef));
verifyTrue(testCase, all(isfinite(data.nInitialIntersectionPixels)));
verifyTrue(testCase, all(data.nInitialIntersectionPixels >= 0));

% All planes in the current reviewed tibia set are usable at the coarse pose.
verifyTrue(testCase, all(data.nInitialIntersectionPixels >= minimumPixels));
verifyTrue(testCase, all(details.activePlaneMask));
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
