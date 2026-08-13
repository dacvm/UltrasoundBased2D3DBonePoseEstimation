function experimentSpec = createBonePoseOptimizationExperimentConfig(configFilePath)
%CREATEBONEPOSEOPTIMIZATIONEXPERIMENTCONFIG Read a v03 experiment JSON file.
% This function loads the shared bone-pose settings, validates the four
% hyperparameter candidate lists and the repeat seeds, and resolves the
% experiment output folder. A separate reader is needed so the existing v02
% reader can keep representing one scalar optimization configuration.
%
% Input:
%   configFilePath - Path to the v03 JSON experiment configuration.
%
% Output:
%   experimentSpec - Resolved experiment specification containing fixed
%                    settings, candidate lists, seeds, and output paths.

%% LOAD THE SHARED CONFIGURATION FIELDS

% Reuse the established path and input parsing used by the v02 workflow.
experimentSpec = createBonePoseOptimizationConfig(configFilePath);
% Read the raw JSON once more because the v02 reader does not know the experiment section.
rawConfig = jsondecode(fileread(configFilePath));

%% NORMALIZE THE HYPERPARAMETER CANDIDATES

% Treat a scalar as a one-value candidate list and a vector as several candidates.
experimentSpec.intersection.normalFacingToleranceDeg = normalizeCandidates( ...
    experimentSpec.intersection.normalFacingToleranceDeg, ...
    'intersection.normalFacingToleranceDeg', true);
experimentSpec.cost.minReferencePixels = normalizeCandidates( ...
    experimentSpec.cost.minReferencePixels, ...
    'cost.minReferencePixels', true);
experimentSpec.cost.nMinPixels = normalizeCandidates( ...
    experimentSpec.cost.nMinPixels, ...
    'cost.nMinPixels', true);
experimentSpec.cost.lambdaMissing = normalizeCandidates( ...
    experimentSpec.cost.lambdaMissing, ...
    'cost.lambdaMissing', false);

% Keep intensity normalization fixed because it is not part of this sweep.
validateattributes(experimentSpec.cost.intensityMax, {'numeric'}, ...
    {'scalar', 'positive', 'finite'}, mfilename, 'cost.intensityMax');

%% READ THE EXPERIMENT SETTINGS

% Require one experiment section because it identifies and repeats the complete sweep.
experimentConfig = getRequiredField(rawConfig, 'experiment', 'experiment');
% Use a readable name in folder names and saved metadata.
experimentSpec.experiment.name = ensureSafeExperimentName( ...
    getRequiredField(experimentConfig, 'name', 'experiment.name'));
% Normalize the explicit seed list so every combination receives the same repetitions.
experimentSpec.experiment.seeds = normalizeSeeds( ...
    getRequiredField(experimentConfig, 'seeds', 'experiment.seeds'));

% Resolve the experiment output against the project root, matching other project paths.
configuredOutputFolder = ensureScalarText( ...
    getRequiredField(experimentConfig, 'outputFolder', ...
    'experiment.outputFolder'), 'experiment.outputFolder');
experimentSpec.experiment.outputFolder = makeAbsolutePath( ...
    configuredOutputFolder, experimentSpec.project.root);

%% CHECK FIXED OPTIMIZER SETTINGS

% These settings stay scalar because optimizer tuning is outside the v03 sweep.
validatePositiveScalar(experimentSpec.optimizer.translationBoundMm, ...
    'optimizer.translationBoundMm', false);
validatePositiveScalar(experimentSpec.optimizer.rotationBoundDeg, ...
    'optimizer.rotationBoundDeg', false);
validatePositiveScalar(experimentSpec.optimizer.translationSigmaMm, ...
    'optimizer.translationSigmaMm', false);
validatePositiveScalar(experimentSpec.optimizer.rotationSigmaDeg, ...
    'optimizer.rotationSigmaDeg', false);
validatePositiveScalar(experimentSpec.optimizer.populationSize, ...
    'optimizer.populationSize', true);
validatePositiveScalar(experimentSpec.optimizer.maxFunctionEvaluations, ...
    'optimizer.maxFunctionEvaluations', true);
validatePositiveScalar(experimentSpec.optimizer.parforWorkers, ...
    'optimizer.parforWorkers', true);
validateattributes(experimentSpec.optimizer.useParfor, {'logical', 'numeric'}, ...
    {'scalar'}, mfilename, 'optimizer.useParfor');
experimentSpec.optimizer.useParfor = logical(experimentSpec.optimizer.useParfor);
end


function candidates = normalizeCandidates(rawCandidates, displayName, requirePositive)
%NORMALIZECANDIDATES Validate and reshape one hyperparameter candidate list.
% rawCandidates contains one or more numeric values, displayName identifies
% the JSON field, requirePositive selects positive or nonnegative validation,
% and candidates is the resulting row vector.

% Candidate collections must be simple numeric vectors so their Cartesian product is clear.
validateattributes(rawCandidates, {'numeric'}, ...
    {'vector', 'nonempty', 'real', 'finite'}, mfilename, displayName);

