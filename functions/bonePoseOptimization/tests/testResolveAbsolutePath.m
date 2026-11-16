function tests = testResolveAbsolutePath
%TESTRESOLVEABSOLUTEPATH Test the Java-free path resolver used by configs.
% This suite checks that relative, absolute, "..", and not-yet-existing
% paths resolve to the same clean absolute paths the config readers expect.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

tests = functiontests(localfunctions);
end


function setupOnce(testCase)
%SETUPONCE Make the functions folder callable and remember the project root.
% testCase stores the absolute project root for all tests in this suite.
% This function has no output.

testFilePath = mfilename('fullpath');
projectRoot = fileparts(fileparts(fileparts(fileparts(testFilePath))));
addpath(genpath(fullfile(projectRoot, 'functions')));
testCase.TestData.projectRoot = projectRoot;
end


function testRelativeFolderIsAnchoredAtBase(testCase)
%TESTRELATIVEFOLDERISANCHOREDATBASE A relative folder joins the base folder.
% testCase supplies the project root. This function has no output.

projectRoot = testCase.TestData.projectRoot;
resolved = resolveAbsolutePath('functions', projectRoot);
verifyEqual(testCase, resolved, fullfile(projectRoot, 'functions'));
end


function testDotDotSegmentsAreRemoved(testCase)
%TESTDOTDOTSEGMENTSAREREMOVED "." and ".." disappear from existing paths.
% testCase supplies the project root. This function has no output.

projectRoot = testCase.TestData.projectRoot;
resolved = resolveAbsolutePath(fullfile('functions', '.', '..', 'functions', 'geometry', 'applyRigidTransform.m'), projectRoot);
verifyEqual(testCase, resolved, fullfile(projectRoot, 'functions', 'geometry', 'applyRigidTransform.m'));
end


function testAbsolutePathIgnoresBase(testCase)
%TESTABSOLUTEPATHIGNORESBASE An absolute path is not joined to the base.
% testCase supplies the project root. This function has no output.

projectRoot = testCase.TestData.projectRoot;
resolved = resolveAbsolutePath(string(projectRoot), fullfile(projectRoot, 'functions'));
verifyEqual(testCase, resolved, projectRoot);
end


function testMissingPathIsResolvedThroughExistingParent(testCase)
%TESTMISSINGPATHISRESOLVEDTHROUGHEXISTINGPARENT A new folder still resolves.
% testCase supplies the project root. This function has no output.

projectRoot = testCase.TestData.projectRoot;
resolved = resolveAbsolutePath(fullfile('functions', '..', 'notCreatedYet', 'run_01'), projectRoot);
verifyEqual(testCase, resolved, fullfile(projectRoot, 'notCreatedYet', 'run_01'));
end


function testDriveRootAndMissingDriveResolve(testCase)
%TESTDRIVEROOTANDMISSINGDRIVERESOLVE Roots resolve without looping forever.
% testCase is the running test. This function has no output.

% Only Windows has drive letters, so this check is skipped elsewhere.
assumeTrue(testCase, ispc);

% An existing drive root has no "." entry in its dir listing.
systemDrive = [getenv('SystemDrive') '\'];
verifyEqual(testCase, resolveAbsolutePath(systemDrive, pwd), systemDrive);

% A drive that does not exist here (e.g. recorded on another workstation)
% must come back as written instead of recursing without end.
missingDrive = '';
for letter = 'ZYXWVUTSRQ'
    if ~isfolder([letter ':\'])
        missingDrive = [letter ':\'];
        break
    end
end
assumeNotEmpty(testCase, missingDrive);
verifyEqual(testCase, resolveAbsolutePath([missingDrive 'data\file.mat'], pwd), ...
    [missingDrive 'data\file.mat']);
end
