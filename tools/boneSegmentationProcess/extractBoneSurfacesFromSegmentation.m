function [surfaceResults, extractionMetadata] = extractBoneSurfacesFromSegmentation( ...
        segmentationResults, ultrasoundSequence, options)
%EXTRACTBONESURFACESFROMSEGMENTATION Estimate thin bone-surface curves.
% This function converts cleaned boundary coordinates into one or more thin
% surface segments. It scores only the supplied coordinates in the matching
% raw B-mode image, then uses global continuity and bounded curvature to select
% a stable probe-facing bone surface.
%
% Inputs:
%   segmentationResults : Struct vector exported by the semi-automatic bone
%                         segmentation tool. Each entry must contain
%                         sequencePosition, sourceIndex, pixelCoordinates, and
%                         status. pixelCoordinates uses [row,column] order.
%   ultrasoundSequence  : Struct vector containing sourceIndex and plane. The
%                         plane must contain image, W, H, nRows, and nCols.
%   options             : Optional scalar struct whose fields override the
%                         JSON defaults in configs/boneSurfaceExtraction.json.
%
% Outputs:
%   surfaceResults      : Struct vector aligned with segmentationResults. Each
%                         entry contains the extracted surface, confidence,
%                         segment labels, physical spacing, and summary values.
%   extractionMetadata : Scalar struct describing the algorithm, coordinate
%                        convention, creation time, and resolved configuration.

if nargin < 3
    options = struct();
end

% Resolve one complete configuration before validating inputs so every frame
% is processed with the same documented settings.
resolvedOptions = resolveExtractionOptions(options);

% Match frames by sourceIndex so reordered ultrasound inputs cannot silently
% attach boundary coordinates to the wrong B-mode image.
ultrasoundMatchIndices = validateAndMatchInputs( ...
    segmentationResults, ultrasoundSequence);

% Preallocate one output record per segmentation entry to preserve the input
% order expected by downstream processing.
numberOfResults = numel(segmentationResults);
surfaceResults = repmat(createSurfaceResultTemplate(), 1, numberOfResults);

for resultIndex = 1:numberOfResults
    segmentationEntry = segmentationResults(resultIndex);
    ultrasoundEntry = ultrasoundSequence(ultrasoundMatchIndices(resultIndex));

    % Validate and align the stored packet before checking status. This keeps
    % skipped outputs correctly sized and catches corrupt source files early.
    [displayedImage, candidateMask, pixelSpacingXYMm] = prepareFrameData( ...
        segmentationEntry, ultrasoundEntry, resultIndex);

    numberOfColumns = size(displayedImage, 2);
    currentResult = createEmptySizedResult( ...
        segmentationEntry, numberOfColumns, pixelSpacingXYMm);

    if ~strcmpi(char(string(segmentationEntry.status)), 'processed')
        % Unprocessed coordinates are not evidence that no bone exists, so preserve
        % that distinction instead of reporting a successful empty extraction.
        currentResult.status = 'skippedUnprocessed';
        surfaceResults(resultIndex) = currentResult;
        continue;
    end

    if ~any(candidateMask(:))
        % A processed record with no exported candidates is a valid no-surface
        % outcome. A documentation mask must never override this decision.
        currentResult.status = 'noSurface';
        surfaceResults(resultIndex) = currentResult;
        continue;
    end

    % Estimate evidence only at exported coordinates, then choose one globally
    % consistent depth from the competing boundary points in each scan line.
    candidateConfidence = computeCandidateConfidence( ...
        displayedImage, candidateMask, pixelSpacingXYMm, resolvedOptions);
    frameSurface = traceSurfacePaths( ...
        candidateConfidence, candidateMask, pixelSpacingXYMm, ...
        resolvedOptions, segmentationEntry.sourceIndex);

    currentResult.surfaceRowByColumn = frameSurface.surfaceRowByColumn;
    currentResult.rawSurfaceRowByColumn = ...
        frameSurface.rawSurfaceRowByColumn;
    currentResult.observedColumnMask = frameSurface.observedColumnMask;
    currentResult.interpolatedColumnMask = frameSurface.interpolatedColumnMask;
    currentResult.segmentIdByColumn = frameSurface.segmentIdByColumn;
    currentResult.confidenceByColumn = frameSurface.confidenceByColumn;
    currentResult.rawConfidenceByColumn = ...
        frameSurface.rawConfidenceByColumn;
    currentResult.regularizationDisplacementMmByColumn = ...
        frameSurface.regularizationDisplacementMmByColumn;
    currentResult.regularizationBoundHitColumnMask = ...
        frameSurface.regularizationBoundHitColumnMask;
    currentResult.regularizationStatus = ...
        frameSurface.regularizationStatus;
    currentResult.roughnessBeforePerMm = ...
        frameSurface.roughnessBeforePerMm;
    currentResult.roughnessAfterPerMm = ...
        frameSurface.roughnessAfterPerMm;
    currentResult.regularizationRmsDisplacementMm = ...
        frameSurface.regularizationRmsDisplacementMm;
    currentResult.regularizationMaxDisplacementMm = ...
        frameSurface.regularizationMaxDisplacementMm;
    currentResult.observedLengthMm = frameSurface.observedLengthMm;
    currentResult.interpolatedLengthMm = frameSurface.interpolatedLengthMm;
    currentResult.meanConfidence = frameSurface.meanConfidence;
    currentResult.numberOfSegments = frameSurface.numberOfSegments;

    validColumns = find(isfinite(frameSurface.surfaceRowByColumn));
    currentResult.surfacePixelCoordinatesXY = [ ...
        double(validColumns(:)), ...
        frameSurface.surfaceRowByColumn(validColumns).'];

    if isempty(validColumns)
        currentResult.status = 'noSurface';
    else
        currentResult.status = 'extracted';
    end

    surfaceResults(resultIndex) = currentResult;
end

% Record reproducibility information once rather than duplicating it in every
% per-frame result.
extractionMetadata = buildExtractionMetadata( ...
    resolvedOptions, surfaceResults);
end


function resolvedOptions = resolveExtractionOptions(options)
%RESOLVEEXTRACTIONOPTIONS Load JSON defaults and apply caller overrides.
% The JSON file remains the visible source of default settings, while callers
% and tests may override selected values without editing that file.
%
% Input:
%   options         : Empty value or scalar struct containing option overrides.
%
% Output:
%   resolvedOptions : Validated scalar struct containing every required option.

configurationPath = fullfile( ...
    fileparts(mfilename('fullpath')), 'configs', ...
    'boneSurfaceExtraction.json');

if ~isfile(configurationPath)
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'Default configuration file was not found: %s', configurationPath);
end

try
    defaultOptions = jsondecode(fileread(configurationPath));
catch configurationError
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'Could not read the default configuration: %s', ...
        configurationError.message);
end

if isempty(options)
    options = struct();
end
if ~isstruct(options) || ~isscalar(options)
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'options must be an empty value or a scalar struct.');
end

