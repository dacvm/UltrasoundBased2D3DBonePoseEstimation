function [angles] = findang_groodsuntay_style(RotM1,RotM2,sideofinterest)
%% findang.m searches the angle between the 1st and 2nd rotation matrix.
%% Input: 
% * RotM1: femoral anatomic coordinate system
% * RotM2: tibial anatomic coordinate system
%% Output: 
% * angles: euler angle (-180 - 180 degrees) between the first and second anatomic coordinate system.
%   The first euler angle corresponds to flexion/extension movement, the
%   second to abduction/adduction in TF kinematics and medial/lateral rotation in
%   PF kinematics, and the third corresponds to internal/external rotation
%   in TF kinematics and medial/lateral tilt in PF kinematics.


R =RotM1'* RotM2;

if isequal(sideofinterest,'right')
    % Calculate Euler angles (grood and suntay convention) from the rotation matrix
    theta_flex_ext = atan2(R(2, 3), R(3, 3));
    theta_abd_add = acos(R(1, 3)) - pi/2;
    theta_int_ext = -atan2(R(1, 2), R(1, 1));
    
elseif isequal(sideofinterest,'left')
    % Calculate Euler angles (grood and suntay convention) from the rotation matrix
    theta_flex_ext = atan2(R(2, 3), R(3, 3));
    theta_abd_add = pi/2 - acos(R(1, 3));
    theta_int_ext = atan2(R(1, 2), R(1, 1));
end

% Convert Euler angles from radians to degrees (optional)
theta_flex_ext_deg = rad2deg(theta_flex_ext);
theta_abd_add_deg = rad2deg(theta_abd_add);
theta_int_ext_deg = rad2deg(theta_int_ext);    


angles = [theta_flex_ext_deg theta_abd_add_deg theta_int_ext_deg];
end
