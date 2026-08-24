function [cost, details] = bonePoseCostIntensityPointCloudV1(poseVector, data, config)
%BONEPOSECOSTINTENSITYPOINTCLOUDV1 Combine image and 3D surface agreement.
% This model evaluates the existing intensity-coverage and 3D point-cloud
% costs at the same candidate pose. It converts the point-cloud RMSE from
% millimetres to a dimensionless value, then blends both costs with one
% configured weight. Keeping the two established models unchanged makes the
% combined objective easy to inspect and extend.
%
% Inputs:
%   poseVector - Six-value perturbation around data.T_CT_ref_initial.
%   data       - Prepared estimation data containing image planes, the CT
%                mesh, initial transforms, and aligned 3D surface points.
%   config     - Scalar runtime configuration containing all component
%                parameters, distanceReferenceMm, and weight.
%
% Outputs:
%   cost       - Dimensionless combined objective value; lower is better.
%   details    - Common candidate geometry, individual cost terms, resolved
%                settings, and the complete diagnostics from both models.

%% EVALUATE BOTH ESTABLISHED COSTS

% Use the same pose, data, and scalar settings so both terms describe one
% candidate bone pose under identical experiment conditions.
[intensityCoverageCost, intensityCoverageDetails] = bonePoseCostIntensityCoverageV1(poseVector, data, config);
[pointCloudCostMm, pointCloudDetails] = bonePoseCost3DPointCloudV1(poseVector, data, config);

%% NORMALIZE AND COMBINE THE COSTS

% The experiment validator creates these scalar runtime settings before the
% optimizer starts, so their meaning stays fixed throughout one run.
distanceReferenceMm = config.cost.parameters.distanceReferenceMm;
weight              = config.cost.parameters.weight;

% Keep the two key blend settings readable when this model is called directly.
validateattributes(distanceReferenceMm, {'numeric'}, ...
    {'scalar', 'real', 'positive', 'finite'}, mfilename, ...
    'config.cost.parameters.distanceReferenceMm');
validateattributes(weight, {'numeric'}, ...
    {'scalar', 'real', 'finite', '>=', 0, '<=', 1}, mfilename, ...
    'config.cost.parameters.weight');

% Dividing millimetres by millimetres makes the point-cloud term
% dimensionless and therefore suitable for combination with the image term.
pointCloudCostNormalized = pointCloudCostMm / distanceReferenceMm;

% Weight multiplies the first cost, matching f3 = weight*f1 + (1-weight)*f2.
intensityCoverageWeighted = weight * intensityCoverageCost;
pointCloudWeighted        = (1 - weight) * pointCloudCostNormalized;
cost                      = intensityCoverageWeighted + pointCloudWeighted;

%% PACKAGE READABLE DIAGNOSTICS

% Keep the common geometry at the top level because evaluation code expects
% to find the final candidate mesh without knowing the selected cost model.
details.T_CT_ref_candidate   = intensityCoverageDetails.T_CT_ref_candidate;
details.T_bone_ref_candidate = intensityCoverageDetails.T_bone_ref_candidate;
details.boneMeshRefCandidate = intensityCoverageDetails.boneMeshRefCandidate;
details.poseEvaluation       = intensityCoverageDetails.poseEvaluation;

% Store the calculation in the same order as the equation so users can
% reconstruct the returned scalar directly from the saved result.
details.costTerms.intensityCoverageRaw      = intensityCoverageCost;
details.costTerms.pointCloud3DRawMm         = pointCloudCostMm;
details.costTerms.pointCloud3DNormalized    = pointCloudCostNormalized;
details.costTerms.intensityCoverageWeighted = intensityCoverageWeighted;
details.costTerms.pointCloud3DWeighted      = pointCloudWeighted;
details.costTerms.combined                  = cost;

% Preserve the exact scalar settings and the full component diagnostics for
% later research inspection without changing either existing cost model.
details.costSettings                      = config.cost.parameters;
details.componentDetails.intensityCoverage = intensityCoverageDetails;
details.componentDetails.pointCloud3D      = pointCloudDetails;
details.status = 'intensity_point_cloud_combined_cost_computed';
end
