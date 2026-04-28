% Read STL mesh into faces/vertices while supporting common MATLAB stlread return styles.
function [faces, vertices] = readStlMesh(stl_file_path)
    % Try modern single-output stlread first (often returns triangulation in newer MATLAB).
    mesh_data = stlread(stl_file_path);
    % Parse triangulation output directly when available.
    if isa(mesh_data, 'triangulation')
        faces = mesh_data.ConnectivityList;
        vertices = mesh_data.Points;
        return;
    end
    % Parse struct output used by some stlread implementations.
    if isstruct(mesh_data)
        if isfield(mesh_data, 'ConnectivityList') && isfield(mesh_data, 'Points')
            faces = mesh_data.ConnectivityList;
            vertices = mesh_data.Points;
            return;
        end
        if isfield(mesh_data, 'Faces') && isfield(mesh_data, 'Vertices')
            faces = mesh_data.Faces;
            vertices = mesh_data.Vertices;
            return;
        end
        if isfield(mesh_data, 'faces') && isfield(mesh_data, 'vertices')
            faces = mesh_data.faces;
            vertices = mesh_data.vertices;
            return;
        end
    end
    % Fall back to two-output call style used by older/file-exchange stlread versions.
    [faces, vertices] = stlread(stl_file_path);
end