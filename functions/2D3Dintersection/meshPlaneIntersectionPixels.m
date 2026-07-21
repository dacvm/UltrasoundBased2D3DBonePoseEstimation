function [mask, pixelList, segments3D, segmentsUV, segmentFaceIdx] = meshPlaneIntersectionPixels(mesh, plane)
%MESHPLANEINTERSECTIONPIXELS Intersect a triangular mesh with a finite image plane.
%   [MASK, PIXELLIST, SEGMENTS3D, SEGMENTSUV, SEGMENTFACEIDX] = MESHPLANEINTERSECTIONPIXELS(MESH, PLANE)
%   computes the intersection between a triangular 3D mesh and a finite 2D
%   image plane patch embedded in 3D space, then rasterizes the resulting
%   intersection curve into image pixels.
%
%   Input MESH is a struct with fields:
%       V : Nv-by-3 array of mesh vertices
%       F : Nf-by-3 array of triangle indices into V
%
%   Input PLANE is a struct with fields:
%       p0    : 3D position of the top-left corner of the plane
%       ex    : 3D direction of increasing image column
%       ey    : 3D direction of increasing image row
%       n     : plane normal provided explicitly by the caller
%       W     : physical width of the finite plane patch
%       H     : physical height of the finite plane patch
%       nRows : number of image rows
%       nCols : number of image columns
%
%   Outputs:
%       mask           : nRows-by-nCols logical image of intersected pixels
%       pixelList      : K-by-2 list of [row, col] coordinates for true pixels
%       segments3D     : cell array of 2-by-3 triangle-plane intersection segments
%       segmentsUV     : cell array of 2-by-2 clipped plane-coordinate segments
%       segmentFaceIdx : segmentCount-by-1 face index aligned with segments3D and segmentsUV
%
%   Geometric conventions:
%       - p0 is the top-left corner of the finite plane patch
%       - ex points in the direction of increasing column
%       - ey points in the direction of increasing row
%       - n is the plane normal and is provided explicitly as input
%       - Points on the plane satisfy x = p0 + u*ex + v*ey
%       - Valid plane coordinates are 0 <= u <= W and 0 <= v <= H
%
%   Notes:
%       - segments3D stores the raw 3D triangle-plane intersection segments
%         that survive projection and clipping to the finite plane patch
%       - segmentsUV stores the corresponding clipped 2D [u v] segments used
%         for rasterization on the image grid
%       - segmentFaceIdx stores which mesh face produced each returned segment
%
%   Example:
%       % Build a mesh struct.
%       mesh.V = [0 0 0; 10 0 0; 0 10 0; 0 0 10];
%       mesh.F = [1 2 3; 1 2 4; 2 3 4; 3 1 4];
%       %
%       % Build a plane struct.
%       plane.p0 = [0 0 2];
%       plane.ex = [1 0 0];
%       plane.ey = [0 1 0];
%       plane.n = [0 0 1];
%       plane.W = 10;
%       plane.H = 10;
%       plane.nRows = 200;
%       plane.nCols = 200;
%       %
%       % Run the mesh-plane intersection.
%       [mask, pixelList, segments3D, segmentsUV, segmentFaceIdx] = meshPlaneIntersectionPixels(mesh, plane);
%       %
%       % Visualize the pixel mask.
%       figure;
%       imagesc(mask);
%       axis image;
%       colormap(gray);
%       title('Mesh-plane intersection pixels');
%       hold on;
%       %
%       % Overlay each clipped segment in image coordinates.
%       du = plane.W / plane.nCols;
%       dv = plane.H / plane.nRows;
%       for k = 1:numel(segmentsUV)
%           seg = segmentsUV{k};
%           cols = seg(:, 1) ./ du + 1;
%           rows = seg(:, 2) ./ dv + 1;
%           plot(cols, rows, 'r-', 'LineWidth', 1.5);
%       end

%% Validate Inputs And Required Fields
% This first section acts like a safety gate before the geometry work starts.
% The idea is to fail early when the caller gives data in the wrong shape,
% misses required fields, or passes unexpected containers. By checking the
% contract up front, the rest of the function can assume the inputs follow
% the expected mesh-and-plane format instead of repeatedly defending against
% bad data later.

