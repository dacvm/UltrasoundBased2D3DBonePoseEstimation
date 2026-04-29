function stateVector = TMatrixToStateVector(T_mesh_ref, T_init_originct)
%TMATRIXTOSTATEVECTOR Convert a candidate 4x4 transform into a 6D SE(3) perturbation vector.
% This function declaration defines the inverse mapping of stateVectorToTMatrix.
%
% What this function does:
%   This function compares a candidate mesh pose against the manual initial
%   pose. It then converts only the difference between those two poses into
%   a six-value Lie algebra vector:
%       [vx; vy; vz; wx; wy; wz]
%
% Why this function exists:
%   Most MATLAB optimizers work with vectors, not 4-by-4 transform matrices.
%   The optimizer state is not the absolute bone pose. It is a local
%   perturbation around the manual initial pose. That is why this function
%   needs both the candidate transform and the initial transform.
%
% Reasoning example:
%   If T_init_originct is the manual pose and the optimizer wants a candidate
%   that is 10 mm farther along reference-frame X, then the state vector
%   should be [10; 0; 0; 0; 0; 0]. It should not contain the full translation
%   already stored inside T_init_originct. This keeps the optimizer numbers
%   small and focused on the correction from the manual alignment.
%
% Inputs:
%   T_mesh_ref:
%       Candidate 4-by-4 transform that places the mesh in the reference
%       frame.
%
%   T_init_originct:
%       Manual initial 4-by-4 transform. This is the center pose that the
%       optimizer perturbs.
%
% Output:
%   stateVector:
%       6-by-1 perturbation vector. The v values use the same distance unit
%       as the mesh and transforms. The w values are rotation-vector
%       increments in radians.
%
% Important details:
%   - Keep this function paired with stateVectorToTMatrix so the vector
%     order and perturbation convention stay matched.
%   - The current convention is left/reference-frame update:
%       T_candidate = expm(xi_hat) * T_init
%     Therefore the inverse conversion is:
%       xi_hat = logm(T_candidate / T_init)

% Check that the candidate pose is a finite 4-by-4 numeric matrix before converting it to a perturbation.
validateattributes(T_mesh_ref, {'numeric'}, {'size', [4 4], 'finite'}, mfilename, 'T_mesh_ref');

% Check that the initial pose is a finite 4-by-4 numeric matrix because the state is measured relative to it.
validateattributes(T_init_originct, {'numeric'}, {'size', [4 4], 'finite'}, mfilename, 'T_init_originct');

% Compute the left-side transform that moves the initial pose into the candidate pose.
T_delta_ref = T_mesh_ref / T_init_originct;

% Map the relative SE(3) transform into the flat se(3) tangent space.
xi_hat_ref = logm(T_delta_ref);

% Measure any imaginary numerical residue because logm can create tiny imaginary values from roundoff.
imagMagnitude = max(abs(imag(xi_hat_ref(:))));

% Stop if the matrix logarithm is meaningfully complex because the state vector must be real for the optimizer.
if imagMagnitude > 1e-10
    error('TMatrixToStateVector:ComplexLogarithm', ...
        'The matrix logarithm produced a complex perturbation with max imaginary magnitude %.3g.', imagMagnitude);
end

% Drop tiny imaginary roundoff so the optimizer receives an ordinary real vector.
xi_hat_ref = real(xi_hat_ref);

% Read the translation part of the twist from the right column of the se(3) matrix.
v_ref = xi_hat_ref(1:3, 4);

% Read the rotation-vector part of the twist from the skew-symmetric block.
w_ref = [xi_hat_ref(3, 2); xi_hat_ref(1, 3); xi_hat_ref(2, 1)];

% Pack the perturbation using the same [v; w] order expected by stateVectorToTMatrix.
stateVector = [v_ref; w_ref];
end
