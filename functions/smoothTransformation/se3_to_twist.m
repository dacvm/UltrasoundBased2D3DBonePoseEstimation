function twist_vec = se3_to_twist(se3_mat)
    % Converts a 4x4 se(3) matrix to a 6x1 twist vector [v; w]
    v = se3_mat(1:3, 4);
    W_hat = se3_mat(1:3, 1:3);
    w = [W_hat(3,2); W_hat(1,3); W_hat(2,1)];
    twist_vec = [v; w];
end