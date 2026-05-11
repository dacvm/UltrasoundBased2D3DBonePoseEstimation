function optimizationResult = runBonePoseOptimization(initialPoseVector, data, config, initialCost)
%RUNBONEPOSEOPTIMIZATION Optimize the bone pose with bounded CMA-ES.
% This function declaration is the optimizer wrapper used by the main script.
%
% What this function does:
%   This function receives the starting SE(3) perturbation vector, prepares a
%   small bounded CMA-ES search around the manual pose, runs cmaes_parfor on
%   bonePoseCostFunction, and packages the best result for visualization.
%
% Why this function exists:
%   The main script should stay readable and should not need to know CMA-ES
%   file-output details, bounds, sigma values, or result fields. Keeping the
%   optimizer orchestration here also keeps bonePoseCostFunction focused on
%   scoring one candidate pose.

%% HANDLE OPTIONAL INPUTS

% Use the configuration stored with the prepared data when the caller does not pass one explicitly.
if nargin < 3 || isempty(config)
    config = data.config;
end

% Check the starting vector before CMA-ES uses it as the center of the search.
validateattributes(initialPoseVector, {'numeric'}, {'vector', 'numel', 6, 'finite'}, mfilename, 'initialPoseVector');

% Force row or column input into the column-vector convention used by the SE(3) helpers.
initialPoseVector = initialPoseVector(:);

% Evaluate the initial pose only when the caller has not already computed it.
if nargin < 4 || isempty(initialCost)
    initialCost = bonePoseCostFunction(initialPoseVector, data, config);
end

%% BUILD CMA-ES SEARCH SETTINGS

% Read CMA-ES settings from config while keeping safe defaults for older config files.
cmaesSettings = getCMAESSettings(config);

% Convert the human-readable translation and rotation bounds into 6-by-1 optimizer vectors.
[lowerBounds, upperBounds, sigma] = buildPoseSearchVectors(cmaesSettings);

% Create a unique output folder so each optimization run keeps its logs separate.
runFolder        = createUniqueRunFolder(cmaesSettings.outputFolder);
% Create the progress MAT file expected by this external cmaes_parfor implementation.
progressFilePath = initializeCMAESProgressFile(runFolder);
% Resolve the project functions folder before changing folders for the CMA-ES run.
functionsFolder  = getFunctionsFolder(config);
% Store the current MATLAB folder so the wrapper can restore it after CMA-ES finishes or errors.
originalFolder   = pwd;
% Store the current MATLAB path so the wrapper does not leave path changes behind after it returns.
originalPath     = path;
% Restore the caller's folder and path even if CMA-ES stops with an error.
cleanupState     = onCleanup(@() restoreFolderAndPath(originalFolder, originalPath));

% Add the absolute helper folder so cmaes_parfor can still find project functions after cd(runFolder).
addpath(genpath(functionsFolder));

% Move into the output run folder because cmaes_parfor uses pwd for one hard-coded progress path.
cd(runFolder);

% Build the CMA-ES options after the output folder exists because logging now happens inside that folder.
opts = buildCMAESOptions(cmaesSettings, lowerBounds, upperBounds);

%% RUN CMA-ES

% Print the bounded search setup so long runs start with visible optimizer context.
fprintf('Running CMA-ES bone-pose optimization in %s\n', runFolder);

% Print the translation and rotation bounds in user-friendly units.
fprintf('State bounds: translation +/- %.3f mm, rotation +/- %.3f deg\n', ...
        cmaesSettings.translationBoundMm, cmaesSettings.rotationBoundDeg);

% Call CMA-ES directly on bonePoseCostFunction; MATLAB returns only its first output to cmaes_parfor.
[xmin, fmin, counteval, stopflag, out, bestever] = cmaes_parfor( ...
    'bonePoseCostFunction', initialPoseVector, sigma, opts, data, config);

%% SELECT BEST RESULT

% Prefer CMA-ES best-ever output because it stores the best evaluated candidate across the full run.
if isstruct(bestever) && isfield(bestever, 'x') && isfield(bestever, 'f')
    bestPoseVector = bestever.x(:);
    bestCost       = bestever.f;
