% Demo: read transformation data from an fCal configuration XML file.
% This script shows the expected way to call read_fcal_transforms().

% Get the current script folder so this demo works from any working directory.
scriptFolder = fileparts(mfilename('fullpath'));

% Build the absolute path to the sample fCal XML file in the same folder.
fcalConfigPath = fullfile( ...
    scriptFolder, ...
    'PlusDeviceSet_fCal_Epiphan_NDIPolaris_UTNML__20260212_153704.xml');

% Parse all <Transform> entries under <CoordinateDefinitions>.
transformations = read_fcal_transforms(fcalConfigPath);

% Print where the data came from and how many transforms were parsed.
fprintf('Loaded %d transformations from:\n%s\n', numel(transformations), fcalConfigPath);

% Stop early with a clear message when no transforms are found.
if isempty(transformations)
    disp('No transformations found in <CoordinateDefinitions>.');
    return;
end

% Build a compact summary table for quick inspection in Command Window.
summaryTable = table( ...
    string({transformations.Name}).', ...
    [transformations.Error].', ...
    string({transformations.Date}).', ...
    'VariableNames', {'Name', 'Error', 'Date'});

% Display the summary table.
disp(summaryTable);

% Print each transform matrix with its name so users can inspect values.
for transformIndex = 1:numel(transformations)
    % Show a label before each matrix for readability.
    fprintf('\n%s matrix:\n', transformations(transformIndex).Name);

    % Display the numeric 4x4 matrix.
    disp(transformations(transformIndex).Matrix);
end
