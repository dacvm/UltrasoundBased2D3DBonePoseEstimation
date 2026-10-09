function [fixedParameters, hyperparameters] = validate_cost_intensityLine(fixedParameters, hyperparameters)
%VALIDATE_COST_INTENSITYLINE Validate smoothed-intensity cost settings.
% This function checks the fixed and sweepable parameters of the
% intensityLine cost model, so the shared config reader does not need to
% know what each model-specific setting means. Mistakes are reported when
% the config is read, before the slow preparation starts.
%
% Inputs:
%   fixedParameters - Struct with intensityMax (intensity that counts as
%                     full evidence) and sampleSpacingMm (distance between
%                     sample points along the predicted bone lines).
%   hyperparameters - Struct with intensitySmoothingSigmaMm, the candidate
%                     Gaussian blur widths in mm.
%
% Outputs:
%   fixedParameters - Validated fixed settings stored as scalar doubles.
%   hyperparameters - Validated candidate arrays stored as row vectors.

% Require exactly the documented fields so JSON spelling mistakes fail early.
validateFieldNames(fixedParameters, {'intensityMax', 'sampleSpacingMm'}, 'cost.fixedParameters');
validateFieldNames(hyperparameters, {'intensitySmoothingSigmaMm'}, 'cost.hyperparameters');

validateattributes(fixedParameters.intensityMax, {'numeric'}, ...
    {'scalar', 'real', 'positive', 'finite'}, mfilename, 'cost.fixedParameters.intensityMax');
validateattributes(fixedParameters.sampleSpacingMm, {'numeric'}, ...
    {'scalar', 'real', 'positive', 'finite'}, mfilename, 'cost.fixedParameters.sampleSpacingMm');

% A sigma of 0 is allowed: it reads the raw image, which is useful as a
% baseline in a sweep.
sigmaCandidates = hyperparameters.intensitySmoothingSigmaMm;
validateattributes(sigmaCandidates, {'numeric'}, ...
    {'vector', 'nonempty', 'real', 'finite', 'nonnegative'}, ...
    mfilename, 'cost.hyperparameters.intensitySmoothingSigmaMm');
if numel(unique(sigmaCandidates)) ~= numel(sigmaCandidates)
    error('validate_cost_intensityLine:DuplicateCandidate', ...
          'cost.hyperparameters.intensitySmoothingSigmaMm must not contain duplicate values.');
end

% Rebuild both groups in one documented order. The generic planner uses
% this field order for stable table columns and combination numbers.
fixedParameters = struct( ...
    'intensityMax',    double(fixedParameters.intensityMax), ...
    'sampleSpacingMm', double(fixedParameters.sampleSpacingMm));
hyperparameters = struct( ...
    'intensitySmoothingSigmaMm', double(sigmaCandidates(:).'));
end


%%

function validateFieldNames(sourceStruct, expectedNames, displayName)
%VALIDATEFIELDNAMES Require exactly the documented fields in one config group.
% sourceStruct is the JSON-derived parameter struct, expectedNames lists the
% accepted fields, and displayName identifies the group in error messages.

if ~isstruct(sourceStruct) || ~isscalar(sourceStruct)
    error('validate_cost_intensityLine:InvalidParameterGroup', ...
          '%s must be a JSON object.', displayName);
end

actualNames     = fieldnames(sourceStruct).';
missingNames    = setdiff(expectedNames, actualNames, 'stable');
unexpectedNames = setdiff(actualNames, expectedNames, 'stable');

if ~isempty(missingNames)
    error('validate_cost_intensityLine:MissingParameter', ...
          '%s is missing: %s.', displayName, strjoin(missingNames, ', '));
end

if ~isempty(unexpectedNames)
    error('validate_cost_intensityLine:UnexpectedParameter', ...
          '%s contains an unsupported field: %s.', displayName, strjoin(unexpectedNames, ', '));
end
end
