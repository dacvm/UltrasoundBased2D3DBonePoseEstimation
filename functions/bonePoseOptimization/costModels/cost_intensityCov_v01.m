function [cost, details] = cost_intensityCov_v01(poseVector, data, config)
%COST_INTENSITYCOV_V01 Evaluate the version 1 intensity cost.
% This function contains the original intensity-and-coverage objective so
% its scientific behavior remains separate from the stable optimizer entry
% point. It is needed so future cost models can be added without rewriting
% the optimizer or changing the established version 1 calculation.
%
% What this function does:
%   This function evaluates one candidate bone pose.
%   It receives a pose vector, converts that vector into a candidate mesh
%   transform, computes probe-facing intersection pixels for that pose, and
%   then returns a scalar cost value.
%
% Why this function exists:
%   Keeping this complete calculation in a named version makes it clear
%   which scientific objective produced a result. bonePoseCostFunction is
%   the public entry point and currently delegates every evaluation here.
%
% Cost idea:
%   Brightness alone is insufficient because a tiny intersection on one very
%   bright pixel can look better than a physically meaningful pose. This
%   cost still rewards bright sampled pixels, but it multiplies each image
%   score by a coverage factor based on the initial-pose pixel count.
%   It also adds a missing-intersection penalty when an active image plane
%   has too few probe-facing pixels at the current candidate pose.
%
% Inputs:
%   poseVector:
%       Six-value perturbation around data.T_CT_ref_initial.
%
%   data:
%       Prepared data from prepareBonePoseOptimizationInputs. This includes
%       the CT mesh, reference-frame image planes, initial transform, and fixed initial-pose
%       per-plane intersection pixel counts.
%
%   config:
%       Optional nested configuration struct. If omitted, data.config is
%       used.
%
% Outputs:
%   cost:
%       Scalar objective value. Lower values are better for the optimizer.
%       The value is finite even when the current pose has no intersections.
%
%   details:
%       Debug information containing frame-explicit candidate transforms,
%       the reference-frame mesh, per-plane pixels, scores, and the two
%       cost terms.
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

% Read the scalar settings prepared by createBonePoseOptimizationRunConfig.
costSettings = getCostSettings(config, data);

%% CONVERT POSE VECTOR TO MESH TRANSFORM

% Convert the optimizer state into the candidate transform applied to CT mesh points.
T_CT_ref_candidate   = stateVectorToTMatrix(poseVector, data.T_CT_ref_initial);
% Propagate the anatomical coordinate system through the same candidate CT pose.
T_bone_ref_candidate = T_CT_ref_candidate * data.T_bone_CT;

%% COMPUTE PROBE-FACING PIXELS

% Evaluate fresh candidate intersections before sampling ultrasound intensities.
[poseEvaluation, boneMeshRefCandidate] = computeProbeFacingPixelsForPose( ...
    data.boneMeshCT, ...
    data.imagePlanesRef, ...
    T_CT_ref_candidate, ...
    config);

% Leave plotting to scripts or display helpers so repeated optimizer calls stay focused on cost computation.
% Plot...

%% COMPUTE INTENSITY-COVERAGE-AWARE COST

% Count planes once so every diagnostic vector stays aligned with data.imagePlanesRef.
n_planes = numel(poseEvaluation);

% Read the fixed initial-pose pixel counts prepared before optimization.
nInitialIntersectionPixels      = getInitialIntersectionPixelCounts(data, n_planes);
% Mark only planes with enough initial-pose pixels as active observations for the final average.
activePlaneMask                 = nInitialIntersectionPixels >= costSettings.minReferencePixels;
% Use a safe denominator so coverage never divides by zero or by a tiny inactive initial count.
safeReferenceCounts             = max(nInitialIntersectionPixels, costSettings.minReferencePixels);