else
    % Fall back to xmin/fmin if a future CMA-ES variant does not return bestever as expected.
    bestPoseVector = xmin(:);
    bestCost       = fmin;
end

% Convert the optimized state vector back into the 4-by-4 mesh transform used by display helpers.
bestTransform = stateVectorToTMatrix(bestPoseVector, data.T_init_originct);

%% PACKAGE RESULT

% Store some necessry values
optimizationResult.initialPoseVector    = initialPoseVector;                % Initial vector so users can compare the optimized perturbation against the start.
optimizationResult.initialCost          = initialCost;                      % Initial cost so users can quickly check whether the optimizer improved the objective.
optimizationResult.bestPoseVector       = bestPoseVector;                   % Best bounded perturbation returned by CMA-ES.
optimizationResult.bestCost             = bestCost;                         % Best scalar objective value returned by CMA-ES.
optimizationResult.bestTransform        = bestTransform;                    % Best transform so downstream code does not need to recompute it for inspection.
optimizationResult.bounds.lower         = lowerBounds;                      % Lower bounds exactly as CMA-ES received them.
optimizationResult.bounds.upper         = upperBounds;                      % Upper bounds exactly as CMA-ES received them.
optimizationResult.bounds.translationMm = cmaesSettings.translationBoundMm; % Translation bound in millimeters for readable result inspection.
optimizationResult.bounds.rotationDeg   = cmaesSettings.rotationBoundDeg;   % Rotation bound in degrees for readable result inspection.
optimizationResult.sigma                = sigma;                            % Initial coordinate-wise standard deviations used by CMA-ES.
optimizationResult.cmaesOptions         = opts;                             % Full CMA-ES options struct so runs can be reproduced later.
optimizationResult.xmin                 = xmin;                             % CMA-ES raw outputs because they contain useful convergence and history information.
optimizationResult.fmin                 = fmin;                             % CMA-ES raw fmin output for comparison with the best-ever result.
optimizationResult.counteval            = counteval;                        % Number of objective evaluations reported by CMA-ES.
optimizationResult.stopflag             = stopflag;                         % CMA-ES stop reason so users know why the run ended.
optimizationResult.out                  = out;                              % Full CMA-ES output struct for detailed debugging.
optimizationResult.bestever             = bestever;                         % CMA-ES best-ever struct for direct inspection.
optimizationResult.runFolder            = runFolder;                        % Run folder so users can find variablescmaes.mat and log files.
optimizationResult.progressFilePath     = progressFilePath;                 % Hard-coded progress file path created for the external CMA-ES script.
optimizationResult.status               = 'cmaes_completed';                % Status string for scripts that check whether the real optimizer ran.
end

%% HELPER: READ CMA-ES SETTINGS FROM CONFIGURATION

function cmaesSettings = getCMAESSettings(config)
%GETCMAESSETTINGS Read CMA-ES settings while supporting older config structs.
%
% What this helper does:
%   This helper collects all CMA-ES settings into one simple struct. It
%   reads values such as the translation bound, rotation bound, sigma,
%   population size, maximum function evaluations, parfor settings, and the
%   output folder. If a setting is missing from the config, it fills in the
%   same default value used by the optimizer plan.
%
% Why this helper is necessary:
%   The main optimizer should not be full of repeated "if this field exists"
%   checks. Those checks are important because older config files may not
%   have an optimizer section yet, but keeping them here makes the main
%   runBonePoseOptimization flow easier to read.
%
% When this helper is called:
%   runBonePoseOptimization calls this helper near the start of the "BUILD
%   CMA-ES SEARCH SETTINGS" section, before it builds bounds, output
%   folders, or CMA-ES options.

% Use the optimizer section when it exists because new JSON configs store CMA-ES options there.
if isfield(config, 'optimizer') && isstruct(config.optimizer)
    optimizerConfig = config.optimizer;
else
    % Use an empty struct when older configs do not yet define optimizer settings.
    optimizerConfig = struct();
end

