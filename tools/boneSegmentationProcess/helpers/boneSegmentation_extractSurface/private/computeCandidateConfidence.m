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

% Keep the evidence-stage settings together locally so each use mirrors the
% matching imageEvidence group in the JSON configuration.
imageEvidenceOptions = options.imageEvidence;
evidenceWeights = imageEvidenceOptions.weights;

% Smooth in physical units so the same settings remain meaningful when image
% dimensions or pixel aspect ratio change.
smoothedImage = imgaussfilt(displayedImage, [ ...
    imageEvidenceOptions.gaussianSigmaMm / ySpacingMm, ...
    imageEvidenceOptions.gaussianSigmaMm / xSpacingMm], ...
    'Padding', 'replicate');
ridgeSmoothedImage = imgaussfilt(displayedImage, [ ...
    imageEvidenceOptions.ridgeSigmaMm / ySpacingMm, ...
    imageEvidenceOptions.ridgeSigmaMm / xSpacingMm], ...
    'Padding', 'replicate');

% A negative Laplacian identifies a bright ridge centre. Physical derivative
% scaling keeps row and column contributions comparable.
secondDerivativeRows = imfilter(ridgeSmoothedImage, ...
    [1; -2; 1] / (ySpacingMm ^ 2), 'replicate', 'corr', 'same');
secondDerivativeColumns = imfilter(ridgeSmoothedImage, ...
    [1, -2, 1] / (xSpacingMm ^ 2), 'replicate', 'corr', 'same');
positiveRidge = max(0, -(secondDerivativeRows + secondDerivativeColumns));

normalizedIntensity = robustNormalizeFeature( ...
    smoothedImage, candidateMask, ...
    imageEvidenceOptions.normalizationPercentiles);
normalizedRidge = robustNormalizeFeature( ...
    positiveRidge, candidateMask, ...
    imageEvidenceOptions.normalizationPercentiles);
reflectionLikelihood = 0.5 * (normalizedIntensity + normalizedRidge);

shadowLikelihood = computeShadowLikelihood( ...
    smoothedImage, candidateMask, ySpacingMm, options);
positionLikelihood = computePositionLikelihood( ...
    smoothedImage, candidateMask, ySpacingMm, options);

% Use a geometric mean so configuration weights change feature importance
% without changing confidence scale or the meaning of evidenceThreshold.
smallValue = 1e-6;
totalWeight = evidenceWeights.position + evidenceWeights.reflection + ...
    evidenceWeights.shadow;
weightedLogEvidence = ...
    evidenceWeights.position * log(max(positionLikelihood, smallValue)) + ...
    evidenceWeights.reflection * ...
        log(max(reflectionLikelihood, smallValue)) + ...
    evidenceWeights.shadow * log(max(shadowLikelihood, smallValue));
candidateConfidence = exp(weightedLogEvidence / totalWeight);
candidateConfidence(~candidateMask) = 0;
candidateConfidence = min(max(candidateConfidence, 0), 1);
end