totalIntensity                  = 0;    % Start the running intensity sum at zero so debugging can still inspect all sampled candidate pixels.
totalIntersectionPixels         = 0;    % Start the sampled-pixel count at zero so the diagnostic mean only uses valid selected pixels.

perPlaneIntersectionPixelCounts = zeros(1, n_planes);   % Create one count slot per plane so debugging can show which images contributed to the cost.
perPlaneMeanIntensity           = zeros(1, n_planes);   % Store the mean raw intensity per plane so users can see whether brightness or coverage drove a score.
perPlaneMeanIntensityNorm       = zeros(1, n_planes);   % Store the normalized mean intensity per plane so the objective is on a predictable scale.
perPlaneCoverage                = zeros(1, n_planes);   % Store the coverage factor per plane so tiny bright intersections are visibly downweighted.
perPlaneScore                   = zeros(1, n_planes);   % Store the final brightness-times-coverage score per plane before the sign flip for minimization.
perPlaneMissingMask             = false(1, n_planes);   % Store the missing-pixel flag per plane so users can inspect the missing-intersection penalty.


% Loop through every evaluated image plane because each active plane contributes one averaged score.
for idx_plane = 1:n_planes

    % Read the selected probe-facing pixels for this plane; each row is stored as [row, col].
    probeFacingPixels = poseEvaluation(idx_plane).probeFacingPixels;
    % Count this plane's selected pixels even when there are zero pixels, because zero can trigger the missing penalty.
    n_plane_pixels    = size(probeFacingPixels, 1);

    % Store the current-pose per-plane count so coverage and missing diagnostics use the same value.
    perPlaneIntersectionPixelCounts(idx_plane) = n_plane_pixels;
    % Mark this plane as missing when the current pose explains it with too few selected pixels.
    perPlaneMissingMask(idx_plane)             = n_plane_pixels < costSettings.nMinPixels;

    % Skip intensity sampling when no selected pixels exist; the score stays zero for this plane.
    if n_plane_pixels == 0
        continue;
    end

    % Read the stored row and col coordinates from the [row, col] pixel list.
    selected_rows = probeFacingPixels(:, 1);
    selected_cols = probeFacingPixels(:, 2);

    % Read the raw image for this plane; project images are stored as [column, row] in this pipeline.
    current_image = data.imagePlanesRef(idx_plane).image;

    % Convert [row, col] pixel coordinates to stored-image indexing, where column is the first dimension.
    selected_linear_indices = sub2ind(size(current_image), selected_cols, selected_rows);
    % Convert sampled intensities to double before averaging so integer image types cannot overflow.
    selected_intensities    = double(current_image(selected_linear_indices));
    % Compute this plane's mean sampled intensity because the objective rewards bright mesh-image overlap.
    meanIntensity_i         = mean(selected_intensities(:));

    % Normalize the mean intensity so lambdaMissing has a stable interpretation across image types.
    meanIntensityNorm_i = meanIntensity_i / costSettings.intensityMax;
    % Compute the current coverage relative to the fixed initial-pose pixel count, capped at one.
    coverage_i          = min(1, n_plane_pixels / safeReferenceCounts(idx_plane));

    % Reset non-finite normalized intensities to zero so one bad image cannot create NaN or Inf cost values.
    if ~isfinite(meanIntensityNorm_i)
        meanIntensityNorm_i = 0;
    end

    % Reset non-finite coverage to zero so invalid reference data cannot create NaN or Inf cost values.
    if ~isfinite(coverage_i)
        coverage_i = 0;
    end

    % Multiply brightness by coverage so a tiny bright intersection receives only a small score.
    score_i = meanIntensityNorm_i * coverage_i;

    % Reset non-finite scores to zero so the final objective always remains finite.
    if ~isfinite(score_i)
        score_i = 0;
    end

    % Store some quantities for later report
    perPlaneMeanIntensity(idx_plane)        = meanIntensity_i;          % Per-plane raw mean intensity for debugging and result inspection.
    perPlaneMeanIntensityNorm(idx_plane)    = meanIntensityNorm_i;      % Per-plane normalized mean intensity for debugging the objective scale.
    perPlaneCoverage(idx_plane)             = coverage_i;               % Per-plane coverage factor for checking whether small intersections are being downweighted.
    perPlaneScore(idx_plane)                = score_i;                  % Per-plane score before averaging active planes.

    % Add this plane's intensity values to the diagnostic total used for the global sampled-pixel mean.
    totalIntensity          = totalIntensity + sum(selected_intensities(:));
    % Add this plane's selected pixel count to the diagnostic denominator.
    totalIntersectionPixels = totalIntersectionPixels + n_plane_pixels;