% Positive thresholds cannot use zero, while a missing-penalty weight may be zero.
if requirePositive && any(rawCandidates <= 0)
    error('createBonePoseOptimizationExperimentConfig:NonpositiveCandidate', ...
        '%s values must be positive.', displayName);
elseif ~requirePositive && any(rawCandidates < 0)
    error('createBonePoseOptimizationExperimentConfig:NegativeCandidate', ...
        '%s values must be nonnegative.', displayName);
end

% Duplicate values would create duplicate optimization runs without adding information.
if numel(unique(rawCandidates)) ~= numel(rawCandidates)
    error('createBonePoseOptimizationExperimentConfig:DuplicateCandidate', ...
        '%s must not contain duplicate values.', displayName);
end

% Store every candidate list in the same row-vector shape for plan generation.
candidates = double(rawCandidates(:).');
end


function seeds = normalizeSeeds(rawSeeds)
%NORMALIZESEEDS Validate the repeat seeds used for every combination.
% rawSeeds contains seed values from JSON and seeds is a row vector of
% distinct positive integers accepted by the CMA-ES Seed option.

% Seeds must be finite integers so saved experiment runs are easy to identify.
validateattributes(rawSeeds, {'numeric'}, ...
    {'vector', 'nonempty', 'real', 'finite', 'integer', 'positive'}, ...
    mfilename, 'experiment.seeds');

% Repeating one seed would repeat the same intended stochastic condition.
if numel(unique(rawSeeds)) ~= numel(rawSeeds)
    error('createBonePoseOptimizationExperimentConfig:DuplicateSeed', ...
        'experiment.seeds must not contain duplicate values.');
end

% Preserve the JSON ordering because it becomes the run order inside each combination.
seeds = double(rawSeeds(:).');
end


function experimentName = ensureSafeExperimentName(rawName)
%ENSURESAFEEXPERIMENTNAME Validate text used in the experiment folder name.
% rawName is the JSON name value and experimentName is a safe character row.

% Normalize MATLAB text types before applying the folder-name rule.
experimentName = ensureScalarText(rawName, 'experiment.name');
% Keep the name portable and readable by allowing letters, numbers, underscores, and hyphens.
if isempty(regexp(experimentName, '^[A-Za-z0-9][A-Za-z0-9_-]*$', 'once'))
    error('createBonePoseOptimizationExperimentConfig:InvalidExperimentName', ...
        ['experiment.name must start with a letter or number and contain ' ...
         'only letters, numbers, underscores, or hyphens.']);
end
end


function validatePositiveScalar(value, displayName, requireInteger)
%VALIDATEPOSITIVESCALAR Check one fixed positive optimizer setting.
% value is the configured setting, displayName names it in an error, and
% requireInteger selects whether fractional values are rejected. This helper
% has no output and throws when the setting is invalid.

% Counts require integers, while physical bounds and sigmas may be fractional.
if requireInteger
    validateattributes(value, {'numeric'}, ...
        {'scalar', 'positive', 'finite', 'integer'}, mfilename, displayName);
else
    validateattributes(value, {'numeric'}, ...
        {'scalar', 'positive', 'finite'}, mfilename, displayName);
end
end


function value = getRequiredField(sourceStruct, fieldName, displayName)
%GETREQUIREDFIELD Read one required field from a JSON-derived struct.
% sourceStruct is the parent struct, fieldName is its MATLAB field, displayName
% is used in errors, and value is the stored field value.

% Stop at the missing field so the user can correct the v03 JSON directly.
if ~isstruct(sourceStruct) || ~isfield(sourceStruct, fieldName)
    error('createBonePoseOptimizationExperimentConfig:MissingField', ...
        'Missing required configuration field: %s', displayName);
end
value = sourceStruct.(fieldName);
end


function value = ensureScalarText(rawValue, displayName)
%ENSURESCALARTEXT Convert one string scalar or character row to char.
% rawValue contains JSON or MATLAB text, displayName identifies it in an
% error, and value is the normalized character row.

% Accept the two scalar text representations used by this project.
if isstring(rawValue) && isscalar(rawValue)
    value = char(rawValue);
elseif ischar(rawValue) && isrow(rawValue)
    value = rawValue;
else
    error('createBonePoseOptimizationExperimentConfig:InvalidText', ...
        '%s must be a character vector or string scalar.', displayName);
end
end


function absolutePath = makeAbsolutePath(inputPath, baseFolder)
%MAKEABSOLUTEPATH Resolve one configured path against the project root.
% inputPath is the configured folder, baseFolder is the project root, and
% absolutePath is the canonical absolute folder path.

% Let Java identify absolute paths so Windows drive and UNC paths stay valid.
pathObject = java.io.File(inputPath);
if pathObject.isAbsolute()
    absolutePath = char(pathObject.getCanonicalPath());
else
    absolutePath = char(java.io.File(fullfile(baseFolder, inputPath)).getCanonicalPath());
end
end
