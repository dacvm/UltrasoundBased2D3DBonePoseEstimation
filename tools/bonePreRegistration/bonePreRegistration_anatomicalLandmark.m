clear;
clc;
close all;

%% PATH DEFINITION

% Keep the CT result path relative to the project so the script works when
% the complete project folder is moved to another computer.
filepath_ctmat = fullfile('tools', 'ctkneePostProcess', 'outputs', 'kneephantom');
filename_ctmat = 'kneephantom_bones_and_bonepins.mat';

%% USER SETTINGS

% Select the anatomical side represented by both meshes. The ERC frame
% convention used by this project points positive z medially for a left
% knee and laterally for a right knee.
kneeSide = "left";

% Move the tibial landmark line this far distally from the tibial ACS
% origin. The mesh and ACS coordinates in this dataset are in millimetres.
tibiaDistalOffset_mm = 10;



%% LOAD AND VALIDATE THE BONE DATA

% Locate the project from this script instead of depending on MATLAB's
% current folder when the user starts the workflow.
scriptFullPath = mfilename('fullpath');
if isempty(scriptFullPath)
    error('bonePreRegistration:ScriptPathUnavailable', ...
          'Run bonePreRegistration_anatomicalLandmark.m as a complete script so its input path can be resolved.');
end
scriptDirectory  = fileparts(scriptFullPath);
toolsDirectory   = fileparts(scriptDirectory);
projectDirectory = fileparts(toolsDirectory);

% Build and check the exact MAT-file path before attempting to load it.
ctmatFullPath = fullfile(projectDirectory, filepath_ctmat, filename_ctmat);
if ~isfile(ctmatFullPath)
    error('bonePreRegistration:MissingCtMatFile', ...
        'The configured CT MAT file does not exist: %s', ctmatFullPath);
end

% Load only the variable needed by this workflow so unrelated saved values
% cannot accidentally replace settings or intermediate variables.
loadedCtData = load(ctmatFullPath, 'bones');
if ~isfield(loadedCtData, 'bones')
    error('bonePreRegistration:MissingBonesVariable', ...
        'The CT MAT file does not contain a variable named bones: %s', ...
        ctmatFullPath);
end
bones = loadedCtData.bones;
if ~isstruct(bones) || numel(bones) ~= 2
    error('bonePreRegistration:InvalidBonesVariable', ...
        'Variable bones must contain exactly the femur and tibia records.');
end

% Select each bone by its saved anatomical code because femur and tibia can
% appear in either array order in different CT MAT files.
[femurBone, femurBoneIndex] = selectBoneRecordByCode( bones, "F", 'Femur');
[tibiaBone, tibiaBoneIndex] = selectBoneRecordByCode( bones, "T", 'Tibia');
validateBoneRecord(femurBone, 'Femur', femurBoneIndex);
validateBoneRecord(tibiaBone, 'Tibia', tibiaBoneIndex);

% Normalize and validate the side setting once so every later label uses
% exactly the same left/right interpretation.
kneeSide = lower(strtrim(convertCharsToStrings(kneeSide)));
if ~isscalar(kneeSide) || ismissing(kneeSide) || ~any(kneeSide == ["left", "right"])
    error('bonePreRegistration:InvalidKneeSide', 'kneeSide must be either "left" or "right".');
end

% A negative offset would move toward the plateau rather than in the
% requested distal direction, so reject it as a user-setting error.
if ~isnumeric(tibiaDistalOffset_mm) || ...
        ~isscalar(tibiaDistalOffset_mm) || ...
        ~isreal(tibiaDistalOffset_mm) || ...
        ~isfinite(tibiaDistalOffset_mm) || ...
        tibiaDistalOffset_mm < 0
    error('bonePreRegistration:InvalidTibiaDistalOffset', ...
        'tibiaDistalOffset_mm must be one finite, nonnegative number.');
end



%% FIND THE FEMORAL LANDMARKS

