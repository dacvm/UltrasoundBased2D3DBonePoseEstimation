function tests = testCalculateRegistrationResidualRmseMm
%TESTCALCULATEREGISTRATIONRESIDUALRMSEMM Test the registration residual metric.
% This suite checks that the residual is the RMSE from the measured points
% to the mesh at the given pose, using a flat mesh where the answer is known.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Add project functions and build the flat-mesh test data.
% testCase stores the synthetic data in TestData. This function has no output.

testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));

testCase.TestData.data = createFlatMeshData();
end


function testResidualAtStartPose(testCase)
%TESTRESIDUALATSTARTPOSE Check the residual with no pose change.
% testCase supplies the synthetic data. This function has no output.

% The mesh is the plane z = 0 and the points lie 1, 2 and 3 mm above it,
% so the residual is sqrt((1 + 4 + 9) / 3).
residualRmseMm = calculateRegistrationResidualRmseMm(zeros(6, 1), testCase.TestData.data);
verifyEqual(testCase, residualRmseMm, sqrt(14 / 3), 'AbsTol', 1e-12);
end


function testResidualFollowsThePose(testCase)
%TESTRESIDUALFOLLOWSTHEPOSE Check that the pose moves the mesh.
% testCase supplies the synthetic data. This function has no output.

% Lifting the mesh by 2 mm puts it 1, 0 and 1 mm away from the points.
poseVector = [0; 0; 2; 0; 0; 0];
residualRmseMm = calculateRegistrationResidualRmseMm(poseVector, testCase.TestData.data);
verifyEqual(testCase, residualRmseMm, sqrt(2 / 3), 'AbsTol', 1e-12);
end


function data = createFlatMeshData()
%CREATEFLATMESHDATA Build the smallest prepared-data struct the residual needs.
% This function has no input. data holds a flat 6-by-6 vertex mesh in the
% plane z = 0, three measured points above its middle, identity start
% transforms, and the same point-to-mesh search structures that
% prepareBonePoseOptimizationInputs builds.

% A 6-by-6 grid gives 36 vertices, more than the 20 nearest vertices the
% residual searches for each point.
[gridX, gridY] = meshgrid(0:5, 0:5);
meshPoints = [gridX(:), gridY(:), zeros(numel(gridX), 1)];
data.boneMeshCT = triangulation(delaunay(gridX(:), gridY(:)), meshPoints);

% With identity transforms the CT, bone and ref frames are the same.
data.T_CT_ref_initial = eye(4);
data.T_bone_CT        = eye(4);
data.pivotPointRef    = [2.5; 2.5; 0];

% Two "images": the first measures two points, the second one point.
data.boneSurfaceMeasurements(1).surfaceCoordinatesXYZRef = [2.2 2.3 1; 2.7 2.1 2];
data.boneSurfaceMeasurements(2).surfaceCoordinatesXYZRef = [2.4 2.6 3];

% Build the vertex KD-tree and the vertex-to-face table the same way as
% prepareBonePoseOptimizationInputs: each row is padded to the same width
% by repeating the vertex's first face.
numberOfVertices  = size(meshPoints, 1);
attachedFaceCells = vertexAttachments(data.boneMeshCT, (1:numberOfVertices).');
facesPerVertex    = max(cellfun(@numel, attachedFaceCells));
faceIndicesByVertex = zeros(numberOfVertices, facesPerVertex);
for vertexIndex = 1:numberOfVertices
    attachedFaces   = attachedFaceCells{vertexIndex};
    numberOfRepeats = facesPerVertex - numel(attachedFaces);
    faceIndicesByVertex(vertexIndex, :) = [attachedFaces, repmat(attachedFaces(1), 1, numberOfRepeats)];
end
data.extra.icpLike.vertexTreeCT        = KDTreeSearcher(meshPoints);
data.extra.icpLike.faceIndicesByVertex = faceIndicesByVertex;
end
