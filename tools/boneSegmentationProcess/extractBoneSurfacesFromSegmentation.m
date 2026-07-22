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
        candidateConfidence, effectiveMask, pixelSpacingXYMm, ...
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
    currentResult.outsideSegmentationColumnMask = ...
        frameSurface.outsideSegmentationColumnMask;
    currentResult.outsideSegmentationFraction = ...
        frameSurface.outsideSegmentationFraction;
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
    'rawSurfaceRowByColumn', nan(1, 0), ...
    'observedColumnMask', false(1, 0), ...
    'interpolatedColumnMask', false(1, 0), ...
    'segmentIdByColumn', zeros(1, 0, 'uint16'), ...
    'confidenceByColumn', nan(1, 0), ...
    'rawConfidenceByColumn', nan(1, 0), ...
    'regularizationDisplacementMmByColumn', nan(1, 0), ...
    'regularizationBoundHitColumnMask', false(1, 0), ...
    'outsideSegmentationColumnMask', false(1, 0), ...
    'outsideSegmentationFraction', nan, ...
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
currentResult.outsideSegmentationColumnMask = ...
    false(1, numberOfColumns);
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
        candidateConfidence, effectiveMask, pixelSpacingXYMm, options, ...
        sourceIndex)
%TRACESURFACEPATHS Select, interpolate, and curvature-refine surface paths.
% Active columns separated by at most the configured physical gap remain in
% one dynamic-programming problem so continuity constrains both sides. A
% bounded second stage removes pixel-scale bending while allowing the final
% approximation to leave an unreliable segmentation region.
%
% Inputs:
%   candidateConfidence : Image-sized candidate confidence in [0,1].
%   effectiveMask       : Logical candidate-region mask.
%   pixelSpacingXYMm    : [xSpacing,ySpacing] in millimetres.
%   options             : Validated extraction configuration.
%   sourceIndex         : Source-frame identifier used in fallback warnings.
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

[rawSurfaceRows, rawConfidenceByColumn, interpolatedMask, segmentIds] = ...
    interpolateAcceptedGaps(observedRows, observedConfidence, ...
    numberOfRows, xSpacingMm, options);
observedMask = isfinite(observedRows);

