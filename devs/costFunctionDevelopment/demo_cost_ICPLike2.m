% DEMO_COST_ICPLIKE2 Minimal example of how to use cost_ICPLike.
%
% A NOTE ON THE NAMES
%   This demo was written for dev_cost_ICPLike2, the development version of
%   the faster ICP-like cost. That function is now the pipeline cost model
%   cost_ICPLike, in functions/bonePoseOptimization/costModels/, and the
%   "2" in this script's name refers to its old name. The previous version
%   is kept next to this script as dev_cost_ICPLike for study only.
%
%   In the pipeline, prepareBonePoseOptimizationInputs builds the search
%   data of STEP 2 by itself. This demo builds it by hand because the saved
%   setup file was made before that step existed, and because seeing the
%   build shows what the cost function needs.
%
% cost_ICPLike tells an optimizer how well a candidate bone pose fits
% the ultrasound data. It returns the RMSE of the distances between the
% bone-surface points seen in the ultrasound images and the CT bone mesh
% placed at that pose. A lower cost means a better fit.
%
% The function is fast because it does not build its own search structures
% on every call. The caller builds them ONCE, before the first call, and
% passes them in through data.extra.icpLike:
%   - vertexTreeCT        : a KD-tree over the mesh vertices in the CT frame;
%   - faceIndicesByVertex : for every vertex, the mesh faces that touch it.
% After that, the function can be called as often as the optimizer needs.
%
% The script tells this story in four steps: load the data, build the search
% data, evaluate the cost at one pose, and look at the result.
% devdemo_cost_ICPLike2.m checks this function against the old
% dev_cost_ICPLike and times both of them.

% Clear the workspace and close all figures, so nothing left over from an
% earlier run can affect this one.
clear; clc; close all;

% The cost function lives in the project's functions folder, which goes on
% the path. The saved setup file sits next to this script, so this folder
% is remembered to load it.
developmentFolder = fileparts(mfilename('fullpath'));
projectRoot       = fileparts(fileparts(developmentFolder));
addpath(genpath(fullfile(projectRoot, 'functions')));

%% STEP 1. LOAD THE PREPARED DATA AND SET THE ICPLIKE CONFIG
% The setup file already holds data that is ready for optimization: the CT
% bone mesh, the measured surface points, the image planes and the initial
% pose. Loading it skips the slow input preparation.
setup  = load(fullfile(developmentFolder, 'optimization_setup.mat'), 'data', 'config');
data   = setup.data;
config = setup.config;

% The saved config was made for another cost model, so its cost settings
% are replaced with the ICPLike ones:
%   nearestVertexCount - how many nearest mesh vertices (K) each point uses
%                        to find the faces it could lie on;
%   pointBatchSize     - how many points are processed together. It only
%                        affects speed and memory, never the result.
% data.config gets the same copy, so code that reads the config from data
% sees the same settings.
config.cost.model      = 'ICPLike';
config.cost.parameters = struct('nearestVertexCount', 20, 'pointBatchSize', 200);
data.config = config;

%% STEP 2. BUILD THE SEARCH DATA ONCE (outside the cost function)
% Only the pose changes during optimization; the CT mesh stays the same.
% Anything built from the CT mesh therefore works for every candidate pose,
% so this step runs once instead of on every cost call.
boneMeshCT       = data.boneMeshCT;
numberOfVertices = size(boneMeshCT.Points, 1);

% The first structure is a KD-tree over the mesh vertices in the CT frame.
% Each cost call moves the measured points into CT, instead of moving the
% whole mesh into ref, so this one tree works for every pose.
vertexTreeCT = KDTreeSearcher(boneMeshCT.Points);

