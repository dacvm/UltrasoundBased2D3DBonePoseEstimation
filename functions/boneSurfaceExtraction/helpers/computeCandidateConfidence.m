function candidateConfidence = computeCandidateConfidence( ...
        displayedImage, candidateMask, pixelSpacingXYMm, options)
%COMPUTECANDIDATECONFIDENCE Score only exported bone-boundary coordinates.
% The score combines coordinate-local gradient-to-first-peak position, bright
% ridge, and distal acoustic shadow as a weighted geometric mean in [0,1].
%
% Inputs:
%   displayedImage   : Double B-mode image normalized to [0,1].
%   candidateMask    : Sparse logical raster of exported coordinates.
%   pixelSpacingXYMm : [xSpacing,ySpacing] in millimetres.
%   options          : Validated extraction configuration.
%
% Output:
%   candidateConfidence : Image-sized map, zero outside listed coordinates.

xSpacingMm = pixelSpacingXYMm(1);
ySpacingMm = pixelSpacingXYMm(2);

% Smooth in physical units so the same settings remain meaningful when image
% dimensions or pixel aspect ratio change.
smoothedImage = imgaussfilt(displayedImage, [ ...
    options.gaussianSigmaMm / ySpacingMm, ...
    options.gaussianSigmaMm / xSpacingMm], 'Padding', 'replicate');
ridgeSmoothedImage = imgaussfilt(displayedImage, [ ...
    options.ridgeSigmaMm / ySpacingMm, ...
    options.ridgeSigmaMm / xSpacingMm], 'Padding', 'replicate');

% A negative Laplacian identifies a bright ridge centre. Physical derivative
% scaling keeps row and column contributions comparable.
secondDerivativeRows = imfilter(ridgeSmoothedImage, ...
    [1; -2; 1] / (ySpacingMm ^ 2), 'replicate', 'corr', 'same');
secondDerivativeColumns = imfilter(ridgeSmoothedImage, ...
    [1, -2, 1] / (xSpacingMm ^ 2), 'replicate', 'corr', 'same');
positiveRidge = max(0, -(secondDerivativeRows + secondDerivativeColumns));

normalizedIntensity = robustNormalizeFeature( ...
    smoothedImage, candidateMask, options.normalizationPercentiles);
normalizedRidge = robustNormalizeFeature( ...
    positiveRidge, candidateMask, options.normalizationPercentiles);
reflectionLikelihood = 0.5 * (normalizedIntensity + normalizedRidge);

shadowLikelihood = computeShadowLikelihood( ...
    smoothedImage, candidateMask, ySpacingMm, options);
positionLikelihood = computePositionLikelihood( ...
    smoothedImage, candidateMask, ySpacingMm, options);

% Use a geometric mean so configuration weights change feature importance
% without changing confidence scale or the meaning of evidenceThreshold.
smallValue = 1e-6;
totalWeight = options.positionWeight + options.reflectionWeight + ...
    options.shadowWeight;
weightedLogEvidence = ...
    options.positionWeight * log(max(positionLikelihood, smallValue)) + ...
    options.reflectionWeight * log(max(reflectionLikelihood, smallValue)) + ...
    options.shadowWeight * log(max(shadowLikelihood, smallValue));
candidateConfidence = exp(weightedLogEvidence / totalWeight);
candidateConfidence(~candidateMask) = 0;
candidateConfidence = min(max(candidateConfidence, 0), 1);
end
