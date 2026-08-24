clear; clc; close all;

% Load the data from the setup of the optimization
load('optimization_setup.mat');


%% DISPLAYING THE SETUP

% Locate the project functions from this script so the display remains usable
% when MATLAB's current folder is the development folder.
developmentFolder = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(developmentFolder));
addpath(genpath(fullfile(projectRoot, 'functions')));

% Stop early when the saved fixture does not contain the aligned 3D surface
% measurements required by this development workflow.
if ~isfield(data, 'hasBoneSurface') || ~data.hasBoneSurface || ~isfield(data, 'boneSurfaceMeasurements') || isempty(data.boneSurfaceMeasurements)
    error('dev_cost_ICPLike_v01:MissingBoneSurface', ...
          'The loaded optimization setup does not contain aligned bone-surface measurements.');
end

% Move the original CT mesh to its coarse initial pose in the reference
% frame. This is the same pose represented by a zero optimizer state.
bonePointsRefInitial = applyRigidTransform(data.boneMeshCT.Points, data.T_CT_ref_initial);
boneMeshRefInitial = triangulation( data.boneMeshCT.ConnectivityList, bonePointsRefInitial);

% Collect the per-image 3D surface measurements into one point cloud for
% this overview while keeping the aligned records unchanged inside data.
numberOfMeasurements = numel(data.boneSurfaceMeasurements);
surfacePointCells    = cell(numberOfMeasurements, 1);
for measurementIndex = 1:numberOfMeasurements
    surfacePointCells{measurementIndex} = data.boneSurfaceMeasurements(measurementIndex).surfaceCoordinatesXYZRef;
end
boneSurfacePointsRef = vertcat(surfacePointCells{:});

% An available artifact may still contain only empty surface records, which
% would make the requested setup display misleading.
if isempty(boneSurfacePointsRef)
    error('dev_cost_ICPLike_v01:EmptyBoneSurface', ...
          'The loaded optimization setup contains no 3D bone-surface points.');
end

% Use the bone size to keep anatomical and image coordinate axes readable
% without relying on a data-set-specific arrow length.
boneExtentRef = max(bonePointsRefInitial, [], 1) - min(bonePointsRefInitial, [], 1);
axisDisplayScale = 0.08 * max(boneExtentRef);
if ~isfinite(axisDisplayScale) || axisDisplayScale <= 0
    axisDisplayScale = 20;
end

% Create one interactive reference-frame scene for inspecting the complete
% fixed setup before any point-to-mesh distance is calculated.
setupFigure = figure('Name', '3D Point-Cloud Cost Development: Initial Setup');
setupAxes = axes(setupFigure);
hold(setupAxes, 'on');
grid(setupAxes, 'on');
axis(setupAxes, 'equal');
axis(setupAxes, 'vis3d');
view(setupAxes, 35, 40);
xlabel(setupAxes, 'X_{ref} (mm)');
ylabel(setupAxes, 'Y_{ref} (mm)');
zlabel(setupAxes, 'Z_{ref} (mm)');

% Draw the initial candidate bone mesh using its coordinates in ref.
boneMeshHandle = patch(setupAxes, ...
    'Faces', boneMeshRefInitial.ConnectivityList, ...
    'Vertices', boneMeshRefInitial.Points, ...
    'FaceColor', [0.92, 0.83, 0.74], ...
    'EdgeColor', 'none', ...
    'FaceAlpha', 0.45, ...
    'DisplayName', 'Initial bone mesh');

% Draw the anatomical bone coordinate system at its coarse pose in ref.
display_axis_v2(setupAxes, ...
    data.T_bone_ref_initial(1:3, 4), ...
    data.T_bone_ref_initial(1:3, 1:3), ...
    axisDisplayScale, ...
    sprintf('%s anatomical coordinate system', data.boneName), ...
    'Tag', 'dev_point_cloud_bone_acs', ...
    'Mode', 'default');

