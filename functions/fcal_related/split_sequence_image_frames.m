function outputPaths = split_sequence_image_frames(filePath, frameIdsZeroBased, outputFolder)
%SPLIT_SEQUENCE_IMAGE_FRAMES Split selected PLUS sequence frames into one-frame MHA files.
% outputPaths = split_sequence_image_frames(filePath, frameIdsZeroBased, outputFolder)
%
% Inputs:
%   filePath           : path to the source PLUS .mha sequence file
%   frameIdsZeroBased  : original MHA frame IDs, for example [50 100 400]
%   outputFolder       : folder where the one-frame .mha files will be written
%
% Output:
%   outputPaths        : 1xN cell array with the written file paths

    % Normalize path inputs first so the rest of the function can use char vectors.
    filePath = normalize_text_scalar(filePath, 'filePath');
    outputFolder = normalize_text_scalar(outputFolder, 'outputFolder');

    % Validate the requested frame IDs before touching the file system.
    % This catches duplicate IDs early because duplicate IDs would create duplicate names.
    frameIdsZeroBased = validate_frame_ids(frameIdsZeroBased);

    % Fail clearly if the input file path points to nothing.
    if ~isfile(filePath)
        error('Source sequence file not found: %s', filePath);
    end

    % Create the destination folder when it does not exist yet.
    % This keeps the caller simple: they only need to choose the folder path.
    ensure_output_folder(outputFolder);

    % Read the whole file as bytes because the MHA payload after the header is binary.
    fileBytes = read_file_as_uint8(filePath);

    % Split the file into the editable text header and the raw image payload.
    % The PLUS format requires ElementDataFile = LOCAL to be the last header field.
    [headerText, imageData, newlineText] = split_local_mha_bytes(fileBytes);

    % Split the text header into lines while keeping the original line contents.
    % We rewrite only the few lines needed for a one-frame file.
    headerLines = split_header_lines(headerText);

    % Parse only the metadata needed for safe splitting.
    % The original text lines stay available for output, so unknown fields are preserved.
    [headerInfo, frameLineIds] = parse_split_metadata(headerLines);

    % Convert DimSize into exact dimensions and reject unsupported image layouts.
    headerInfo = validate_supported_header(headerInfo);

    % Check that every requested frame exists in both the declared frame range and metadata.
    validate_frame_requests(frameIdsZeroBased, headerInfo.numFrames, frameLineIds);

    % For the first supported version, each pixel is one uint8 byte.
    % Therefore one frame is width * height bytes.
    bytesPerFrame = headerInfo.frameWidth * headerInfo.frameHeight;

    % Make sure the source payload is long enough before slicing any frame bytes.
    validate_payload_length(imageData, bytesPerFrame, headerInfo.numFrames);

    % Build stable output file names from the original file name and the original frame ID.
    [~, baseName, ext] = fileparts(filePath);
    if isempty(ext)
        % Keep the output as an MHA file even if the input path had no extension.
        ext = '.mha';
    end

    % Pre-allocate the cell array returned to the caller.
    outputPaths = cell(1, numel(frameIdsZeroBased));

    % Write one output file per requested original frame ID.
    for requestIndex = 1:numel(frameIdsZeroBased)
        % Keep the requested ID in a named variable because it is zero-based.
        originalFrameId = frameIdsZeroBased(requestIndex);

        % Slice exactly one frame from the original binary payload.
        frameBytes = extract_frame_bytes(imageData, bytesPerFrame, originalFrameId);

        % Build a one-frame header that preserves original general fields and selected metadata.
        outputHeaderText = build_single_frame_header(headerLines, frameLineIds, headerInfo, originalFrameId, newlineText);

        % Include the original frame ID in the filename so the file can be traced back later.
        outputFileName = sprintf('%s_frame%04d%s', baseName, originalFrameId, ext);
        outputPath = fullfile(outputFolder, outputFileName);

        % Write the text header and binary frame bytes to a new MHA file.
        write_mha_file(outputPath, outputHeaderText, frameBytes);

        % Return the path so downstream scripts do not have to rebuild it.
        outputPaths{requestIndex} = outputPath;
    end
end

function textValue = normalize_text_scalar(textValue, inputName)
%NORMALIZE_TEXT_SCALAR Accept a char vector or string scalar and return char.

    % Accept MATLAB string scalars for convenience.
    if isstring(textValue)
        % Reject string arrays because each input must name exactly one thing.
        if ~isscalar(textValue)
            error('%s must be a character vector or string scalar.', inputName);
        end

        % Convert to char so older file I/O functions can use it directly.
        textValue = char(textValue);
    end

    % Reject other types early so later error messages stay focused.
    if ~ischar(textValue)
        error('%s must be a character vector or string scalar.', inputName);
    end
