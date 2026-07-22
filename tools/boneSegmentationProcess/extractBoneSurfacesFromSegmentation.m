function [surfaceResults, extractionMetadata] = extractBoneSurfacesFromSegmentation( ...
        segmentationResults, ultrasoundSequence, options)
%EXTRACTBONESURFACESFROMSEGMENTATION Estimate thin bone-surface curves.
% This function converts each accepted thick bone-response mask into one or
% more thin surface segments. It uses the matching raw B-mode image so the
% selected curve follows the first strong tissue-to-bone response and the
% acoustic shadow instead of following an arbitrary side of the mask.
%
% Inputs:
%   segmentationResults : Struct vector exported by the semi-automatic bone
%                         segmentation tool. Each processed entry must contain
%                         sourceIndex, segmentationMask, and status.
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
% attach a segmentation mask to the wrong B-mode image.
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
    [displayedImage, effectiveMask, pixelSpacingXYMm] = prepareFrameData( ...
        segmentationEntry, ultrasoundEntry, resultIndex);

    numberOfColumns = size(displayedImage, 2);
    currentResult = createEmptySizedResult( ...
        segmentationEntry, numberOfColumns, pixelSpacingXYMm);

    if ~strcmpi(char(string(segmentationEntry.status)), 'processed')
        % An unprocessed mask is not evidence that no bone exists, so preserve
        % that distinction instead of reporting a successful empty extraction.
        currentResult.status = 'skippedUnprocessed';
        surfaceResults(resultIndex) = currentResult;
        continue;
    end

    if ~any(effectiveMask(:))
        % A reviewed, processed empty mask is a valid no-surface outcome.
        currentResult.status = 'noSurface';
        surfaceResults(resultIndex) = currentResult;
        continue;
    end

    % Estimate image evidence and then choose a single globally consistent
    % depth from all competing mask runs in each active scan line.
    candidateConfidence = computeCandidateConfidence( ...
        displayedImage, effectiveMask, pixelSpacingXYMm, resolvedOptions);
    frameSurface = traceSurfacePaths( ...
        candidateConfidence, effectiveMask, pixelSpacingXYMm, resolvedOptions);

    currentResult.surfaceRowByColumn = frameSurface.surfaceRowByColumn;
    currentResult.observedColumnMask = frameSurface.observedColumnMask;
    currentResult.interpolatedColumnMask = frameSurface.interpolatedColumnMask;
    currentResult.segmentIdByColumn = frameSurface.segmentIdByColumn;
    currentResult.confidenceByColumn = frameSurface.confidenceByColumn;
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
    'shadowStartMm', 'shadowLengthMm', 'smoothnessWeight'};
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
    'sequencePosition', 'sourceIndex', 'segmentationMask', 'status'};
if ~isstruct(segmentationResults) || ~isvector(segmentationResults) || ...
        isempty(segmentationResults) || ...
        ~all(isfield(segmentationResults, requiredSegmentationFields))
    error('extractBoneSurfacesFromSegmentation:InvalidSegmentationResults', ...
        ['segmentationResults must be a non-empty struct vector containing ' ...
        'sequencePosition, sourceIndex, segmentationMask, and status.']);
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


function [displayedImage, effectiveMask, pixelSpacingXYMm] = ...
        prepareFrameData(segmentationEntry, ultrasoundEntry, resultIndex)
%PREPAREFRAMEDATA Align and validate one B-mode image and segmentation mask.
% The acquisition stores image packets as [width,height], so one transpose is
% required to reproduce the segmentation tool's [row,column] display space.
%
% Inputs:
%   segmentationEntry : One segmentationResults record.
%   ultrasoundEntry   : Matching ultrasoundSequence record.
%   resultIndex       : One-based result position used in error messages.
%
% Outputs:
%   displayedImage    : Double B-mode image normalized to [0,1].
%   effectiveMask     : Logical mask after applying the segmentation-area mask.
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

segmentationMask = segmentationEntry.segmentationMask;
if ~isValidBinaryMask(segmentationMask) || ...
        ~isequal(size(segmentationMask), displayedImageSize)
    error('extractBoneSurfacesFromSegmentation:ImageMaskSizeMismatch', ...
        ['segmentationMask must be a binary array matching the displayed ' ...
        'image size for result %d.'], resultIndex);
end