% Draw every tracked ultrasound image at its saved pose in ref. The first
% image supplies the single legend entry so a large data set stays readable.
ultrasoundImageHandle = gobjects(1);
% Loop for all image plane in the data
for planeIndex = 1:numel(data.imagePlanesRef)

    % Get the current plane
    plane = data.imagePlanesRef(planeIndex);

    % Convert the stored physical image extent into local pixel spacing for
    % the textured image-plane helper.
    pixelSpacing = [ ...
        plane.W / max(plane.nCols - 1, 1), ...
        plane.H / max(plane.nRows - 1, 1)];

    currentImageHandle = display_image3D(setupAxes, ...
        plane.image, ...
        plane.T_image_ref, ...
        'SwapXY', true, ...
        'PixelSpacing', pixelSpacing, ...
        'Tag', 'dev_point_cloud_ultrasound_image', ...
        'Colormap', 'gray', ...
        'FaceAlpha', 0.30);

    if planeIndex == 1
        currentImageHandle.DisplayName = 'Ultrasound images';
        ultrasoundImageHandle = currentImageHandle;
    else
        currentImageHandle.HandleVisibility = 'off';
    end

    % Draw an unlabeled thin coordinate triad so each ultrasound plane's
    % orientation is visible without filling the scene with text labels.
    display_axis_v2(setupAxes, ...
        plane.T_image_ref(1:3, 4), ...
        plane.T_image_ref(1:3, 1:3), ...
        axisDisplayScale * 0.6, ...
        '', ...
        'Tag', 'dev_point_cloud_ultrasound_axis', ...
        'Mode', 'thin');
end

% Overlay the measured ultrasound bone surface as one ref-frame point cloud.
boneSurfaceHandle = scatter3(setupAxes, ...
    boneSurfacePointsRef(:, 1), ...
    boneSurfacePointsRef(:, 2), ...
    boneSurfacePointsRef(:, 3), ...
    14, ...
    [0.00, 0.65, 0.95], ...
    'filled', ...
    'DisplayName', 'Measured 3D bone surface');

% Finish the scene with a focused legend and surface lighting. The figure
% remains rotatable so correspondences can be inspected from any direction.
legend(setupAxes, ...
    [boneMeshHandle, ultrasoundImageHandle, boneSurfaceHandle], ...
    'Location', 'best', ...
    'Interpreter', 'none');
camlight(setupAxes, 'headlight');
lighting(setupAxes, 'gouraud');
material(setupAxes, 'dull');
title(setupAxes, sprintf( ...
    '%s initial setup in ref (%d surface points)', ...
    data.boneName, size(boneSurfacePointsRef, 1)), ...
    'Interpreter', 'none');
rotate3d(setupFigure, 'on');
drawnow;

%% FIND CLOSEST POINT-SURFACE DISTANCE

% Confirm that the GEOM3D helper is available before starting the expensive
% correspondence search. The helper finds the nearest point anywhere on the
% triangular surface instead of restricting the result to mesh vertices.
if exist('distancePointMesh', 'file') ~= 2
    error('dev_cost_ICPLike_v01:MissingDistancePointMesh', ...
          'distancePointMesh is not available on the MATLAB path.');
end

% Read the fixed candidate mesh arrays once because every measured point is
% compared with the same initial bone mesh in the reference frame.
boneMeshVerticesRef = boneMeshRefInitial.Points;
boneMeshFaces       = boneMeshRefInitial.ConnectivityList;

% Keep correspondence results grouped by ultrasound measurement. This
% preserves the one-to-one relationship between surfacePointCells{k} and
% its closest mesh points and distances.
closestBonePointsRefCells          = cell(numberOfMeasurements, 1);
pointToSurfaceDistanceMmCells      = cell(numberOfMeasurements, 1);
numberOfSurfacePointsByMeasurement = zeros(numberOfMeasurements, 1);
meanDistanceMmByMeasurement        = nan(numberOfMeasurements, 1);
rmseDistanceMmByMeasurement        = nan(numberOfMeasurements, 1);
maximumDistanceMmByMeasurement     = nan(numberOfMeasurements, 1);

% Measure the complete correspondence-search time so later implementations
% can be compared with this correctness-first reference.
correspondenceTimer = tic;

