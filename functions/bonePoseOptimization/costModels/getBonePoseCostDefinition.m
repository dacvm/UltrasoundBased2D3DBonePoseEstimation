function definition = getBonePoseCostDefinition(modelName)
%GETBONEPOSECOSTDEFINITION Connect a cost-model name to its implementation.
% The JSON configuration stores a readable model name instead of MATLAB
% function handles. This function translates that name into the matching
% cost evaluator, configuration validator, and input requirements.
%
% Configuration loading uses the validator returned here, while the stable
% bonePoseCostFunction dispatcher uses the evaluator returned here. Keeping
% both mappings together prevents these two parts of the pipeline from
% accidentally supporting different model lists or calling mismatched code.
%
% This registry becomes important when the project has more than one cost
% model. Without it, separate model-selection switch blocks would be needed
% in configuration loading and cost evaluation. Those duplicated lists could
% drift apart when a model is added, renamed, or removed.
%
% To add a new cost model:
%   1. Create its cost evaluator and model-specific configuration validator.
%   2. Add one case below that connects a new model name to both functions.
%   3. Set cost.model and the model's parameter values in the experiment JSON.
% The validator owns the accepted fixed parameters, hyperparameters, value
% checks, and canonical field order. Do not repeat parameter names here. The
% generic planner reads the validated hyperparameter fields automatically.
%
% Input:
%   modelName  - Character vector or string scalar naming the cost model.
%
% Output:
%   definition - Struct containing the selected model name, evaluator,
%                validator, and declared input requirements.

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
        definition.requiresBoneSurface          = false;

    case 'pointCloud3D_v1'
        definition.modelName                    = 'pointCloud3D_v1';
        definition.evaluateFcn                  = @bonePoseCost3DPointCloudV1;
        definition.validateExperimentConfigFcn  = @validateBonePoseCost3DPointCloudV1Config;
        definition.requiresBoneSurface          = true;

    case 'intensityPointCloud_v1'
        definition.modelName                    = 'intensityPointCloud_v1';
        definition.evaluateFcn                  = @bonePoseCostIntensityPointCloudV1;
        definition.validateExperimentConfigFcn  = @validateBonePoseCostIntensityPointCloudV1Config;
        definition.requiresBoneSurface          = true;

    otherwise
        error('getBonePoseCostDefinition:UnsupportedModel', 'Unsupported cost model: %s', modelName);
end
end
