function inputMatches = validateAndMatchInputs( ...
        segmentationResults, ultrasoundSequence)
%VALIDATEANDMATCHINPUTS Validate grouped inputs and build composite mappings.
% Exact group metadata and group-local source indices prevent a record from
% being paired with another directory when sourceIndex values repeat globally.
%
% Inputs:
%   segmentationResults : Grouped segmentation-result struct vector.
%   ultrasoundSequence  : Grouped source-ultrasound struct vector.
%
% Output:
%   inputMatches : Struct vector in segmentation group order. Each entry stores
%                  the matching ultrasound group and local record indices.

requiredGroupFields = {'name', 'bone', 'path', 'data'};
validateGroupedArrayShape( ...
    segmentationResults, requiredGroupFields, ...
    'extractBoneSurfacesFromSegmentation:InvalidSegmentationResults', ...
    'segmentationResults');
validateGroupedArrayShape( ...
    ultrasoundSequence, requiredGroupFields, ...
    'extractBoneSurfacesFromSegmentation:InvalidUltrasoundSequence', ...
    'ultrasoundSequence');

% A one-to-one metadata match requires the two artifacts to retain the same
% number of source-directory groups, even when their outer order differs.
if numel(segmentationResults) ~= numel(ultrasoundSequence)
    error('extractBoneSurfacesFromSegmentation:GroupSetMismatch', ...
        ['segmentationResults and ultrasoundSequence must contain the same ' ...
        'set of source-directory groups.']);
end

[segmentationNames, segmentationBones, segmentationPaths] = ...
    readGroupMetadata( ...
        segmentationResults, ...
        'extractBoneSurfacesFromSegmentation:InvalidSegmentationResults', ...
        'segmentationResults');
[ultrasoundNames, ultrasoundBones, ultrasoundPaths] = ...
    readGroupMetadata( ...
        ultrasoundSequence, ...
        'extractBoneSurfacesFromSegmentation:InvalidUltrasoundSequence', ...
        'ultrasoundSequence');

validateUniqueGroupIdentities( ...
    segmentationNames, segmentationBones, segmentationPaths, ...
    'extractBoneSurfacesFromSegmentation:DuplicateSegmentationGroupIdentity', ...
    'segmentationResults');
validateUniqueGroupIdentities( ...
    ultrasoundNames, ultrasoundBones, ultrasoundPaths, ...
    'extractBoneSurfacesFromSegmentation:DuplicateUltrasoundGroupIdentity', ...
    'ultrasoundSequence');

numberOfGroups = numel(segmentationResults);
segmentationSourceIndicesByGroup = cell(1, numberOfGroups);
ultrasoundSourceIndicesByGroup = cell(1, numberOfGroups);
totalSegmentationRecords = 0;

% Validate every group-local record before creating any cross-input mapping.
for groupIndex = 1:numberOfGroups
    segmentationSourceIndicesByGroup{groupIndex} = ...
        validateSegmentationGroupData( ...
            segmentationResults(groupIndex).data, groupIndex);
    totalSegmentationRecords = totalSegmentationRecords + ...
        numel(segmentationSourceIndicesByGroup{groupIndex});

    ultrasoundSourceIndicesByGroup{groupIndex} = ...
        validateUltrasoundGroupData( ...
            ultrasoundSequence(groupIndex).data, groupIndex);
end

if totalSegmentationRecords == 0
    error('extractBoneSurfacesFromSegmentation:NoSegmentationRecords', ...
        'At least one segmentationResults group must contain data records.');
end

matchTemplate = struct( ...
    'ultrasoundGroupIndex', [], ...
    'ultrasoundLocalIndices', zeros(1, 0));
inputMatches = repmat(matchTemplate, 1, numberOfGroups);
usedUltrasoundGroups = false(1, numberOfGroups);

for segmentationGroupIndex = 1:numberOfGroups
    % Match the exact normalized metadata tuple while preserving segmentation
    % group order as the public output order.
    matchingGroupMask = ...
        ultrasoundNames == segmentationNames(segmentationGroupIndex) & ...
        ultrasoundBones == segmentationBones(segmentationGroupIndex) & ...
        ultrasoundPaths == segmentationPaths(segmentationGroupIndex);
    matchingUltrasoundGroup = find(matchingGroupMask);
    if numel(matchingUltrasoundGroup) ~= 1
        error('extractBoneSurfacesFromSegmentation:GroupSetMismatch', ...
            ['No unique ultrasound group matches segmentation group %d ' ...
            '(%s, %s, %s).'], ...
            segmentationGroupIndex, ...
            segmentationNames(segmentationGroupIndex), ...
            segmentationBones(segmentationGroupIndex), ...
            segmentationPaths(segmentationGroupIndex));
    end
    usedUltrasoundGroups(matchingUltrasoundGroup) = true;

    segmentationSourceIndices = ...
        segmentationSourceIndicesByGroup{segmentationGroupIndex};
    ultrasoundSourceIndices = ...
        ultrasoundSourceIndicesByGroup{matchingUltrasoundGroup};
    [hasMatchingImage, ultrasoundLocalIndices] = ismember( ...
        segmentationSourceIndices, ultrasoundSourceIndices);

    % Both directions and equal counts are checked so neither artifact may
    % silently contain an unused or missing frame inside a matched group.
    hasExactFrameSet = ...
        numel(segmentationSourceIndices) == numel(ultrasoundSourceIndices) && ...
        all(hasMatchingImage) && ...
        all(ismember(ultrasoundSourceIndices, segmentationSourceIndices));
    if ~hasExactFrameSet
        error('extractBoneSurfacesFromSegmentation:FrameSetMismatch', ...
            ['Group "%s" must contain identical group-local sourceIndex ' ...
            'sets in segmentationResults and ultrasoundSequence.'], ...
            segmentationNames(segmentationGroupIndex));
    end

    inputMatches(segmentationGroupIndex).ultrasoundGroupIndex = ...
        matchingUltrasoundGroup;
    inputMatches(segmentationGroupIndex).ultrasoundLocalIndices = ...
        ultrasoundLocalIndices;
