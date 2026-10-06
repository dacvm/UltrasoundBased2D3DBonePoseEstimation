function tests = testReadCSV_qualisysRigidBodiesV02
%TESTREADCSV_QUALISYSRIGIDBODIESV02 Test row-preserving CSV preparation.
% These tests confirm that the V02 reader keeps valid and invalid samples in
% their original rows, which protects MHA-packet-to-CSV-row correspondence.
%
% Output:
%   tests - MATLAB function-based test suite discovered by runtests.

tests = functiontests(localfunctions);
end

function testValidAndInvalidRowsRemainAligned(testCase)
%TESTVALIDANDINVALIDROWSREMAINALIGNED Keep invalid poses without dropping rows.
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for verification.
%
% Output:
%   None. The test verifies the returned table directly.

temporaryCsvPath = [tempname, '.csv'];
cleanupFile = onCleanup(@() deleteTemporaryFile(temporaryCsvPath));

% Row one is a valid identity pose. Row two represents an untracked body by
% storing NaN in all pose components, as the acquisition CSV files do.
csvData = table( ...
    [1000; 1010], ...
    [1; NaN], [0; NaN], [0; NaN], [0; NaN], ...
    [10; NaN], [20; NaN], [30; NaN], ...
    'VariableNames', { ...
        'utc_epoch_ms', ...
        'B_N_REF_q1', 'B_N_REF_q2', 'B_N_REF_q3', 'B_N_REF_q4', ...
        'B_N_REF_t1', 'B_N_REF_t2', 'B_N_REF_t3'});
writetable(csvData, temporaryCsvPath);

rigidBodies = readCSV_qualisysRigidBodiesV02(temporaryCsvPath);

verifyEqual(testCase, height(rigidBodies), 2);
verifyTrue(testCase, rigidBodies.B_N_REF{1}.isValid);
verifyFalse(testCase, rigidBodies.B_N_REF{2}.isValid);
verifyEqual(testCase, rigidBodies.B_N_REF{1}.T, ...
    [eye(3), [10; 20; 30]; 0, 0, 0, 1], 'AbsTol', 1e-12);
verifyTrue(testCase, all(isnan(rigidBodies.B_N_REF{2}.T(:))));
verifyEqual(testCase, rigidBodies.Timestamps, [1000; 1010]);
end

function testZeroQuaternionIsInvalid(testCase)
%TESTZEROQUATERNIONISINVALID Avoid normalizing a zero-length quaternion.
% Input:
%   testCase - matlab.unittest.FunctionTestCase used for verification.
%
% Output:
%   None. The test verifies the validity fields directly.

temporaryCsvPath = [tempname, '.csv'];
cleanupFile = onCleanup(@() deleteTemporaryFile(temporaryCsvPath));
csvData = table(2000, 0, 0, 0, 0, 1, 2, 3, ...
    'VariableNames', { ...
        'utc_epoch_ms', ...
        'C_F_PRO_q1', 'C_F_PRO_q2', 'C_F_PRO_q3', 'C_F_PRO_q4', ...
        'C_F_PRO_t1', 'C_F_PRO_t2', 'C_F_PRO_t3'});
writetable(csvData, temporaryCsvPath);

rigidBodies = readCSV_qualisysRigidBodiesV02(temporaryCsvPath);

verifyFalse(testCase, rigidBodies.C_F_PRO{1}.isValid);
verifyEqual(testCase, rigidBodies.C_F_PRO{1}.status, ...
    "Invalid: quaternion has zero length.");
end

function deleteTemporaryFile(temporaryCsvPath)
%DELETETEMPORARYFILE Remove a CSV fixture after a test completes.
% Input:
%   temporaryCsvPath - Full path of the temporary CSV fixture.
%
% Output:
%   None. The function deletes the file when it exists.

if isfile(temporaryCsvPath)
    delete(temporaryCsvPath);
end
end