% Read the femoral ACS origin and mediolateral direction from the saved
% column-wise transform. Normalization makes the signed line parameters
% physical distances in millimetres.
T_femurBone_CT           = femurBone.T_bone_CT;
point_femurLineOrigin_CT = T_femurBone_CT(1:3, 4).';
vector_femurZ_CT         = normalizeVector(T_femurBone_CT(1:3, 3).', 'femoral z-axis');

% Intersect the full z-axis with every triangle, then retain the two
% exterior crossings rather than a nearby-vertex approximation.
[points_femurIntersections_CT, distances_femurIntersections_mm] = ...
    intersectInfiniteLineWithMesh(femurBone.mesh, ...
    point_femurLineOrigin_CT, vector_femurZ_CT, 'femur');
[point_femurNegativeZ_CT, point_femurPositiveZ_CT, ...
    distance_femurNegativeZ_mm, distance_femurPositiveZ_mm] = ...
    selectOuterLineIntersections(points_femurIntersections_CT, ...
    distances_femurIntersections_mm, 'femur');



%% FIND THE TIBIAL LANDMARKS

% The ERC positive y-axis is proximal, so subtracting the requested
% distance moves the tibial line origin distally along the condyles.
T_tibiaBone_CT           = tibiaBone.T_bone_CT;
point_tibiaAcsOrigin_CT  = T_tibiaBone_CT(1:3, 4).';
vector_tibiaY_CT         = normalizeVector(T_tibiaBone_CT(1:3, 2).', 'tibial y-axis');
vector_tibiaZ_CT         = normalizeVector(T_tibiaBone_CT(1:3, 3).', 'tibial z-axis');
point_tibiaLineOrigin_CT = point_tibiaAcsOrigin_CT - tibiaDistalOffset_mm * vector_tibiaY_CT;

% Reuse the exact surface calculation so both bones follow one consistent
% landmark definition and one set of numerical tolerances.
[points_tibiaIntersections_CT, distances_tibiaIntersections_mm] = ...
    intersectInfiniteLineWithMesh(tibiaBone.mesh, ...
    point_tibiaLineOrigin_CT, vector_tibiaZ_CT, 'tibia');
[point_tibiaNegativeZ_CT, point_tibiaPositiveZ_CT, ...
    distance_tibiaNegativeZ_mm, distance_tibiaPositiveZ_mm] = ...
    selectOuterLineIntersections(points_tibiaIntersections_CT, ...
    distances_tibiaIntersections_mm, 'tibia');



%% MAP THE SIGNED POINTS TO ANATOMICAL SIDES

% Use the selected knee side to give stable anatomical names while keeping
% the underlying signed-z geometry available for inspection.
switch kneeSide
    case "left"
        positiveZSide = "medial";
        point_femurMedial_CT  = point_femurPositiveZ_CT;
        point_femurLateral_CT = point_femurNegativeZ_CT;
        point_tibiaMedial_CT  = point_tibiaPositiveZ_CT;
        point_tibiaLateral_CT = point_tibiaNegativeZ_CT;
    case "right"
        positiveZSide = "lateral";
        point_femurMedial_CT  = point_femurNegativeZ_CT;
        point_femurLateral_CT = point_femurPositiveZ_CT;
        point_tibiaMedial_CT  = point_tibiaNegativeZ_CT;
        point_tibiaLateral_CT = point_tibiaPositiveZ_CT;
end



%% COLLECT AND REPORT THE LANDMARK RESULTS

% Match the 1-by-2 bones interface so the same index always identifies the
% same anatomy in bones, landmarks, and intersectionDiagnostics.
landmarkTemplate = struct( ...
    'name', '', ...
    'bone', '', ...
    'T_bone_CT', eye(4), ...
    'coordinateFrame', "CT", ...
    'units', "mm", ...
    'kneeSide', kneeSide, ...
    'positiveZSide', positiveZSide, ...
    'distalOffset_mm', 0, ...
    'medial', zeros(1, 3), ...
    'lateral', zeros(1, 3), ...
    'points', zeros(2, 3));
landmarks = repmat(landmarkTemplate, size(bones));

% Copy only the identity and coordinate context from bones. The source mesh
% and path stay in bones and remain reachable through the aligned index.
for boneIndex = 1:numel(bones)
    landmarks(boneIndex).name = bones(boneIndex).name;
    landmarks(boneIndex).bone = bones(boneIndex).bone;
end

% Store each pair in the fixed row order [medial; lateral]. A zero femoral
% offset records that its line passes through the original ACS origin.
landmarks(1).distalOffset_mm = 0;
landmarks(1).medial          = point_femurMedial_CT;
landmarks(1).lateral         = point_femurLateral_CT;
landmarks(1).points          = [point_femurMedial_CT; point_femurLateral_CT];
landmarks(2).distalOffset_mm = tibiaDistalOffset_mm;
landmarks(2).medial          = point_tibiaMedial_CT;
landmarks(2).lateral         = point_tibiaLateral_CT;
landmarks(2).points          = [point_tibiaMedial_CT; point_tibiaLateral_CT];

% Build a matching diagnostics array without duplicating either bone mesh.
% These fields retain every unique crossing for later topology inspection.
diagnosticTemplate = struct( ...
    'name', '', ...
    'bone', '', ...
    'T_bone_CT', eye(4), ...
    'coordinateFrame', "CT", ...
    'units', "mm", ...
    'distalOffset_mm', 0, ...
    'lineOrigin', zeros(1, 3), ...
    'lineDirection', zeros(1, 3), ...
    'points', zeros(0, 3), ...
    'signedDistances_mm', zeros(0, 1));
intersectionDiagnostics = repmat(diagnosticTemplate, size(bones));

% Copy the shared bone identity so diagnostics(i) always describes bones(i).
for boneIndex = 1:numel(bones)
    intersectionDiagnostics(boneIndex).name = bones(boneIndex).name;
    intersectionDiagnostics(boneIndex).bone = bones(boneIndex).bone;
end

% Record the femoral and tibial line calculations in their matching slots.
intersectionDiagnostics(1).distalOffset_mm    = 0;
intersectionDiagnostics(1).lineOrigin         = point_femurLineOrigin_CT;
intersectionDiagnostics(1).lineDirection      = vector_femurZ_CT;
intersectionDiagnostics(1).points             = points_femurIntersections_CT;
intersectionDiagnostics(1).signedDistances_mm = distances_femurIntersections_mm;
intersectionDiagnostics(2).distalOffset_mm    = tibiaDistalOffset_mm;
intersectionDiagnostics(2).lineOrigin         = point_tibiaLineOrigin_CT;
intersectionDiagnostics(2).lineDirection      = vector_tibiaZ_CT;
intersectionDiagnostics(2).points             = points_tibiaIntersections_CT;
intersectionDiagnostics(2).signedDistances_mm = distances_tibiaIntersections_mm;

% Display one compact table so the four requested coordinates can be read
% or copied directly from the MATLAB command window.
boneName                = ["Femur"; "Femur"; "Tibia"; "Tibia"];
anatomicalSide          = ["Medial"; "Lateral"; "Medial"; "Lateral"];
landmarkCoordinates_CT  = vertcat(landmarks.points);
landmarkTable = table(boneName, anatomicalSide, ...
    landmarkCoordinates_CT(:, 1), ...
    landmarkCoordinates_CT(:, 2), ...
    landmarkCoordinates_CT(:, 3), ...
    'VariableNames', {'Bone', 'Side', 'X_CT_mm', 'Y_CT_mm', 'Z_CT_mm'});
disp(landmarkTable);

fprintf('Femoral landmark width: %.2f mm\n', norm(point_femurLateral_CT - point_femurMedial_CT));
fprintf('Tibial landmark width at %.2f mm distal: %.2f mm\n', tibiaDistalOffset_mm, norm(point_tibiaLateral_CT - point_tibiaMedial_CT));
fprintf('Positive local z is mapped to the %s side for a %s knee.\n', positiveZSide, kneeSide);



%% DISPLAY THE LANDMARKS FOR VISUAL VERIFICATION

% Use one shared CT-space view so the selected dots can be compared with
% the bone shapes and coordinate systems shown in the reference figure.
figure_landmarks = figure( ...
    'Name', 'Bone pre-registration anatomical landmarks', ...
    'Color', 'white', ...
    'Position', [100, 100, 1000, 850]);
axes_landmarks = axes('Parent', figure_landmarks);
hold(axes_landmarks, 'on');

% Draw transparent surfaces so the axes and intersection lines remain
% visible when they pass through the bones.
patch_femur = patch(axes_landmarks, ...
    'Faces', femurBone.mesh.ConnectivityList, ...
    'Vertices', femurBone.mesh.Points, ...
    'FaceColor', [0.25, 0.55, 0.75], ...
    'FaceAlpha', 0.42, ...
    'EdgeColor', 'none', ...
    'DisplayName', 'Femur');
patch_tibia = patch(axes_landmarks, ...
    'Faces', tibiaBone.mesh.ConnectivityList, ...
    'Vertices', tibiaBone.mesh.Points, ...
    'FaceColor', [0.72, 0.53, 0.43], ...
    'FaceAlpha', 0.42, ...
    'EdgeColor', 'none', ...
    'DisplayName', 'Tibia');

% Extend each displayed line slightly beyond its outer crossings so its
% relationship to the selected surface points is visually clear.
femurLineMargin_mm          = 0.08 * (distance_femurPositiveZ_mm - distance_femurNegativeZ_mm);
femurLineDistances_mm       = [distance_femurNegativeZ_mm - femurLineMargin_mm; ...
                               distance_femurPositiveZ_mm + femurLineMargin_mm];
points_femurLineDisplay_CT  = point_femurLineOrigin_CT + femurLineDistances_mm .* vector_femurZ_CT;
plot3(axes_landmarks, ...
    points_femurLineDisplay_CT(:, 1), ...
    points_femurLineDisplay_CT(:, 2), ...
    points_femurLineDisplay_CT(:, 3), '-', ...
    'Color', [0.00, 0.20, 0.80], 'LineWidth', 2.0, ...
    'HandleVisibility', 'off');

tibiaLineMargin_mm          = 0.08 * (distance_tibiaPositiveZ_mm - distance_tibiaNegativeZ_mm);
tibiaLineDistances_mm       = [distance_tibiaNegativeZ_mm - tibiaLineMargin_mm; 
                               distance_tibiaPositiveZ_mm + tibiaLineMargin_mm];
points_tibiaLineDisplay_CT  = point_tibiaLineOrigin_CT + tibiaLineDistances_mm .* vector_tibiaZ_CT;
plot3(axes_landmarks, ...
    points_tibiaLineDisplay_CT(:, 1), ...
    points_tibiaLineDisplay_CT(:, 2), ...
    points_tibiaLineDisplay_CT(:, 3), '-', ...
    'Color', [0.90, 0.10, 0.10], 'LineWidth', 2.0, ...
    'HandleVisibility', 'off');

% Show the tibial distal shift as a dashed segment from the ACS origin to
% the line origin, making the user-set offset easy to check visually.
plot3(axes_landmarks, ...
    [point_tibiaAcsOrigin_CT(1), point_tibiaLineOrigin_CT(1)], ...
    [point_tibiaAcsOrigin_CT(2), point_tibiaLineOrigin_CT(2)], ...
    [point_tibiaAcsOrigin_CT(3), point_tibiaLineOrigin_CT(3)], ...
    'k--', 'LineWidth', 1.5, 'HandleVisibility', 'off');

% Match the requested visual convention: blue dots for the femur and red
% dots for the tibia, both with dark outlines for contrast on the meshes.
scatter_femur = scatter3(axes_landmarks, ...
    landmarks(1).points(:, 1), ...
    landmarks(1).points(:, 2), ...
    landmarks(1).points(:, 3), ...
    130, [0.00, 0.45, 0.85], 'filled', ...
    'MarkerEdgeColor', 'k', 'LineWidth', 1.2, ...
    'DisplayName', 'Femur landmarks');
scatter_tibia = scatter3(axes_landmarks, ...
    landmarks(2).points(:, 1), ...
    landmarks(2).points(:, 2), ...
    landmarks(2).points(:, 3), ...
    130, [1.00, 0.10, 0.10], 'filled', ...
    'MarkerEdgeColor', 'k', 'LineWidth', 1.2, ...
    'DisplayName', 'Tibia landmarks');

% Place each label just outside its landmark pair so the two names do not
% overlap in the frontal CT X-Z verification view.
labelOffset_mm = 3;
if point_femurMedial_CT(1) >= point_femurLateral_CT(1)
    femurMedialLabelX_mm = point_femurMedial_CT(1) + labelOffset_mm;
    femurLateralLabelX_mm = point_femurLateral_CT(1) - labelOffset_mm;
    femurMedialAlignment = 'left';
    femurLateralAlignment = 'right';
else
    femurMedialLabelX_mm = point_femurMedial_CT(1) - labelOffset_mm;
    femurLateralLabelX_mm = point_femurLateral_CT(1) + labelOffset_mm;
    femurMedialAlignment = 'right';
    femurLateralAlignment = 'left';
end
if point_tibiaMedial_CT(1) >= point_tibiaLateral_CT(1)
    tibiaMedialLabelX_mm = point_tibiaMedial_CT(1) + labelOffset_mm;
    tibiaLateralLabelX_mm = point_tibiaLateral_CT(1) - labelOffset_mm;
    tibiaMedialAlignment = 'left';
    tibiaLateralAlignment = 'right';
else
    tibiaMedialLabelX_mm = point_tibiaMedial_CT(1) - labelOffset_mm;
    tibiaLateralLabelX_mm = point_tibiaLateral_CT(1) + labelOffset_mm;
    tibiaMedialAlignment = 'right';
    tibiaLateralAlignment = 'left';
end

% Label every result so the medial/lateral mapping can be reviewed without
% relying only on color or point order.
text(axes_landmarks, femurMedialLabelX_mm, ...
    point_femurMedial_CT(2), point_femurMedial_CT(3), ...
    'Femur medial', 'FontWeight', 'bold', ...
    'HorizontalAlignment', femurMedialAlignment, ...
    'Color', [0.00, 0.25, 0.65]);
text(axes_landmarks, femurLateralLabelX_mm, ...
    point_femurLateral_CT(2), point_femurLateral_CT(3), ...
    'Femur lateral', 'FontWeight', 'bold', ...
    'HorizontalAlignment', femurLateralAlignment, ...
    'Color', [0.00, 0.25, 0.65]);
text(axes_landmarks, tibiaMedialLabelX_mm, ...
    point_tibiaMedial_CT(2), point_tibiaMedial_CT(3), ...
    'Tibia medial', 'FontWeight', 'bold', ...
    'HorizontalAlignment', tibiaMedialAlignment, ...
    'Color', [0.75, 0.00, 0.00]);
text(axes_landmarks, tibiaLateralLabelX_mm, ...
    point_tibiaLateral_CT(2), point_tibiaLateral_CT(3), ...
    'Tibia lateral', 'FontWeight', 'bold', ...
    'HorizontalAlignment', tibiaLateralAlignment, ...
    'Color', [0.75, 0.00, 0.00]);

% Draw both anatomical coordinate systems at scales based on the matching
% mesh lengths so the arrows remain readable for differently sized bones.
femurMeshExtent_mm  = max(femurBone.mesh.Points, [], 1) - min(femurBone.mesh.Points, [], 1);
tibiaMeshExtent_mm  = max(tibiaBone.mesh.Points, [], 1) - min(tibiaBone.mesh.Points, [], 1);
femurAxisScale_mm   = 0.12 * max(femurMeshExtent_mm);
tibiaAxisScale_mm   = 0.12 * max(tibiaMeshExtent_mm);
axisColors          = [1, 0, 0; 0, 0.70, 0; 0, 0.25, 1];
for axisIndex = 1:3
    quiver3(axes_landmarks, point_femurLineOrigin_CT(1), ...
        point_femurLineOrigin_CT(2), point_femurLineOrigin_CT(3), ...
        T_femurBone_CT(1, axisIndex) * femurAxisScale_mm, ...
        T_femurBone_CT(2, axisIndex) * femurAxisScale_mm, ...
        T_femurBone_CT(3, axisIndex) * femurAxisScale_mm, 0, ...
        'Color', axisColors(axisIndex, :), 'LineWidth', 1.5, ...
        'MaxHeadSize', 0.4, 'HandleVisibility', 'off');
    quiver3(axes_landmarks, point_tibiaAcsOrigin_CT(1), ...
        point_tibiaAcsOrigin_CT(2), point_tibiaAcsOrigin_CT(3), ...
        T_tibiaBone_CT(1, axisIndex) * tibiaAxisScale_mm, ...
        T_tibiaBone_CT(2, axisIndex) * tibiaAxisScale_mm, ...
        T_tibiaBone_CT(3, axisIndex) * tibiaAxisScale_mm, 0, ...
        'Color', axisColors(axisIndex, :), 'LineWidth', 1.5, ...
        'MaxHeadSize', 0.4, 'HandleVisibility', 'off');
end

% Finish with an undistorted frontal CT X-Z view that matches the supplied
% reference image. The user can still rotate the interactive figure.
title(axes_landmarks, sprintf('%s knee landmarks, tibia offset %.1f mm distal', upper(kneeSide), tibiaDistalOffset_mm));
xlabel(axes_landmarks, 'CT X (mm)');
ylabel(axes_landmarks, 'CT Y (mm)');
zlabel(axes_landmarks, 'CT Z (mm)');
axis(axes_landmarks, 'equal');
grid(axes_landmarks, 'on');
view(axes_landmarks, 0, 0);
legend(axes_landmarks, [patch_femur, patch_tibia, scatter_femur, scatter_tibia], 'Location', 'northeastoutside');
camlight(axes_landmarks, 'headlight');
lighting(axes_landmarks, 'gouraud');

%% SAVE THE OUTPUT

% Keep generated results beside this tool so they do not depend on the
% current MATLAB folder and remain separate from the source CT inputs.
outputDirectory = fullfile(scriptDirectory, 'outputs');
if ~isfolder(outputDirectory)
    [wasOutputDirectoryCreated, mkdirMessage] = mkdir(outputDirectory);
    if ~wasOutputDirectoryCreated
        error('bonePreRegistration:OutputDirectoryCreationFailed', 'Could not create output directory %s: %s', outputDirectory, mkdirMessage);
    end
end

% Capture the time once so the MAT, FIG, and PNG always share one base name.
% Uppercase HH uses a 24-hour clock and avoids AM/PM ambiguity.
outputTimestamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
outputBaseName = ['boneLandmarks_', outputTimestamp];
outputMatPath = fullfile(outputDirectory, [outputBaseName, '.mat']);
outputFigPath = fullfile(outputDirectory, [outputBaseName, '.fig']);
outputPngPath = fullfile(outputDirectory, [outputBaseName, '.png']);

% Refuse a same-second collision rather than silently replacing an earlier
% landmark result or creating artifacts with mismatched contents.
if any(isfile({outputMatPath, outputFigPath, outputPngPath}))
    error('bonePreRegistration:OutputFileAlreadyExists', ...
        'An output file already exists for timestamp %s.', outputTimestamp);
end

% Ensure the exact verification figure is still available before starting
% the three-file export sequence.
if ~isgraphics(figure_landmarks, 'figure')
    error('bonePreRegistration:VerificationFigureUnavailable', ...
        'The landmark verification figure is not available for saving.');
end

% Save only the two requested public data structures. Version 7.3 remains
% usable if future diagnostic arrays become much larger.
save(outputMatPath, 'landmarks', 'intersectionDiagnostics', '-v7.3');

% Finish pending drawing before storing both the editable MATLAB figure and
% a high-resolution image of the same visual state.
drawnow;
savefig(figure_landmarks, outputFigPath);
exportgraphics(figure_landmarks, outputPngPath, 'Resolution', 300);

% Verify and report every artifact so missing output is caught immediately
% and the user can find the completed run from the command window.
if ~all(isfile({outputMatPath, outputFigPath, outputPngPath}))
    error('bonePreRegistration:OutputSaveIncomplete', ...
        'One or more landmark output files were not created successfully.');
end
fprintf('Saved bone landmark outputs:\n');
fprintf('  MAT: %s\n', outputMatPath);
fprintf('  FIG: %s\n', outputFigPath);
fprintf('  PNG: %s\n', outputPngPath);



%% LOCAL VALIDATION AND GEOMETRY HELPERS

function [boneRecord, boneIndex] = selectBoneRecordByCode( ...
        bones, requestedCode, boneLabel)
%SELECTBONERECORDBYCODE Find one anatomical bone without assuming its index.
%   Different MAT files can save femur and tibia in different array orders.
%   This helper uses the bones(...).bone indicator so the correct mesh and
%   transform are selected regardless of that order.
%
%   Inputs:
%       bones         - Struct array containing the saved bone records.
%       requestedCode - One-character indicator, such as "F" or "T".
%       boneLabel     - Human-readable anatomical name for error messages.
%
%   Outputs:
%       boneRecord - The single record matching requestedCode.
%       boneIndex  - Its one-based index in the original bones array.

% Require the indicator before reading individual records so a legacy MAT
% file fails with a direct explanation.
if ~isfield(bones, 'bone')
    error('bonePreRegistration:MissingBoneCodeField', ...
        'Every record in bones must contain the field bone.');
end

% Normalize each saved indicator independently because MAT files may store
% the values as either character vectors or string scalars.
boneCodes = strings(size(bones));
for currentIndex = 1:numel(bones)
    currentCode = convertCharsToStrings(bones(currentIndex).bone);
    if ~isscalar(currentCode) || ismissing(currentCode) || ...
            strlength(strtrim(currentCode)) == 0
        error('bonePreRegistration:InvalidBoneCode', ...
            'bones(%d).bone must contain one valid bone indicator.', ...
            currentIndex);
    end
    boneCodes(currentIndex) = upper(strtrim(currentCode));
end

% Exactly one match is required because no safe automatic choice exists
% when a requested bone is absent or duplicated.
requestedCode = upper(strtrim(convertCharsToStrings(requestedCode)));
matchingIndices = find(boneCodes == requestedCode);
if numel(matchingIndices) ~= 1
    error('bonePreRegistration:BoneCodeNotUnique', ...
        ['Expected exactly one %s record with bones(...).bone == "%s", ', ...
         'but found %d.'], boneLabel, requestedCode, numel(matchingIndices));
end

% Return both the selected record and its source index for later validation
% messages and workspace diagnostics.
boneIndex = matchingIndices(1);
boneRecord = bones(boneIndex);
end

function validateBoneRecord(boneRecord, expectedName, boneIndex)
%VALIDATEBONERECORD Check one saved bone record before landmark extraction.
%   This function verifies the mesh and anatomical transform because an
%   invalid record would otherwise produce misleading surface landmarks.
%
%   Inputs:
%       boneRecord   - Scalar struct containing name, mesh, and T_bone_CT.
%       expectedName - Expected anatomical name, such as 'Femur'.
%       boneIndex    - Selected one-based position inside the bones array.
%
%   Outputs:
%       None. The function throws a descriptive error when validation fails.

% Require one struct with every field used by the extraction workflow.
if ~isstruct(boneRecord) || ~isscalar(boneRecord) || ...
        ~all(isfield(boneRecord, {'name', 'mesh', 'T_bone_CT'}))
    error('bonePreRegistration:InvalidBoneRecord', ...
        'bones(%d) must contain name, mesh, and T_bone_CT.', boneIndex);
end

% Confirm that the selected code and descriptive name refer to the same
% anatomy rather than silently accepting inconsistent saved metadata.
recordName = convertCharsToStrings(boneRecord.name);
if ~isscalar(recordName) || ismissing(recordName) || ...
        ~strcmpi(strtrim(recordName), expectedName)
    error('bonePreRegistration:UnexpectedBoneName', ...
        'Expected bones(%d) to be %s, but found "%s".', ...
        boneIndex, expectedName, recordName);
end

% A triangulation supplies the triangle connectivity required by the exact
% line-surface calculation.
meshTri = boneRecord.mesh;
if ~isa(meshTri, 'triangulation') || isempty(meshTri.Points) || ...
        isempty(meshTri.ConnectivityList)
    error('bonePreRegistration:InvalidBoneMesh', ...
        'The %s mesh must be a nonempty MATLAB triangulation.', expectedName);
end
if any(~isfinite(meshTri.Points), 'all')
    error('bonePreRegistration:NonFiniteBoneMesh', ...
        'The %s mesh contains NaN or Inf vertex coordinates.', expectedName);
end

% Check the complete homogeneous transform before reading individual axes.
T_bone_CT = boneRecord.T_bone_CT;
if ~isnumeric(T_bone_CT) || ~isreal(T_bone_CT) || ...
        ~isequal(size(T_bone_CT), [4, 4]) || ...
        any(~isfinite(T_bone_CT), 'all')
    error('bonePreRegistration:InvalidBoneTransform', ...
        'The %s T_bone_CT must be one finite real 4-by-4 matrix.', ...
        expectedName);
end
if norm(T_bone_CT(4, :) - [0, 0, 0, 1], inf) > 1e-9
    error('bonePreRegistration:InvalidHomogeneousRow', ...
        'The %s T_bone_CT must end with [0 0 0 1].', expectedName);
end

% Require a proper near-orthonormal rotation so z-sign and distal y-shifts
% keep their intended anatomical meaning.
rotationMatrix = T_bone_CT(1:3, 1:3);
if norm(rotationMatrix.' * rotationMatrix - eye(3), 'fro') > 1e-3 || ...
        abs(det(rotationMatrix) - 1) > 1e-3
    error('bonePreRegistration:InvalidBoneRotation', ...
        'The %s rotation in T_bone_CT must be right-handed and orthonormal.', ...
        expectedName);
end
end

function unitVector = normalizeVector(inputVector, vectorLabel)
%NORMALIZEVECTOR Convert a finite 3D direction to unit length.
%   Normalization makes signed intersection parameters represent physical
%   distances and prevents small rotation-matrix scale errors from mattering.
%
%   Inputs:
%       inputVector - Three-element numeric row or column direction.
%       vectorLabel - Human-readable name used in validation errors.
%
%   Outputs:
%       unitVector - One-by-three normalized direction vector.

% Convert every input to a row so later vectorized mesh operations have a
% consistent shape.
inputVector = inputVector(:).';
if numel(inputVector) ~= 3 || ~isreal(inputVector) || ...
        any(~isfinite(inputVector))
    error('bonePreRegistration:InvalidAxisDirection', ...
        'The %s must contain three finite real values.', vectorLabel);
end

% Reject a direction with no usable length before dividing by it.
vectorLength = norm(inputVector);
if vectorLength <= eps(max(1, max(abs(inputVector))))
    error('bonePreRegistration:ZeroAxisDirection', ...
        'The %s has zero or negligible length.', vectorLabel);
end
unitVector = inputVector / vectorLength;
end

function [intersectionPoints, signedDistances] = ...
        intersectInfiniteLineWithMesh(meshTri, lineOrigin, ...
        lineDirection, meshLabel)
%INTERSECTINFINITELINEWITHMESH Find exact crossings of a line and triangles.
%   The function applies the vectorized Moller-Trumbore test to an infinite
%   line. It is needed because projecting a nearby mesh vertex onto the line
%   does not guarantee a true point on the triangular surface.
%
%   Inputs:
%       meshTri      - MATLAB triangulation describing the bone surface.
%       lineOrigin   - One-by-three point located on the infinite line.
%       lineDirection - One-by-three unit direction of the line.
%       meshLabel    - Human-readable bone name used in error messages.
%
%   Outputs:
%       intersectionPoints - N-by-3 unique CT-space surface crossings,
%                            sorted along the line direction.
%       signedDistances    - N-by-1 signed distances from lineOrigin.

% Read all triangle corners once so the intersection calculation stays
% vectorized across the complete mesh.
vertices = meshTri.Points;
faces = meshTri.ConnectivityList;
trianglePoint0 = vertices(faces(:, 1), :);
triangleEdge1 = vertices(faces(:, 2), :) - trianglePoint0;
triangleEdge2 = vertices(faces(:, 3), :) - trianglePoint0;

% Normalize defensively because signed parameters should use mesh units.
lineOrigin = lineOrigin(:).';
lineDirection = normalizeVector(lineDirection, ...
    sprintf('%s landmark line direction', meshLabel));
repeatedLineDirection = repmat(lineDirection, size(faces, 1), 1);

% Scale the parallel and duplicate tolerances to the current bone rather
% than assuming every input mesh has the same physical dimensions.
meshExtent = max(vertices, [], 1) - min(vertices, [], 1);
meshScale = max(meshExtent);
if ~isfinite(meshScale) || meshScale <= 0
    error('bonePreRegistration:DegenerateBoneMesh', ...
        'The %s mesh has no usable spatial extent.', meshLabel);
end
parallelTolerance = max(eps(meshScale ^ 2), 1e-12 * meshScale ^ 2);
barycentricTolerance = 1e-10;
mergeTolerance = max(1e-9, 1e-9 * meshScale);

% Compute the Moller-Trumbore determinant and skip parallel or degenerate
% triangles before division.
crossDirectionEdge2 = cross(repeatedLineDirection, triangleEdge2, 2);
determinant = sum(triangleEdge1 .* crossDirectionEdge2, 2);
validTriangle = abs(determinant) > parallelTolerance;

% Initialize invalid faces as NaN so they cannot pass the final hit mask.
uCoordinate = nan(size(determinant));
vCoordinate = nan(size(determinant));
signedParameter = nan(size(determinant));
vectorPoint0ToOrigin = lineOrigin - trianglePoint0;
inverseDeterminant = 1 ./ determinant(validTriangle);

% Calculate the first barycentric coordinate for nonparallel triangles.
uCoordinate(validTriangle) = sum( ...
    vectorPoint0ToOrigin(validTriangle, :) .* ...
    crossDirectionEdge2(validTriangle, :), 2) .* inverseDeterminant;

% Calculate the second barycentric coordinate and the signed line distance.
crossOriginEdge1 = cross(vectorPoint0ToOrigin, triangleEdge1, 2);
vCoordinate(validTriangle) = sum( ...
    repeatedLineDirection(validTriangle, :) .* ...
    crossOriginEdge1(validTriangle, :), 2) .* inverseDeterminant;
signedParameter(validTriangle) = sum( ...
    triangleEdge2(validTriangle, :) .* ...
    crossOriginEdge1(validTriangle, :), 2) .* inverseDeterminant;

% Accept points inside triangle boundaries in both directions because this
% is an infinite line rather than a one-sided ray.
isIntersection = validTriangle & ...
    uCoordinate >= -barycentricTolerance & ...
    vCoordinate >= -barycentricTolerance & ...
    (uCoordinate + vCoordinate) <= 1 + barycentricTolerance & ...
    isfinite(signedParameter);
rawSignedDistances = signedParameter(isIntersection);
if isempty(rawSignedDistances)
    error('bonePreRegistration:NoLineMeshIntersection', ...
        ['The %s landmark line does not intersect the mesh. Check the ACS ', ...
         'and, for the tibia, reduce the distal offset.'], meshLabel);
end

% Shared edges and vertices can report the same crossing from several
% triangles. Merge those distances before reconstructing exact line points.
signedDistances = uniquetol(rawSignedDistances, mergeTolerance, ...
    'DataScale', 1);
signedDistances = sort(signedDistances(:));
intersectionPoints = lineOrigin + signedDistances .* lineDirection;
end

function [negativePoint, positivePoint, negativeDistance, ...
        positiveDistance] = selectOuterLineIntersections( ...
        intersectionPoints, signedDistances, meshLabel)
%SELECTOUTERLINEINTERSECTIONS Choose exterior crossings on both line sides.
%   Complex or imperfect meshes can cross one line more than twice. The
%   farthest negative and positive crossings consistently represent the two
%   exterior condyle or epicondyle surfaces requested by this workflow.
%
%   Inputs:
%       intersectionPoints - N-by-3 unique points sorted along the line.
%       signedDistances    - N-by-1 matching signed line distances.
%       meshLabel          - Human-readable bone name for error messages.
%
%   Outputs:
%       negativePoint    - One-by-three outer point in negative z.
%       positivePoint    - One-by-three outer point in positive z.
%       negativeDistance - Signed distance of negativePoint from the origin.
%       positiveDistance - Signed distance of positivePoint from the origin.

% Ignore numerical zero when separating the two anatomical line sides.
sideTolerance = max(1e-9, 1e-9 * max(abs(signedDistances)));
negativeIndices = find(signedDistances < -sideTolerance);
positiveIndices = find(signedDistances > sideTolerance);
if isempty(negativeIndices) || isempty(positiveIndices)
    error('bonePreRegistration:MissingOppositeSideIntersections', ...
        ['The %s landmark line must cross the mesh on both sides of its ', ...
         'origin. Check the ACS and, for the tibia, reduce the offset.'], ...
        meshLabel);
end

% The sorted list makes its first and last entries the two exterior points.
negativeIndex = negativeIndices(1);
positiveIndex = positiveIndices(end);
negativePoint = intersectionPoints(negativeIndex, :);
positivePoint = intersectionPoints(positiveIndex, :);
negativeDistance = signedDistances(negativeIndex);
positiveDistance = signedDistances(positiveIndex);
end
