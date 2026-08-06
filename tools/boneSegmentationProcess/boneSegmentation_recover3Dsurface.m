clear; clc; close all;

%% LOAD AND VALIDATE THE CONFIGURATION

% Locate this script first so the configuration file can be found even when
% MATLAB was started from a different current folder.
scriptFullPath = mfilename('fullpath');
if isempty(scriptFullPath)
    error('boneSegmentation_recover3Dsurface:ScriptPathUnavailable', ...
          'Run boneSegmentation_recover3Dsurface.m as a complete script so its configuration file can be located.');
end
scriptDirectory = fileparts(scriptFullPath);

% Keep dataset-specific paths and filenames in JSON. A new processing run
% can then be selected without changing this MATLAB script.
configurationFilePath = fullfile(scriptDirectory, 'configs', 'boneSegmentation_recover3Dsurface.json');
configuration = readBoneSurfaceRecoveryConfiguration(configurationFilePath);

% Use short workflow names below while keeping the requested JSON field names
% in the validated configuration structure. Grab the bone surface path:
filepath_boneSurface     = configuration.input.boneSurfaceFilePath;
filename_boneSurface     = configuration.input.boneSurfaceFileName;
fullpath_boneSurface     = fullfile(filepath_boneSurface, filename_boneSurface);
% Grab the ultrasound image path
filepath_ultrasoundimage = configuration.input.ultrasoundImageFilePath;
filename_ultrasoundimage = configuration.input.ultrasoundImageFileName;
fullfile_ultrasoundimage = fullfile(filepath_ultrasoundimage, filename_ultrasoundimage);
% Grab the output path
boneSurface3DOutputPath  = configuration.output.boneSurface3DOutputPath;

%% PREPARE THE REQUIRED FUNCTION PATHS

% The script uses one geometry helper to transform points and one display
% helper to draw ultrasound images in 3D. Find these folders relative to this
% script instead of assuming that MATLAB was started in the project root.
projectDirectory = fileparts(fileparts(scriptDirectory));
geometryFunctionDirectory = fullfile(projectDirectory, 'functions', 'geometry');
displayFunctionDirectory  = fullfile(projectDirectory, 'functions', 'display');

% Stop here when the project layout is incomplete. Otherwise MATLAB would fail
% later with a less helpful "undefined function" message.
if ~isfolder(geometryFunctionDirectory) || ~isfolder(displayFunctionDirectory)
    error('boneSegmentation_recover3Dsurface:MissingFunctionDirectory', ...
        'The geometry or display function folder is missing.');
end
addpath(geometryFunctionDirectory, displayFunctionDirectory);

%% LOAD THE BONE SURFACE RESULTS

% LOAD with an output returns a temporary structure. Requesting both required
% variables explicitly avoids reading other large values stored in the MAT-file.
if ~isfile(fullpath_boneSurface)
    error('boneSegmentation_recover3Dsurface:MissingSurfaceFile', ...
        'Bone-surface file not found: %s', fullpath_boneSurface);
end
surfaceFileData = load(fullpath_boneSurface, 'surfaceResults', 'extractionMetadata');
if ~isfield(surfaceFileData, 'surfaceResults')
    error('boneSegmentation_recover3Dsurface:MissingSurfaceResults', ...
          'The selected MAT-file does not contain surfaceResults.');
end
if ~isfield(surfaceFileData, 'extractionMetadata')
    error('boneSegmentation_recover3Dsurface:MissingExtractionMetadata', ...
          'The selected MAT-file does not contain extractionMetadata.');
end
surfaceResults     = surfaceFileData.surfaceResults;
extractionMetadata = surfaceFileData.extractionMetadata;
clear surfaceFileData;

% The extraction step must declare the complete result schema before this
% script fills the 3D coordinates. Reject older artifacts instead of silently
% creating a new field here, because that would make saved results inconsistent.
for groupIndex = 1:numel(surfaceResults)
    currentSurfaceData = surfaceResults(groupIndex).data;
    if ~isstruct(currentSurfaceData) || ~isfield(currentSurfaceData, 'surfaceCoordinatesRefXYZ')
        error('boneSegmentation_recover3Dsurface:MissingSurfaceCoordinatesRefXYZ', ...
              ['Surface group %d does not contain surfaceCoordinatesRefXYZ.' ...
               'Rerun boneSegmentation_extractSurface.m to create a compatible MAT-file.'], ...
            groupIndex);
    end
