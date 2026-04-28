function sequence = read_sequence_image(filePath)
%READ_SEQUENCE_IMAGE Parse a Plus Sequence Image (*.mha) file.
% This reads a Sequence Image file that contains:
% - A text header with general fields and per-frame metadata
% - A binary payload (image bytes) after the line: ElementDataFile = LOCAL
%
% Output struct layout:
%   sequence.header  : struct with general header fields
%   sequence.packets : 1xN struct array (N = header.DimSize(3))
%
% Each packet struct contains:
%   ProbeToTrackerDeviceTransform               (4x4 double)
%   ProbeToTrackerDeviceTransformStatus         (logical)
%   ReferenceToTrackerDeviceTransform           (4x4 double)
%   ReferenceToTrackerDeviceTransformStatus     (logical)
%   Timestamp                                   (double)
%   ImageStatus                                 (logical)
%   Image                                       (uint8 matrix)

    % Accept both string and char inputs, then normalize to a char vector.
    % This makes the function easy to call from different MATLAB versions.
    if isstring(filePath)
        % Reject string arrays (multiple paths) because this function reads one file.
        if ~isscalar(filePath)
            error('filePath must be a character vector or string scalar.');
        end

        % Convert string scalar to classic char, since many I/O functions expect char.
        filePath = char(filePath);
    end

    % Validate the final type early so the rest of the function can assume char.
    if ~ischar(filePath)
        error('filePath must be a character vector or string scalar.');
    end

    % Fail fast if the file does not exist.
    if ~isfile(filePath)
        error('Sequence file not found: %s', filePath);
    end

    % Read the entire file as raw bytes.
    % We need raw bytes because the payload after the header is binary.
    fileBytes = read_file_as_uint8(filePath);

    % The header/payload separator in Plus sequence files is a literal line.
    % The payload begins on the next line after this text.
    separator = uint8('ElementDataFile = LOCAL');

    % Find the separator inside the file (search on a row vector for strfind).
    separatorStart = strfind(fileBytes.', separator); 
    if isempty(separatorStart)
        error('Header separator "ElementDataFile = LOCAL" was not found.');
    end

    % If the separator appears more than once, we use the first occurrence.
    separatorStart = separatorStart(1);

    % Compute the last byte index of the separator string.
    separatorEnd = separatorStart + numel(separator) - 1;

    % Compute where the image payload starts (skipping CR/LF after the separator).
    imageDataStart = find_image_data_start(fileBytes, separatorEnd);

    % Extract only the header bytes (everything before the separator line).
    if separatorStart > 1
        headerBytes = fileBytes(1:separatorStart - 1);
    else
        headerBytes = uint8([]);
    end

    % Convert header bytes into text.
    % MHA/Plus headers are ASCII-compatible key/value lines.
    headerText = char(headerBytes).';

    % Parse the header into:
    % - header: general fields like ObjectType, NDims, DimSize, ElementType, etc.
    % - frameData: per-frame fields like Seq_Frame0000_Timestamp, transforms, statuses
    [header, frameData] = parse_header_text(headerText);

    % Store ElementDataFile in the header as requested.
    % In this task, we only support LOCAL payloads (inline binary data).
    header.ElementDataFile = 'LOCAL';

    % DimSize is required because it defines image dimensions and number of frames.
    if ~isfield(header, 'DimSize')
        error('Header field "DimSize" is required but was not found.');
    end

    % Convert DimSize to numeric so we can use it in math.
    dimSize = double(header.DimSize);

    % We need at least 3 values: [width height numberOfFrames].
    if numel(dimSize) < 3
        error('Header field "DimSize" must contain 3 values.');
    end

    % In this simplified reader we treat DimSize as:
    % DimSize(1) = width, DimSize(2) = height, DimSize(3) = number of frames
    frameWidth = dimSize(1);
    frameHeight = dimSize(2);
    numPackets = dimSize(3);

    % Validate that these are whole numbers (DimSize should be integers).
    if any(abs([frameWidth, frameHeight, numPackets] - round([frameWidth, frameHeight, numPackets])) > 1e-12)
        error('DimSize values must be integers.');
    end

    % Validate that these are positive.
    if any([frameWidth, frameHeight, numPackets] <= 0)
        error('DimSize values must be positive.');
    end

    % Convert to exact integers for indexing and reshape sizes.
    frameWidth = round(frameWidth);
    frameHeight = round(frameHeight);
    numPackets = round(numPackets);

    % Pre-allocate packets so we always return a 1xN struct array.
    % This also ensures every packet has the same fields.
    packets = initialize_packets(numPackets);

    % Copy the parsed per-frame metadata into the matching packet index.
    % Packets with missing metadata keep default values.
    packets = merge_frame_data(packets, frameData);

    % Slice the binary payload bytes out of the file.
    % This is everything after the separator line and its newline.
    imageData = fileBytes(imageDataStart:end);

    % Compute how many bytes a single frame image should occupy.
    % Task requirement: treat each pixel as 1 byte (uint8).
    bytesPerFrame = frameWidth * frameHeight;

    % Compute how many bytes we expect for all frames.
    expectedBytes = bytesPerFrame * numPackets;

    % Compute how many complete frames are actually available in the payload.
    availableFrames = floor(double(numel(imageData)) / double(bytesPerFrame));

    % Only decode up to DimSize(3) frames.
    framesToLoad = min(double(numPackets), availableFrames);

    % Decode each frame and store it in packet.Image.
    for packetIndex = 1:framesToLoad
        % Compute the byte range for this frame.
        byteStart = (packetIndex - 1) * bytesPerFrame + 1;
        byteEnd = byteStart + bytesPerFrame - 1;

        % Extract the raw bytes for this frame.
        frameBytes = imageData(byteStart:byteEnd);

        % Reshape flat bytes into a 2D uint8 image.
        % We store shape [width, height] as requested.
        packets(packetIndex).Image = reshape(frameBytes, [frameWidth, frameHeight]);
    end

    % Warn when the file payload does not match what DimSize claims.
    % This commonly happens with dummy/example files that omit the full binary payload.
    if numel(imageData) < expectedBytes
        warning(['Image payload is shorter than expected (%d < %d bytes). ', ...
                 'Missing packet.Image values remain empty.'], ...
                 numel(imageData), expectedBytes);
    elseif numel(imageData) > expectedBytes
        warning(['Image payload is longer than expected (%d > %d bytes). ', ...
                 'Extra trailing bytes are ignored.'], ...
                 numel(imageData), expectedBytes);
    end

    % Build the final output struct with the requested top-level fields.
    sequence = struct();
    sequence.header = header;
    sequence.packets = packets;
end

function bytes = read_file_as_uint8(filePath)
%READ_FILE_AS_UINT8 Read an entire file into a uint8 vector.
% We use binary mode to avoid newline conversion issues on Windows.

    % Open file in binary read mode.
    fid = fopen(filePath, 'rb');
    if fid < 0
        error('Cannot open file: %s', filePath);
    end

    % Ensure the file always gets closed (even if an error occurs later).
    cleaner = onCleanup(@() fclose(fid));

    % Read all bytes as uint8.
    bytes = fread(fid, inf, '*uint8');
end

function imageDataStart = find_image_data_start(fileBytes, separatorEnd)
%FIND_IMAGE_DATA_START Return the first payload byte after the separator line.
% The payload begins after the newline following "ElementDataFile = LOCAL".

    % Start right after the last byte of the separator string.
    imageDataStart = separatorEnd + 1;

    % If separator is at the end of the file, then payload is empty.
    if imageDataStart > numel(fileBytes)
        imageDataStart = numel(fileBytes) + 1;
        return;
    end

    % Skip newline characters after the separator.
    % Windows files often use CRLF (13 then 10), while Unix uses LF (10).
    if fileBytes(imageDataStart) == 13
        % Skip CR.
        imageDataStart = imageDataStart + 1;

        % If the next byte is LF, skip it too.
        if imageDataStart <= numel(fileBytes) && fileBytes(imageDataStart) == 10
            imageDataStart = imageDataStart + 1;
        end
    elseif fileBytes(imageDataStart) == 10
        % Skip LF.
        imageDataStart = imageDataStart + 1;
    end
end

function [header, frameData] = parse_header_text(headerText)
%PARSE_HEADER_TEXT Parse header text into general fields and per-frame fields.
% Header lines generally look like:
%   FieldName = FieldValue
% Per-frame lines look like:
%   Seq_Frame0000_Timestamp = 0.024

    % This struct will store general header key/value pairs.
    header = struct();

    % This struct will store per-frame packet metadata keyed by "F1", "F2", ...
    % (1-based frame index to match MATLAB indexing).
    frameData = struct();

    % Split the header into lines (support CRLF, LF, and CR).
    lines = regexp(headerText, '\r\n|\n|\r', 'split');

    % Pattern for "key = value".
    fieldPattern = '^\s*([^=]+?)\s*=\s*(.*?)\s*$';

    % Pattern for per-frame keys like "Seq_Frame0000_Timestamp".
    framePattern = '^Seq_Frame(\d+)_([A-Za-z0-9_]+)$';

    % Process each line in the header.
    for i = 1:numel(lines)
        % Trim spaces and ignore empty lines.
        line = strtrim(lines{i});
        if isempty(line)
            continue;
        end

        % Parse the "key = value" layout.
        tokens = regexp(line, fieldPattern, 'tokens', 'once');
        if isempty(tokens)
            % If the line is not "key = value", ignore it.
            continue;
        end

        % Extract key and value as raw strings.
        rawField = strtrim(tokens{1});
        rawValue = strtrim(tokens{2});

        % Check if this is a per-frame key.
        frameTokens = regexp(rawField, framePattern, 'tokens', 'once');
        if isempty(frameTokens)
            % General header field: store under a MATLAB-safe field name.
            matlabField = matlab.lang.makeValidName(rawField);

            % Convert the value to a suitable MATLAB type (logical/numeric/text).
            header.(matlabField) = parse_general_value(rawValue);
            continue;
        end

        % Convert the file's 0-based frame index to MATLAB's 1-based index.
        frameIndex = str2double(frameTokens{1}) + 1;

        % Extract the field name after the frame prefix.
        seqFieldName = frameTokens{2};

        % Build a stable per-frame key so we can store it in a struct.
        frameId = sprintf('F%d', frameIndex);

        % Ensure the frame has a packet struct, even if we only see some fields.
        if ~isfield(frameData, frameId)
            frameData.(frameId) = make_packet_template();
        end

        % Get the current packet for this frame, update it, then store it back.
        packet = frameData.(frameId);
        switch seqFieldName
            case 'ProbeToTrackerDeviceTransform'
                % 16 numbers -> 4x4 transform matrix.
                packet.ProbeToTrackerDeviceTransform = parse_transform_4x4(rawValue);
            case 'ProbeToTrackerDeviceTransformStatus'
                % "OK"/"INVALID" -> boolean.
                packet.ProbeToTrackerDeviceTransformStatus = parse_status(rawValue);
            case 'ReferenceToTrackerDeviceTransform'
                packet.ReferenceToTrackerDeviceTransform = parse_transform_4x4(rawValue);
            case 'ReferenceToTrackerDeviceTransformStatus'
                packet.ReferenceToTrackerDeviceTransformStatus = parse_status(rawValue);
            case 'Timestamp'
                % Timestamp can be fractional (double) or integer-like.
                packet.Timestamp = parse_timestamp(rawValue);
            case 'ImageStatus'
                packet.ImageStatus = parse_status(rawValue);
            otherwise
                % Ignore other frame fields not requested by the task.
        end

        % Save the updated packet.
        frameData.(frameId) = packet;
    end
end

function packets = initialize_packets(numPackets)
%INITIALIZE_PACKETS Pre-allocate a 1xN packet struct array.

    % Create one template packet.
    template = make_packet_template();

    % Replicate it N times (fast and ensures a consistent struct layout).
    packets = repmat(template, 1, numPackets);
end

function template = make_packet_template()
%MAKE_PACKET_TEMPLATE Define the default packet struct layout.

    % Default values are chosen to make missing data obvious:
    % - transforms start as NaN(4,4)
    % - statuses start as false
    % - Image is empty until payload decoding fills it
    template = struct( ...
        'ProbeToTrackerDeviceTransform', nan(4, 4), ...
        'ProbeToTrackerDeviceTransformStatus', false, ...
        'ReferenceToTrackerDeviceTransform', nan(4, 4), ...
        'ReferenceToTrackerDeviceTransformStatus', false, ...
        'Timestamp', 0, ...
        'ImageStatus', false, ...
        'Image', uint8([]));
end

function packets = merge_frame_data(packets, frameData)
%MERGE_FRAME_DATA Copy parsed per-frame metadata into the packet array.

    % Get all frame keys (e.g., "F1", "F2", ...).
    frameIds = fieldnames(frameData);

    for i = 1:numel(frameIds)
        % Convert the key back to an integer index.
        frameId = frameIds{i};
        frameIndex = sscanf(frameId, 'F%d');
        if isempty(frameIndex)
            continue;
        end

        % Ignore frame metadata outside the declared packet count.
        if frameIndex < 1 || frameIndex > numel(packets)
            warning('Frame metadata index %d is outside DimSize(3) and is ignored.', frameIndex - 1);
            continue;
        end

        % Overwrite default packet fields with the parsed metadata packet.
        packets(frameIndex) = frameData.(frameId);
    end
end

function value = parse_general_value(rawValue)
%PARSE_GENERAL_VALUE Convert a header value string into a useful MATLAB type.
% Rules:
% - "True"/"False" -> logical
% - "1 2 3" -> numeric vector (int64 if all integer-like, else double)
% - otherwise -> char text

    % Remove extra whitespace.
    rawValue = strtrim(rawValue);

    % Parse textual booleans.
    if strcmpi(rawValue, 'true')
        value = true;
        return;
    end
    if strcmpi(rawValue, 'false')
        value = false;
        return;
    end

    % Try to parse as a list of numbers.
    tokens = strsplit(rawValue);
    nums = str2double(tokens);

    % If all tokens parsed into valid numbers, keep them as numeric.
    if ~any(isnan(nums))
        % If every number is integer-like, store as int64; else keep as double.
        if all(abs(nums - round(nums)) < 1e-12)
            value = int64(round(nums));
        else
            value = nums;
        end
        return;
    end

    % Fallback to a plain text value.
    value = rawValue;
end

function tf = parse_status(rawValue)
%PARSE_STATUS Convert common status values into boolean.
% We treat OK/TRUE/1 as true, everything else as false.

    % Normalize case and whitespace.
    normalized = upper(strtrim(rawValue));

    % Map status strings into a boolean.
    tf = strcmp(normalized, 'OK') || strcmp(normalized, 'TRUE') || strcmp(normalized, '1');
end

function t = parse_transform_4x4(rawValue)
%PARSE_TRANSFORM_4X4 Parse 16 numeric values into a 4x4 matrix.

    % Split the value string into tokens and convert each to double.
    values = str2double(strsplit(strtrim(rawValue)));

    % Validate that we got exactly 16 numeric values.
    if numel(values) ~= 16 || any(isnan(values))
        warning('Invalid transform field encountered. Returning NaN(4,4).');
        t = nan(4, 4);
        return;
    end

    % Reshape into 4x4 and transpose.
    % This matches how these files typically list matrix elements in one line.
    t = reshape(values, [4, 4]).';
end

function ts = parse_timestamp(rawValue)
%PARSE_TIMESTAMP Parse a timestamp value and always return it as double.

    % Convert the string to a number.
    num = str2double(strtrim(rawValue));

    % If conversion fails, return NaN.
    if isnan(num)
        ts = nan;
        return;
    end

    % Keep the parsed numeric value as double for all valid timestamps.
    % This avoids mixed numeric classes (int64/double) across packets.
    ts = num;
end
