function stateVector = TMatrixToStateVector(T_CT_ref_candidate, T_CT_ref_initial)
%TMATRIXTOSTATEVECTOR Convert a CT-to-ref transform into an optimizer state.
% This is the inverse of stateVectorToTMatrix. It removes the initial coarse
% pose, maps the remaining reference-frame correction to se(3), and returns
% the six values expected by the optimizer.
%
% Inputs:
%   T_CT_ref_candidate - Candidate 4-by-4 transform from CT to reference.
%   T_CT_ref_initial   - Initial 4-by-4 transform from CT to reference.
%
% Output:
%   stateVector        - Six-value vector [vx; vy; vz; wx; wy; wz].

% Check both transforms before comparing their poses.
validateattributes(T_CT_ref_candidate, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_CT_ref_candidate');
validateattributes(T_CT_ref_initial, {'numeric'}, ...
    {'size', [4 4], 'finite'}, mfilename, 'T_CT_ref_initial');

% Remove the initial pose on the right because the forward update is left-sided.
T_delta_ref = T_CT_ref_candidate / T_CT_ref_initial;
twistHatRef = logm(T_delta_ref);

% Matrix logarithms can contain tiny imaginary roundoff for real rigid transforms.
imaginaryMagnitude = max(abs(imag(twistHatRef(:))));
if imaginaryMagnitude > 1e-10
    error('TMatrixToStateVector:ComplexLogarithm', ...
        'The transform produced a complex state with magnitude %.3g.', ...
        imaginaryMagnitude);
end
twistHatRef = real(twistHatRef);

% Unpack the translation and rotation vector in the shared [v; w] order.
translationRef = twistHatRef(1:3, 4);
rotationVectorRef = [twistHatRef(3, 2); ...
                     twistHatRef(1, 3); ...
                     twistHatRef(2, 1)];
stateVector = [translationRef; rotationVectorRef];
end
