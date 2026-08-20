function boneSurface = prepareBoneSurfaceMeasurements( ...
        surfaceFilePath, snapshotSources, imagePlanesRef, targetBone, ...
        referenceSnapshotFilePath)
%PREPAREBONESURFACEMEASUREMENTS Load and align measured bone surfaces.
% This function reads the 2D and 3D bone surfaces produced by the
% bone-segmentation tools, checks their basic coordinate contract, and puts
% them in the same order as the ultrasound image planes. This alignment is
% needed so a future cost model can use measurement k with image plane k.
%
% Inputs:
%   surfaceFilePath          - Path to the MAT-file containing surfaceResults
%                              and extractionMetadata.
%   snapshotSources          - One source-identity record per prepared image.
%   imagePlanesRef           - Ultrasound image planes aligned with the source
%                              records. Only the number of planes is checked here.
%   targetBone               - Bone code selected for optimization, such as T.
%   referenceSnapshotFilePath - Snapshot MAT-file used by the optimizer.
%
% Output:
%   boneSurface              - Struct containing the source metadata and one
%                              aligned surface measurement per image plane.

%% LOAD THE SURFACE TOOL OUTPUT

% Report the configured input directly when it cannot be opened.
if ~isfile(surfaceFilePath)
    error('prepareBoneSurfaceMeasurements:MissingSurfaceFile', ...
          'Bone-surface file was not found: %s', surfaceFilePath);
end

% Load only the two public variables produced by the extraction workflow.
surfaceFileData = load(surfaceFilePath, 'surfaceResults', 'extractionMetadata');
if ~isfield(surfaceFileData, 'surfaceResults') || ...
        ~isfield(surfaceFileData, 'extractionMetadata')
    error('prepareBoneSurfaceMeasurements:MissingSurfaceVariables', ...
          'Bone-surface file must contain surfaceResults and extractionMetadata.');
end

surfaceResults     = surfaceFileData.surfaceResults;
extractionMetadata = surfaceFileData.extractionMetadata;

%% CHECK THE SMALL METADATA CONTRACT

% Confirm that the surface was created from the same snapshot file that the
% optimizer is preparing. Canonical paths avoid false mismatches from "..".
validateSurfaceMetadata(extractionMetadata, referenceSnapshotFilePath);

%% MATCH EACH SURFACE TO ITS PREPARED IMAGE

% Preparation already made these arrays one-to-one, so their sizes must agree
% before we add another aligned measurement array.
numberOfImages = numel(imagePlanesRef);
if numel(snapshotSources) ~= numberOfImages
    error('prepareBoneSurfaceMeasurements:SnapshotSourceCountMismatch', ...
          'snapshotSources and imagePlanesRef must contain the same number of records.');
end

% A cell array keeps the matching loop simple. The cells are joined into one
% struct array only after every image has found exactly one surface record.
measurementCells = cell(1, numberOfImages);
surfaceGroupBones = upper(string({surfaceResults.bone}));

for imageIndex = 1:numberOfImages
    source = snapshotSources(imageIndex);

    % Group name, path, and bone identify the acquisition before sourceIndex
    % identifies the selected frame inside that group.
    groupMatches = surfaceGroupBones == upper(string(targetBone)) & ...
        string({surfaceResults.name}) == string(source.groupName) & ...
        string({surfaceResults.path}) == string(source.groupPath);
    matchingGroupIndexes = find(groupMatches);

    if numel(matchingGroupIndexes) ~= 1
        error('prepareBoneSurfaceMeasurements:SurfaceGroupMatchFailed', ...
              'Expected one surface group for image %d, but found %d.', ...
              imageIndex, numel(matchingGroupIndexes));
    end

    matchingGroup = surfaceResults(matchingGroupIndexes);
    recordMatches = find([matchingGroup.data.sourceIndex] == source.sourceIndex);
    if numel(recordMatches) ~= 1
        error('prepareBoneSurfaceMeasurements:SurfaceRecordMatchFailed', ...
              'Expected one surface record for image %d and sourceIndex %d, but found %d.', ...
              imageIndex, source.sourceIndex, numel(recordMatches));
    end

    % Keep the complete tool result so later cost models can choose which
    % confidence or regularization fields they need without changing preparation.
    measurement = matchingGroup.data(recordMatches);
    validateSurfaceMeasurement(measurement, imageIndex);

    % Restore the group identity that would otherwise be lost after flattening.
    measurement.groupName = char(string(matchingGroup.name));
    measurement.groupPath = char(string(matchingGroup.path));
    measurement.bone      = char(string(matchingGroup.bone));
    measurementCells{imageIndex} = measurement;
end

%% PACKAGE THE ALIGNED INPUT

% Keep provenance beside the measurements so saved configurations and debug
% sessions can identify exactly which tool output supplied the surfaces.
boneSurface.isAvailable       = true;
boneSurface.sourceFilePath    = canonicalPath(surfaceFilePath);
boneSurface.extractionMetadata = extractionMetadata;
boneSurface.measurements      = [measurementCells{:}];
end


function validateSurfaceMetadata(metadata, referenceSnapshotFilePath)
%VALIDATESURFACEMETADATA Check source identity and coordinate conventions.
% metadata is the extractionMetadata struct, referenceSnapshotFilePath is the
% optimizer snapshot path, and this function returns no output.

