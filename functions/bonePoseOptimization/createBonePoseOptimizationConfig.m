function config = createBonePoseOptimizationConfig(configFilePath)
%CREATEBONEPOSEOPTIMIZATIONCONFIG Create settings for the bone-pose optimization pipeline.
% This function declaration loads user-editable settings from a hierarchical JSON file.
%
% What this function does:
%   This function reads the external JSON configuration file and converts it
%   into a MATLAB struct named config. The JSON file is meant to be edited
%   by the user, so experiment settings can change without editing MATLAB
%   source code.
%
% Why this function exists:
%   The bone-pose optimization pipeline needs many settings: where the
%   project lives, which ultrasound recordings to load, which STL mesh to
%   use, how densely to sample image planes, and which intersection options
%   to apply. Keeping those settings in one JSON file makes experiments
%   easier to repeat and easier to debug.
%
% Input:
%   configFilePath:
%       Optional path to a JSON configuration file. If this is empty or not
%       provided, the function uses config/bonePoseOptimizationConfig.json
%       inside the current project folder.
%
% Output:
%   config:
%       A nested MATLAB struct that follows the same category layout as the
%       JSON file. For example:
%           config.project.root
%           config.input.sequenceFilenames
%           config.imagePlaneSampling.packetStep
%           config.smoothing.method
%           config.intersection.normalFacingToleranceDeg
%           config.logging.printPreparationProgress
%
% Important details:
%   - JSON null becomes [] in MATLAB. This is useful for packetEndIndex,
%     where [] means "use the last packet from each sequence".
%   - Relative paths are resolved from the JSON file location, not from a
%     random current folder. This makes the config file more portable.
%   - sequenceFilenames is converted to a cell array of char vectors because
%     the rest of the MATLAB code uses curly-brace indexing, such as
%     config.input.sequenceFilenames{index_filename}.

%% SELECT CONFIGURATION FILE

% Use the default project configuration file when the caller does not provide a custom file.
if nargin < 1 || isempty(configFilePath)
    configFilePath = fullfile(pwd, 'config', 'bonePoseOptimizationConfig.json');
end

% Convert the configuration file path to an absolute path so later relative paths have a stable base.
configFilePath = makeAbsolutePath(configFilePath, pwd);

% Stop early with a clear message when the configuration file cannot be found.
if ~isfile(configFilePath)
    error('createBonePoseOptimizationConfig:MissingConfigFile', ...
        'Configuration file was not found: %s', configFilePath);
end

%% PARSE JSON CONFIGURATION

% Read the entire JSON file as text because jsondecode expects one character vector.
configText = fileread(configFilePath);
% Decode the JSON text into a nested MATLAB struct that mirrors the file hierarchy.
rawConfig = jsondecode(configText);
% Store the folder containing the JSON file so relative paths can be resolved from the file location.
configFolder = fileparts(configFilePath);

%% PROJECT PATHS

% Read the project root from the JSON file so users can move the config without editing MATLAB code.
projectRootRaw = getRequiredField(rawConfig.project, 'root', 'project.root');

% Resolve the project root relative to the configuration file folder when it is not already absolute.
config.project.root = makeAbsolutePath(projectRootRaw, configFolder);

% Read the helper folder name from JSON so projects can rename the helper folder if needed.
functionsFolderName = getRequiredField(rawConfig.project, 'functionsFolderName', 'project.functionsFolderName');

% Store the helper folder as an absolute path so callers can add paths consistently.
config.project.functionsFolder = makeAbsolutePath(functionsFolderName, config.project.root);

%% INPUT FILENAMES

% Store the fCal XML filename used to load the Image-to-Probe calibration transform.
config.input.fcalFilename = getRequiredField(rawConfig.input, 'fcalFilename', 'input.fcalFilename');

% Store the folder that contains the ultrasound sequence recordings used by the current validation script.
config.input.sequenceFolder = makeAbsolutePath(getRequiredField(rawConfig.input, 'sequenceFolder', 'input.sequenceFolder'), config.project.root);

% Store the sequence filenames as a cell array so later code can loop over them with normal MATLAB indexing.
config.input.sequenceFilenames = ensureCellString(getRequiredField(rawConfig.input, 'sequenceFilenames', 'input.sequenceFilenames'));

% Store the ACS MAT filename used to build the original femur coordinate transform.
config.input.acsFilename = getRequiredField(rawConfig.input, 'acsFilename', 'input.acsFilename');

% Store the manual adjustment MAT filename used as the initial mesh pose for optimization.
config.input.manualAdjustmentFilename = getRequiredField(rawConfig.input, 'manualAdjustmentFilename', 'input.manualAdjustmentFilename');

% Store the STL filename used as the femur mesh geometry.
config.input.stlFilename = getRequiredField(rawConfig.input, 'stlFilename', 'input.stlFilename');

%% IMAGE-PLANE SAMPLING OPTIONS

