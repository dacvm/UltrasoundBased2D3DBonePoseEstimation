function resolvedOptions = resolveExtractionOptions(options)
%RESOLVEEXTRACTIONOPTIONS Load JSON defaults and apply caller overrides.
% The JSON file remains the visible source of default settings, while callers
% and tests may override selected values without editing that file.
%
% Input:
%   options         : Empty value or scalar struct containing option overrides.
%
% Output:
%   resolvedOptions : Validated scalar struct containing every required option.

% Walk from functions/boneSurfaceExtraction/helpers to the project root so
% moving this helper does not change where the tool-owned JSON file is stored.
helperDirectory = fileparts(mfilename('fullpath'));
projectDirectory = fileparts(fileparts(fileparts(helperDirectory)));
configurationPath = fullfile(projectDirectory, 'tools', ...
    'boneSegmentationProcess', 'configs', 'boneSurfaceExtraction.json');

if ~isfile(configurationPath)
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'Default configuration file was not found: %s', configurationPath);
end

try
    defaultOptions = jsondecode(fileread(configurationPath));
catch configurationError
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'Could not read the default configuration: %s', ...
        configurationError.message);
end

if isempty(options)
    options = struct();
end
if ~isstruct(options) || ~isscalar(options)
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'options must be an empty value or a scalar struct.');
end

% Reject unknown names because a misspelled parameter would otherwise appear
% to work while leaving the intended default unchanged.
defaultFieldNames = fieldnames(defaultOptions);
overrideFieldNames = fieldnames(options);
unknownFields = setdiff(overrideFieldNames, defaultFieldNames);
if ~isempty(unknownFields)
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'Unknown extraction option: %s', unknownFields{1});
end

resolvedOptions = defaultOptions;
for fieldIndex = 1:numel(overrideFieldNames)
    currentField = overrideFieldNames{fieldIndex};
    resolvedOptions.(currentField) = options.(currentField);
end

resolvedOptions = validateExtractionOptions(resolvedOptions);
end
