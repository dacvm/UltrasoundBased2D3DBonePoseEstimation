function [fixedParameters, hyperparameters] = validate_cost_intensityICP_v01(fixedParameters, hyperparameters)
%VALIDATE_COST_INTENSITYICP_V01 Validate combined settings.
% This validator checks the union of the existing intensity and point-cloud
% settings plus the distance normalization and blend weight. It reuses the
% two component validators so their established parameter rules stay in one
% place while returning a stable field order for experiment planning.
%
% Inputs:
%   fixedParameters - Struct containing intensityMax, nearestVertexCount,
%                     and distanceReferenceMm.
%   hyperparameters - Struct containing minReferencePixels, nMinPixels,
%                     lambdaMissing, and weight candidate arrays.
%
% Outputs:
%   fixedParameters - Validated fixed settings stored as scalar doubles.
%   hyperparameters - Validated candidate arrays stored as row vectors in
%                     the documented planning order.

% Require the complete combined-model schema so spelling mistakes are
% reported before data preparation or optimization begins.
validateFieldNames(fixedParameters, ...
    {'intensityMax', 'nearestVertexCount', 'distanceReferenceMm'}, ...
    'cost.fixedParameters');
validateFieldNames(hyperparameters, ...
    {'minReferencePixels', 'nMinPixels', 'lambdaMissing', 'weight'}, ...
    'cost.hyperparameters');

% Reuse each component validator on the settings that belong to that model.
intensityFixed = struct('intensityMax', fixedParameters.intensityMax);
intensityHyper = struct( ...
    'minReferencePixels', hyperparameters.minReferencePixels, ...
    'nMinPixels', hyperparameters.nMinPixels, ...
    'lambdaMissing', hyperparameters.lambdaMissing);
[intensityFixed, intensityHyper] = validate_cost_intensityCov_v01(intensityFixed, intensityHyper);

pointCloudFixed = struct('nearestVertexCount', fixedParameters.nearestVertexCount);
[pointCloudFixed, ~] = validate_cost_ICPLike_v01(pointCloudFixed, struct());

% The reference distance removes the millimetre unit from the point-cloud RMSE.
distanceReferenceMm = fixedParameters.distanceReferenceMm;
validateattributes(distanceReferenceMm, {'numeric'}, ...
    {'scalar', 'real', 'positive', 'finite'}, mfilename, ...
    'cost.fixedParameters.distanceReferenceMm');

% Weight is a sweep candidate and must remain a valid convex blend coefficient.
weight = normalizeWeightCandidates(hyperparameters.weight);

% Rebuild both groups in the order used for experiment table columns.
fixedParameters = struct();
fixedParameters.intensityMax        = intensityFixed.intensityMax;
fixedParameters.nearestVertexCount  = pointCloudFixed.nearestVertexCount;
fixedParameters.distanceReferenceMm = double(distanceReferenceMm);

hyperparameters = struct();
hyperparameters.minReferencePixels = intensityHyper.minReferencePixels;
hyperparameters.nMinPixels         = intensityHyper.nMinPixels;
hyperparameters.lambdaMissing      = intensityHyper.lambdaMissing;
hyperparameters.weight             = weight;
end


%%

function validateFieldNames(sourceStruct, expectedNames, displayName)
%VALIDATEFIELDNAMES Require exactly the documented combined-model fields.
% sourceStruct is one JSON-derived parameter group, expectedNames lists its
% accepted fields, and displayName identifies the group in error messages.

if ~isstruct(sourceStruct) || ~isscalar(sourceStruct)
    error('validate_cost_intensityICP_v01:InvalidParameterGroup', ...
        '%s must be a JSON object.', displayName);
end

actualNames     = fieldnames(sourceStruct).';
missingNames    = setdiff(expectedNames, actualNames, 'stable');
unexpectedNames = setdiff(actualNames, expectedNames, 'stable');

if ~isempty(missingNames)
    error('validate_cost_intensityICP_v01:MissingParameter', ...
        '%s is missing: %s.', displayName, strjoin(missingNames, ', '));
end
if ~isempty(unexpectedNames)
    error('validate_cost_intensityICP_v01:UnexpectedParameter', ...
        '%s contains an unsupported field: %s.', ...
        displayName, strjoin(unexpectedNames, ', '));
end
end


function weight = normalizeWeightCandidates(rawWeight)
%NORMALIZEWEIGHTCANDIDATES Validate and reshape blend-weight candidates.
% rawWeight contains the configured values and weight is the validated row
% vector used by the generic experiment planner.

validateattributes(rawWeight, {'numeric'}, ...
    {'vector', 'nonempty', 'real', 'finite', '>=', 0, '<=', 1}, ...
    mfilename, 'cost.hyperparameters.weight');

if numel(unique(rawWeight)) ~= numel(rawWeight)
    error('validate_cost_intensityICP_v01:DuplicateWeight', ...
        'cost.hyperparameters.weight must not contain duplicate values.');
end

weight = double(rawWeight(:).');
end