% Store the first sampled packet index used to collect image planes.
config.imagePlaneSampling.packetStartIndex = getRequiredField(rawConfig.imagePlaneSampling, 'packetStartIndex', 'imagePlaneSampling.packetStartIndex');

% Store the packet step size used to thin the image-plane collection.
config.imagePlaneSampling.packetStep = getRequiredField(rawConfig.imagePlaneSampling, 'packetStep', 'imagePlaneSampling.packetStep');

% Store the optional final packet index, where JSON null becomes [] for "use sequence end".
config.imagePlaneSampling.packetEndIndex = getRequiredField(rawConfig.imagePlaneSampling, 'packetEndIndex', 'imagePlaneSampling.packetEndIndex');

%% SMOOTHING OPTIONS

% Store the transform smoothing method used before image-plane construction.
config.smoothing.method = getRequiredField(rawConfig.smoothing, 'method', 'smoothing.method');

% Store the smoothing window used before image-plane construction.
config.smoothing.window = getRequiredField(rawConfig.smoothing, 'window', 'smoothing.window');

%% INTERSECTION OPTIONS

% Store the maximum angle for keeping probe-facing mesh intersections.
config.intersection.normalFacingToleranceDeg = getRequiredField(rawConfig.intersection, 'normalFacingToleranceDeg', 'intersection.normalFacingToleranceDeg');

%% LOGGING OPTIONS

% Store whether slow preparation steps should print progress messages.
config.logging.printPreparationProgress = getRequiredField(rawConfig.logging, 'printPreparationProgress', 'logging.printPreparationProgress');

% Store whether repeated per-plane geometry evaluation should print progress messages.
config.logging.printEvaluationProgress = getRequiredField(rawConfig.logging, 'printEvaluationProgress', 'logging.printEvaluationProgress');

%% BOOKKEEPING

% Store the loaded JSON file path so results can be traced back to the configuration source.
config.source.configFilePath = configFilePath;
end

function value = getRequiredField(sourceStruct, fieldName, displayName)
%GETREQUIREDFIELD Read a required field and report a clear config path when it is missing.
% This local function keeps the parser messages helpful for users editing the JSON file.

% Stop early if a required configuration group or field is missing.
if ~isstruct(sourceStruct) || ~isfield(sourceStruct, fieldName)
    error('createBonePoseOptimizationConfig:MissingField', ...
        'Missing required configuration field: %s', displayName);
end

% Return the requested value so the caller can assign it into the flat config struct.
value = sourceStruct.(fieldName);
end

function absolutePath = makeAbsolutePath(inputPath, baseFolder)
%MAKEABSOLUTEPATH Resolve a path against a base folder when it is relative.
% This local function lets the JSON file use short relative paths without depending on the current folder.

% Convert MATLAB string values to character vectors for file path functions.
inputPath = char(inputPath);

% Leave Windows absolute paths and UNC paths unchanged.
if isAbsolutePath(inputPath)
    absolutePath = char(java.io.File(inputPath).getCanonicalPath());
else
    % Resolve relative paths against the provided base folder and normalize any ".." pieces.
    absolutePath = char(java.io.File(fullfile(baseFolder, inputPath)).getCanonicalPath());
end
end

function isAbsolute = isAbsolutePath(inputPath)
%ISABSOLUTEPATH Detect whether a path is already absolute on Windows or Unix-like systems.
% This local function avoids assuming that every project will run from the same drive or operating system.

% Match Windows drive paths like C:\folder and Unix paths like /home/user.
isDrivePath = numel(inputPath) >= 3 && isstrprop(inputPath(1), 'alpha') && inputPath(2) == ':' && any(inputPath(3) == ['\' '/']);

% Match UNC network paths like \\server\share.
isUncPath = startsWith(inputPath, '\\');

% Match Unix-like absolute paths.
isUnixPath = startsWith(inputPath, '/');

% Combine all supported absolute path forms into one logical flag.
isAbsolute = isDrivePath || isUncPath || isUnixPath;
end

function values = ensureCellString(rawValues)
%ENSURECELLSTRING Convert JSON string arrays into a MATLAB cell array of character vectors.
% This local function keeps sequenceFilenames compatible with existing curly-brace indexing.

% Convert an already decoded cell array into a row cell array of character vectors.
if iscell(rawValues)
    values = cellfun(@char, rawValues(:).', 'UniformOutput', false);
    return;
end

% Convert MATLAB string arrays into a row cell array of character vectors.
if isstring(rawValues)
    values = cellstr(rawValues(:).');
    return;
end

% Convert a single character vector into a one-element cell array.
if ischar(rawValues)
    values = {rawValues};
    return;
end

% Stop early because the sequence file list must be text-based.
error('createBonePoseOptimizationConfig:InvalidStringList', ...
    'input.sequenceFilenames must be a string array or cell array of strings.');
end
