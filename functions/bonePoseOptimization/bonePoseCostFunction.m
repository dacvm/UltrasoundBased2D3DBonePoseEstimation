function [cost, details] = bonePoseCostFunction(poseVector, data, config)
%BONEPOSECOSTFUNCTION Image-intensity cost function for bone-pose optimization.
% This function declaration defines the cost-function entry point that an optimizer can call.
%
% What this function does:
%   This function evaluates one candidate bone pose.
%   It receives a pose vector, converts that vector into a candidate mesh
%   transform, computes probe-facing intersection pixels for that pose, and
%   then returns a scalar cost value.
%
% Why this function exists:
%   An optimizer needs one function that answers the question:
%   "How good is this candidate bone pose?" This function wires together
%   the geometry pieces and image sampling needed to answer that question.
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
%       Scalar objective value. It returns the negative mean image intensity
%       sampled at the selected probe-facing intersection pixels.
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

% Leave plotting to scripts or display helpers so repeated optimizer calls stay focused on cost computation.

%% COMPUTE IMAGE-INTENSITY COST

% Start the running intensity sum at zero so every plane can add its sampled pixels.
totalIntensity          = 0;
% Start the sampled-pixel count at zero so the mean only uses valid selected pixels.
totalIntersectionPixels = 0;
% Create one count slot per plane so debugging can show which images contributed to the cost.
perPlaneIntersectionPixelCounts = zeros(1, numel(poseEvaluation));

% Loop through every evaluated image plane because the cost uses all available intersection pixels.
for idx_plane = 1:numel(poseEvaluation)

    % Read the selected probe-facing pixels for this plane; each row is stored as [row, col].
    probeFacingPixels = poseEvaluation(idx_plane).probeFacingPixels;

    % Skip this image when no selected pixels exist, because there is nothing to sample from its image.
    if isempty(probeFacingPixels)
        continue;
    end

    % Count this plane's selected pixels so the final denominator includes every sampled pixel exactly once.
    n_plane_pixels = size(probeFacingPixels, 1);

    % Store the per-plane count so callers can inspect how the final cost was built.
    perPlaneIntersectionPixelCounts(idx_plane) = n_plane_pixels;

    % Read the stored row and col coordinates from the [row, col] pixel list.
    selected_rows = probeFacingPixels(:, 1);
    selected_cols = probeFacingPixels(:, 2);

    % Read the raw image for this plane; project images are stored as [column, row] in this pipeline.
    current_image = data.planes(idx_plane).image;

    % Convert [row, col] pixel coordinates to stored-image indexing, where column is the first dimension.
    selected_linear_indices = sub2ind(size(current_image), selected_cols, selected_rows);
    % Convert sampled intensities to double before summing so integer image types cannot overflow.
    selected_intensities    = double(current_image(selected_linear_indices));

    % Add this plane's intensity values to the running total used for the global mean.
    totalIntensity = totalIntensity + sum(selected_intensities(:));

    % Add this plane's selected pixel count to the running denominator.
    totalIntersectionPixels = totalIntersectionPixels + n_plane_pixels;
end

% Guard against divide-by-zero when the candidate pose produces no usable probe-facing pixels.
if totalIntersectionPixels == 0
    % Return a neutral finite cost for empty intersections, following the requested behavior.
    meanIntensity = 0;
    % Keep the cost finite when there are no sampled pixels.
    cost = 0;
    % Store a short status string so debugging can quickly identify the empty-pixel case.
    costStatus = 'no_probe_facing_pixels_cost_zero';
else
    % Compute the mean selected-pixel intensity across all images.
    meanIntensity = totalIntensity / totalIntersectionPixels;
    % Return the negative mean so a minimizing optimizer prefers brighter selected intersections.
    cost = -meanIntensity;
    % Store a short status string so debugging can quickly identify the normal computed-cost case.
    costStatus = 'negative_mean_probe_facing_intensity_computed';
end


%% PACKAGE DETAILS FOR DEBUGGING

% Store some of the details from the cost function
details.T_candidate_init                = T_candidate_init;                % Candidate transform so future debugging can compare optimizer poses.
details.transformedMesh                 = transformedMesh;                 % Transformed mesh so users can visualize the exact geometry used for this candidate pose.
details.poseEvaluation                  = poseEvaluation;                  % Per-plane selected pixels because this is the essential output needed for the future cost.
details.totalIntensity                  = totalIntensity;                  % Sum of all sampled intensities so users can verify the cost numerator.
details.totalIntersectionPixels         = totalIntersectionPixels;         % Count of all sampled pixels so users can verify the cost denominator.
details.meanIntensity                   = meanIntensity;                   % Mean sampled intensity before the sign flip used for minimization.
details.perPlaneIntersectionPixelCounts = perPlaneIntersectionPixelCounts; % Per-image counts so users can see which images contributed.
details.status                          = costStatus;                      % Short status message.
end