% Loop for all measurement
for measurementIndex = 1:numberOfMeasurements

    % Read the measured ref-frame points belonging to one ultrasound image.
    currentSurfacePointsRef = surfacePointCells{measurementIndex};
    numberOfCurrentPoints   = size(currentSurfacePointsRef, 1);
    numberOfSurfacePointsByMeasurement(measurementIndex) = numberOfCurrentPoints;

    % Preserve a valid empty result for images where surface extraction did
    % not return any points.
    if numberOfCurrentPoints == 0
        closestBonePointsRefCells{measurementIndex} = zeros(0, 3);
        pointToSurfaceDistanceMmCells{measurementIndex} = zeros(0, 1);
        continue;
    end

    % Preallocate one closest surface point and one unsigned distance for
    % every measured point in this ultrasound image.
    currentClosestBonePointsRef = zeros(numberOfCurrentPoints, 3);
    currentDistancesMm          = zeros(numberOfCurrentPoints, 1);

    for pointIndex = 1:numberOfCurrentPoints
        % distancePointMesh evaluates triangle interiors, edges, and vertices
        % and returns the closest surface location in the mesh coordinate frame.
        [currentDistancesMm(pointIndex), currentClosestBonePointsRef(pointIndex, :)] = ...
            distancePointMesh(currentSurfacePointsRef(pointIndex, :), boneMeshVerticesRef, boneMeshFaces, 'algorithm', 'vectorized');
    end

    % Stop immediately if the external geometry helper returns an invalid
    % result, because silently continuing would corrupt the future cost.
    if any(~isfinite(currentDistancesMm)) || any(currentDistancesMm < 0) || any(~isfinite(currentClosestBonePointsRef), 'all')
        error('dev_cost_ICPLike_v01:InvalidCorrespondence', ...
              'Measurement %d produced an invalid point-to-surface correspondence.', ...
              measurementIndex);
    end

    % Store the correspondence arrays in the same cell position as their
    % input surface points so they remain traceable to the source image.
    closestBonePointsRefCells{measurementIndex}     = currentClosestBonePointsRef;
    pointToSurfaceDistanceMmCells{measurementIndex} = currentDistancesMm;

    % Calculate simple per-image statistics for inspecting whether one image
    % has unusually large correspondence distances.
    meanDistanceMmByMeasurement(measurementIndex)    = mean(currentDistancesMm);
    rmseDistanceMmByMeasurement(measurementIndex)    = sqrt(mean(currentDistancesMm .^ 2));
    maximumDistanceMmByMeasurement(measurementIndex) = max(currentDistancesMm);

    fprintf('Matched measurement %d of %d: %d surface points.\n', measurementIndex, numberOfMeasurements, numberOfCurrentPoints);

end
correspondenceRuntimeSeconds = toc(correspondenceTimer);

% Flatten the aligned cell results for the future global point-cloud cost.
% The row order remains identical to boneSurfacePointsRef.
closestBonePointsRef      = vertcat(closestBonePointsRefCells{:});
pointToSurfaceDistancesMm = vertcat(pointToSurfaceDistanceMmCells{:});

% Verify that flattening did not break the point-to-correspondence alignment.
if size(closestBonePointsRef, 1) ~= size(boneSurfacePointsRef, 1) || numel(pointToSurfaceDistancesMm) ~= size(boneSurfacePointsRef, 1)
    error('dev_cost_ICPLike_v01:CorrespondenceCountMismatch', ...
          'The flattened correspondence count does not match the measured point count.');
end

% Independently reconstruct every distance from its point pair. This check
% confirms that the stored closest point and reported distance agree.
reconstructedDistancesMm = vecnorm( boneSurfacePointsRef - closestBonePointsRef, 2, 2);
distanceAgreementToleranceMm = 1e-9;
if any(abs(reconstructedDistancesMm - pointToSurfaceDistancesMm) > distanceAgreementToleranceMm)
    error('dev_cost_ICPLike_v01:DistanceMismatch', ...
          'A reported distance does not match its measured-to-closest-point pair.');
end

% Summarize each aligned ultrasound measurement in a readable table while
% retaining empty measurements as rows with unavailable distance statistics.
measurementIndex  = (1:numberOfMeasurements).';
sourceIndex       = [data.boneSurfaceMeasurements.sourceIndex].';
measurementStatus = string({data.boneSurfaceMeasurements.status}).';
correspondenceSummaryTable = table( ...
    measurementIndex, ...
    sourceIndex, ...
    measurementStatus, ...
    numberOfSurfacePointsByMeasurement, ...
    meanDistanceMmByMeasurement, ...
    rmseDistanceMmByMeasurement, ...
    maximumDistanceMmByMeasurement);

% Calculate global values directly from all measured points. These are the
% quantities that will later support the first 3D point-cloud cost model.
meanPointToSurfaceDistanceMm    = mean(pointToSurfaceDistancesMm);
rmsePointToSurfaceDistanceMm    = sqrt(mean(pointToSurfaceDistancesMm .^ 2));
medianPointToSurfaceDistanceMm  = median(pointToSurfaceDistancesMm);
maximumPointToSurfaceDistanceMm = max(pointToSurfaceDistancesMm);