% Reject unknown names because a misspelled parameter would otherwise appear
% to work while leaving the intended default unchanged.
defaultFieldNames = fieldnames(defaultOptions);
overrideFieldNames = fieldnames(options);
unknownFields = setdiff(overrideFieldNames, defaultFieldNames);
if ~isempty(unknownFields)
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'Unknown extraction option: %s', unknownFields{1});
end

resolvedOptions = defaultOptions;
for fieldIndex = 1:numel(overrideFieldNames)
    currentField = overrideFieldNames{fieldIndex};
    resolvedOptions.(currentField) = options.(currentField);
end

resolvedOptions = validateExtractionOptions(resolvedOptions);
end


function options = validateExtractionOptions(options)
%VALIDATEEXTRACTIONOPTIONS Check ranges and normalize option text values.
% Validation prevents invalid physical windows or weights from producing a
% plausible-looking but meaningless surface.
%
% Input:
%   options : Scalar struct containing the complete extraction configuration.
%
% Output:
%   options : The validated configuration with interpolationMethod as char.

positiveFields = { ...
    'gaussianSigmaMm', 'ridgeSigmaMm', 'gradientSearchMarginMm', ...
    'shadowStartMm', 'shadowLengthMm', 'smoothnessWeight', ...
    'regularizationHalfResponseWavelengthMm', ...
    'regularizationHuberDeltaMm', ...
    'regularizationMaxDisplacementMm', ...
    'regularizationConvergenceMm'};
for fieldIndex = 1:numel(positiveFields)
    validateFiniteScalar(options.(positiveFields{fieldIndex}), ...
        positiveFields{fieldIndex}, true);
end

nonnegativeFields = { ...
    'positionWeight', 'reflectionWeight', 'shadowWeight', ...
    'minimumObservedSegmentLengthMm', 'maxInterpolatedGapMm'};
for fieldIndex = 1:numel(nonnegativeFields)
    validateFiniteScalar(options.(nonnegativeFields{fieldIndex}), ...
        nonnegativeFields{fieldIndex}, false);
end

unitIntervalFields = { ...
    'evidenceThreshold', 'minimumMeanSegmentConfidence', ...
    'fallbackConfidenceScale'};
for fieldIndex = 1:numel(unitIntervalFields)
    currentName = unitIntervalFields{fieldIndex};
    currentValue = options.(currentName);
    validateFiniteScalar(currentValue, currentName, false);
    if currentValue < 0 || currentValue > 1
        error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
            '%s must be between 0 and 1.', currentName);
    end
end

if options.shadowLengthMm <= options.shadowStartMm
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'shadowLengthMm must be greater than shadowStartMm.');
end

if options.positionWeight + options.reflectionWeight + ...
        options.shadowWeight <= 0
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'At least one candidate-evidence weight must be positive.');
end

% Keep the refinement switch strict so text or nonscalar values cannot
% accidentally enable a numerical stage that the caller meant to disable.
if ~islogical(options.regularizationEnabled) || ...
        ~isscalar(options.regularizationEnabled)
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'regularizationEnabled must be a logical scalar.');
end

minimumDataWeight = options.regularizationMinimumDataWeight;
validateFiniteScalar(minimumDataWeight, ...
    'regularizationMinimumDataWeight', true);
if minimumDataWeight > 1
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'regularizationMinimumDataWeight must be no greater than 1.');
end

maximumIterations = options.regularizationMaximumIterations;
if ~isnumeric(maximumIterations) || ~isscalar(maximumIterations) || ...
        ~isreal(maximumIterations) || ~isfinite(maximumIterations) || ...
        maximumIterations < 1 || maximumIterations ~= fix(maximumIterations)
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        ['regularizationMaximumIterations must be a positive integer ' ...
        'numeric scalar.']);
end
options.regularizationMaximumIterations = double(maximumIterations);

% The default refinement uses quadprog for bounded convex subproblems. Fail
% before processing frames when the requested dependency is unavailable.
if options.regularizationEnabled && exist('quadprog', 'file') ~= 2
    error('extractBoneSurfacesFromSegmentation:MissingDependency', ...
        ['regularizationEnabled requires quadprog from MATLAB ' ...
        'Optimization Toolbox.']);
end

percentiles = options.normalizationPercentiles;
if ~isnumeric(percentiles) || numel(percentiles) ~= 2 || ...
        any(~isfinite(percentiles(:))) || percentiles(1) < 0 || ...
        percentiles(2) > 100 || percentiles(1) >= percentiles(2)
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        ['normalizationPercentiles must contain two increasing finite ' ...
        'values between 0 and 100.']);
end
options.normalizationPercentiles = double(reshape(percentiles, 1, 2));

if ~(ischar(options.interpolationMethod) || ...
        (isstring(options.interpolationMethod) && ...
        isscalar(options.interpolationMethod)))
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'interpolationMethod must be text.');
end
options.interpolationMethod = lower(char(string(options.interpolationMethod)));
if ~ismember(options.interpolationMethod, {'linear', 'pchip'})
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        'interpolationMethod must be either "linear" or "pchip".');
end
end


function validateFiniteScalar(value, fieldName, requirePositive)
%VALIDATEFINITESCALAR Validate one numeric scalar option.
% This small helper keeps all scalar-option errors consistent and readable.
%
% Inputs:
%   value           : Candidate numeric option value.
%   fieldName       : Name used in an explanatory error message.
%   requirePositive : True requires value > 0; false permits value == 0.
%
% Outputs:
%   None. The function throws an error when validation fails.

isValid = isnumeric(value) && isscalar(value) && isreal(value) && ...
    isfinite(value);
if requirePositive
    isValid = isValid && value > 0;
else
    isValid = isValid && value >= 0;
end

if ~isValid
    if requirePositive
        rangeDescription = 'positive';
    else
        rangeDescription = 'nonnegative';
    end
    error('extractBoneSurfacesFromSegmentation:InvalidOptions', ...
        '%s must be a finite %s numeric scalar.', ...
        fieldName, rangeDescription);
end
end


function ultrasoundMatchIndices = validateAndMatchInputs( ...
        segmentationResults, ultrasoundSequence)
%VALIDATEANDMATCHINPUTS Validate arrays and match frames by sourceIndex.
% Matching by an explicit identifier protects the extraction from reordered
% arrays and from accidental use of an unrelated ultrasound file.
%
% Inputs:
%   segmentationResults : Candidate segmentation-result struct vector.
%   ultrasoundSequence  : Candidate source-ultrasound struct vector.
%
% Output:
%   ultrasoundMatchIndices : Index into ultrasoundSequence for every
%                            segmentationResults entry.

requiredSegmentationFields = { ...
    'sequencePosition', 'sourceIndex', 'pixelCoordinates', 'status'};
if ~isstruct(segmentationResults) || ~isvector(segmentationResults) || ...
        isempty(segmentationResults) || ...
        ~all(isfield(segmentationResults, requiredSegmentationFields))
    error('extractBoneSurfacesFromSegmentation:InvalidSegmentationResults', ...
        ['segmentationResults must be a non-empty struct vector containing ' ...
        'sequencePosition, sourceIndex, pixelCoordinates, and status.']);
end

