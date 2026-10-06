function allRigidBodies = readCSV_qualisysRigidBodiesV02(csvFilePath)
%READCSV_QUALISYSRIGIDBODIESV02 Read one or more Qualisys rigid-body rows.
% This function is a validity-aware version of readCSV_qualisysRigidBodies.
% The older reader is kept unchanged because existing workflows already use
% its table layout and waitbar behavior. This V02 reader is needed by the
% static-and-kinematic ultrasound workflow, where every CSV row must remain
% aligned with one ultrasound packet, even when a rigid body was not tracked.
%
% The main differences from the older reader are:
% - no waitbar is opened, so preparation can run without figures;
% - rows containing NaN or zero-length quaternions are retained;
% - an invalid row is marked instead of being normalized and used as a pose;
% - every rigid-body record includes isValid and status fields.
%
% Input:
%   csvFilePath - Path to a Qualisys CSV file. The file must contain the
%                 utc_epoch_ms column and q1-q4/t1-t3 columns for each body.
%
% Output:
%   allRigidBodies - Table with one row per CSV data row. Timestamps is the
%                    first column. Every other table cell contains a struct
%                    with q, t, T, isValid, and status fields.

% Read all rows at once so their order stays identical to the CSV file.
rawData = readtable(csvFilePath);
columnNames = rawData.Properties.VariableNames;

% The acquisition timestamp is the stable link used to order static poses.
if ~ismember('utc_epoch_ms', columnNames)
    error('readCSV_qualisysRigidBodiesV02:MissingTimestamp', ...
        'Timestamp column "utc_epoch_ms" was not found in: %s', csvFilePath);
end
timestamps = rawData.utc_epoch_ms;

% A rigid-body name is the part before a q1-q4 or t1-t3 suffix.
nameTokens = regexp(columnNames, '^(.*?)_(?:q[1-4]|t[1-3])$', 'tokens', 'once');
nameTokens = nameTokens(~cellfun(@isempty, nameTokens));
rigidBodyNames = unique(cellfun(@(token) token{1}, nameTokens, ...
    'UniformOutput', false), 'stable');

% Prepare one cell-valued column per body. A cell is used because each table
% entry contains both the transform and a short explanation of its validity.
allRigidBodies = table('Size', [height(rawData), numel(rigidBodyNames)], ...
    'VariableTypes', repmat({'cell'}, 1, numel(rigidBodyNames)), ...
    'VariableNames', rigidBodyNames);

for rigidBodyIndex = 1:numel(rigidBodyNames)
    rigidBodyName = rigidBodyNames{rigidBodyIndex};

    % Use explicit component names so the quaternion order remains [w x y z]
    % and similarly named rigid bodies cannot accidentally share columns.
    quaternionNames = strcat(rigidBodyName, {'_q1', '_q2', '_q3', '_q4'});
    translationNames = strcat(rigidBodyName, {'_t1', '_t2', '_t3'});
    requiredNames = [quaternionNames, translationNames];
    if ~all(ismember(requiredNames, columnNames))
        error('readCSV_qualisysRigidBodiesV02:MissingComponents', ...
            'Rigid body "%s" does not contain q1-q4 and t1-t3 in: %s', ...
            rigidBodyName, csvFilePath);
    end

    for rowIndex = 1:height(rawData)
        q = table2array(rawData(rowIndex, quaternionNames));
        t = table2array(rawData(rowIndex, translationNames));
        T = nan(4, 4);
        isValid = false;

        % NaN values mean Qualisys did not provide this rigid body at the
        % current time. Keep the row, but do not turn it into a transform.
        if ~all(isfinite([q, t]))
            status = "Invalid: quaternion or translation is not finite.";
        elseif norm(q) <= eps
            status = "Invalid: quaternion has zero length.";
        else
            % Normalize only a finite, nonzero quaternion before conversion.
            q = q / norm(q);
            T = eye(4);
            T(1:3, 1:3) = quat2rotm(q);
            T(1:3, 4) = t(:);
            isValid = true;
            status = "Valid";
        end

        allRigidBodies{rowIndex, rigidBodyName} = {struct( ...
            'q', q, ...
            't', t, ...
            'T', T, ...
            'isValid', isValid, ...
            'status', status)};
    end
end

% Match the familiar Qualisys-reader layout by keeping timestamps first.
allRigidBodies = addvars(allRigidBodies, timestamps, 'Before', 1, ...
    'NewVariableNames', 'Timestamps');
end
