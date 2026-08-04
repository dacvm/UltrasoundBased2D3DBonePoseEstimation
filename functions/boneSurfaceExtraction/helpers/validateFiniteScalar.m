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