% Check that the caller provided exactly the two required inputs.
if nargin ~= 2
    error('meshPlaneIntersectionPixels:InvalidInputCount', ...
        'The function requires exactly two inputs: mesh and plane.');
end

% Check that mesh is a scalar struct before inspecting its fields.
if ~isstruct(mesh) || ~isscalar(mesh)
    error('meshPlaneIntersectionPixels:InvalidMeshStruct', ...
        'Input mesh must be a scalar struct.');
end

% Check that plane is a scalar struct before inspecting its fields.
if ~isstruct(plane) || ~isscalar(plane)
    error('meshPlaneIntersectionPixels:InvalidPlaneStruct', ...
        'Input plane must be a scalar struct.');
end

% Enforce the exact mesh API so the function stays predictable.
expectedMeshFields = sort({'V', 'F'});
actualMeshFields = sort(fieldnames(mesh));
if ~isequal(actualMeshFields, expectedMeshFields(:))
    error('meshPlaneIntersectionPixels:InvalidMeshFields', ...
        'mesh must contain only the fields V and F.');
end

% Require the core plane fields, but allow callers to include extra fields.
requiredPlaneFields = {'p0', 'ex', 'ey', 'n', 'W', 'H', 'nRows', 'nCols'};

% Read the available plane field names so we can test for the required ones.
actualPlaneFields = fieldnames(plane);

% Check that every required field is present, even if plane has extra fields too.
if ~all(ismember(requiredPlaneFields, actualPlaneFields))
    error('meshPlaneIntersectionPixels:InvalidPlaneFields', ...
        'plane must contain at least p0, ex, ey, n, W, H, nRows, and nCols.');
end

%% Validate Numeric Geometry Data
% After confirming the structs have the right fields, this section checks
% whether the actual numbers inside them make geometric sense. The main idea
% is to make sure vertices, triangle indices, plane vectors, and image sizes
% are all finite, correctly sized, and usable for later indexing and math.
% This keeps the algorithm from reaching a more complicated step with invalid
% numbers and then failing in a harder-to-understand way.

% Read the mesh arrays into local variables for simpler code below.
V = mesh.V;
F = mesh.F;

% Validate that vertices are numeric 3D points.
if ~isnumeric(V) || ~isreal(V) || size(V, 2) ~= 3 || isempty(V) || any(~isfinite(V(:)))
    error('meshPlaneIntersectionPixels:InvalidVertices', ...
        'mesh.V must be a non-empty finite numeric Nv-by-3 array.');
end

% Validate that faces are numeric triangle indices.
if ~isnumeric(F) || ~isreal(F) || size(F, 2) ~= 3 || any(~isfinite(F(:)))
    error('meshPlaneIntersectionPixels:InvalidFaces', ...
        'mesh.F must be a finite numeric Nf-by-3 array of triangle indices.');
end

% Check that each face index is an integer so indexing stays valid.
if any(abs(F(:) - round(F(:))) > 0)
    error('meshPlaneIntersectionPixels:NonIntegerFaces', ...
        'mesh.F must contain integer triangle indices.');
end

% Check that face indices point to existing vertices.
if ~isempty(F) && (any(F(:) < 1) || any(F(:) > size(V, 1)))
    error('meshPlaneIntersectionPixels:FaceIndexOutOfRange', ...
        'mesh.F contains indices outside the valid range of mesh.V.');
end

% Reshape the plane origin into a row vector so later arithmetic is uniform.
p0 = reshape(plane.p0, 1, []);

% Reshape the in-plane x direction into a row vector so later arithmetic is uniform.
ex = reshape(plane.ex, 1, []);

% Reshape the in-plane y direction into a row vector so later arithmetic is uniform.
ey = reshape(plane.ey, 1, []);

% Reshape the provided plane normal into a row vector so later arithmetic is uniform.
n = reshape(plane.n, 1, []);

