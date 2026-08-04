function shadowLikelihood = computeShadowLikelihood( ...
        smoothedImage, candidateMask, ySpacingMm, options)
%COMPUTESHADOWLIKELIHOOD Measure darkness distal to every possible surface.
% Gaussian weighting emphasizes the near shadow, while coverage blending makes
% candidates near the image bottom less certain instead of falsely perfect.
%
% Inputs:
%   smoothedImage : Smoothed normalized B-mode image.
%   candidateMask : Sparse logical raster of exported coordinates.
%   ySpacingMm    : Axial pixel spacing in millimetres.
%   options       : Validated extraction configuration.
%
% Output:
%   shadowLikelihood : Image-sized normalized shadow confidence in [0,1].

% Read all shadow-window settings from their image-evidence group.
imageEvidenceOptions = options.imageEvidence;
startOffsetRows = max(1, ceil( ...
    imageEvidenceOptions.shadowStartMm / ySpacingMm));
endOffsetRows = max(startOffsetRows, ...
    floor(imageEvidenceOptions.shadowLengthMm / ySpacingMm));
offsetRows = startOffsetRows:endOffsetRows;
offsetDistancesMm = offsetRows * ySpacingMm;
shadowSigmaMm = max(imageEvidenceOptions.shadowLengthMm / 2, ySpacingMm);
weights = exp(-0.5 * (offsetDistancesMm / shadowSigmaMm) .^ 2);

weightedIntensity = zeros(size(smoothedImage));
availableWeight = zeros(size(smoothedImage));
numberOfRows = size(smoothedImage, 1);

for offsetIndex = 1:numel(offsetRows)
    currentOffset = offsetRows(offsetIndex);
    if currentOffset >= numberOfRows
        continue;
    end

    targetRows = 1:(numberOfRows - currentOffset);
    sourceRows = (1 + currentOffset):numberOfRows;
    currentWeight = weights(offsetIndex);
    weightedIntensity(targetRows, :) = ...
        weightedIntensity(targetRows, :) + ...
        currentWeight * smoothedImage(sourceRows, :);
    availableWeight(targetRows, :) = ...
        availableWeight(targetRows, :) + currentWeight;
end

fullWeight = sum(weights);
hasShadowSamples = availableWeight > 0;
weightedMean = 0.5 * ones(size(smoothedImage));
weightedMean(hasShadowSamples) = ...
    weightedIntensity(hasShadowSamples) ./ ...
    availableWeight(hasShadowSamples);

% Missing distal support is blended toward neutral evidence (0.5). This keeps
% a short, dark truncated window from looking like a complete acoustic shadow.
coverage = min(availableWeight / max(fullWeight, eps), 1);
rawShadow = coverage .* (1 - weightedMean) + (1 - coverage) * 0.5;
shadowLikelihood = robustNormalizeFeature( ...
    rawShadow, candidateMask, ...
    imageEvidenceOptions.normalizationPercentiles);
end
