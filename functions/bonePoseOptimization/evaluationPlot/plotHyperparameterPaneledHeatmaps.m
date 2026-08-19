function figureHandle = plotHyperparameterPaneledHeatmaps(perCombinationTable, parameterNames, heatmapSettings)
%PLOTHYPERPARAMETERPANELEDHEATMAPS Show selected parameter interactions.
% This function displays median surface RMSE in one or more heatmap panels.
% The user chooses which parameters control the heatmap axes, which parameters
% create panel rows and columns, and which remaining parameters are held at
% selected values for this figure.
% This explicit choice keeps higher-dimensional experiments understandable.
%
% Inputs:
%   perCombinationTable - One evaluated row per parameter combination.
%   parameterNames      - Ordered cell array of swept parameter names from
%                         the saved experiment plan.
%   heatmapSettings     - Scalar struct containing xParameter, yParameter,
%                         panelRowParameter, panelColumnParameter, and
%                         parametersToHold.
%
% Output:
%   figureHandle        - Handle to the created MATLAB figure.

%% READ AND CHECK THE DISPLAY SETTINGS

% Validate only the choices needed to prevent a misleading heatmap. The
% experiment-planning and aggregation code already validate the table schema.
validateHeatmapSettings(parameterNames, heatmapSettings);

xParameter           = heatmapSettings.xParameter;
yParameter           = heatmapSettings.yParameter;
panelRowParameter    = heatmapSettings.panelRowParameter;
panelColumnParameter = heatmapSettings.panelColumnParameter;

%% SELECT THE REQUESTED PARAMETER SLICE

% Apply held parameter values before finding axis and panel values. This
% makes the colour range and displayed combinations belong to the same slice.
[plotTable, heldParameterLabel] = selectHeldParameterRows(perCombinationTable, heatmapSettings.parametersToHold);

% Stop when the selected slice has no evaluated accuracy values to display.
finiteRmse = plotTable.medianSurfaceRmseMm(isfinite(plotTable.medianSurfaceRmseMm));
if isempty(finiteRmse)
    error('plotHyperparameterPaneledHeatmaps:NoEvaluatedCombinations', ...
          'The selected parameter slice has no evaluated surface RMSE values.');
end

% Use sorted values so axes and panel positions remain predictable between runs.
xValues = unique(plotTable.(xParameter), 'sorted');
yValues = unique(plotTable.(yParameter), 'sorted');

hasPanelRows    = ~isempty(panelRowParameter);
hasPanelColumns = ~isempty(panelColumnParameter);

% An unused panel direction still needs one layout position for the heatmap.
if hasPanelRows
    panelRowValues = unique(plotTable.(panelRowParameter), 'sorted');
else
    panelRowValues = NaN;
end
if hasPanelColumns
    panelColumnValues = unique(plotTable.(panelColumnParameter), 'sorted');
else
    panelColumnValues = NaN;
end

%% CREATE THE PANEL LAYOUT

% Share one colour range across all panels so equal colours mean equal errors.
colorLimits = [min(finiteRmse), max(finiteRmse)];
if colorLimits(1) == colorLimits(2)
    colorLimits = colorLimits + [-0.5 0.5];
end

figureHandle = figure('Name', 'Hyperparameter Paneled Heatmaps');
layout = tiledlayout(numel(panelRowValues), numel(panelColumnValues), 'TileSpacing', 'compact', 'Padding', 'compact');

