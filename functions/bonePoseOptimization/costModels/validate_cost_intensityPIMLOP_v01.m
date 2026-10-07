function [fixedParameters, hyperparameters] = validate_cost_intensityPIMLOP_v01(fixedParameters, hyperparameters)
%VALIDATE_COST_INTENSITYPIMLOP_V01 Validate combined intensity and P-IMLOP settings.
% This validator checks the union of the smoothed-intensity and P-IMLOP
% settings plus the blend weight. It reuses
% the two component validators so their established parameter rules stay in
% one place while returning a stable field order for experiment planning.
%
% Inputs:
%   fixedParameters - Struct containing intensityMax, sampleSpacingMm,
%                     measurementSubsampleFraction,
%                     positionXStandardDeviationImage,
%                     positionYStandardDeviationImage, and
%                     positionZStandardDeviationImage.
%   hyperparameters - Struct containing intensitySmoothingSigmaMm, kappa,
%                     and weight candidate arrays.
%
% Outputs:
%   fixedParameters - Validated fixed settings stored as scalar doubles.
%   hyperparameters - Validated candidate arrays stored as row vectors in
%                     the documented planning order.

% Require the complete combined-model schema so spelling mistakes are
% reported before data preparation or optimization begins.
pimlopFixedNames = { ...
    'measurementSubsampleFraction', ...
    'positionXStandardDeviationImage', ...
    'positionYStandardDeviationImage', ...
    'positionZStandardDeviationImage'};
validateFieldNames(fixedParameters, [{'intensityMax', 'sampleSpacingMm'}, pimlopFixedNames], 'cost.fixedParameters');
validateFieldNames(hyperparameters, {'intensitySmoothingSigmaMm', 'kappa', 'weight'}, 'cost.hyperparameters');

% Reuse each component validator on the settings that belong to that model.
intensityFixed = struct( ...
    'intensityMax',    fixedParameters.intensityMax, ...
    'sampleSpacingMm', fixedParameters.sampleSpacingMm);
intensityHyper = struct( ...
    'intensitySmoothingSigmaMm', hyperparameters.intensitySmoothingSigmaMm);
[intensityFixed, intensityHyper] = validate_cost_intensityCov_v02(intensityFixed, intensityHyper);

pimlopFixed = struct();
for nameIndex = 1:numel(pimlopFixedNames)
    pimlopFixed.(pimlopFixedNames{nameIndex}) = fixedParameters.(pimlopFixedNames{nameIndex});
end
pimlopHyper = struct('kappa', hyperparameters.kappa);
[pimlopFixed, pimlopHyper] = validate_cost_PIMLOP_v01(pimlopFixed, pimlopHyper);

% Weight is a sweep candidate and must remain a valid convex blend coefficient.
weight = normalizeWeightCandidates(hyperparameters.weight);

% Rebuild both groups in the order used for experiment table columns.
fixedParameters = struct();
fixedParameters.intensityMax                    = intensityFixed.intensityMax;
fixedParameters.sampleSpacingMm                 = intensityFixed.sampleSpacingMm;
fixedParameters.measurementSubsampleFraction    = pimlopFixed.measurementSubsampleFraction;
fixedParameters.positionXStandardDeviationImage = pimlopFixed.positionXStandardDeviationImage;
fixedParameters.positionYStandardDeviationImage = pimlopFixed.positionYStandardDeviationImage;
fixedParameters.positionZStandardDeviationImage = pimlopFixed.positionZStandardDeviationImage;

hyperparameters = struct();
hyperparameters.intensitySmoothingSigmaMm = intensityHyper.intensitySmoothingSigmaMm;
hyperparameters.kappa                     = pimlopHyper.kappa;
hyperparameters.weight                    = weight;
end


%%

function validateFieldNames(sourceStruct, expectedNames, displayName)
%VALIDATEFIELDNAMES Require exactly the documented combined-model fields.
% sourceStruct is one JSON-derived parameter group, expectedNames lists its
% accepted fields, and displayName identifies the group in error messages.

if ~isstruct(sourceStruct) || ~isscalar(sourceStruct)
    error('validate_cost_intensityPIMLOP_v01:InvalidParameterGroup', ...
        '%s must be a JSON object.', displayName);
end

actualNames     = fieldnames(sourceStruct).';
missingNames    = setdiff(expectedNames, actualNames, 'stable');
unexpectedNames = setdiff(actualNames, expectedNames, 'stable');

if ~isempty(missingNames)
    error('validate_cost_intensityPIMLOP_v01:MissingParameter', ...
        '%s is missing: %s.', displayName, strjoin(missingNames, ', '));
end
if ~isempty(unexpectedNames)
    error('validate_cost_intensityPIMLOP_v01:UnexpectedParameter', ...
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
    error('validate_cost_intensityPIMLOP_v01:DuplicateWeight', ...
        'cost.hyperparameters.weight must not contain duplicate values.');
end

weight = double(rawWeight(:).');
end
