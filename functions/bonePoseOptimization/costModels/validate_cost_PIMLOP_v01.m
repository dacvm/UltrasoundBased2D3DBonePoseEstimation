function [fixedParameters, hyperparameters] = validate_cost_PIMLOP_v01(fixedParameters, hyperparameters)
%VALIDATE_COST_PIMLOP_V01 Validate P-IMLOP V1 settings.
% This function checks the configuration owned by the P-IMLOP cost model
% (cost_PIMLOP_v01). It is needed so the shared configuration reader can
% validate this model without knowing its model-specific settings.
%
% Inputs:
%   fixedParameters - Struct containing:
%                     measurementSubsampleFraction, the fraction (0, 1] of
%                     valid surface points kept from every image, and
%                     positionStandardDeviationImage, the three position
%                     standard deviations [sx sy sz] in mm along the image
%                     axes.
%   hyperparameters - Struct containing kappa, the candidate orientation
%                     concentration values to sweep.
%
% Outputs:
%   fixedParameters - Validated fixed settings stored as doubles, with
%                     positionStandardDeviationImage as a 1x3 row vector.
%   hyperparameters - Validated kappa candidates stored as a row vector.

% Require exactly the documented fields so missing or misspelled settings fail early.
validateFieldNames(fixedParameters, {'measurementSubsampleFraction', 'positionStandardDeviationImage'}, 'cost.fixedParameters');
validateFieldNames(hyperparameters, {'kappa'}, 'cost.hyperparameters');

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
kappa = hyperparameters.kappa;
validateattributes(kappa, {'numeric'}, ...
    {'vector', 'nonempty', 'real', 'finite', 'nonnegative'}, ...
    mfilename, 'cost.hyperparameters.kappa');
if numel(unique(kappa)) ~= numel(kappa)
    error('validate_cost_PIMLOP_v01:DuplicateKappa', ...
        'cost.hyperparameters.kappa must not contain duplicate values.');
end

% Rebuild both groups in one documented order. The generic planner uses
% this field order for stable table columns and combination numbers.
fixedParameters = struct();
fixedParameters.measurementSubsampleFraction   = double(measurementSubsampleFraction);
fixedParameters.positionStandardDeviationImage = double(positionStandardDeviationImage(:).');

hyperparameters = struct();
hyperparameters.kappa = double(kappa(:).');
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