end

%% LOAD THE ULTRASOUND SEQUENCE

% validSnapshots contains the image-plane geometry that belongs to the 2D
% surface results. Rename it to ultrasoundSequence after loading so this script
% uses the same terminology as the segmentation and extraction code.
if ~isfile(fullfile_ultrasoundimage)
    error('boneSegmentation_recover3Dsurface:MissingUltrasoundFile', ...
        'Valid-snapshot file not found: %s', fullfile_ultrasoundimage);
end
ultrasoundFileData = load(fullfile_ultrasoundimage, 'validSnapshots');
if ~isfield(ultrasoundFileData, 'validSnapshots')
    error('boneSegmentation_recover3Dsurface:MissingValidSnapshots', ...
        'The selected MAT-file does not contain validSnapshots.');
end
ultrasoundSequence = ultrasoundFileData.validSnapshots;
clear ultrasoundFileData;

%% CHECK THE ONE-TO-ONE CORRESPONDENCE

% The rest of the script uses this direct relationship:
%
%   surfaceResults(groupIndex).data(recordIndex)
%       belongs to
%   ultrasoundSequence(groupIndex).data(recordIndex)
%
% The upstream workflow preserves this order. These short checks make sure the
% user did not accidentally select files from different runs before any point
% is transformed with the wrong image pose.
numberOfSurfaceGroups = numel(surfaceResults);
if numberOfSurfaceGroups ~= numel(ultrasoundSequence)
    error('boneSegmentation_recover3Dsurface:GroupCountMismatch', ...
          'surfaceResults and ultrasoundSequence have different group counts.');
end

% Loop for all group (sensor location)
for groupIndex = 1:numberOfSurfaceGroups

    % A group describes one acquisition source, such as a bone and probe
    % location. Matching name, bone, and path confirms that both arrays refer
    % to the same source before comparing the records inside it.
    surfaceGroupIdentity = string({ ...
        surfaceResults(groupIndex).name, ...
        surfaceResults(groupIndex).bone, ...
        surfaceResults(groupIndex).path});
    ultrasoundGroupIdentity = string({ ...
        ultrasoundSequence(groupIndex).name, ...
        ultrasoundSequence(groupIndex).bone, ...
        ultrasoundSequence(groupIndex).path});
    if ~isequal(surfaceGroupIdentity, ultrasoundGroupIdentity)
        error('boneSegmentation_recover3Dsurface:GroupIdentityMismatch', ...
              'Surface and ultrasound group %d do not describe the same source.', ...
              groupIndex);
    end

    % Matching groups must contain the same number of selected ultrasound
    % frames. This lets recordIndex be used safely in both arrays.
    numberOfSurfaceRecords    = numel(surfaceResults(groupIndex).data);
    numberOfUltrasoundRecords = numel(ultrasoundSequence(groupIndex).data);
    if numberOfSurfaceRecords ~= numberOfUltrasoundRecords
        error('boneSegmentation_recover3Dsurface:RecordCountMismatch', ...
            'Surface and ultrasound group %d have different record counts.', ...
            groupIndex);
    end

    % Equal counts alone are not enough: two groups could contain different
    % frames. sourceIndex identifies the original selected snapshot, so equal
    % source-index sequences confirm the record-by-record pairing.
    surfaceSourceIndices    = [surfaceResults(groupIndex).data.sourceIndex];
    ultrasoundSourceIndices = [ultrasoundSequence(groupIndex).data.sourceIndex];
    if ~isequal(surfaceSourceIndices, ultrasoundSourceIndices)
        error('boneSegmentation_recover3Dsurface:SourceIndexMismatch', ...
              'Surface and ultrasound source indices differ in group %d.', ...
              groupIndex);
    end
end

