function [E_match, details, graphicsHandles] = calculatePIMLOPMatchError( ...
    X, Y, R_p, positionCovarianceImage, kappa, options)
%CALCULATEPIMLOPMATCHERROR Calculate one nonnegative P-IMLOP match error.
%   This function evaluates one ultrasound oriented point X against one
%   model oriented point Y. It returns the nonnegative Equation (7) form so
%   a perfect position-and-orientation match has zero error. Optional plots
%   help inspect one match during development without slowing normal calls.
%
%   Paper notation used in this function
%   ------------------------------------
%   X.position3D     corresponds to x_3dp, the measured ultrasound point.
%   X.normal2DImage  corresponds to x_2dn, its measured in-plane unit normal.
%   Y.position3D     corresponds to y_3dp, one candidate model point.
%   Y.normal3D       corresponds to y_3dn, its 3D model-surface unit normal.
%   R_p              is the image-plane rotation used in Equations (1)-(3).
%   Sigma3D          corresponds to Sigma, the covariance of x_3dp.
%   kappa            is the concentration of the 2D von Mises normal model.
%
%   Equation (3) combines a Gaussian position term and a von Mises
%   orientation term:
%
%     E_match,Eq3 = 1/2*(y_3dp-x_3dp)'*inv(Sigma)*(y_3dp-x_3dp)
%                   - kappa*cos(theta).
%
%   Equation (7) adds the constant kappa and is the form returned here:
%
%     E_match = E_position + kappa*(1-cos(theta)).
%
%   The two forms select the same best correspondence because their values
%   differ only by the fixed constant kappa for this measurement.
%
%   Inputs
%   ------
%   X : Scalar structure describing the ultrasound measurement. It must have
%       position3D, a 3x1 position in the chosen shared 3D frame, and
%       normal2DImage, a nonzero 2x1 normal in the ultrasound image plane.
%   Y : Scalar structure describing the model correspondence. It must have
%       position3D, a 3x1 position in the same shared 3D frame, and normal3D,
%       a nonzero 3x1 model normal in that frame.
%   R_p : 3x3 rotation from the local ultrasound image frame into the shared
%       3D frame. Thus, R_p' rotates y_3dn back into local image X-Y-Z before
%       the projection operator P removes its image-Z component.
%   positionCovarianceImage : 3x3 positive-definite positional covariance in
%       the local image X-Y-Z frame. Keeping it separate from X allows one
%       shared noise model or a different matrix for an individual point.
%       The function rotates it into the shared 3D frame to obtain the Sigma
%       used in the positional term of Equations (3), (5), and (7).
%   kappa : Nonnegative von Mises concentration for the measured 2D normal.
%   options : Optional scalar structure controlling diagnostics. ShowDisplay
%       enables plotting; Axes must then be supplied by the caller.
%       NormalDisplayScale controls arrow length, ConfidenceProbability
%       controls the covariance ellipsoid, ShowLabels controls distance
%       labels, and Verbose controls command-window reporting.
%
%   Outputs
%   -------
%   E_match : Nonnegative Equation (7) match error, equal to E_position plus
%       kappa*(1-cos(theta)).
%   details : Structure containing the intermediate distances, orientation
%       quantities, covariance in the shared 3D frame, and the Equation (3)
%       match value.
%   graphicsHandles : Structure containing handles created when ShowDisplay
%       is true. Its fields contain empty graphics arrays otherwise.

narginchk(5, 6);

% Use quiet, calculation-only behavior unless the caller explicitly asks for
% diagnostics. During P-IMLOP, this function may be evaluated many times for
% candidate correspondences, so figure creation and printing must be opt-in.
if nargin < 6 || isempty(options)
    options = struct();
end
if ~isstruct(options) || ~isscalar(options)
    error('calculatePIMLOPMatchError:InvalidOptions', ...
          'options must be a scalar structure.');
end

if ~isfield(options, 'ShowDisplay')
    options.ShowDisplay = false;
end
if ~isfield(options, 'Axes')
    options.Axes = [];
