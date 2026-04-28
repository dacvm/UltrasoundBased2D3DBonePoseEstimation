function transformations = read_fcal_transforms(fcalConfigPath)
%READ_FCAL_TRANSFORMS Parse transform entries from an fCal XML configuration file.
% This function reads the <CoordinateDefinitions> section and returns one
% struct per <Transform> tag with fields: Name, Matrix, Error, and Date.

    % Accept string input, then convert it to char for MATLAB XML/file APIs.
    if isstring(fcalConfigPath)
        % Reject string arrays because this function reads one file path only.
        if ~isscalar(fcalConfigPath)
            error('fcalConfigPath must be a character vector or string scalar.');
        end

        % Convert a string scalar to char for compatibility.
        fcalConfigPath = char(fcalConfigPath);
    end

    % Validate the final type so the rest of the function can assume char.
    if ~ischar(fcalConfigPath)
        error('fcalConfigPath must be a character vector or string scalar.');
    end

    % Stop early when the target XML file does not exist.
    if ~isfile(fcalConfigPath)
        error('fCal configuration file not found: %s', fcalConfigPath);
    end

    % Parse XML text into a DOM document object.
    try
        xmlDocument = xmlread(fcalConfigPath);
    catch parseError
        % Surface parsing problems with the file path for easier debugging.
        error('Failed to parse XML file "%s": %s', fcalConfigPath, parseError.message);
    end

    % Locate the CoordinateDefinitions section that stores calibration transforms.
    coordinateDefinitionsNodes = xmlDocument.getElementsByTagName('CoordinateDefinitions');
    if coordinateDefinitionsNodes.getLength() == 0
        error('No <CoordinateDefinitions> section found in file: %s', fcalConfigPath);
    end

    % Use the first CoordinateDefinitions node (standard fCal file layout).
    coordinateDefinitionsNode = coordinateDefinitionsNodes.item(0);

    % Collect all Transform tags under CoordinateDefinitions.
    transformNodes = coordinateDefinitionsNode.getElementsByTagName('Transform');
    numberOfTransforms = transformNodes.getLength();

    % Prepare the output struct template so all entries have consistent fields.
    transformTemplate = struct( ...
        'Name', '', ...
        'Matrix', nan(4, 4), ...
        'Error', nan, ...
        'Date', '');

    % Pre-allocate a 1xN struct array for predictable output shape.
    transformations = repmat(transformTemplate, 1, numberOfTransforms);

    % Convert each XML Transform node into one MATLAB struct entry.
    for transformIndex = 1:numberOfTransforms
        % Get the current Transform node (Java DOM is 0-based index).
        transformNode = transformNodes.item(transformIndex - 1);

        % Read frame names to build the output Name as [From]To[To].
        fromFrame = strtrim(char(transformNode.getAttribute('From')));
        toFrame = strtrim(char(transformNode.getAttribute('To')));

        % Build the requested transform name format (example: ImageToProbe).
        transformations(transformIndex).Name = sprintf('%sTo%s', fromFrame, toFrame);

        % Parse the multi-line Matrix attribute into a numeric 4x4 matrix.
        matrixText = char(transformNode.getAttribute('Matrix'));
        transformations(transformIndex).Matrix = parse_matrix_attribute(matrixText, transformIndex);

        % Parse the Error attribute to double (missing/invalid values become NaN).
        errorText = char(transformNode.getAttribute('Error'));
        transformations(transformIndex).Error = parse_error_attribute(errorText, transformIndex);

        % Copy Date text exactly as saved in the fCal file.
        dateText = char(transformNode.getAttribute('Date'));
        transformations(transformIndex).Date = strtrim(dateText);
    end
end

function matrixValue = parse_matrix_attribute(matrixText, transformIndex)
%PARSE_MATRIX_ATTRIBUTE Convert matrix attribute text into a 4x4 double matrix.

    % Read all numeric values from the text, including values split over lines.
    matrixNumbers = sscanf(matrixText, '%f');

    % Validate element count because a rigid transform must be 4x4 (16 numbers).
    if numel(matrixNumbers) ~= 16
        warning(['Transform #%d has %d matrix values (expected 16). ', ...
                 'Returning NaN(4,4) for this matrix.'], ...
                transformIndex, numel(matrixNumbers));
        matrixValue = nan(4, 4);
        return;
    end

    % Reshape row-wise listed values into a proper 4x4 MATLAB matrix.
    matrixValue = reshape(matrixNumbers, [4, 4]).';
end

function errorValue = parse_error_attribute(errorText, transformIndex)
%PARSE_ERROR_ATTRIBUTE Convert Error attribute text to a double value.

    % Remove surrounding spaces so empty checks and conversion are reliable.
    errorText = strtrim(errorText);

    % Handle missing Error attributes (some transforms in real files omit Error).
    if isempty(errorText)
        errorValue = nan;
        return;
    end

    % Convert numeric text into double.
    errorValue = str2double(errorText);

    % Guard against non-numeric text so downstream code gets a predictable NaN.
    if isnan(errorValue)
        warning(['Transform #%d has a non-numeric Error value "%s". ', ...
                 'Returning NaN for this error.'], ...
                transformIndex, errorText);
    end
end
