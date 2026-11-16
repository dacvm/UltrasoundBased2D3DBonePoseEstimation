function absolutePath = resolveAbsolutePath(inputPath, baseFolder)
%RESOLVEABSOLUTEPATH Turn a configured path into a clean absolute path.
% This function anchors a relative path at a base folder and removes "."
% and ".." segments, so every saved and compared path is unambiguous.
% It is needed because config files hold relative paths such as
% "tools/.../file.mat", while the pipeline must not depend on MATLAB's
% current folder (it can change, e.g. inside parfor workers). It uses only
% documented base-MATLAB functions (no Java), so it also works in MATLAB
% releases that run without a Java runtime.
%
% Input:
%   inputPath    - Path to resolve, character vector or string scalar.
%                  May be absolute (drive, UNC, or Unix root) or relative.
%                  It does not have to exist yet (e.g. an output folder).
%   baseFolder   - Folder that a relative inputPath is relative to.
%
% Output:
%   absolutePath - Absolute path as a character vector, without "." or
%                  ".." segments.

% Anchor a relative path at the base folder; an absolute path is kept.
inputPath = char(inputPath);
if ~isAbsolutePath(inputPath)
    inputPath = fullfile(char(baseFolder), inputPath);
end

absolutePath = cleanExistingOrNewPath(inputPath);
end


function cleanPath = cleanExistingOrNewPath(pathText)
%CLEANEXISTINGORNEWPATH Ask the file system for the clean form of a path.
% pathText is one absolute path; cleanPath is the same location written
% without "." or ".." segments.

% dir reports the real folder of anything that exists, with "." and ".."
% already resolved. Every entry of a folder listing carries that folder
% (a drive root such as C:\ has no "." entry, so we do not look for one);
% for a file, the folder plus the file name gives the full path.
if isfolder(pathText)
    listing   = dir(pathText);
    cleanPath = listing(1).folder;
elseif isfile(pathText)
    listing   = dir(pathText);
    cleanPath = fullfile(listing.folder, listing.name);
else
    % The path does not exist yet (e.g. a new output folder). Clean the
    % parent the same way, then add the last part back on.
    [parentPath, name, extension] = fileparts(pathText);
    if strcmp(parentPath, pathText)
        % We reached a root that does not exist on this computer (e.g. a
        % drive letter recorded on another workstation). Nothing above it
        % can be cleaned, so keep it as written.
        cleanPath = pathText;
        return
    end
    cleanPath = fullfile(cleanExistingOrNewPath(parentPath), [name extension]);
end
end


function isAbsolute = isAbsolutePath(inputPath)
%ISABSOLUTEPATH Check whether a path is absolute on Windows or Unix.
% inputPath is one character path and isAbsolute reports the result.

% Recognize drive paths, UNC paths, and Unix root paths used by MATLAB.
isDrivePath = numel(inputPath) >= 3 && isstrprop(inputPath(1), 'alpha') && ...
    inputPath(2) == ':' && any(inputPath(3) == ['\' '/']);
isUncPath = startsWith(inputPath, '\\');
isUnixPath = startsWith(inputPath, '/');
isAbsolute = isDrivePath || isUncPath || isUnixPath;
end
