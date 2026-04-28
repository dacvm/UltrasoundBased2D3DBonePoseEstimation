function stateVector = TMatrixToStateVector(T_mesh_ref)
%TMATRIXTOSTATEVECTOR Create the starting state vector for future optimization.
% This function declaration marks where a real transform-to-state convention should be implemented later.
%
% What this function does:
%   This placeholder converts an initial 4-by-4 mesh transform into a state
%   vector that a future optimizer can edit. At the moment, it does not
%   decompose the transform. It only validates the input and returns a
%   six-value zero vector.
%
% Why this function exists:
%   Most MATLAB optimizers work with vectors, not 4-by-4 transform matrices.
%   A future implementation will likely use a vector such as
%   [tx ty tz rx ry rz], where tx, ty, and tz are translations, and rx, ry,
%   and rz are rotation parameters. This function is the planned place for
%   converting the starting transform into that vector representation.
%
% Input:
%   T_mesh_ref:
%       Initial 4-by-4 transform that places the mesh in the reference frame.
%
% Output:
%   stateVector:
%       Placeholder 6-by-1 vector. For now, zeros mean "no perturbation from
%       the initial pose".
%
% Important details:
%   - Keep this function paired with stateVectorToTMatrix, so the
%     vector-to-transform and transform-to-vector conventions match.

% Check that the starting transform is a 4-by-4 numeric matrix before future pose decomposition is added.
validateattributes(T_mesh_ref, {'numeric'}, {'size', [4 4]}, mfilename, 'T_mesh_ref');

% Return six zeros as a placeholder perturbation vector: [tx ty tz rx ry rz].
stateVector = zeros(6, 1);
end
