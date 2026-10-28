function addSurfaceRmseColorbar(ax, style)
%ADDSURFACERMSECOLORBAR Add the shared surface-RMSE colour bar to a figure.
% Every evaluation plot colours combinations by median surface RMSE, so
% every figure gets the same colour bar on the right side of its layout.
%
% Inputs:
%   ax    - Axes inside a tiled layout; its colour limits set the bar range.
%   style - Shared style struct from getEvaluationPlotStyle.
%
% Output:
%   none

% Set the colormap on the whole figure so all panels of a figure share it.
colormap(ancestor(ax, 'figure'), style.colormap);

colorBar = colorbar(ax);
colorBar.Layout.Tile  = 'east';
colorBar.FontSize     = style.fontSize;
colorBar.Label.String = 'Median surface RMSE (mm)';
end