disp(correspondenceSummaryTable);
fprintf(['Matched %d measured points in %.3f seconds.\n', ...
         'Overall distance: mean %.3f mm, RMSE %.3f mm, ', ...
         'median %.3f mm, maximum %.3f mm.\n'], ...
    numel(pointToSurfaceDistancesMm), ...
    correspondenceRuntimeSeconds, ...
    meanPointToSurfaceDistanceMm, ...
    rmsePointToSurfaceDistanceMm, ...
    medianPointToSurfaceDistanceMm, ...
    maximumPointToSurfaceDistanceMm);

% % Interleave every measured point, closest mesh point, and a NaN separator.
% % This draws all correspondences with one graphics object instead of creating
% % thousands of separate line objects that would make the figure sluggish.
% numberOfCorrespondences                 = size(boneSurfacePointsRef, 1);
% correspondenceLinePointsRef             = nan(3 * numberOfCorrespondences, 3);
% correspondenceLinePointsRef(1:3:end, :) = boneSurfacePointsRef;
% correspondenceLinePointsRef(2:3:end, :) = closestBonePointsRef;
% 
% % Draw each measured-to-mesh correspondence in the existing setup scene.
% correspondenceLineHandle = line(setupAxes, ...
%     correspondenceLinePointsRef(:, 1), ...
%     correspondenceLinePointsRef(:, 2), ...
%     correspondenceLinePointsRef(:, 3), ...
%     'Color', [0.90, 0.20, 0.15], ...
%     'LineWidth', 0.75, ...
%     'DisplayName', 'Point-to-surface correspondences', ...
%     'Tag', 'dev_point_cloud_correspondence_lines');

% Update the focused legend to include the newly calculated correspondence
% lines without adding individual anatomical or image coordinate axes.
legend(setupAxes, ...
    [boneMeshHandle, ultrasoundImageHandle, boneSurfaceHandle], ...
    'Location', 'best', ...
    'Interpreter', 'none');
drawnow;

%% ACCELERATE CORRESPONDENCE SEARCH WITH KNN CANDIDATE FACES

% STEP 1: Choose how many nearby mesh vertices will seed the local search.
%
% Intuition:
% A surface point close to the mesh is usually near several mesh vertices.
% Those vertices provide a fast hint about which local mesh region should be
% searched in detail.
%
% Assumption:
% At least one vertex belonging to the true closest triangle is included in
% this K-nearest set. This is usually reasonable for a well-resolved mesh but
% is not mathematically guaranteed for long or irregular triangles.
%
% Usefulness for the next step:
% The selected vertices let us collect a much smaller set of real mesh faces
% without incorrectly treating the K vertices themselves as one triangle.
requestedNearestVertexCount = 20;
nearestVertexCount = min(requestedNearestVertexCount, size(boneMeshVerticesRef, 1));

% Measure the complete accelerated path, including the KNN search and local
% exact triangle searches, so its runtime can be compared fairly with the
% all-face reference implementation above.
knnCorrespondenceTimer = tic;

% STEP 2: Find the K nearest existing mesh vertices for every measured point.
%
% Intuition:
% knnsearch uses an optimized spatial search instead of comparing each query
% point manually with every mesh vertex.
%
% Assumption:
% Vertex proximity is used only as a local-region hint. The returned vertices
% are not assumed to form a triangle and are not used as final correspondences.
%
% Usefulness for the next step:
% Each returned vertex can identify the original mesh faces attached to it.
nearestVertexIndicesByPoint = knnsearch( boneMeshVerticesRef, boneSurfacePointsRef, 'K', nearestVertexCount);

% STEP 3: Cache the original mesh faces attached to every mesh vertex.
%
% Intuition:
% A vertex can belong to several neighboring triangles. Taking the union of
% those attached faces produces a valid local patch from the original mesh.
%
% Assumption:
% Mesh connectivity remains fixed while only vertex coordinates change under
% rigid transformations, so this topological relationship is stable.
%
% Usefulness for the next step:
% distancePointMesh can evaluate exact triangle-interior, edge, and vertex
% distances using only this smaller candidate-face patch.
meshVertexIndices           = (1:size(boneMeshVerticesRef, 1)).';
faceIndicesAttachedToVertex = vertexAttachments(boneMeshRefInitial, meshVertexIndices);

