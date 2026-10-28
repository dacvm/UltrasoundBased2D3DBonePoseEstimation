function tests = testGetRunResultFilePath
%TESTGETRUNRESULTFILEPATH Test the shared run-result path rule of the sweep.
% This suite checks that getRunResultFilePath builds the folder layout the
% sweep writes and the evaluation script reads, for string and char input.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

% Let MATLAB discover every local function whose name starts with test.
tests = functiontests(localfunctions);
end


function testBuildsRunsCombinationSeedLayout(testCase)
%TESTBUILDSRUNSCOMBINATIONSEEDLAYOUT Check the full path for one run.
% testCase is the MATLAB test context. This function has no output.

experimentFolder = fullfile(tempdir, 'myExperiment');

resultFilePath = getRunResultFilePath(experimentFolder, "combination_0001", 2001);

% The path must follow runs/<combinationId>/seed_<seed>/runResult.mat.
expectedFilePath = fullfile(experimentFolder, 'runs', 'combination_0001', 'seed_2001', 'runResult.mat');
verifyEqual(testCase, resultFilePath, expectedFilePath);
end


function testCharAndStringCombinationIdGiveSamePath(testCase)
%TESTCHARANDSTRINGCOMBINATIONIDGIVESAMEPATH Check both text types work.
% testCase is the MATLAB test context. This function has no output.

% The summary table stores combinationId as a string, while hand-written
% calls often pass char. Both must lead to the same file.
experimentFolder = fullfile(tempdir, 'myExperiment');

pathFromString = getRunResultFilePath(experimentFolder, "combination_0027", 2005);
pathFromChar   = getRunResultFilePath(experimentFolder, 'combination_0027', 2005);

verifyEqual(testCase, pathFromString, pathFromChar);
end