% Validate that the plane origin is a 3D finite vector.
if ~isnumeric(p0) || ~isreal(p0) || numel(p0) ~= 3 || any(~isfinite(p0))
    error('meshPlaneIntersectionPixels:InvalidPlaneOrigin', ...
        'plane.p0 must be a finite 3-element vector.');
end

% Validate that the column direction is a 3D finite vector.
if ~isnumeric(ex) || ~isreal(ex) || numel(ex) ~= 3 || any(~isfinite(ex))
    error('meshPlaneIntersectionPixels:InvalidPlaneEx', ...
        'plane.ex must be a finite 3-element vector.');
end

% Validate that the row direction is a 3D finite vector.
if ~isnumeric(ey) || ~isreal(ey) || numel(ey) ~= 3 || any(~isfinite(ey))
    error('meshPlaneIntersectionPixels:InvalidPlaneEy', ...
        'plane.ey must be a finite 3-element vector.');
end

% Validate that the plane normal is a 3D finite vector.
if ~isnumeric(n) || ~isreal(n) || numel(n) ~= 3 || any(~isfinite(n))
    error('meshPlaneIntersectionPixels:InvalidPlaneNormal', ...
        'plane.n must be a finite 3-element vector.');
end

% Validate the finite plane width before using it for clipping and rasterization.
if ~isscalar(plane.W) || ~isnumeric(plane.W) || ~isreal(plane.W) || ...
        ~isfinite(plane.W) || plane.W <= 0
    error('meshPlaneIntersectionPixels:InvalidPlaneWidth', ...
        'plane.W must be a positive finite scalar.');
end

% Validate the finite plane height before using it for clipping and rasterization.
if ~isscalar(plane.H) || ~isnumeric(plane.H) || ~isreal(plane.H) || ...
        ~isfinite(plane.H) || plane.H <= 0
    error('meshPlaneIntersectionPixels:InvalidPlaneHeight', ...
        'plane.H must be a positive finite scalar.');
end

% Validate the image row count before building the output mask.
if ~isscalar(plane.nRows) || ~isnumeric(plane.nRows) || ~isreal(plane.nRows) || ...
        ~isfinite(plane.nRows) || plane.nRows <= 0 || plane.nRows ~= round(plane.nRows)
    error('meshPlaneIntersectionPixels:InvalidRowCount', ...
        'plane.nRows must be a positive integer scalar.');
end

% Validate the image column count before building the output mask.
if ~isscalar(plane.nCols) || ~isnumeric(plane.nCols) || ~isreal(plane.nCols) || ...
        ~isfinite(plane.nCols) || plane.nCols <= 0 || plane.nCols ~= round(plane.nCols)
    error('meshPlaneIntersectionPixels:InvalidColumnCount', ...
        'plane.nCols must be a positive integer scalar.');
end

% Copy scalar plane settings into local variables for readability.
W = double(plane.W);
H = double(plane.H);
nRows = double(plane.nRows);
nCols = double(plane.nCols);

%% Prepare Plane Frame And Diagnostic Tolerances
% This section turns the user-provided plane description into a stable local
% working frame. The idea is to normalize the in-plane directions and normal,
% compute tolerances that scale with the mesh size, and emit warnings when
% the plane basis looks suspicious. These warnings do not stop execution, but
% they help explain empty or skewed results when the mesh and plane are not
% described in a fully consistent coordinate frame.

% Measure the mesh size so tolerance scales with the data magnitude.
bboxSize = norm(max(V, [], 1) - min(V, [], 1));

% Build a distance tolerance that stays meaningful for small and large meshes.
tol = 1e-10 * max(bboxSize, 1);

% Compute the length of ex so we can reject a zero direction safely.
exNorm = norm(ex);

% Compute the length of ey so we can reject a zero direction safely.
eyNorm = norm(ey);

% Compute the length of n so we can reject a zero normal safely.
nNorm = norm(n);

% Reject a zero column direction because projection along ex would be undefined.
if exNorm <= tol
    error('meshPlaneIntersectionPixels:ZeroPlaneEx', ...
        'plane.ex must have non-zero length.');
