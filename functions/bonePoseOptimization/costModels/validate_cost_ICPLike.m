function [fixedParameters, hyperparameters] = validate_cost_ICPLike(fixedParameters, hyperparameters)
%VALIDATE_COST_ICPLIKE Validate the ICP-like point-to-mesh cost settings.
% This function checks the configuration owned by the ICPLike cost model.
% It is needed so the shared configuration reader can validate this model
% without knowing its model-specific settings.
%
% Inputs:
%   fixedParameters - Struct containing:
%                       nearestVertexCount - number K of nearby mesh
%                           vertices whose faces are searched per point.
%                       pointBatchSize     - number of measured points
%                           processed together. It only changes speed and
%                           memory use, never the result.
%   hyperparameters - Empty struct because this model has no sweepable
%                     hyperparameters.
%
% Outputs:
%   fixedParameters - Validated fixed settings stored as doubles, in the
%                     order nearestVertexCount, pointBatchSize.
%   hyperparameters - Empty struct representing no model hyperparameters.

% Require exactly the documented fields so missing or misspelled settings fail early.
validateFieldNames(fixedParameters, {'nearestVertexCount', 'pointBatchSize'}, 'cost.fixedParameters');
validateFieldNames(hyperparameters, {}, 'cost.hyperparameters');

% K controls an approximation choice, and the batch size counts points, so
% each must be one positive whole number.
nearestVertexCount = fixedParameters.nearestVertexCount;
validateattributes(nearestVertexCount, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'positive', 'integer'}, ...
    mfilename, 'cost.fixedParameters.nearestVertexCount');

pointBatchSize = fixedParameters.pointBatchSize;
validateattributes(pointBatchSize, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'positive', 'integer'}, ...
    mfilename, 'cost.fixedParameters.pointBatchSize');

% Rebuild both groups in their documented form for predictable downstream use.
fixedParameters = struct();
fixedParameters.nearestVertexCount = double(nearestVertexCount);
fixedParameters.pointBatchSize     = double(pointBatchSize);

hyperparameters = struct();
end



%%
function validateFieldNames(sourceStruct, expectedNames, displayName)
%VALIDATEFIELDNAMES Require exactly the documented fields in one config group.
% sourceStruct is the JSON-derived parameter struct, expectedNames lists the
% accepted fields, and displayName identifies the group in error messages.

if ~isstruct(sourceStruct) || ~isscalar(sourceStruct)
    error('validate_cost_ICPLike:InvalidParameterGroup', ...
        '%s must be a JSON object.', displayName);
end

actualNames     = fieldnames(sourceStruct).';
missingNames    = setdiff(expectedNames, actualNames, 'stable');
unexpectedNames = setdiff(actualNames, expectedNames, 'stable');

if ~isempty(missingNames)
    error('validate_cost_ICPLike:MissingParameter', ...
          '%s is missing: %s.', displayName, strjoin(missingNames, ', '));
end

if ~isempty(unexpectedNames)
    error('validate_cost_ICPLike:UnexpectedParameter', ...
          '%s contains an unsupported field: %s.', displayName, strjoin(unexpectedNames, ', '));
end
end