if ~isstruct(ultrasoundSequence) || ~isvector(ultrasoundSequence) || ...
        isempty(ultrasoundSequence) || ...
        ~all(isfield(ultrasoundSequence, {'sourceIndex', 'plane'}))
    error('extractBoneSurfacesFromSegmentation:InvalidUltrasoundSequence', ...
        ['ultrasoundSequence must be a non-empty struct vector containing ' ...
        'sourceIndex and plane.']);
end

segmentationSourceIndices = zeros(1, numel(segmentationResults));
for resultIndex = 1:numel(segmentationResults)
    currentSourceIndex = segmentationResults(resultIndex).sourceIndex;
    if ~isnumeric(currentSourceIndex) || ~isscalar(currentSourceIndex) || ...
            ~isreal(currentSourceIndex) || ~isfinite(currentSourceIndex)
        error('extractBoneSurfacesFromSegmentation:InvalidSegmentationResults', ...
            'Segmentation sourceIndex at entry %d must be finite and scalar.', ...
            resultIndex);
    end
    segmentationSourceIndices(resultIndex) = double(currentSourceIndex);

    currentSequencePosition = ...
        segmentationResults(resultIndex).sequencePosition;
    currentStatus = segmentationResults(resultIndex).status;
    if ~isnumeric(currentSequencePosition) || ...
            ~isscalar(currentSequencePosition) || ...
            ~isreal(currentSequencePosition) || ...
            ~isfinite(currentSequencePosition) || ...
            ~(ischar(currentStatus) || ...
            (isstring(currentStatus) && isscalar(currentStatus)))
        error('extractBoneSurfacesFromSegmentation:InvalidSegmentationResults', ...
            ['sequencePosition must be a finite scalar and status must be ' ...
            'text at segmentation entry %d.'], resultIndex);
    end
end

ultrasoundSourceIndices = zeros(1, numel(ultrasoundSequence));
for imageIndex = 1:numel(ultrasoundSequence)
    currentSourceIndex = ultrasoundSequence(imageIndex).sourceIndex;
    if ~isnumeric(currentSourceIndex) || ~isscalar(currentSourceIndex) || ...
            ~isreal(currentSourceIndex) || ~isfinite(currentSourceIndex)
        error('extractBoneSurfacesFromSegmentation:InvalidUltrasoundSequence', ...
            'Ultrasound sourceIndex at entry %d must be finite and scalar.', ...
            imageIndex);
    end
    ultrasoundSourceIndices(imageIndex) = double(currentSourceIndex);
end

if numel(unique(segmentationSourceIndices)) ~= ...
        numel(segmentationSourceIndices)
    error(['extractBoneSurfacesFromSegmentation:' ...
        'DuplicateSegmentationSourceIndex'], ...
        'segmentationResults contains duplicate sourceIndex values.');
end
if numel(unique(ultrasoundSourceIndices)) ~= numel(ultrasoundSourceIndices)
    error(['extractBoneSurfacesFromSegmentation:' ...
        'DuplicateUltrasoundSourceIndex'], ...
        'ultrasoundSequence contains duplicate sourceIndex values.');
end

[hasMatchingImage, ultrasoundMatchIndices] = ismember( ...
    segmentationSourceIndices, ultrasoundSourceIndices);
if ~all(hasMatchingImage)
    missingIndex = find(~hasMatchingImage, 1, 'first');
    error('extractBoneSurfacesFromSegmentation:MissingSourceImage', ...
        'No ultrasound image matches segmentation sourceIndex %g.', ...
        segmentationSourceIndices(missingIndex));
end
end


function [displayedImage, candidateMask, pixelSpacingXYMm] = ...
        prepareFrameData(segmentationEntry, ultrasoundEntry, resultIndex)
%PREPAREFRAMEDATA Align one B-mode image and rasterize coordinate candidates.
% The acquisition stores image packets as [width,height], so one transpose is
% required to reproduce the segmentation tool's [row,column] display space.
% The candidate raster is built only from pixelCoordinates; documentation masks
% are deliberately neither read nor validated by the extractor.
%
% Inputs:
%   segmentationEntry : One segmentationResults record.
%   ultrasoundEntry   : Matching ultrasoundSequence record.
%   resultIndex       : One-based result position used in error messages.
%
% Outputs:
%   displayedImage    : Double B-mode image normalized to [0,1].
%   candidateMask     : Sparse logical mask containing only supplied candidates.
%   pixelSpacingXYMm  : [xSpacing,ySpacing] in millimetres per pixel.

plane = ultrasoundEntry.plane;
requiredPlaneFields = {'image', 'W', 'H', 'nRows', 'nCols'};
if ~isstruct(plane) || ~isscalar(plane) || ...
        ~all(isfield(plane, requiredPlaneFields))
    error('extractBoneSurfacesFromSegmentation:InvalidUltrasoundSequence', ...
        'Ultrasound plane for result %d lacks required geometry fields.', ...
        resultIndex);
end

storedImage = plane.image;
if ~isnumeric(storedImage) || ~ismatrix(storedImage) || ...
        isempty(storedImage) || ~isreal(storedImage) || ...
        any(~isfinite(double(storedImage(:)))) || ...
        any(double(storedImage(:)) < 0) || ...
        any(double(storedImage(:)) > 255)
    error('extractBoneSurfacesFromSegmentation:InvalidUltrasoundSequence', ...
        'plane.image for result %d must be a finite 2D image in [0,255].', ...
        resultIndex);
end

hasValidW = isnumeric(plane.W) && isscalar(plane.W) && ...
    isreal(plane.W) && isfinite(plane.W) && plane.W > 0;
hasValidH = isnumeric(plane.H) && isscalar(plane.H) && ...
    isreal(plane.H) && isfinite(plane.H) && plane.H > 0;
hasValidRows = isnumeric(plane.nRows) && isscalar(plane.nRows) && ...
    isreal(plane.nRows) && isfinite(plane.nRows) && ...
    plane.nRows > 1 && plane.nRows == round(plane.nRows);
hasValidColumns = isnumeric(plane.nCols) && isscalar(plane.nCols) && ...
    isreal(plane.nCols) && isfinite(plane.nCols) && ...
    plane.nCols > 1 && plane.nCols == round(plane.nCols);
if ~(hasValidW && hasValidH && hasValidRows && hasValidColumns)
    error('extractBoneSurfacesFromSegmentation:InvalidPlaneGeometry', ...
        ['plane W/H must be positive and nRows/nCols must be integer values ' ...
        'greater than one for result %d.'], resultIndex);
end