for panelRowIndex = 1:numel(panelRowValues)
    for panelColumnIndex = 1:numel(panelColumnValues)

        % Select the full-combination rows belonging to this heatmap panel.
        panelRows = true(height(plotTable), 1);
        if hasPanelRows
            panelRows = panelRows & plotTable.(panelRowParameter) == panelRowValues(panelRowIndex);
        end
        if hasPanelColumns
            panelRows = panelRows & plotTable.(panelColumnParameter) == panelColumnValues(panelColumnIndex);
        end

        % Each matrix position represents one X-and-Y parameter combination.
        heatmapValues = nan(numel(yValues), numel(xValues));
        for xIndex = 1:numel(xValues)
            for yIndex = 1:numel(yValues)
                matchingRows = panelRows & ...
                               plotTable.(xParameter) == xValues(xIndex) & ...
                               plotTable.(yParameter) == yValues(yIndex);

                % Missing combinations remain grey, but duplicate combinations
                % are ambiguous and must not be reduced to an arbitrary row.
                numberOfMatches = nnz(matchingRows);
                if numberOfMatches > 1
                    error('plotHyperparameterPaneledHeatmaps:AmbiguousCell', ...
                          'More than one combination matches one heatmap cell.');
                elseif numberOfMatches == 1
                    matchingIndex = find(matchingRows, 1);
                    heatmapValues(yIndex, xIndex) = plotTable.medianSurfaceRmseMm(matchingIndex);
                end
            end
        end

        % Draw this panel with the same missing-cell and colour rules as every
        % other panel in the figure.
        ax = nexttile(layout);
        imagesc(ax, heatmapValues, 'AlphaData', isfinite(heatmapValues));
        ax.Color = [0.82 0.82 0.82];
        ax.YDir = 'normal';
        clim(ax, colorLimits);
        xticks(ax, 1:numel(xValues));
        xticklabels(ax, string(xValues));
        yticks(ax, 1:numel(yValues));
        yticklabels(ax, string(yValues));
        xlabel(ax, xParameter, 'Interpreter', 'none');
        ylabel(ax, yParameter, 'Interpreter', 'none');

        % Name the panel only with parameter values that actually divide the
        % figure into multiple heatmaps.
        panelTitle = createPanelTitle( ...
            panelRowParameter, panelRowValues(panelRowIndex), ...
            panelColumnParameter, panelColumnValues(panelColumnIndex));
        if ~isempty(panelTitle)
            title(ax, panelTitle, 'Interpreter', 'none');
        end
    end
end

%% FINISH THE SHARED FIGURE LABELS

% Place one colour bar beside the complete panel layout.
colormap(figureHandle, parula);
colorBar = colorbar;
colorBar.Layout.Tile = 'east';
colorBar.Label.String = 'Median surface RMSE (mm)';

% Include held selections in the title so a saved figure explains its slice.
figureTitle = 'Hyperparameter Effects on Surface RMSE';
if ~isempty(heldParameterLabel)
    figureTitle = sprintf('%s | Held: %s', figureTitle, heldParameterLabel);
end
title(layout, figureTitle, 'Interpreter', 'none');
end





function validateHeatmapSettings(parameterNames, heatmapSettings)
%VALIDATEHEATMAPSETTINGS Check how swept parameters are assigned to the plot.
% parameterNames contains all swept parameter names. heatmapSettings contains
% the requested axis, panel, and held roles. This function has no output.

requiredFields = {'xParameter', 'yParameter', 'panelRowParameter', ...
    'panelColumnParameter', 'parametersToHold'};
if ~isstruct(heatmapSettings) || ~isscalar(heatmapSettings) || ~all(isfield(heatmapSettings, requiredFields))
    error('plotHyperparameterPaneledHeatmaps:InvalidSettings', ...
          'heatmapSettings is missing one or more required fields.');
end

% Parameter roles use simple character vectors so they are easy to edit in
% the evaluation script. Empty text is allowed only for panel directions.
roleFields = {'xParameter', 'yParameter', 'panelRowParameter', 'panelColumnParameter'};
for roleIndex = 1:numel(roleFields)
    roleField = roleFields{roleIndex};
    roleValue = heatmapSettings.(roleField);
    if ~ischar(roleValue) || (~isempty(roleValue) && ~isrow(roleValue))
        error('plotHyperparameterPaneledHeatmaps:InvalidSettings', ...
              '%s must be a character row vector.', roleField);
    end
end
if isempty(heatmapSettings.xParameter) || isempty(heatmapSettings.yParameter)
    error('plotHyperparameterPaneledHeatmaps:InvalidSettings', ...
          'xParameter and yParameter must not be empty.');
end
if ~isstruct(heatmapSettings.parametersToHold) || ...
        ~isscalar(heatmapSettings.parametersToHold)
    error('plotHyperparameterPaneledHeatmaps:InvalidSettings', ...
          'parametersToHold must be one scalar struct.');
end

