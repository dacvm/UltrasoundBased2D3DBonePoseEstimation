function positionLikelihood = computePositionLikelihood( ...
        smoothedImage, candidateMask, ySpacingMm, options)
%COMPUTEPOSITIONLIKELIHOOD Score each coordinate near a probe-facing first echo.
% Each exported point receives an independent local gradient-to-first-peak
% estimate. This preserves first-echo evidence without reconstructing, reading,
% or depending on a filled segmentation region.
%
% Inputs:
%   smoothedImage : Smoothed normalized B-mode image.
%   candidateMask : Sparse logical raster of exported coordinates.
%   ySpacingMm    : Axial pixel spacing in millimetres.
%   options       : Validated extraction configuration.
%
% Output:
%   positionLikelihood : Image-sized likelihood, nonzero only at candidates.

% Positive values mean brightness increases while travelling away from the
% probe along increasing rows.
depthGradient = imfilter(smoothedImage, ...
    [-1; 0; 1] / (2 * ySpacingMm), 'replicate', 'corr', 'same');
marginRows = max(1, round(options.gradientSearchMarginMm / ySpacingMm));
positionLikelihood = zeros(size(smoothedImage));

for columnIndex = 1:size(candidateMask, 2)
    candidateRows = find(candidateMask(:, columnIndex));
    numberOfCandidates = numel(candidateRows);
    gradientStrength = zeros(numberOfCandidates, 1);
    distanceLikelihood = ones(numberOfCandidates, 1);
    hasValidGradient = false(numberOfCandidates, 1);

    for candidateIndex = 1:numel(candidateRows)
        candidateRow = candidateRows(candidateIndex);

        % Only inspect gradients on the probe-facing side through the candidate
        % itself. A deeper boundary therefore cannot borrow a positive gradient
        % that occurs below it, while the true entrance remains available.
        gradientSearchStart = max(1, candidateRow - marginRows);
        gradientValues = depthGradient( ...
            gradientSearchStart:candidateRow, columnIndex);
        [strongestGradient, gradientOffset] = max(gradientValues);
        hasValidGradient(candidateIndex) = ...
            isfinite(strongestGradient) && strongestGradient > 0;

        if hasValidGradient(candidateIndex)
            gradientRow = gradientSearchStart + gradientOffset - 1;
            peakSearchEnd = min(size(smoothedImage, 1), ...
                candidateRow + marginRows);
            peakValues = smoothedImage( ...
                gradientRow:peakSearchEnd, columnIndex);
            peakOffset = findFirstPeak(peakValues);
            peakRow = gradientRow + peakOffset - 1;
            preferredRow = 0.5 * (gradientRow + peakRow);
            positionSigmaRows = max( ...
                options.ridgeSigmaMm / ySpacingMm, ...
                max(1, 0.5 * abs(peakRow - gradientRow)));
            gradientStrength(candidateIndex) = strongestGradient;
            distanceLikelihood(candidateIndex) = exp(-0.5 * ( ...
                (candidateRow - preferredRow) / positionSigmaRows) ^ 2);
        end
    end

    if any(hasValidGradient)
        % Relative gradient strength suppresses small positive fluctuations on
        % distal or side boundaries. Only candidates with genuine positive-rise
        % evidence compete when the column contains at least one such point.
        maximumGradient = max(gradientStrength);
        relativeGradientStrength = gradientStrength / maximumGradient;
        candidateLikelihood = ...
            relativeGradientStrength .* distanceLikelihood;
    else
        % When the entire column lacks a positive rise, retain all exported
        % coordinates with reduced evidence so geometry can provide a fallback.
        candidateLikelihood = options.fallbackConfidenceScale * ...
            ones(numberOfCandidates, 1);
    end

    positionLikelihood(candidateRows, columnIndex) = candidateLikelihood;
end
end
