function extractionMetadata = buildExtractionMetadata(surfaceResults)
%BUILDEXTRACTIONMETADATA Create simple metadata for extracted surfaces.
% This function records the run summary and the image-coordinate conventions
% needed to interpret the extracted points. The orchestration script adds the
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

% Describe how each saved [x,y] coordinate maps to a MATLAB image array.
% Compact string values remain readable while the separate fields allow later
% code to use the convention without parsing a sentence.
coordinateConvention = struct();
coordinateConvention.indexBase = 1;
coordinateConvention.coordinateOrder = ["x", "y"];
coordinateConvention.imageAxisByCoordinate = ["column", "row"];
coordinateConvention.origin = "topLeftPixelCenter";

% MATLAB stores image rows in dimension 1. The ultrasound beam moves toward
% larger row indices, so adding rowIndexStep advances one pixel in depth.
beamAxis = struct();
beamAxis.name = "row";
beamAxis.matlabDimension = 1;

beamDirection = struct();
beamDirection.name = "increasingRowIndex";
beamDirection.rowIndexStep = 1;

% Record the normal frame and polarity explicitly. This avoids relying on a
% reader to infer whether a normal points into the anatomy or toward the
% ultrasound probe.
normalConvention = struct;
normalConvention.coordinateFrame = 'imagePhysicalXY';
normalConvention.coordinateOrder = ["x", "y"];
normalConvention.unitLength = true;
normalConvention.polarity = 'towardProbe';
normalConvention.probeDirection = 'decreasingImageY';
normalConvention.estimator = 'segmentWiseCentralDifference';

% Keep this structure intentionally small so its purpose is clear when a
% junior developer inspects the saved MAT-file.
extractionMetadata = struct( ...
    'createdAt', char(datetime('now', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ss')), ...
    'algorithmVersion', '1.3.0', ...
    'numberOfFrames', numberOfFrames, ...
    'coordinateConvention', coordinateConvention, ...
    'beamAxis', beamAxis, ...
    'beamDirection', beamDirection, ...
    'normalConvention', normalConvention);
end
