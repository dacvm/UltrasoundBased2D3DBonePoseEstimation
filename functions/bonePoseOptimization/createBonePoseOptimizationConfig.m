function config = createBonePoseOptimizationConfig(configFilePath)
%CREATEBONEPOSEOPTIMIZATIONCONFIG Load shared schemaVersion04 settings.
% This function reads one active bone-pose configuration, validates its
% selected cost model, and resolves project paths. Experiment-specific seed
% and output settings are added by createBonePoseOptimizationExperimentConfig.
%
% Input:
%   configFilePath - Path to an active schemaVersion04 JSON configuration.
%
% Output:
%   config         - Nested struct containing project paths, standardized
%                    input files, and optimization settings.

%% READ THE CONFIGURATION FILE

% Active workflows must select their JSON explicitly so archived configs are not used by accident.
if nargin < 1 || isempty(configFilePath)
    error('createBonePoseOptimizationConfig:MissingConfigFilePath', ...
        'An active schemaVersion04 configuration path is required.');
end

% Normalize MATLAB string and character inputs before using file functions.
configFilePath = ensureScalarText(configFilePath, 'configFilePath');
% Convert the path to an absolute path so later bookkeeping is unambiguous.
configFilePath = makeAbsolutePath(configFilePath, pwd);

% Report a direct error when the selected JSON file does not exist.
if ~isfile(configFilePath)
    error('createBonePoseOptimizationConfig:MissingConfigFile', ...
        'Configuration file was not found: %s', configFilePath);
end

% Decode the complete JSON document into the same nested MATLAB structure.
rawConfig = jsondecode(fileread(configFilePath));
% Resolve the project root relative to the folder containing this JSON file.
configFolder = fileparts(configFilePath);

%% CHECK THE CONFIGURATION SCHEMA