% Preallocate one approximate correspondence result per measured point. The
% word "KNN" in these names records that candidate-face selection is not
% guaranteed to include the globally closest triangle.
numberOfMeasuredSurfacePoints = size(boneSurfacePointsRef, 1);
closestBonePointsRefKnn       = zeros(numberOfMeasuredSurfacePoints, 3);
pointToSurfaceDistancesMmKnn  = zeros(numberOfMeasuredSurfacePoints, 1);
candidateFaceCountByPoint     = zeros(numberOfMeasuredSurfacePoints, 1);

% STEP 4: Build a local face patch and calculate the exact distance within it.
%
% Intuition:
% KNN performs the fast coarse search. distancePointMesh then performs the
% accurate point-to-triangle calculation on genuine faces near the query.
%
% Assumption:
% The local patch contains the globally closest triangle. When it does not,
% the local result can only be equal to or farther than the all-face result.
%
% Usefulness for the next step:
% Comparing this result with the all-face reference quantifies whether the
% speed improvement is acceptable for the current mesh and measurements.
for pointIndex = 1:numberOfMeasuredSurfacePoints
    currentNearestVertexIndices = nearestVertexIndicesByPoint(pointIndex, :);

    % Collect all faces touching any selected vertex, then remove duplicates
    % because neighboring vertices commonly share the same triangle.
    currentAttachmentCells      = faceIndicesAttachedToVertex(currentNearestVertexIndices);
    currentCandidateFaceIndices = unique([currentAttachmentCells{:}]);

    if isempty(currentCandidateFaceIndices)
        error('dev_cost_ICPLike_v01:EmptyKnnCandidateFaces', ...
              'Measured point %d has no candidate faces.', pointIndex);
    end

    currentCandidateFaces = boneMeshFaces(currentCandidateFaceIndices, :);
    candidateFaceCountByPoint(pointIndex) = numel(currentCandidateFaceIndices);

    [pointToSurfaceDistancesMmKnn(pointIndex), ...
     closestBonePointsRefKnn(pointIndex, :)] = ...
        distancePointMesh( ...
            boneSurfacePointsRef(pointIndex, :), ...
            boneMeshVerticesRef, ...
            currentCandidateFaces, ...
            'algorithm', 'vectorized');
end
knnCorrespondenceRuntimeSeconds = toc(knnCorrespondenceTimer);

% Preserve the same per-measurement cell organization used by the all-face
% reference so later debugging can trace accelerated results back to images.
closestBonePointsRefKnnCells     = cell(numberOfMeasurements, 1);
pointToSurfaceDistanceMmKnnCells = cell(numberOfMeasurements, 1);
firstPointIndex = 1;

for currentMeasurementIndex = 1:numberOfMeasurements
    currentPointCount   = numberOfSurfacePointsByMeasurement(currentMeasurementIndex);
    currentPointIndices = firstPointIndex:(firstPointIndex + currentPointCount - 1);

    closestBonePointsRefKnnCells{currentMeasurementIndex}     = closestBonePointsRefKnn(currentPointIndices, :);
    pointToSurfaceDistanceMmKnnCells{currentMeasurementIndex} = pointToSurfaceDistancesMmKnn(currentPointIndices);

    firstPointIndex = firstPointIndex + currentPointCount;
end

% STEP 5: Report the correspondences
%
% Summarize the accelerated correspondences with the same columns as the
% full-mesh table. Keeping both table layouts identical makes their rows easy
% to compare without requiring separate analysis code.

meanDistanceMmByMeasurementKnn    = nan(numberOfMeasurements, 1);
rmseDistanceMmByMeasurementKnn    = nan(numberOfMeasurements, 1);
maximumDistanceMmByMeasurementKnn = nan(numberOfMeasurements, 1);

for currentMeasurementIndex = 1:numberOfMeasurements
    % Read the accelerated distances for one ultrasound measurement. Empty
    % measurements remain NaN in the table because no statistic exists.
    currentDistancesMmKnn = pointToSurfaceDistanceMmKnnCells{currentMeasurementIndex};
    if isempty(currentDistancesMmKnn)
        continue;
    end

    % Calculate the same three distance statistics used by the full-mesh
    % implementation so differences come only from correspondence searching.
    meanDistanceMmByMeasurementKnn(currentMeasurementIndex) = mean(currentDistancesMmKnn);
    rmseDistanceMmByMeasurementKnn(currentMeasurementIndex) = sqrt(mean(currentDistancesMmKnn .^ 2));
    maximumDistanceMmByMeasurementKnn(currentMeasurementIndex) = max(currentDistancesMmKnn);
end