% Store the necessary values
cmaesSettings.translationBoundMm     = getOptionalSetting(optimizerConfig, 'translationBoundMm', 10);               % Default translation search radius in millimeters.
cmaesSettings.rotationBoundDeg       = getOptionalSetting(optimizerConfig, 'rotationBoundDeg', 10);                 % Default rotation search radius in degrees for readability.
cmaesSettings.translationSigmaMm     = getOptionalSetting(optimizerConfig, 'translationSigmaMm', 5);                % Default translation sigma in millimeters.
cmaesSettings.rotationSigmaDeg       = getOptionalSetting(optimizerConfig, 'rotationSigmaDeg', 5);                  % Default rotation sigma in degrees for readability.
cmaesSettings.populationSize         = getOptionalSetting(optimizerConfig, 'populationSize', 12);                   % Moderate first-run CMA-ES population size.
cmaesSettings.maxFunctionEvaluations = getOptionalSetting(optimizerConfig, 'maxFunctionEvaluations', 400);          % Moderate first-run function-evaluation budget.
cmaesSettings.useParfor              = logical(getOptionalSetting(optimizerConfig, 'useParfor', true));             % Whether the wrapper should use parfor when the Parallel Computing Toolbox is available.
cmaesSettings.parforWorkers          = getOptionalSetting(optimizerConfig, 'parforWorkers', 4);                     % Requested parfor worker cap used by the external CMA-ES implementation.

defaultOutputFolder                  = fullfile(config.project.root, 'output', 'bonePoseOptimization', 'cmaes');        % Build a default output folder under the project root when the config does not provide one.
cmaesSettings.outputFolder           = char(getOptionalSetting(optimizerConfig, 'outputFolder', defaultOutputFolder));  % Base folder where unique per-run CMA-ES output folders will be created.

end

%% HELPER: READ ONE OPTIONAL SETTING

function value = getOptionalSetting(sourceStruct, fieldName, defaultValue)
%GETOPTIONALSETTING Return a config value when present, otherwise return a default.
%
% What this helper does:
%   This helper reads one optional field from a config struct. If the field
%   exists and has a non-empty value, it returns that value. If the field is
%   missing or empty, it returns the default value passed by the caller.
%
% Why this helper is necessary:
%   Optional config values are useful because they let the project add new
%   settings without breaking older JSON files. This helper also avoids
%   repeating the same field-existence logic for every CMA-ES setting.
%
% When this helper is called:
%   getCMAESSettings calls this helper once for each optimizer setting that
%   may or may not be present in config.optimizer.

% Use the configured value only when the section exists, the field exists, and the field is not empty.
if isstruct(sourceStruct) && isfield(sourceStruct, fieldName) && ~isempty(sourceStruct.(fieldName))
    value = sourceStruct.(fieldName);
else
    % Use the default value when the config file does not define the optional setting.
    value = defaultValue;
end

end

%% HELPER: BUILD BOUNDS AND SIGMA VECTORS

function [lowerBounds, upperBounds, sigma] = buildPoseSearchVectors(cmaesSettings)
%BUILDPOSESEARCHVECTORS Convert readable CMA-ES settings into 6D vectors.
%
% What this helper does:
%   This helper turns the human-readable optimizer settings into the exact
%   vectors that CMA-ES needs. Translation values stay in millimeters.
%   Rotation values are entered in degrees for easier editing, then converted
%   to radians because the SE(3) state vector stores rotations in radians.
%
% Why this helper is necessary:
%   CMA-ES searches a 6-by-1 vector in the order [vx; vy; vz; wx; wy; wz].
%   The wrapper needs lower bounds, upper bounds, and sigma in that exact
%   order. Keeping the conversion here reduces the chance of mixing units or
%   putting values in the wrong vector slots.
%
% When this helper is called:
%   runBonePoseOptimization calls this helper after getCMAESSettings, before
%   it creates output folders or builds the final CMA-ES options struct.

% Validate the translation bound because it controls the maximum local position correction.
validateattributes(cmaesSettings.translationBoundMm, {'numeric'}, {'scalar', 'positive', 'finite'}, mfilename, 'translationBoundMm');
% Validate the rotation bound because it controls the maximum local angular correction.
validateattributes(cmaesSettings.rotationBoundDeg, {'numeric'}, {'scalar', 'positive', 'finite'}, mfilename, 'rotationBoundDeg');
% Validate the translation sigma because CMA-ES needs a positive search width.
validateattributes(cmaesSettings.translationSigmaMm, {'numeric'}, {'scalar', 'positive', 'finite'}, mfilename, 'translationSigmaMm');
% Validate the rotation sigma because CMA-ES needs a positive angular search width.
validateattributes(cmaesSettings.rotationSigmaDeg, {'numeric'}, {'scalar', 'positive', 'finite'}, mfilename, 'rotationSigmaDeg');


