function [fixedParameters, hyperparameters] = validate_cost_PIMLOP_v01(fixedParameters, hyperparameters)
%VALIDATE_COST_PIMLOP_V01 Validate P-IMLOP V1 settings.
% This function checks the configuration owned by the P-IMLOP cost model
% (cost_PIMLOP_v01). It is needed so the shared configuration reader can
% validate this model without knowing its model-specific settings.
%
% Inputs:
%   fixedParameters - Struct containing:
%                     measurementSubsampleFraction, the fraction (0, 1] of
%                     valid surface points kept from every image;
%                     positionStandardDeviationImage, the three position
%                     standard deviations [sx sy sz] in mm along the image
%                     axes; and
%                     kappa, the nonnegative orientation concentration.
%   hyperparameters - Empty struct because this model has no sweepable
%                     hyperparameters yet.
%
% Outputs:
%   fixedParameters - Validated fixed settings stored as doubles, with
%                     positionStandardDeviationImage as a 1x3 row vector.
%   hyperparameters - Empty struct representing no model hyperparameters.
%
% Note: kappa can later move into hyperparameters to sweep it. The cost
% function does not change, because the run configuration places fixed and
% swept values together under config.cost.parameters.

% Require exactly the documented fields so missing or misspelled settings fail early.
validateFieldNames(fixedParameters, ...
    {'measurementSubsampleFraction', 'positionStandardDeviationImage', 'kappa'}, ...
    'cost.fixedParameters');
validateFieldNames(hyperparameters, {}, 'cost.hyperparameters');

% The subsample fraction keeps part of each surface curve, so it must lie in (0, 1].
measurementSubsampleFraction = fixedParameters.measurementSubsampleFraction;
validateattributes(measurementSubsampleFraction, {'numeric'}, ...
    {'scalar', 'real', 'finite', '>', 0, '<=', 1}, ...
    mfilename, 'cost.fixedParameters.measurementSubsampleFraction');

% One standard deviation per image axis builds the diagonal position covariance.
positionStandardDeviationImage = fixedParameters.positionStandardDeviationImage;
validateattributes(positionStandardDeviationImage, {'numeric'}, ...
    {'vector', 'numel', 3, 'real', 'finite', 'positive'}, ...
    mfilename, 'cost.fixedParameters.positionStandardDeviationImage');

% Kappa weights the orientation term; zero switches it off, so it must be nonnegative.
kappa = fixedParameters.kappa;
validateattributes(kappa, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'nonnegative'}, ...
    mfilename, 'cost.fixedParameters.kappa');

% Rebuild both groups in one documented order. The generic planner uses
% this field order for stable table columns and combination numbers.
fixedParameters = struct();
fixedParameters.measurementSubsampleFraction   = double(measurementSubsampleFraction);
fixedParameters.positionStandardDeviationImage = double(positionStandardDeviationImage(:).');
fixedParameters.kappa                          = double(kappa);

hyperparameters = struct();
end



%%
function validateFieldNames(sourceStruct, expectedNames, displayName)
%VALIDATEFIELDNAMES Require exactly the documented fields in one config group.
% sourceStruct is the JSON-derived parameter struct, expectedNames lists the
% accepted fields, and displayName identifies the group in error messages.

if ~isstruct(sourceStruct) || ~isscalar(sourceStruct)
    error('validate_cost_PIMLOP_v01:InvalidParameterGroup', ...
        '%s must be a JSON object.', displayName);
end

actualNames     = fieldnames(sourceStruct).';
missingNames    = setdiff(expectedNames, actualNames, 'stable');
unexpectedNames = setdiff(actualNames, expectedNames, 'stable');

if ~isempty(missingNames)
    error('validate_cost_PIMLOP_v01:MissingParameter', ...
          '%s is missing: %s.', displayName, strjoin(missingNames, ', '));
end

if ~isempty(unexpectedNames)
    error('validate_cost_PIMLOP_v01:UnexpectedParameter', ...
          '%s contains an unsupported field: %s.', displayName, strjoin(unexpectedNames, ', '));
end
end
