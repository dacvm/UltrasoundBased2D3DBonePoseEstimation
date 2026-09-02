clear; clc; close all;

%% LOAD THE SAVED OPTIMIZATION SETUP

% Resolve paths from this script so it works even when MATLAB was started
% from another folder.
developmentFolder = fileparts(mfilename('fullpath'));
projectRoot       = fileparts(fileparts(developmentFolder));
setupFilePath     = fullfile(developmentFolder, 'optimization_setup.mat');

% Add the project helpers used to draw the tracked ultrasound plane and its
% local rigid-body axes.
addpath(genpath(fullfile(projectRoot, 'functions')));

% Load the fixed fixture created from the one-sweep optimization workflow.
% The variables remain visible in the workspace for the next E_match steps.
load(setupFilePath, 'data', 'config', 'initialPoseVector');


%% SELECT ONE IMAGE PLANE AND ONE VALID ORIENTED ULTRASOUND POINT

% Surface measurements were aligned to image planes during input
% preparation, so the same index selects one image and its extracted curve.
planeIndex                 = 11;
selectedPlane              = data.imagePlanesRef(planeIndex);
selectedSurfaceMeasurement = data.boneSurfaceMeasurements(planeIndex);

% Stop with a clear message if an older setup file without surface normals
% is loaded accidentally.
requiredNormalFields = {'surfaceCoordinatesXYZRef', 'surfaceNormalXY', 'surfaceNormalMask'};
if ~all(isfield(selectedSurfaceMeasurement, requiredNormalFields))
    error('dev_Ematch_simpleSetup:MissingSurfaceNormals', ...
          'Surface measurement %d does not contain the required normal fields.', planeIndex);
end

% Select the middle valid normal rather than an end point, because central
% curve points are easier to inspect and are less sensitive to edge effects.
validNormalIndices = find(selectedSurfaceMeasurement.surfaceNormalMask);
if isempty(validNormalIndices)
    error('dev_Ematch_simpleSetup:NoValidSurfaceNormal', ...
          'Surface measurement %d contains no valid surface normal.', planeIndex);
end
surfacePointIndex = validNormalIndices(round((numel(validNormalIndices) + 1) / 2));

% Store x_3dp directly in the ultrasound oriented-point struct. Row i of the
% point and normal arrays refers to the same extracted surface sample.
x.position3DRef = double(selectedSurfaceMeasurement.surfaceCoordinatesXYZRef(surfacePointIndex, :)).';

% Store x_2dn as a 2D unit direction in physical image X-Y. Force it to a
% column and normalize again to protect this development script from
% harmless floating-point drift in the saved artifact.
x.normal2DImage = double(selectedSurfaceMeasurement.surfaceNormalXY(surfacePointIndex, :)).';
x.normal2DImage = x.normal2DImage / norm(x.normal2DImage);

% Lift the 2D normal into the local 3D image frame by assigning zero to its
% out-of-plane component. Rotate it into ref using the rotation block of
% T_image_ref:
%       n_ref = R_image_ref * [n_x; n_y; 0].
% Translation is deliberately excluded because a normal is a direction.
R_image_ref            = selectedPlane.T_image_ref(1:3, 1:3);
xNormal3DRefForDisplay = R_image_ref * [x.normal2DImage; 0];
xNormal3DRefForDisplay = xNormal3DRefForDisplay / norm(xNormal3DRefForDisplay);

% X is the complete ultrasound measurement set. In this one-point setup,
% that set contains only x. Keep X here because x now has both properties
% that define one projection-oriented point: its position and 2D normal.
X = x;


%% CREATE ONE SYNTHETIC ORIENTED MODEL POINT

% Place the synthetic model point close to the measurement, with one offset
% inside the ultrasound plane and a smaller offset normal to that plane.
% This keeps the point nearby while making it visibly separate in 3D.
imageExtentMm       = max([selectedPlane.W, selectedPlane.H]);
inPlaneOffsetMm     = 0.05 * imageExtentMm;
outOfPlaneOffsetMm  = 0.15 * imageExtentMm;
imagePlaneNormalRef = R_image_ref(:, 3);
y.position3DRef = x.position3DRef ...
                  + inPlaneOffsetMm * xNormal3DRefForDisplay ...
                  + outOfPlaneOffsetMm * imagePlaneNormalRef;