end
if ~isfield(options, 'NormalDisplayScale')
    options.NormalDisplayScale = [];
end
if ~isfield(options, 'ConfidenceProbability')
    options.ConfidenceProbability = 0.95;
end
if ~isfield(options, 'ShowLabels')
    options.ShowLabels = true;
end
if ~isfield(options, 'Verbose')
    options.Verbose = false;
end

% Require scalar logical flags so accidental arrays do not create ambiguous
% display or printing behavior.
validateattributes(options.ShowDisplay, {'logical', 'numeric'}, {'scalar'}, mfilename, 'options.ShowDisplay');
validateattributes(options.ShowLabels,  {'logical', 'numeric'}, {'scalar'}, mfilename, 'options.ShowLabels');
validateattributes(options.Verbose,     {'logical', 'numeric'}, {'scalar'}, mfilename, 'options.Verbose');
showDisplay = logical(options.ShowDisplay);
showLabels  = logical(options.ShowLabels);
verbose     = logical(options.Verbose);

% Check the two point structures before reading their fields. Keeping these
% errors close to the interface makes frame or shape mistakes easier to find.
requiredXFields = {'position3D', 'normal2DImage'};
requiredYFields = {'position3D', 'normal3D'};
if ~isstruct(X) || ~isscalar(X) || ~all(isfield(X, requiredXFields))
    error('calculatePIMLOPMatchError:InvalidX', ...
          'X must be a scalar structure with position3D and normal2DImage.');
end
if ~isstruct(Y) || ~isscalar(Y) || ~all(isfield(Y, requiredYFields))
    error('calculatePIMLOPMatchError:InvalidY', ...
          'Y must be a scalar structure with position3D and normal3D.');
end

validateattributes(X.position3D,    {'numeric'}, {'real', 'finite', 'size', [3, 1]}, mfilename, 'X.position3D');
validateattributes(X.normal2DImage, {'numeric'}, {'real', 'finite', 'size', [2, 1]}, mfilename, 'X.normal2DImage');
validateattributes(Y.position3D,    {'numeric'}, {'real', 'finite', 'size', [3, 1]}, mfilename, 'Y.position3D');
validateattributes(Y.normal3D,      {'numeric'}, {'real', 'finite', 'size', [3, 1]}, mfilename, 'Y.normal3D');
validateattributes(R_p, {'numeric'}, {'real', 'finite', 'size', [3, 3]}, mfilename, 'R_p');
validateattributes(positionCovarianceImage, {'numeric'}, {'real', 'finite', 'size', [3, 3]}, mfilename, 'positionCovarianceImage');
validateattributes(kappa, {'numeric'}, {'real', 'finite', 'scalar', 'nonnegative'}, mfilename, 'kappa');

% Equations (1), (3), and (7) compare unit directions. In paper notation,
% x_2dn is already a unit 2D direction, and y_3dn is a unit 3D direction.
% Normalize local copies here so harmless magnitude drift in stored data does
% not change their dot product or the resulting von Mises orientation term.
normalLengthTolerance = 1e-12;
xNormalLength = norm(X.normal2DImage);
yNormalLength = norm(Y.normal3D);
if xNormalLength <= normalLengthTolerance
    error('calculatePIMLOPMatchError:ZeroMeasuredNormal', ...
          'X.normal2DImage must have nonzero length.');
end
if yNormalLength <= normalLengthTolerance
    error('calculatePIMLOPMatchError:ZeroModelNormal', ...
          'Y.normal3D must have nonzero length.');
end
xNormal2DImage = double(X.normal2DImage) / xNormalLength;
yNormal3D      = double(Y.normal3D) / yNormalLength;