end


% Compute the diagnostic raw mean intensity across all current selected pixels when any exist.
if totalIntersectionPixels == 0
    % Keep the diagnostic mean finite when the candidate pose produces no usable probe-facing pixels.
    meanIntensity = 0;
else
    % Compute the mean selected-pixel intensity across all images for backward-compatible diagnostics.
    meanIntensity = totalIntensity / totalIntersectionPixels;
end


% Use only active planes for the final average because inactive planes were not expected to contain bone.
if any(activePlaneMask)

    % Negate the active-plane score mean so a minimizing optimizer prefers bright, well-covered intersections.
    intensityCoverageCost = -mean(perPlaneScore(activePlaneMask));

    % Average active missing flags so the penalty grows when the pose explains only a small subset of images.
    missingPenaltyCost = mean(perPlaneMissingMask(activePlaneMask));

    % Combine the reward term and the missing-intersection penalty into the final scalar objective.
    cost = intensityCoverageCost + costSettings.lambdaMissing * missingPenaltyCost;

    % Store a short status string so debugging can quickly identify the normal computed-cost case.
    costStatus = 'intensity_coverage_cost_computed';

else

    % Use a large finite penalty instead of NaN or Inf when no plane has a usable initial count.
    intensityCoverageCost = costSettings.noActivePlanePenalty;

    % Treat the no-active-plane case as fully missing because the objective has no valid active average.
    missingPenaltyCost = 1;

    % Return the large finite penalty so optimizers can keep running without accepting an invalid objective.
    cost = costSettings.noActivePlanePenalty;

    % Store a short status string so debugging can quickly identify missing reference data.
    costStatus = 'no_active_reference_planes_large_penalty';

end

% Guard the final scalar because optimizers expect a finite numeric value from every objective call.
if ~isfinite(cost)
    % Replace any unexpected NaN or Inf with the same large finite penalty used for missing references.
    cost = costSettings.noActivePlanePenalty;

    % Store a short status string so debugging can quickly identify the final finite-cost guard.
    costStatus = 'nonfinite_cost_replaced_with_large_penalty';
end

%% PACKAGE DETAILS FOR DEBUGGING

% Store frame-explicit candidate geometry for later inspection.
details.T_CT_ref_candidate              = T_CT_ref_candidate;
details.T_bone_ref_candidate            = T_bone_ref_candidate;
details.boneMeshRefCandidate            = boneMeshRefCandidate;
details.poseEvaluation                  = poseEvaluation;

% Store values related to global values of the pixel intensities
details.nInitialIntersectionPixels      = nInitialIntersectionPixels;       % Store fixed initial-pose per-image counts so users can verify the coverage references.
details.activePlaneMask                 = activePlaneMask;                  % Store the active-plane mask so users can see which planes were included in the final average.
details.totalIntensity                  = totalIntensity;                   % Diagnostic sum of all sampled intensities so users can verify the raw numerator.
details.totalIntersectionPixels         = totalIntersectionPixels;          % Diagnostic count of all sampled pixels so users can verify the raw denominator.
details.meanIntensity                   = meanIntensity;                    % Diagnostic mean sampled intensity for continuity with older inspection scripts.

