% Apply a 4x4 rigid transform to N-by-3 points using homogeneous coordinates.
function vertices_out = applyRigidTransform(vertices_in, T)
    % Count points once so homogeneous augmentation is dimensionally correct.
    n_vertices = size(vertices_in, 1);
    % Append a column of ones so matrix multiplication handles translation.
    vertices_h = [vertices_in, ones(n_vertices, 1)];
    % Apply transform and transpose back to N-by-3 layout expected by patch.
    vertices_h_t = (T * vertices_h.').';
    % Drop homogeneous column and keep transformed XYZ only.
    vertices_out = vertices_h_t(:, 1:3);
end