% Build a synthetic 3D model normal that is similar, but not identical, to
% the measured normal. The small in-plane tangent component changes its
% projected angle, while the Z component makes it a genuine 3D direction.
xTangent2DImage               = [-x.normal2DImage(2); x.normal2DImage(1)];
yNormal3DImageForConstruction = [x.normal2DImage + 0.30 * xTangent2DImage; 0.20];
yNormal3DImageForConstruction = yNormal3DImageForConstruction / norm(yNormal3DImageForConstruction);
y.normal3DRef                 = R_image_ref * yNormal3DImageForConstruction;
y.normal3DRef                 = y.normal3DRef / norm(y.normal3DRef);

% Y is the current model-correspondence set. The simple setup uses the one
% synthetic model point y as the correspondence for X(1).
Y = y;

% FUTURE MANY-POINT ORGANIZATION
% When this development setup grows to N data points and N current model
% correspondences, preallocate struct arrays while preserving the same
% individual-point fields used by x and y:
%
% xTemplate = struct( ...
%     'position3DRef', zeros(3, 1), ...
%     'normal2DImage', zeros(2, 1));
%
% yTemplate = struct( ...
%     'position3DRef', zeros(3, 1), ...
%     'normal3DRef', zeros(3, 1));
%
% X = repmat(xTemplate, numberOfDataPoints, 1);
% Y = repmat(yTemplate, numberOfDataPoints, 1);
%
% With this layout, X(i) is one ultrasound oriented point and Y(i) is its
% current model correspondence.


%% DISPLAY THE SIMPLE E_MATCH SETUP IN REF

% Use the physical image size to keep all arrows readable without hard-coded
% lengths that only work for one acquisition.
axisDisplayScale   = 0.15 * imageExtentMm;
normalDisplayScale = 0.15 * imageExtentMm;
pixelSpacingXYMm   = [ ...
    selectedPlane.W / max(selectedPlane.nCols - 1, 1), ...
    selectedPlane.H / max(selectedPlane.nRows - 1, 1)];

setupFigure = figure('Name', 'P-IMLOP E_{match}: Simple Setup');
setupAxes   = axes(setupFigure);
hold(setupAxes, 'on');
grid(setupAxes, 'on');
axis(setupAxes, 'equal');
view(setupAxes, 35, 35);
xlabel(setupAxes, 'X_{ref} (mm)');
ylabel(setupAxes, 'Y_{ref} (mm)');
zlabel(setupAxes, 'Z_{ref} (mm)');

% Draw the selected tracked image at its saved pose in ref.
imageHandle = display_image3D(setupAxes, ...
    selectedPlane.image, ...
    selectedPlane.T_image_ref, ...
    'SwapXY', true, ...
    'PixelSpacing', pixelSpacingXYMm, ...
    'Tag', 'dev_ematch_image_plane', ...
    'Colormap', 'gray', ...
    'FaceAlpha', 0.40);
imageHandle.DisplayName = sprintf('Ultrasound plane %d', planeIndex);

% Draw the rigid-body axes stored by T_image_ref. The columns of its rotation
% block are the local image X, Y, and Z directions expressed in ref.
display_axis_v2(setupAxes, ...
    selectedPlane.T_image_ref(1:3, 4), ...
    R_image_ref, ...
    axisDisplayScale, ...
    '', ...
    'Tag', 'dev_ematch_image_axes', ...
    'Mode', 'default');

% Draw the selected ultrasound surface sample x as a red point.
xPointHandle = scatter3(setupAxes, ...
    x.position3DRef(1), x.position3DRef(2), x.position3DRef(3), ...
    70, [0.90, 0.05, 0.05], 'filled', ...
    'DisplayName', 'Ultrasound point x');

% Draw the lifted 2D ultrasound normal from the measured point. AutoScale is
% disabled because the vector is already multiplied by the desired length.
xNormalHandle = quiver3(setupAxes, ...
    x.position3DRef(1), x.position3DRef(2), x.position3DRef(3), ...
    xNormal3DRefForDisplay(1) * normalDisplayScale, ...
    xNormal3DRefForDisplay(2) * normalDisplayScale, ...
    xNormal3DRefForDisplay(3) * normalDisplayScale, ...
    0, ...
    'Color', [0.90, 0.05, 0.05], ...
    'LineWidth', 2.5, ...
    'MaxHeadSize', 0.8, ...
    'DisplayName', 'Ultrasound normal x_{2dn} in ref');