%% CONVERT THE 2D SURFACES INTO THE REFERENCE FRAME

% The coordinate conversion has two clear stages:
%
%   [column,row] pixels
%       -> [x_mm,y_mm,0] in the local image frame
%       -> [X_ref,Y_ref,Z_ref] using T_image_ref
%
% Process every paired record and store the 3D result beside its original 2D
% surface data. The counters are only used for the summary printed at the end.
totalRecoveredPointCount = 0;
totalSurfaceRecordCount = 0;

% Loop for all group (sensor location)
for groupIndex = 1:numberOfSurfaceGroups

    % Loop for all data within a group
    for recordIndex = 1:numel(surfaceResults(groupIndex).data)

        % Read both sides of the verified pair together. currentSurfaceResult
        % supplies the pixels, while currentPlane supplies physical size and
        % the image-to-reference transformation.
        currentSurfaceResult = surfaceResults(groupIndex).data(recordIndex);
        currentPlane         = ultrasoundSequence(groupIndex).data(recordIndex).plane;

        % W and H span the first-to-last pixel centres, so divide each extent
        % by one fewer than the corresponding number of pixels.
        pixelSpacingXYMm = [ ...
            double(currentPlane.W) / (double(currentPlane.nCols) - 1), ...
            double(currentPlane.H) / (double(currentPlane.nRows) - 1)];

        % surfacePixelCoordinatesXY stores one-based [column,row] positions.
        % Subtract one to place the first pixel centre at image-frame [0,0].
        surfacePixelCoordinatesXY  = double(currentSurfaceResult.surfacePixelCoordinatesXY);
        numberOfSurfacePoints      = size(surfacePixelCoordinatesXY, 1);
        surfaceCoordinatesImageXYZ = [ ...
            (surfacePixelCoordinatesXY(:, 1) - 1) * pixelSpacingXYMm(1), ...
            (surfacePixelCoordinatesXY(:, 2) - 1) * pixelSpacingXYMm(2), ...
            zeros(numberOfSurfacePoints, 1)];

        % Ultrasound pixels lie on the image plane, so their local Z coordinate
        % is zero. applyRigidTransform applies both the rotation and translation
        % in T_image_ref to produce physical points in the ref frame. Fill the
        % field that was already declared by the surface extraction step.
        surfaceCoordinatesRefXYZ = applyRigidTransform(surfaceCoordinatesImageXYZ, currentPlane.T_image_ref);
        surfaceResults(groupIndex).data(recordIndex).surfaceCoordinatesRefXYZ = surfaceCoordinatesRefXYZ;

        totalRecoveredPointCount = totalRecoveredPointCount + numberOfSurfacePoints;
        totalSurfaceRecordCount  = totalSurfaceRecordCount + 1;
    end
end

%% SHOW THE DETECTED BONE SURFACE IN 3D SPACE

% Create one shared 3D scene. Every plane and point is already expressed in
% ref, so they can be plotted together without any additional transformation.
fig1 = figure('Name', 'Recovered 3D Bone Surfaces');
ax1 = axes(fig1);
xlabel(ax1, 'X_{ref} (mm)');
ylabel(ax1, 'Y_{ref} (mm)');
zlabel(ax1, 'Z_{ref} (mm)');
title(ax1, 'Recovered bone surfaces and ultrasound image planes');
grid(ax1, 'on');
axis(ax1, 'equal');
hold(ax1, 'on');
view(ax1, 35, 40);

% Draw all ultrasound planes before drawing the bone points. The original
% image arrays use [width,height] storage, so SwapXY restores normal displayed
% [row,column] orientation. The same pixel spacing used during conversion
% guarantees that the texture and recovered points occupy the same plane.
imagePlaneAlpha = 0.08;

