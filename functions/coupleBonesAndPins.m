function boneUnits = coupleBonesAndPins(bones, bonepins, pinSelection)
%COUPLEBONESANDPINS Couple each bone with its pins and selected pin.
%   This function prepares the bone and pin data for later processing and
%   display. The CT file stores bones and pins in separate struct arrays,
%   so their array positions cannot safely be used as a relationship: one
%   bone may have one pin today and two redundant pins in another dataset.
%   This function uses the shared bone code instead, groups all matching
%   pins under their bone, and records which grouped pin was selected.
%
%   BONEUNITS = COUPLEBONESANDPINS(BONES, BONEPINS, PINSELECTION) accepts:
%       BONES         - Struct array containing one entry per bone. Each
%                       entry must have at least the fields 'name' and
%                       'bone'. The 'bone' field is the stable identifier,
%                       such as 'F' for femur or 'T' for tibia.
%       BONEPINS      - Struct array containing one entry per attached pin.
%                       Each entry must have at least the fields 'bone' and
%                       'place'. The 'bone' field identifies its bone and
%                       'place' identifies the pin location, such as 'PRO'
%                       or 'DIS'. All other pin fields are preserved.
%       PINSELECTION  - Scalar struct that stores the chosen place for each
%                       bone code, for example struct('F','PRO','T','DIS').
%                       The selected place is checked against the available
%                       pins, so a spelling mistake does not go unnoticed.
%
%   BONEUNITS is a struct array with one entry per bone. Each entry contains:
%       name               - Readable bone name from BONES.
%       code               - Normalized bone identifier used for matching.
%       boneData           - The complete original bone entry.
%       pins               - Every original pin belonging to this bone.
%       selectedPinPlace   - The normalized place requested in PINSELECTION.
%       selectedPinIndex   - Index of the selected pin inside this entry's
%                            PINS array.
%   The original BONES and BONEPINS arrays are not modified. Downstream code
%   can therefore loop over BONEUNITS and use the selected pin consistently,
%   even when a bone has more than one candidate pin.

% Fail early when a caller passes a different data type than the CT loader
% produces. The remaining checks can then give more specific messages.
validateattributes(bones, {'struct'}, {'vector', 'nonempty'}, ...
    mfilename, 'bones', 1);
validateattributes(bonepins, {'struct'}, {'vector', 'nonempty'}, ...
    mfilename, 'bonepins', 2);
validateattributes(pinSelection, {'struct'}, {'scalar'}, ...
    mfilename, 'pinSelection', 3);

% These identifiers are required for coupling. The other bone and pin
% fields remain untouched inside boneData and pins.
requireStructFields(bones, {'name', 'bone'}, 'bones');
requireStructFields(bonepins, {'bone', 'place'}, 'bonepins');

% Normalize only the labels used for matching. The original loaded values
% are preserved in boneData and pins for later processing.
boneCodes = upper(strtrim(string({bones.bone})));
pinBoneCodes = upper(strtrim(string({bonepins.bone})));
pinPlaces = upper(strtrim(string({bonepins.place})));

% Empty or missing labels cannot form a reliable bone-to-pin relationship.
if any(ismissing(boneCodes) | strlength(boneCodes) == 0)
    error('coupleBonesAndPins:EmptyBoneCode', ...
        'Every bones entry must contain a nonempty bone code.');
end
if any(ismissing(pinBoneCodes) | strlength(pinBoneCodes) == 0)
    error('coupleBonesAndPins:EmptyPinBoneCode', ...
        'Every bonepins entry must contain a nonempty bone code.');
end
if any(ismissing(pinPlaces) | strlength(pinPlaces) == 0)
    error('coupleBonesAndPins:EmptyPinPlace', ...
        'Every bonepins entry must contain a nonempty place.');
end

% A bone code must identify exactly one bone. Otherwise a pin could not be
% coupled without relying on the input array order.
if numel(unique(boneCodes)) ~= numel(boneCodes)
    error('coupleBonesAndPins:DuplicateBoneCode', ...
        'Each bones entry must have a unique bone code.');
