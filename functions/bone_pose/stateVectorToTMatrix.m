function T_mesh_ref = stateVectorToTMatrix(stateVector, T_init_originct)
%STATEVECTORTOTMATRIX Convert a future optimizer state vector into a 4x4 transform.
% This function declaration marks the exact place where the state parameterization should be implemented later.
%
% What this function does:
%   This placeholder converts an optimizer state vector back into a 4-by-4
%   mesh transform. At the moment, it validates the inputs and returns the
%   initial transform unchanged.
%
% Why this function exists:
%   The cost function needs a full transform matrix because the mesh vertices
%   must be moved in 3D space before intersection with ultrasound planes.
%   Optimizers usually change a small numeric vector instead. This function
%   will become the bridge from optimizer vector parameters to a transform
%   matrix.
%
% Inputs:
%   stateVector:
%       Future optimizer parameters. The current placeholder expects a
%       numeric vector but does not use its values yet.
%
%   T_init_originct:
%       Initial 4-by-4 mesh pose. The current placeholder returns this
%       transform directly.
%
% Output:
%   T_mesh_ref:
%       Candidate 4-by-4 mesh transform that can be passed into
%       computeProbeFacingPixelsForPose.
%
% Important details for junior developers:
%   - When the real pose convention is implemented, this function should
%     apply the stateVector as a perturbation around T_init_originct.
%   - Be careful with rotation units later. Decide clearly whether rx, ry,
%     rz are degrees, radians, Euler angles, or another representation.

% Check that the state vector is numeric before future state-to-transform math is added.
validateattributes(stateVector, {'numeric'}, {'vector'}, mfilename, 'stateVector');

% Check that the initial transform is a 4-by-4 numeric matrix because this placeholder returns it directly.
validateattributes(T_init_originct, {'numeric'}, {'size', [4 4]}, mfilename, 'T_init_originct');

% Return the initial transform unchanged until the real pose-vector convention is chosen.
T_mesh_ref = T_init_originct;
end
