function [selectedSegmentMask, selectedSegments3D, selectedSegmentsUV, selectedPixels, segmentFacingScore] = ...
    selectProbeFacingIntersectionSegments(mesh, segments3D, segmentsUV, segmentFaceIdx, plane, du, dv, nRows, nCols, normalFacingToleranceDeg)
%SELECTPROBEFACINGINTERSECTIONSEGMENTS Keep intersection segments from probe-facing mesh faces.
%   [SELECTEDSEGMENTMASK, SELECTEDSEGMENTS3D, SELECTEDSEGMENTSUV, SELECTEDPIXELS, SEGMENTFACINGSCORE] = ...
%   SELECTPROBEFACINGINTERSECTIONSEGMENTS(MESH, SEGMENTS3D, SEGMENTSUV, SEGMENTFACEIDX, PLANE, DU, DV, NROWS, NCOLS, NORMALFACINGTOLERANCEDEG)
%   keeps only the mesh-plane intersection segments whose source mesh face
%   normal points against PLANE.EY within the requested angular tolerance.
%
%   Inputs:
%       mesh                     : struct with fields V and F
%       segments3D               : cell array of 2-by-3 intersection segments
%       segmentsUV               : cell array of 2-by-2 clipped plane-coordinate segments
%       segmentFaceIdx           : face index aligned with each returned segment
%       plane                    : plane struct that must contain ey
%       du                       : physical width of one image pixel
%       dv                       : physical height of one image pixel
%       nRows                    : number of image rows
%       nCols                    : number of image columns
%       normalFacingToleranceDeg : maximum angle from -plane.ey, in degrees
%
%   Outputs:
%       selectedSegmentMask : logical mask aligned with the input segments
%       selectedSegments3D  : kept 3D segments
%       selectedSegmentsUV  : kept UV segments
%       selectedPixels      : [row, col] pixels rasterized from the kept UV segments
%       segmentFacingScore  : dot product between each face normal and -plane.ey

%% Validate Inputs And Required Geometry Data
% This section makes sure every input has the shape and meaning that the
% rest of the function expects.
%
% The main idea is simple: this function combines geometry data, plane
% direction data, and image-grid data. If one of those parts is missing or
% malformed, the later math could fail or, even worse, produce misleading
% results.
%
% So before doing any selection work, we stop early for invalid inputs.
% That keeps the later code easier to read because the rest of the function
% can assume the inputs are already trustworthy.

% Check that mesh is a scalar struct because the helper expects one mesh only.
if ~isstruct(mesh) || ~isscalar(mesh)
    % Stop early because face-normal computation depends on one well-defined mesh.
    error('selectProbeFacingIntersectionSegments:InvalidMeshStruct', ...
        'mesh must be a scalar struct.');
end

% Check that mesh exposes both vertices and faces because normals need both arrays.
if ~all(isfield(mesh, {'V', 'F'}))
    % Stop early because missing geometry fields would make face normals undefined.
    error('selectProbeFacingIntersectionSegments:InvalidMeshFields', ...
        'mesh must contain fields V and F.');
end

% Check that the 3D segment container is a cell array because each segment lives in one cell.
if ~iscell(segments3D)
    % Stop early because downstream indexing assumes cell-array segments.
    error('selectProbeFacingIntersectionSegments:InvalidSegments3D', ...
        'segments3D must be a cell array.');
end

% Check that the UV segment container is a cell array for the same reason.
if ~iscell(segmentsUV)
    % Stop early because downstream indexing assumes cell-array segments.
    error('selectProbeFacingIntersectionSegments:InvalidSegmentsUV', ...
        'segmentsUV must be a cell array.');
end

% Check that the face-index list is numeric and vector-shaped so each segment can map to one face.
if ~isnumeric(segmentFaceIdx) || ~isvector(segmentFaceIdx)
    % Stop early because one face id per segment is required for probe-facing selection.
    error('selectProbeFacingIntersectionSegments:InvalidSegmentFaceIdx', ...
        'segmentFaceIdx must be a numeric vector aligned with the segment outputs.');
