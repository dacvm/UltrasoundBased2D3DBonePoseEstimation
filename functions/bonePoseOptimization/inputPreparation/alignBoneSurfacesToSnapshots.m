function alignedBoneSurface = alignBoneSurfacesToSnapshots(collectedBoneSurface, snapshotSources, referenceSnapshotFilePath)
%ALIGNBONESURFACESTOSNAPSHOTS Align surfaces with reviewed snapshots.
% This function validates that collected surfaces came from the configured
% snapshot artifact and reorders them to match the prepared snapshot order.
% It is needed so image plane k and surface measurement k refer to one frame.
%
% Inputs:
%   collectedBoneSurface      - Surface measurements in artifact order, as
%                               returned by collectBoneSurfaceMeasurements.
%   snapshotSources           - Source identity for each prepared snapshot.
%   referenceSnapshotFilePath - Configured validSnapshots MAT-file path.
%
% Output:
%   alignedBoneSurface        - The same surface input with measurements
%                               reordered into snapshot order.

%% CHECK ARTIFACT PROVENANCE

metadata = collectedBoneSurface.extractionMetadata;
requiredFields = {'sourceUltrasoundFile', 'sourceUltrasoundVariable'};
if ~all(isfield(metadata, requiredFields))
    error('alignBoneSurfacesToSnapshots:MissingSourceMetadata', ...
          'Surface metadata must identify its source ultrasound artifact.');
end

% Compare normalized paths because the same file can be written with relative
% segments or different path separators.
surfaceSnapshotPath = canonicalPath(metadata.sourceUltrasoundFile);
referenceSnapshotPath = canonicalPath(referenceSnapshotFilePath);
if ~strcmpi(surfaceSnapshotPath, referenceSnapshotPath) || string(metadata.sourceUltrasoundVariable) ~= "validSnapshots"
    error('alignBoneSurfacesToSnapshots:SurfaceSourceMismatch', ...
          'Bone surfaces were not created from the configured validSnapshots input.');
end

%% ALIGN RECORDS BY SOURCE IDENTITY

measurements = collectedBoneSurface.measurements;
if numel(measurements) ~= numel(snapshotSources)
    error('alignBoneSurfacesToSnapshots:MeasurementCountMismatch', ...
          'Expected one bone-surface measurement for every prepared snapshot.');
end

% Cache identity arrays once so the matching loop reads like a simple join.
measurementGroupNames    = string({measurements.groupName});
measurementGroupPaths    = string({measurements.groupPath});
measurementSourceIndices = [measurements.sourceIndex];
alignedMeasurementCells  = cell(1, numel(snapshotSources));

for snapshotIndex = 1:numel(snapshotSources)
    source = snapshotSources(snapshotIndex);
    isMatch = measurementGroupNames == string(source.groupName) & ...
              measurementGroupPaths == string(source.groupPath) & ...
              measurementSourceIndices == source.sourceIndex;
    matchingIndices = find(isMatch);

    if numel(matchingIndices) ~= 1
        error('alignBoneSurfacesToSnapshots:SurfaceMatchFailed', ...
              'Expected one surface for snapshot %d, but found %d.', ...
              snapshotIndex, numel(matchingIndices));
    end

    alignedMeasurementCells{snapshotIndex} = measurements(matchingIndices);
end

% Return a clearly named aligned value rather than hiding the order change.
alignedBoneSurface = collectedBoneSurface;
alignedBoneSurface.measurements = [alignedMeasurementCells{:}];
end


function absolutePath = canonicalPath(filePath)
%CANONICALPATH Return one normalized absolute filesystem path.
% filePath is a character vector or string scalar and absolutePath is the
% canonical character path used for provenance comparisons.

absolutePath = char(java.io.File(char(filePath)).getCanonicalPath());
end