% Loop for all group (sensor location)
for groupIndex = 1:numberOfSurfaceGroups

    % Loop for all data within a group
    for recordIndex = 1:numel(surfaceResults(groupIndex).data)
        
        % Get current plane
        currentPlane = ultrasoundSequence(groupIndex).data(recordIndex).plane;
        % Compute the spacing for display
        pixelSpacingXYMm = [ ...
            double(currentPlane.W) / (double(currentPlane.nCols) - 1), ...
            double(currentPlane.H) / (double(currentPlane.nRows) - 1)];

        imagePlaneHandle = display_image3D( ...
            ax1, currentPlane.image, currentPlane.T_image_ref, ...
            'SwapXY', true, ...
            'PixelSpacing', pixelSpacingXYMm, ...
            'Tag', 'recovered_image_plane', ...
            'Colormap', 'gray', ...
            'FaceAlpha', imagePlaneAlpha);

        % Image planes provide context but should not create 30 legend entries.
        imagePlaneHandle.HandleVisibility = 'off';
    end
end

% Draw each recovered path as unconnected points. Connecting all points with a
% line could incorrectly bridge gaps between separate detected surface parts.
% A shared color identifies records from the same acquisition group.
surfaceGroupNames       = string({surfaceResults.name});
surfaceGroupBones       = string({surfaceResults.bone});
surfaceGroupColors      = lines(max(numberOfSurfaceGroups, 1));
hasVisibleSurfaceGroup  = false(1, numberOfSurfaceGroups);

% Loop for all group (sensor location)
for groupIndex = 1:numberOfSurfaceGroups

    % Loop for all data within a group
    for recordIndex = 1:numel(surfaceResults(groupIndex).data)

        % Get current data
        surfaceCoordinatesRefXYZ = surfaceResults(groupIndex).data(recordIndex).surfaceCoordinatesRefXYZ;

        % Some valid records may contain no detected surface. Their image plane
        % remains visible, but there are no 3D bone points to draw.
        if isempty(surfaceCoordinatesRefXYZ)
            continue;
        end

        % Display the 3d bone surface
        boneSurfaceHandle = scatter3(ax1, ...
            surfaceCoordinatesRefXYZ(:, 1), ...
            surfaceCoordinatesRefXYZ(:, 2), ...
            surfaceCoordinatesRefXYZ(:, 3), ...
            10, surfaceGroupColors(groupIndex, :), 'filled', ...
            'Tag', 'recovered_bone_surface');

        % Use the first visible record as the group's legend representative.
        % Hide later records from the legend without hiding their points.
        if ~hasVisibleSurfaceGroup(groupIndex)
            boneSurfaceHandle.DisplayName      = sprintf('%s (%s)', surfaceGroupNames(groupIndex), surfaceGroupBones(groupIndex));
            hasVisibleSurfaceGroup(groupIndex) = true;
        else
            boneSurfaceHandle.HandleVisibility = 'off';
        end
    end
end

% Empty groups do not need a legend entry. After all objects are present, fit
% the limits to the complete scene while preserving equal physical axis scale.
if any(hasVisibleSurfaceGroup)
    legend(ax1, 'show', 'Location', 'best');
end

axis(ax1, 'tight');
axis(ax1, 'equal');
drawnow;

fprintf('Recovered %d bone-surface point(s) from %d record(s) in ref.\n', totalRecoveredPointCount, totalSurfaceRecordCount);

%% SAVE THE RECOVERED BONE SURFACES

% Use the same timestamped filename convention as the extraction step. Save
% in the configured output directory while the original extraction metadata
% stays unchanged.
recoveryTimestamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
recoveredSurfaceOutputFilePath = fullfile( ...
    boneSurface3DOutputPath, ['boneSurface_', recoveryTimestamp, '.mat']);

% surfaceResults now contains the recovered reference-frame coordinates. Keep
% extractionMetadata with it so the processing provenance is not separated from
% the numerical result.
save(recoveredSurfaceOutputFilePath, 'surfaceResults', 'extractionMetadata', '-v7.3');
fprintf('Saved recovered bone surfaces to:\n%s\n', recoveredSurfaceOutputFilePath);









%% HELPER: READ CONFIGURATION

function configuration = readBoneSurfaceRecoveryConfiguration(configurationFilePath)
%READBONESURFACERECOVERYCONFIGURATION Load and validate recovery settings.
% This function reads run-specific paths from JSON so a different pair of
% input files can be selected without editing the recovery script.
%
% Input:
%   configurationFilePath - Path to the recovery JSON configuration file.
%
% Output:
%   configuration - Scalar structure containing validated absolute input
%                   and output paths plus the two MAT-file names.

