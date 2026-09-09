function configuration = readPoseModeProcessConfiguration(configurationPath)
%READPOSEMODEPROCESSCONFIGURATION Read static/kinematic preparation settings.
% This function validates the separate development configuration without
% changing the configuration contract of the working snapshot workflow.
%
% Input:
%   configurationPath - Path to the JSON configuration file.
%
% Output:
%   configuration - Scalar struct containing resolved input paths, selected
%                   pins, required rigid-body names, and bone-pose mode.

% Report a missing file separately from malformed JSON so the user knows
% whether to correct the path or the contents.
if ~isfile(configurationPath)
    error('build_ultrasoundBone_intersectionData_poseModes:ConfigurationNotFound', ...
        'Configuration file not found: %s', configurationPath);
end

try
    rawConfiguration = jsondecode(fileread(configurationPath));
catch configurationError
    error('build_ultrasoundBone_intersectionData_poseModes:InvalidConfigurationJson', ...
        'Could not read configuration JSON "%s". Reason: %s', ...
        configurationPath, configurationError.message);
end

if ~isstruct(rawConfiguration) || ~isscalar(rawConfiguration)
    error('build_ultrasoundBone_intersectionData_poseModes:InvalidConfigurationRoot', ...
        'Configuration JSON must contain one object at its top level.');
end

configurationDirectory = fileparts(configurationPath);

% Resolve relative paths from the configuration directory, matching the
% behavior of the established snapshot workflow.
configuration.acquisitionDirectory = resolveConfiguredInputPath( ...
    requireConfigurationText(rawConfiguration, ...
        'acquisitionDirectory', 'acquisitionDirectory'), ...
    configurationDirectory, 'acquisitionDirectory', 'directory', '');
configuration.fcalConfigFile = resolveConfiguredInputPath( ...
    requireConfigurationText(rawConfiguration, ...
        'fcalConfigFile', 'fcalConfigFile'), ...
    configurationDirectory, 'fcalConfigFile', 'file', '.xml');
configuration.ctPostProcessedMatFile = resolveConfiguredInputPath( ...
    requireConfigurationText(rawConfiguration, ...
        'ctPostProcessedMatFile', 'ctPostProcessedMatFile'), ...
    configurationDirectory, 'ctPostProcessedMatFile', 'file', '.mat');

% Normalize the selected pin places before building their Qualisys names.
rawPinSelection = requireConfigurationObject( ...
    rawConfiguration, 'pinSelection', 'pinSelection');
configuration.pinSelection = struct( ...
    'F', normalizePinPlace(requireConfigurationText( ...
        rawPinSelection, 'F', 'pinSelection.F'), 'F', 'pinSelection.F'), ...
    'T', normalizePinPlace(requireConfigurationText( ...
        rawPinSelection, 'T', 'pinSelection.T'), 'T', 'pinSelection.T'));

% One mode is enough to describe the acquisition policy: perDataRow means
% kinematic, while the three reducing modes describe static snapshots.
requestedMode = lower(requireConfigurationText( ...
    rawConfiguration, 'bonePoseMode', 'bonePoseMode'));
validModes = {'average', 'first', 'last', 'perdatarow'};
if ~ismember(requestedMode, validModes)
    error('build_ultrasoundBone_intersectionData_poseModes:InvalidBonePoseMode', ...
        'bonePoseMode must be "average", "first", "last", or "perDataRow".');
end
if strcmp(requestedMode, 'perdatarow')
    configuration.bonePoseMode = "perDataRow";
    configuration.processingMode = "kinematic";
else
    configuration.bonePoseMode = string(requestedMode);
    configuration.processingMode = "static";
end

% Registration always needs the reference and the selected pin for each bone.
configuration.requiredRigidBodyNames = { ...
    'B_N_REF', ...
    sprintf('C_F_%s', configuration.pinSelection.F), ...
    sprintf('C_T_%s', configuration.pinSelection.T)};
end