end

% Reject a zero row direction because projection along ey would be undefined.
if eyNorm <= tol
    error('meshPlaneIntersectionPixels:ZeroPlaneEy', ...
        'plane.ey must have non-zero length.');
end

% Reject a zero normal because signed distances to the plane would be undefined.
if nNorm <= tol
    error('meshPlaneIntersectionPixels:ZeroPlaneNormal', ...
        'plane.n must have non-zero length.');
end

% Normalize ex while keeping the user-provided direction.
ex = ex / exNorm;

% Normalize ey while keeping the user-provided direction.
ey = ey / eyNorm;

% Normalize n while keeping the user-provided direction.
n = n / nNorm;

% Measure signed distances for all mesh vertices once so we can detect obvious frame mismatches early.
meshSignedDistances = (V - p0) * n.';

% Store the smallest signed distance so we can see whether any vertex lies on the negative side.
meshMinDistance = min(meshSignedDistances);

% Store the largest signed distance so we can see whether any vertex lies on the positive side.
meshMaxDistance = max(meshSignedDistances);

% Warn when the whole mesh lies on one side of the plane because intersections will be empty.
if meshMinDistance > tol || meshMaxDistance < -tol
    warning('meshPlaneIntersectionPixels:MeshDoesNotStraddlePlane', ...
            ['The mesh vertices do not straddle the plane. ' ...
             'Signed distance range is [%.6f, %.6f], so the intersection may be empty.'], ...
            meshMinDistance, meshMaxDistance);
end

% Use a small dimensionless tolerance for pose-consistency warnings.
poseWarnTol = 1e-6;

% Warn if ex and ey are not close to orthogonal because plane coordinates may skew.
if abs(dot(ex, ey)) > poseWarnTol
    warning('meshPlaneIntersectionPixels:ExEyNotOrthogonal', ...
        'plane.ex and plane.ey are not close to orthogonal; proceeding without orthogonalization.');
end

% Warn if ex is not close to perpendicular to n because signed-distance and projection frames disagree.
if abs(dot(ex, n)) > poseWarnTol
    warning('meshPlaneIntersectionPixels:ExNotPerpendicularToNormal', ...
        'plane.ex is not close to perpendicular to plane.n; proceeding with the provided vectors.');
end

% Warn if ey is not close to perpendicular to n because signed-distance and projection frames disagree.
if abs(dot(ey, n)) > poseWarnTol
    warning('meshPlaneIntersectionPixels:EyNotPerpendicularToNormal', ...
        'plane.ey is not close to perpendicular to plane.n; proceeding with the provided vectors.');
end

% Compare the axis cross-product against n to flag orientation inconsistencies.
crossExEy = cross(ex, ey);

% Measure the cross-product length to detect nearly parallel in-plane directions.
crossExEyNorm = norm(crossExEy);

% Warn if the in-plane axes are nearly parallel because the local plane frame becomes ill-conditioned.
if crossExEyNorm <= poseWarnTol
    warning('meshPlaneIntersectionPixels:PlaneAxesNearlyParallel', ...
        'cross(plane.ex, plane.ey) is very small, so the plane basis is nearly degenerate.');
else
    % Normalize the axis cross-product so it can be compared to the provided normal direction.
    crossExEy = crossExEy / crossExEyNorm;

    % Warn if cross(ex, ey) is not close to n or -n because the handedness or consistency is off.
    if min(norm(crossExEy - n), norm(crossExEy + n)) > 1e-3
        warning('meshPlaneIntersectionPixels:PlaneNormalMismatch', ...
            'Normalized cross(plane.ex, plane.ey) is not close to plane.n or -plane.n.');
    end
end

% Compute the physical pixel width in plane coordinates.
du = W / nCols;

% Compute the physical pixel height in plane coordinates.
dv = H / nRows;

%% Initialize Outputs And Per-Face Bookkeeping
% Before looping through the mesh, this section prepares all containers used
% to collect results. The idea is simple: start with an empty mask, reserve
% space for one possible segment per face, and keep counters that explain
% what happened later if no visible intersection survives clipping.