% Give a direct error when the expected configuration file is missing.
if ~isfile(configurationFilePath)
    error('boneSegmentation_recover3Dsurface:ConfigurationNotFound', ...
        'Configuration file was not found: %s', configurationFilePath);
end

% Add the source path to JSON parsing errors so the user knows which file
% needs to be corrected.
try
    configurationText = fileread(configurationFilePath);
    rawConfiguration = jsondecode(configurationText);
catch configurationError
    error('boneSegmentation_recover3Dsurface:InvalidConfigurationJson', ...
        'Could not read configuration JSON "%s". Reason: %s', ...
        configurationFilePath, configurationError.message);
end

% The remaining validation expects one object with named input and output
% sections, not an array of configuration objects.
if ~isstruct(rawConfiguration) || ~isscalar(rawConfiguration)
    error('boneSegmentation_recover3Dsurface:InvalidConfigurationRoot', ...
        'Configuration JSON must contain one object at its top level: %s', ...
        configurationFilePath);
end

% Validate both sections before accessing their settings so missing or
% incorrectly typed objects produce clear error messages.
inputConfiguration = requireRecoveryConfigurationObject( ...
    rawConfiguration, 'input', 'input');
outputConfiguration = requireRecoveryConfigurationObject( ...
    rawConfiguration, 'output', 'output');

% Read every requested setting as nonempty text before working with paths.
boneSurfaceFilePathSetting = requireRecoveryConfigurationText( ...
    inputConfiguration, 'boneSurfaceFilePath', ...
    'input.boneSurfaceFilePath');
boneSurfaceFileName = requireRecoveryConfigurationText( ...
    inputConfiguration, 'boneSurfaceFileName', ...
    'input.boneSurfaceFileName');
ultrasoundImageFilePathSetting = requireRecoveryConfigurationText( ...
    inputConfiguration, 'ultrasoundImageFilePath', ...
    'input.ultrasoundImageFilePath');
ultrasoundImageFileName = requireRecoveryConfigurationText( ...
    inputConfiguration, 'ultrasoundImageFileName', ...
    'input.ultrasoundImageFileName');
boneSurface3DOutputPathSetting = requireRecoveryConfigurationText( ...
    outputConfiguration, 'boneSurface3DOutputPath', ...
    'output.boneSurface3DOutputPath');

% Filenames are kept separate from directories in the JSON schema. Reject a
% parent path here so FULLFILE always combines the settings predictably.
validateRecoveryMatFileName( ...
    boneSurfaceFileName, 'input.boneSurfaceFileName');
validateRecoveryMatFileName( ...
    ultrasoundImageFileName, 'input.ultrasoundImageFileName');

% Resolve relative directories beside the JSON configuration. Input folders
% must exist, while a missing output folder may be created for a new run.
configurationDirectory = fileparts(configurationFilePath);
boneSurfaceFilePath = resolveRecoveryConfiguredDirectory( ...
    boneSurfaceFilePathSetting, configurationDirectory, ...
    'input.boneSurfaceFilePath', false);
ultrasoundImageFilePath = resolveRecoveryConfiguredDirectory( ...
    ultrasoundImageFilePathSetting, configurationDirectory, ...
    'input.ultrasoundImageFilePath', false);
boneSurface3DOutputPath = resolveRecoveryConfiguredDirectory( ...
    boneSurface3DOutputPathSetting, configurationDirectory, ...
    'output.boneSurface3DOutputPath', true);

% Validate the complete input paths now that both directory settings and
% filename settings are known.
boneSurfaceFullPath = fullfile( ...
    boneSurfaceFilePath, boneSurfaceFileName);
if ~isfile(boneSurfaceFullPath)
    error('boneSegmentation_recover3Dsurface:ConfiguredSurfaceFileNotFound', ...
        'Configured bone-surface file was not found: %s', ...
        boneSurfaceFullPath);
