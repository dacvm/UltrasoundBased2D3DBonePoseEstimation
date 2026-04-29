function T_mesh_ref = stateVectorToTMatrix(stateVector, T_init_originct)
%STATEVECTORTOTMATRIX Convert a 6D SE(3) perturbation vector into a 4x4 transform.
% This function declaration defines how optimizer numbers become a rigid candidate pose.
%
% What this function does:
%   This function maps a flat 6-by-1 optimizer vector into the SE(3)
%   manifold, then applies that transform as a left/reference-frame update
%   around the manual initial pose.
%
% Why this function exists:
%   The cost function needs a full transform matrix because the mesh vertices
%   must be moved in 3D space before intersection with ultrasound planes.
%   Optimizers usually change a small numeric vector instead. This function
%   is the bridge from optimizer vector parameters to a valid rigid transform.
%   The initial transform is a separate input because the state vector is a
%   local correction around that pose, not a full absolute pose by itself.
%
% Reasoning example:
%   A zero vector means "do not change the manual pose", so this function
%   returns T_init_originct. A vector [10; 0; 0; 0; 0; 0] means "move the
%   manual pose 10 distance-units along reference-frame X". The state vector
%   only stores that correction; T_init_originct stores the large baseline
%   pose that came from calibration and manual alignment.
%
% Inputs:
%   stateVector:
%       6-value optimizer perturbation vector:
%           [vx; vy; vz; wx; wy; wz]
%       The v values use the same distance unit as the mesh and transforms.
%       The w values are a rotation vector in radians.
%
%   T_init_originct:
%       Initial 4-by-4 mesh pose. This is the manual alignment that the
%       optimizer perturbs. The function needs this second input because the
%       optimizer vector is measured relative to this pose.
%
% Output:
%   T_mesh_ref:
%       Candidate 4-by-4 mesh transform that can be passed into
%       computeProbeFacingPixelsForPose.
%
% Important details for junior developers:
%   - The optimizer vector is flat, but rotations are not flat.
%   - expm maps the small se(3) matrix xi_hat back onto the SE(3) manifold.
%   - The selected convention is a left/reference-frame update:
%       T_mesh_ref = expm(xi_hat) * T_init_originct
%   - The inverse helper uses the matching rule:
%       stateVector = TMatrixToStateVector(T_mesh_ref, T_init_originct)

% Check that the optimizer state is a finite numeric vector so expm receives valid real values.
validateattributes(stateVector, {'numeric'}, {'vector', 'numel', 6, 'finite'}, mfilename, 'stateVector');

% Check that the initial pose is a finite 4-by-4 numeric matrix before applying the perturbation around it.
validateattributes(T_init_originct, {'numeric'}, {'size', [4 4], 'finite'}, mfilename, 'T_init_originct');

% Force row or column input into the column convention documented above.
stateVector = stateVector(:);

% Read the translation part of the twist in the reference-frame distance unit.
v_ref = stateVector(1:3);

% Read the rotation-vector part of the twist in radians.
w_ref = stateVector(4:6);

% Build the skew-symmetric matrix that represents cross products with the rotation vector.
w_hat_ref = [ 0,        -w_ref(3),  w_ref(2); ...
              w_ref(3),  0,        -w_ref(1); ...
             -w_ref(2),  w_ref(1),  0        ];

% Pack the twist into an se(3) matrix so MATLAB can apply the matrix exponential.
xi_hat_ref = [w_hat_ref, v_ref; 0, 0, 0, 0];

% Map the flat perturbation vector back to a valid 4-by-4 rigid transform on SE(3).
T_delta_ref = expm(xi_hat_ref);

% Apply the perturbation on the left so translation and rotation are expressed in the reference frame.
T_mesh_ref = T_delta_ref * T_init_originct;
end
