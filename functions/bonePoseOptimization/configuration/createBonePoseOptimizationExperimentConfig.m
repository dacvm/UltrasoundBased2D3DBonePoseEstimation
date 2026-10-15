function experimentSpec = createBonePoseOptimizationExperimentConfig(configFilePath)
%CREATEBONEPOSEOPTIMIZATIONEXPERIMENTCONFIG Read an active experiment JSON file.
% This function loads the shared schemaVersion04 settings, validates the
% intersection candidates and repeat seeds, and resolves the experiment
% output folder. When experiment.resumeFolder is set, it also checks that
% the JSON still matches the experiment being resumed. Cost-model
% parameters are checked by their model validator.
%
% Where it fits in the framework:
%   A bone-pose experiment runs in three configuration steps, always in
%   this order (see main_bonePoseOptimization_*.m and
%   runBonePoseOptimizationExperiment.m):
%     1. createBonePoseOptimizationExperimentConfig (this function)
%        JSON file  ->  experimentSpec (everything checked, nothing run yet)
%     2. createBonePoseOptimizationExperimentPlan
%        experimentSpec  ->  table of every combination and every run
%     3. createBonePoseOptimizationRunConfig
%        experimentSpec + one plan row  ->  config for one single run
%   This function is the FIRST step and the only one that touches the JSON
%   file. It is called once, at the very start of an experiment.
%
% Why it is needed:
%   An experiment can take hours (many combinations x many seeds). If a
%   typo or bad value in the JSON were only discovered when the run that
%   uses it starts, hours of work could be wasted or, worse, results would
%   be produced with wrong settings. So this function reads the whole JSON
%   up front, checks every experiment-level setting, and turns relative
%   paths into absolute ones. After it returns, later steps can trust
%   experimentSpec without re-checking it, and the user gets any error
%   within seconds instead of halfway through the sweep.
%
%   It builds on createBonePoseOptimizationConfig (the shared reader used
%   for single runs too) and only adds what is specific to an experiment:
%   candidate lists to sweep, repeat seeds, the experiment name, and the
%   experiment output folder.
%
% Input:
%   configFilePath - Path to a schemaVersion04 experiment configuration.
%
% Output:
%   experimentSpec - Resolved experiment specification containing fixed
%                    settings, candidate lists, seeds, and output paths.

%% LOAD THE SHARED CONFIGURATION FIELDS

% Why reuse the shared reader: data paths, schema version, intersection and
% optimizer settings, and the cost model (including its own validator for
% the cost parameters) are read in exactly the same way for a single run
% and for an experiment. Calling the shared reader keeps that logic in one
% place, so a fix there automatically applies to experiments too.
experimentSpec  = createBonePoseOptimizationConfig(configFilePath);

% The face-toward-probe tolerance (in degrees) controls which mesh faces
% count as visible to the probe. It is not a cost parameter, but we still
% want to sweep it, so the JSON may give a list of candidate values. Here we
% check that list (positive, no duplicates) and store it as a row vector,
% because the plan step expects every sweep list in that same shape.
experimentSpec.intersection.normalFacingToleranceDeg = normalizePositiveCandidates( ...
    experimentSpec.intersection.normalFacingToleranceDeg, 'intersection.normalFacingToleranceDeg');

%% READ THE EXPERIMENT SETTINGS

% The shared reader ignores the "experiment" section (single runs do not
% have one), so we read the raw JSON again to get it. This is cheap: the
% file is small and this happens only once per experiment.
rawConfig        = jsondecode(fileread(configFilePath));
% The "experiment" section is required: without it we would not know how
% to name the experiment, how many repeats to run, or where to save results.
experimentConfig = getRequiredField(rawConfig, 'experiment', 'experiment');

