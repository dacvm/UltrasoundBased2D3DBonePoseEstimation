function [cost, details] = bonePoseCostFunction(poseVector, data, config)
%BONEPOSECOSTFUNCTION Evaluate a bone pose through the stable cost entry point.
% This function gives scripts and optimizers one permanent function to call.
% It reads the configured model and forwards the evaluation to the matching
% versioned implementation. Keeping this wrapper small lets new models be
% added without changing scripts or optimizer code.
%
% Inputs:
%   poseVector - Six-value perturbation around data.T_CT_ref_initial.
%   data       - Prepared estimation data containing the CT mesh, tracked
%                ultrasound planes, initial transforms, and reference counts.
%   config     - Optional scalar runtime configuration. When omitted or
%                empty, the versioned implementation uses data.config.
%
% Outputs:
%   cost       - Finite scalar objective value; lower values are better.
%   details    - Diagnostic transforms, geometry, per-plane measurements,
%                cost components, resolved settings, and evaluation status.

% Use the scalar runtime config saved with prepared data when it is omitted.
if nargin < 3 || isempty(config)
    config = data.config;
end

% Fail before geometry work when the runtime configuration cannot identify its model.
if ~isstruct(config) || ~isfield(config, 'cost') || ...
        ~isstruct(config.cost) || ~isfield(config.cost, 'model')
    error('bonePoseCostFunction:MissingCostModel', ...
        'The runtime configuration must define cost.model.');
end

% Resolve only approved project models instead of accepting a JSON function name.
costDefinition = getBonePoseCostDefinition(config.cost.model);
[cost, details] = costDefinition.evaluateFcn(poseVector, data, config);

% Record the canonical model beside its diagnostics for direct workspace inspection.
details.costModel = costDefinition.modelName;
end