% Use an explicit accelerated-version name so the original reference table
% remains available in the workspace for side-by-side debugging.
correspondenceSummaryTableAccelerated = table( ...
    measurementIndex, ...
    sourceIndex, ...
    measurementStatus, ...
    numberOfSurfacePointsByMeasurement, ...
    meanDistanceMmByMeasurementKnn, ...
    rmseDistanceMmByMeasurementKnn, ...
    maximumDistanceMmByMeasurementKnn, ...
    'VariableNames', correspondenceSummaryTable.Properties.VariableNames);

% Calculate global statistics from every accelerated correspondence. These
% values provide the direct equivalent of the full-mesh summary above.
meanPointToSurfaceDistanceMmKnn    = mean(pointToSurfaceDistancesMmKnn);
rmsePointToSurfaceDistanceMmKnn    = sqrt(mean(pointToSurfaceDistancesMmKnn .^ 2));
medianPointToSurfaceDistanceMmKnn  = median(pointToSurfaceDistancesMmKnn);
maximumPointToSurfaceDistanceMmKnn = max(pointToSurfaceDistancesMmKnn);

disp(correspondenceSummaryTableAccelerated);
fprintf(['Matched %d measured points in %.3f seconds using KNN candidate faces.\n', ...
         'Overall distance: mean %.3f mm, RMSE %.3f mm, ', ...
         'median %.3f mm, maximum %.3f mm.\n'], ...
    numel(pointToSurfaceDistancesMmKnn), ...
    knnCorrespondenceRuntimeSeconds, ...
    meanPointToSurfaceDistanceMmKnn, ...
    rmsePointToSurfaceDistanceMmKnn, ...
    medianPointToSurfaceDistanceMmKnn, ...
    maximumPointToSurfaceDistanceMmKnn);

%% COMPARING THE TWO APPROACH.

knnDistanceErrorMm     = pointToSurfaceDistancesMmKnn - pointToSurfaceDistancesMm;
knnClosestPointErrorMm = vecnorm(closestBonePointsRefKnn - closestBonePointsRef, 2, 2);
knnMatchToleranceMm    = 1e-6;

% A local subset cannot produce a meaningfully shorter distance than the
% global all-face search. A violation indicates an implementation problem.
if any(knnDistanceErrorMm < -knnMatchToleranceMm)
    error('dev_cost_ICPLike_v01:KnnDistanceBelowReference', ...
          'A KNN candidate-face distance is smaller than the all-face reference.');
end

knnExactDistanceMatchMask      = abs(knnDistanceErrorMm) <= knnMatchToleranceMm;
knnExactDistanceMatchPercent   = 100 * mean(knnExactDistanceMatchMask);
knnMeanAbsoluteDistanceErrorMm = mean(abs(knnDistanceErrorMm));
knnRmseDistanceErrorMm         = sqrt(mean(knnDistanceErrorMm .^ 2));
knnMaximumDistanceErrorMm      = max(abs(knnDistanceErrorMm));
knnMaximumClosestPointErrorMm  = max(knnClosestPointErrorMm);
meanCandidateFaceCount         = mean(candidateFaceCountByPoint);
maximumCandidateFaceCount      = max(candidateFaceCountByPoint);
knnSpeedupFactor               = correspondenceRuntimeSeconds / knnCorrespondenceRuntimeSeconds;

% Present one compact comparison row so different K values can be tested by
% changing only requestedNearestVertexCount and rerunning this section.
knnCorrespondenceComparisonTable = table( ...
    nearestVertexCount, ...
    meanCandidateFaceCount, ...
    maximumCandidateFaceCount, ...
    correspondenceRuntimeSeconds, ...
    knnCorrespondenceRuntimeSeconds, ...
    knnSpeedupFactor, ...
    knnExactDistanceMatchPercent, ...
    knnMeanAbsoluteDistanceErrorMm, ...
    knnRmseDistanceErrorMm, ...
    knnMaximumDistanceErrorMm, ...
    knnMaximumClosestPointErrorMm);

disp(knnCorrespondenceComparisonTable);
fprintf(['KNN candidate-face search used K = %d and matched %.2f%% ', ...
         'of reference distances within %.1e mm.\n', ...
         'Runtime %.3f s versus %.3f s reference (%.2fx speedup).\n'], ...
    nearestVertexCount, ...
    knnExactDistanceMatchPercent, ...
    knnMatchToleranceMm, ...
    knnCorrespondenceRuntimeSeconds, ...
    correspondenceRuntimeSeconds, ...
    knnSpeedupFactor);
