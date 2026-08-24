function [fixedParameters, hyperparameters] = validateBonePoseCost3DPointCloudV1Config(fixedParameters, hyperparameters)
%VALIDATEBONEPOSECOST3DPOINTCLOUDV1CONFIG Validate 3D point-cloud V1 settings.
% This function checks the configuration owned by the 3D point-cloud V1
% cost model. It is needed so the shared configuration reader can validate
% this model without knowing its model-specific settings.
%
% Inputs:
%   fixedParameters - Struct containing nearestVertexCount, the fixed number
%                     of nearby mesh vertices used to find candidate faces.
%   hyperparameters - Empty struct because this model has no sweepable
%                     hyperparameters.
%
% Outputs:
%   fixedParameters - Validated fixed settings with nearestVertexCount
%                     stored as a double.
%   hyperparameters - Empty struct representing no model hyperparameters.

% Require exactly the documented fields so missing or misspelled settings fail early.
validateFieldNames(fixedParameters, {'nearestVertexCount'}, 'cost.fixedParameters');
validateFieldNames(hyperparameters, {}, 'cost.hyperparameters');

% K controls an approximation choice, so it must be one positive whole number.
nearestVertexCount = fixedParameters.nearestVertexCount;
validateattributes(nearestVertexCount, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'positive', 'integer'}, ...
    mfilename, 'cost.fixedParameters.nearestVertexCount');

% Rebuild both groups in their documented form for predictable downstream use.
fixedParameters = struct();
fixedParameters.nearestVertexCount = double(nearestVertexCount);

hyperparameters = struct();
end



%%
function validateFieldNames(sourceStruct, expectedNames, displayName)
%VALIDATEFIELDNAMES Require exactly the documented fields in one config group.
% sourceStruct is the JSON-derived parameter struct, expectedNames lists the
% accepted fields, and displayName identifies the group in error messages.

if ~isstruct(sourceStruct) || ~isscalar(sourceStruct)
    error('validateBonePoseCost3DPointCloudV1Config:InvalidParameterGroup', ...
        '%s must be a JSON object.', displayName);
end

actualNames     = fieldnames(sourceStruct).';
missingNames    = setdiff(expectedNames, actualNames, 'stable');
unexpectedNames = setdiff(actualNames, expectedNames, 'stable');

if ~isempty(missingNames)
    error('validateBonePoseCost3DPointCloudV1Config:MissingParameter', ...
          '%s is missing: %s.', displayName, strjoin(missingNames, ', '));
end

if ~isempty(unexpectedNames)
    error('validateBonePoseCost3DPointCloudV1Config:UnexpectedParameter', ...
          '%s contains an unsupported field: %s.', displayName, strjoin(unexpectedNames, ', '));
end
end
