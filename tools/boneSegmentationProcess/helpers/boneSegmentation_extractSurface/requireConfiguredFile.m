function requireConfiguredFile(parentDirectory, fileName, fieldLabel)
%REQUIRECONFIGUREDFILE Check that one configured extraction input file exists.
% This script-specific helper combines a validated directory and filename and
% reports which extraction JSON fields selected a missing file.
%
% Inputs:
%   parentDirectory - Resolved absolute directory containing the input file.
%   fileName        - Validated filename to append to the parent directory.
%   fieldLabel      - User-facing description of the related JSON fields.
%
% Output:
%   This function has no output; it throws a named error when the file is absent.

% Check the complete path because validating the parent directory alone does
% not guarantee that it contains the requested input file.
candidateFile = fullfile(parentDirectory, fileName);
if ~isfile(candidateFile)
    error('boneSegmentation_extractSurface:ConfiguredInputFileNotFound', ...
          'Configured input from "%s" was not found: %s', ...
          fieldLabel, candidateFile);
end
end