% Initialize the output mask as all false before collecting segment hits.
mask = false(nRows, nCols);

% Preallocate segment storage to the number of faces for efficient growth control.
segments3D = cell(size(F, 1), 1);

% Preallocate clipped 2D segment storage to the number of faces for efficient growth control.
segmentsUV = cell(size(F, 1), 1);

% Preallocate the source face index storage so each returned segment keeps its parent face id.
segmentFaceIdx = zeros(size(F, 1), 1);

% Track how many valid segments actually survive clipping to the finite plane.
segmentCount = 0;

% Count how many triangles produce a valid 3D segment before finite-plane clipping.
nSegmentsBeforeClipping = 0;

% Count how many projected segments are rejected by rectangle clipping.
nSegmentsRejectedByClip = 0;

%% Intersect Each Triangle, Clip To The Plane Patch, And Rasterize
% This is the core geometric workflow of the function. For each triangle, we
% find where its edges meet the infinite plane, reduce duplicate points,
% choose the two endpoints that represent the triangle-plane cut, project that
% 3D segment into 2D plane coordinates, clip it to the finite image rectangle,
% and finally mark the covered pixels in the mask. In short, this section
% converts "mesh meets plane in 3D" into "which image pixels are touched".

% Loop over each triangle because the requested algorithm works triangle by triangle.
for iFace = 1:size(F, 1)
    % Read the current triangle vertices in 3D.
    tri = V(F(iFace, :), :);

    % Compute signed distances from the triangle vertices to the plane using the provided normal.
    d = (tri - p0) * n.';

    % Snap very small distances to zero to stabilize edge classification near the plane.
    d(abs(d) < tol) = 0;

    % Start with an empty list of candidate intersection points for this triangle.
    candidatePoints = zeros(0, 3);

    % Intersect edge (1,2) against the plane and append any candidate points.
    candidatePoints = collectEdgeIntersections(candidatePoints, tri(1, :), tri(2, :), d(1), d(2));

    % Intersect edge (2,3) against the plane and append any candidate points.
    candidatePoints = collectEdgeIntersections(candidatePoints, tri(2, :), tri(3, :), d(2), d(3));

    % Intersect edge (3,1) against the plane and append any candidate points.
    candidatePoints = collectEdgeIntersections(candidatePoints, tri(3, :), tri(1, :), d(3), d(1));

    % Merge points that are the same within tolerance so shared vertices do not duplicate the segment.
    candidatePoints = uniquePointsTol(candidatePoints, tol);

    % Skip triangles that do not leave at least two unique points on the plane.
    if size(candidatePoints, 1) < 2
        continue;
    end

    % Count this triangle because it produced a valid 3D segment before clipping.
    nSegmentsBeforeClipping = nSegmentsBeforeClipping + 1;

    % Resolve degenerate coplanar cases by keeping the farthest pair as the segment endpoints.
    if size(candidatePoints, 1) > 2
        segment3D = selectFarthestPair(candidatePoints);
    else
        % Keep the normal two-point intersection segment as-is.
        segment3D = candidatePoints(1:2, :);
    end

    % Project the 3D segment endpoints into local plane coordinates using ex and ey.
    segmentUV = [(segment3D - p0) * ex.', (segment3D - p0) * ey.'];

    % Clip the 2D segment to the finite plane rectangle before rasterization.
    [isInsideRect, clippedUV] = clipSegmentToRect(segmentUV(1, :), segmentUV(2, :), W, H);

    % Skip segments that lie completely outside the finite plane patch.
    if ~isInsideRect
        % Count clipped-out segments so empty output is easier to diagnose later.
        nSegmentsRejectedByClip = nSegmentsRejectedByClip + 1;
        continue;
    end

    % Rasterize the clipped segment so every hit pixel is marked in the logical mask.
    mask = rasterizeSegment(mask, clippedUV(1, :), clippedUV(2, :), du, dv);

    % Advance the valid segment counter now that this segment contributes to the outputs.
    segmentCount = segmentCount + 1;

    % Store the raw 3D segment for this contributing triangle-plane intersection.
    segments3D{segmentCount} = segment3D;

    % Store the clipped 2D segment that was actually rasterized on the finite plane.
    segmentsUV{segmentCount} = clippedUV;
    
    % Store which mesh face created the current returned segment.
    segmentFaceIdx(segmentCount) = iFace;
