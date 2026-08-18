function [cost, details] = bonePoseCostFunction(poseVector, data, config)
%BONEPOSECOSTFUNCTION Evaluate a bone pose through the stable cost entry point.
% This function gives scripts and optimizers one permanent function to call.
% It currently forwards every evaluation to the original version 1
% intensity-and-coverage model. Keeping this wrapper small will make it easy
% to add an explicit model choice later without changing optimizer code.
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

% Preserve the established optional-config behavior instead of creating a
% second configuration rule inside this public wrapper.
if nargin < 3 || isempty(config)
    [cost, details] = bonePoseCostIntensityCoverageV1(poseVector, data);
    return;
end

% Pass the caller's configuration through unchanged so the versioned model
% remains the single owner of version 1 settings and calculations.
[cost, details] = bonePoseCostIntensityCoverageV1(poseVector, data, config);
end