% Convert the rotation bound from degrees to radians because stateVectorToTMatrix expects radians.
rotationBoundRad = deg2rad(cmaesSettings.rotationBoundDeg);
% Convert the rotation sigma from degrees to radians because CMA-ES searches the same state vector units.
rotationSigmaRad = deg2rad(cmaesSettings.rotationSigmaDeg);

% Build the lower bound vector in the [vx; vy; vz; wx; wy; wz] order used by the project.
lowerBounds = [-cmaesSettings.translationBoundMm; ...
               -cmaesSettings.translationBoundMm; ...
               -cmaesSettings.translationBoundMm; ...
               -rotationBoundRad; ...
               -rotationBoundRad; ...
               -rotationBoundRad];

% Build the upper bound vector in the same [vx; vy; vz; wx; wy; wz] order.
upperBounds = [ cmaesSettings.translationBoundMm; ...
                cmaesSettings.translationBoundMm; ...
                cmaesSettings.translationBoundMm; ...
                rotationBoundRad; ...
                rotationBoundRad; ...
                rotationBoundRad];

% Build the coordinate-wise initial sigma vector in the same state-vector units.
sigma = [cmaesSettings.translationSigmaMm; ...
         cmaesSettings.translationSigmaMm; ...
         cmaesSettings.translationSigmaMm; ...
         rotationSigmaRad; ...
         rotationSigmaRad; ...
         rotationSigmaRad];
end

%% HELPER: CREATE A UNIQUE RUN FOLDER

function runFolder = createUniqueRunFolder(outputFolder)
%CREATEUNIQUERUNFOLDER Create one timestamped output folder for a CMA-ES run.
%
% What this helper does:
%   This helper creates the base CMA-ES output folder if needed, then creates
%   a timestamped subfolder for the current optimizer run. If two runs start
%   in the same second, it adds a small numeric suffix so the folder is still
%   unique.
%
% Why this helper is necessary:
%   CMA-ES writes log files and a variables MAT file. A unique folder keeps
%   each run's files together and prevents a new run from overwriting an old
%   run. This makes debugging and comparing optimizer runs much easier.
%
% When this helper is called:
%   runBonePoseOptimization calls this helper after it builds the bounds and
%   sigma vectors, before it initializes the CMA-ES progress file.

% Create the base CMA-ES output folder if it does not exist yet.
[baseFolderCreated, baseFolderMessage, baseFolderMessageId] = mkdir(outputFolder);

% Stop early with MATLAB's folder-creation message when the base folder cannot be created.
if ~baseFolderCreated
    error(baseFolderMessageId, 'Could not create CMA-ES output folder: %s', baseFolderMessage);
end

% Build a readable timestamp that can be used safely in a Windows folder name.
runStamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
% Build the first candidate run folder name from the timestamp.
runFolder = fullfile(outputFolder, ['run_' runStamp]);
% Start the collision counter at one so repeated runs in the same second can still be unique.
runIndex = 1;

% Add a numeric suffix only when the timestamped folder already exists.
while isfolder(runFolder)
    runIndex = runIndex + 1;
    runFolder = fullfile(outputFolder, sprintf('run_%s_%02d', runStamp, runIndex));
end

% Create the final unique run folder before CMA-ES starts writing logs.
[runFolderCreated, runFolderMessage, runFolderMessageId] = mkdir(runFolder);

% Stop early if MATLAB cannot create the unique run folder.
if ~runFolderCreated
    error(runFolderMessageId, 'Could not create CMA-ES run folder: %s', runFolderMessage);
end
end

%% HELPER: INITIALIZE THE CMA-ES PROGRESS FILE