end

function frameIdsZeroBased = validate_frame_ids(frameIdsZeroBased)
%VALIDATE_FRAME_IDS Check that requested frame IDs are usable zero-based integers.

    % Frame IDs must be numeric because they are used for indexing and filenames.
    if ~isnumeric(frameIdsZeroBased)
        error('frameIdsZeroBased must be a numeric vector.');
    end

    % A splitter call with no selected frames is almost always a caller mistake.
    if isempty(frameIdsZeroBased)
        error('frameIdsZeroBased must contain at least one frame ID.');
    end

    % Work with a row vector so outputPaths has the same simple orientation every time.
    frameIdsZeroBased = double(frameIdsZeroBased(:).');

    % Reject NaN, Inf, fractional values, and negative values before indexing bytes.
    if any(~isfinite(frameIdsZeroBased)) || ...
            any(abs(frameIdsZeroBased - round(frameIdsZeroBased)) > 1e-12) || ...
            any(frameIdsZeroBased < 0)
        error('frameIdsZeroBased must contain finite nonnegative integer frame IDs.');
    end

    % Convert IDs to exact integer-valued doubles for formatting and indexing.
    frameIdsZeroBased = round(frameIdsZeroBased);

    % Duplicate frame IDs would produce duplicate filenames and ambiguous results.
    if numel(unique(frameIdsZeroBased)) ~= numel(frameIdsZeroBased)
        error('Duplicate frame IDs are not allowed because each frame writes one output file.');
    end
end

function ensure_output_folder(outputFolder)
%ENSURE_OUTPUT_FOLDER Create the output folder if needed.

    % Refuse to write into a path that already exists as a file.
    if exist(outputFolder, 'file') && ~isfolder(outputFolder)
        error('Output path exists but is not a folder: %s', outputFolder);
    end

    % Create the folder tree when it is missing.
    if ~isfolder(outputFolder)
        [created, messageText] = mkdir(outputFolder);
        if ~created
            error('Could not create output folder "%s": %s', outputFolder, messageText);
        end
    end
end

function bytes = read_file_as_uint8(filePath)
%READ_FILE_AS_UINT8 Read an entire file as raw uint8 bytes.

    % Open in binary mode so MATLAB does not translate line endings on Windows.
    fid = fopen(filePath, 'rb');
    if fid < 0
        error('Cannot open source file: %s', filePath);
    end

    % Always close the file, even if a later read or validation step errors.
    cleaner = onCleanup(@() fclose(fid));

    % Read all bytes at once because we need random access to frame payload chunks.
    bytes = fread(fid, inf, '*uint8');
end

function [headerText, imageData, newlineText] = split_local_mha_bytes(fileBytes)
%SPLIT_LOCAL_MHA_BYTES Separate the text header from the LOCAL binary payload.

    % This literal field marks the final header line for inline MHA payloads.
    separator = uint8('ElementDataFile = LOCAL');

    % Search on a row vector because strfind returns easier indices for this layout.
    separatorStart = strfind(fileBytes.', separator);
    if isempty(separatorStart)
        error('Header separator "ElementDataFile = LOCAL" was not found.');
    end

    % Use the first separator because any bytes after it are image payload by definition.
    separatorStart = separatorStart(1);
    separatorEnd = separatorStart + numel(separator) - 1;

    % Keep only the header text before ElementDataFile so we can rebuild the final line.
    if separatorStart > 1
        headerBytes = fileBytes(1:separatorStart - 1);
    else
        headerBytes = uint8([]);
    end

    % Convert the header bytes to text; PLUS MHA headers are ASCII-compatible.
    headerText = char(headerBytes).';

    % Preserve the source newline style for the generated output headers.
    newlineText = detect_newline_text(headerText);

    % Find the first binary payload byte after the ElementDataFile line.
    imageDataStart = find_image_data_start(fileBytes, separatorEnd);
    if imageDataStart <= numel(fileBytes)
        imageData = fileBytes(imageDataStart:end);
    else
        imageData = uint8([]);
    end
end

function newlineText = detect_newline_text(headerText)
%DETECT_NEWLINE_TEXT Return the newline style already used by the source header.

    % Prefer CRLF when present because most PLUS files written on Windows use it.
    if contains(headerText, sprintf('\r\n'))
        newlineText = sprintf('\r\n');
        return;
    end

    % Fall back to LF for Unix-style files.
    if contains(headerText, newline)
        newlineText = newline;
        return;
    end

    % Support old CR-only files even though they are uncommon.
    if contains(headerText, sprintf('\r'))
        newlineText = sprintf('\r');
        return;
    end

    % If the source header had no newline, use LF for the new header.
    newlineText = newline;
end

function imageDataStart = find_image_data_start(fileBytes, separatorEnd)
%FIND_IMAGE_DATA_START Return the first binary byte after ElementDataFile.

    % Start immediately after the LOCAL text.
    imageDataStart = separatorEnd + 1;

    % Ignore spaces or tabs that may appear before the line ending.
    while imageDataStart <= numel(fileBytes) && ...
            (fileBytes(imageDataStart) == uint8(' ') || fileBytes(imageDataStart) == uint8(sprintf('\t')))
        imageDataStart = imageDataStart + 1;
    end

    % Skip the actual line ending, supporting both CRLF and LF.
    if imageDataStart <= numel(fileBytes) && fileBytes(imageDataStart) == 13
        imageDataStart = imageDataStart + 1;
        if imageDataStart <= numel(fileBytes) && fileBytes(imageDataStart) == 10
            imageDataStart = imageDataStart + 1;
        end
    elseif imageDataStart <= numel(fileBytes) && fileBytes(imageDataStart) == 10
        imageDataStart = imageDataStart + 1;
    end
end

function headerLines = split_header_lines(headerText)
%SPLIT_HEADER_LINES Split header text and remove only trailing separator whitespace.

    % Split on any common newline style while keeping the text inside each line unchanged.
    headerLines = regexp(headerText, '\r\n|\n|\r', 'split');

    % Remove empty lines created only because the header ended right before ElementDataFile.
    while ~isempty(headerLines) && isempty(headerLines{end})
        headerLines(end) = [];
    end
end

function [headerInfo, frameLineIds] = parse_split_metadata(headerLines)
%PARSE_SPLIT_METADATA Collect the fields needed to split frames safely.

    % Initialize defaults that match the uncompressed single-channel files we support.
    headerInfo = struct();
    headerInfo.dimSize = [];
    headerInfo.dimSizeLineIndex = [];
    headerInfo.elementType = '';
    headerInfo.compressedData = false;
    headerInfo.elementNumberOfChannels = 1;

    % frameLineIds stores the numeric original frame ID for each metadata line.
    % Non-frame lines are NaN so the header builder can keep them unchanged.
    frameLineIds = nan(1, numel(headerLines));

    % These patterns parse normal "Field = Value" lines and per-frame metadata lines.
    fieldPattern = '^\s*([^=]+?)\s*=\s*(.*?)\s*$';
    framePattern = '^\s*Seq_Frame(\d+)_([A-Za-z0-9_]+)\s*=';

    % Inspect every header line once.
    for lineIndex = 1:numel(headerLines)
        % Keep the original line text intact for output, but parse a trimmed copy.
        lineText = headerLines{lineIndex};

        % Remember which lines belong to which original frame.
        frameTokens = regexp(lineText, framePattern, 'tokens', 'once');
        if ~isempty(frameTokens)
            frameLineIds(lineIndex) = str2double(frameTokens{1});
            continue;
        end

        % Parse general key/value fields.
        fieldTokens = regexp(lineText, fieldPattern, 'tokens', 'once');
        if isempty(fieldTokens)
            continue;
        end

        % Use case-insensitive field names because MetaIO fields are text keys.
        fieldName = lower(strtrim(fieldTokens{1}));
        rawValue = strtrim(fieldTokens{2});

        % Store only the fields needed for validation and output rewriting.
        switch fieldName
            case 'dimsize'
                if ~isempty(headerInfo.dimSizeLineIndex)
                    error('Multiple DimSize fields were found; this splitter expects exactly one.');
                end
                headerInfo.dimSize = parse_numeric_vector(rawValue, 'DimSize');
                headerInfo.dimSizeLineIndex = lineIndex;
            case 'elementtype'
                headerInfo.elementType = rawValue;
            case 'compresseddata'
                headerInfo.compressedData = parse_boolean_field(rawValue, 'CompressedData');
            case 'elementnumberofchannels'
                headerInfo.elementNumberOfChannels = parse_numeric_scalar(rawValue, 'ElementNumberOfChannels');
            otherwise
                % Other general fields are preserved as text but are not needed here.
        end
    end
end

function values = parse_numeric_vector(rawValue, fieldName)
%PARSE_NUMERIC_VECTOR Convert a whitespace-separated numeric field to doubles.

    % Split on whitespace so invalid tokens can be detected reliably.
    valueTokens = strsplit(strtrim(rawValue));
    values = str2double(valueTokens);

    % Reject any token MATLAB could not parse as a number.
    if isempty(values) || any(isnan(values))
        error('%s must contain only numeric values.', fieldName);
    end
end

function value = parse_numeric_scalar(rawValue, fieldName)
%PARSE_NUMERIC_SCALAR Convert a single numeric field to a double.

    % Reuse vector parsing so error behavior stays consistent.
    values = parse_numeric_vector(rawValue, fieldName);
    if numel(values) ~= 1
        error('%s must contain exactly one numeric value.', fieldName);
    end

    % Return the one scalar value.
    value = values(1);
end

function tf = parse_boolean_field(rawValue, fieldName)
%PARSE_BOOLEAN_FIELD Convert MetaIO true/false text to logical.

    % Normalize the text so True, TRUE, and true behave the same way.
    normalized = lower(strtrim(rawValue));

    % Accept the common textual and numeric boolean spellings.
    if strcmp(normalized, 'true') || strcmp(normalized, '1')
        tf = true;
        return;
    end
    if strcmp(normalized, 'false') || strcmp(normalized, '0')
        tf = false;
        return;
    end

    % A strange boolean value means we cannot know how to slice the payload safely.
    error('%s must be True or False.', fieldName);
end

function headerInfo = validate_supported_header(headerInfo)
%VALIDATE_SUPPORTED_HEADER Reject formats this splitter does not yet implement.

    % DimSize is required because it defines width, height, and frame count.
    if isempty(headerInfo.dimSize)
        error('Header field "DimSize" is required but was not found.');
    end

    % This first implementation supports only width, height, and frame count.
    if numel(headerInfo.dimSize) ~= 3
        error('Only 3-value DimSize headers are supported: width height frameCount.');
    end

    % DimSize values must be positive integers before they can be used as byte counts.
    dimSize = double(headerInfo.dimSize);
    if any(abs(dimSize - round(dimSize)) > 1e-12) || any(dimSize <= 0)
        error('DimSize values must be positive integers.');
    end

    % Store exact integer dimensions with names that explain their role.
    headerInfo.frameWidth = round(dimSize(1));
    headerInfo.frameHeight = round(dimSize(2));
    headerInfo.numFrames = round(dimSize(3));

    % Compression changes the payload layout, so direct frame byte slicing is not safe.
    if headerInfo.compressedData
        error('CompressedData = True is not supported. Please uncompress the sequence first.');
    end

    % The existing reader and this splitter currently support one uint8 byte per pixel.
    if isempty(headerInfo.elementType)
        error('Header field "ElementType" is required but was not found.');
    end
    if ~strcmpi(strtrim(headerInfo.elementType), 'MET_UCHAR')
        error('Only ElementType = MET_UCHAR is supported. Found: %s', headerInfo.elementType);
    end

    % Multi-channel images need a larger bytes-per-frame calculation, so reject them for now.
    if abs(headerInfo.elementNumberOfChannels - 1) > 1e-12
        error('Only single-channel image data is supported.');
    end
end

function validate_frame_requests(frameIdsZeroBased, numFrames, frameLineIds)
%VALIDATE_FRAME_REQUESTS Check selected IDs against the header metadata.

    % Frame IDs are zero-based, so the largest valid ID is numFrames - 1.
    outOfRange = frameIdsZeroBased >= numFrames;
    if any(outOfRange)
        badFrameId = frameIdsZeroBased(find(outOfRange, 1));
        error('Requested frame ID %d is outside the valid range 0 to %d.', badFrameId, numFrames - 1);
    end

    % Require metadata for each selected frame so every output has a valid Seq_Frame0000 block.
    validFrameLineIds = frameLineIds(~isnan(frameLineIds));
    for requestIndex = 1:numel(frameIdsZeroBased)
        originalFrameId = frameIdsZeroBased(requestIndex);
        if ~any(validFrameLineIds == originalFrameId)
            error('Frame metadata for Seq_Frame%04d was not found.', originalFrameId);
        end
    end
end

function validate_payload_length(imageData, bytesPerFrame, numFrames)
%VALIDATE_PAYLOAD_LENGTH Confirm the binary payload contains all declared frames.

    % Compute the number of bytes the source header promises.
    expectedBytes = bytesPerFrame * numFrames;

    % A short payload means selected frame bytes may be missing or shifted.
    if numel(imageData) < expectedBytes
        error('Image payload is shorter than expected (%d < %d bytes).', numel(imageData), expectedBytes);
    end

    % Extra bytes do not prevent safe slicing, but tell the caller because the file is unusual.
    if numel(imageData) > expectedBytes
        warning(['Image payload is longer than expected (%d > %d bytes). ', ...
                 'Extra trailing bytes are ignored.'], numel(imageData), expectedBytes);
    end
end

function frameBytes = extract_frame_bytes(imageData, bytesPerFrame, originalFrameId)
%EXTRACT_FRAME_BYTES Slice one zero-based frame from the payload.

    % Convert the zero-based frame ID into a one-based byte range.
    byteStart = originalFrameId * bytesPerFrame + 1;
    byteEnd = byteStart + bytesPerFrame - 1;

    % Return exactly the bytes for this frame, preserving the original pixel order.
    frameBytes = imageData(byteStart:byteEnd);
end

function outputHeaderText = build_single_frame_header(headerLines, frameLineIds, headerInfo, originalFrameId, newlineText)
%BUILD_SINGLE_FRAME_HEADER Create the header text for one selected frame.

    % Collect output lines in a cell array so we can preserve ordering cleanly.
    outputLines = {};

    % Walk through the source header lines and keep only the selected frame metadata.
    for lineIndex = 1:numel(headerLines)
        % Frame metadata lines need filtering and renumbering.
        if ~isnan(frameLineIds(lineIndex))
            if frameLineIds(lineIndex) == originalFrameId
                outputLines{end + 1} = rewrite_frame_line_to_zero(headerLines{lineIndex}); %#ok<AGROW>
            end
            continue;
        end

        % DimSize must say this new file contains exactly one frame.
        if lineIndex == headerInfo.dimSizeLineIndex
            outputLines{end + 1} = sprintf('DimSize = %d %d 1', headerInfo.frameWidth, headerInfo.frameHeight); %#ok<AGROW>
        else
            outputLines{end + 1} = headerLines{lineIndex}; %#ok<AGROW>
        end
    end

    % Join all preserved lines with the same newline style as the source file.
    outputHeaderText = join_lines(outputLines, newlineText);

    % Add a newline before the required final ElementDataFile line when needed.
    if ~isempty(outputHeaderText)
        outputHeaderText = [outputHeaderText newlineText];
    end

    % ElementDataFile must be the final header field before the binary image bytes.
    outputHeaderText = [outputHeaderText 'ElementDataFile = LOCAL' newlineText];
end

function lineText = rewrite_frame_line_to_zero(lineText)
%REWRITE_FRAME_LINE_TO_ZERO Rename one selected frame metadata line to Seq_Frame0000.

    % Replace only the first frame prefix so any value text after "=" stays unchanged.
    lineText = regexprep(lineText, 'Seq_Frame\d+_', 'Seq_Frame0000_', 'once');
end

function textValue = join_lines(lines, newlineText)
%JOIN_LINES Join a cell array of text lines using a caller-supplied newline.

    % Return empty text for an empty line list.
    if isempty(lines)
        textValue = '';
        return;
    end

    % Start with the first line, then append each later line with a newline before it.
    textValue = lines{1};
    for lineIndex = 2:numel(lines)
        textValue = [textValue newlineText lines{lineIndex}]; %#ok<AGROW>
    end
end

function write_mha_file(outputPath, headerText, frameBytes)
%WRITE_MHA_FILE Write an MHA text header followed by binary frame bytes.

    % Open in binary write mode so the payload bytes are not changed.
    fid = fopen(outputPath, 'wb');
    if fid < 0
        error('Cannot open output file for writing: %s', outputPath);
    end

    % Always close the file, even if one of the writes fails.
    cleaner = onCleanup(@() fclose(fid));

    % Write the ASCII-compatible header first.
    headerCount = fwrite(fid, uint8(headerText), 'uint8');
    if headerCount ~= numel(uint8(headerText))
        error('Failed to write the complete header to: %s', outputPath);
    end

    % Write the selected original image bytes immediately after the header.
    payloadCount = fwrite(fid, frameBytes, 'uint8');
    if payloadCount ~= numel(frameBytes)
        error('Failed to write the complete image payload to: %s', outputPath);
    end
end
