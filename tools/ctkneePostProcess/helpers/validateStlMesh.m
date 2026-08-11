function validateStlMesh(mesh_object, mesh_path)
% validateStlMesh Check the triangulation shape used by later processing.
%
% This helper verifies that an STL reader returned a finite triangular mesh
% with enough points for sphere fitting and later geometry operations.
%
% Inputs:
%   mesh_object - Mesh object returned by stlread.
%   mesh_path   - Source STL path used in error messages.
%
% Outputs:
%   None.

    % Confirm that the reader returned MATLAB's triangulation type expected by
    % the marker and bone processing sections.
    if ~isa(mesh_object, 'triangulation')
        error('preprocess_markerstls:InvalidStlMesh', ...
            'stlread did not return a triangulation for: %s', mesh_path);
    end

    % Read the two mesh arrays once so the shape and finite-value checks are
    % explicit and easy to inspect.
    mesh_points = mesh_object.Points;
    mesh_connectivity = mesh_object.ConnectivityList;

    % Sphere fitting needs at least four finite 3D samples; bone meshes also
    % easily satisfy this small requirement when they are valid surfaces.
    if ~isnumeric(mesh_points) ...
            || size(mesh_points, 2) ~= 3 ...
            || size(mesh_points, 1) < 4 ...
            || any(~isfinite(mesh_points), 'all') ...
            || ~isnumeric(mesh_connectivity) ...
            || size(mesh_connectivity, 2) ~= 3 ...
            || isempty(mesh_connectivity)
        error('preprocess_markerstls:InvalidStlMesh', ...
            'STL file does not contain a finite triangular 3D mesh: %s', mesh_path);
    end
end