end

% Check that plane is a scalar struct with ey because the facing test uses that direction.
if ~isstruct(plane) || ~isscalar(plane) || ~isfield(plane, 'ey')
    % Stop early because the probe-facing direction comes from plane.ey.
    error('selectProbeFacingIntersectionSegments:InvalidPlaneStruct', ...
        'plane must be a scalar struct that contains field ey.');
end

% Check that pixel spacing is valid because pixel rasterization depends on positive spacing.
if ~isnumeric(du) || ~isscalar(du) || ~isfinite(du) || du <= 0 || ...
   ~isnumeric(dv) || ~isscalar(dv) || ~isfinite(dv) || dv <= 0
    % Stop early because UV-to-pixel conversion would be unstable otherwise.
    error('selectProbeFacingIntersectionSegments:InvalidPixelSpacing', ...
        'du and dv must be finite positive scalars.');
end

% Check that the image size is valid because pixel clamping depends on positive bounds.
if ~isnumeric(nRows) || ~isscalar(nRows) || ~isfinite(nRows) || nRows < 1 || mod(nRows, 1) ~= 0 || ...
   ~isnumeric(nCols) || ~isscalar(nCols) || ~isfinite(nCols) || nCols < 1 || mod(nCols, 1) ~= 0
    % Stop early because rasterization needs valid image bounds.
    error('selectProbeFacingIntersectionSegments:InvalidImageSize', ...
        'nRows and nCols must be finite positive integers.');
end

% Check that the angular tolerance is a finite non-negative scalar.
if ~isnumeric(normalFacingToleranceDeg) || ~isscalar(normalFacingToleranceDeg) || ...
   ~isfinite(normalFacingToleranceDeg) || normalFacingToleranceDeg < 0
    % Stop early because the facing threshold must be easy to interpret.
    error('selectProbeFacingIntersectionSegments:InvalidFacingTolerance', ...
        'normalFacingToleranceDeg must be a finite non-negative scalar.');
end

%% Read Mesh Arrays And Confirm Segment Alignment
% This section pulls out the mesh arrays and checks that all segment-related
% inputs line up with each other.
%
% The idea here is that each returned intersection segment must stay linked
% to exactly one source face. That face link is what lets us ask,
% "Is this segment coming from a face that points toward the probe?"
%
% If the segment lists and face-index list do not match in length or
% validity, then any later face-normal lookup would point to the wrong
% place. So we verify that alignment now, before doing any geometric test.

% Read the mesh arrays into local variables so the later code stays compact.
V = mesh.V;
% Read the face array once for the same reason.
F = mesh.F;

% Check that vertices are finite 3D points because face normals depend on valid coordinates.
if ~isnumeric(V) || size(V, 2) ~= 3 || any(~isfinite(V(:)))
    % Stop early because invalid vertices would corrupt normal computation.
    error('selectProbeFacingIntersectionSegments:InvalidVertices', ...
        'mesh.V must be a finite Nv-by-3 numeric array.');
end

% Check that faces are valid triangle indices because normal computation uses triangle corners.
if ~isnumeric(F) || size(F, 2) ~= 3 || any(~isfinite(F(:))) || any(F(:) < 1) || any(mod(F(:), 1) ~= 0) || any(F(:) > size(V, 1))
    % Stop early because invalid triangle indices would break face lookup.
    error('selectProbeFacingIntersectionSegments:InvalidFaces', ...
        'mesh.F must be a valid Nf-by-3 triangle index array.');
end

% Count the input segments once because multiple output arrays must align to that size.
nSegments = numel(segmentsUV);

% Check that both segment containers have matching length because they describe the same geometry.
if numel(segments3D) ~= nSegments
    % Stop early because one 3D segment must exist for each UV segment.
    error('selectProbeFacingIntersectionSegments:SegmentCountMismatch', ...
        'segments3D and segmentsUV must contain the same number of segments.');
