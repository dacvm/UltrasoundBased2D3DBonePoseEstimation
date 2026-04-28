function se3_mat = twist_to_se3(twist_vec)
    % Converts a 6x1 twist vector [v; w] to a 4x4 se(3) matrix
    v = twist_vec(1:3);
    w = twist_vec(4:6);
    W_hat = [  0,  -w(3),  w(2);
             w(3),    0,  -w(1);
            -w(2),  w(1),    0  ];
    se3_mat = [W_hat, v; 0 0 0 0];
end