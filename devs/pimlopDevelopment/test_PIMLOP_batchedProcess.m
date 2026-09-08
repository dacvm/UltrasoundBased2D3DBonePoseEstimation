function report = test_PIMLOP_batchedProcess(includeRealData)
%TEST_PIMLOP_BATCHEDPROCESS Verify batch arithmetic against scalar references.
%   Tests exercise complete triangle minimization, projected-normal costs,
%   anisotropic ellipsoid/box tests, and query-specific pruning. No parallel
%   workers are used and no project inputs or figures are modified.
%
%   Input
%   -----
%   includeRealData : Optional logical flag, default true. True also tests
%       the first five and last five valid measurements from image 11 in
%       optimization_setup.mat. False runs only deterministic synthetic tests.
%   Output
%   ------
%   report : Maximum numerical differences and, when real data is requested,
%       scalar/batched timings for the same ten queries. Assertions fail if
%       costs, geometry, pruning, or batch-size invariance disagree.

if nargin < 1, includeRealData = true; end
folder = fileparts(mfilename('fullpath'));
addpath(folder);
previousRandomState = rng;
restoreRandomState = onCleanup(@() rng(previousRandomState));
rng(47);
report = struct();

% Check analytically known interior, edge, and vertex cases before comparing
% against another implementation. This catches an accidental boundary-only solver.
triangle = [0 0 0;4 0 0;0 4 0];
[positions,weights] = findMostLikelyPointOnTriangle_batchedProcess( ...
    [1 1 2;3 3 2;-1 -1 1],triangle,eye(3));
assert(norm(reshape(positions,3,3)-[1 1 0;2 2 0;0 0 0],'fro') < 1e-12);
assert(norm(reshape(weights,3,3)-[0.5 0.25 0.25;0 0.5 0.5;1 0 0],'fro') < 1e-12);