end
ultrasoundImageFullPath = fullfile( ...
    ultrasoundImageFilePath, ultrasoundImageFileName);
if ~isfile(ultrasoundImageFullPath)
    error('boneSegmentation_recover3Dsurface:ConfiguredUltrasoundFileNotFound', ...
        'Configured ultrasound image file was not found: %s', ...
        ultrasoundImageFullPath);
end

% Return the same input/output hierarchy as the JSON, with all directories
% normalized to absolute paths for the main workflow.
configuration = struct();
configuration.input = struct( ...
    'boneSurfaceFilePath', boneSurfaceFilePath, ...
    'boneSurfaceFileName', boneSurfaceFileName, ...
    'ultrasoundImageFilePath', ultrasoundImageFilePath, ...
    'ultrasoundImageFileName', ultrasoundImageFileName);
configuration.output = struct( ...
    'boneSurface3DOutputPath', boneSurface3DOutputPath);
end


%% HELPER: REQUIRE CONFIGURATION OBJECT

function objectValue = requireRecoveryConfigurationObject( ...
        parentValue, fieldName, fieldLabel)
%REQUIRERECOVERYCONFIGURATIONOBJECT Read one required scalar JSON object.
% This helper checks a configuration section before code accesses fields
% inside it, which gives a clear message for a missing input or output object.
%
% Inputs:
%   parentValue - Structure expected to contain the required object.
%   fieldName   - MATLAB field name created by JSONDECODE.
%   fieldLabel  - User-facing JSON field path used in error messages.
%
% Output:
%   objectValue - Validated scalar structure from the requested field.

% Later code expects one named object, so validate its presence and shape.
if ~isfield(parentValue, fieldName)
    error('boneSegmentation_recover3Dsurface:MissingConfigurationObject', ...
        'Required configuration object "%s" is missing.', fieldLabel);
end
objectValue = parentValue.(fieldName);
if ~isstruct(objectValue) || ~isscalar(objectValue)
    error('boneSegmentation_recover3Dsurface:InvalidConfigurationObject', ...
        'Configuration field "%s" must contain one object.', fieldLabel);
end
end


%% HELPER: REQUIRE CONFIGURATION TEXT

function textValue = requireRecoveryConfigurationText( ...
        parentValue, fieldName, fieldLabel)
%REQUIRERECOVERYCONFIGURATIONTEXT Read one required nonempty JSON text value.
% This helper provides one consistent character-vector type to MATLAB path
% functions and reports the exact JSON setting when its value is invalid.
%
% Inputs:
%   parentValue - Structure expected to contain the required text field.
%   fieldName   - MATLAB field name created by JSONDECODE.
%   fieldLabel  - User-facing JSON field path used in error messages.
%
% Output:
%   textValue - Trimmed, nonempty character vector from the requested field.

% Check for a missing field before reading it so the error names the setting.
if ~isfield(parentValue, fieldName)
    error('boneSegmentation_recover3Dsurface:MissingConfigurationField', ...
        'Required configuration field "%s" is missing.', fieldLabel);
end
rawValue = parentValue.(fieldName);

% Accept either MATLAB text type but reject arrays or non-text JSON values.
isCharacterText = ischar(rawValue) && isrow(rawValue);
isScalarString = isstring(rawValue) && isscalar(rawValue);
if ~isCharacterText && ~isScalarString
    error('boneSegmentation_recover3Dsurface:InvalidConfigurationText', ...
        'Configuration field "%s" must contain one text value.', ...
        fieldLabel);
end
textValue = strtrim(char(rawValue));
if isempty(textValue)
    error('boneSegmentation_recover3Dsurface:EmptyConfigurationText', ...
        'Configuration field "%s" cannot be empty.', fieldLabel);
end
end


%% HELPER: VALIDATE MAT-FILE NAME

function validateRecoveryMatFileName(fileName, fieldLabel)
%VALIDATERECOVERYMATFILENAME Validate one configured MAT-file name.
% This helper keeps a configured filename separate from its directory and
% ensures the recovery workflow receives the MAT-file type that it expects.
%
% Inputs:
%   fileName   - Filename read from the JSON configuration.
%   fieldLabel - User-facing JSON field path used in error messages.
%
% Outputs:
%   This function has no output. It throws an error for an invalid filename.