% Draw the synthetic model-oriented point y in blue so it can be compared
% directly with the measured red point.
yPointHandle = scatter3(setupAxes, ...
    y.position3DRef(1), y.position3DRef(2), y.position3DRef(3), ...
    70, [0.05, 0.35, 0.95], 'filled', ...
    'DisplayName', 'Synthetic model point y');

yNormalHandle = quiver3(setupAxes, ...
    y.position3DRef(1), y.position3DRef(2), y.position3DRef(3), ...
    y.normal3DRef(1) * normalDisplayScale, ...
    y.normal3DRef(2) * normalDisplayScale, ...
    y.normal3DRef(3) * normalDisplayScale, ...
    0, ...
    'Color', [0.05, 0.35, 0.95], ...
    'LineWidth', 2.5, ...
    'MaxHeadSize', 0.8, ...
    'DisplayName', 'Synthetic model normal y_{3dn}');

title(setupAxes, sprintf( ...
    'Simple E_{match} setup (plane: %d, surface point: %d)', ...
    planeIndex, surfacePointIndex), ...
    'Interpreter', 'tex');

% Add MATLAB's usual breathing room around the plotted objects. Without
% padded limits, this small one-plane scene can sit almost directly against
% the axes boundaries and make the interactive figure feel overly tight.
rotate3d(setupFigure, 'on');
drawnow;

% Print the selected values so the next development step can relate every
% plotted vector directly to the symbols used in Equation (3).
fprintf('Selected plane index: %d\n', planeIndex);
fprintf('Selected surface point index: %d\n', surfacePointIndex);
fprintf('x_3dp in ref           : [%.6f %.6f %.6f] mm\n', x.position3DRef);
fprintf('x_2dn in image XY      : [%.6f %.6f]\n',         x.normal2DImage);
fprintf('x_2dn lifted to ref    : [%.6f %.6f %.6f]\n',    xNormal3DRefForDisplay);
fprintf('Synthetic y_3dp in ref : [%.6f %.6f %.6f] mm\n', y.position3DRef);
fprintf('Synthetic y_3dn in ref : [%.6f %.6f %.6f]\n',    y.normal3DRef);


%% CALCULATING E_POSITION

% -------------------------------------------------------------------------
% PART 1: DEFINE COVARIANCE OF MEASUREMENT POINT AND DISPLAY IT

% Begin with the uncertainty used for ultrasound points in the P-IMLOP
% paper: 1 mm standard deviation in both image-plane directions and 1.5 mm
% perpendicular to the image. 
% Image X is the lateral direction, image Y is the axial/beam direction, 
% and image Z is the elevational direction.
% These are sensible development values, but later experiments should
% replace them with uncertainties measured for the actual imaging system.
positionStdImageMm = [1.0; 1.0; 1.5];

% A covariance stores variances, so square each standard deviation. Keep
% this uncertainty separate from x and X: the oriented point contains only
% its position and normal, while SigmaImage is a registration parameter.
% The zero off-diagonal entries assume independent errors along the three
% local image axes in this first simple model.
SigmaImage = diag(positionStdImageMm .^ 2);

% Rotate the covariance from image coordinates into ref. Translation does
% not appear because covariance describes the size and orientation of an
% uncertainty cloud, not the location of its centre.
SigmaRef = R_image_ref * SigmaImage * R_image_ref.';