end

% Reshape the face-index vector into a column so indexing stays consistent below.
segmentFaceIdx = segmentFaceIdx(:);

% Check that the face-index vector length matches the number of returned segments.
if numel(segmentFaceIdx) ~= nSegments
    % Stop early because every returned segment must map back to one face id.
    error('selectProbeFacingIntersectionSegments:FaceIndexCountMismatch', ...
        'segmentFaceIdx must contain one face id per returned segment.');
end

% Check that every face id is valid for this mesh because the selector will index into F.
if any(~isfinite(segmentFaceIdx)) || any(mod(segmentFaceIdx, 1) ~= 0) || any(segmentFaceIdx < 1) || any(segmentFaceIdx > size(F, 1))
    % Stop early because invalid face ids would make the face-normal lookup unsafe.
    error('selectProbeFacingIntersectionSegments:InvalidFaceIndices', ...
        'segmentFaceIdx must contain valid integer indices into mesh.F.');
end

%% Return Early When There Is Nothing To Select
% This section handles the empty-input case in one place.
%
% The idea is to return clean, correctly shaped outputs immediately when no
% intersection segments exist. That avoids running the rest of the logic on
% an empty set and also makes the function's behavior easy to predict for
% callers.

% Return empty aligned outputs directly when there are no segments to select.
if nSegments == 0
    % Keep the mask aligned to the empty segment list.
    selectedSegmentMask = false(0, 1);
    % Keep the selected 3D segment output defined.
    selectedSegments3D = cell(0, 1);
    % Keep the selected UV segment output defined.
    selectedSegmentsUV = cell(0, 1);
    % Keep the selected pixel output defined.
    selectedPixels = zeros(0, 2);
    % Keep the score output aligned to the empty segment list.
    segmentFacingScore = zeros(0, 1);
    return;
end

%% Build Probe-Facing Reference Direction And Face Normals
% This section prepares the two things needed for the facing test:
% a normalized target direction from the probe definition, and one
% normalized outward face normal for each mesh triangle.
%
% The idea is that we do not test the raw segments directly. Instead, each
% segment inherits the orientation of the mesh face that created it. By
% turning both directions into unit vectors, their dot product becomes a
% clear "how well do these directions agree?" score.
%
% This section also checks whether the mesh has consistent face orientation.
% That warning matters because a badly oriented mesh can make a front-facing
% test look unreliable even when the math itself is correct.

% Read plane.ey into a column vector so the dot-product code stays explicit.
planeEy = plane.ey(:);

% Check that plane.ey is a finite 3-element vector because it defines the facing direction.
if ~isnumeric(planeEy) || numel(planeEy) ~= 3 || any(~isfinite(planeEy))
    % Stop early because the facing direction must be a valid 3D vector.
    error('selectProbeFacingIntersectionSegments:InvalidPlaneEy', ...
        'plane.ey must be a finite 3-element vector.');
end

% Measure the magnitude of plane.ey so it can be normalized safely.
planeEyNorm = norm(planeEy);

% Reject a zero direction because the probe-facing test would be undefined.
if planeEyNorm == 0
    % Stop early because a zero facing vector cannot define a direction.
    error('selectProbeFacingIntersectionSegments:ZeroPlaneEy', ...
        'plane.ey must have non-zero length.');
end

% Normalize plane.ey so the facing score becomes a cosine-like dot product.
planeEyUnit = planeEy ./ planeEyNorm;
% Define the desired face-normal direction as opposite to plane.ey, per the requested convention.
targetDirection = -planeEyUnit.';

% Compute one outward-oriented unit normal per mesh face for later segment selection.
[faceNormalsUnit, validFaceNormalMask, consistencyFraction] = computeOutwardFaceNormals(V, F);

