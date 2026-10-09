function [cost, details] = cost_intensityPIMLOP(poseVector, data, config)
%COST_INTENSITYPIMLOP Combine image intensity and P-IMLOP agreement.
% This model evaluates the smoothed-intensity cost (intensityLine) and the
% P-IMLOP cost at the same candidate pose. The P-IMLOP total grows with the number of
% measurements, so it is turned into a mean match error per measurement.
% This keeps its size independent of how many surface points were
% segmented, so it can be blended with the image term using one configured
% weight. Keeping the two established models unchanged makes the combined
% objective easy to inspect and extend.
%
% Inputs:
%   poseVector - Six-value perturbation around data.T_CT_ref_initial.
%   data       - Prepared estimation data containing image planes, the CT
%                mesh, initial transforms, aligned 3D surface points with
%                2D normals, the P-IMLOP model data.extra.pimlop.PsiCT, and
%                the smoothed images data.extra.intensityLine.smoothedImages.
%   config     - Scalar runtime configuration containing all component
%                parameters and weight.
%
% Outputs:
%   cost       - Combined objective value; lower is better.
%   details    - Common candidate geometry, individual cost terms, resolved
%                settings, and the complete diagnostics from both models.

%% EVALUATE BOTH ESTABLISHED COSTS

% Use the same pose, data, and scalar settings so both terms describe one
% candidate bone pose under identical experiment conditions. The P-IMLOP
% details are always requested because they report the measurement count
% needed for the mean match error below.
[intensityCost, intensityDetails]      = cost_intensityLine(poseVector, data, config);
[pimlopTotalMatchError, pimlopDetails] = cost_PIMLOP(poseVector, data, config);

%% NORMALIZE AND COMBINE THE COSTS

% The experiment validator creates this scalar runtime setting before the
% optimizer starts, so its meaning stays fixed throughout one run.
weight = config.cost.parameters.weight;

% Keep the blend setting readable when this model is called directly.
validateattributes(weight, {'numeric'}, ...
    {'scalar', 'real', 'finite', '>=', 0, '<=', 1}, mfilename, ...
    'config.cost.parameters.weight');

% The P-IMLOP total is a sum over all retained measurements. Averaging it
% removes the dependence on how many points were segmented or subsampled.
% The same measurements are used for every candidate pose, so this divides
% by a fixed number and does not move the P-IMLOP best pose.
pimlopMeanMatchError = pimlopTotalMatchError / pimlopDetails.numberOfMeasurements;

% Weight multiplies the first cost, matching f3 = weight*f1 + (1-weight)*f2.
intensityWeighted = weight * intensityCost;
pimlopWeighted    = (1 - weight) * pimlopMeanMatchError;
cost              = intensityWeighted + pimlopWeighted;

%% PACKAGE READABLE DIAGNOSTICS

% Keep the common geometry at the top level because evaluation code expects
% to find the final candidate mesh without knowing the selected cost model.
details.T_CT_ref_candidate   = intensityDetails.T_CT_ref_candidate;
details.T_bone_ref_candidate = intensityDetails.T_bone_ref_candidate;
details.boneMeshRefCandidate = intensityDetails.boneMeshRefCandidate;
details.poseEvaluation       = intensityDetails.poseEvaluation;

% Store the calculation in the same order as the equation so users can
% reconstruct the returned scalar directly from the saved result.
details.costTerms.intensityRaw               = intensityCost;
details.costTerms.pimlopTotalMatchError      = pimlopTotalMatchError;
details.costTerms.pimlopNumberOfMeasurements = pimlopDetails.numberOfMeasurements;
details.costTerms.pimlopMeanMatchError       = pimlopMeanMatchError;
details.costTerms.intensityWeighted          = intensityWeighted;
details.costTerms.pimlopWeighted             = pimlopWeighted;
details.costTerms.combined                   = cost;

% Preserve the exact scalar settings and the full component diagnostics for
% later research inspection without changing either existing cost model.
details.costSettings               = config.cost.parameters;
details.componentDetails.intensity = intensityDetails;
details.componentDetails.pimlop    = pimlopDetails;
details.status = 'intensity_pimlop_combined_cost_computed';
end