% Store values related to calculating the cost function
details.perPlaneIntersectionPixelCounts = perPlaneIntersectionPixelCounts;  % Per-plane intersection pixel count, so users can see which images contributed enough pixels.
details.perPlaneMeanIntensity           = perPlaneMeanIntensity;            % Per-plane raw mean intensity, for debugging brightness behavior.
details.perPlaneMeanIntensityNorm       = perPlaneMeanIntensityNorm;        % Per-plane normalized mean intensity, for debugging intensity scaling.
details.perPlaneCoverage                = perPlaneCoverage;                 % Per-plane coverage factors, for debugging tiny-intersection downweighting.
details.perPlaneScore                   = perPlaneScore;                    % Per-plane scores, so users can inspect the value averaged by the reward term.
details.perPlaneMissingMask             = perPlaneMissingMask;              % Per-plane missing flags, so users can inspect the missing-intersection penalty term.

% Store the contribution value of cost function
details.intensityCoverageCost           = intensityCoverageCost;            % The reward term separately so users can understand the final combined cost.
details.missingPenaltyCost              = missingPenaltyCost;               % The missing penalty separately so users can tune lambdaMissing without re-reading the code.

% Store the properties of cost function
details.costSettings                    = costSettings;                     % Store the resolved cost settings so each result records the values used for scoring.
details.status                          = costStatus;                       % Store a short status message for quick debugging in scripts.
end



%% HELPER: READ COST SETTINGS

function costSettings = getCostSettings(config, data)
%GETCOSTSETTINGS Read scalar V1 settings from the runtime configuration.
% This helper keeps setting defaults and image-based intensity inference out
% of the main scientific calculation.

% Runtime configs merge fixed and selected sweep values into one parameter group.
costConfig = config.cost.parameters;

% Read or infer the intensity maximum used to normalize sampled image brightness.
costSettings.intensityMax           = resolveIntensityMax(getOptionalSetting(costConfig, 'intensityMax', []), data);
% Read the active-plane threshold, with a default that ignores tiny initial intersections.
costSettings.minReferencePixels     = getPositiveScalarSetting(costConfig, 'minReferencePixels', 10);
% Read the missing-plane threshold, with a default that treats tiny current intersections as insufficient.
costSettings.nMinPixels             = getPositiveScalarSetting(costConfig, 'nMinPixels', 10);
% Read the missing-plane penalty weight, with a normalized-intensity default of one cost unit.
costSettings.lambdaMissing          = getNonnegativeScalarSetting(costConfig, 'lambdaMissing', 1.0);
% Keep one large finite fallback value for invalid reference data or unexpected non-finite costs.
costSettings.noActivePlanePenalty   = 1e6;

end



%% HELPER: READ ONE OPTIONAL SETTING

function value = getOptionalSetting(sourceStruct, fieldName, defaultValue)
%GETOPTIONALSETTING Return a config value when present, otherwise return a default.
% This helper supports older config files that do not define every newer objective field.

% Use the configured value only when the section exists, the field exists, and the field is not empty.
if isstruct(sourceStruct) && isfield(sourceStruct, fieldName) && ~isempty(sourceStruct.(fieldName))
    value = sourceStruct.(fieldName);
else
    % Use the default value when the config file does not define the optional setting.
    value = defaultValue;
end
end



%% HELPER: READ POSITIVE SCALAR SETTING

function value = getPositiveScalarSetting(sourceStruct, fieldName, defaultValue)
%GETPOSITIVESCALARSETTING Read a positive finite scalar or return a default.
% This helper keeps bad config values from creating divide-by-zero or NaN behavior.

% Read the raw optional setting before validating it.
rawValue = getOptionalSetting(sourceStruct, fieldName, defaultValue);

% Accept the configured value only when it is numeric, scalar, finite, and positive.
if isnumeric(rawValue) && isscalar(rawValue) && isfinite(rawValue) && rawValue > 0
    value = double(rawValue);
