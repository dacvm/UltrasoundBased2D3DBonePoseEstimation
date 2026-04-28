function h_surface = display_image3D(ax_handle, image_data, T_image_ref, varargin)
%DISPLAY_IMAGE3D Draw an image packet as a textured plane in 3D space.
% This helper keeps the packet-to-surface logic in one reusable place.
%
% Inputs:
%   ax_handle    : Target axes handle where the image plane will be drawn.
%   image_data   : 2D grayscale image (H x W) or 3D RGB image (H x W x 3).
%   T_image_ref  : 4x4 transform from image frame to reference frame.
%
% Name-value options:
%   'SwapXY'       : true/false. When true, permute image_data as [2,1,3].
%   'PixelSpacing' : [sx sy] spacing in image-plane units per pixel.
%   'PlaneZ'       : Local Z offset of the image plane before transform.
%   'Tag'          : Graphics tag used for find/delete operations.
%   'FaceColor'    : Surface face color mode (default: 'texturemap').
%   'EdgeColor'    : Surface edge color (default: 'none').
%   'Colormap'     : Colormap name or Nx3 matrix applied to target axes.
%   'FaceAlpha'    : Surface alpha value in [0, 1].

    % Define defaults so behavior matches previous inline implementation.
    default_swapxy = true;
    default_pixelspacing = [1, 1];
    default_planez = 0;
    default_tag = 'plot_usimage';
    default_facecolor = 'texturemap';
    default_edgecolor = 'none';
    default_colormap = [];
    default_facealpha = 1;

    % Validate numeric spacing input as a 2-element vector.
    pixelSpacingValidationFcn = @(x) isnumeric(x) && isvector(x) && numel(x) == 2;

    % Parse required and optional inputs for flexible future use.
    p = inputParser;
    addRequired(p, 'ax_handle');
    addRequired(p, 'image_data');
    addRequired(p, 'T_image_ref', @(x) isnumeric(x) && isequal(size(x), [4, 4]));
    addParameter(p, 'SwapXY', default_swapxy, @(x) islogical(x) && isscalar(x));
    addParameter(p, 'PixelSpacing', default_pixelspacing, pixelSpacingValidationFcn);
    addParameter(p, 'PlaneZ', default_planez, @(x) isnumeric(x) && isscalar(x));
    addParameter(p, 'Tag', default_tag, @ischar);
    addParameter(p, 'FaceColor', default_facecolor, @ischar);
    addParameter(p, 'EdgeColor', default_edgecolor);
    addParameter(p, 'Colormap', default_colormap);
    addParameter(p, 'FaceAlpha', default_facealpha, @(x) isnumeric(x) && isscalar(x) && x >= 0 && x <= 1);
    parse(p, ax_handle, image_data, T_image_ref, varargin{:});

    % Read image size before optional axis swapping.
    [H, W, ~] = size(image_data);

    % Swap image axes when packet storage uses [width, height] ordering.
    if p.Results.SwapXY
        % Permute image matrix so rows/columns align with MATLAB display convention.
        displayImage = permute(image_data, [2, 1, 3]);
        % Swap size values so corner math matches the permuted image data.
        [H, W] = deal(W, H);
    else
        % Keep image data unchanged when no axis swap is requested.
        displayImage = image_data;
    end

    % Read per-pixel scale along local image X and local image Y.
    sx = p.Results.PixelSpacing(1);
    sy = p.Results.PixelSpacing(2);

    % Define image-plane corners in homogeneous coordinates before world transform.
    P00 = [0;            0;            p.Results.PlaneZ; 1];
    P10 = [(W - 1) * sx; 0;            p.Results.PlaneZ; 1];
    P11 = [(W - 1) * sx; (H - 1) * sy; p.Results.PlaneZ; 1];
    P01 = [0;            (H - 1) * sy; p.Results.PlaneZ; 1];

    % Transform each local corner point into the reference frame.
    G00 = p.Results.T_image_ref * P00;
    G10 = p.Results.T_image_ref * P10;
    G11 = p.Results.T_image_ref * P11;
    G01 = p.Results.T_image_ref * P01;

    % Arrange transformed points in row/column order expected by surface texture mapping.
    X = [G00(1), G10(1); G01(1), G11(1)];
    Y = [G00(2), G10(2); G01(2), G11(2)];
    Z = [G00(3), G10(3); G01(3), G11(3)];

    % Apply optional colormap to the target axes (useful for grayscale display tuning).
    if ~isempty(p.Results.Colormap)
        colormap(ax_handle, p.Results.Colormap);
    end

    % Draw the image as a textured surface in 3D reference space.
    h_surface = surface(ax_handle, X, Y, Z, ...
        'FaceColor', p.Results.FaceColor, ...
        'CData', displayImage, ...
        'EdgeColor', p.Results.EdgeColor, ...
        'FaceAlpha', p.Results.FaceAlpha, ...
        'Tag', p.Results.Tag);
end
