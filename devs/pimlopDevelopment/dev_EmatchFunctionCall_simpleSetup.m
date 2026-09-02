clear; clc; close all;

%% LOAD THE SAVED OPTIMIZATION SETUP

% Resolve every path from this script so it works from any MATLAB folder.
developmentFolder = fileparts(mfilename('fullpath'));
projectRoot       = fileparts(fileparts(developmentFolder));
setupFilePath     = fullfile(developmentFolder, 'optimization_setup.mat');

% Add the reusable project helpers and this development function folder.
addpath(genpath(fullfile(projectRoot, 'functions')));
addpath(developmentFolder);

% Only data is required to build this one-point development example.
load(setupFilePath, 'data');


%% SELECT ONE IMAGE PLANE AND ONE VALID ORIENTED ULTRASOUND POINT

% Surface measurements and image planes use matching indices after input
% preparation. Keep the same plane used by the original simple script.
planeIndex                 = 11;
selectedPlane              = data.imagePlanesRef(planeIndex);
selectedSurfaceMeasurement = data.boneSurfaceMeasurements(planeIndex);

% Stop early if an older setup artifact without extracted normals is loaded.
requiredNormalFields = {'surfaceCoordinatesXYZRef', 'surfaceNormalXY', 'surfaceNormalMask'};
if ~all(isfield(selectedSurfaceMeasurement, requiredNormalFields))
    error('dev_EmatchFunctionCall_simpleSetup:MissingSurfaceNormals', ...
          'Surface measurement %d does not contain the required normal fields.', planeIndex);
end

% Select a central valid sample because curve endpoints are less convenient
% for visual inspection and can be more sensitive to extraction edge effects.
validNormalIndices = find(selectedSurfaceMeasurement.surfaceNormalMask);
if isempty(validNormalIndices)
    error('dev_EmatchFunctionCall_simpleSetup:NoValidSurfaceNormal', ...
          'Surface measurement %d contains no valid surface normal.', planeIndex);
end
surfacePointIndex = validNormalIndices(round((numel(validNormalIndices) + 1) / 2));

% X contains only the measurement geometry. Its covariance remains a separate
% noise-model input so one matrix can be shared by many measurements.
X = struct();
X.position3DRef = double(selectedSurfaceMeasurement.surfaceCoordinatesXYZRef(surfacePointIndex, :)).';
X.normal2DImage = double(selectedSurfaceMeasurement.surfaceNormalXY(surfacePointIndex, :)).';
X.normal2DImage = X.normal2DImage / norm(X.normal2DImage);

% R_p maps local image-frame directions into ref. It is required both for the
% projected normal comparison and for rotating image covariance into ref.
R_p = selectedPlane.T_image_ref(1:3, 1:3);
xNormal3DRefForSetup = R_p * [X.normal2DImage; 0];
xNormal3DRefForSetup = xNormal3DRefForSetup / norm(xNormal3DRefForSetup);


%% CREATE ONE SYNTHETIC ORIENTED MODEL POINT

% Place Y close to X with both an in-plane and out-of-plane displacement so
% the positional residual remains visible in the diagnostic plot.
imageExtentMm       = max([selectedPlane.W, selectedPlane.H]);
inPlaneOffsetMm     = 0.05 * imageExtentMm;
outOfPlaneOffsetMm  = 0.15 * imageExtentMm;
imagePlaneNormalRef = R_p(:, 3);

Y = struct();
Y.position3DRef = X.position3DRef ...
                  + inPlaneOffsetMm * xNormal3DRefForSetup ...
                  + outOfPlaneOffsetMm * imagePlaneNormalRef;

% Give Y a similar but nonidentical normal. The tangent component creates an
% in-plane angular mismatch; the Z component makes it a true 3D model normal.
xTangent2DImage = [-X.normal2DImage(2); X.normal2DImage(1)];
yNormal3DImageForConstruction = [X.normal2DImage + 0.30 * xTangent2DImage; 0.20];
yNormal3DImageForConstruction = yNormal3DImageForConstruction / norm(yNormal3DImageForConstruction);
Y.normal3DRef = R_p * yNormal3DImageForConstruction;
Y.normal3DRef = Y.normal3DRef / norm(Y.normal3DRef);


%% CREATE THE INITIAL FIGURE AND AXES

% The caller owns the figure and axes. The match function only adds diagnostic
% objects to the axes when explicitly requested.
axisDisplayScale   = 0.15 * imageExtentMm;
normalDisplayScale = 0.15 * imageExtentMm;
pixelSpacingXYMm   = [ ...
    selectedPlane.W / max(selectedPlane.nCols - 1, 1), ...
    selectedPlane.H / max(selectedPlane.nRows - 1, 1)];

