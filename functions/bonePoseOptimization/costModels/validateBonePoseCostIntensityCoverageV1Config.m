function [fixedParameters, hyperparameters] = validateBonePoseCostIntensityCoverageV1Config(fixedParameters, hyperparameters)
%VALIDATEBONEPOSECOSTINTENSITYCOVERAGEV1CONFIG Validate V1 experiment settings.
% This function checks the fixed and sweepable parameters owned by the
% intensity-and-coverage V1 cost model. It is needed so the shared config
% reader does not need to know the meaning of each model-specific setting.
%
% Inputs:
%   fixedParameters - Struct containing the fixed intensity normalization.
%   hyperparameters - Struct containing candidate arrays for the V1 sweep.
%
% Outputs:
%   fixedParameters - Validated fixed settings with numeric values as double.
%   hyperparameters - Validated candidate settings stored as row vectors.

% Require the small, documented V1 parameter set so JSON spelling mistakes fail early.
validateFieldNames(fixedParameters, {'intensityMax'}, 'cost.fixedParameters');
validateFieldNames(hyperparameters, {'minReferencePixels', 'nMinPixels', 'lambdaMissing'}, 'cost.hyperparameters');

% Intensity normalization is fixed for the complete experiment.
validateattributes(fixedParameters.intensityMax, {'numeric'}, ...
    {'scalar', 'real', 'positive', 'finite'}, mfilename, ...
    'cost.fixedParameters.intensityMax');
fixedParameters.intensityMax = double(fixedParameters.intensityMax);

% Normalize candidate arrays now so the explicit Stage 2 planner sees one stable shape.
hyperparameters.minReferencePixels  = normalizeCandidates(hyperparameters.minReferencePixels, 'cost.hyperparameters.minReferencePixels', true);
hyperparameters.nMinPixels          = normalizeCandidates(hyperparameters.nMinPixels, 'cost.hyperparameters.nMinPixels', true);
hyperparameters.lambdaMissing       = normalizeCandidates(hyperparameters.lambdaMissing, 'cost.hyperparameters.lambdaMissing', false);
end



%%
function validateFieldNames(sourceStruct, expectedNames, displayName)
%VALIDATEFIELDNAMES Require exactly the documented fields in one config group.
% sourceStruct is the JSON-derived parameter struct, expectedNames lists the
% accepted fields, and displayName identifies the group in error messages.

if ~isstruct(sourceStruct) || ~isscalar(sourceStruct)
    error('validateBonePoseCostIntensityCoverageV1Config:InvalidParameterGroup', ...
        '%s must be a JSON object.', displayName);
end

actualNames     = fieldnames(sourceStruct).';
missingNames    = setdiff(expectedNames, actualNames, 'stable');
unexpectedNames = setdiff(actualNames, expectedNames, 'stable');

if ~isempty(missingNames)
    error('validateBonePoseCostIntensityCoverageV1Config:MissingParameter', ...
          '%s is missing: %s.', displayName, strjoin(missingNames, ', '));
end

if ~isempty(unexpectedNames)
    error('validateBonePoseCostIntensityCoverageV1Config:UnexpectedParameter', ...
          '%s contains an unsupported field: %s.', displayName, strjoin(unexpectedNames, ', '));
end
end



%%
function candidates = normalizeCandidates(rawCandidates, displayName, requirePositive)
%NORMALIZECANDIDATES Validate one V1 hyperparameter candidate list.
% rawCandidates contains configured values, displayName labels errors,
% requirePositive selects the lower-bound rule, and candidates is a row vector.

validateattributes(rawCandidates, {'numeric'}, ...
    {'vector', 'nonempty', 'real', 'finite'}, mfilename, displayName);

if requirePositive && any(rawCandidates <= 0)
    error('validateBonePoseCostIntensityCoverageV1Config:NonpositiveCandidate', ...
          '%s values must be positive.', displayName);
elseif ~requirePositive && any(rawCandidates < 0)
    error('validateBonePoseCostIntensityCoverageV1Config:NegativeCandidate', ...
          '%s values must be nonnegative.', displayName);
end

if numel(unique(rawCandidates)) ~= numel(rawCandidates)
    error('validateBonePoseCostIntensityCoverageV1Config:DuplicateCandidate', ...
        '%s must not contain duplicate values.', displayName);
end

candidates = double(rawCandidates(:).');
end