% The second structure turns a nearest vertex into the faces around it.
% vertexAttachments gives one cell per vertex, and the cells have different
% lengths. A plain matrix lets the cost function look up all points at
% once, so each row is filled up to the same width by repeating the
% vertex's first face. The cost function removes repeated faces, so this
% filling never changes the result.
attachedFaceCells   = vertexAttachments(boneMeshCT, (1:numberOfVertices).');
facesPerVertex      = max(cellfun(@numel, attachedFaceCells));
faceIndicesByVertex = zeros(numberOfVertices, facesPerVertex);
for vertexIndex = 1:numberOfVertices
    attachedFaces   = attachedFaceCells{vertexIndex};
    numberOfRepeats = facesPerVertex - numel(attachedFaces);
    faceIndicesByVertex(vertexIndex, :) = [attachedFaces, repmat(attachedFaces(1), 1, numberOfRepeats)];
end

% With both structures ready, store them in data.extra.icpLike. That is
% where cost_ICPLike looks for them, so data is now ready for any
% number of cost calls.
data.extra.icpLike.vertexTreeCT        = vertexTreeCT;
data.extra.icpLike.faceIndicesByVertex = faceIndicesByVertex;

%% STEP 3. EVALUATE THE COST AT ONE POSE
% The optimizer describes a pose as a 6D change [tx; ty; tz; rx; ry; rz]
% (mm, rad) from the initial pose. A zero vector is the initial pose
% itself, which is a natural first pose to check. An optimizer calls this
% same line many times, each time with a different pose vector.
poseVector      = zeros(6, 1);
[cost, details] = cost_ICPLike(poseVector, data, config);

% A one-line summary gives the result as a number before the figure shows
% it in 3D. The run time shows how cheap one call is now that the search
% data is reused.
fprintf('cost_ICPLike at the initial pose: RMSE = %.3f mm over %d points (%.1f ms)\n', ...
    cost, numel(details.pointToSurfaceDistancesMm), 1e3 * details.correspondenceRuntimeSeconds);

%% STEP 4. SHOW THE RESULT: MESH, ULTRASOUND IMAGES AND CORRESPONDENCES
% The cost is a single number, so a 3D view shows where the fit is good and
% where it is poor. The points and the mesh are in the ref frame, and all
% axes use the same scale so distances on screen are not distorted.
figureHandle = figure('Name', 'cost_ICPLike: correspondences at the initial pose');
axesHandle = axes(figureHandle);
hold(axesHandle, 'on');
grid(axesHandle, 'on');
axis(axesHandle, 'equal');
view(axesHandle, 35, 40);
xlabel(axesHandle, 'X_{ref} (mm)');
ylabel(axesHandle, 'Y_{ref} (mm)');
zlabel(axesHandle, 'Z_{ref} (mm)');

% The bone mesh is drawn first, at the pose that was just evaluated. It is
% half-transparent, so points behind or inside it stay visible.
boneMeshRef = details.boneMeshRefCandidate;
patch(axesHandle, 'Faces', boneMeshRef.ConnectivityList, 'Vertices', boneMeshRef.Points, ...
    'FaceColor', [0.92 0.83 0.74], 'EdgeColor', 'none', 'FaceAlpha', 0.45, 'DisplayName', 'Bone mesh');

% Next come the ultrasound images that the points were taken from, each at
% its tracked pose. They let you check that the points lie on the bright
% bone echo, and that the mesh follows that echo too.
isFirstImage = true;
for measurementIndex = 1:numel(data.boneSurfaceMeasurements)
    % An image with no bone-surface points does not affect the cost, so it
    % is skipped to keep the view clear.
    if isempty(data.boneSurfaceMeasurements(measurementIndex).surfaceCoordinatesXYZRef)
        continue
    end

    % The grey image is turned into RGB, which does not use the axes
    % colormap. That way the image stays grey while the points below are
    % coloured by distance.
    plane     = data.imagePlanesRef(measurementIndex);
    grayImage = double(plane.image) / 255;
    rgbImage  = repmat(grayImage, 1, 1, 3);

    % The image's size in mm and its pixel count give the pixel spacing,
    % which places every pixel at its real location in ref. The image is
    % see-through, so the points and lines behind it stay visible.
    pixelSpacing = [plane.W / max(plane.nCols - 1, 1), plane.H / max(plane.nRows - 1, 1)];
    imageHandle = display_image3D(axesHandle, rgbImage, plane.T_image_ref, ...
        'SwapXY', true, ...
        'PixelSpacing', pixelSpacing, ...
        'FaceAlpha', 0.35);

    % All images mean the same thing, so only the first one gets a legend
    % entry and the others are hidden from the legend.
    if isFirstImage
        imageHandle.DisplayName = 'Ultrasound images';
        isFirstImage = false;
    else
        imageHandle.HandleVisibility = 'off';
    end
end

% On top come the measured points, coloured by their distance to the mesh
% so poorly matched areas stand out. Next to each one is the closest mesh
% point the cost function found for it.
measuredPointsRef = details.boneSurfacePointsRef;
closestPointsRef  = details.closestBonePointsRef;
scatter3(axesHandle, ...
    measuredPointsRef(:, 1), ...
    measuredPointsRef(:, 2), ...
    measuredPointsRef(:, 3), ...
    12, details.pointToSurfaceDistancesMm, 'filled', ...
    'DisplayName', 'Measured points (colour = distance)');
scatter3(axesHandle, ...
    closestPointsRef(:, 1), ...
    closestPointsRef(:, 2), ...
    closestPointsRef(:, 3), 6, 'k', 'filled', ...
    'DisplayName', 'Closest mesh points');

% Lines from measured points to their matches show the pairs the cost is
% built from. Only every 5th point gets a line, to avoid clutter. A NaN
% after each pair breaks the line there, so one line object can draw all
% the separate segments.
shownPoints = 1:5:size(measuredPointsRef, 1);
lineX = [measuredPointsRef(shownPoints, 1), closestPointsRef(shownPoints, 1), nan(numel(shownPoints), 1)].';
lineY = [measuredPointsRef(shownPoints, 2), closestPointsRef(shownPoints, 2), nan(numel(shownPoints), 1)].';
lineZ = [measuredPointsRef(shownPoints, 3), closestPointsRef(shownPoints, 3), nan(numel(shownPoints), 1)].';
plot3(axesHandle, lineX(:), lineY(:), lineZ(:), '-', 'Color', [0.85 0.1 0.1], 'DisplayName', 'Correspondence (every 5th)');

% The mesh is much bigger than the measured area, so the view is zoomed to
% the points plus a margin (mm). The colour scale runs from zero to the
% largest distance, and the colorbar says what the colours mean.
margin = 50;
xlim(axesHandle, [min(measuredPointsRef(:, 1)) - margin, max(measuredPointsRef(:, 1)) + margin]);
ylim(axesHandle, [min(measuredPointsRef(:, 2)) - margin, max(measuredPointsRef(:, 2)) + margin]);
zlim(axesHandle, [min(measuredPointsRef(:, 3)) - margin, max(measuredPointsRef(:, 3)) + margin]);
clim(axesHandle, [0, max(details.pointToSurfaceDistancesMm)]);
colorbarHandle = colorbar(axesHandle);
colorbarHandle.Label.String = 'point-to-surface distance (mm)';

% Finally, a legend, lighting that shows the shape of the mesh, and a title
% that repeats the cost, so the figure can be understood on its own. Mouse
% rotation is turned on so the fit can be checked from every side.
legend(axesHandle, 'Location', 'best');
camlight(axesHandle, 'headlight');
lighting(axesHandle, 'gouraud');
title(axesHandle, sprintf('%s initial pose: RMSE %.3f mm (%d points)', data.boneName, cost, size(measuredPointsRef, 1)), 'Interpreter', 'none');
rotate3d(figureHandle, 'on');