function progressFilePath = initializeCMAESProgressFile(runFolder)
%INITIALIZECMAESPROGRESSFILE Create the progress file expected by cmaes_parfor.
%
% What this helper does:
%   This helper creates an OptSaver.mat file inside the folder structure that
%   the external cmaes_parfor script expects. The MAT file starts with an
%   empty value history and a run counter set to one.
%
% Why this helper is necessary:
%   The external CMA-ES file has a hard-coded progress path based on the
%   current folder. We are not allowed to edit functions/external/CMAES, so
%   this helper prepares the folder and file that cmaes_parfor will try to
%   load. That lets the optimizer run without modifying external code.
%
% When this helper is called:
%   runBonePoseOptimization calls this helper right after createUniqueRunFolder,
%   before changing into the run folder and before calling cmaes_parfor.

% Recreate the hard-coded folder shape that cmaes_parfor loads from pwd.
progressFolder = fullfile(runFolder, 'functions', 'optimizers', 'CMAES', 'OptData');
% Create the progress folder before saving OptSaver.mat into it.
[progressFolderCreated, progressFolderMessage, progressFolderMessageId] = mkdir(progressFolder);

% Stop early if the progress folder cannot be created.
if ~progressFolderCreated
    error(progressFolderMessageId, 'Could not create CMA-ES progress folder: %s', progressFolderMessage);
end

% Initialize the external script's value history as empty because no evaluations have run yet.
val_list = [];
% Initialize the external script's run counter because cmaes_parfor saves it back to OptSaver.mat.
i_opts   = 1;
% Build the exact MAT-file path that the external cmaes_parfor progress code expects.
progressFilePath = fullfile(progressFolder, 'OptSaver.mat');

% Save the expected variables so the external CMA-ES progress code can load them without error.
save(progressFilePath, 'val_list', 'i_opts');
end

%% HELPER: RESOLVE THE PROJECT FUNCTIONS FOLDER

function functionsFolder = getFunctionsFolder(config)
%GETFUNCTIONSFOLDER Resolve the absolute project functions folder.
%
% What this helper does:
%   This helper finds the absolute path to the project's functions folder.
%   It first uses config.project.functionsFolder when available. If that
%   field is missing, it falls back to projectRoot/functions.
%
% Why this helper is necessary:
%   runBonePoseOptimization changes the current folder to the CMA-ES output
%   folder before running cmaes_parfor. After that folder change, relative
%   paths are no longer safe. This helper gives the wrapper an absolute
%   functions path that can be added to MATLAB's path before the folder
%   change.
%
% When this helper is called:
%   runBonePoseOptimization calls this helper before it stores the original
%   folder/path and before it changes into the CMA-ES run folder.

% Use the parsed absolute helper path when createBonePoseOptimizationConfig has provided it.
if isfield(config, 'project') && isfield(config.project, 'functionsFolder') && ~isempty(config.project.functionsFolder)
    functionsFolder = config.project.functionsFolder;
else
    % Fall back to projectRoot/functions for older config structs that only know the root folder.
    functionsFolder = fullfile(config.project.root, 'functions');
end

% Stop early with a clear message if the helper folder is missing.
if ~isfolder(functionsFolder)
    error('runBonePoseOptimization:MissingFunctionsFolder', ...
        'Project functions folder was not found: %s', functionsFolder);
end
end

%% HELPER: BUILD THE CMA-ES OPTIONS STRUCT

function opts = buildCMAESOptions(cmaesSettings, lowerBounds, upperBounds)
%BUILDCMAESOPTIONS Build the external CMA-ES option struct for this project.
%
% What this helper does:
%   This helper starts from the default cmaes_parfor options, then sets the
%   project-specific values: bounds, population size, function-evaluation
%   limit, restart behavior, parfor behavior, save filename, log prefix, and
%   display settings.
%
% Why this helper is necessary:
%   The external CMA-ES implementation has many options. Keeping option
%   setup in one helper makes it clear which options this project changes
%   and which options are left at the documented CMA-ES defaults.
%
% When this helper is called:
%   runBonePoseOptimization calls this helper after changing into the unique
%   run folder and just before it calls cmaes_parfor.

% Start from the external CMA-ES defaults so unspecified options keep their documented behavior.
opts = cmaes_parfor('defaults');