% The name is used inside folder names and saved metadata, so it must be
% safe for the file system (no spaces, slashes, etc.) and easy to recognise
% when browsing results later.
experimentSpec.experiment.name  = ensureSafeExperimentName(getRequiredField(experimentConfig, 'name', 'experiment.name'));
% Seeds control the random start of CMA-ES. Each combination is run once
% per seed, so the spread of results shows how stable the optimizer is.
% Using the same explicit seed list for every combination keeps the
% comparison between combinations fair and makes every run reproducible.
experimentSpec.experiment.seeds = normalizeSeeds(getRequiredField(experimentConfig, 'seeds', 'experiment.seeds'));

% A relative output path would otherwise depend on MATLAB's current folder
% at the time of saving, which can change (e.g. inside parfor workers).
% Resolving it once against the project root, like all other project
% paths, makes sure every run writes to the same, predictable place.
configuredOutputFolder = ensureScalarText(getRequiredField(experimentConfig, 'outputFolder', 'experiment.outputFolder'), 'experiment.outputFolder');
experimentSpec.experiment.outputFolder = makeAbsolutePath(configuredOutputFolder, experimentSpec.project.root);

% resumeFolder is optional. Empty (or missing) means "start a new
% experiment". A folder path means "continue the experiment in that folder":
% the runner then skips every run that already has a valid result file.
% It lives in the git-ignored local JSON, so resuming never changes a
% tracked file.
configuredResumeFolder = '';
if isfield(experimentConfig, 'resumeFolder') && ~isempty(experimentConfig.resumeFolder)
    configuredResumeFolder = ensureScalarText(experimentConfig.resumeFolder, 'experiment.resumeFolder');
end

if isempty(configuredResumeFolder)
    experimentSpec.experiment.resumeFolder = '';
else
    % Resolve it like outputFolder, so a path relative to the project root
    % (e.g. "output/bonePoseOptimization/experiments/<name>") works.
    resumeFolder = makeAbsolutePath(configuredResumeFolder, experimentSpec.project.root);
    checkResumeFolderMatchesConfig(resumeFolder, rawConfig);
    experimentSpec.experiment.resumeFolder = resumeFolder;
end

%% CHECK FIXED OPTIMIZER SETTINGS

% This experiment sweeps cost and intersection settings, not optimizer
% settings. Each optimizer setting must therefore be ONE positive number
% shared by all runs; otherwise differences between combinations could come
% from the optimizer instead of from the parameters we want to study.
% Checking them here (bounds and sigmas may be fractional, counts must be
% integers) catches a bad value before the first expensive run starts.
validatePositiveScalar(experimentSpec.optimizer.translationBoundMm,     'optimizer.translationBoundMm',     false);
validatePositiveScalar(experimentSpec.optimizer.rotationBoundDeg,       'optimizer.rotationBoundDeg',       false);
validatePositiveScalar(experimentSpec.optimizer.translationSigmaMm,     'optimizer.translationSigmaMm',     false);
validatePositiveScalar(experimentSpec.optimizer.rotationSigmaDeg,       'optimizer.rotationSigmaDeg',       false);
validatePositiveScalar(experimentSpec.optimizer.populationSize,         'optimizer.populationSize',         true);
validatePositiveScalar(experimentSpec.optimizer.maxFunctionEvaluations, 'optimizer.maxFunctionEvaluations', true);
validatePositiveScalar(experimentSpec.optimizer.parforWorkers,          'optimizer.parforWorkers',          true);
validateattributes(experimentSpec.optimizer.useParfor, {'logical', 'numeric'}, {'scalar'}, mfilename, 'optimizer.useParfor');

% JSON may give true/false or 1/0. Converting to logical once means the
% runner can use it directly in an if-statement without guessing its type.
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