end

% Every pin must reference a known bone so accidental spelling mistakes do
% not silently leave data unused.
unknownPinCodes = setdiff(unique(pinBoneCodes), boneCodes);
if ~isempty(unknownPinCodes)
    error('coupleBonesAndPins:UnknownPinBone', ...
        'Bone pin code "%s" does not match any bones entry.', ...
        char(unknownPinCodes(1)));
end

% The place is the user-facing pin identifier within one bone. Rejecting
% duplicate pairs guarantees that one selection always has one result.
pinKeys = pinBoneCodes + "|" + pinPlaces;
if numel(unique(pinKeys)) ~= numel(pinKeys)
    error('coupleBonesAndPins:DuplicateBonePlace', ...
        'Each (bone, place) pair in bonepins must be unique.');
end

% Preallocate the output with the documented fields. The empty pins value
% keeps the same struct schema as the loaded bonepins array.
unitTemplate = struct( ...
    'name', "", ...
    'code', "", ...
    'boneData', bones(1), ...
    'pins', bonepins([]), ...
    'selectedPinPlace', "", ...
    'selectedPinIndex', []);
boneUnits = repmat(unitTemplate, 1, numel(bones));

% Build one self-contained unit per bone. Its pins array may contain one
% normal pin or several redundant pins without changing downstream loops.
for boneIndex = 1:numel(bones)
    currentCode = boneCodes(boneIndex);

    % Struct field names carry the user's selection, for example F -> PRO.
    % Requiring a valid field name keeps the configuration direct and clear.
    if ~isvarname(char(currentCode))
        error('coupleBonesAndPins:InvalidSelectionField', ...
            ['Bone code "%s" cannot be used as a pinSelection field. ' ...
             'Use a valid MATLAB field name as the bone code.'], ...
            char(currentCode));
    end
    if ~isfield(pinSelection, char(currentCode))
        error('coupleBonesAndPins:MissingSelection', ...
            'pinSelection does not define a place for bone "%s".', ...
            char(currentCode));
    end

    % Normalize the requested place exactly like the loaded pin places.
    selectedPlace = upper(strtrim(string(pinSelection.(char(currentCode)))));
    if ~isscalar(selectedPlace) || ismissing(selectedPlace) || strlength(selectedPlace) == 0
        error('coupleBonesAndPins:InvalidSelection', ...
            'The selected place for bone "%s" must be one nonempty label.', ...
            char(currentCode));
    end

    % Keep all pins belonging to this bone and locate the requested place
    % within that smaller local array.
    matchingPinMask = pinBoneCodes == currentCode;
    matchingPins = bonepins(matchingPinMask);
    matchingPlaces = pinPlaces(matchingPinMask);
    selectedPinIndex = find(matchingPlaces == selectedPlace);

    if isempty(selectedPinIndex)
        error('coupleBonesAndPins:SelectionNotFound', ...
            'Bone "%s" has no pin at place "%s".', ...
            char(currentCode), char(selectedPlace));
    end

    % Copy the original records into the coupled unit and store only the
    % selected local index, avoiding a second copy that could become stale.
    boneUnits(boneIndex).name = string(bones(boneIndex).name);
    boneUnits(boneIndex).code = currentCode;
    boneUnits(boneIndex).boneData = bones(boneIndex);
    boneUnits(boneIndex).pins = matchingPins;
    boneUnits(boneIndex).selectedPinPlace = selectedPlace;
    boneUnits(boneIndex).selectedPinIndex = selectedPinIndex;
end
end

function requireStructFields(inputStruct, requiredFields, inputName)
%REQUIRESTRUCTFIELDS Report the first required field missing from an input.

% Check the schema once so later field access cannot fail with a vague
% "unrecognized field" message.
for fieldIndex = 1:numel(requiredFields)
    currentField = requiredFields{fieldIndex};
    if ~isfield(inputStruct, currentField)
        error('coupleBonesAndPins:MissingField', ...
            '%s must contain the field "%s".', inputName, currentField);
    end
end
end
