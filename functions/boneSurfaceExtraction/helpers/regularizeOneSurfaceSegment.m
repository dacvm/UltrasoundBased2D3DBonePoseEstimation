function [refinedRows, boundHitMask, succeeded, failureMessage] = ...
        regularizeOneSurfaceSegment(rawRows, rawConfidence, ...
        observedMask, numberOfImageRows, pixelSpacingXYMm, options)
%REGULARIZEONESURFACESEGMENT Solve one raw-bounded curvature problem.
% Huber iteratively reweighted least squares limits the influence of isolated
% branch excursions. Quadprog enforces image limits and the maximum permitted
% displacement from the coordinate-constrained raw path.
%
% Inputs:
%   rawRows          : Raw DP/PCHIP rows for one complete retained segment.
%   rawConfidence    : Raw confidence at those columns.
%   observedMask     : Logical flags for image-observed segment columns.
%   numberOfImageRows: Height of the displayed B-mode image.
%   pixelSpacingXYMm : [xSpacing,ySpacing] in millimetres.
%   options          : Validated regularization settings.
%
% Outputs:
%   refinedRows   : Final subpixel rows, or raw rows on failure.
%   boundHitMask  : Logical points whose final depth touches a hard bound.
%   succeeded     : True when every attempted bounded quadratic solve succeeds.
%   failureMessage: Empty text on success; diagnostic reason on failure.

xSpacingMm = pixelSpacingXYMm(1);
ySpacingMm = pixelSpacingXYMm(2);
numberOfPoints = numel(rawRows);

% Depth zero is the centre of MATLAB row one. The only spatial constraints are
% image limits and the configured distance from the raw curve.
initialDepthMm = (double(rawRows(:)) - 1) * ySpacingMm;
maximumImageDepthMm = (numberOfImageRows - 1) * ySpacingMm;
lowerBoundsMm = max(0, initialDepthMm - ...
    options.regularizationMaxDisplacementMm);
upperBoundsMm = min(maximumImageDepthMm, initialDepthMm + ...
    options.regularizationMaxDisplacementMm);

refinedRows = rawRows;
boundHitMask = false(size(rawRows));
succeeded = false;
failureMessage = '';

% Physical d2z/dx2 has straight tilted lines in its null space, so curvature
% smoothing does not introduce a preference for horizontal bone surfaces.
secondDerivative = spdiags( ...
    [ones(numberOfPoints - 2, 1), ...
    -2 * ones(numberOfPoints - 2, 1), ...
    ones(numberOfPoints - 2, 1)], ...
    0:2, numberOfPoints - 2, numberOfPoints) / (xSpacingMm ^ 2);

baseWeights = zeros(numberOfPoints, 1);
observedConfidence = double(rawConfidence(observedMask));
observedConfidence(~isfinite(observedConfidence)) = 0;
baseWeights(observedMask(:)) = max( ...
    observedConfidence(:), options.regularizationMinimumDataWeight);

% This conversion gives the configured physical wavelength a clear meaning in
% the continuous smoothing response rather than making it resolution-specific.
alphaMm4 = (options.regularizationHalfResponseWavelengthMm / ...
    (2 * pi)) ^ 4;
currentDepthMm = initialDepthMm;
try
    quadraticOptions = optimoptions('quadprog', 'Display', 'off');
catch solverSetupError
    failureMessage = solverSetupError.message;
    return;
end

for iterationIndex = 1:options.regularizationMaximumIterations
    residualMagnitudeMm = abs(currentDepthMm - initialDepthMm);
    huberWeights = ones(numberOfPoints, 1);
    largeResidualMask = residualMagnitudeMm > ...
        options.regularizationHuberDeltaMm;
    huberWeights(largeResidualMask) = ...
        options.regularizationHuberDeltaMm ./ ...
        residualMagnitudeMm(largeResidualMask);
    effectiveWeights = baseWeights .* huberWeights;

    dataWeightMatrix = spdiags( ...
        effectiveWeights, 0, numberOfPoints, numberOfPoints);
    hessian = 2 * xSpacingMm * (dataWeightMatrix + ...
        alphaMm4 * (secondDerivative.' * secondDerivative));
    hessian = 0.5 * (hessian + hessian.');
    linearTerm = -2 * xSpacingMm * ...
        (effectiveWeights .* initialDepthMm);

    try
        [nextDepthMm, ~, exitFlag] = quadprog( ...
            hessian, linearTerm, [], [], [], [], ...
            lowerBoundsMm, upperBoundsMm, currentDepthMm, ...
            quadraticOptions);
    catch solverError
        failureMessage = solverError.message;
        return;
    end

    if exitFlag <= 0 || any(~isfinite(nextDepthMm))
        failureMessage = sprintf( ...
            'quadprog returned exit flag %d.', exitFlag);
        return;
    end

    maximumChangeMm = max(abs(nextDepthMm - currentDepthMm));
    currentDepthMm = nextDepthMm;
    succeeded = true;
    if maximumChangeMm < options.regularizationConvergenceMm
        break;
    end
end

% Reaching the IRLS iteration cap is not a solver failure. The last successful
% convex subproblem remains bounded and valid; only quadprog errors, nonpositive
% exit flags, or nonfinite solutions trigger the raw-path fallback above.

% Remove only negligible numerical bound violations before converting back to
% image rows. The analytical solution is already constrained by these bounds.
currentDepthMm = min(max( ...
    currentDepthMm, lowerBoundsMm), upperBoundsMm);
refinedRows = reshape(currentDepthMm / ySpacingMm + 1, size(rawRows));
boundToleranceMm = max(options.regularizationConvergenceMm, 1e-8);
boundHitMask = reshape( ...
    abs(currentDepthMm - lowerBoundsMm) <= boundToleranceMm | ...
    abs(currentDepthMm - upperBoundsMm) <= boundToleranceMm, ...
    size(rawRows));

end