% Warn when many faces still disagree with the outward-direction check after the global flip.
if consistencyFraction < 0.70
    % Warn because front/back selection may become unreliable when STL winding is inconsistent.
    warning('selectProbeFacingIntersectionSegments:InconsistentFaceOrientation', ...
        ['Only %.1f%% of valid face area agrees with the outward-orientation check after global sign correction. ' ...
         'Probe-facing selection may be unreliable for this mesh.'], ...
        100 * consistencyFraction);
end

%% Score Segments And Keep Only Probe-Facing Ones
% This section is the core selection step.
%
% The idea is:
% 1. Look up the source face of each segment.
% 2. Read that face's outward unit normal.
% 3. Compare it with the desired probe-facing direction using a dot product.
% 4. Keep the segment if the score is inside the requested angular tolerance.
%
% A dot product close to 1 means the face normal points strongly in the
% desired direction. By converting the angle tolerance into a cosine
% threshold, the code can make this decision with one stable numeric
% comparison per segment.

% Start all segment scores at NaN so invalid cases remain easy to diagnose.
segmentFacingScore = NaN(nSegments, 1);
% Start all segment selections as false before evaluating the facing rule.
selectedSegmentMask = false(nSegments, 1);

% Convert the angle threshold into a cosine threshold so the comparison stays stable.
facingCosThreshold = cosd(normalFacingToleranceDeg);

% Loop over every returned segment because each one inherits its source face normal.
for idxSegment = 1:nSegments
    % Read the source face id of the current segment.
    faceIdx = segmentFaceIdx(idxSegment);

    % Skip faces with invalid normals because they cannot define a reliable orientation.
    if ~validFaceNormalMask(faceIdx)
        continue;
    end

    % Read the oriented unit normal of the source face.
    currentFaceNormal = faceNormalsUnit(faceIdx, :);
    % Score how strongly the face normal points against plane.ey.
    currentFacingScore = dot(currentFaceNormal, targetDirection);
    % Store the score so callers can inspect or tune the threshold later.
    segmentFacingScore(idxSegment) = currentFacingScore;
    % Keep the segment when the face normal lies within the requested angular tolerance.
    selectedSegmentMask(idxSegment) = currentFacingScore >= facingCosThreshold;
end

%% Collect Kept Segments And Rasterize Them Back To Pixels
% This section turns the logical selection result into the final outputs
% that the caller wants to use.
%
% The idea is to reuse the mask computed above to extract only the accepted
% 3D and UV segments, then convert the kept UV segments into image pixels.
% In other words, the geometric filtering happens first, and the image-grid
% representation is built only from the surviving segments.

% Keep only the selected 3D segments so the caller can reuse them directly.
selectedSegments3D = segments3D(selectedSegmentMask);
% Keep only the selected UV segments for the same reason.
selectedSegmentsUV = segmentsUV(selectedSegmentMask);
% Rasterize the selected UV segments back onto the image grid to build the pixel output.
selectedPixels = rasterizeSelectedUVSegments(selectedSegmentsUV, du, dv, nRows, nCols);

end

function [faceNormalsUnit, validFaceNormalMask, consistencyFraction] = computeOutwardFaceNormals(V, F)
%COMPUTEOUTWARDFACENORMALS Compute one globally oriented unit normal per mesh face.

%% Build Raw Face Normals From Triangle Geometry
% This section converts each triangle into a raw normal vector.
%
% The idea is to form two triangle edges and take their cross product. That
% cross product gives a direction perpendicular to the face, following the
% triangle vertex order. At this stage the normal length still depends on
% triangle size, so these are not unit normals yet.

% Read the triangle corner coordinates for every face.
faceV1 = V(F(:, 1), :);
% Read the second triangle corner coordinates for every face.
faceV2 = V(F(:, 2), :);
% Read the third triangle corner coordinates for every face.
faceV3 = V(F(:, 3), :);