% These fields define the small boundary that optimization needs to interpret
% the surface coordinates without depending on extraction implementation details.
requiredFields = {'sourceUltrasoundFile', 'sourceUltrasoundVariable', ...
    'coordinateConvention', 'beamAxis', 'beamDirection'};
if ~isstruct(metadata) || ~all(isfield(metadata, requiredFields))
    error('prepareBoneSurfaceMeasurements:InvalidSurfaceMetadata', ...
          'extractionMetadata is missing a required source or coordinate field.');
end

% The surface and optimizer must refer to the same reviewed snapshot artifact.
surfaceSnapshotPath = canonicalPath(metadata.sourceUltrasoundFile);
optimizerSnapshotPath = canonicalPath(referenceSnapshotFilePath);
if ~strcmpi(surfaceSnapshotPath, optimizerSnapshotPath) || ...
        string(metadata.sourceUltrasoundVariable) ~= "validSnapshots"
    error('prepareBoneSurfaceMeasurements:SurfaceSourceMismatch', ...
          'Bone surfaces were not created from the configured validSnapshots input.');
end

% Readable named fields avoid relying on an ambiguous free-text convention.
coordinateConvention = metadata.coordinateConvention;
coordinateFields = {'indexBase', 'coordinateOrder', ...
    'imageAxisByCoordinate', 'origin'};
if ~isstruct(coordinateConvention) || ...
        ~all(isfield(coordinateConvention, coordinateFields)) || ...
        coordinateConvention.indexBase ~= 1 || ...
        ~isequal(string(coordinateConvention.coordinateOrder), ["x", "y"]) || ...
        ~isequal(string(coordinateConvention.imageAxisByCoordinate), ...
                 ["column", "row"]) || ...
        string(coordinateConvention.origin) ~= "topLeftPixelCenter"
    error('prepareBoneSurfaceMeasurements:UnsupportedCoordinateConvention', ...
          'Bone surfaces must use one-based [x,y] = [column,row] image coordinates.');
end

% The beam fields make the meaning of increasing image rows explicit.
beamAxis = metadata.beamAxis;
beamDirection = metadata.beamDirection;
if ~isstruct(beamAxis) || ~isstruct(beamDirection) || ...
        ~all(isfield(beamAxis, {'name', 'matlabDimension'})) || ...
        ~all(isfield(beamDirection, {'name', 'rowIndexStep'})) || ...
        string(beamAxis.name) ~= "row" || beamAxis.matlabDimension ~= 1 || ...
        string(beamDirection.name) ~= "increasingRowIndex" || ...
        beamDirection.rowIndexStep ~= 1
    error('prepareBoneSurfaceMeasurements:UnsupportedBeamConvention', ...
          'Bone surfaces must use increasing row index as the beam direction.');
end
end


function validateSurfaceMeasurement(measurement, imageIndex)
%VALIDATESURFACEMEASUREMENT Check the basic 2D and 3D surface record shape.
% measurement is one matched tool result, imageIndex identifies it in errors,
% and this function returns no output.

% Only fields needed to identify and consume the measurement are required here.
requiredFields = {'sourceIndex', 'status', ...
    'surfaceCoordinatesXY', 'surfaceCoordinatesXYZRef'};
if ~isstruct(measurement) || ~all(isfield(measurement, requiredFields))
    error('prepareBoneSurfaceMeasurements:InvalidSurfaceRecord', ...
          'Surface record for image %d is missing a required field.', imageIndex);
end

% Preserve the three statuses produced by the extraction tool. An empty surface
% is valid input and a future cost model can decide how it should be scored.
allowedStatuses = ["extracted", "noSurface", "skippedUnprocessed"];
if ~any(string(measurement.status) == allowedStatuses)
    error('prepareBoneSurfaceMeasurements:InvalidSurfaceStatus', ...
          'Surface record for image %d has unsupported status %s.', ...
          imageIndex, string(measurement.status));
end

surfaceCoordinatesXY = measurement.surfaceCoordinatesXY;
surfacePointsRef      = measurement.surfaceCoordinatesXYZRef;

% The two arrays describe the same points before and after conversion to ref.
if ~isnumeric(surfaceCoordinatesXY) || size(surfaceCoordinatesXY, 2) ~= 2 || ...
        ~isnumeric(surfacePointsRef) || size(surfacePointsRef, 2) ~= 3 || ...
        size(surfaceCoordinatesXY, 1) ~= size(surfacePointsRef, 1) || ...
        ~all(isfinite(surfaceCoordinatesXY), 'all') || ...
        ~all(isfinite(surfacePointsRef), 'all')
    error('prepareBoneSurfaceMeasurements:InvalidSurfaceCoordinates', ...
          'Surface record for image %d must contain matching finite N-by-2 and N-by-3 coordinates.', ...
          imageIndex);
end
end


function absolutePath = canonicalPath(filePath)
%CANONICALPATH Return one normalized absolute filesystem path.
% filePath is a character vector or string scalar and absolutePath is the
% canonical character path used for provenance comparisons.

absolutePath = char(java.io.File(char(filePath)).getCanonicalPath());
end