end

if ~all(usedUltrasoundGroups)
    error('extractBoneSurfacesFromSegmentation:GroupSetMismatch', ...
        ['segmentationResults and ultrasoundSequence must contain the same ' ...
        'set of source-directory groups.']);
end
end


function validateGroupedArrayShape( ...
        groupedData, requiredGroupFields, errorIdentifier, inputName)
%VALIDATEGROUPEDARRAYSHAPE Require the grouped-only outer data contract.
% This helper gives obsolete flat arrays a clear error before record fields are
% interpreted as globally unique identities.
%
% Inputs:
%   groupedData         : Candidate outer grouped value.
%   requiredGroupFields : Required name, bone, path, and data field names.
%   errorIdentifier     : Public error identifier for this input type.
%   inputName           : Input name used in the validation message.
%
% Outputs:
%   None. The function throws when the grouped shape is invalid.

if ~isstruct(groupedData) || ~isvector(groupedData) || ...
        isempty(groupedData) || ...
        ~all(isfield(groupedData, requiredGroupFields))
    error(errorIdentifier, ...
        ['%s must be a non-empty grouped struct vector containing name, ' ...
        'bone, path, and data. Flat input is unsupported.'], inputName);
end
end


function [groupNames, groupBones, groupPaths] = readGroupMetadata( ...
        groupedData, errorIdentifier, inputName)
%READGROUPMETADATA Validate and normalize source-directory metadata.
% Character vectors and scalar strings are normalized only for exact matching;
% the original values remain untouched for grouped output.
%
% Inputs:
%   groupedData     : Candidate grouped struct vector.
%   errorIdentifier : Public error identifier for malformed metadata.
%   inputName       : Input name used in validation messages.
%
% Outputs:
%   groupNames : Row string vector of normalized group names.
%   groupBones : Row string vector of normalized bone labels.
%   groupPaths : Row string vector of normalized source paths.

numberOfGroups = numel(groupedData);
groupNames = strings(1, numberOfGroups);
groupBones = strings(1, numberOfGroups);
groupPaths = strings(1, numberOfGroups);

for groupIndex = 1:numberOfGroups
    metadataValues = { ...
        groupedData(groupIndex).name, ...
        groupedData(groupIndex).bone, ...
        groupedData(groupIndex).path};
    for metadataIndex = 1:numel(metadataValues)
        if ~isTextScalar(metadataValues{metadataIndex})
            error(errorIdentifier, ...
                '%s group %d name, bone, and path must be text scalars.', ...
                inputName, groupIndex);
        end
    end
    normalizedMetadata = string(metadataValues);
    if any(ismissing(normalizedMetadata)) || ...
            strlength(string(groupedData(groupIndex).name)) == 0 || ...
            strlength(string(groupedData(groupIndex).bone)) == 0
        error(errorIdentifier, ...
            '%s group %d name and bone must not be empty.', ...
            inputName, groupIndex);
    end

    groupNames(groupIndex) = string(groupedData(groupIndex).name);
    groupBones(groupIndex) = string(groupedData(groupIndex).bone);
    groupPaths(groupIndex) = string(groupedData(groupIndex).path);
end
end


function validateUniqueGroupIdentities( ...
        groupNames, groupBones, groupPaths, errorIdentifier, inputName)
%VALIDATEUNIQUEGROUPIDENTITIES Reject ambiguous outer metadata tuples.
% A duplicate `(name,bone,path)` tuple would prevent a deterministic group
% match even when the contained source indices differ.
%
% Inputs:
%   groupNames      : Normalized group-name string vector.
%   groupBones      : Normalized bone-label string vector.
%   groupPaths      : Normalized source-path string vector.
%   errorIdentifier : Public error identifier for duplicate identities.
%   inputName       : Input name used in the validation message.
%
% Outputs:
%   None. The function throws when a duplicate tuple is found.

for firstGroupIndex = 1:numel(groupNames)
    duplicateMask = ...
        groupNames == groupNames(firstGroupIndex) & ...
        groupBones == groupBones(firstGroupIndex) & ...
        groupPaths == groupPaths(firstGroupIndex);
    if nnz(duplicateMask) > 1
        error(errorIdentifier, ...
            '%s contains a duplicate identity at group %d.', ...
            inputName, firstGroupIndex);
    end