if isfield(segmentationEntry, 'segmentationAreaMask') && ...
        ~isempty(segmentationEntry.segmentationAreaMask)
    segmentationAreaMask = segmentationEntry.segmentationAreaMask;
    if ~isValidBinaryMask(segmentationAreaMask) || ...
            ~isequal(size(segmentationAreaMask), displayedImageSize)
        error('extractBoneSurfacesFromSegmentation:ImageMaskSizeMismatch', ...
            ['segmentationAreaMask must be a binary array matching the ' ...
            'displayed image size for result %d.'], resultIndex);
    end
else
    % Older result files may omit the optional reviewed-area mask. Treat the
    % full image as reviewed while preserving the main accepted mask.
    segmentationAreaMask = true(displayedImageSize);
end

displayedImage = double(storedImage.') / 255;
effectiveMask = logical(segmentationMask) & logical(segmentationAreaMask);

% Use pixel-centre endpoint spacing so physical gap and error thresholds use
% the same plane extent as current project visualization code.
pixelSpacingXYMm = [ ...
    double(plane.W) / (double(plane.nCols) - 1), ...
    double(plane.H) / (double(plane.nRows) - 1)];
end


function isValid = isValidBinaryMask(candidateMask)
%ISVALIDBINARYMASK Check whether an array safely represents a logical mask.
% Numeric zero/one masks are accepted for compatibility with MAT files that
% did not preserve logical class information.
%
% Input:
%   candidateMask : Candidate logical or numeric mask array.
%
% Output:
%   isValid       : True when the input is a finite real 2D binary array.

isValid = ismatrix(candidateMask) && ~isempty(candidateMask) && ...
    (islogical(candidateMask) || isnumeric(candidateMask));
if ~isValid
    return;
end

if isnumeric(candidateMask)
    isValid = isreal(candidateMask) && ...
        all(isfinite(candidateMask(:))) && ...
        all(candidateMask(:) == 0 | candidateMask(:) == 1);
end
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
    'observedColumnMask', false(1, 0), ...
    'interpolatedColumnMask', false(1, 0), ...
    'segmentIdByColumn', zeros(1, 0, 'uint16'), ...
    'confidenceByColumn', nan(1, 0), ...
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
currentResult.observedColumnMask = false(1, numberOfColumns);
currentResult.interpolatedColumnMask = false(1, numberOfColumns);
currentResult.segmentIdByColumn = zeros(1, numberOfColumns, 'uint16');
currentResult.confidenceByColumn = nan(1, numberOfColumns);
currentResult.pixelSpacingXYMm = pixelSpacingXYMm;
end


function candidateConfidence = computeCandidateConfidence( ...
        displayedImage, effectiveMask, pixelSpacingXYMm, options)
%COMPUTECANDIDATECONFIDENCE Score every mask pixel as a bone-surface point.
% The score combines the gradient-to-first-peak position, bright ridge, and
% distal acoustic shadow as a weighted geometric mean in [0,1].
%
% Inputs:
%   displayedImage   : Double B-mode image normalized to [0,1].
%   effectiveMask    : Logical accepted search region.
%   pixelSpacingXYMm : [xSpacing,ySpacing] in millimetres.
%   options          : Validated extraction configuration.
%
% Output:
%   candidateConfidence : Image-sized confidence map, zero outside the mask.

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
    smoothedImage, effectiveMask, options.normalizationPercentiles);
normalizedRidge = robustNormalizeFeature( ...
    positiveRidge, effectiveMask, options.normalizationPercentiles);
reflectionLikelihood = 0.5 * (normalizedIntensity + normalizedRidge);

shadowLikelihood = computeShadowLikelihood( ...
    smoothedImage, effectiveMask, ySpacingMm, options);
positionLikelihood = computePositionLikelihood( ...
    smoothedImage, effectiveMask, ySpacingMm, options);

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
candidateConfidence(~effectiveMask) = 0;
candidateConfidence = min(max(candidateConfidence, 0), 1);
end


function shadowLikelihood = computeShadowLikelihood( ...
        smoothedImage, effectiveMask, ySpacingMm, options)