end

%% Finalize Returned Outputs And Empty-Result Warnings
% Once the loop is finished, this section cleans up the outputs so they only
% contain real surviving segments. It also converts the logical mask into an
% explicit list of hit pixels and gives a final warning if nothing survived.
% The purpose is to return tidy outputs and make "why is the result empty?"
% easier to diagnose for the caller.

% Trim unused preallocated cells so outputs only contain valid segments.
segments3D = segments3D(1:segmentCount);

% Trim unused preallocated cells so outputs only contain valid segments.
segmentsUV = segmentsUV(1:segmentCount);

% Trim unused face ids so the face-index output stays aligned with returned segments.
segmentFaceIdx = segmentFaceIdx(1:segmentCount);

% Convert the logical mask into an explicit list of hit [row, col] pixel coordinates.
[hitRows, hitCols] = find(mask);

% Pack row and column coordinates into the requested K-by-2 output array.
pixelList = [hitRows, hitCols];

% Warn with simple counters when nothing survived so the caller can see where the failure happened.
if segmentCount == 0
    % Explain the case where the infinite plane never produced a usable triangle segment.
    if nSegmentsBeforeClipping == 0
        warning('meshPlaneIntersectionPixels:No3DIntersectionSegments', ...
                ['No triangle produced a valid 3D mesh-plane segment before clipping. ' ...
                 'This usually means the mesh and plane do not intersect in the same frame.']);
    else
        % Explain the case where 3D intersections existed but all of them missed the finite plane patch.
        warning('meshPlaneIntersectionPixels:AllSegmentsClippedOut', ...
                ['Triangles with 3D segments before clipping: %d. ' ...
                 'Segments rejected by finite plane clipping: %d.'], ...
                nSegmentsBeforeClipping, nSegmentsRejectedByClip);
    end
end

end

%% Helper: Collect Edge-Plane Intersection Candidates
% This helper looks at one triangle edge at a time and decides whether that
% edge contributes any point to the triangle-plane intersection. The idea is
% to handle the simple edge cases carefully: an endpoint on the plane, the
% whole edge lying on the plane, or a clean crossing between opposite sides.
function points = collectEdgeIntersections(points, a, b, da, db)
%COLLECTEDGEINTERSECTIONS Add plane-intersection candidates from one triangle edge.

% Keep both endpoints when the full edge is coplanar with the plane.
if da == 0 && db == 0
    points = [points; a; b];
    return;
end

% Keep the first endpoint when it lies exactly on the plane.
if da == 0
    points = [points; a];
    return;
end

% Keep the second endpoint when it lies exactly on the plane.
if db == 0
    points = [points; b];
    return;
end

% Interpolate the crossing point when the edge endpoints lie on opposite sides.
if da * db < 0
    % Compute the parametric crossing location along the edge.
    t = da / (da - db);

    % Evaluate the 3D crossing point on the edge.
    p = a + t * (b - a);

    % Append the computed crossing point to the candidate list.
    points = [points; p];
end

end

%% Helper: Merge Duplicate Candidate Points
% Different triangle edges can report the same geometric point, especially
% when a vertex lies exactly on the plane. This helper removes duplicates
% within a tolerance so the main loop can reason about the true unique
% intersection points instead of counting the same location multiple times.
function uniquePoints = uniquePointsTol(points, tol)
%UNIQUEPOINTSTOL Remove duplicate 3D points using a Euclidean tolerance.

% Return an empty list immediately when there are no candidate points.
if isempty(points)
    uniquePoints = zeros(0, 3);
    return;
end

% Seed the unique list with the first point.
uniquePoints = points(1, :);

