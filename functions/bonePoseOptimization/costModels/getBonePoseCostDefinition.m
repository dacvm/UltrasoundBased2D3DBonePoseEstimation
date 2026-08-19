function definition = getBonePoseCostDefinition(modelName)
%GETBONEPOSECOSTDEFINITION Describe one supported bone-pose cost model.
% This function is the single readable list of cost models available to the
% optimization pipeline. It maps a configured model name to its evaluator,
% parameter names, validation function, and required prepared inputs.
%
% Input:
%   modelName  - Character vector or string scalar naming the cost model.
%
% Output:
%   definition - Struct describing the selected cost model.

% Normalize the text once so configuration and runtime callers use the same name.
if isstring(modelName) && isscalar(modelName)
    modelName = char(modelName);
elseif ~ischar(modelName) || ~isrow(modelName)
    error('getBonePoseCostDefinition:InvalidModelName', ...
          'cost.model must be a character vector or string scalar.');
end

% Keep the supported models together so a new developer can find the extension point.
switch modelName
    case 'intensityCoverage_v1'
        definition.modelName                    = 'intensityCoverage_v1';
        definition.evaluateFcn                  = @bonePoseCostIntensityCoverageV1;
        definition.validateExperimentConfigFcn  = @validateBonePoseCostIntensityCoverageV1Config;
        definition.fixedParameterNames          = {'intensityMax'};
        definition.hyperparameterNames          = {'minReferencePixels', 'nMinPixels', 'lambdaMissing'};
        definition.requiresBoneSurface          = false;

    otherwise
        error('getBonePoseCostDefinition:UnsupportedModel', 'Unsupported cost model: %s', modelName);
end

% Check the small parameter-name contract once so planning can safely use names as table columns.
allParameterNames = [definition.fixedParameterNames, definition.hyperparameterNames];
if numel(unique(allParameterNames)) ~= numel(allParameterNames) || ~all(cellfun(@isvarname, allParameterNames))
    error('getBonePoseCostDefinition:InvalidParameterNames', ...
          'Cost-model parameter names must be unique valid MATLAB variable names.');
end

% Swept names share a table with these workflow columns, so they must not reuse them.
reservedSweepNames = {'combinationNumber', 'combinationId', 'costModel', 'runNumber', 'runId', 'seed', 'normalFacingToleranceDeg'};
if any(ismember(definition.hyperparameterNames, reservedSweepNames))
    error('getBonePoseCostDefinition:ReservedHyperparameterName', ...
          'A cost hyperparameter name conflicts with an experiment-table column.');
end
end
