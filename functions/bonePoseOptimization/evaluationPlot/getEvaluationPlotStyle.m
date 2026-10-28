function style = getEvaluationPlotStyle()
%GETEVALUATIONPLOTSTYLE Return the shared look of all evaluation plots.
% Every evaluation plot reads its font sizes, colours, marker size, and
% figure size from this one struct. Keeping these values in one place makes
% the plots look like one set and lets a new plot match them without copying
% numbers from another file.
%
% Inputs:
%   none
%
% Output:
%   style - Scalar struct with these fields:
%           fontSize             - Axes, label, and colour-bar text (points).
%           titleFontSize        - Figure title (points).
%           pointLabelFontSize   - Small text placed next to data points (points).
%           subtitleColor        - RGB colour of the figure subtitle.
%           colormap             - 256-by-3 colormap for median surface RMSE;
%                                  dark blue is a low error, yellow a high error.
%           topMarkerEdgeColor   - RGB outline colour of top-ranked points.
%           legendMarkerColor    - RGB fill of legend markers, which stand
%                                  for points of any colour.
%           iqrLineColor         - RGB colour of the IQR lines.
%           seedPointColor       - RGB colour of individual seed results.
%           missingCellColor     - RGB colour of empty heatmap cells.
%           markerSize           - Seed-dot marker area in the boxplot (points^2).
%           scatterMarkerSize    - Point marker area in the scatter plots (points^2).
%           boxFaceAlpha         - Opacity of the boxplot box faces.
%           figureSizeCm         - Default [width height] of a figure (cm).
%           heatmapPanelHeightCm - Figure height added per heatmap panel row (cm).

% Text sizes: one base size for everything on the axes, a larger title, and
% a smaller size for point labels so they do not cover the data.
style.fontSize           = 11;
style.titleFontSize      = 13;
style.pointLabelFontSize = 9;
style.subtitleColor      = [0.35 0.35 0.35];

% Colour always means median surface RMSE, in every figure, on the same
% parula scale. Shape, not colour, marks the top-ranked combinations.
style.colormap           = parula(256);
style.topMarkerEdgeColor = [0.85 0 0];
style.legendMarkerColor  = [0.60 0.60 0.60];

% Greys are used for everything that only gives context. Missing cells use
% a mid grey, which is neither parula's dark-blue low end nor its yellow
% high end, so an empty cell cannot be mistaken for a value.
style.iqrLineColor     = [0.80 0.80 0.80];
style.seedPointColor   = [0.20 0.20 0.20];
style.missingCellColor = [0.55 0.55 0.55];

% Marks: scatter points are a bit larger than seed dots so the median points
% and their outlines stand out, and boxes are opaque enough to show their
% colour behind the seed dots.
style.markerSize        = 36;
style.scatterMarkerSize = 64;
style.boxFaceAlpha      = 0.7;

% Figure size: the same canvas for every plot; heatmaps grow taller when
% they stack more panel rows.
style.figureSizeCm         = [18 13];
style.heatmapPanelHeightCm = 6;
end
