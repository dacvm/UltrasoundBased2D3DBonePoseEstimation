function isAbsolute = isAbsolutePath(pathValue)
%ISABSOLUTEPATH Identify absolute Windows, UNC, and Unix-style paths.
% This helper is needed so relative configuration paths can be anchored
% beside the JSON file without changing paths that are already absolute.
%
% Input:
%   pathValue - Path stored as a character vector.
%
% Output:
%   isAbsolute - Logical true when pathValue is an absolute path.

% Windows accepts drive-rooted, UNC, and separator-rooted paths. Other
% platforms use a leading forward slash.
if ispc
    hasDriveRoot = ~isempty(regexp( ...
        pathValue, '^[A-Za-z]:[\\/]', 'once'));
    hasSeparatorRoot = startsWith(pathValue, filesep) ...
        || startsWith(pathValue, '/');
    isAbsolute = hasDriveRoot || hasSeparatorRoot;
else
    isAbsolute = startsWith(pathValue, '/');
end
end