%COMPUTESHADOWLIKELIHOOD Measure darkness distal to every possible surface.
% Gaussian weighting emphasizes the near shadow, while coverage blending makes
% candidates near the image bottom less certain instead of falsely perfect.
%
% Inputs:
%   smoothedImage : Smoothed normalized B-mode image.
%   effectiveMask : Logical candidate-region mask.
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
    rawShadow, effectiveMask, options.normalizationPercentiles);
end


function positionLikelihood = computePositionLikelihood( ...
        smoothedImage, effectiveMask, ySpacingMm, options)
%COMPUTEPOSITIONLIKELIHOOD Locate the gradient-to-first-peak surface estimate.
% Every contiguous mask run receives its own preferred depth so multiple tissue
% or reverberation responses remain available for the global path optimizer.
%
% Inputs:
%   smoothedImage : Smoothed normalized B-mode image.
%   effectiveMask : Logical candidate-region mask.
%   ySpacingMm    : Axial pixel spacing in millimetres.
%   options       : Validated extraction configuration.
%
% Output:
%   positionLikelihood : Image-sized likelihood centred within every mask run.

% Positive values mean brightness increases while travelling away from the
% probe along increasing rows.
depthGradient = imfilter(smoothedImage, ...
    [-1; 0; 1] / (2 * ySpacingMm), 'replicate', 'corr', 'same');
marginRows = max(1, round(options.gradientSearchMarginMm / ySpacingMm));
positionLikelihood = zeros(size(smoothedImage));

for columnIndex = 1:size(effectiveMask, 2)
    columnMask = effectiveMask(:, columnIndex);
    runChanges = diff([false; columnMask; false]);
    runStarts = find(runChanges == 1);
    runEnds = find(runChanges == -1) - 1;

    for runIndex = 1:numel(runStarts)
        runStart = runStarts(runIndex);
        runEnd = runEnds(runIndex);

        % Search near the probe-facing entrance only. Searching the full run
        % could select a deeper reverberation edge instead of the first echo.
        gradientSearchStart = max(1, runStart - marginRows);
        gradientSearchEnd = min(runEnd, runStart + marginRows);
        gradientValues = depthGradient( ...
            gradientSearchStart:gradientSearchEnd, columnIndex);
        [strongestGradient, gradientOffset] = max(gradientValues);
        hasValidGradient = isfinite(strongestGradient) && strongestGradient > 0;

        if hasValidGradient
            gradientRow = gradientSearchStart + gradientOffset - 1;
            peakSearchStart = max(runStart, gradientRow);
            peakValues = smoothedImage( ...
                peakSearchStart:runEnd, columnIndex);
            peakOffset = findFirstPeak(peakValues);
            peakRow = peakSearchStart + peakOffset - 1;
            preferredRow = 0.5 * (gradientRow + peakRow);
            confidenceScale = 1;
        else
            % A flat or noisy response has no defensible gradient-to-peak
            % estimate. Keep the run available but lower its confidence.
            preferredRow = 0.5 * (runStart + runEnd);
            peakRow = preferredRow;
            gradientRow = preferredRow;
            confidenceScale = options.fallbackConfidenceScale;
        end

        preferredRow = min(max(preferredRow, runStart), runEnd);
        positionSigmaRows = max( ...
            options.ridgeSigmaMm / ySpacingMm, ...
            max(1, 0.5 * abs(peakRow - gradientRow)));
        candidateRows = (runStart:runEnd).';
        runLikelihood = exp(-0.5 * ( ...
            (candidateRows - preferredRow) / positionSigmaRows) .^ 2);
        positionLikelihood(candidateRows, columnIndex) = ...
            confidenceScale * runLikelihood;
    end
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
        featureImage, effectiveMask, percentiles)
%ROBUSTNORMALIZEFEATURE Scale one image feature using mask percentiles.
% Percentile clipping avoids a few extreme speckle values controlling all
% confidences, while a constant feature becomes neutral evidence rather than
% producing NaN or forcing rejection.
%
% Inputs:
%   featureImage  : Numeric feature image.
%   effectiveMask : Logical region used to estimate the robust range.
%   percentiles   : [lower,upper] percentile values.
%
% Output:
%   normalizedFeature : Image-sized feature in [0,1], zero outside the mask.

maskValues = double(featureImage(effectiveMask));
lowerValue = prctile(maskValues, percentiles(1));
upperValue = prctile(maskValues, percentiles(2));
normalizedFeature = zeros(size(featureImage));