end
end


function sourceIndices = validateSegmentationGroupData(groupData, groupIndex)
%VALIDATESEGMENTATIONGROUPDATA Validate records inside one segmentation group.
% Required record fields and unique local source indices establish the first
% half of the composite group/record identity.
%
% Inputs:
%   groupData  : Candidate segmentation records for one group.
%   groupIndex : One-based outer group index used in error messages.
%
% Output:
%   sourceIndices : Row vector of validated numeric source indices.

requiredFields = { ...
    'sequencePosition', 'sourceIndex', 'pixelCoordinates', 'status'};
if ~isstruct(groupData) || (~isempty(groupData) && ~isvector(groupData)) || ...
        (~isempty(groupData) && ~all(isfield(groupData, requiredFields)))
    error('extractBoneSurfacesFromSegmentation:InvalidSegmentationResults', ...
        ['segmentationResults(%d).data must be a struct vector containing ' ...
        'sequencePosition, sourceIndex, pixelCoordinates, and status.'], ...
        groupIndex);
end

sourceIndices = zeros(1, numel(groupData));
for localIndex = 1:numel(groupData)
    currentSourceIndex = groupData(localIndex).sourceIndex;
    currentSequencePosition = groupData(localIndex).sequencePosition;
    currentStatus = groupData(localIndex).status;
    if ~isnumeric(currentSourceIndex) || ~isscalar(currentSourceIndex) || ...
            ~isreal(currentSourceIndex) || ~isfinite(currentSourceIndex)
        error('extractBoneSurfacesFromSegmentation:InvalidSegmentationResults', ...
            ['Segmentation sourceIndex at group %d, local position %d ' ...
            'must be a finite numeric scalar.'], groupIndex, localIndex);
    end
    if ~isnumeric(currentSequencePosition) || ...
            ~isscalar(currentSequencePosition) || ...
            ~isreal(currentSequencePosition) || ...
            ~isfinite(currentSequencePosition) || ...
            ~isTextScalar(currentStatus) || ...
            ismissing(string(currentStatus))
        error('extractBoneSurfacesFromSegmentation:InvalidSegmentationResults', ...
            ['sequencePosition must be a finite scalar and status must be ' ...
            'text at group %d, local position %d.'], groupIndex, localIndex);
    end
    sourceIndices(localIndex) = double(currentSourceIndex);
end

if numel(unique(sourceIndices)) ~= numel(sourceIndices)
    error(['extractBoneSurfacesFromSegmentation:' ...
        'DuplicateSegmentationSourceIndex'], ...
        'segmentationResults group %d contains duplicate sourceIndex values.', ...
        groupIndex);
end
end


function sourceIndices = validateUltrasoundGroupData(groupData, groupIndex)
%VALIDATEULTRASOUNDGROUPDATA Validate records inside one ultrasound group.
% Required record fields and unique local source indices establish the second
% half of the composite group/record identity.
%
% Inputs:
%   groupData  : Candidate ultrasound records for one group.
%   groupIndex : One-based outer group index used in error messages.
%
% Output:
%   sourceIndices : Row vector of validated numeric source indices.

requiredFields = {'sourceIndex', 'plane'};
if ~isstruct(groupData) || (~isempty(groupData) && ~isvector(groupData)) || ...
        (~isempty(groupData) && ~all(isfield(groupData, requiredFields)))
    error('extractBoneSurfacesFromSegmentation:InvalidUltrasoundSequence', ...
        ['ultrasoundSequence(%d).data must be a struct vector containing ' ...
        'sourceIndex and plane.'], groupIndex);
end

sourceIndices = zeros(1, numel(groupData));
for localIndex = 1:numel(groupData)
    currentSourceIndex = groupData(localIndex).sourceIndex;
    if ~isnumeric(currentSourceIndex) || ~isscalar(currentSourceIndex) || ...
            ~isreal(currentSourceIndex) || ~isfinite(currentSourceIndex)
        error('extractBoneSurfacesFromSegmentation:InvalidUltrasoundSequence', ...
            ['Ultrasound sourceIndex at group %d, local position %d ' ...
            'must be a finite numeric scalar.'], groupIndex, localIndex);
    end
    sourceIndices(localIndex) = double(currentSourceIndex);
end

if numel(unique(sourceIndices)) ~= numel(sourceIndices)
    error(['extractBoneSurfacesFromSegmentation:' ...
        'DuplicateUltrasoundSourceIndex'], ...
        'ultrasoundSequence group %d contains duplicate sourceIndex values.', ...
        groupIndex);
end
end


function isScalarText = isTextScalar(value)
%ISTEXTSCALAR Return whether a value is one character row or scalar string.
% Centralizing this small rule keeps grouped metadata and status validation
% consistent without converting malformed string arrays first.
%
% Input:
%   value : Candidate text value.
%
% Output:
%   isScalarText : True for a character row or scalar string; otherwise false.

isScalarText = ...
    (ischar(value) && (isrow(value) || isempty(value))) || ...
    (isstring(value) && isscalar(value));
end
