function residualRmseMm = calculateRegistrationResidualRmseMm(poseVector, data)
%CALCULATEREGISTRATIONRESIDUALRMSEMM Measure how well the mesh fits the ultrasound points.
% This function places the CT bone mesh at one pose and returns the
% root-mean-square (RMSE) distance from every measured ultrasound
% bone-surface point to its closest location on the mesh surface:
%   residualRmseMm = sqrt(mean(d_i^2)),
% where d_i is the distance from measured point i to the mesh, in mm.
%
% Why this function is needed:
%   Each cost model scores a pose in its own way and on its own scale, so
%   bestCost cannot be compared between cost models. This residual is
%   computed the same way for every cost model, so it shows how well any
%   registration aligned the mesh to the measured bone surface. It is the
%   "registration residual" often reported in papers.
%
%   Note: the residual is NOT the registration accuracy. It compares the
%   mesh with the measured points, not with the ground-truth pose. A mesh
%   can fit the points well and still sit in the wrong place.
%
% The distances are computed by cost_ICPLike, which already does exactly
% this point-to-mesh RMSE. Its search settings are fixed here, so the
% residual does not depend on the settings of the cost model that ran the
% optimization.
%
% Inputs:
%   poseVector - Six-value pose perturbation [vx; vy; vz; wx; wy; wz]
%                (mm, rad) around data.T_CT_ref_initial, as stored in
%                optimizationResult.result.bestPoseVector.
%   data       - Prepared data from prepareBonePoseOptimizationInputs. It
%                holds the CT mesh, the measured surface points in ref, and
%                the point-to-mesh search structures (data.extra.icpLike).
%
% Output:
%   residualRmseMm - RMSE distance in mm from the measured points to the
%                    mesh at poseVector. Lower means a closer fit.

% cost_ICPLike reads its two search settings from config.cost.parameters.
% nearestVertexCount: the faces around this many nearest mesh vertices are
% searched for each point; 20 is generous enough to always find the true
% closest face. pointBatchSize only limits memory and never changes the
% result. Both match the values in the ICPLike configs.
icpConfig.cost.parameters.nearestVertexCount = 20;
icpConfig.cost.parameters.pointBatchSize     = 200;

% cost_ICPLike returns the point-to-mesh RMSE as its cost.
residualRmseMm = cost_ICPLike(poseVector, data, icpConfig);
end