function checkResumeFolderMatchesConfig(resumeFolder, rawConfig)
%CHECKRESUMEFOLDERMATCHESCONFIG Stop if the JSON differs from the resumed experiment.
% resumeFolder is the absolute experiment folder to continue and rawConfig
% is the decoded local JSON. This helper has no output and throws when the
% folder is not an experiment folder or its settings differ from the JSON.
%
% Why this check exists:
%   When resuming, the runner takes all settings from the experiment folder
%   itself, not from the JSON. If the JSON had been edited since the sweep
%   started, those edits would be silently ignored, and the user would
%   believe they were used. The same happens when resumeFolder is
%   forgotten in the JSON while preparing a NEW experiment. Requiring the
%   JSON to equal the snapshot saved at the start catches both mistakes.

if ~isfolder(resumeFolder)
    error('createBonePoseOptimizationExperimentConfig:ResumeFolderNotFound', ...
          'experiment.resumeFolder does not exist: %s', resumeFolder);
end

% Every experiment saves a copy of the JSON it was started with.
snapshotFilePath = fullfile(resumeFolder, 'experiment_config_snapshot.json');
if ~isfile(snapshotFilePath)
    error('createBonePoseOptimizationExperimentConfig:ResumeSnapshotNotFound', ...
          ['experiment.resumeFolder is not an experiment folder ' ...
           '(no experiment_config_snapshot.json): %s'], resumeFolder);
end
snapshotConfig = jsondecode(fileread(snapshotFilePath));

% resumeFolder itself must be ignored: it is empty in the snapshot (or
% absent in older experiments) and set in the JSON used for resuming.
currentSettings  = removeResumeFolderField(rawConfig);
snapshotSettings = removeResumeFolderField(snapshotConfig);

differentFields = listDifferentFields(currentSettings, snapshotSettings, '');
if ~isempty(differentFields)
    error('createBonePoseOptimizationExperimentConfig:ResumeSettingsChanged', ...
          ['The experiment in experiment.resumeFolder was started with different settings.\n' ...
           'Differences in: %s\n' ...
           'Either restore those settings, or clear experiment.resumeFolder to start a new experiment.'], ...
          strjoin(differentFields, ', '));
end
end


function config = removeResumeFolderField(config)
%REMOVERESUMEFOLDERFIELD Drop experiment.resumeFolder before comparing configs.
% config is a decoded JSON struct and the output is the same struct
% without experiment.resumeFolder.

if isfield(config, 'experiment') && isfield(config.experiment, 'resumeFolder')
    config.experiment = rmfield(config.experiment, 'resumeFolder');
end
end


function differentFields = listDifferentFields(firstStruct, secondStruct, parentPath)
%LISTDIFFERENTFIELDS Name every field whose value differs between two structs.
% firstStruct and secondStruct are decoded JSON structs, parentPath is the
% dotted path of these structs ('' at the top), and differentFields is a
% string array of dotted paths such as "optimizer.populationSize".
%
% Nested scalar structs are compared field by field, so the error message
% can point at the exact setting instead of a whole JSON section.

differentFields = strings(1, 0);
allFieldNames   = union(fieldnames(firstStruct), fieldnames(secondStruct));

for fieldIndex = 1:numel(allFieldNames)
    fieldName = allFieldNames{fieldIndex};
    if isempty(parentPath)
        fieldPath = fieldName;
    else
        fieldPath = [parentPath '.' fieldName];
    end

    if ~isfield(firstStruct, fieldName) || ~isfield(secondStruct, fieldName)
        % A field added or removed is a difference too.
        differentFields(end + 1) = fieldPath; %#ok<AGROW>
    elseif isstruct(firstStruct.(fieldName)) && isscalar(firstStruct.(fieldName)) && ...
           isstruct(secondStruct.(fieldName)) && isscalar(secondStruct.(fieldName))
        % Go one level deeper to find the exact differing setting.
        differentFields = [differentFields, ...
            listDifferentFields(firstStruct.(fieldName), secondStruct.(fieldName), fieldPath)]; %#ok<AGROW>
    elseif ~isequal(firstStruct.(fieldName), secondStruct.(fieldName))
        differentFields(end + 1) = fieldPath; %#ok<AGROW>
    end
end
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