else
    % Fall back to the default when the configured value is invalid.
    value = double(defaultValue);
end
end



%% HELPER: READ NONNEGATIVE SCALAR SETTING

function value = getNonnegativeScalarSetting(sourceStruct, fieldName, defaultValue)
%GETNONNEGATIVESCALARSETTING Read a nonnegative finite scalar or return a default.
% This helper lets lambdaMissing be zero while still rejecting invalid penalty weights.

% Read the raw optional setting before validating it.
rawValue = getOptionalSetting(sourceStruct, fieldName, defaultValue);

% Accept the configured value only when it is numeric, scalar, finite, and nonnegative.
if isnumeric(rawValue) && isscalar(rawValue) && isfinite(rawValue) && rawValue >= 0
    value = double(rawValue);
else
    % Fall back to the default when the configured value is invalid.
    value = double(defaultValue);
end
end



%% HELPER: RESOLVE INTENSITY MAXIMUM

function intensityMax = resolveIntensityMax(configuredIntensityMax, data)
%RESOLVEINTENSITYMAX Resolve the image-intensity normalization denominator.
% This helper uses the configured runtime value and retains image-based inference as a safe fallback.

% Use the configured value when it is a positive finite scalar.
if isnumeric(configuredIntensityMax) && isscalar(configuredIntensityMax) && isfinite(configuredIntensityMax) && configuredIntensityMax > 0
    intensityMax = double(configuredIntensityMax);
    return;
end

% Infer a denominator from the prepared image planes when the config leaves intensityMax empty or invalid.
intensityMax = inferIntensityMaxFromPlanes(data.imagePlanesRef);
end



%% HELPER: INFER INTENSITY MAXIMUM FROM IMAGE DATA

function intensityMax = inferIntensityMaxFromPlanes(planes)
%INFERINTENSITYMAXFROMPLANES Infer a safe intensity denominator from the first available image.
% This helper provides a finite fallback when the configured intensity scale is empty or invalid.

% Start with the common 8-bit ultrasound denominator so empty data still gets a finite default.
intensityMax = 255;

% Loop only until the first usable image because image class normally stays consistent across all planes.
for idx_plane = 1:numel(planes)
    % Read the current image so the class and numeric range can be inspected.
    current_image = planes(idx_plane).image;

    % Skip empty images because they cannot tell us a useful intensity scale.
    if isempty(current_image)
        continue;
    end

    % Use the full class range for integer images such as uint8 or uint16.
    if isinteger(current_image)
        intensityMax = double(intmax(class(current_image)));
        return;
    end

    % Use one for logical images because their values are already 0 or 1.
    if islogical(current_image)
        intensityMax = 1;
        return;
    end

    % Use the observed finite maximum for floating-point images when it is positive.
    finitePixelValues = double(current_image(isfinite(current_image)));

    % Accept the observed floating-point maximum only when the image has finite positive values.
    if ~isempty(finitePixelValues) && max(finitePixelValues(:)) > 0
        intensityMax = max(finitePixelValues(:));
    end

    % Stop after the first non-empty floating-point image because it gave us the best available scale.
    return;
end
end



%% HELPER: READ INITIAL INTERSECTION COUNTS

function initialCounts = getInitialIntersectionPixelCounts(data, n_planes)
%GETINITIALINTERSECTIONPIXELCOUNTS Read fixed initial-pose intersection counts from data.
% This helper avoids recomputing the initial-pose counts inside repeated cost-function calls.

% Convert the prepared counts to a row so they align with per-plane vectors.
initialCounts = double(data.nInitialIntersectionPixels(:).');

% Preparation creates exactly one reference count for every fixed image plane.
if numel(initialCounts) ~= n_planes
    error('bonePoseCostFunction:InitialCountSizeMismatch', ...
        'Expected %d initial intersection counts, but received %d.', ...
        n_planes, numel(initialCounts));
end
end
