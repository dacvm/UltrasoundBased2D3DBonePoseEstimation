function allRigidBodies = readCSV_qualisysRigidBodies(csvFilePath)
% processRigidBodyData Reads a CSV file of rigid body transformations, normalizes quaternions,
%                      and organizes the data into a table with transformation matrices.
%
% INPUT:
%   csvFilePath - (string) Path to the CSV file containing the rigid body data.
%                 The CSV file should have columns with the following format:
%                 <rigid_body_name>_<parameter>, where <parameter> is:
%                 - 'q1', 'q2', 'q3', 'q4': quaternion components (q4 is the scalar part).
%                 - 't1', 't2', 't3': translation vector components.
%                 The CSV must also include a 'timestamp' column.
%
% OUTPUT:
%   organizedDataTable - (table) A table where:
%       - Each row corresponds to a timestamp.
%       - The first column contains timestamps.
%       - Each remaining column corresponds to a rigid body.
%         Each cell contains a struct with:
%           - q: The normalized quaternion as [q4, q1, q2, q3].
%           - t: The translation vector [t1, t2, t3].
%           - T: The 4x4 rigid body transformation matrix.
%
% USAGE:
%   organizedDataTable = readCSV_qualisysRigidBodies('path/to/file.csv');
%
% EXAMPLE:
%   organizedDataTable = readCSV_qualisysRigidBodies('MocapData.csv');
%   disp(organizedDataTable);

    % Read the CSV file
    data = readtable(csvFilePath);

    % Extract column names
    columnNames = data.Properties.VariableNames;

    % Extract timestamps
    if ismember('utc_epoch_ms', columnNames)
        timestamps = data.utc_epoch_ms; % Extract timestamps
    else
        error('Timestamp column not found in the dataset.');
    end

    % Ensure columnNames is a cell array of character vectors
    if ~iscellstr(columnNames)
        columnNames = cellfun(@char, columnNames, 'UniformOutput', false);
    end

    % Extract unique rigid body names without suffixes (_q or _t)
    rigidBodyNames = cellfun(@(x) regexp(x, '^(.*?)_(?=q|t)', 'tokens', 'once'), columnNames, 'UniformOutput', false);
    rigidBodyNames = vertcat(rigidBodyNames{:}); % Flatten the nested cell array
    rigidBodyNames = unique(rigidBodyNames);     % Remove duplicates
    rigidBodyNames = rigidBodyNames(~ismember(rigidBodyNames, {'q', 't'})); % Filter out invalid names

    % Initialize a table to store the organized data
    allRigidBodies = table('Size', [height(data) length(rigidBodyNames)], ...
        'VariableTypes', repmat({'cell'}, 1, length(rigidBodyNames)), ...
        'VariableNames', rigidBodyNames);

    % Function to convert quaternion and translation to a 4x4 transformation matrix
    quatToTransform = @(q, t) [
        quat2rotm(q), t(:); % 3x3 rotation matrix and 3x1 translation vector
        0 0 0 1             % Homogeneous coordinates
    ];

    % initialize waitbar, so the user not get bored
    h = waitbar(0, 'Please wait...');

    % get the number of iterations
    n_rigidBody = length(rigidBodyNames);

    % Populate the table
    for i = 1:n_rigidBody

        % show the waitbar progress
        waitbar(i/n_rigidBody, h, sprintf('Progress: %d%%', round(i/n_rigidBody*100)));

        % Extract the current body
        body = rigidBodyNames{i};

        % Find all columns related to this rigid body
        relatedCols = startsWith(columnNames, body);
        bodyTable = data(:, relatedCols); % Subtable with relevant columns

        % Separate quaternions and translations
        quaternionCols = contains(columnNames(relatedCols), '_q');
        translationCols = contains(columnNames(relatedCols), '_t');

        quaternions = bodyTable(:, quaternionCols);
        translations = bodyTable(:, translationCols);

        % Create a struct for each timestamp
        for row = 1:height(data)

            % Extract quaternion
            q = table2array(quaternions(row, :)); 

            % Reorder quaternion to [q4, q1, q2, q3]
            % (fromt the csv, q4 is the scalar, i put it in the front using matlab notation)
            q = [q(4), q(1:3)];

            % Normalize the quaternion
            q = q / norm(q);

            t = table2array(translations(row, :)); % Extract translation

            % Compute the transformation matrix
            T = quatToTransform(q, t);

            % Store the data in a struct
            allRigidBodies{row, body} = {struct('q', q, ...
                                                    't', t, ...
                                                    'T', T)};
        end
    end

    % Add timestamps as a separate column
    allRigidBodies = addvars(allRigidBodies, timestamps, 'Before', 1, 'NewVariableNames', 'Timestamps');

    % Close the waitbar
    close(h);
end
