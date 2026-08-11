function configuration = readBoneSegmentationConfiguration(configurationFilePath)
%READBONESEGMENTATIONCONFIGURATION Load and validate segmentation settings.
% This function reads dataset-specific paths from JSON so the segmentation
% script stays unchanged when a different ultrasound file is selected.
%
% Input:
%   configurationFilePath - Path to the JSON configuration file.
%
% Output:
%   configuration - Scalar structure containing validated absolute input
%                   and output paths plus the ultrasound MAT-file name.

% Pass the owning script namespace into shared validators so their error
% identifiers remain compatible with the original local helpers.
errorNamespace = 'boneSegmentation_semiAutomatic';

% Report a missing configuration separately from malformed JSON because the
% two problems require different corrections from the user.
if ~isfile(configurationFilePath)
    error('boneSegmentation_semiAutomatic:ConfigurationNotFound', ...
          'Configuration file was not found: %s', configurationFilePath);
end

% Include the source path in parsing failures so the user knows exactly
% which file must be corrected.
try
    configurationText = fileread(configurationFilePath);
    rawConfiguration = jsondecode(configurationText);
catch configurationError
    error('boneSegmentation_semiAutomatic:InvalidConfigurationJson', ...
          'Could not read configuration JSON "%s". Reason: %s', ...
          configurationFilePath, configurationError.message);
end

% Require one JSON object because the remaining validation expects named
% input and output sections rather than an array of configurations.
if ~isstruct(rawConfiguration) || ~isscalar(rawConfiguration)
    error('boneSegmentation_semiAutomatic:InvalidConfigurationRoot', ...
          'Configuration JSON must contain one object at its top level: %s', ...
          configurationFilePath);
end

% Validate the two sections before reading their nested settings. This gives
% a direct error when a section name is missing or has the wrong JSON type.
inputConfiguration = requireConfigurationObject( ...
    rawConfiguration, 'input', 'input', errorNamespace);
outputConfiguration = requireConfigurationObject( ...
    rawConfiguration, 'output', 'output', errorNamespace);

% Read nonempty text first so path errors can name the exact JSON field that
% supplied the invalid value.
ultrasoundImageFilePathSetting = requireConfigurationText( ...
    inputConfiguration, 'ultrasoundImageFilePath', ...
    'input.ultrasoundImageFilePath', errorNamespace);
ultrasoundImageFileName = requireConfigurationText( ...
    inputConfiguration, 'ultrasoundImageFileName', ...
    'input.ultrasoundImageFileName', errorNamespace);
segmentationOutputPathSetting = requireConfigurationText( ...
    outputConfiguration, 'segmentationOutputPath', ...
    'output.segmentationOutputPath', errorNamespace);

% A separate configured filename must not contain a parent path. Keeping the
% directory and filename roles distinct prevents FULLFILE from ignoring or
% unexpectedly extending the configured input directory.
[fileParent, ~, fileExtension] = fileparts(ultrasoundImageFileName);
if ~isempty(fileParent)
    error('boneSegmentation_semiAutomatic:InvalidUltrasoundFileName', ...
          ['Configuration field "input.ultrasoundImageFileName" must ' ...
           'contain a filename only, without a directory.']);
end
if ~strcmpi(fileExtension, '.mat')
    error('boneSegmentation_semiAutomatic:InvalidUltrasoundFileExtension', ...
          ['Configuration field "input.ultrasoundImageFileName" must ' ...
           'identify a MAT-file.']);
end

% Resolve relative paths beside the JSON file so running MATLAB from another
% current folder does not change which input and output folders are used.
configurationDirectory = fileparts(configurationFilePath);
ultrasoundImageFilePath = resolveConfiguredDirectory( ...
    ultrasoundImageFilePathSetting, configurationDirectory, ...
    'input.ultrasoundImageFilePath', false, errorNamespace);
segmentationOutputPath = resolveConfiguredDirectory( ...
    segmentationOutputPathSetting, configurationDirectory, ...
    'output.segmentationOutputPath', true, errorNamespace);

% Check the combined input after validating its two parts so a missing file
% produces an error that displays the complete resolved path.
ultrasoundImageFullPath = fullfile( ...
    ultrasoundImageFilePath, ultrasoundImageFileName);
if ~isfile(ultrasoundImageFullPath)
    error('boneSegmentation_semiAutomatic:UltrasoundFileNotFound', ...
          'Configured ultrasound image file was not found: %s', ...
          ultrasoundImageFullPath);
end

% Return the same input/output hierarchy used by the JSON file, but with its
% directory settings normalized to absolute paths for the main workflow.
configuration = struct();
configuration.input = struct( ...
    'ultrasoundImageFilePath', ultrasoundImageFilePath, ...
    'ultrasoundImageFileName', ultrasoundImageFileName);
configuration.output = struct( ...
    'segmentationOutputPath', segmentationOutputPath);
end
