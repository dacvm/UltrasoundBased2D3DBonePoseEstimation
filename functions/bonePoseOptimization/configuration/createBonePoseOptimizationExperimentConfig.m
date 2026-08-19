function experimentSpec = createBonePoseOptimizationExperimentConfig(configFilePath)
%CREATEBONEPOSEOPTIMIZATIONEXPERIMENTCONFIG Read an active experiment JSON file.
% This function loads the shared schemaVersion04 settings, validates the
% intersection candidates and repeat seeds, and resolves the experiment
% output folder. Cost-model parameters are validated by their model definition.
%
% Input:
%   configFilePath - Path to a schemaVersion04 experiment configuration.
%
% Output:
%   experimentSpec - Resolved experiment specification containing fixed
%                    settings, candidate lists, seeds, and output paths.

%% LOAD THE SHARED CONFIGURATION FIELDS

% Reuse the shared schema, path, and cost-model parsing.
experimentSpec  = createBonePoseOptimizationConfig(configFilePath);
% Read the raw JSON once more because the shared reader does not own experiment settings.
rawConfig       = jsondecode(fileread(configFilePath));

%% NORMALIZE THE HYPERPARAMETER CANDIDATES

% The intersection tolerance remains one explicit non-cost sweep setting.
experimentSpec.intersection.normalFacingToleranceDeg = normalizePositiveCandidates( ...
    experimentSpec.intersection.normalFacingToleranceDeg, 'intersection.normalFacingToleranceDeg');

%% READ THE EXPERIMENT SETTINGS

% Require one experiment section because it identifies and repeats the complete sweep.
experimentConfig                = getRequiredField(rawConfig, 'experiment', 'experiment');

% Use a readable name in folder names and saved metadata.
experimentSpec.experiment.name  = ensureSafeExperimentName(getRequiredField(experimentConfig, 'name', 'experiment.name'));
% Normalize the explicit seed list so every combination receives the same repetitions.
experimentSpec.experiment.seeds = normalizeSeeds(getRequiredField(experimentConfig, 'seeds', 'experiment.seeds'));

% Resolve the experiment output against the project root, matching other project paths.
configuredOutputFolder = ensureScalarText(getRequiredField(experimentConfig, 'outputFolder', 'experiment.outputFolder'), 'experiment.outputFolder');
experimentSpec.experiment.outputFolder = makeAbsolutePath(configuredOutputFolder, experimentSpec.project.root);

%% CHECK FIXED OPTIMIZER SETTINGS

% These settings stay scalar because optimizer tuning is outside this sweep.
validatePositiveScalar(experimentSpec.optimizer.translationBoundMm,     'optimizer.translationBoundMm',     false);
validatePositiveScalar(experimentSpec.optimizer.rotationBoundDeg,       'optimizer.rotationBoundDeg',       false);
validatePositiveScalar(experimentSpec.optimizer.translationSigmaMm,     'optimizer.translationSigmaMm',     false);
validatePositiveScalar(experimentSpec.optimizer.rotationSigmaDeg,       'optimizer.rotationSigmaDeg',       false);
validatePositiveScalar(experimentSpec.optimizer.populationSize,         'optimizer.populationSize',         true);
validatePositiveScalar(experimentSpec.optimizer.maxFunctionEvaluations, 'optimizer.maxFunctionEvaluations', true);
validatePositiveScalar(experimentSpec.optimizer.parforWorkers,          'optimizer.parforWorkers',          true);
validateattributes(experimentSpec.optimizer.useParfor, {'logical', 'numeric'}, {'scalar'}, mfilename, 'optimizer.useParfor');

experimentSpec.optimizer.useParfor = logical(experimentSpec.optimizer.useParfor);
end






function candidates = normalizePositiveCandidates(rawCandidates, displayName)
%NORMALIZEPOSITIVECANDIDATES Validate and reshape one positive candidate list.
% rawCandidates contains one or more numeric values, displayName identifies
% the JSON field, and candidates is the resulting row vector.

% Candidate collections must be simple numeric vectors so their Cartesian product is clear.
validateattributes(rawCandidates, {'numeric'}, {'vector', 'nonempty', 'real', 'finite'}, mfilename, displayName);

% The geometric tolerance must be greater than zero.
if any(rawCandidates <= 0)
    error('createBonePoseOptimizationExperimentConfig:NonpositiveCandidate', ...
          '%s values must be positive.', displayName);
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
    validateattributes(value, {'numeric'}, {'scalar', 'positive', 'finite', 'integer'}, mfilename, displayName);
else
    validateattributes(value, {'numeric'}, {'scalar', 'positive', 'finite'}, mfilename, displayName);
end
end


function value = getRequiredField(sourceStruct, fieldName, displayName)
%GETREQUIREDFIELD Read one required field from a JSON-derived struct.
% sourceStruct is the parent struct, fieldName is its MATLAB field, displayName
% is used in errors, and value is the stored field value.

% Stop at the missing field so the user can correct the active JSON directly.
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
