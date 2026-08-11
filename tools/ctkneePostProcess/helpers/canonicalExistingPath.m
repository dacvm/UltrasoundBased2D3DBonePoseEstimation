function canonical_path = canonicalExistingPath(candidate_path, field_label)
% canonicalExistingPath Return MATLAB's normalized full path for provenance.
%
% This helper centralizes fileattrib-based path normalization so every input
% and output path saved by the workflow has the same canonical form.
%
% Inputs:
%   candidate_path - Existing file or directory path to normalize.
%   field_label    - Human-readable field path used in error messages.
%
% Outputs:
%   canonical_path - MATLAB's normalized absolute path.

    % Ask MATLAB to resolve the existing path and report a clear configuration
    % error if the path cannot be canonicalized.
    [path_found, path_attributes] = fileattrib(candidate_path);
    if ~path_found
        error('preprocess_markerstls:PathResolutionFailed', ...
            'Could not resolve configured path "%s": %s', ...
            field_label, candidate_path);
    end
    canonical_path = path_attributes.Name;
end