displayedImageSize = size(storedImage.');
if ~isequal(displayedImageSize, [plane.nRows, plane.nCols])
    error('extractBoneSurfacesFromSegmentation:InvalidPlaneGeometry', ...
        ['The transpose of plane.image does not match plane.nRows and ' ...
        'plane.nCols for result %d.'], resultIndex);
end

displayedImage = double(storedImage.') / 255;
candidateMask = buildCandidateMask( ...
    segmentationEntry.pixelCoordinates, displayedImageSize, resultIndex);

% Use pixel-centre endpoint spacing so physical gap and error thresholds use
% the same plane extent as current project visualization code.
pixelSpacingXYMm = [ ...
    double(plane.W) / (double(plane.nCols) - 1), ...
    double(plane.H) / (double(plane.nRows) - 1)];
end


function candidateMask = buildCandidateMask( ...
        pixelCoordinates, imageSize, resultIndex)
%BUILDCANDIDATEMASK Validate and rasterize authoritative boundary coordinates.
% The sparse raster lets existing image and dynamic-programming operations work
% efficiently without treating filled segmentation pixels as surface choices.
%
% Inputs:
%   pixelCoordinates : N-by-2 numeric [row,column] candidate coordinates.
%   imageSize        : [numberOfRows,numberOfColumns] of the displayed image.
%   resultIndex      : One-based result position used in validation messages.
%
% Output:
%   candidateMask : Image-sized logical raster containing unique candidates.

% Require the exported coordinate convention exactly. In particular, a plain
% empty array is ambiguous; exporters should preserve the documented 0-by-2
% shape when a processed frame has no candidate surface pixels.
if ~isnumeric(pixelCoordinates) || ~isreal(pixelCoordinates) || ...
        ~ismatrix(pixelCoordinates) || size(pixelCoordinates, 2) ~= 2
    error('extractBoneSurfacesFromSegmentation:InvalidPixelCoordinates', ...
        ['pixelCoordinates at result %d must be a numeric N-by-2 ' ...
        '[row,column] array.'], resultIndex);
end

coordinateValues = double(pixelCoordinates);
if any(~isfinite(coordinateValues(:))) || ...
        any(coordinateValues(:) ~= round(coordinateValues(:)))
    error('extractBoneSurfacesFromSegmentation:InvalidPixelCoordinates', ...
        ['pixelCoordinates at result %d must contain finite integer ' ...
        '[row,column] values.'], resultIndex);
end

if any(coordinateValues(:, 1) < 1) || ...
        any(coordinateValues(:, 1) > imageSize(1)) || ...
        any(coordinateValues(:, 2) < 1) || ...
        any(coordinateValues(:, 2) > imageSize(2))
    error('extractBoneSurfacesFromSegmentation:InvalidPixelCoordinates', ...
        ['pixelCoordinates at result %d must lie inside the displayed ' ...
        'image bounds.'], resultIndex);
end

candidateMask = false(imageSize);
if isempty(coordinateValues)
    return;
end

% Raster assignment naturally removes duplicates and makes extraction
% independent of the order in which boundary points were exported.
linearIndices = sub2ind(imageSize, ...
    coordinateValues(:, 1), coordinateValues(:, 2));
candidateMask(linearIndices) = true;
end


function resultTemplate = createSurfaceResultTemplate()
%CREATESURFACERESULTTEMPLATE Define the stable public result fields.
% One shared template guarantees that every status exposes the same interface
% and can be concatenated into a MATLAB struct array.
%
% Inputs:
%   None.
%
% Output:
%   resultTemplate : Scalar struct containing initialized public fields.

resultTemplate = struct( ...
    'sequencePosition', [], ...
    'sourceIndex', [], ...
    'status', 'noSurface', ...
    'surfacePixelCoordinatesXY', zeros(0, 2), ...
    'surfaceRowByColumn', nan(1, 0), ...
    'rawSurfaceRowByColumn', nan(1, 0), ...
    'observedColumnMask', false(1, 0), ...
    'interpolatedColumnMask', false(1, 0), ...
    'segmentIdByColumn', zeros(1, 0, 'uint16'), ...
    'confidenceByColumn', nan(1, 0), ...
    'rawConfidenceByColumn', nan(1, 0), ...
    'regularizationDisplacementMmByColumn', nan(1, 0), ...
    'regularizationBoundHitColumnMask', false(1, 0), ...
    'regularizationStatus', 'notApplicable', ...
    'roughnessBeforePerMm', nan, ...
    'roughnessAfterPerMm', nan, ...
    'regularizationRmsDisplacementMm', nan, ...
    'regularizationMaxDisplacementMm', nan, ...
    'pixelSpacingXYMm', [nan, nan], ...
    'observedLengthMm', 0, ...
    'interpolatedLengthMm', 0, ...
    'meanConfidence', nan, ...
    'numberOfSegments', 0);
end


function currentResult = createEmptySizedResult( ...
        segmentationEntry, numberOfColumns, pixelSpacingXYMm)
%CREATEEMPTYSIZEDRESULT Initialize one output with image-sized vectors.
% Sized empty vectors let downstream code distinguish missing values by NaN
% without separately reopening the source image to learn its width.
%
% Inputs:
%   segmentationEntry : One source segmentation record.
%   numberOfColumns   : Number of lateral image columns.
%   pixelSpacingXYMm  : [xSpacing,ySpacing] in millimetres.
%
% Output:
%   currentResult     : Initialized scalar surface-result struct.

currentResult = createSurfaceResultTemplate();
currentResult.sequencePosition = segmentationEntry.sequencePosition;
currentResult.sourceIndex = segmentationEntry.sourceIndex;
currentResult.surfaceRowByColumn = nan(1, numberOfColumns);
currentResult.rawSurfaceRowByColumn = nan(1, numberOfColumns);
currentResult.observedColumnMask = false(1, numberOfColumns);
currentResult.interpolatedColumnMask = false(1, numberOfColumns);
currentResult.segmentIdByColumn = zeros(1, numberOfColumns, 'uint16');
currentResult.confidenceByColumn = nan(1, numberOfColumns);
currentResult.rawConfidenceByColumn = nan(1, numberOfColumns);
currentResult.regularizationDisplacementMmByColumn = ...
    nan(1, numberOfColumns);
currentResult.regularizationBoundHitColumnMask = ...
    false(1, numberOfColumns);
currentResult.pixelSpacingXYMm = pixelSpacingXYMm;
end


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

startOffsetRows = max(1, ceil(options.shadowStartMm / ySpacingMm));
endOffsetRows = max(startOffsetRows, ...
    floor(options.shadowLengthMm / ySpacingMm));
offsetRows = startOffsetRows:endOffsetRows;
offsetDistancesMm = offsetRows * ySpacingMm;
shadowSigmaMm = max(options.shadowLengthMm / 2, ySpacingMm);
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
    rawShadow, candidateMask, options.normalizationPercentiles);
end


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


function peakIndex = findFirstPeak(values)
%FINDFIRSTPEAK Find the first local maximum in a one-dimensional response.
% The global maximum is used only when a monotonic or very short response has
% no local maximum, matching the extraction plan's explicit fallback.
%
% Input:
%   values    : Non-empty numeric vector ordered from shallow to deep.
%
% Output:
%   peakIndex : One-based index of the selected peak within values.

values = values(:);
numberOfValues = numel(values);
if numberOfValues == 1
    peakIndex = 1;
    return;
end

if values(1) >= values(2)
    peakIndex = 1;
    return;
end

for valueIndex = 2:(numberOfValues - 1)
    if values(valueIndex) >= values(valueIndex - 1) && ...
            values(valueIndex) > values(valueIndex + 1)
        peakIndex = valueIndex;
        return;
    end
end

if values(end) > values(end - 1)
    peakIndex = numberOfValues;
else
    [~, peakIndex] = max(values);
end
end


function normalizedFeature = robustNormalizeFeature( ...
        featureImage, sampleMask, percentiles)
%ROBUSTNORMALIZEFEATURE Scale one image feature using candidate percentiles.
% Percentile clipping avoids a few extreme speckle values controlling all
% confidences, while a constant feature becomes neutral evidence rather than
% producing NaN or forcing rejection.
%
% Inputs:
%   featureImage  : Numeric feature image.
%   sampleMask   : Logical coordinates used to estimate the robust range.
%   percentiles   : [lower,upper] percentile values.
%
% Output:
%   normalizedFeature : Image-sized feature in [0,1], zero outside the mask.

maskValues = double(featureImage(sampleMask));
lowerValue = prctile(maskValues, percentiles(1));
upperValue = prctile(maskValues, percentiles(2));
normalizedFeature = zeros(size(featureImage));

if upperValue <= lowerValue + eps(max(abs([lowerValue, upperValue, 1])))
    % A constant feature carries no preference, so use neutral evidence.
    normalizedFeature(sampleMask) = 0.5;
    return;
end

normalizedFeature = (double(featureImage) - lowerValue) / ...
    (upperValue - lowerValue);
normalizedFeature = min(max(normalizedFeature, 0), 1);
normalizedFeature(~sampleMask) = 0;
end


function frameSurface = traceSurfacePaths( ...
        candidateConfidence, candidateMask, pixelSpacingXYMm, options, ...
        sourceIndex)
%TRACESURFACEPATHS Select, interpolate, and curvature-refine surface paths.
% Active columns separated by at most the configured physical gap remain in
% one dynamic-programming problem so continuity constrains both sides. A
% bounded second stage removes pixel-scale bending while allowing the final
% approximation to leave an unreliable segmentation region.
%
% Inputs:
%   candidateConfidence : Image-sized candidate confidence in [0,1].
%   candidateMask       : Sparse raster of authoritative boundary candidates.
%   pixelSpacingXYMm    : [xSpacing,ySpacing] in millimetres.
%   options             : Validated extraction configuration.
%   sourceIndex         : Source-frame identifier used in fallback warnings.
%
% Output:
%   frameSurface        : Scalar struct containing column-wise surface data.

numberOfRows = size(candidateMask, 1);
numberOfColumns = size(candidateMask, 2);
xSpacingMm = pixelSpacingXYMm(1);
ySpacingMm = pixelSpacingXYMm(2);

% The exported coordinates are authoritative, so a low image score must not
% create a new gap. Retain every listed point but apply the existing threshold
% as a soft confidence penalty. DP can still use global continuity to recover a
% weak local echo, while consistently weak segments remain rejectable below.
belowThresholdMask = candidateMask & ...
    candidateConfidence < options.evidenceThreshold;
candidateConfidence(belowThresholdMask) = ...
    options.fallbackConfidenceScale ^ 2 * ...
    candidateConfidence(belowThresholdMask);
activeColumns = find(any(candidateMask, 1));

observedRows = nan(1, numberOfColumns);
observedConfidence = nan(1, numberOfColumns);

if ~isempty(activeColumns)
    missingGapMm = (diff(activeColumns) - 1) * xSpacingMm;
    groupStarts = [1, find(missingGapMm > ...
        options.maxInterpolatedGapMm) + 1];
    groupEnds = [groupStarts(2:end) - 1, numel(activeColumns)];

    for groupIndex = 1:numel(groupStarts)
        groupColumns = activeColumns( ...
            groupStarts(groupIndex):groupEnds(groupIndex));
        [groupRows, groupConfidence] = traceOneActiveGroup( ...
            groupColumns, candidateConfidence, candidateMask, ...
            xSpacingMm, ySpacingMm, options);

        % Gate on actual observed support rather than endpoint span, because a
        % small number of points separated by a wide gap is not a long surface.
        observedSupportMm = numel(groupColumns) * xSpacingMm;
        meanGroupConfidence = mean(groupConfidence);
        if observedSupportMm < options.minimumObservedSegmentLengthMm || ...
                meanGroupConfidence < options.minimumMeanSegmentConfidence
            continue;
        end

        observedRows(groupColumns) = groupRows;
        observedConfidence(groupColumns) = groupConfidence;
    end
end

[rawSurfaceRows, rawConfidenceByColumn, interpolatedMask, segmentIds] = ...
    interpolateAcceptedGaps(observedRows, observedConfidence, ...
    numberOfRows, xSpacingMm, options);
observedMask = isfinite(observedRows);

% The DP is not allowed to invent an observed raw location. Guard this public
% contract explicitly so future scoring changes cannot widen the candidate set.
observedColumns = find(observedMask);
observedLinearIndices = sub2ind(size(candidateMask), ...
    observedRows(observedColumns), observedColumns);
assert(all(candidateMask(observedLinearIndices)), ...
    'Every observed raw point must match an exported pixel coordinate.');

% The coordinate-constrained DP/PCHIP result remains the auditable raw trace.
% Refinement is bounded only by raw displacement and image dimensions.
[surfaceRows, confidenceByColumn, regularizationDiagnostics] = ...
    regularizeSurfaceSegments(rawSurfaceRows, rawConfidenceByColumn, ...
    observedMask, interpolatedMask, segmentIds, numberOfRows, ...
    pixelSpacingXYMm, options, sourceIndex);
validMask = isfinite(surfaceRows);

observedConfidenceValues = confidenceByColumn(observedMask);
if isempty(observedConfidenceValues)
    meanConfidence = nan;
else
    meanConfidence = mean(observedConfidenceValues);
end

frameSurface = struct( ...
    'surfaceRowByColumn', surfaceRows, ...
    'rawSurfaceRowByColumn', rawSurfaceRows, ...
    'observedColumnMask', observedMask, ...
    'interpolatedColumnMask', interpolatedMask, ...
    'segmentIdByColumn', segmentIds, ...
    'confidenceByColumn', confidenceByColumn, ...
    'rawConfidenceByColumn', rawConfidenceByColumn, ...
    'regularizationDisplacementMmByColumn', ...
        regularizationDiagnostics.displacementMmByColumn, ...
    'regularizationBoundHitColumnMask', ...
        regularizationDiagnostics.boundHitColumnMask, ...
    'regularizationStatus', regularizationDiagnostics.status, ...
    'roughnessBeforePerMm', ...
        regularizationDiagnostics.roughnessBeforePerMm, ...
    'roughnessAfterPerMm', ...
        regularizationDiagnostics.roughnessAfterPerMm, ...
    'regularizationRmsDisplacementMm', ...
        regularizationDiagnostics.rmsDisplacementMm, ...
    'regularizationMaxDisplacementMm', ...
        regularizationDiagnostics.maxDisplacementMm, ...
    'observedLengthMm', nnz(observedMask) * xSpacingMm, ...
    'interpolatedLengthMm', nnz(interpolatedMask) * xSpacingMm, ...
    'meanConfidence', meanConfidence, ...
    'numberOfSegments', double(max([segmentIds, uint16(0)])));

% These invariants protect the public interface if future algorithm changes
% alter the path or interpolation implementation.
assert(~any(observedMask & interpolatedMask), ...
    'Observed and interpolated masks must be disjoint.');
assert(isequal(validMask, observedMask | interpolatedMask), ...
    'Finite surface rows must match observed or interpolated columns.');
end


function [selectedRows, selectedConfidence] = traceOneActiveGroup( ...
        activeColumns, candidateConfidence, candidateMask, ...
        xSpacingMm, ySpacingMm, options)
%TRACEONEACTIVEGROUP Find the minimum-cost path through one lateral group.
% Dynamic programming compares every mask row, including rows from multiple
% disconnected runs, and returns the globally best first-order smooth path.
%
% Inputs:
%   activeColumns       : Increasing vector of columns in one gap-bounded group.
%   candidateConfidence : Image-sized confidence map.
%   candidateMask       : Sparse raster of exported coordinate candidates.
%   xSpacingMm          : Lateral pixel spacing in millimetres.
%   ySpacingMm          : Axial pixel spacing in millimetres.
%   options             : Validated extraction configuration.
%
% Outputs:
%   selectedRows       : One selected integer row per active column.
%   selectedConfidence : Local candidate confidence at each selected row.

numberOfActiveColumns = numel(activeColumns);
candidateRows = cell(1, numberOfActiveColumns);
backPointers = cell(1, numberOfActiveColumns);
smallValue = 1e-6;

firstColumn = activeColumns(1);
candidateRows{1} = find(candidateMask(:, firstColumn));
previousCosts = -log(max( ...
    candidateConfidence(candidateRows{1}, firstColumn), smallValue));
previousCosts = previousCosts(:);

for activeIndex = 2:numberOfActiveColumns
    currentColumn = activeColumns(activeIndex);
    previousColumn = activeColumns(activeIndex - 1);
    previousRows = candidateRows{activeIndex - 1};
    currentRows = find(candidateMask(:, currentColumn));
    candidateRows{activeIndex} = currentRows;

    endpointDistanceMm = (currentColumn - previousColumn) * xSpacingMm;
    depthDifferenceMm = ( ...
        double(currentRows(:).') - double(previousRows(:))) * ySpacingMm;
    slope = depthDifferenceMm / endpointDistanceMm;
    transitionCost = options.smoothnessWeight * ...
        (slope .^ 2) * endpointDistanceMm;

    accumulatedCosts = previousCosts + transitionCost;
    [bestPreviousCost, bestPreviousIndex] = min( ...
        accumulatedCosts, [], 1);
    currentDataCost = -log(max( ...
        candidateConfidence(currentRows, currentColumn), smallValue));
    previousCosts = currentDataCost(:) + bestPreviousCost(:);
    backPointers{activeIndex} = bestPreviousIndex(:);
end

[~, selectedStateIndex] = min(previousCosts);
selectedRows = zeros(1, numberOfActiveColumns);
selectedRows(end) = candidateRows{end}(selectedStateIndex);

for activeIndex = numberOfActiveColumns:-1:2
    selectedStateIndex = backPointers{activeIndex}(selectedStateIndex);
    selectedRows(activeIndex - 1) = ...
        candidateRows{activeIndex - 1}(selectedStateIndex);
end

linearIndices = sub2ind(size(candidateConfidence), ...
    selectedRows, activeColumns);
selectedConfidence = candidateConfidence(linearIndices);
end


function [surfaceRows, confidenceByColumn, interpolatedMask, segmentIds] = ...
        interpolateAcceptedGaps(observedRows, observedConfidence, ...
        numberOfRows, xSpacingMm, options)
%INTERPOLATEACCEPTEDGAPS Fill bounded gaps and label separate surface segments.
% Interpolation never changes observed rows and never extrapolates past the
% first or last observed point of a retained segment.
%
% Inputs:
%   observedRows       : One-by-columns selected observed rows with NaN gaps.
%   observedConfidence : One-by-columns observed confidence with NaN gaps.
%   numberOfRows       : Image height used to clamp interpolated values.
%   xSpacingMm         : Lateral pixel spacing in millimetres.
%   options            : Validated extraction configuration.
%
% Outputs:
%   surfaceRows       : Observed plus interpolated surface rows.
%   confidenceByColumn: Confidence at every finite surface column.
%   interpolatedMask  : Logical mask marking inferred columns only.
%   segmentIds        : Consecutive nonzero labels for retained segments.

numberOfColumns = numel(observedRows);
surfaceRows = observedRows;
confidenceByColumn = observedConfidence;
interpolatedMask = false(1, numberOfColumns);
segmentIds = zeros(1, numberOfColumns, 'uint16');
observedColumns = find(isfinite(observedRows));

if isempty(observedColumns)
    return;
end

missingGapMm = (diff(observedColumns) - 1) * xSpacingMm;
segmentStarts = [1, find(missingGapMm > ...
    options.maxInterpolatedGapMm) + 1];
segmentEnds = [segmentStarts(2:end) - 1, numel(observedColumns)];

for segmentIndex = 1:numel(segmentStarts)
    currentObservedColumns = observedColumns( ...
        segmentStarts(segmentIndex):segmentEnds(segmentIndex));
    fullSegmentColumns = currentObservedColumns(1): ...
        currentObservedColumns(end);

    if isscalar(currentObservedColumns)
        interpolatedRows = observedRows(currentObservedColumns);
    else
        interpolationMethod = options.interpolationMethod;
        if numel(currentObservedColumns) == 2
            % Two endpoints define a straight line; explicitly using linear
            % avoids implying curvature without supporting observations.
            interpolationMethod = 'linear';
        end
        interpolatedRows = interp1( ...
            double(currentObservedColumns), ...
            observedRows(currentObservedColumns), ...
            double(fullSegmentColumns), interpolationMethod);
    end

    interpolatedRows = min(max(interpolatedRows, 1), numberOfRows);
    surfaceRows(fullSegmentColumns) = interpolatedRows;
    segmentIds(fullSegmentColumns) = uint16(segmentIndex);

    currentInterpolated = ~isfinite(observedRows(fullSegmentColumns));
    interpolatedColumns = fullSegmentColumns(currentInterpolated);
    interpolatedMask(interpolatedColumns) = true;

    % Assign the requested confidence decay separately for each bounded gap.
    for endpointIndex = 1:(numel(currentObservedColumns) - 1)
        leftColumn = currentObservedColumns(endpointIndex);
        rightColumn = currentObservedColumns(endpointIndex + 1);
        if rightColumn <= leftColumn + 1
            continue;
        end

        gapColumns = (leftColumn + 1):(rightColumn - 1);
        gapLengthMm = numel(gapColumns) * xSpacingMm;
        endpointConfidence = min( ...
            observedConfidence(leftColumn), ...
            observedConfidence(rightColumn));
        confidenceByColumn(gapColumns) = endpointConfidence * ...
            exp(-gapLengthMm / options.maxInterpolatedGapMm);
    end
end
end


function [surfaceRows, confidenceByColumn, diagnostics] = ...
        regularizeSurfaceSegments(rawSurfaceRows, rawConfidenceByColumn, ...
        observedMask, interpolatedMask, segmentIds, numberOfImageRows, ...
        pixelSpacingXYMm, options, sourceIndex)
%REGULARIZESURFACESEGMENTS Refine raw paths with bounded curvature smoothing.
% The raw dynamic-programming path decides which probe-facing echo response is
% bone. This stage reduces rapid bending while allowing the final approximation
% to leave the sparse coordinate set within its raw-path and image bounds.
%
% Inputs:
%   rawSurfaceRows       : Raw DP/PCHIP row at each column, with NaN elsewhere.
%   rawConfidenceByColumn: Raw confidence at observed and interpolated columns.
%   observedMask         : Logical columns directly selected from image evidence.
%   interpolatedMask     : Logical columns filled across accepted short gaps.
%   segmentIds           : Nonzero segment label at each retained column.
%   numberOfImageRows    : Height of the displayed B-mode image.
%   pixelSpacingXYMm     : [xSpacing,ySpacing] in millimetres.
%   options              : Validated extraction and regularization settings.
%   sourceIndex          : Source-frame identifier used in fallback warnings.
%
% Outputs:
%   surfaceRows       : Final subpixel row at each retained column.
%   confidenceByColumn: Raw confidence reduced according to refinement movement
%                       and decayed across interpolated gaps.
%   diagnostics       : Scalar struct containing status, movement, bound-hit,
%                       and before/after roughness audit values.

surfaceRows = rawSurfaceRows;
confidenceByColumn = rawConfidenceByColumn;
validMask = isfinite(rawSurfaceRows);

% Signed movement retains direction for audit. Absent columns remain NaN so
% downstream code cannot mistake them for unchanged surface samples.
displacementMmByColumn = nan(size(rawSurfaceRows));
displacementMmByColumn(validMask) = 0;
boundHitColumnMask = false(size(rawSurfaceRows));

roughnessBeforePerMm = computeSurfaceRoughness( ...
    rawSurfaceRows, segmentIds, pixelSpacingXYMm);

if ~any(validMask)
    diagnostics = buildRegularizationDiagnostics( ...
        'notApplicable', displacementMmByColumn, boundHitColumnMask, ...
        roughnessBeforePerMm, roughnessBeforePerMm);
    return;
end

if ~options.regularizationEnabled
    % Disabled mode is an exact compatibility path, including confidence.
    diagnostics = buildRegularizationDiagnostics( ...
        'disabled', displacementMmByColumn, boundHitColumnMask, ...
        roughnessBeforePerMm, roughnessBeforePerMm);
    return;
end

segmentNumbers = unique(double(segmentIds(validMask)));
segmentNumbers(segmentNumbers == 0) = [];
numberAttempted = 0;
numberSucceeded = 0;
numberFailed = 0;

for segmentNumber = segmentNumbers(:).'
    segmentColumns = find(double(segmentIds) == segmentNumber);

    % Fewer than three columns cannot define a second derivative. Preserve
    % these rare short segments exactly as the legacy extraction produced them.
    if numel(segmentColumns) < 3
        continue;
    end

    numberAttempted = numberAttempted + 1;
    [refinedRows, segmentBoundHits, succeeded, failureMessage] = ...
        regularizeOneSurfaceSegment( ...
        rawSurfaceRows(segmentColumns), ...
        rawConfidenceByColumn(segmentColumns), ...
        observedMask(segmentColumns), numberOfImageRows, ...
        pixelSpacingXYMm, options);

    if succeeded
        numberSucceeded = numberSucceeded + 1;
        surfaceRows(segmentColumns) = refinedRows;
        boundHitColumnMask(segmentColumns) = segmentBoundHits;
        displacementMmByColumn(segmentColumns) = ...
            (refinedRows - rawSurfaceRows(segmentColumns)) * ...
            pixelSpacingXYMm(2);
    else
        % A numerical failure must never remove an otherwise valid surface.
        numberFailed = numberFailed + 1;
        warning( ...
            'extractBoneSurfacesFromSegmentation:RegularizationFallback', ...
            ['Regularization failed for sourceIndex %g, segment %d: %s ' ...
            'The raw path was retained.'], ...
            sourceIndex, segmentNumber, failureMessage);
    end
end

if numberAttempted == 0
    regularizationStatus = 'notApplicable';
elseif numberFailed == 0
    regularizationStatus = 'applied';
elseif numberSucceeded == 0
    regularizationStatus = 'fallback';
else
    regularizationStatus = 'partialFallback';
end

% The final location may leave the listed coordinates, so confidence derives
% from raw image support and decays monotonically with movement.
confidenceByColumn = applyDisplacementConfidenceDecay( ...
    rawConfidenceByColumn, displacementMmByColumn, observedMask, ...
    interpolatedMask, segmentIds, pixelSpacingXYMm(1), ...
    options.maxInterpolatedGapMm, ...
    options.regularizationMaxDisplacementMm);

roughnessAfterPerMm = computeSurfaceRoughness( ...
    surfaceRows, segmentIds, pixelSpacingXYMm);
diagnostics = buildRegularizationDiagnostics( ...
    regularizationStatus, displacementMmByColumn, boundHitColumnMask, ...
    roughnessBeforePerMm, roughnessAfterPerMm);
end


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


function confidenceByColumn = applyDisplacementConfidenceDecay( ...
        rawConfidenceByColumn, displacementMmByColumn, observedMask, ...
        interpolatedMask, segmentIds, xSpacingMm, maximumGapMm, ...
        maximumDisplacementMm)
%APPLYDISPLACEMENTCONFIDENCEDECAY Score support for the refined approximation.
% Observed confidence decreases exponentially as the final curve moves away
% from the raw image-supported location. Gap confidence retains the existing
% lower-endpoint decay after endpoint confidence has been adjusted.
%
% Inputs:
%   rawConfidenceByColumn   : Confidence before regularization.
%   displacementMmByColumn  : Signed refinement movement in millimetres.
%   observedMask            : Logical directly observed columns.
%   interpolatedMask        : Logical accepted-gap columns.
%   segmentIds              : Nonzero segment label at retained columns.
%   xSpacingMm              : Lateral pixel spacing in millimetres.
%   maximumGapMm            : Existing gap-confidence decay scale.
%   maximumDisplacementMm   : Refinement movement bound and decay scale.
%
% Output:
%   confidenceByColumn : Final confidence at observed and interpolated columns.

confidenceByColumn = rawConfidenceByColumn;
observedMovementMm = abs(displacementMmByColumn(observedMask));
confidenceByColumn(observedMask) = ...
    rawConfidenceByColumn(observedMask) .* ...
    exp(-observedMovementMm / maximumDisplacementMm);
confidenceByColumn(observedMask) = min(max( ...
    confidenceByColumn(observedMask), 0), 1);
confidenceByColumn(interpolatedMask) = nan;

segmentNumbers = unique(double(segmentIds(segmentIds > 0)));
for segmentNumber = segmentNumbers(:).'
    currentObservedColumns = find( ...
        double(segmentIds) == segmentNumber & observedMask);

    for endpointIndex = 1:(numel(currentObservedColumns) - 1)
        leftColumn = currentObservedColumns(endpointIndex);
        rightColumn = currentObservedColumns(endpointIndex + 1);
        if rightColumn <= leftColumn + 1
            continue;
        end

        gapColumns = (leftColumn + 1):(rightColumn - 1);
        gapColumns = gapColumns(interpolatedMask(gapColumns));
        if isempty(gapColumns)
            continue;
        end

        gapLengthMm = numel(gapColumns) * xSpacingMm;
        endpointConfidence = min( ...
            confidenceByColumn(leftColumn), ...
            confidenceByColumn(rightColumn));
        confidenceByColumn(gapColumns) = endpointConfidence * ...
            exp(-gapLengthMm / maximumGapMm);
    end
end
end


function roughnessPerMm = computeSurfaceRoughness( ...
        surfaceRows, segmentIds, pixelSpacingXYMm)
%COMPUTESURFACEROUGHNESS Measure RMS physical curvature over all segments.
% The second derivative ignores absolute depth and constant slope while
% responding strongly to rapid bending and pixel-scale branch excursions.
%
% Inputs:
%   surfaceRows      : Row coordinate at retained columns, with NaN elsewhere.
%   segmentIds       : Nonzero segment label at retained columns.
%   pixelSpacingXYMm : [xSpacing,ySpacing] in millimetres.
%
% Output:
%   roughnessPerMm : RMS d2y/dx2 in inverse millimetres, or NaN when no segment
%                    contains at least three points.

xSpacingMm = pixelSpacingXYMm(1);
ySpacingMm = pixelSpacingXYMm(2);
curvatureValues = zeros(0, 1);
segmentNumbers = unique(double(segmentIds(segmentIds > 0)));

for segmentNumber = segmentNumbers(:).'
    segmentRows = surfaceRows(double(segmentIds) == segmentNumber);
    if numel(segmentRows) < 3
        continue;
    end

    segmentDepthMm = double(segmentRows(:)) * ySpacingMm;
    currentCurvature = diff(segmentDepthMm, 2) / (xSpacingMm ^ 2);
    curvatureValues = [curvatureValues; currentCurvature]; %#ok<AGROW>
end

if isempty(curvatureValues)
    roughnessPerMm = nan;
else
    roughnessPerMm = sqrt(mean(curvatureValues .^ 2));
end
end


function diagnostics = buildRegularizationDiagnostics( ...
        status, displacementMmByColumn, boundHitColumnMask, ...
        roughnessBeforePerMm, roughnessAfterPerMm)
%BUILDREGULARIZATIONDIAGNOSTICS Summarize one frame's refinement outcome.
% Centralizing this summary keeps empty, disabled, successful, and fallback
% frames consistent for downstream audit code.
%
% Inputs:
%   status                        : Text status for the frame refinement.
%   displacementMmByColumn        : Signed movement, with NaN when absent.
%   boundHitColumnMask            : Logical columns ending on a hard bound.
%   roughnessBeforePerMm          : RMS physical curvature before refinement.
%   roughnessAfterPerMm           : RMS physical curvature after refinement.
%
% Output:
%   diagnostics : Scalar struct containing public regularization diagnostics.

finiteDisplacements = displacementMmByColumn( ...
    isfinite(displacementMmByColumn));
if isempty(finiteDisplacements)
    rmsDisplacementMm = nan;
    maxDisplacementMm = nan;
else
    rmsDisplacementMm = sqrt(mean(finiteDisplacements .^ 2));
    maxDisplacementMm = max(abs(finiteDisplacements));
end

diagnostics = struct( ...
    'status', status, ...
    'displacementMmByColumn', displacementMmByColumn, ...
    'boundHitColumnMask', boundHitColumnMask, ...
    'roughnessBeforePerMm', roughnessBeforePerMm, ...
    'roughnessAfterPerMm', roughnessAfterPerMm, ...
    'rmsDisplacementMm', rmsDisplacementMm, ...
    'maxDisplacementMm', maxDisplacementMm);
end


function extractionMetadata = buildExtractionMetadata(options, surfaceResults)
%BUILDEXTRACTIONMETADATA Create reproducibility metadata for a completed run.
% Source filenames are added by the orchestration script because array inputs
% alone do not retain the MAT-file paths from which they were loaded.
%
% Inputs:
%   options        : Resolved extraction configuration.
%   surfaceResults : Completed per-frame surface result array.
%
% Output:
%   extractionMetadata : Scalar metadata struct for saving with results.

statuses = {surfaceResults.status};
regularizationStatuses = {surfaceResults.regularizationStatus};
regularizationStatusCounts = struct( ...
    'applied', nnz(strcmp(regularizationStatuses, 'applied')), ...
    'disabled', nnz(strcmp(regularizationStatuses, 'disabled')), ...
    'notApplicable', ...
        nnz(strcmp(regularizationStatuses, 'notApplicable')), ...
    'partialFallback', ...
        nnz(strcmp(regularizationStatuses, 'partialFallback')), ...
    'fallback', nnz(strcmp(regularizationStatuses, 'fallback')));
extractionMetadata = struct( ...
    'algorithmName', ...
        'pixelCoordinateGradientPeakShadowDynamicProgrammingRawBoundedCurvature', ...
    'algorithmVersion', '1.2.0', ...
    'createdAt', char(datetime('now', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ss')), ...
    'coordinateConvention', ...
        ['MATLAB 1-based [x,y] = [column,row], origin at the ' ...
        'top-left pixel centre'], ...
    'beamAxis', 'row', ...
    'beamDirection', 'increasing row', ...
    'candidateSource', 'segmentationResults.pixelCoordinates', ...
    'candidateCoordinateConvention', ...
        'MATLAB 1-based [row,column] integer image coordinates', ...
    'segmentationMaskRole', 'not consumed by extractor', ...
    'positionLikelihoodDefinition', ...
        ['coordinate-local strongest positive axial gradient to first ' ...
        'intensity peak, evaluated only at exported coordinates'], ...
    'evidenceThresholdDefinition', ...
        ['listed coordinates remain DP candidates; confidence below the ' ...
        'threshold receives the squared fallback-confidence penalty'], ...
    'meanConfidenceDefinition', ...
        ['mean raw observed confidence with exponential final-path ' ...
        'displacement decay'], ...
    'confidenceByColumnDefinition', ...
        ['observed raw confidence multiplied by exp(-absolute displacement/' ...
        'maximum displacement); interpolated confidence uses the adjusted ' ...
        'endpoint minimum and configured gap-length decay'], ...
    'resolvedConfiguration', options, ...
    'regularizationStatusCounts', regularizationStatusCounts, ...
    'numberOfFrames', numel(surfaceResults), ...
    'numberExtracted', nnz(strcmp(statuses, 'extracted')), ...
    'numberNoSurface', nnz(strcmp(statuses, 'noSurface')), ...
    'numberSkippedUnprocessed', ...
        nnz(strcmp(statuses, 'skippedUnprocessed')));
end