% Remove tiny numerical asymmetry introduced by matrix multiplication. A
% covariance is symmetric by definition, and later E_position calculations
% should receive that symmetric form.
SigmaRef = 0.5 * (SigmaRef + SigmaRef.');

% For a 3D Gaussian, the joint 95% confidence boundary satisfies
%       d^T * inv(Sigma) * d = chi2inv(0.95, 3).
% Store the known three-degree-of-freedom quantile directly so this visual
% development script does not require the Statistics Toolbox just to draw
% the ellipsoid.
confidenceProbability   = 0.95;
chiSquareQuantile3D95   = 7.81472790325118;
confidenceRadiusScale95 = sqrt(chiSquareQuantile3D95);

% Multiplying each one-standard-deviation axis by the common chi-square
% scale gives the semi-axis radii of the joint 95% confidence ellipsoid.
confidenceRadiiImageMm = confidenceRadiusScale95 * positionStdImageMm;

% Start from a unit sphere, stretch it by the three confidence radii in the
% local image frame, rotate it into ref, and finally centre it on x_3dp.
[unitSphereX, unitSphereY, unitSphereZ] = sphere(48);
unitSpherePoints = [ unitSphereX(:).'; ...
                     unitSphereY(:).'; ...
                     unitSphereZ(:).'];
ellipsoidPointsRef = x.position3DRef ...
                     + R_image_ref * diag(confidenceRadiiImageMm) * unitSpherePoints;

% Restore the sphere-grid shape required by SURF.
ellipsoidXRef = reshape(ellipsoidPointsRef(1, :), size(unitSphereX));
ellipsoidYRef = reshape(ellipsoidPointsRef(2, :), size(unitSphereY));
ellipsoidZRef = reshape(ellipsoidPointsRef(3, :), size(unitSphereZ));

% Draw the joint 95% positional confidence region around x. The longest
% ellipsoid direction is the less certain elevational image direction.
covarianceEllipsoidHandle = surf(setupAxes, ...
    ellipsoidXRef, ellipsoidYRef, ellipsoidZRef, ...
    'FaceColor', [1.00, 0.55, 0.05], ...
    'FaceAlpha', 0.22, ...
    'EdgeColor', 'none', ...
    'DisplayName', sprintf('%.0f%% positional confidence ellipsoid', 100 * confidenceProbability) ...
    );

% Add the final legend after PART 1 creates the ellipsoid handle. The image
% axes remain visible without adding their three arrows to the legend.
legend(setupAxes, ...
    [imageHandle, covarianceEllipsoidHandle, xPointHandle, xNormalHandle, ...
     yPointHandle, yNormalHandle], ...
    'Location', 'best', ...
    'Interpreter', 'none');
drawnow;

% Print the assumed covariance and its confidence radii for direct comparison
% with the visual ellipsoid and the upcoming E_position calculation.
fprintf('\nPosition std in image  : [%.6f %.6f %.6f] mm\n', positionStdImageMm);
fprintf('95%% ellipsoid radii    : [%.6f %.6f %.6f] mm\n',  confidenceRadiiImageMm);
fprintf('Position covariance in ref (mm^2):\n');
disp(SigmaRef);


% Equation (3) in P-IMLOP measures the position mismatch with a
% covariance-weighted squared distance:
%
%   E_position = 1/2 * (Y - X)' * Sigma_X^(-1) * (Y - X)
%
% Here, X is the ultrasound measurement and Y is the synthetic model
% point. The covariance belongs to X because it describes how uncertain
% the ultrasound measurement is. We assume Y is exact in this simple
% example.
positionResidualRef = Y.position3DRef - X.position3DRef;

% Do not form inv(Sigma_X) explicitly. The Cholesky factor provides a
% numerically safer way to normalize the residual by the measurement
% uncertainty. 
% If Sigma_X = L*L', then ||L\residual||^2 is exactly the
% Mahalanobis distance squared.
covarianceCholeskyLower    = chol(SigmaRef, 'lower');
normalizedPositionResidual = covarianceCholeskyLower \ positionResidualRef;
mahalanobisDistanceSquared = normalizedPositionResidual.' * normalizedPositionResidual;
E_position                 = 0.5 * mahalanobisDistanceSquared;

% E_position is one-half of a squared distance. Therefore, the distance
% represented by E_position is sqrt(2*E_position). This Mahalanobis
% distance is dimensionless: it tells us how large the mismatch is
% relative to the assumed ultrasound uncertainty, rather than in mm.
mahalanobisDistance = sqrt(2 * E_position);
euclideanDistanceMm = norm(positionResidualRef);

% Draw the residual from the ultrasound point X to the model point Y.
positionResidualHandle = plot3(setupAxes, ...
    [X.position3DRef(1), Y.position3DRef(1)], ...
    [X.position3DRef(2), Y.position3DRef(2)], ...
    [X.position3DRef(3), Y.position3DRef(3)], ...
    '--', ...
    'Color', [0.65, 0.10, 0.65], ...
    'LineWidth', 2.5, ...
    'DisplayName', 'Position residual X-Y');

% Put the label near the middle of the dashed line. Move it in a direction
% perpendicular to both the residual and the image-plane normal, so the
% label does not slide along and cover the short residual itself.
residualMidpointRef      = 0.5 * (X.position3DRef + Y.position3DRef);
labelOffsetDirectionRef  = cross(positionResidualRef, imagePlaneNormalRef);
labelOffsetDirectionRef  = labelOffsetDirectionRef / norm(labelOffsetDirectionRef);
labelOffsetRef           = 0 * imageExtentMm * labelOffsetDirectionRef;
residualLabelPositionRef = residualMidpointRef + labelOffsetRef;
residualLabelText        = sprintf('d_M = %.3f', mahalanobisDistance);

text(setupAxes, ...
    residualLabelPositionRef(1), ...
    residualLabelPositionRef(2), ...
    residualLabelPositionRef(3), ...
    residualLabelText, ...
    'Interpreter', 'tex', ...
    'FontSize', 9, ...
    'FontWeight', 'bold', ...
    'Color', [0.45, 0.05, 0.45], ...
    'Margin', 3, ...
    'HorizontalAlignment', 'center');

% Refresh the legend so that it also contains the newly drawn residual.
legend(setupAxes, ...
    [imageHandle, covarianceEllipsoidHandle, ...
     xPointHandle, xNormalHandle, yPointHandle, yNormalHandle, ...
     positionResidualHandle], ...
    'Location', 'best', ...
    'Interpreter', 'none');

fprintf('E_position calculation:\n');
fprintf('  Ordinary Euclidean distance : %.3f mm\n',   euclideanDistanceMm);
fprintf('  Mahalanobis distance        : %.3f unit\n', mahalanobisDistance);
fprintf('  E_position: %.6f\n', E_position);


%% CALCULATING E_ORIENTATION

% -------------------------------------------------------------------------
% PART 1: CALCULATE PROJECTION VECTOR AND DISPLAY IT

% In the paper, R_p maps a direction from the local 2D image frame into the
% surrounding 3D frame. Our image plane is already expressed in ref, so its
% rotation block is exactly R_p for this simple setup.
R_p = R_image_ref;

% First rotate the 3D model normal from ref back into the local image frame:
%       R_p' * y_3dn.
% The resulting three components point along local image X, image Y, and the
% out-of-plane image Z direction, respectively.
yNormal3DImage = R_p.' * Y.normal3DRef;

% P is the projection operator from Equation (1). It removes the local image
% Z component and keeps only the two components visible inside the image.
P_image3D_to_image2D = [1, 0, 0; ...
                        0, 1, 0];
projectedYNormal2DImageUnnormalized = P_image3D_to_image2D * yNormal3DImage;

% Projection generally shortens a vector. Equation (1) therefore divides
% by the projected length to restore a 2D unit direction before comparing
% it with the measured ultrasound normal x_2dn.
projectedYNormalLength = norm(projectedYNormal2DImageUnnormalized);
projectionLengthTolerance = 1e-12;
if projectedYNormalLength <= projectionLengthTolerance
    error('dev_Ematch_simpleSetup:UndefinedProjectedNormal', ...
          'The synthetic model normal is nearly perpendicular to the image plane, so its 2D projected direction is undefined.');
end
projectedYNormal2DImage = projectedYNormal2DImageUnnormalized / projectedYNormalLength;

% The normalized vector above is the actual 2D projection used by the
% P-IMLOP orientation term. For the 3D figure only, lift it back into the
% image plane with a zero Z component and rotate it from image into ref:
%       n_projection_ref = R_p * [n_projection_x; n_projection_y; 0].
% No translation is applied because this is a direction vector.
projectedYNormal3DImageForDisplay = [projectedYNormal2DImage; 0];
projectedYNormal3DRefForDisplay   = R_p * projectedYNormal3DImageForDisplay;
projectedYNormal3DRefForDisplay   = projectedYNormal3DRefForDisplay / norm(projectedYNormal3DRefForDisplay);

% Draw the projected model normal from the ultrasound point X, as requested.
% The green arrow lies entirely inside the selected image plane and can now
% be compared visually with the red measured ultrasound normal. Make only
% its displayed length slightly larger because the deliberately similar red
% and green directions would otherwise almost completely cover one another.
projectionDisplayScale = 1.0 * normalDisplayScale;
projectedYNormalHandle = quiver3(setupAxes, ...
    X.position3DRef(1), X.position3DRef(2), X.position3DRef(3), ...
    projectedYNormal3DRefForDisplay(1) * projectionDisplayScale, ...
    projectedYNormal3DRefForDisplay(2) * projectionDisplayScale, ...
    projectedYNormal3DRefForDisplay(3) * projectionDisplayScale, ...
    0, ...
    'Color', [0.05, 0.70, 0.20], ...
    'LineWidth', 1, ...
    'MaxHeadSize', 0.8, ...
    'DisplayName', 'Projected model normal P(R_p^T y_{3dn})');

% A correct projection must be perpendicular to the image-plane normal in
% ref. Keep this numerical check close to the display conversion so a future
% frame-convention mistake fails immediately rather than drawing a bad arrow.
projectionOutOfPlaneComponent = dot(projectedYNormal3DRefForDisplay, imagePlaneNormalRef);

% The saved tracking transform is a rotation to normal floating-point
% precision rather than a mathematically exact orthonormal matrix. Scale the
% check by its measured orthogonality error so harmless stored rounding does
% not reject a visually and geometrically valid in-plane projection.
rotationOrthogonalityError = norm(R_p.' * R_p - eye(3), 'fro');
projectionPlaneTolerance   = max(1e-10, 10 * rotationOrthogonalityError);
if abs(projectionOutOfPlaneComponent) > projectionPlaneTolerance
    error('dev_Ematch_simpleSetup:ProjectionLeftImagePlane', ...
          'The displayed projected normal is not contained in the image plane.');
end

% Refresh the legend with the green projection arrow added after E_position.
legend(setupAxes, ...
    [imageHandle, covarianceEllipsoidHandle, ...
     xPointHandle, xNormalHandle, yPointHandle, yNormalHandle, ...
     positionResidualHandle, projectedYNormalHandle], ...
    'Location', 'best', ...
    'Interpreter', 'none');
drawnow;

% Print each projection stage so the numerical values can be matched to the
% operations in Equation (1) before E_orientation itself is implemented.
fprintf('\nProjected model-normal calculation:\n');
fprintf('  R_p^T * y_3dn in image XYZ            : [%.6f, %.6f, %.6f]\n',  yNormal3DImage);
fprintf('  P(R_p^T * y_3dn) in image XY          : [%.6f, %.6f]\n',        projectedYNormal2DImageUnnormalized);
fprintf('  Projected length before normalization : %.6f\n',                projectedYNormalLength);
fprintf('  Normalized projection in image XY     : [%.6f, %.6f]\n',        projectedYNormal2DImage);
fprintf('  Display projection in ref XYZ         : [%.6f, %.6f, %.6f]\n',  projectedYNormal3DRefForDisplay);


% -------------------------------------------------------------------------
% PART 2: CALCULATE E_ORIENTATION AND DISPLAY THE ORIENTATION DISTANCE

% Use the orientation concentration assumed for ultrasound measurements in
% the paper. Kappa = 50 corresponds to an angular standard deviation of
% approximately 8 degrees, so disagreement in the measured normal direction
% has a meaningful influence on the match error.
kappa = 50;

% Both vectors are unit directions in the same local image X-Y coordinates.
% Their dot product is cos(theta), where theta is their angular mismatch.
% Clamp only the tiny floating-point excess outside [-1, 1] so ACOS and the
% later distance calculation remain numerically valid.
orientationCosineRaw = projectedYNormal2DImage.' * X.normal2DImage;
orientationCosine    = min(1, max(-1, orientationCosineRaw));

% Equation (3) uses the negative orientation agreement directly:
%       E_orientation = -kappa * cos(theta).
% A good orientation match therefore produces a value near -kappa, not zero.
E_orientation = -kappa * orientationCosine;

% The raw term above is a likelihood contribution and can be negative, so
% sqrt(2*E_orientation) would not define a real distance. Add the constant
% kappa to obtain the equivalent nonnegative mismatch energy. Eq (7).
%       kappa * (1 - cos(theta)).
% Adding this fixed constant does not change which orientation minimizes the
% cost, but it lets us recover the unit-vector chord distance between tips:
%       d_orientation = sqrt(2 * (1 - cos(theta)))
%                     = sqrt(2 * E_orientationMismatch / kappa).
E_orientationMismatch    = E_orientation + kappa;
orientationChordDistance = sqrt(max(0, 2 * E_orientationMismatch / kappa));
orientationAngleRad      = acos(orientationCosine);
orientationAngleDeg      = rad2deg(orientationAngleRad);

% Independently compute the same chord distance from the two 2D unit vectors.
% This check links the energy calculation to the geometry being displayed.
orientationChordDistanceDirect = norm(projectedYNormal2DImage - X.normal2DImage);
if abs(orientationChordDistance - orientationChordDistanceDirect) > 1e-12
    error('dev_Ematch_simpleSetup:OrientationDistanceMismatch', ...
          'The E_orientation-derived distance does not match the vector-tip distance.');
end

% The red and green arrows start at X and use the same display length. Their
% two endpoints therefore visualize the same unit-vector chord distance up
% to the common normalDisplayScale used only for plotting.
if abs(projectionDisplayScale - normalDisplayScale) > 1e-12
    error('dev_Ematch_simpleSetup:UnequalNormalDisplayScales', ...
          'The two normals must use the same display scale to show their chord distance.');
end
xNormalTipRef          = X.position3DRef + normalDisplayScale * xNormal3DRefForDisplay;
projectedYNormalTipRef = X.position3DRef + projectionDisplayScale * projectedYNormal3DRefForDisplay;

orientationDistanceHandle = plot3(setupAxes, ...
    [xNormalTipRef(1), projectedYNormalTipRef(1)], ...
    [xNormalTipRef(2), projectedYNormalTipRef(2)], ...
    [xNormalTipRef(3), projectedYNormalTipRef(3)], ...
    '--', ...
    'Color', [0.95, 0.45, 0.05], ...
    'LineWidth', 2.0, ...
    'DisplayName', 'Orientation chord distance');

% Put the label beside the short dashed chord. The offset direction is in
% the ultrasound plane and perpendicular to the chord, so the label remains
% associated with the line without covering either arrowhead.
orientationChordVectorRef = projectedYNormalTipRef - xNormalTipRef;
orientationLabelOffsetDirectionRef = cross(imagePlaneNormalRef, orientationChordVectorRef);
if norm(orientationLabelOffsetDirectionRef) > 1e-12
    orientationLabelOffsetDirectionRef = orientationLabelOffsetDirectionRef / norm(orientationLabelOffsetDirectionRef);
else
    % Perfectly matching normals produce a zero-length chord. Use the local
    % image X direction as a stable label offset in that special case.
    orientationLabelOffsetDirectionRef = R_p(:, 1);
end
orientationDistanceMidpointRef = 0.5 * (xNormalTipRef + projectedYNormalTipRef);
orientationLabelPositionRef    = orientationDistanceMidpointRef + 0.012 * imageExtentMm * orientationLabelOffsetDirectionRef;
orientationLabelText           = sprintf('d_{orientation} = %.3f', orientationChordDistance);

text(setupAxes, ...
    orientationLabelPositionRef(1), ...
    orientationLabelPositionRef(2), ...
    orientationLabelPositionRef(3), ...
    orientationLabelText, ...
    'Interpreter', 'tex', ...
    'FontSize', 9, ...
    'FontWeight', 'bold', ...
    'Color', [0.80, 0.30, 0.00], ...
    'Margin', 3, ...
    'HorizontalAlignment', 'center');

% Refresh the legend with the dashed orientation-distance line.
legend(setupAxes, ...
    [imageHandle, covarianceEllipsoidHandle, ...
     xPointHandle, xNormalHandle, yPointHandle, yNormalHandle, ...
     positionResidualHandle, projectedYNormalHandle, ...
     orientationDistanceHandle], ...
    'Location', 'best', ...
    'Interpreter', 'none');
drawnow;

fprintf('\nE_orientation calculation:\n');
fprintf('  Kappa                                   : %.3f\n',      kappa);
fprintf('  Orientation agreement cos(theta)        : %.6f\n',      orientationCosine);
fprintf('  Angular mismatch theta                  : %.3f deg\n',  orientationAngleDeg);
fprintf('  E_orientation = -kappa*cos(theta)       : %.6f\n',      E_orientation);
fprintf('  Shifted mismatch kappa*(1-cos(theta))   : %.6f\n',      E_orientationMismatch);
fprintf('  Orientation chord distance              : %.6f unit\n', orientationChordDistance);

%%
