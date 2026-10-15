function [isSaved, failureMessage] = saveMatFileWithRetry(filePath, variablesToSave, numberOfAttempts, pauseSeconds)
%SAVEMATFILEWITHRETRY Save variables to a MAT file, retrying when Windows blocks it.
% This function writes the variables to a temporary MAT file next to the
% target, renames it to the target name, and tries again after a short
% pause when the save or the rename fails. It reports failure instead of
% throwing an error.
%
% Why it is needed:
%   A hyperparameter sweep saves one result file after every run and runs
%   unattended for many hours. On Windows a save can fail for a moment for
%   reasons outside MATLAB: antivirus or the search indexer opening the new
%   file, a sync client (OneDrive, Dropbox) locking it, or a network drive
%   dropping out. A plain save then throws "The file could not be closed"
%   and ends the whole sweep. Such locks usually last only seconds, so
%   trying again after a pause is often enough.
%
%   Writing to a temporary file first means the target name only appears
%   when the file was written completely. A half-written file can then
%   never be mistaken for a finished result.
%
% Input:
%   filePath         - Full path of the target MAT file, ending in '.mat'.
%   variablesToSave  - Scalar struct. Each field is saved as one variable
%                      with the field's name (save -struct).
%   numberOfAttempts - How many times to try before giving up (>= 1).
%   pauseSeconds     - Seconds to wait between two attempts.
%
% Output:
%   isSaved        - true when the target file was written, false otherwise.
%   failureMessage - Message of the last failed attempt; '' when saved.

%% PREPARE THE TEMPORARY FILE NAME

% The temporary file sits in the same folder as the target. A rename within
% one folder is a quick, single file-system step, unlike copying the data.
% The "_partial" name makes it obvious what a left-over file is.
[targetFolder, targetName] = fileparts(filePath);
temporaryFilePath          = fullfile(targetFolder, [targetName '_partial.mat']);

isSaved        = false;
failureMessage = '';

%% TRY TO SAVE, PAUSING BETWEEN ATTEMPTS

for attemptNumber = 1:numberOfAttempts

    % The try/catch is the point of this function: a failed save must be
    % retried, not end the caller. save throws on failure, while movefile
    % reports failure through its first output instead.
    try
        % -v7.3 because run results can hold large intersection data, and
        % older MAT formats cannot store variables larger than 2 GB.
        save(temporaryFilePath, '-struct', 'variablesToSave', '-v7.3');
        % 'f' replaces an existing target, e.g. a corrupt file from an
        % earlier attempt that is now being rerun.
        [isMoved, moveMessage] = movefile(temporaryFilePath, filePath, 'f');
        if isMoved
            isSaved        = true;
            failureMessage = '';
            return;
        end
        failureMessage = moveMessage;
    catch saveError
        failureMessage = saveError.message;
    end

    % Tell the user, so a slow sweep can be explained from the log later.
    fprintf('Saving %s failed (attempt %d of %d): %s\n', ...
            filePath, attemptNumber, numberOfAttempts, failureMessage);

    % Only wait when another attempt follows.
    if attemptNumber < numberOfAttempts
        pause(pauseSeconds);
    end
end

%% CLEAN UP AFTER THE LAST FAILED ATTEMPT

% A partial file may hold incomplete data. Remove it so nothing that looks
% like a result is left behind. isfile is false for a folder of the same
% name, which the tests use to block the save.
if isfile(temporaryFilePath)
    delete(temporaryFilePath);
end
end