% A parent directory belongs in the corresponding FilePath JSON field.
[fileParent, ~, fileExtension] = fileparts(fileName);
if ~isempty(fileParent)
    error('boneSegmentation_recover3Dsurface:InvalidConfiguredFileName', ...
        ['Configuration field "%s" must contain a filename only, ' ...
         'without a directory.'], fieldLabel);
end

% Both inputs are MATLAB artifacts, so reject any other extension early.
if ~strcmpi(fileExtension, '.mat')
    error('boneSegmentation_recover3Dsurface:InvalidConfiguredFileExtension', ...
        'Configuration field "%s" must identify a MAT-file.', fieldLabel);
end
end


%% HELPER: RESOLVE CONFIGURED DIRECTORY

function resolvedDirectory = resolveRecoveryConfiguredDirectory( ...
        configuredDirectory, configurationDirectory, fieldLabel, ...
        createIfMissing)
%RESOLVERECOVERYCONFIGUREDDIRECTORY Resolve one configured directory.
% Relative paths are anchored beside the JSON file so the result does not
% depend on MATLAB's current working folder.
%
% Inputs:
%   configuredDirectory   - Absolute path or path relative to the JSON file.
%   configurationDirectory - Directory containing the JSON configuration.
%   fieldLabel            - User-facing JSON field path for error messages.
%   createIfMissing       - Logical true when a missing folder may be made.
%
% Output:
%   resolvedDirectory - Canonical absolute path to the usable directory.

% Preserve absolute paths and anchor only relative paths at the config file.
if isRecoveryAbsolutePath(configuredDirectory)
    candidateDirectory = configuredDirectory;
else
    candidateDirectory = fullfile( ...
        configurationDirectory, configuredDirectory);
end

% Existing inputs are required. The output folder can be made automatically
% because a new location may not exist before its first processing run.
if ~isfolder(candidateDirectory)
    if ~createIfMissing
        error('boneSegmentation_recover3Dsurface:ConfiguredDirectoryNotFound', ...
            'Configured directory "%s" was not found: %s', ...
            fieldLabel, candidateDirectory);
    end
    [directoryCreated, creationMessage] = mkdir(candidateDirectory);
    if ~directoryCreated
        error('boneSegmentation_recover3Dsurface:OutputDirectoryCreationFailed', ...
            'Could not create configured directory "%s": %s', ...
            candidateDirectory, creationMessage);
    end
end

% Canonicalize the path so later messages and saved locations are stable.
[pathFound, pathAttributes] = fileattrib(candidateDirectory);
if ~pathFound
    error('boneSegmentation_recover3Dsurface:DirectoryResolutionFailed', ...
        'Could not resolve configured directory "%s": %s', ...
        fieldLabel, candidateDirectory);
end
resolvedDirectory = pathAttributes.Name;
end


%% HELPER: IDENTIFY ABSOLUTE PATHS

function isAbsolute = isRecoveryAbsolutePath(pathValue)
%ISRECOVERYABSOLUTEPATH Identify absolute Windows, UNC, and Unix paths.
% This helper prevents an already absolute configured path from being joined
% incorrectly to the configuration directory.
%
% Input:
%   pathValue - Directory path stored as a character vector.
%
% Output:
%   isAbsolute - Logical true when pathValue is an absolute path.

% Windows supports drive-rooted, UNC, and separator-rooted paths. Other
% platforms use a leading forward slash for absolute paths.
if ispc
    hasDriveRoot = ~isempty(regexp( ...
        pathValue, '^[A-Za-z]:[\\/]', 'once'));
    hasUncRoot = startsWith(pathValue, '\\') || startsWith(pathValue, '//');
    hasSeparatorRoot = startsWith(pathValue, '\') || startsWith(pathValue, '/');
    isAbsolute = hasDriveRoot || hasUncRoot || hasSeparatorRoot;
else
    isAbsolute = startsWith(pathValue, '/');
end
end