% Visit the remaining points one by one because the lists are small per triangle.
for iPoint = 2:size(points, 1)
    % Read the current point for comparison against existing unique points.
    currentPoint = points(iPoint, :);

    % Measure distances to every unique point gathered so far.
    distances = sqrt(sum((uniquePoints - currentPoint) .^ 2, 2));

    % Append the point only when it is farther than tol from all unique points.
    if all(distances > tol)
        uniquePoints = [uniquePoints; currentPoint];
    end
end

end

%% Helper: Choose The Longest Valid Segment In Degenerate Cases
% Sometimes a triangle is coplanar or nearly coplanar, so more than two
% candidate points can appear. This helper simplifies that situation by
% keeping the farthest pair, which gives one representative segment spanning
% the full visible extent of those points.
function pair = selectFarthestPair(points)
%SELECTFARTHESTPAIR Choose the farthest two points to resolve degenerate cases.

% Start with the first two points as a valid initial pair.
idxPair = [1, 2];

% Track the best squared distance so we can avoid repeated square roots.
maxDistSq = -inf;

% Compare every point pair because each triangle yields only a few candidates.
for iPoint = 1:size(points, 1) - 1
    % Compare the current point to every later point.
    for jPoint = iPoint + 1:size(points, 1)
        % Compute the squared distance between the candidate pair.
        distSq = sum((points(iPoint, :) - points(jPoint, :)) .^ 2);

        % Keep the pair when it is farther apart than all previous pairs.
        if distSq > maxDistSq
            idxPair = [iPoint, jPoint];
            maxDistSq = distSq;
        end
    end
end

% Return the two selected endpoints as a 2-by-3 segment.
pair = points(idxPair, :);

end

%% Helper: Clip A 2D Segment To The Finite Plane Rectangle
% The triangle may intersect the infinite plane outside the image patch we
% actually care about. This helper trims the projected segment so only the
% part inside the finite [0,W] by [0,H] rectangle remains. If no part stays
% inside, the segment is rejected before rasterization.
function [ok, seg] = clipSegmentToRect(p1, p2, W, H)
%CLIPSEGMENTTORECT Clip a 2D segment to the rectangle [0,W] x [0,H].

% Start with an empty segment so the output is defined even on rejection.
seg = zeros(2, 2);

% Measure the x displacement for Liang-Barsky clipping.
dx = p2(1) - p1(1);

% Measure the y displacement for Liang-Barsky clipping.
dy = p2(2) - p1(2);

% Start with the full parametric segment range.
t0 = 0;

% Start with the full parametric segment range.
t1 = 1;

% Use a small tolerance based on rectangle scale to handle nearly parallel cases robustly.
clipTol = 1e-12 * max([W, H, 1]);

% Clip against the left edge u >= 0.
[ok, t0, t1] = clipTest(-dx, p1(1), t0, t1, clipTol);
if ~ok
    return;
end

% Clip against the right edge u <= W.
[ok, t0, t1] = clipTest(dx, W - p1(1), t0, t1, clipTol);
if ~ok
    return;
end

% Clip against the top edge v >= 0.
[ok, t0, t1] = clipTest(-dy, p1(2), t0, t1, clipTol);
if ~ok
    return;
end

% Clip against the bottom edge v <= H.
[ok, t0, t1] = clipTest(dy, H - p1(2), t0, t1, clipTol);
if ~ok
    return;
end

% Reject if accumulated numerical drift inverted the segment interval.
if t0 > t1 + clipTol
    ok = false;
    return;
end

% Compute the first clipped endpoint.
q1 = p1 + t0 * [dx, dy];

% Compute the second clipped endpoint.
q2 = p1 + t1 * [dx, dy];

% Clamp the first endpoint into the rectangle to clean up tiny numerical overshoots.
q1(1) = min(max(q1(1), 0), W);
q1(2) = min(max(q1(2), 0), H);

% Clamp the second endpoint into the rectangle to clean up tiny numerical overshoots.
q2(1) = min(max(q2(1), 0), W);
q2(2) = min(max(q2(2), 0), H);

% Package the clipped endpoints into the requested 2-by-2 segment output.
seg = [q1; q2];

end