% Random nondegenerate triangles and an off-axis anisotropic covariance test
% all query/triangle combinations, including singleton batch dimensions.
triangles = randn(3,3,17)*3;
queries = randn(11,3)*4;
A = [1 .3 -.1;.2 2 .4;.1 -.2 .7];
Sigma = A*A.';
[positions,weights,squaredDistances] = findMostLikelyPointOnTriangle_batchedProcess(queries,triangles,Sigma);
maxPositionDifference = 0;
maxDistanceDifference = 0;
for i = 1:size(queries,1)
    for j = 1:size(triangles,3)
        [ys,bs] = findMostLikelyPointOnTriangle(queries(i,:).',triangles(:,:,j),Sigma);
        yb = reshape(positions(i,j,:),3,1);
        bb = reshape(weights(i,j,:),3,1);
        residual = ys-queries(i,:).';
        maxPositionDifference = max(maxPositionDifference,norm(ys-yb));
        maxDistanceDifference = max(maxDistanceDifference,abs(squaredDistances(i,j)-residual.'*(Sigma\residual)));
        assert(norm(bs-bb) < 1e-8 && min(bb) >= -1e-12 && abs(sum(bb)-1) < 1e-12);
    end
end
assert(maxPositionDifference < 1e-8 && maxDistanceDifference < 1e-8);
report.trianglePositionDifferenceMm = maxPositionDifference;
report.triangleDistanceDifference = maxDistanceDifference;

% Compare numerical-only paired costs with the original full diagnostic path.
% Include an exactly undefined projection and its original zero-agreement rule.
X = struct('position3D',queries,'normal2DImage',randn(11,2));
Y = struct('position3D',randn(11,3),'normal3D',randn(11,3));
Y.normal3D(1,:) = [0 0 1];
[eb,db] = calculatePIMLOPMatchError_batchedProcess(X,Y,eye(3),Sigma,50);
assert(~db.projectionIsDefined(1));
maxCostDifference = 0;
for i = 1:11
    xs = struct('position3D',X.position3D(i,:).','normal2DImage',X.normal2DImage(i,:).');
    ys = struct('position3D',Y.position3D(i,:).','normal3D',Y.normal3D(i,:).');
    [es,ds] = calculatePIMLOPMatchError(xs,ys,eye(3),Sigma,50);
    maxCostDifference = max(maxCostDifference,abs(es-eb(i)));
    assert(abs(ds.orientationAngleDeg-db.orientationAngleDeg(i)) < 1e-10);
end
assert(maxCostDifference < 1e-9);
report.pairedCostDifference = maxCostDifference;

% Compare the 27-feature box minimum for many queries, including different
% ellipsoid radii. The same node is allowed to survive for only some queries.
[rotation,~] = qr(randn(3));
if det(rotation) < 0, rotation(:,3) = -rotation(:,3); end
node.T_node_CT = [rotation,[1;2;3];0 0 0 1];
node.boundsMinNode = [-2 -1 -.5];
node.boundsMaxNode = [1 3 2];
limits = linspace(0,20,11).';
[keepBatch,distBatch] = ellipsoidIntersectsOBB_batchedProcess(queries,inv(Sigma),limits,node);
maxBoxDifference = 0;
for i = 1:11
    [keepScalar,distScalar] = ellipsoidIntersectsOBB(queries(i,:).',inv(Sigma),limits(i),node);
    assert(keepScalar == keepBatch(i));
    maxBoxDifference = max(maxBoxDifference,abs(distScalar-distBatch(i)));
end
assert(maxBoxDifference < 1e-9);
report.boxDistanceDifference = maxBoxDifference;

% Analytic zero-radius containment and exact tangency guard the <= comparison.
node.T_node_CT = eye(4);
node.boundsMinNode = [0 0 0]; node.boundsMaxNode = [1 1 1];
keep = ellipsoidIntersectsOBB_batchedProcess([.5 .5 .5;2 .5 .5;2 .5 .5],eye(3),[0;.5;.49],node);
assert(isequal(keep,[true;true;false]));

% A tiny mesh lets us test kappa=0, arbitrary batch sizes, and exhaustive
% versus pruned traversal independently of the real-data setup file.
vertices = reshape(permute(triangles,[1 3 2]),[],3);
faces = reshape(1:size(vertices,1),3,[]).';
model = preparePIMLOPModel_batchedProcess(triangulation(faces,vertices));
model.pdTree = buildPIMLOPPDTree_batchedProcess(model.mesh,model.validFaceMask, ...
    struct('faceCountThreshold',2,'minimumNodeDiagonalMm',0));
[yt,et] = searchPDTree_batchedProcess(X,model,rotation,Sigma,0);
[ye,ee] = searchPDTree_batchedProcess(X,model,rotation,Sigma,0, ...
    struct('UsePruning',false,'QueryBatchSize',1,'MaxPairsPerBatch',1));
assert(max(abs(et-ee)) < 1e-8 && max(vecnorm(yt.position3D-ye.position3D,2,2)) < 1e-8);
fprintf('Synthetic batch tests passed. Triangle delta %.3g mm; cost delta %.3g; box delta %.3g.\n', ...
    maxPositionDifference,maxCostDifference,maxBoxDifference);

if ~includeRealData, return; end

% Test exactly ten endpoint measurements. Original scalar search is the
% independent pruning/traversal reference; the batch exhaustive run checks
% that grouped query bounds never reject a winning face.
loaded = load(fullfile(folder,'optimization_setup.mat'),'data');
data = loaded.data;
model = preparePIMLOPModel_batchedProcess(data.boneMeshCT);
model.pdTree = buildPIMLOPPDTree_batchedProcess(model.mesh,model.validFaceMask);
measurement = data.boneSurfaceMeasurements(11);
valid = find(measurement.surfaceNormalMask);
selected = valid([1:5,end-4:end]);
T = data.T_CT_ref_initial;
R = T(1:3,1:3);
Rp = R.'*data.imagePlanesRef(11).T_image_ref(1:3,1:3);
SigmaImage = diag([1 1 1.5].^2);
X.position3D = (measurement.surfaceCoordinatesXYZRef(selected,:)-T(1:3,4).')*R;
X.normal2DImage = measurement.surfaceNormalXY(selected,:);
timer = tic;
[yb,eb,details] = searchPDTree_batchedProcess(X,model,Rp,SigmaImage,50);
report.batchTenQuerySeconds = toc(timer);
ys = zeros(10,3); es = zeros(10,1); scalarFaces = zeros(10,1);
timer = tic;
for i = 1:10
    query.position3D = X.position3D(i,:).';
    query.normal2DImage = X.normal2DImage(i,:).';
    [match,es(i)] = searchPDTree(query,model,Rp,SigmaImage,50);
    ys(i,:) = match.position3D.';
    scalarFaces(i) = match.faceIndex;
end
report.scalarTenQuerySeconds = toc(timer);
report.realPositionDifferenceMm = max(vecnorm(yb.position3D-ys,2,2));
report.realCostDifference = max(abs(eb-es));
assert(report.realPositionDifferenceMm < 1e-7 && report.realCostDifference < 1e-8);
assert(isequal(yb.faceIndex,scalarFaces));
[ye,ee] = searchPDTree_batchedProcess(X,model,Rp,SigmaImage,50,struct('UsePruning',false));
assert(max(abs(eb-ee)) < 1e-8 && max(vecnorm(yb.position3D-ye.position3D,2,2)) < 1e-7);
[ysmall,esmall] = searchPDTree_batchedProcess(X,model,Rp,SigmaImage,50, ...
    struct('QueryBatchSize',3,'MaxPairsPerBatch',32));
assert(max(abs(eb-esmall)) < 1e-8 && max(vecnorm(yb.position3D-ysmall.position3D,2,2)) < 1e-7);
report.endpointIndices = selected;
report.endpointBarycentricCoordinates = details.barycentricCoordinates;
fprintf('Ten endpoint queries passed: position delta %.3g mm, cost delta %.3g.\n', ...
    report.realPositionDifferenceMm,report.realCostDifference);
fprintf('Same ten queries: scalar %.3f s, batch %.3f s (%.1fx).\n', ...
    report.scalarTenQuerySeconds,report.batchTenQuerySeconds, ...
    report.scalarTenQuerySeconds/report.batchTenQuerySeconds);
end
