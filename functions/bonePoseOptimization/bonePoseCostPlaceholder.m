function [cost, details] = bonePoseCostPlaceholder(poseVector, data, config)
%BONEPOSECOSTPLACEHOLDER Placeholder for the future image-intensity cost function.
% This function declaration defines the cost-function entry point that an optimizer can call later.
%
% What this function does:
%   This placeholder shows the intended shape of the cost function.
%   It receives a pose vector, converts that vector into a candidate mesh
%   transform, computes probe-facing intersection pixels for that pose, and
%   then returns a scalar cost value.
%
% Why this function exists:
%   An optimizer needs one function that answers the question:
%   "How good is this candidate bone pose?" This placeholder already wires
%   together the geometry pieces needed to answer that question later.
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

% Convert the optimizer candidate state into a 4x4 transform around the initial pose.
T_candidate_init = stateVectorToTMatrix(poseVector, data.T_init_originct);

%% COMPUTE PROBE-FACING PIXELS

% Evaluate the geometry for this candidate pose so the cost function can sample image intensities later.
[poseEvaluation, transformedMesh] = computeProbeFacingPixelsForPose( ...
                                        data.meshVerticesLocal, ...
                                        data.meshFaces, ...
                                        data.planes, ...
                                        T_candidate_init, ...
                                        config);

% % Show the precomputed image intersections for sanity checking; comment this line before real optimization runs.
% planeImages = {data.planes.image};
% displayImageIntersections(planeImages, poseEvaluation, 'Cost Placeholder Probe-Facing Intersections');

%% FUTURE COST-FUNCTION PLACEHOLDER

% This is where future code should sample image intensities at poseEvaluation(idx).probeFacingPixels.
% The intended future objective is to maximize sampled intensity, or minimize the negative sampled intensity.
cost = 0;

%% PACKAGE DETAILS FOR DEBUGGING

% Store some of the details from the cost function
details.T_candidate_init = T_candidate_init;        % Candidate transform so future debugging can compare optimizer poses.
details.transformedMesh = transformedMesh;          % Transformed mesh so users can visualize the exact geometry used for this candidate pose.
details.poseEvaluation = poseEvaluation;            % Per-plane selected pixels because this is the essential output needed for the future cost.
details.status = 'placeholder_cost_returns_zero';   % Short status message.
end
