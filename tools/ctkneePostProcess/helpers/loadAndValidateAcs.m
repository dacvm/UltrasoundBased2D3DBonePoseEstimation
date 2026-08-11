function acs = loadAndValidateAcs(acs_mat_path)
% loadAndValidateAcs Read and validate the fixed femur/tibia ACS contract.
%
% This helper loads only the expected ACS variable and validates both required
% bone frames before the main script starts mesh processing.
%
% Inputs:
%   acs_mat_path - Path to the MAT file containing the ACS structure.
%
% Outputs:
%   acs - Validated scalar ACS structure containing femur and tibia frames.

    % Load only acs so unrelated variables in the MAT file cannot silently
    % appear in the script workspace.
    loaded_acs = load(acs_mat_path, 'acs');
    if ~isfield(loaded_acs, 'acs')
        error('preprocess_markerstls:MissingAcsVariable', ...
            'ACS MAT file does not contain the expected "acs" variable: %s', ...
            acs_mat_path);
    end

    % Require one ACS structure before accessing its femur and tibia fields.
    acs = loaded_acs.acs;
    if ~isstruct(acs) || ~isscalar(acs)
        error('preprocess_markerstls:InvalidAcsVariable', ...
            'Variable "acs" must be one struct in MAT file: %s', acs_mat_path);
    end

    % Validate both named frames so downstream transforms can rely on the
    % same shape and numerical-value contract.
    femur_acs = requireStructField(acs, 'f', 'acs.f');
    tibia_acs = requireStructField(acs, 't', 'acs.t');
    validateAcsFrame(femur_acs, 'acs.f', acs_mat_path);
    validateAcsFrame(tibia_acs, 'acs.t', acs_mat_path);
end
