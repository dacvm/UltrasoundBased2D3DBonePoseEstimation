function colorLimits = getSurfaceRmseColorLimits(perCombinationTable)
%GETSURFACERMSECOLORLIMITS Return the shared colour range for surface RMSE.
% All evaluation plots colour combinations by their median surface RMSE.
% Taking the range from the whole combination table, instead of from what
% one figure shows, makes a given colour mean the same error in every figure.
%
% Input:
%   perCombinationTable - Combination table with medianSurfaceRmseMm.
%
% Output:
%   colorLimits         - [lowest highest] median surface RMSE (mm).

finiteRmse  = perCombinationTable.medianSurfaceRmseMm(isfinite(perCombinationTable.medianSurfaceRmseMm));
colorLimits = [min(finiteRmse), max(finiteRmse)];

% A colour range needs two different ends; widen it when all values match.
if colorLimits(1) == colorLimits(2)
    colorLimits = colorLimits + [-0.5 0.5];
end
end
