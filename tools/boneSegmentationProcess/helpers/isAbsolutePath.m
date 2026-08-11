function isAbsolute = isAbsolutePath(pathValue)
%ISABSOLUTEPATH Identify absolute Windows, UNC, and Unix-style paths.
% This shared helper keeps configured path resolution consistent across all
% three bone-segmentation workflows.
%
% Input:
%   pathValue - Directory path stored as a character vector.
%
% Output:
%   isAbsolute - Logical true when pathValue is an absolute path.

% Windows accepts drive-rooted, UNC, and separator-rooted paths. Other
% platforms use a leading forward slash.
if ispc
    hasDriveRoot = ~isempty(regexp( ...
        pathValue, '^[A-Za-z]:[\\/]', 'once'));
    hasUncRoot = startsWith(pathValue, '\\') || startsWith(pathValue, '//');
    hasSeparatorRoot = startsWith(pathValue, '\') || startsWith(pathValue, '/');
    isAbsolute = hasDriveRoot || hasUncRoot || hasSeparatorRoot;
else
    isAbsolute = startsWith(pathValue, '/');
end
end