opts.LBounds            = lowerBounds;                              % Apply the local lower bounds that keep the Lie algebra perturbation small.
opts.UBounds            = upperBounds;                              % Apply the local upper bounds that keep the Lie algebra perturbation small.
opts.PopSize            = cmaesSettings.populationSize;             % Use the selected moderate population size for this 6D problem.
opts.MaxFunEvals        = cmaesSettings.maxFunctionEvaluations;     % Limit total objective calls so the first real optimizer stays practical.
opts.Restarts           = 0;                                        % Keep restarts off for the first bounded local-search implementation.
opts.EvalParallel       = 'no';                                     % Keep vectorized objective evaluation off because bonePoseCostFunction evaluates one pose at a time.
opts.ParforRun          = double(cmaesSettings.useParfor && hasParallelComputingToolbox()); % Use parfor only when requested and supported by the installed MATLAB toolboxes.
opts.ParforWorkers      = cmaesSettings.parforWorkers;              % Pass the configured worker cap to the external parfor loop.
opts.SaveVariables      = 'final';                                  % Save the final CMA-ES variables inside the per-run output folder.
opts.SaveFilename       = 'variablescmaes.mat';                     % Store the CMA-ES variable snapshot in the current run folder for later inspection.
opts.LogFilenamePrefix  = 'outcmaes';                               % Store CMA-ES log files in the current run folder next to the variable snapshot.
opts.LogModulo          = 1;                                        % Keep CMA-ES file logging enabled so the run can be inspected afterward.
opts.LogPlot            = 'off';                                    % Disable live plotting because optimization scripts should not create extra figures during long runs.
opts.DispModulo         = 1;                                        % Print regular CMA-ES progress so users can see that the optimizer is still running.

% Tell the user when parfor was requested but cannot be used in this MATLAB session.
if cmaesSettings.useParfor && opts.ParforRun == 0
    warning('runBonePoseOptimization:ParforUnavailable', ...
        'Parallel Computing Toolbox is unavailable, so CMA-ES will run serially.');
end
end

%% HELPER: CHECK WHETHER PARFOR CAN BE USED

function hasParallelToolbox = hasParallelComputingToolbox()
%HASPARALLELCOMPUTINGTOOLBOX Check whether parfor can be used.
%
% What this helper does:
%   This helper checks whether MATLAB can see the Parallel Computing Toolbox
%   and whether the current MATLAB session has a license for it.
%
% Why this helper is necessary:
%   The config can request parfor, but not every MATLAB installation can run
%   parfor. This helper lets the optimizer fall back to serial CMA-ES instead
%   of failing immediately on a computer without the toolbox or license.
%
% When this helper is called:
%   buildCMAESOptions calls this helper while setting opts.ParforRun.

% Check whether MATLAB can see the Parallel Computing Toolbox on the path.
hasToolbox = ~isempty(ver('parallel'));

% Ask the license manager only when the toolbox appears to be installed.
if hasToolbox
    hasLicense = license('test', 'Distrib_Computing_Toolbox');
else
    % Treat a missing toolbox as unavailable without calling the license manager.
    hasLicense = false;
end

% Use parfor only when both the toolbox files and license are available.
hasParallelToolbox = hasToolbox && hasLicense;
end

%% HELPER: RESTORE MATLAB FOLDER AND PATH

function restoreFolderAndPath(originalFolder, originalPath)
%RESTOREFOLDERANDPATH Return MATLAB to the caller's working state.
%
% What this helper does:
%   This helper changes MATLAB back to the folder that was active before the
%   optimizer started, and restores the MATLAB path to its previous value.
%
% Why this helper is necessary:
%   runBonePoseOptimization temporarily changes folder and adds absolute
%   helper paths so the external CMA-ES code can run from the output folder.
%   Without cleanup, later commands in the same MATLAB session might run from
%   the wrong folder or use a changed path.
%
% When this helper is called:
%   MATLAB calls this helper automatically through the onCleanup object when
%   runBonePoseOptimization finishes, even if CMA-ES throws an error.

% Restore the original current folder before returning to the caller.
cd(originalFolder);

% Restore the original MATLAB path so temporary absolute path additions do not linger.
path(originalPath);
end
