function [T, info] = estimateRBfrom3Points_v2(P)
%ESTIMATERBFROM3POINTS_V2 Build a rigid-body frame from four markers.
%   [T, INFO] = ESTIMATERBFROM3POINTS_V2(P) creates the bone-pin frame used
%   by CT knee preprocessing. Marker 1 supplies the frame origin, markers 2
%   and 3 define its axis directions, and marker 4 is retained as a check.
%
%   Input:
%       P    - 3-by-4 numeric matrix. Each column contains the [x; y; z]
%              position of one marker. The columns must be ordered as
%              origin, x reference, y reference, and additional marker.
%
%   Outputs:
%       T    - 4-by-4 homogeneous transform whose rotation columns contain
%              the local x, y, and z axes and whose translation is marker 1.
%       info - Structure containing the calculated axes, rotation checks,
%              marker geometry diagnostics, and marker 4 in local space.

% Require exactly four finite 3D marker positions because each column has a
% fixed physical role in the bone-pin definition.
if ~isequal(size(P), [3, 4])
    error('estimateRBfrom3Points_v2:InvalidSize', ...
        'Input P must be a 3-by-4 matrix with one marker per column.');
end
if ~isnumeric(P) || ~isreal(P) || any(~isfinite(P(:)))
    error('estimateRBfrom3Points_v2:InvalidValues', ...
        'Input P must contain finite, real numeric marker positions.');
end

% Give each marker a clear name so the following geometry matches the
% marker roles documented in the configuration file.
p1 = P(:, 1);
p2 = P(:, 2);
p3 = P(:, 3);
p4 = P(:, 4);

% Marker 1 is the rigid-body origin in CT coordinates.
t = p1;

% Define the y direction from marker 1 toward marker 3. Coincident markers
% cannot define a direction, so reject that geometry early.
vector_y = p3 - p1;
norm_vector_y = norm(vector_y);
if norm_vector_y < eps
    error('estimateRBfrom3Points_v2:UndefinedYAxis', ...
        'Markers 1 and 3 are too close to define the y-axis.');
end
y_axis = vector_y / norm_vector_y;

% Remove the y component from the marker 1-to-2 vector. The remaining part
% defines an x-axis that is perpendicular to the y-axis.
vector_to_marker_2 = p2 - p1;
vector_x = vector_to_marker_2 ...
    - dot(vector_to_marker_2, y_axis) * y_axis;
norm_vector_x = norm(vector_x);
if norm_vector_x < eps
    error('estimateRBfrom3Points_v2:UndefinedXAxis', ...
        'Marker 2 is too close to the line through markers 1 and 3.');
end
x_axis = vector_x / norm_vector_x;

% Complete a right-handed coordinate system, then normalize the result to
% limit numerical error from the marker measurements.
z_axis = cross(x_axis, y_axis);
norm_vector_z = norm(z_axis);
if norm_vector_z < eps
    error('estimateRBfrom3Points_v2:UndefinedZAxis', ...
        'The calculated x-axis and y-axis are nearly parallel.');
end
z_axis = z_axis / norm_vector_z;

% Recompute x from the normalized y and z axes so all three axes remain as
% close to orthogonal as floating-point calculations allow.
x_axis = cross(y_axis, z_axis);
x_axis = x_axis / norm(x_axis);
R = [x_axis, y_axis, z_axis];

% A negative determinant would describe a reflected frame. Flip z if round-
% off or unexpected input geometry ever produces that invalid handedness.
if det(R) < 0
    z_axis = -z_axis;
    R = [x_axis, y_axis, z_axis];
end

% Store the rotation and marker-1 origin in a homogeneous transformation.
T = eye(4);
T(1:3, 1:3) = R;
T(1:3, 4) = t;

% Return diagnostics that let later processing inspect frame quality without
% repeating the geometric construction.
info = struct();
info.origin = t;
info.x_axis = x_axis;
info.y_axis = y_axis;
info.z_axis = z_axis;
info.det_R = det(R);
info.orthogonality_error = norm(R' * R - eye(3), 'fro');
info.marker2_perpendicular_distance_to_line13 = norm_vector_x;

% Record the closest point on the marker 1-to-3 line for visual or numeric
% checks of how strongly marker 2 defines the x direction.
projection_p2_on_line13 = p1 ...
    + dot(vector_to_marker_2, y_axis) * y_axis;
info.projection_p2_on_line13 = projection_p2_on_line13;

% Express marker 4 in the calculated local frame. It does not define the
% frame, but its expected local position can validate tracking consistency.
p4_homogeneous = [p4; 1];
p4_local = T \ p4_homogeneous;
info.marker4_local_position = p4_local(1:3);
end
