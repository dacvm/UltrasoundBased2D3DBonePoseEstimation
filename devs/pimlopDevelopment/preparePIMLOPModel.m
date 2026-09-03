function PsiCT = preparePIMLOPModel(boneMeshCT)
%PREPAREPIMLOPMODEL Prepare CT mesh geometry for future P-IMLOP matching.
%   This function computes one area and one unit face normal for every
%   triangle in a CT-frame bone mesh. It also marks degenerate triangles so
%   later PD-tree construction can ignore them safely. Stage 1 prepares only
%   the mesh geometry; the PD-tree field is deliberately left empty.
%
%   Input
%   -----
%   boneMeshCT : MATLAB triangulation containing the bone vertices and
%       triangle connectivity in CT coordinates. Point coordinates are
%       expected in millimetres.
%
%   Output
%   ------
%   PsiCT : Structure describing the complete P-IMLOP model in CT. It has:
%       mesh             - the original CT-frame triangulation;
%       faceNormals      - M-by-3 face unit normals in CT;
%       faceAreas        - M-by-1 triangle areas in square millimetres;
%       validFaceMask    - M-by-1 logical mask for nondegenerate faces;
%       normalConvention - metadata explaining the normal convention;
%       pdTree           - empty in Stage 1, ready for Stage 2.
%
%   Example
%   -------
%       PsiCT = preparePIMLOPModel(data.boneMeshCT);
%       validNormalsCT = PsiCT.faceNormals(PsiCT.validFaceMask, :);

% A triangulation is required because P-IMLOP treats every mesh triangle as
% one model datum. Keeping this check small gives a clear message when the
% wrong model representation is supplied.
if ~isa(boneMeshCT, 'triangulation')
    error('preparePIMLOPModel:InvalidMesh', ...
          'boneMeshCT must be a MATLAB triangulation.');
end

bonePointsCT = double(boneMeshCT.Points);
boneFaces    = boneMeshCT.ConnectivityList;

% Face calculations require finite vertex coordinates. A nonfinite vertex
% would make both its triangle area and normal impossible to interpret.
if any(~isfinite(bonePointsCT), 'all')
    error('preparePIMLOPModel:NonfiniteVertex', ...
          'boneMeshCT contains a vertex with a nonfinite coordinate.');
end

% Gather the three vertices belonging to every triangle. Keeping one row per
% face makes the following cross-product calculation easy to read.
faceVertex1CT = bonePointsCT(boneFaces(:, 1), :);
faceVertex2CT = bonePointsCT(boneFaces(:, 2), :);
faceVertex3CT = bonePointsCT(boneFaces(:, 3), :);

faceEdge12CT = faceVertex2CT - faceVertex1CT;
faceEdge13CT = faceVertex3CT - faceVertex1CT;

% The cross product follows the triangle vertex order. Its length is twice
% the triangle area, and its direction is the corresponding face normal.
unnormalizedFaceNormalsCT = cross(faceEdge12CT, faceEdge13CT, 2);
doubleFaceAreas           = vecnorm(unnormalizedFaceNormalsCT, 2, 2);
faceAreas                 = 0.5 * doubleFaceAreas;

% Use a small tolerance relative to the whole mesh size. This rejects only
% triangles whose area is effectively zero at the scale of this bone.
meshExtentCT          = max(bonePointsCT, [], 1) - min(bonePointsCT, [], 1);
meshDiagonalMm        = norm(meshExtentCT);
minimumFaceAreaMm2    = max(meshDiagonalMm ^ 2, 1) * 1e-12;
hasThreeVertexIndices = boneFaces(:, 1) ~= boneFaces(:, 2) & ...
                        boneFaces(:, 1) ~= boneFaces(:, 3) & ...
                        boneFaces(:, 2) ~= boneFaces(:, 3);
validFaceMask = hasThreeVertexIndices & faceAreas > minimumFaceAreaMm2;

if ~any(validFaceMask)
    error('preparePIMLOPModel:NoValidFaces', ...
          'boneMeshCT does not contain any nondegenerate triangles.');
end

% Invalid faces receive NaN normals so they cannot be mistaken for usable
% P-IMLOP model orientations. Valid normals are normalized row by row.
numberOfFaces = size(boneFaces, 1);
faceNormalsCT = nan(numberOfFaces, 3);
faceNormalsCT(validFaceMask, :) = unnormalizedFaceNormalsCT(validFaceMask, :) ./ doubleFaceAreas(validFaceMask);

% Collect the Stage 1 model values under PsiCT. The normal direction comes
% from the mesh winding, which this project expects to be consistently
% outward for the closed CT bone surface.
PsiCT = struct();
PsiCT.mesh          = boneMeshCT;
PsiCT.faceNormals   = faceNormalsCT;
PsiCT.faceAreas     = faceAreas;
PsiCT.validFaceMask = validFaceMask;

PsiCT.normalConvention = struct();
PsiCT.normalConvention.frame       = 'CT';
PsiCT.normalConvention.association = 'face';
PsiCT.normalConvention.direction   = 'outward';
PsiCT.normalConvention.source      = 'triangle vertex winding';
PsiCT.normalConvention.unitLength  = true;

% Stage 2 will replace this empty value with the spatial search tree. Making
% the field visible now documents the intended final structure of PsiCT.
PsiCT.pdTree = [];
end