% Build the first edge vector of every face.
edge12 = faceV2 - faceV1;
% Build the second edge vector of every face.
edge13 = faceV3 - faceV1;
% Compute one raw normal per face using the right-hand rule of the STL winding.
faceNormalsRaw = cross(edge12, edge13, 2);

% Measure each raw normal length because degenerate triangles cannot be normalized safely.
faceNormalLength = sqrt(sum(faceNormalsRaw .^ 2, 2));
% Mark which faces have a usable non-zero normal.
validFaceNormalMask = faceNormalLength > 0;

%% Normalize Valid Normals And Estimate Their Outward Sense
% This section turns usable raw normals into unit normals and then compares
% them with a simple outward reference built from the mesh centroid.
%
% The idea is that a face on the outside of a closed shape usually points
% away from the mesh center. So for each face, we compare the normal
% direction with the vector from the mesh centroid to the face centroid.
% That does not fix every possible mesh problem, but it gives a practical
% way to decide whether the whole set of normals should be flipped.

% Start the unit-normal array at zero so invalid faces stay defined.
faceNormalsUnit = zeros(size(faceNormalsRaw));

% Normalize only the valid raw normals so zero-length faces do not divide by zero.
faceNormalsUnit(validFaceNormalMask, :) = faceNormalsRaw(validFaceNormalMask, :) ./ faceNormalLength(validFaceNormalMask);

% Compute the mesh centroid once as the reference point for outward-direction estimation.
meshCentroid = mean(V, 1);
% Compute one face centroid per triangle so each normal can be compared to its radial direction.
faceCentroids = (faceV1 + faceV2 + faceV3) ./ 3;
% Build the vector from the mesh centroid to each face centroid.
faceRadialVector = faceCentroids - meshCentroid;

% Compute the radial alignment score for every face before any global sign correction.
radialAlignment = sum(faceNormalsUnit .* faceRadialVector, 2);
% Weight faces by triangle area so large surface regions dominate the global flip decision.
faceAreaWeight = 0.5 * faceNormalLength;

% Measure how much valid face area currently points outward.
outwardArea = sum(faceAreaWeight(validFaceNormalMask & radialAlignment >= 0));
% Measure how much valid face area currently points inward.
inwardArea = sum(faceAreaWeight(validFaceNormalMask & radialAlignment < 0));

%% Apply One Global Flip And Report Orientation Consistency
% This section makes a single global orientation choice for the mesh normals
% and then reports how consistent that choice is.
%
% The idea is to avoid flipping faces one by one. Instead, if most valid
% surface area points inward, we flip all valid normals together. That keeps
% the mesh orientation coherent.
%
% After that, we compute how much valid face area agrees with the chosen
% outward direction. This consistency value lets the caller decide whether
% the mesh winding looks reliable enough for probe-facing selection.

% Flip all normals once when the majority of valid face area points inward.
if inwardArea > outwardArea
    faceNormalsUnit(validFaceNormalMask, :) = -faceNormalsUnit(validFaceNormalMask, :);
    radialAlignment = -radialAlignment;
end

% Measure the fraction of valid face area that agrees with the outward check after the global flip.
totalValidArea = sum(faceAreaWeight(validFaceNormalMask));

% Return perfect consistency when there are no valid faces because there is nothing to contradict.
if totalValidArea == 0
    consistencyFraction = 1;
else
    % Compute the post-flip agreeing area fraction so callers can warn about inconsistent winding.
    consistencyFraction = sum(faceAreaWeight(validFaceNormalMask & radialAlignment >= 0)) ./ totalValidArea;
end

end

function selectedPixels = rasterizeSelectedUVSegments(selectedSegmentsUV, du, dv, nRows, nCols)
%RASTERIZESELECTEDUVSEGMENTS Convert kept UV segments into [row, col] image pixels.

%% Rasterize Every Kept UV Segment Into One Shared Pixel Mask
% This section converts all accepted UV segments into image hits on a common
% binary mask.
%
% The idea is to treat the final pixel output as the union of many small
% segment contributions. Each kept segment is checked for valid shape, then
% drawn into the same mask. Using one shared mask makes it easy to avoid
% duplicate pixel coordinates automatically.