if upperValue <= lowerValue + eps(max(abs([lowerValue, upperValue, 1])))
    % A constant feature carries no preference, so use neutral evidence.
    normalizedFeature(effectiveMask) = 0.5;
    return;
end

normalizedFeature = (double(featureImage) - lowerValue) / ...
    (upperValue - lowerValue);
normalizedFeature = min(max(normalizedFeature, 0), 1);
normalizedFeature(~effectiveMask) = 0;
end


function frameSurface = traceSurfacePaths( ...
        candidateConfidence, effectiveMask, pixelSpacingXYMm, options)
%TRACESURFACEPATHS Select smooth observed paths and interpolate short gaps.
% Active columns separated by at most the configured physical gap remain in
% one dynamic-programming problem so continuity constrains both sides.
%
% Inputs:
%   candidateConfidence : Image-sized candidate confidence in [0,1].
%   effectiveMask       : Logical candidate-region mask.
%   pixelSpacingXYMm    : [xSpacing,ySpacing] in millimetres.
%   options             : Validated extraction configuration.
%
% Output:
%   frameSurface        : Scalar struct containing column-wise surface data.

numberOfRows = size(effectiveMask, 1);
numberOfColumns = size(effectiveMask, 2);
xSpacingMm = pixelSpacingXYMm(1);
ySpacingMm = pixelSpacingXYMm(2);

columnMaximumConfidence = max(candidateConfidence, [], 1);
activeColumns = find(any(effectiveMask, 1) & ...
    columnMaximumConfidence >= options.evidenceThreshold);

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
            groupColumns, candidateConfidence, effectiveMask, ...
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

[surfaceRows, confidenceByColumn, interpolatedMask, segmentIds] = ...
    interpolateAcceptedGaps(observedRows, observedConfidence, ...
    numberOfRows, xSpacingMm, options);
observedMask = isfinite(observedRows);
validMask = isfinite(surfaceRows);

observedConfidenceValues = observedConfidence(observedMask);
if isempty(observedConfidenceValues)
    meanConfidence = nan;
else
    meanConfidence = mean(observedConfidenceValues);
end

frameSurface = struct( ...
    'surfaceRowByColumn', surfaceRows, ...
    'observedColumnMask', observedMask, ...
    'interpolatedColumnMask', interpolatedMask, ...
    'segmentIdByColumn', segmentIds, ...
    'confidenceByColumn', confidenceByColumn, ...
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
        activeColumns, candidateConfidence, effectiveMask, ...
        xSpacingMm, ySpacingMm, options)
%TRACEONEACTIVEGROUP Find the minimum-cost path through one lateral group.
% Dynamic programming compares every mask row, including rows from multiple
% disconnected runs, and returns the globally best first-order smooth path.
%
% Inputs:
%   activeColumns       : Increasing vector of columns in one gap-bounded group.
%   candidateConfidence : Image-sized confidence map.
%   effectiveMask       : Logical candidate mask.
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
candidateRows{1} = find(effectiveMask(:, firstColumn));
previousCosts = -log(max( ...
    candidateConfidence(candidateRows{1}, firstColumn), smallValue));
previousCosts = previousCosts(:);

for activeIndex = 2:numberOfActiveColumns
    currentColumn = activeColumns(activeIndex);
    previousColumn = activeColumns(activeIndex - 1);
    previousRows = candidateRows{activeIndex - 1};
    currentRows = find(effectiveMask(:, currentColumn));
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
extractionMetadata = struct( ...
    'algorithmName', 'gradientPeakShadowDynamicProgramming', ...
    'algorithmVersion', '1.0.0', ...
    'createdAt', char(datetime('now', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ss')), ...
    'coordinateConvention', ...
        ['MATLAB 1-based [x,y] = [column,row], origin at the ' ...
        'top-left pixel centre'], ...
    'beamAxis', 'row', ...
    'beamDirection', 'increasing row', ...
    'meanConfidenceDefinition', 'mean over observed points only', ...
    'resolvedConfiguration', options, ...
    'numberOfFrames', numel(surfaceResults), ...
    'numberExtracted', nnz(strcmp(statuses, 'extracted')), ...
    'numberNoSurface', nnz(strcmp(statuses, 'noSurface')), ...
    'numberSkippedUnprocessed', ...
        nnz(strcmp(statuses, 'skippedUnprocessed')));
end
