function tests = testSaveMatFileWithRetry
%TESTSAVEMATFILEWITHRETRY Test the retrying MAT-file save used by the sweep.
% This suite checks a normal save, a save that keeps failing, and a save
% that fails first and succeeds on a later attempt.
%
% How a failing save is simulated:
%   A real Windows lock (antivirus, sync client) cannot be created on
%   demand. Instead, a FOLDER is created at the path of the temporary
%   "<name>_partial.mat" file. save cannot write a file where a folder
%   exists, so every attempt fails, on any machine. Removing the folder
%   makes the save work again.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

% Let MATLAB discover every local function whose name starts with test.
tests = functiontests(localfunctions);
end


function setup(testCase)
%SETUP Give every test its own empty temporary folder.
% testCase receives the folder in TestData. This function has no output.

testCase.TestData.folder = tempname;
mkdir(testCase.TestData.folder);
end


function teardown(testCase)
%TEARDOWN Remove the temporary folder created by setup.
% testCase supplies the folder in TestData. This function has no output.

rmdir(testCase.TestData.folder, 's');
end


function testNormalSaveWritesTargetAndNoPartialFile(testCase)
%TESTNORMALSAVEWRITESTARGETANDNOPARTIALFILE Check the plain success path.
% testCase supplies the temporary folder. This function has no output.

targetFilePath = fullfile(testCase.TestData.folder, 'runResult.mat');
variablesToSave.runResult = struct('value', 42);

[isSaved, failureMessage, failureIdentifier] = saveMatFileWithRetry(targetFilePath, variablesToSave, 3, 0);

% The target must hold the variable under its field name, and the
% temporary file must be gone after the rename.
verifyTrue(testCase, isSaved);
verifyEqual(testCase, failureMessage, '');
verifyEqual(testCase, failureIdentifier, '');
savedFile = load(targetFilePath, 'runResult');
verifyEqual(testCase, savedFile.runResult.value, 42);
verifyFalse(testCase, isfile(fullfile(testCase.TestData.folder, 'runResult_partial.mat')));
end


function testPermanentFailureReturnsFalseWithoutThrowing(testCase)
%TESTPERMANENTFAILURERETURNSFALSEWITHOUTTHROWING Check the give-up path.
% testCase supplies the temporary folder. This function has no output.

targetFilePath = fullfile(testCase.TestData.folder, 'runResult.mat');
blockingFolder = fullfile(testCase.TestData.folder, 'runResult_partial.mat');
mkdir(blockingFolder);
variablesToSave.runResult = struct('value', 42);

% Every attempt fails; the function must report it instead of throwing.
[isSaved, failureMessage, failureIdentifier] = saveMatFileWithRetry(targetFilePath, variablesToSave, 2, 0);

verifyFalse(testCase, isSaved);
verifyNotEmpty(testCase, failureMessage);
% The identifier is returned too, so callers can store it like any error.
verifyNotEmpty(testCase, failureIdentifier);
verifyFalse(testCase, isfile(targetFilePath));
end


function testSaveSucceedsOnLaterAttempt(testCase)
%TESTSAVESUCCEEDSONLATERATTEMPT Check that a short lock is overcome by retrying.
% testCase supplies the temporary folder. This function has no output.

targetFilePath = fullfile(testCase.TestData.folder, 'runResult.mat');
blockingFolder = fullfile(testCase.TestData.folder, 'runResult_partial.mat');
mkdir(blockingFolder);
variablesToSave.runResult = struct('value', 42);

% The timer plays the part of an antivirus scan that ends after a moment:
% it removes the blocking folder 0.3 s from now. MATLAB runs timer
% callbacks during pause, so the folder disappears while the function
% waits between attempt 1 and attempt 2.
unblockTimer = timer('StartDelay', 0.3, 'TimerFcn', @(~, ~) rmdir(blockingFolder));
timerCleanup = onCleanup(@() delete(unblockTimer));
start(unblockTimer);

[isSaved, ~] = saveMatFileWithRetry(targetFilePath, variablesToSave, 3, 1);

verifyTrue(testCase, isSaved);
savedFile = load(targetFilePath, 'runResult');
verifyEqual(testCase, savedFile.runResult.value, 42);
clear timerCleanup;
end