% The segmentation-constrained DP/PCHIP result remains the auditable raw
% trace. Refinement is bounded only by raw displacement and image dimensions.
[surfaceRows, confidenceByColumn, regularizationDiagnostics] = ...
    regularizeSurfaceSegments(rawSurfaceRows, rawConfidenceByColumn, ...
    observedMask, interpolatedMask, segmentIds, effectiveMask, ...
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
    'outsideSegmentationColumnMask', ...
        regularizationDiagnostics.outsideSegmentationColumnMask, ...
    'outsideSegmentationFraction', ...
        regularizationDiagnostics.outsideSegmentationFraction, ...
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
assert(~any(regularizationDiagnostics.outsideSegmentationColumnMask & ...
    ~observedMask), ...
    'Only originally observed columns may be flagged outside segmentation.');
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


function [surfaceRows, confidenceByColumn, diagnostics] = ...
        regularizeSurfaceSegments(rawSurfaceRows, rawConfidenceByColumn, ...
        observedMask, interpolatedMask, segmentIds, effectiveMask, ...
        pixelSpacingXYMm, options, sourceIndex)
%REGULARIZESURFACESEGMENTS Refine raw paths with bounded curvature smoothing.
% The raw dynamic-programming path decides which probe-facing echo response is
% bone. This stage reduces rapid bending while allowing the final approximation
% to leave the segmentation when its irregular boundary is not trustworthy.
%
% Inputs:
%   rawSurfaceRows       : Raw DP/PCHIP row at each column, with NaN elsewhere.
%   rawConfidenceByColumn: Raw confidence at observed and interpolated columns.
%   observedMask         : Logical columns directly selected from image evidence.
%   interpolatedMask     : Logical columns filled across accepted short gaps.
%   segmentIds           : Nonzero segment label at each retained column.
%   effectiveMask        : Logical extraction mask, used only for audit flags.
%   pixelSpacingXYMm     : [xSpacing,ySpacing] in millimetres.
%   options              : Validated extraction and regularization settings.
%   sourceIndex          : Source-frame identifier used in fallback warnings.
%
% Outputs:
%   surfaceRows       : Final subpixel row at each retained column.
%   confidenceByColumn: Raw confidence reduced according to refinement movement
%                       and decayed across interpolated gaps.
%   diagnostics       : Scalar struct containing status, movement, outside-mask,
%                       bound-hit, and before/after roughness audit values.

surfaceRows = rawSurfaceRows;
confidenceByColumn = rawConfidenceByColumn;
validMask = isfinite(rawSurfaceRows);

% Signed movement retains direction for audit. Absent columns remain NaN so
% downstream code cannot mistake them for unchanged surface samples.
displacementMmByColumn = nan(size(rawSurfaceRows));
displacementMmByColumn(validMask) = 0;
boundHitColumnMask = false(size(rawSurfaceRows));
outsideSegmentationColumnMask = false(size(rawSurfaceRows));

roughnessBeforePerMm = computeSurfaceRoughness( ...
    rawSurfaceRows, segmentIds, pixelSpacingXYMm);

if ~any(validMask)
    diagnostics = buildRegularizationDiagnostics( ...
        'notApplicable', displacementMmByColumn, boundHitColumnMask, ...
        outsideSegmentationColumnMask, observedMask, ...
        roughnessBeforePerMm, roughnessBeforePerMm);
    return;
end

if ~options.regularizationEnabled
    % Disabled mode is an exact compatibility path, including confidence.
    diagnostics = buildRegularizationDiagnostics( ...
        'disabled', displacementMmByColumn, boundHitColumnMask, ...
        outsideSegmentationColumnMask, observedMask, ...
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
        observedMask(segmentColumns), size(effectiveMask, 1), ...
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

% The final location is intentionally allowed outside the segmentation, so its
% confidence derives from raw support and decays monotonically with movement.
confidenceByColumn = applyDisplacementConfidenceDecay( ...
    rawConfidenceByColumn, displacementMmByColumn, observedMask, ...
    interpolatedMask, segmentIds, pixelSpacingXYMm(1), ...
    options.maxInterpolatedGapMm, ...
    options.regularizationMaxDisplacementMm);

outsideSegmentationColumnMask = findOutsideSegmentationColumns( ...
    surfaceRows, observedMask, effectiveMask);
roughnessAfterPerMm = computeSurfaceRoughness( ...
    surfaceRows, segmentIds, pixelSpacingXYMm);
diagnostics = buildRegularizationDiagnostics( ...
    regularizationStatus, displacementMmByColumn, boundHitColumnMask, ...
    outsideSegmentationColumnMask, observedMask, ...
    roughnessBeforePerMm, roughnessAfterPerMm);
end


function [refinedRows, boundHitMask, succeeded, failureMessage] = ...
        regularizeOneSurfaceSegment(rawRows, rawConfidence, ...
        observedMask, numberOfImageRows, pixelSpacingXYMm, options)
%REGULARIZEONESURFACESEGMENT Solve one raw-bounded curvature problem.
% Huber iteratively reweighted least squares limits the influence of isolated
% branch excursions. Quadprog enforces image limits and the maximum permitted
% displacement from the segmentation-constrained raw path.
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


function outsideMask = findOutsideSegmentationColumns( ...
        surfaceRows, observedMask, effectiveMask)
%FINDOUTSIDESEGMENTATIONCOLUMNS Flag refined observed points outside the mask.
% Interpolated points are deliberately excluded because their separate public
% flag already communicates that no direct segmentation evidence existed.
%
% Inputs:
%   surfaceRows : Final subpixel row at each image column.
%   observedMask: Logical columns with a raw image-supported observation.
%   effectiveMask: Logical extraction mask after applying the reviewed area.
%
% Output:
%   outsideMask : Logical observed columns whose rounded final row lies outside
%                 the effective extraction mask.

outsideMask = false(size(observedMask));
numberOfRows = size(effectiveMask, 1);
observedColumns = find(observedMask);
roundedRows = round(surfaceRows(observedColumns));
roundedRows = min(max(roundedRows, 1), numberOfRows);
linearIndices = sub2ind(size(effectiveMask), ...
    roundedRows(:), observedColumns(:));
outsideMask(observedColumns) = ~effectiveMask(linearIndices);
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
        outsideSegmentationColumnMask, observedMask, ...
        roughnessBeforePerMm, roughnessAfterPerMm)
%BUILDREGULARIZATIONDIAGNOSTICS Summarize one frame's refinement outcome.
% Centralizing this summary keeps empty, disabled, successful, and fallback
% frames consistent for downstream audit code.
%
% Inputs:
%   status                        : Text status for the frame refinement.
%   displacementMmByColumn        : Signed movement, with NaN when absent.
%   boundHitColumnMask            : Logical columns ending on a hard bound.
%   outsideSegmentationColumnMask : Refined observed points outside the mask.
%   observedMask                  : Logical originally observed columns.
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

numberObserved = nnz(observedMask);
if numberObserved == 0
    outsideSegmentationFraction = nan;
else
    outsideSegmentationFraction = ...
        nnz(outsideSegmentationColumnMask) / numberObserved;
end

diagnostics = struct( ...
    'status', status, ...
    'displacementMmByColumn', displacementMmByColumn, ...
    'boundHitColumnMask', boundHitColumnMask, ...
    'outsideSegmentationColumnMask', ...
        outsideSegmentationColumnMask, ...
    'outsideSegmentationFraction', outsideSegmentationFraction, ...
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
        'gradientPeakShadowDynamicProgrammingRawBoundedCurvature', ...
    'algorithmVersion', '1.1.0', ...
    'createdAt', char(datetime('now', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ss')), ...
    'coordinateConvention', ...
        ['MATLAB 1-based [x,y] = [column,row], origin at the ' ...
        'top-left pixel centre'], ...
    'beamAxis', 'row', ...
    'beamDirection', 'increasing row', ...
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
