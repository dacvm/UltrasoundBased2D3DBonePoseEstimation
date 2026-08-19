function extractionMetadata = buildExtractionMetadata(surfaceResults)
%BUILDEXTRACTIONMETADATA Create simple metadata for extracted surfaces.
% This function records when the extraction ran, which algorithm version was
% used, and how many frames were handled. The orchestration script adds the
% input file information because this function receives arrays, not paths.
%
% Input:
%   surfaceResults : Completed grouped surface result array.
%
% Output:
%   extractionMetadata : Small scalar metadata struct saved with the results.

% Count every record, including extracted, empty, and skipped frames, because
% all of them belong to the input dataset used for this run.
numberOfFrames = sum(arrayfun( ...
    @(surfaceGroup) numel(surfaceGroup.data), surfaceResults));

% Keep this structure intentionally small so its purpose is clear when a
% junior developer inspects the saved MAT-file.
extractionMetadata = struct( ...
    'createdAt', char(datetime('now', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ss')), ...
    'algorithmVersion', '1.2.0', ...
    'numberOfFrames', numberOfFrames);
end