% Start an empty mask so each kept segment can mark its hit pixels.
mask = false(nRows, nCols);

% Loop over each kept segment because the selected pixels are the union of all kept segments.
for idxSegment = 1:numel(selectedSegmentsUV)
    % Read the current kept UV segment from the cell array.
    currentSegmentUV = selectedSegmentsUV{idxSegment};

    % Skip empty cells so partially empty selections stay harmless.
    if isempty(currentSegmentUV)
        continue;
    end

    % Check that the current kept segment still has the expected 2-by-2 shape.
    if ~isnumeric(currentSegmentUV) || ~isequal(size(currentSegmentUV), [2, 2]) || any(~isfinite(currentSegmentUV(:)))
        % Stop early because malformed kept geometry would corrupt the pixel output.
        error('selectProbeFacingIntersectionSegments:InvalidSelectedSegmentUV', ...
            'Each selected UV segment must be a finite 2-by-2 numeric array.');
    end

    % Rasterize the current kept UV segment into the shared pixel mask.
    mask = rasterizeSegment(mask, currentSegmentUV(1, :), currentSegmentUV(2, :), du, dv);
end

%% Convert The Binary Mask Into Explicit Pixel Coordinates
% This section changes the internal mask representation into the final list
% of `[row, col]` coordinates.
%
% The idea is that a mask is convenient while drawing, but an explicit list
% of pixel indices is often more convenient for plotting, saving, or later
% processing. So we extract the hit locations at the end.

% Convert the mask into explicit [row, col] coordinates for convenient plotting and storage.
[pixelRows, pixelCols] = find(mask);
% Pack row-column coordinates into the requested output array.
selectedPixels = [pixelRows, pixelCols];

end

function mask = rasterizeSegment(mask, p1, p2, du, dv)
%RASTERIZESEGMENT Mark image pixels intersected by one selected UV segment.

%% Sample One UV Segment Densely And Mark The Covered Pixels
% This section turns one continuous UV line segment into discrete image
% pixels.
%
% The idea is to sample many points along the segment, convert those sample
% positions into row and column indices, clamp them to the image bounds, and
% then mark the touched pixels in the mask.
%
% The oversampling step matters because a segment can be steep, long, or
% cross multiple pixels quickly. Dense sampling reduces the chance of
% leaving visible holes in the rasterized result.

% Read the mask size so the sampled pixels can be clamped to valid bounds.
[nRows, nCols] = size(mask);

% Measure the horizontal span of the segment in pixel units.
nu = abs((p2(1) - p1(1)) / du);
% Measure the vertical span of the segment in pixel units.
nv = abs((p2(2) - p1(2)) / dv);

% Oversample the segment so rasterization stays dense even for steep or long segments.
nSamples = max(2, ceil(4 * max(nu, nv)) + 1);

% Build evenly spaced interpolation parameters from the first endpoint to the second endpoint.
t = linspace(0, 1, nSamples).';
% Sample UV points along the segment without relying on implicit expansion.
samples = bsxfun(@plus, p1, bsxfun(@times, t, (p2 - p1)));

% Convert sampled u coordinates into 1-based image columns.
pixelCols = floor(samples(:, 1) / du) + 1;
% Convert sampled v coordinates into 1-based image rows.
pixelRows = floor(samples(:, 2) / dv) + 1;

% Clamp columns so points on the right edge stay inside the valid image range.
pixelCols = min(max(pixelCols, 1), nCols);
% Clamp rows so points on the bottom edge stay inside the valid image range.
pixelRows = min(max(pixelRows, 1), nRows);

% Convert row-column pairs into linear indices for efficient mask updates.
linearIdx = sub2ind([nRows, nCols], pixelRows, pixelCols);
% Mark every sampled pixel as selected.
mask(linearIdx) = true;

end