% schemaVersion04 introduces explicit cost-model identity and parameter groups.
schemaVersion = getRequiredField(rawConfig, 'schemaVersion', 'schemaVersion');
validateattributes(schemaVersion, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer'}, mfilename, 'schemaVersion');
if schemaVersion ~= 4
    error('createBonePoseOptimizationConfig:UnsupportedSchemaVersion', ...
        'Only schemaVersion04 is supported by the active workflow.');
end
config.schemaVersion = 4;

%% RESOLVE PROJECT AND INPUT PATHS

% Resolve the project root first because every standardized input path uses it.
projectRoot = getRequiredField(rawConfig.project, 'root', 'project.root');
config.project.root = makeAbsolutePath(projectRoot, configFolder);

% Store the absolute functions folder for the optimizer, which temporarily changes folders.
functionsFolderName = getRequiredField( ...
    rawConfig.project, 'functionsFolderName', 'project.functionsFolderName');
config.project.functionsFolder = makeAbsolutePath( ...
    functionsFolderName, config.project.root);

% Normalize the short bone code so matching is independent of text case.
targetBone = upper(ensureScalarText( ...
    getRequiredField(rawConfig.input, 'bone', 'input.bone'), 'input.bone'));
if numel(targetBone) ~= 1
    error('createBonePoseOptimizationConfig:InvalidBoneCode', ...
        'input.bone must be one bone code, such as F or T.');
end
config.input.bone = targetBone;

% Resolve each standardized MAT-file path from the project root.
config.input.validSnapshotsMatFile = makeAbsolutePath( ...
    getRequiredField(rawConfig.input, 'validSnapshotsMatFile', ...
    'input.validSnapshotsMatFile'), config.project.root);
config.input.ctPostProcessedMatFile = makeAbsolutePath( ...
    getRequiredField(rawConfig.input, 'ctPostProcessedMatFile', ...
    'input.ctPostProcessedMatFile'), config.project.root);
config.input.coarseRegistrationMatFile = makeAbsolutePath( ...
    getRequiredField(rawConfig.input, 'coarseRegistrationMatFile', ...
    'input.coarseRegistrationMatFile'), config.project.root);

%% COPY GEOMETRY AND COST SETTINGS

% Keep the probe-facing tolerance explicit because it affects every candidate intersection.
config.intersection.normalFacingToleranceDeg = getRequiredField( ...
    rawConfig.intersection, 'normalFacingToleranceDeg', ...
    'intersection.normalFacingToleranceDeg');

% Read the selected model before asking its own validator to check its parameters.
costConfig = getRequiredField(rawConfig, 'cost', 'cost');
modelName = ensureScalarText( ...
    getRequiredField(costConfig, 'model', 'cost.model'), 'cost.model');
costDefinition = getBonePoseCostDefinition(modelName);

fixedParameters = getRequiredField( ...
    costConfig, 'fixedParameters', 'cost.fixedParameters');
hyperparameters = getRequiredField( ...
    costConfig, 'hyperparameters', 'cost.hyperparameters');
[fixedParameters, hyperparameters] = ...
    costDefinition.validateExperimentConfigFcn( ...
    fixedParameters, hyperparameters);

config.cost.model = costDefinition.modelName;
config.cost.fixedParameters = fixedParameters;
config.cost.hyperparameters = hyperparameters;

% Copy the two progress switches used during preparation and repeated evaluations.
config.logging.printPreparationProgress = getRequiredField( ...
    rawConfig.logging, 'printPreparationProgress', ...
    'logging.printPreparationProgress');
config.logging.printEvaluationProgress = getRequiredField( ...
    rawConfig.logging, 'printEvaluationProgress', ...
    'logging.printEvaluationProgress');

%% COPY OPTIMIZER SETTINGS

% Read optional CMA-ES settings here so the wrapper receives one complete config.
optimizerConfig = getOptionalField(rawConfig, 'optimizer', struct());
config.optimizer.translationBoundMm = getOptionalField( ...
    optimizerConfig, 'translationBoundMm', 10);
config.optimizer.rotationBoundDeg = getOptionalField( ...
    optimizerConfig, 'rotationBoundDeg', 10);
config.optimizer.translationSigmaMm = getOptionalField( ...
    optimizerConfig, 'translationSigmaMm', 5);
config.optimizer.rotationSigmaDeg = getOptionalField( ...
    optimizerConfig, 'rotationSigmaDeg', 5);
config.optimizer.populationSize = getOptionalField( ...
    optimizerConfig, 'populationSize', 12);
config.optimizer.maxFunctionEvaluations = getOptionalField( ...
    optimizerConfig, 'maxFunctionEvaluations', 400);
config.optimizer.useParfor = getOptionalField( ...
    optimizerConfig, 'useParfor', true);
config.optimizer.parforWorkers = getOptionalField( ...
    optimizerConfig, 'parforWorkers', 4);

% Resolve optimizer output once so later folder changes cannot affect it.
defaultOutputFolder = fullfile('output', 'bonePoseOptimization', 'cmaes');
outputFolder = getOptionalField(optimizerConfig, 'outputFolder', defaultOutputFolder);
config.optimizer.outputFolder = makeAbsolutePath(outputFolder, config.project.root);

% Keep the source JSON path with the parsed settings for reproducibility.
config.source.configFilePath = configFilePath;
end


function value = getRequiredField(sourceStruct, fieldName, displayName)
%GETREQUIREDFIELD Read one required configuration field.
% Inputs are the source struct, MATLAB field name, and user-facing field
% name. The output is the stored value.

% Stop at the missing field so the JSON path is easy to identify and fix.
if ~isstruct(sourceStruct) || ~isfield(sourceStruct, fieldName)
    error('createBonePoseOptimizationConfig:MissingField', ...
        'Missing required configuration field: %s', displayName);
end

% Return the configured value without changing its type.
value = sourceStruct.(fieldName);
end


function value = getOptionalField(sourceStruct, fieldName, defaultValue)
%GETOPTIONALFIELD Read one optional field or use its documented default.
% Inputs are the source struct, field name, and default value. The output is
% the configured nonempty value or the supplied default.

% Use the JSON value only when the optional field is present and nonempty.
if isstruct(sourceStruct) && isfield(sourceStruct, fieldName) && ...
        ~isempty(sourceStruct.(fieldName))
    value = sourceStruct.(fieldName);
else
    value = defaultValue;
end
end


function value = ensureScalarText(rawValue, displayName)
%ENSURESCALARTEXT Convert one string scalar or character vector to char.
% rawValue is the text to normalize, displayName identifies it in errors,
% and value is the resulting character row vector.

% Accept one MATLAB string and convert it to the text type used by file functions.
if isstring(rawValue) && isscalar(rawValue)
    value = char(rawValue);
    return;
end

% Accept an ordinary character row vector without changing it.
if ischar(rawValue) && isrow(rawValue)
    value = rawValue;
    return;
end

% Reject arrays because each configuration field represents one value.
error('createBonePoseOptimizationConfig:InvalidText', ...
    '%s must be a character vector or string scalar.', displayName);
end


function absolutePath = makeAbsolutePath(inputPath, baseFolder)
%MAKEABSOLUTEPATH Resolve a relative path against a known base folder.
% inputPath is the configured path, baseFolder anchors relative paths, and
% absolutePath is the normalized absolute result.

% Normalize the configured path before checking whether it is already absolute.
inputPath = char(inputPath);
if isAbsolutePath(inputPath)
    absolutePath = char(java.io.File(inputPath).getCanonicalPath());
else
    absolutePath = char(java.io.File(fullfile(baseFolder, inputPath)).getCanonicalPath());
end
end


function isAbsolute = isAbsolutePath(inputPath)
%ISABSOLUTEPATH Check whether a path is absolute on Windows or Unix.
% inputPath is one character path and isAbsolute reports the result.

% Recognize drive paths, UNC paths, and Unix root paths used by MATLAB.
isDrivePath = numel(inputPath) >= 3 && isstrprop(inputPath(1), 'alpha') && ...
    inputPath(2) == ':' && any(inputPath(3) == ['\' '/']);
isUncPath = startsWith(inputPath, '\\');
isUnixPath = startsWith(inputPath, '/');
isAbsolute = isDrivePath || isUncPath || isUnixPath;
end
