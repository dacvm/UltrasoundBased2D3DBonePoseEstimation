function collectedBoneSurface = collectBoneSurfaceMeasurements( ...
        surfaceOutput, targetBone)
%COLLECTBONESURFACEMEASUREMENTS Collect surface records for one bone.
% This function reads the already-loaded bone-surface tool output and
% flattens the selected groups into one measurement array. It is needed so
% surface preparation stays independent from snapshot matching.
%
% Inputs:
%   surfaceOutput - Struct loaded from the bone-surface MAT-file. It contains
%                   surfaceResults and extractionMetadata.
%   targetBone    - Bone code selected for optimization, such as T.
%
% Output:
%   collectedBoneSurface - Collected measurements and extraction metadata.
%                          Measurements remain in the artifact's order.

surfaceResults      = surfaceOutput.surfaceResults;
extractionMetadata = surfaceOutput.extractionMetadata;

% Select every surface group belonging to the requested bone.
surfaceGroupBones = upper(string({surfaceResults.bone}));
targetGroupIndices = find(surfaceGroupBones == upper(string(targetBone)));

% Count records first so collection remains easy to follow and does not grow
% the output array inside the nested loop.
numberOfMeasurements = 0;
for groupIndex = targetGroupIndices
    numberOfMeasurements = numberOfMeasurements + ...
        numel(surfaceResults(groupIndex).data);
end
measurementCells = cell(1, numberOfMeasurements);

% Flatten the selected groups while retaining the identity needed to match
% each measurement with its reviewed snapshot later.
outputIndex = 1;
for groupIndex = targetGroupIndices
    currentGroup = surfaceResults(groupIndex);
    for recordIndex = 1:numel(currentGroup.data)
        measurement = currentGroup.data(recordIndex);

        measurement.groupName = char(string(currentGroup.name));
        measurement.groupPath = char(string(currentGroup.path));
        measurement.bone      = char(string(currentGroup.bone));
        measurementCells{outputIndex} = measurement;
        outputIndex = outputIndex + 1;
    end
end

collectedBoneSurface.isAvailable        = true;
collectedBoneSurface.extractionMetadata = extractionMetadata;
collectedBoneSurface.measurements       = [measurementCells{:}];
end
