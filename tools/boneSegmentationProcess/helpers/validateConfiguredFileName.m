function validateConfiguredFileName( ...
        fileName, fieldLabel, expectedExtension, errorNamespace)
%VALIDATECONFIGUREDFILENAME Validate a filename separated from its directory.
% This shared helper enforces the common filename layout and expected file
% type used by the extraction and recovery configuration readers.
%
% Inputs:
%   fileName          - Configured filename without a parent directory.
%   fieldLabel        - User-facing JSON field path used in error messages.
%   expectedExtension - Required filename extension, including the period.
%   errorNamespace    - Calling script's error-identifier namespace.
%
% Output:
%   This function has no output; it throws a named error for invalid input.

% FILEPARTS returns a nonempty parent when a filename field incorrectly
% contains directory components.
[fileParent, ~, fileExtension] = fileparts(fileName);
if ~isempty(fileParent)
    error([errorNamespace ':InvalidConfiguredFileName'], ...
          ['Configuration field "%s" must contain a filename only, ' ...
           'without a directory.'], fieldLabel);
end

% Check the extension before any specialized loader sees the configured file.
if ~strcmpi(fileExtension, expectedExtension)
    error([errorNamespace ':InvalidConfiguredFileExtension'], ...
          'Configuration field "%s" must identify a %s file.', ...
          fieldLabel, expectedExtension);
end
end
