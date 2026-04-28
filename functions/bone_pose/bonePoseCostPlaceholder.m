function [cost, details] = bonePoseCostPlaceholder(poseVector, data, config)
%BONEPOSECOSTPLACEHOLDER Placeholder for the future image-intensity cost function.
% This function declaration defines the cost-function entry point that an optimizer can call later.
%
% What this function does:
%   This placeholder shows the intended shape of the future cost function.
%   It receives a pose vector, converts that vector into a candidate mesh
%   transform, computes probe-facing intersection pixels for that pose, and
%   then returns a scalar cost value.
%
% Why this function exists:
%   A future optimizer needs one function that answers the question:
%   "How good is this candidate bone pose?" This placeholder already wires
%   together the geometry pieces needed to answer that question later. The
%   only missing part is the actual image-intensity scoring.
%
% Inputs:
%   poseVector:
%       Candidate pose parameters from the future optimizer.
%
%   data:
%       Prepared data from prepareBonePoseOptimizationInputs. This includes
%       the mesh, image planes, and initial transform.
%
%   config:
%       Optional nested configuration struct. If omitted, data.config is
%       used.
%
% Outputs:
%   cost:
%       Placeholder scalar cost. It currently returns 0. In the future this
%       should become the objective value that the optimizer minimizes.
%
%   details:
%       Debug information containing the candidate transform, transformed
%       mesh, and per-plane probe-facing pixels.
%
%
% Important details:
%   - Keep expensive plotting out of this function.
%   - A cost function should always return one numeric scalar.
%   - The details output is useful for debugging from scripts, but most
%     optimizers will only use the first output, cost.

%% HANDLE OPTIONAL CONFIGURATION

% Use the configuration stored with the prepared data when the caller does not pass one explicitly.
if nargin < 3 || isempty(config)
    config = data.config;
end

%% CONVERT POSE VECTOR TO MESH TRANSFORM

% Convert the candidate pose parameters to a 4x4 mesh transform using the future pose-convention placeholder.
T_candidateMeshToReference = poseVectorToTransformPlaceholder(poseVector, data.T_init_originct);

%% COMPUTE PROBE-FACING PIXELS

% Evaluate the geometry for this candidate pose so the cost function can sample image intensities later.
[poseEvaluation, transformedMesh] = computeProbeFacingPixelsForPose( ...
    data.meshVerticesLocal, ...
    data.meshFaces, ...
    data.planes, ...
    T_candidateMeshToReference, ...
    config);

%% FUTURE COST-FUNCTION PLACEHOLDER

% This is where future code should sample image intensities at poseEvaluation(idx).probeFacingPixels.
% The intended future objective is to maximize sampled intensity, or minimize the negative sampled intensity.
cost = 0;

%% PACKAGE DETAILS FOR DEBUGGING

% Store the candidate transform so future debugging can compare optimizer poses.
details.T_candidateMeshToReference = T_candidateMeshToReference;

% Store the transformed mesh so users can visualize the exact geometry used for this candidate pose.
details.transformedMesh = transformedMesh;

% Store the per-plane selected pixels because this is the essential output needed for the future cost.
details.poseEvaluation = poseEvaluation;

% Store a short status message so it is obvious that this function is not a real cost yet.
details.status = 'placeholder_cost_returns_zero';
end
