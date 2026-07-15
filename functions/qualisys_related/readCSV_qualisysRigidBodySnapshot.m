function allRigidBodies = readCSV_qualisysRigidBodySnapshot(csvFilePath)
% readCSV_qualisysRigidBodySnapshot Reads a CSV file of a snapshot (one 
% frame) of rigid body transformations, normalizes quaternions, and 
% organizes the data into a table with transformation matrices.
%
% INPUT:
%   csvFilePath - (string) Path to the CSV file containing the rigid body data.
%                 The CSV file should have columns with the following format:
%                 <rigid_body_name>_<parameter>, where <parameter> is:
%                 - 'q1', 'q2', 'q3', 'q4': quaternion components stored
%                   as [w, x, y, z], so q1 is the scalar part.
%                 - 't1', 't2', 't3': translation vector components.
%                 The CSV must also include a 'timestamp' column.
%
% OUTPUT:
%   organizedDataTable - (table) A table where:
%       - Each row corresponds to a timestamp.
%       - The first column contains timestamps.
%       - Each remaining column corresponds to a rigid body.
%         Each cell contains a struct with:
%           - q: The normalized quaternion as [q1, q2, q3, q4], which
%                follows MATLAB's scalar-first [w, x, y, z] order.
%           - t: The translation vector [t1, t2, t3].
%           - T: The 4x4 rigid body transformation matrix.
%
% USAGE:
%   organizedDataTable = readCSV_qualisysRigidBodies('path/to/file.csv');
%
% EXAMPLE:
%   organizedDataTable = readCSV_qualisysRigidBodies('MocapData.csv');
%   disp(organizedDataTable);

    % Read the complete snapshot because it should contain only one data row.
    data = readtable(csvFilePath);

    % Reject empty recordings and multi-row recordings because this helper is
    % intentionally limited to a single snapshot.
    if height(data) ~= 1
        error('readCSV_qualisysRigidBodySnapshot:InvalidRowCount', ...
            'Expected exactly one data row, but the CSV file contains %d rows.', ...
            height(data));
    end

    % Keep the imported names so each rigid body's quaternion and translation
    % columns can be found from their shared prefix.
    columnNames = data.Properties.VariableNames;

    % Read the snapshot time and give a clear error when the required field is
    % absent instead of failing later while building the output table.
    if ismember('utc_epoch_ms', columnNames)
        timestamp = data.utc_epoch_ms;
    else
        error('readCSV_qualisysRigidBodySnapshot:MissingTimestamp', ...
            'Timestamp column ''utc_epoch_ms'' was not found in the dataset.');
    end

    % Convert string names to a cell array of character vectors because the
    % regular expression below processes one name at a time.
    if isstring(columnNames)
        columnNames = cellstr(columnNames);
    elseif ~iscellstr(columnNames)
        columnNames = cellfun(@char, columnNames, 'UniformOutput', false);
    end

    % Remove the _q* and _t* suffixes, then keep one entry for each body.
    rigidBodyNames = cellfun( ...
        @(name) regexp(name, '^(.*?)_(?=q|t)', 'tokens', 'once'), ...
        columnNames, 'UniformOutput', false);
    rigidBodyNames = vertcat(rigidBodyNames{:});
    rigidBodyNames = unique(rigidBodyNames);
    rigidBodyNames = rigidBodyNames(~ismember(rigidBodyNames, {'q', 't'}));

    % Preallocate one cell-valued table column for every rigid body in the
    % snapshot. The timestamp is added after the body data has been filled.
    allRigidBodies = table('Size', [1, length(rigidBodyNames)], ...
        'VariableTypes', repmat({'cell'}, 1, length(rigidBodyNames)), ...
        'VariableNames', rigidBodyNames);

    % Combine a MATLAB-order quaternion and translation into one homogeneous
    % transform. Keeping this local avoids repeating the matrix construction.
    quatToTransform = @(q, t) [ ...
        quat2rotm(q), t(:); ...
        0, 0, 0, 1];

    % A snapshot has one row, but it can still contain several rigid bodies.
    % Process each body once without a row loop or progress waitbar.
    for bodyIndex = 1:length(rigidBodyNames)
        body = rigidBodyNames{bodyIndex};

        % Select all quaternion and translation columns belonging to this body.
        relatedCols = startsWith(columnNames, body);
        bodyTable = data(:, relatedCols);
        quaternionCols = contains(columnNames(relatedCols), '_q');
        translationCols = contains(columnNames(relatedCols), '_t');

        % Read the scalar-first [w, x, y, z] quaternion written by the
        % acquisition application, then normalize it before conversion.
        q = table2array(bodyTable(:, quaternionCols));
        q = q / norm(q);

        % Read the only translation and combine it with the rotation.
        t = table2array(bodyTable(:, translationCols));
        T = quatToTransform(q, t);

        % Store the values in the same struct layout as the multi-row reader.
        allRigidBodies{1, body} = {struct('q', q, 't', t, 'T', T)};
    end

    % Put the timestamp first so the output layout matches the existing reader.
    allRigidBodies = addvars(allRigidBodies, timestamp, 'Before', 1, ...
        'NewVariableNames', 'Timestamps');
end