setupFigure = figure('Name', 'P-IMLOP E_{match} Function Call: Simple Setup');
setupAxes   = axes(setupFigure);
hold(setupAxes, 'on');
grid(setupAxes, 'on');
axis(setupAxes, 'equal');
view(setupAxes, 35, 35);
xlabel(setupAxes, 'X_{ref} (mm)');
ylabel(setupAxes, 'Y_{ref} (mm)');
zlabel(setupAxes, 'Z_{ref} (mm)');

% Draw only the surrounding ultrasound scene here. X, Y, covariance, and both
% mismatch diagnostics are owned by calculatePIMLOPMatchError.
imageHandle = display_image3D(setupAxes, ...
    selectedPlane.image, ...
    selectedPlane.T_image_ref, ...
    'SwapXY', true, ...
    'PixelSpacing', pixelSpacingXYMm, ...
    'Tag', 'dev_ematch_function_image_plane', ...
    'Colormap', 'gray', ...
    'FaceAlpha', 0.40);
imageHandle.DisplayName = sprintf('Ultrasound plane %d', planeIndex);

display_axis_v2(setupAxes, ...
    selectedPlane.T_image_ref(1:3, 4), ...
    R_p, ...
    axisDisplayScale, ...
    '', ...
    'Tag', 'dev_ematch_function_image_axes', ...
    'Mode', 'default');

title(setupAxes, sprintf( ...
    'Function-based E_{match} setup (plane: %d, surface point: %d)', ...
    planeIndex, surfacePointIndex), ...
    'Interpreter', 'tex');


%% PREPARE THE MATCH PARAMETERS

% Reuse the paper's experimental ultrasound noise model for every point in
% this simple setup: 1 mm in-plane and 1.5 mm out-of-plane standard deviation.
% The function rotates this shared image-frame covariance into ref using R_p.
positionStdImageMm       = [1.0; 1.0; 1.5];
positionCovarianceImage  = diag(positionStdImageMm .^ 2);
kappa                    = 50;

% Enable the optional diagnostic display and detailed command-window output.
% Passing the caller-owned axes is mandatory when ShowDisplay is true.
displayOptions = struct();
displayOptions.ShowDisplay           = true;
displayOptions.Axes                  = setupAxes;
displayOptions.NormalDisplayScale    = normalDisplayScale;
displayOptions.ConfidenceProbability = 0.95;
displayOptions.ShowLabels            = true;
displayOptions.Verbose               = true;


%% CALL CALCULATEPIMLOPMATCHERROR

[E_match, matchDetails, matchGraphics] = calculatePIMLOPMatchError( ...
    X, Y, R_p, positionCovarianceImage, kappa, displayOptions);

% Combine the caller's ultrasound plane with the diagnostic objects returned
% by the function. The rigid-body axes remain visible but out of the legend.
legend(setupAxes, ...
    [imageHandle; matchGraphics.legendHandles], ...
    'Location', 'best', ...
    'Interpreter', 'none');
rotate3d(setupFigure, 'on');
drawnow;


%% VERIFY THE CALCULATION-ONLY CALL

% A second call without axes exercises the fast path used by optimization.
% It must return exactly the same numerical result and must create no graphics.
fastOptions = struct('ShowDisplay', false, 'Verbose', false);
[E_matchNoDisplay, matchDetailsNoDisplay, matchGraphicsNoDisplay] = ...
    calculatePIMLOPMatchError( ...
    X, Y, R_p, positionCovarianceImage, kappa, fastOptions);

comparisonTolerance = 1e-12;
if abs(E_matchNoDisplay - E_match) > comparisonTolerance
    error('dev_EmatchFunctionCall_simpleSetup:DisplayChangedResult', ...
          'Display-enabled and display-disabled calls returned different E_match values.');
end
if ~isempty(matchGraphicsNoDisplay.legendHandles)
    error('dev_EmatchFunctionCall_simpleSetup:UnexpectedFastGraphics', ...
          'The display-disabled function call unexpectedly created graphics.');
end
if abs(matchDetailsNoDisplay.E_matchEquation3 - matchDetails.E_matchEquation3) ...
        > comparisonTolerance
    error('dev_EmatchFunctionCall_simpleSetup:DetailsChangedResult', ...
          'Display-enabled and display-disabled Equation (3) values differ.');
end

fprintf('\nFunction-call verification:\n');
fprintf('  Selected plane index                    : %d\n', planeIndex);
fprintf('  Selected surface point index            : %d\n', surfacePointIndex);
fprintf('  Display-enabled E_match                 : %.6f\n', E_match);
fprintf('  Display-disabled E_match                : %.6f\n', E_matchNoDisplay);
fprintf('  Display modes return the same value     : PASS\n');
