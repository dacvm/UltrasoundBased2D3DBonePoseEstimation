function [fixedParameters, hyperparameters] = validate_cost_PIMLOP_v01(fixedParameters, hyperparameters)
%VALIDATE_COST_PIMLOP_V01 Validate P-IMLOP V1 settings.
% This function checks the configuration owned by the P-IMLOP cost model
% (cost_PIMLOP_v01). It is needed so the shared configuration reader can
% validate this model without knowing its model-specific settings.
%
% Inputs:
%   fixedParameters - Struct containing:
%                     measurementSubsampleFraction, the fraction (0, 1] of
%                     valid surface points kept from every image; and
%                     positionXStandardDeviationImage,
%                     positionYStandardDeviationImage,
%                     positionZStandardDeviationImage, the position
%                     standard deviations in mm along the image x, y and
%                     out-of-plane z axes (one positive scalar each).
%   hyperparameters - Struct containing:
%                     kappa, a list of candidate orientation concentrations
%                     (nonnegative, no duplicates). A single run uses a
%                     one-value list, for example [50].
%
% Outputs:
%   fixedParameters - Validated fixed settings stored as double scalars.
%   hyperparameters - Validated candidate lists stored as double row
%                     vectors; the experiment plan sweeps every value.
%
% Note: kappa is a hyperparameter because, with the position covariance
% fixed, it alone sets how strongly the orientation term counts against the
% position term, and the paper's value (50) was assumed, not tuned for our
% normals. The cost function does not care about the split: the run
% configuration places fixed values and the chosen kappa together under
% config.cost.parameters.
%
% The three position standard deviations are separate scalar fields, not
% one [sx sy sz] list, so a reader of the JSON does not mistake them for
% candidate values that the experiment would sweep.

% Require exactly the documented fields so missing or misspelled settings fail early.
positionStandardDeviationNames = { ...
    'positionXStandardDeviationImage', ...
    'positionYStandardDeviationImage', ...
    'positionZStandardDeviationImage'};
validateFieldNames(fixedParameters, ...
    [{'measurementSubsampleFraction'}, positionStandardDeviationNames], ...
    'cost.fixedParameters');
validateFieldNames(hyperparameters, {'kappa'}, 'cost.hyperparameters');

% The subsample fraction keeps part of each surface curve, so it must lie in (0, 1].
measurementSubsampleFraction = fixedParameters.measurementSubsampleFraction;
validateattributes(measurementSubsampleFraction, {'numeric'}, ...
    {'scalar', 'real', 'finite', '>', 0, '<=', 1}, ...
    mfilename, 'cost.fixedParameters.measurementSubsampleFraction');

% One standard deviation per image axis builds the diagonal position
% covariance, so each one must be a single positive number.
for nameIndex = 1:numel(positionStandardDeviationNames)
    parameterName = positionStandardDeviationNames{nameIndex};
    validateattributes(fixedParameters.(parameterName), {'numeric'}, ...
        {'scalar', 'real', 'finite', 'positive'}, ...
        mfilename, ['cost.fixedParameters.' parameterName]);
end

% Kappa weights the orientation term; zero switches it off, so every
% candidate must be nonnegative. A repeated value would only repeat the
% same runs, so duplicates are rejected like in the other cost models.
kappaCandidates = hyperparameters.kappa;
validateattributes(kappaCandidates, {'numeric'}, ...
    {'vector', 'nonempty', 'real', 'finite', 'nonnegative'}, ...
    mfilename, 'cost.hyperparameters.kappa');
if numel(unique(kappaCandidates)) ~= numel(kappaCandidates)
    error('validate_cost_PIMLOP_v01:DuplicateCandidate', ...
        'cost.hyperparameters.kappa must not contain duplicate values.');
end

% Rebuild both groups in one documented order. The generic planner uses
% this field order for stable table columns and combination numbers.
validatedFixedParameters = struct();
validatedFixedParameters.measurementSubsampleFraction    = double(measurementSubsampleFraction);
validatedFixedParameters.positionXStandardDeviationImage = double(fixedParameters.positionXStandardDeviationImage);
validatedFixedParameters.positionYStandardDeviationImage = double(fixedParameters.positionYStandardDeviationImage);
validatedFixedParameters.positionZStandardDeviationImage = double(fixedParameters.positionZStandardDeviationImage);
fixedParameters = validatedFixedParameters;

% The planner expects every candidate list as a row vector.
hyperparameters = struct();
hyperparameters.kappa = double(kappaCandidates(:).');
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
