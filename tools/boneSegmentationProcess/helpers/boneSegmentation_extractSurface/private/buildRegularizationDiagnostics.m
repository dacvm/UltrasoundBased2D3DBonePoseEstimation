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