%% Helper: Update Liang-Barsky Clip Parameters
% This small helper performs one boundary test for Liang-Barsky clipping.
% The main idea is to shrink the valid parameter interval of the segment each
% time we compare it against one rectangle edge. If the interval collapses,
% the segment lies outside and should be rejected.
function [ok, t0, t1] = clipTest(p, q, t0, t1, tol)
%CLIPTEST Update Liang-Barsky parameters against one rectangle boundary.

% Assume success unless this boundary proves the segment is outside.
ok = true;

% Handle the parallel case separately because division by p would be unstable.
if abs(p) <= tol
    % Reject only when the parallel segment lies fully outside this boundary.
    if q < -tol
        ok = false;
    end
    return;
end

% Compute the boundary intersection parameter along the segment.
r = q / p;

% Update the entry parameter when the segment enters through this boundary.
if p < 0
    if r > t1 + tol
        ok = false;
    elseif r > t0
        t0 = r;
    end
else
    % Update the exit parameter when the segment leaves through this boundary.
    if r < t0 - tol
        ok = false;
    elseif r < t1
        t1 = r;
    end
end

end

%% Helper: Convert A Clipped Segment Into Hit Pixels
% After a segment is confirmed to lie on the finite plane patch, this helper
% turns it into image pixels. The idea is to sample along the segment densely
% enough, convert those sampled plane coordinates into row-column indices, and
% mark every touched pixel in the logical mask.
function mask = rasterizeSegment(mask, p1, p2, du, dv)
%RASTERIZESEGMENT Mark image pixels intersected by a clipped 2D segment.

% Read the mask size so sampled points can be clamped to valid pixel indices.
[nRows, nCols] = size(mask);

% Estimate the segment span in horizontal pixel units.
nu = abs((p2(1) - p1(1)) / du);

% Estimate the segment span in vertical pixel units.
nv = abs((p2(2) - p1(2)) / dv);

% Oversample the segment so rasterization remains practical and robust.
nSamples = max(2, ceil(4 * max(nu, nv)) + 1);

% Build evenly spaced interpolation parameters along the segment.
t = linspace(0, 1, nSamples).';

% Sample 2D points along the clipped segment without relying on implicit expansion.
samples = bsxfun(@plus, p1, bsxfun(@times, t, (p2 - p1)));

% Convert sampled u coordinates into image columns using the requested mapping.
cols = floor(samples(:, 1) / du) + 1;

% Convert sampled v coordinates into image rows using the requested mapping.
rows = floor(samples(:, 2) / dv) + 1;

% Clamp columns so points on the right border stay inside the valid image range.
cols = min(max(cols, 1), nCols);

% Clamp rows so points on the bottom border stay inside the valid image range.
rows = min(max(rows, 1), nRows);

% Convert row-column pairs into linear indices for efficient mask updates.
linIdx = sub2ind([nRows, nCols], rows, cols);

% Mark every sampled pixel as intersected by the segment.
mask(linIdx) = true;

end

% Example usage:
% mesh.V = [0 0 0; 20 0 0; 0 20 0; 0 0 20];
% mesh.F = [1 2 3; 1 2 4; 2 3 4; 3 1 4];
%
% plane.p0 = [0 0 5];
% plane.ex = [1 0 0];
% plane.ey = [0 1 0];
% plane.n = [0 0 1];
% plane.W = 20;
% plane.H = 20;
% plane.nRows = 256;
% plane.nCols = 256;
%
% [mask, pixelList, segments3D, segmentsUV, segmentFaceIdx] = meshPlaneIntersectionPixels(mesh, plane);
%
% figure;
% imagesc(mask);
% axis image;
% colormap(gray);
% title('Intersection mask');
% hold on;
%
% du = plane.W / plane.nCols;
% dv = plane.H / plane.nRows;
% for k = 1:numel(segmentsUV)
%     seg = segmentsUV{k};
%     cols = seg(:, 1) ./ du + 1;
%     rows = seg(:, 2) ./ dv + 1;
%     plot(cols, rows, 'r-', 'LineWidth', 1.5);
% end