% R_p defines the tracked ultrasound plane orientation in the paper. It must
% be a proper rotation because both R_p' * y_3dn and R_p * Sigma * R_p' rely
% on its inverse being its transpose. The tolerance permits normal tracking
% round-off while still catching a scale, reflection, or wrong matrix.
rotationOrthogonalityError = norm(R_p.' * R_p - eye(3), 'fro');
rotationDeterminantError   = abs(det(R_p) - 1);
rotationTolerance          = 1e-6;
if rotationOrthogonalityError > rotationTolerance || ...
        rotationDeterminantError > rotationTolerance
    error('calculatePIMLOPMatchError:InvalidRotation', ...
          'R_p must be a proper 3D rotation matrix.');
end

% Sigma describes a three-dimensional Gaussian uncertainty around x_3dp.
% Such a covariance must be symmetric and positive definite: its variances
% must be positive in every direction. Symmetrize only the tiny round-off
% allowed by the check, then use Cholesky as the final validity test.
covarianceScale = max(1, norm(positionCovarianceImage, 'fro'));
covarianceSymmetryError = norm(positionCovarianceImage - positionCovarianceImage.', 'fro');
if covarianceSymmetryError > 1e-10 * covarianceScale
    error('calculatePIMLOPMatchError:AsymmetricCovariance', ...
          'positionCovarianceImage must be symmetric.');
end
SigmaImage = 0.5 * (double(positionCovarianceImage) + double(positionCovarianceImage).');
[~, covarianceCholeskyStatus] = chol(SigmaImage, 'lower');
if covarianceCholeskyStatus ~= 0
    error('calculatePIMLOPMatchError:NonPositiveDefiniteCovariance', ...
          'positionCovarianceImage must be positive definite.');
end

% The paper writes Sigma in the same 3D coordinate system as x_3dp and y_3dp.
% Our reusable input instead describes uncertainty along local image X, Y,
% and Z, where the out-of-plane variance can be larger. Rotate that uncertainty
% ellipsoid into the shared 3D frame using
%
%     Sigma_3D = R_p * Sigma_image * R_p'.
%
% Translation does not appear because covariance describes spread and
% orientation around a point, not the position of the centre itself.
Sigma3D = R_p * SigmaImage * R_p.';
Sigma3D = 0.5 * (Sigma3D + Sigma3D.');

% Form the positional residual d = y_3dp - x_3dp from Equation (3). The paper
% weights this residual by inv(Sigma), so displacement along a reliable axis
% costs more than the same displacement along an uncertain axis:
%
%     E_position = 1/2 * d' * inv(Sigma_3D) * d.
%
% Do not form inv(Sigma_3D) explicitly. If Sigma_3D = L*L', then L\d is
% the residual expressed in standard-deviation units, and ||L\d||^2 is the
% squared Mahalanobis distance. This Cholesky solve is numerically safer.
positionResidual3D          = double(Y.position3D) - double(X.position3D);
covarianceCholeskyLower     = chol(Sigma3D, 'lower');
normalizedPositionResidual  = covarianceCholeskyLower \ positionResidual3D;
mahalanobisDistanceSquared  = normalizedPositionResidual.' * normalizedPositionResidual;
E_position                  = 0.5 * mahalanobisDistanceSquared;
mahalanobisDistance         = sqrt(mahalanobisDistanceSquared);
euclideanDistanceMm         = norm(positionResidual3D);

% Reproduce the projection inside the orientation term of Equation (1):
%
%     projected_y_2dn = P(R_p' * y_3dn) / ||P(R_p' * y_3dn)||.
%
% R_p' first expresses the model normal in local image X-Y-Z coordinates.
% P then keeps image X and Y while removing image Z. Projection shortens the
% vector, so divide by its new length to restore a 2D unit direction. When
% the model normal points along image Z, the projected vector is zero. The
% paper authors' implementation treats this as zero orientation agreement.
yNormal3DImage = R_p.' * yNormal3D;
projectedYNormal2DImageUnnormalized = yNormal3DImage(1:2);
projectedYNormalLength = norm(projectedYNormal2DImageUnnormalized);
if projectedYNormalLength <= normalLengthTolerance
    projectedYNormal2DImage = zeros(2, 1);
    projectionIsDefined = false;
else
    projectedYNormal2DImage = ...
        projectedYNormal2DImageUnnormalized / projectedYNormalLength;
    projectionIsDefined = true;
end

% The orientation factor in Equations (1), (3), and (7) is the dot product
%
%     projected_y_2dn' * x_2dn = cos(theta),
%
% where theta is the in-plane angle between the projected model normal and
% the measured ultrasound normal. Clamp only floating-point drift outside
% [-1,1] so ACOS and the nonnegative mismatch remain mathematically valid.
orientationCosineRaw = projectedYNormal2DImage.' * xNormal2DImage;
orientationCosine    = min(1, max(-1, orientationCosineRaw));
orientationAngleRad  = acos(orientationCosine);
orientationAngleDeg  = rad2deg(orientationAngleRad);

% Equation (3) uses -kappa*cos(theta). It is expected to be negative for a
% good match: perfect alignment gives -kappa, perpendicular normals give 0,
% and opposite normals give +kappa. Equation (7) adds kappa and instead uses
% kappa*(1-cos(theta)); its orientation mismatch ranges from 0 to 2*kappa.
% This function returns Equation (7) because zero then means a perfect match,
% while details.E_matchEquation3 preserves the paper's Equation (3) value.
E_orientation         = -kappa * orientationCosine;
E_orientationMismatch =  kappa * (1 - orientationCosine);
E_matchEquation3      =  E_position + E_orientation;
E_match               =  E_position + E_orientationMismatch;

% The chord distance is a display diagnostic, not another term from the paper.
% For two unit vectors it satisfies
%
%     d_chord = ||projected_y_2dn - x_2dn||
%             = sqrt(2*(1-cos(theta))).
%
% It gives the dashed line a geometric label, but it must not be added to
% E_match because Equation (7) already contains the orientation mismatch.
orientationChordDistance = norm(projectedYNormal2DImage - xNormal2DImage);

% Guard the exact relationship
%
%     E_match,Eq7 = E_match,Eq3 + kappa.
%
% This is why the PD-tree can use Equation (7) while Equation (3)/(4) can be
% used elsewhere without changing the chosen correspondence or optimum pose.
matchShiftTolerance = 1e-12 * max(1, abs(E_match));
if abs(E_match - (E_matchEquation3 + kappa)) > matchShiftTolerance
    error('calculatePIMLOPMatchError:MatchErrorShiftMismatch', ...
          'The Equation (7) match error must equal Equation (3) plus kappa.');
end

% These percentages are only a debugging summary of the nonnegative Equation
% (7) value. They are not probabilities and are not part of P-IMLOP itself.
if E_match > 0
    positionContributionPercent    = 100 * E_position / E_match;
    orientationContributionPercent = 100 * E_orientationMismatch / E_match;
else
    positionContributionPercent    = 0;
    orientationContributionPercent = 0;
end

% Return the intermediate values so a caller can trace every part of the
% equations without requiring command-window output or graphics. In
% particular, expose both Equation (3) and Equation (7) conventions to avoid
% confusing their different numerical zero points.
details = struct();
details.E_position                            = E_position;
details.E_orientation                         = E_orientation;
details.E_orientationMismatch                 = E_orientationMismatch;
details.E_matchEquation3                      = E_matchEquation3;
details.positionResidual3D                    = positionResidual3D;
details.mahalanobisDistance                   = mahalanobisDistance;
details.mahalanobisDistanceSquared            = mahalanobisDistanceSquared;
details.euclideanDistanceMm                   = euclideanDistanceMm;
details.orientationCosine                     = orientationCosine;
details.orientationAngleDeg                   = orientationAngleDeg;
details.orientationChordDistance              = orientationChordDistance;
details.projectedYNormal2DImage               = projectedYNormal2DImage;
details.projectedYNormal2DImageUnnormalized   = projectedYNormal2DImageUnnormalized;
details.projectedYNormalLength                = projectedYNormalLength;
details.projectionIsDefined                   = projectionIsDefined;
details.positionCovarianceImage               = SigmaImage;
details.positionCovariance3D                  = Sigma3D;
details.positionContributionPercent           = positionContributionPercent;
details.orientationContributionPercent        = orientationContributionPercent;

% Predefine every graphics field so calculation-only callers receive a
% predictable empty structure instead of mode-dependent field names.
graphicsHandles = struct();
graphicsHandles.covarianceEllipsoid = gobjects(0);
graphicsHandles.xPoint              = gobjects(0);
graphicsHandles.xNormal             = gobjects(0);
graphicsHandles.yPoint              = gobjects(0);
graphicsHandles.yNormal             = gobjects(0);
graphicsHandles.positionResidual    = gobjects(0);
graphicsHandles.positionLabel       = gobjects(0);
graphicsHandles.projectedYNormal    = gobjects(0);
graphicsHandles.orientationChord    = gobjects(0);
graphicsHandles.orientationLabel    = gobjects(0);
graphicsHandles.legendHandles       = gobjects(0);

if showDisplay
    % The caller owns the figure and axes. Requiring that axes here prevents
    % an unexpected figure from being created inside repeated calculations.
    if isempty(options.Axes) || ~isgraphics(options.Axes, 'axes')
        error('calculatePIMLOPMatchError:MissingDisplayAxes', ...
              'options.Axes must contain a valid axes when ShowDisplay is true.');
    end
    displayAxes = options.Axes;

    % Use a caller-controlled normal length when provided. The automatic
    % fallback uses the point separation and covariance size to remain visible.
    if isempty(options.NormalDisplayScale)
        largestPositionStdMm = sqrt(max(eig(Sigma3D)));
        normalDisplayScale   = max([1, euclideanDistanceMm, 2 * largestPositionStdMm]);
    else
        validateattributes(options.NormalDisplayScale, {'numeric'}, ...
            {'real', 'finite', 'scalar', 'positive'}, mfilename, ...
            'options.NormalDisplayScale');
        normalDisplayScale = double(options.NormalDisplayScale);
    end
    validateattributes(options.ConfidenceProbability, {'numeric'}, ...
        {'real', 'finite', 'scalar', '>', 0, '<', 1}, mfilename, ...
        'options.ConfidenceProbability');
    confidenceProbability = double(options.ConfidenceProbability);

    % Keep the caller's hold state intact after adding the diagnostic objects.
    axesWasHeld = ishold(displayAxes);
    hold(displayAxes, 'on');

    % Transform the two in-plane directions into the shared 3D frame only
    % for drawing. The P-IMLOP orientation calculation above remains in local
    % image X-Y, as in Equation (1). No translation is applied because
    % normals are directions.
    xNormal3D          = R_p * [xNormal2DImage; 0];
    xNormal3D          = xNormal3D / norm(xNormal3D);
    projectedYNormal3D = R_p * [projectedYNormal2DImage; 0];
    imagePlaneNormal3D = R_p(:, 3) / norm(R_p(:, 3));

    % Visualize the Gaussian positional model assumed in Equation (1). A joint
    % 3D confidence boundary is a constant-Mahalanobis-distance ellipsoid:
    %
    %     d' * inv(Sigma_3D) * d = chi-square quantile.
    %
    % Compute that quantile without requiring Statistics Toolbox, then map a
    % unit sphere through the same Cholesky factor used for E_position.
    confidenceRadiusScale = sqrt(2 * gammaincinv(confidenceProbability, 3 / 2));
    [unitSphereX, unitSphereY, unitSphereZ] = sphere(48);
    unitSpherePoints   = [unitSphereX(:).'; unitSphereY(:).'; unitSphereZ(:).'];
    ellipsoidPoints3D = double(X.position3D) + confidenceRadiusScale * covarianceCholeskyLower * unitSpherePoints;
    ellipsoidX3D = reshape(ellipsoidPoints3D(1, :), size(unitSphereX));
    ellipsoidY3D = reshape(ellipsoidPoints3D(2, :), size(unitSphereY));
    ellipsoidZ3D = reshape(ellipsoidPoints3D(3, :), size(unitSphereZ));

    graphicsHandles.covarianceEllipsoid = surf(displayAxes, ...
        ellipsoidX3D, ellipsoidY3D, ellipsoidZ3D, ...
        'FaceColor', [1.00, 0.55, 0.05], ...
        'FaceAlpha', 0.22, ...
        'EdgeColor', 'none', ...
        'DisplayName', sprintf('%.0f%% positional confidence ellipsoid', ...
        100 * confidenceProbability));

    % Draw the two points and their original measured/model normals.
    graphicsHandles.xPoint = scatter3(displayAxes, ...
        X.position3D(1), X.position3D(2), X.position3D(3), ...
        70, [0.90, 0.05, 0.05], 'filled', ...
        'DisplayName', 'Ultrasound point x');
    graphicsHandles.xNormal = quiver3(displayAxes, ...
        X.position3D(1), X.position3D(2), X.position3D(3), ...
        normalDisplayScale * xNormal3D(1), ...
        normalDisplayScale * xNormal3D(2), ...
        normalDisplayScale * xNormal3D(3), ...
        0, 'Color', [0.90, 0.05, 0.05], 'LineWidth', 2.5, ...
        'MaxHeadSize', 0.8, 'DisplayName', 'Ultrasound normal x_{2dn}');
    graphicsHandles.yPoint = scatter3(displayAxes, ...
        Y.position3D(1), Y.position3D(2), Y.position3D(3), ...
        70, [0.05, 0.35, 0.95], 'filled', ...
        'DisplayName', 'Model point y');
    graphicsHandles.yNormal = quiver3(displayAxes, ...
        Y.position3D(1), Y.position3D(2), Y.position3D(3), ...
        normalDisplayScale * yNormal3D(1), ...
        normalDisplayScale * yNormal3D(2), ...
        normalDisplayScale * yNormal3D(3), ...
        0, 'Color', [0.05, 0.35, 0.95], 'LineWidth', 2.5, ...
        'MaxHeadSize', 0.8, 'DisplayName', 'Model normal y_{3dn}');

    % Show the two geometries entering Equation (7): the purple line is
    % d = y_3dp-x_3dp from E_position, and the green arrow is the normalized
    % P(R_p'*y_3dn) direction used by the orientation dot product. Both red
    % and green in-plane normal arrows use exactly the same display scale.
    graphicsHandles.positionResidual = plot3(displayAxes, ...
        [X.position3D(1), Y.position3D(1)], ...
        [X.position3D(2), Y.position3D(2)], ...
        [X.position3D(3), Y.position3D(3)], ...
        '--', 'Color', [0.65, 0.10, 0.65], 'LineWidth', 2.5, ...
        'DisplayName', 'Position residual X-Y');
    graphicsHandles.projectedYNormal = quiver3(displayAxes, ...
        X.position3D(1), X.position3D(2), X.position3D(3), ...
        normalDisplayScale * projectedYNormal3D(1), ...
        normalDisplayScale * projectedYNormal3D(2), ...
        normalDisplayScale * projectedYNormal3D(3), ...
        0, 'Color', [0.05, 0.70, 0.20], 'LineWidth', 1.5, ...
        'MaxHeadSize', 0.8, ...
        'DisplayName', 'Projected model normal P(R_p^T y_{3dn})');

    % Join the equally scaled in-plane normal tips. This orange line visualizes
    % the dimensionless chord derived from cos(theta); it is deliberately kept
    % visually separate from the kappa-weighted orientation energy.
    xNormalTip3D          = double(X.position3D) + normalDisplayScale * xNormal3D;
    projectedYNormalTip3D = double(X.position3D) + normalDisplayScale * projectedYNormal3D;
    graphicsHandles.orientationChord = plot3(displayAxes, ...
        [xNormalTip3D(1), projectedYNormalTip3D(1)], ...
        [xNormalTip3D(2), projectedYNormalTip3D(2)], ...
        [xNormalTip3D(3), projectedYNormalTip3D(3)], ...
        '--', 'Color', [0.95, 0.45, 0.05], 'LineWidth', 2.0, ...
        'DisplayName', 'Orientation chord distance');

    if showLabels
        % Offset the position label within the image plane so it does not
        % cover a short residual. Use image X when the residual is degenerate.
        residualMidpoint3D = 0.5 * (double(X.position3D) + double(Y.position3D));
        positionLabelDirection3D = cross(positionResidual3D, imagePlaneNormal3D);
        if norm(positionLabelDirection3D) <= normalLengthTolerance
            positionLabelDirection3D = R_p(:, 1);
        else
            positionLabelDirection3D = positionLabelDirection3D / norm(positionLabelDirection3D);
        end
        positionLabel3D = residualMidpoint3D + 0.08 * normalDisplayScale * positionLabelDirection3D;
        graphicsHandles.positionLabel = text(displayAxes, ...
            positionLabel3D(1), positionLabel3D(2), positionLabel3D(3), ...
            sprintf('d_M = %.3f', mahalanobisDistance), ...
            'Interpreter', 'tex', 'FontSize', 9, 'FontWeight', 'bold', ...
            'Color', [0.45, 0.05, 0.45], 'Margin', 3, ...
            'HorizontalAlignment', 'center');

        % Offset the orientation label perpendicular to its chord while
        % keeping the label inside the ultrasound plane.
        orientationChord3D = projectedYNormalTip3D - xNormalTip3D;
        orientationLabelDirection3D = cross(imagePlaneNormal3D, orientationChord3D);
        if norm(orientationLabelDirection3D) <= normalLengthTolerance
            orientationLabelDirection3D = R_p(:, 1);
        else
            orientationLabelDirection3D = orientationLabelDirection3D / norm(orientationLabelDirection3D);
        end
        orientationLabel3D = 0.5 * (xNormalTip3D + projectedYNormalTip3D) + 0.08 * normalDisplayScale * orientationLabelDirection3D;
        graphicsHandles.orientationLabel = text(displayAxes, ...
            orientationLabel3D(1), orientationLabel3D(2), orientationLabel3D(3), ...
            sprintf('d_{orientation} = %.3f', orientationChordDistance), ...
            'Interpreter', 'tex', 'FontSize', 9, 'FontWeight', 'bold', ...
            'Color', [0.80, 0.30, 0.00], 'Margin', 3, ...
            'HorizontalAlignment', 'center');
    end

    % Provide an ordered list so the caller can combine these diagnostics
    % with pre-existing scene objects, such as the ultrasound image plane.
    graphicsHandles.legendHandles = [ ...
        graphicsHandles.covarianceEllipsoid; ...
        graphicsHandles.xPoint; ...
        graphicsHandles.xNormal; ...
        graphicsHandles.yPoint; ...
        graphicsHandles.yNormal; ...
        graphicsHandles.positionResidual; ...
        graphicsHandles.projectedYNormal; ...
        graphicsHandles.orientationChord];

    if ~axesWasHeld
        hold(displayAxes, 'off');
    end
    drawnow;
end

if verbose
    % Print both paper conventions side by side so a junior developer can see
    % why Equation (3) may be negative while Equation (7) is nonnegative.
    % Keep reporting optional because printing inside hundreds of candidate or
    % optimizer evaluations would otherwise become a major performance cost.
    fprintf('\nP-IMLOP one-pair match calculation:\n');
    fprintf('  Euclidean position distance             : %.6f mm\n', euclideanDistanceMm);
    fprintf('  Mahalanobis position distance           : %.6f unit\n', mahalanobisDistance);
    fprintf('  E_position                              : %.6f\n', E_position);
    fprintf('  Orientation agreement cos(theta)        : %.6f\n', orientationCosine);
    fprintf('  Orientation angle                       : %.6f deg\n', orientationAngleDeg);
    fprintf('  E_orientation (Equation 3)              : %.6f\n', E_orientation);
    fprintf('  E_orientationMismatch (Equation 7)      : %.6f\n', E_orientationMismatch);
    fprintf('  E_match (Equation 3)                    : %.6f\n', E_matchEquation3);
    fprintf('  E_match (nonnegative Equation 7)        : %.6f\n', E_match);
    fprintf('  Position contribution                   : %.2f %%\n', positionContributionPercent);
    fprintf('  Orientation contribution                : %.2f %%\n', orientationContributionPercent);
end
end