% Combine every displayed and held role before checking it against the
% experiment's authoritative parameter-name list.
assignedParameters = {heatmapSettings.xParameter, heatmapSettings.yParameter};
if ~isempty(heatmapSettings.panelRowParameter)
    assignedParameters{end + 1} = heatmapSettings.panelRowParameter;
end
if ~isempty(heatmapSettings.panelColumnParameter)
    assignedParameters{end + 1} = heatmapSettings.panelColumnParameter;
end
heldParameterNames = fieldnames(heatmapSettings.parametersToHold).';
assignedParameters = [assignedParameters, heldParameterNames];

declaredParameters     = string(parameterNames);
assignedParametersText = string(assignedParameters);
if any(~ismember(assignedParametersText, declaredParameters))
    error('plotHyperparameterPaneledHeatmaps:UnknownParameter', ...
          'Every heatmap parameter must be declared by the experiment plan.');
end
if numel(unique(assignedParametersText, 'stable')) ~= numel(assignedParametersText)
    error('plotHyperparameterPaneledHeatmaps:RepeatedParameter', ...
          'Each swept parameter can have only one heatmap role.');
end

% Require an explicit choice for every parameter so future dimensions cannot
% disappear silently from a two-dimensional plot.
unassignedParameters = setdiff(declaredParameters, assignedParametersText, 'stable');
if ~isempty(unassignedParameters)
    error('plotHyperparameterPaneledHeatmaps:UnassignedParameter', ...
          'Assign every swept parameter to an axis, panel, or held value.');
end
end


function [plotTable, heldParameterLabel] = selectHeldParameterRows( ...
        perCombinationTable, parametersToHold)
%SELECTHELDPARAMETERROWS Keep combinations matching values held for this plot.
% perCombinationTable contains all combinations. parametersToHold maps the
% parameter names not shown by the plot to selected scalar values. plotTable
% contains the retained rows, and heldParameterLabel describes the selection
% for the figure title.

selectedRows = true(height(perCombinationTable), 1);
heldParameterNames = fieldnames(parametersToHold);
labelParts = cell(1, numel(heldParameterNames));

for heldParameterIndex = 1:numel(heldParameterNames)
    parameterName = heldParameterNames{heldParameterIndex};
    parameterValue = parametersToHold.(parameterName);

    % Held selections are numeric scalar values because Stage 4 currently
    % supports numeric scalar sweep parameters.
    if ~isnumeric(parameterValue) || ~isscalar(parameterValue) || ~isfinite(parameterValue)
        error('plotHyperparameterPaneledHeatmaps:InvalidHeldValue', ...
              'The held value for %s must be one finite numeric scalar.', ...
              parameterName);
    end
    if ~any(perCombinationTable.(parameterName) == parameterValue)
        error('plotHyperparameterPaneledHeatmaps:HeldValueNotFound', ...
              'The held value for %s does not exist in the combination table.', ...
              parameterName);
    end

    % Add this held choice to the combined row filter and readable title.
    selectedRows = selectedRows & perCombinationTable.(parameterName) == parameterValue;
    labelParts{heldParameterIndex} = sprintf('%s = %.4g', parameterName, parameterValue);
end

if ~any(selectedRows)
    error('plotHyperparameterPaneledHeatmaps:EmptySlice', ...
          'The selected held parameter values do not occur together.');
end

plotTable = perCombinationTable(selectedRows, :);
heldParameterLabel = strjoin(labelParts, ', ');
end


function panelTitle = createPanelTitle(panelRowParameter, panelRowValue, panelColumnParameter, panelColumnValue)
%CREATEPANELTITLE Describe the parameter values represented by one panel.
% panelRowParameter and panelColumnParameter are optional parameter names.
% panelRowValue and panelColumnValue are their current scalar values.
% panelTitle is readable text for the heatmap panel title.

titleParts = {};
if ~isempty(panelRowParameter)
    titleParts{end + 1} = sprintf('%s = %.4g', panelRowParameter, panelRowValue);
end
if ~isempty(panelColumnParameter)
    titleParts{end + 1} = sprintf('%s = %.4g', panelColumnParameter, panelColumnValue);
end
panelTitle = strjoin(titleParts, ', ');
end
