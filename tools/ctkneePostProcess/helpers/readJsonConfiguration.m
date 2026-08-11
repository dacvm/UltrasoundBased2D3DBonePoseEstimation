function configuration = readJsonConfiguration(configuration_path)
% readJsonConfiguration Read and validate the tool's JSON configuration.
%
% This helper keeps file and JSON validation outside the main processing
% script so configuration errors are reported before mesh processing starts.
%
% Inputs:
%   configuration_path - Path to the JSON configuration file.
%
% Outputs:
%   configuration - Decoded scalar configuration structure.

    % Check the path first so a missing configuration is distinguished from
    % invalid JSON content.
    if ~isfile(configuration_path)
        error('preprocess_markerstls:ConfigurationNotFound', ...
            'Configuration file not found: %s', configuration_path);
    end

    % Keep JSON parsing inside a try block so syntax errors include both the
    % configuration path and MATLAB's parser explanation.
    try
        configuration_text = fileread(configuration_path);
        configuration = jsondecode(configuration_text);
    catch configuration_error
        error('preprocess_markerstls:InvalidConfigurationJson', ...
            'Could not read configuration JSON "%s". Reason: %s', ...
            configuration_path, configuration_error.message);
    end

    % Require one top-level object because all later helpers expect named
    % configuration sections on a scalar structure.
    if ~isstruct(configuration) || ~isscalar(configuration)
        error('preprocess_markerstls:InvalidConfigurationRoot', ...
            'Configuration JSON must contain one object at its top level: %s', ...
            configuration_path);
    end
end
