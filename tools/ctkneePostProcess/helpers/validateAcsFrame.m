function validateAcsFrame(acs_frame, frame_label, acs_mat_path)
% validateAcsFrame Check one row-wise rotation matrix and origin vector.
%
% This helper validates the ACS frame shape and finite numeric values while
% allowing small measured deviations from perfect orthonormality.
%
% Inputs:
%   acs_frame   - Scalar ACS frame structure to validate.
%   frame_label - Human-readable frame path used in error messages.
%   acs_mat_path - Source MAT-file path used in error messages.
%
% Outputs:
%   None.

    % Require the two fields used by all downstream pose calculations.
    if ~isfield(acs_frame, 'R') || ~isfield(acs_frame, 'origin')
        error('preprocess_markerstls:MissingAcsField', ...
            'ACS frame "%s" must contain fields R and origin in: %s', ...
            frame_label, acs_mat_path);
    end

    % Read the measured frame values once so shape and finite-value checks are
    % easy to follow and produce no repeated dynamic field access.
    current_rotation = acs_frame.R;
    current_origin = acs_frame.origin;

    % Only the shape and numerical validity are enforced because measured ACS
    % rotations can contain small deviations from perfect orthonormality.
    if ~isnumeric(current_rotation) ...
            || ~isreal(current_rotation) ...
            || ~isequal(size(current_rotation), [3 3]) ...
            || any(~isfinite(current_rotation), 'all')
        error('preprocess_markerstls:InvalidAcsRotation', ...
            'ACS field "%s.R" must be a finite real 3-by-3 numeric matrix.', ...
            frame_label);
    end

    % Accept either row or column origins because only their three finite
    % numeric values are needed by the pose-processing code.
    if ~isnumeric(current_origin) ...
            || ~isreal(current_origin) ...
            || numel(current_origin) ~= 3 ...
            || any(~isfinite(current_origin), 'all')
        error('preprocess_markerstls:InvalidAcsOrigin', ...
            'ACS field "%s.origin" must contain three finite real numeric values.', ...
            frame_label);
    end
end
