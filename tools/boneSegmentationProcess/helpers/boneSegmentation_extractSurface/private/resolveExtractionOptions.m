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

% Walk from this private folder to the owning bone-segmentation tool. Keeping
% the default JSON beside the tool makes the algorithm and its configuration
% move together instead of depending on the project-wide functions folder.
privateHelperDirectory = fileparts(mfilename('fullpath'));
surfaceExtractionHelperDirectory = fileparts(privateHelperDirectory);
sharedHelperDirectory = fileparts(surfaceExtractionHelperDirectory);
extractionToolDirectory = fileparts(sharedHelperDirectory);
configurationPath = fullfile(extractionToolDirectory, 'configs', ...
    'boneSurfaceExtraction.json');

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

% Merge at every hierarchy level so a caller may override one leaf without
% copying all sibling defaults from the same algorithm group.
resolvedOptions = mergeExtractionOptionStructs( ...
    defaultOptions, options, '');

resolvedOptions = validateExtractionOptions(resolvedOptions);
end

function mergedOptions = mergeExtractionOptionStructs( ...
        defaultOptions, overrideOptions, parentPath)
%MERGEEXTRACTIONOPTIONSTRUCTS Apply validated overrides recursively.
% This helper keeps unspecified JSON defaults while rejecting misspelled group
% or parameter names. It is needed because replacing a whole nested group
% would otherwise discard defaults for every sibling parameter.
%
% Inputs:
%   defaultOptions  : Scalar struct containing defaults at the current level.
%   overrideOptions : Scalar struct containing caller values at this level.
%   parentPath      : Dot-separated parent path used in clear error messages.
%
% Output:
%   mergedOptions   : Scalar struct with the requested leaf overrides applied.

mergedOptions = defaultOptions;
overrideFieldNames = fieldnames(overrideOptions);

for fieldIndex = 1:numel(overrideFieldNames)
    currentField = overrideFieldNames{fieldIndex};

    % Include the full hierarchy in errors so similarly named settings are
    % easy to locate in the JSON file.
    if isempty(parentPath)
        currentPath = currentField;
    else
        currentPath = [parentPath, '.', currentField];
    end

    if ~isfield(defaultOptions, currentField)
        error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
            'Unknown extraction option: %s', currentPath);
    end

    defaultValue = defaultOptions.(currentField);
    overrideValue = overrideOptions.(currentField);
    if isstruct(defaultValue)
        % Configuration groups must stay scalar structs so their required
        % child settings remain addressable and unambiguous.
        if ~isstruct(overrideValue) || ~isscalar(overrideValue)
            error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
                '%s must be a scalar struct.', currentPath);
        end
        mergedOptions.(currentField) = mergeExtractionOptionStructs( ...
            defaultValue, overrideValue, currentPath);
    else
        mergedOptions.(currentField) = overrideValue;
    end
end
end
