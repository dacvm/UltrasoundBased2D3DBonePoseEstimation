function is_absolute = isAbsolutePath(path_value)
% isAbsolutePath Recognize Windows, UNC, and Unix-style absolute paths.
%
% This helper makes path interpretation independent of the operating system
% so configuration files can be checked consistently on Windows and Unix.
%
% Inputs:
%   path_value - Character row containing the path to inspect.
%
% Outputs:
%   is_absolute - Logical scalar that is true for an absolute path.

    % Check the path syntax appropriate for the current operating system.
    if ispc
        % A Windows path can start with a drive plus separator, a root
        % separator, or a forward slash accepted by MATLAB on Windows.
        has_drive_root = ~isempty(regexp(path_value, '^[A-Za-z]:[\\/]', 'once'));
        has_separator_root = startsWith(path_value, filesep) || startsWith(path_value, '/');
        is_absolute = has_drive_root || has_separator_root;
    else
        % Unix-style absolute paths begin at the filesystem root.
        is_absolute = startsWith(path_value, '/');
    end
end
