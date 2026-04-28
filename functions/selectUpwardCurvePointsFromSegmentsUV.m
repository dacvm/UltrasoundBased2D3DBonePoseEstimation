function [orderedCurveUV, tangentUV, upwardMask, selectedUV, selectedPixels] = selectUpwardCurvePointsFromSegmentsUV(segmentsUV, angleIntervalDeg, du, dv, nRows, nCols, varargin)
%SELECTUPWARDCURVEPOINTSFROMSEGMENTSUV Order UV segments, compute tangents, and keep selected points.
%   [ORDEREDCURVEUV, TANGENTUV, UPWARDMASK, SELECTEDUV, SELECTEDPIXELS] = ...
%   SELECTUPWARDCURVEPOINTSFROMSEGMENTSUV(SEGMENTSUV, ANGLEINTERVALDEG, DU, DV, NROWS, NCOLS)
%   merges connected UV segments into ordered curve components, resamples each
%   component, computes a first-derivative tangent at every sampled point, and
%   keeps only the points whose tangent lies within ANGLEINTERVALDEG from the
%   image horizontal axis.
%
%   Inputs:
%       segmentsUV        : cell array where each cell stores one 2-by-2 [u v] segment
%       angleIntervalDeg  : non-negative scalar maximum tangent angle away from horizontal, in degrees
%       du                : physical width of one image pixel
%       dv                : physical height of one image pixel
%       nRows             : number of image rows used for pixel conversion
%       nCols             : number of image columns used for pixel conversion
%
%   Name-value options:
%       'EndpointMergeTol': distance tolerance for merging nearby endpoints
%       'SampleSpacing'   : spacing used when resampling each ordered curve
%       'TangentTol'      : minimum tangent norm accepted as valid
%
%   Outputs:
%       orderedCurveUV : cell array of ordered N-by-2 UV point lists
%       tangentUV      : cell array of N-by-2 tangent vectors
%       upwardMask     : cell array of N-by-1 logical masks for accepted points
%                        kept under the horizontal-angle rule; the legacy
%                        name is kept so older caller code still works
%       selectedUV     : cell array of accepted UV points under the horizontal-angle rule
%       selectedPixels : cell array of accepted [row, col] pixels under the horizontal-angle rule

%% Validate Required Inputs And Optional Settings
% This section protects the rest of the function from bad input data.
% The main idea is to stop early when the input shape, numeric values, or
% image scaling information do not make sense, because every later step
% assumes these basics are already correct.
%
% This section also reads the optional name-value settings in one place.
% That keeps the function call flexible while still making the defaults
% easy to understand and safe to reuse later.

% Check that the caller provided the required number of inputs.
if nargin < 6
    % Stop early because the helper needs image scaling and image size.
    error('selectUpwardCurvePointsFromSegmentsUV:InvalidInputCount', ...
        'The function requires segmentsUV, angleIntervalDeg, du, dv, nRows, and nCols.');
end

% Check that the segment container is a cell array because each segment lives in one cell.
if ~iscell(segmentsUV)
    % Stop early because the downstream code expects cell indexing.
    error('selectUpwardCurvePointsFromSegmentsUV:InvalidSegmentsContainer', ...
        'segmentsUV must be a cell array of 2-by-2 numeric segments.');
end

% Check that the angle interval is a real finite scalar.
if ~isnumeric(angleIntervalDeg) || ~isscalar(angleIntervalDeg) || ~isfinite(angleIntervalDeg) || angleIntervalDeg < 0
    % Stop early because the angle threshold must be a simple non-negative scalar.
    error('selectUpwardCurvePointsFromSegmentsUV:InvalidAngleInterval', ...
        'angleIntervalDeg must be a finite non-negative scalar.');
end

% Check that the pixel size inputs are valid positive scalars.
if ~isnumeric(du) || ~isscalar(du) || ~isfinite(du) || du <= 0 || ...
   ~isnumeric(dv) || ~isscalar(dv) || ~isfinite(dv) || dv <= 0
    % Stop early because pixel conversion depends on positive physical pixel size.
    error('selectUpwardCurvePointsFromSegmentsUV:InvalidPixelSpacing', ...
        'du and dv must be finite positive scalars.');
end

% Check that the image size inputs are valid positive integers.
if ~isnumeric(nRows) || ~isscalar(nRows) || ~isfinite(nRows) || nRows < 1 || mod(nRows, 1) ~= 0 || ...
   ~isnumeric(nCols) || ~isscalar(nCols) || ~isfinite(nCols) || nCols < 1 || mod(nCols, 1) ~= 0
    % Stop early because row-column conversion depends on valid image bounds.
    error('selectUpwardCurvePointsFromSegmentsUV:InvalidImageSize', ...
        'nRows and nCols must be finite positive integers.');
end

% Create an input parser so optional tolerances stay readable at the call site.
parser = inputParser;
% Keep parser behavior strict so misspelled options are caught immediately.
parser.FunctionName = 'selectUpwardCurvePointsFromSegmentsUV';
% Set a merge tolerance tied to pixel scale so nearly equal endpoints merge but separate features stay separate.
addParameter(parser, 'EndpointMergeTol', 0.25 * min(du, dv), ...
    @(value) isnumeric(value) && isscalar(value) && isfinite(value) && value > 0);
% Set the default resampling step to about one pixel so tangent neighborhoods stay stable.
addParameter(parser, 'SampleSpacing', min(du, dv), ...
    @(value) isnumeric(value) && isscalar(value) && isfinite(value) && value > 0);
% Set a small tangent tolerance so zero-length derivatives are rejected safely.
addParameter(parser, 'TangentTol', 1e-9 * max([du, dv, 1]), ...
    @(value) isnumeric(value) && isscalar(value) && isfinite(value) && value > 0);
% Parse the optional name-value inputs now so defaults and overrides are both supported.
parse(parser, varargin{:});

% Read the parsed option values into local variables for simpler code below.
endpointMergeTol = parser.Results.EndpointMergeTol;
% Read the sample spacing once because it is reused by every component.
sampleSpacing = parser.Results.SampleSpacing;
% Read the tangent tolerance once because it is reused by every component.
tangentTol = parser.Results.TangentTol;

%% Prepare Outputs And Handle Empty Cases Early
% This section creates safe default outputs before any heavy work starts.
% The idea is simple: even when the input is empty or collapses into
% nothing useful, the caller should still receive valid empty outputs
% instead of half-defined variables.
%
% Returning early here also keeps the later code focused on the normal
% path, because from that point on we know there is actual geometry to
% process.

% Prepare empty outputs in the requested cell-array shape.
orderedCurveUV = {};
% Prepare empty tangent output so callers still receive a defined variable on empty input.
tangentUV = {};
% Prepare empty upward masks for the same reason.
upwardMask = {};
% Prepare empty selected UV output for the same reason.
selectedUV = {};
% Prepare empty selected pixel output for the same reason.
selectedPixels = {};

% Return early when no UV segments were provided because there is nothing to order or sample.
if isempty(segmentsUV)
    return;
end

%% Convert Segments Into Connected Graph Components
% This section changes the raw segment list into a graph view of the curve.
% Nearby endpoints are merged into shared nodes, duplicate or degenerate
% edges are removed, and the remaining graph is split into connected
% pieces.
%
% The idea behind this step is that ordering is easier on a graph than on
% independent segments. Once segments become nodes and edges, each
% connected component can be followed as one curve instead of many small
% pieces.

% Build a graph representation so connected segments can be ordered into curve components.
[nodeUV, edgeNodePairs] = buildSegmentGraph(segmentsUV, endpointMergeTol);

% Return early when all input segments collapsed into degenerate edges.
if isempty(edgeNodePairs)
    return;
end

% Remove nodes that no longer belong to any edge so isolated leftovers do not create fake components.
[nodeUV, edgeNodePairs] = compactGraphNodes(nodeUV, edgeNodePairs);

% Split the edge graph into connected components so each curve is handled independently.
componentNodeSets = splitNodeComponents(size(nodeUV, 1), edgeNodePairs);

% Prepare one output cell per connected component so the caller can inspect them separately.
nComponents = numel(componentNodeSets);
orderedCurveUV = cell(1, nComponents);
% Match the tangent container size to the curve container size.
tangentUV = cell(1, nComponents);
% Match the upward mask container size to the curve container size.
upwardMask = cell(1, nComponents);
% Match the selected UV container size to the curve container size.
selectedUV = cell(1, nComponents);
% Match the selected pixel container size to the curve container size.
selectedPixels = cell(1, nComponents);

% Define the image horizontal direction once because all tangent angle tests use the same target.
horizontalVector = [1, 0];
% Precompute the cosine threshold once so each point test is cheap and stable.
cosThreshold = cosd(angleIntervalDeg);

%% Order, Resample, And Filter Each Curve Component
% This section processes each connected component one by one.
% For every component, the code first orders the nodes so they follow the
% curve, then resamples the curve so the point spacing is more regular,
% then computes tangents, and finally keeps only the points whose tangent
% direction is close enough to horizontal.
%
% In other words, this is the main "turn segments into usable curve
% points" stage. The outputs stored here are the finished per-component
% results that the caller will use later.

% Loop over each connected component because each curve must be ordered and sampled independently.
for idxComponent = 1:nComponents
    % Read the node list of the current component once for clarity.
    currentNodeIds = componentNodeSets{idxComponent};
    % Keep only the edges whose endpoints both belong to the current component.
    isCurrentEdge = ismember(edgeNodePairs(:, 1), currentNodeIds) & ismember(edgeNodePairs(:, 2), currentNodeIds);
    % Extract the current component edges so the ordering code stays local to this component.
    currentEdgePairs = edgeNodePairs(isCurrentEdge, :);

    % Order the current graph component into a node path that follows the curve.
    [orderedNodeIds, isClosedCurve] = orderComponentNodes(nodeUV, currentEdgePairs);

    % Convert the ordered node ids into their UV coordinates.
    orderedNodesUV = nodeUV(orderedNodeIds, :);

    % Resample the ordered nodes so tangent estimation uses roughly pixel-spaced points.
    sampledCurveUV = resampleCurvePoints(orderedNodesUV, sampleSpacing, isClosedCurve, endpointMergeTol);

    % Compute the point-wise tangent vectors on the sampled curve.
    sampledTangentUV = computeCurveTangents(sampledCurveUV, isClosedCurve);

    % Measure the tangent norm so degenerate derivatives can be rejected safely.
    tangentNorm = hypot(sampledTangentUV(:, 1), sampledTangentUV(:, 2));
    % Mark tangents as valid only when their norm is large enough to trust.
    validTangentMask = tangentNorm > tangentTol;

    % Start with a zero tangent unit vector array so invalid points stay defined.
    tangentUnit = zeros(size(sampledTangentUV));
    % Normalize only the valid tangents so division by very small values never happens.
    tangentUnit(validTangentMask, :) = sampledTangentUV(validTangentMask, :) ./ tangentNorm(validTangentMask);

    % Compare each normalized tangent to the image horizontal direction using a dot product.
    dotToHorizontal = tangentUnit * horizontalVector.';
    % Keep only the valid points whose tangent stays close enough to horizontal in either left or right direction.
    keepMask = validTangentMask & (abs(dotToHorizontal) >= cosThreshold);

    % Store the sampled UV curve for this component.
    orderedCurveUV{idxComponent} = sampledCurveUV;
    % Store the raw tangent vectors for this component.
    tangentUV{idxComponent} = sampledTangentUV;
    % Store the accepted logical mask for this component.
    upwardMask{idxComponent} = keepMask;
    % Store the accepted UV subset for this component.
    selectedUV{idxComponent} = sampledCurveUV(keepMask, :);
    % Convert the accepted UV points into [row, col] pixels for convenient image overlay.
    selectedPixels{idxComponent} = uvPointsToPixels(selectedUV{idxComponent}, du, dv, nRows, nCols);
end

end

%% Graph Construction Helpers
% The helper functions below are responsible for building a clean graph
% from the raw segment list.
% Their job is to merge nearby endpoints, remove unnecessary leftovers,
% and describe the connectivity in a form that later stages can traverse
% reliably.

function [nodeUV, edgeNodePairs] = buildSegmentGraph(segmentsUV, endpointMergeTol)
%BUILDSEGMENTGRAPH Merge nearby endpoints and turn UV segments into graph edges.

% Start with no stored graph nodes because they will be created from segment endpoints.
nodeUV = zeros(0, 2);
% Start with no stored edges because they depend on merged node ids.
edgeNodePairs = zeros(0, 2);

% Loop over every input segment because each segment contributes one graph edge at most.
for idxSegment = 1:numel(segmentsUV)
    % Read the current segment from the cell array.
    currentSegment = segmentsUV{idxSegment};

    % Skip empty cells so partially filled containers do not break the helper.
    if isempty(currentSegment)
        continue;
    end

    % Check that the current segment has the expected 2-by-2 numeric shape.
    if ~isnumeric(currentSegment) || ~isequal(size(currentSegment), [2, 2]) || any(~isfinite(currentSegment(:)))
        % Stop early because malformed segment geometry would corrupt the graph.
        error('selectUpwardCurvePointsFromSegmentsUV:InvalidSegmentShape', ...
            'Each segmentsUV entry must be a finite 2-by-2 numeric [u v] segment.');
    end

    % Merge the first endpoint into the shared node list or create a new node when needed.
    [nodeUV, firstNodeId] = getOrCreateNode(nodeUV, currentSegment(1, :), endpointMergeTol);
    % Merge the second endpoint into the shared node list or create a new node when needed.
    [nodeUV, secondNodeId] = getOrCreateNode(nodeUV, currentSegment(2, :), endpointMergeTol);

    % Skip degenerate edges whose endpoints collapsed onto the same merged node.
    if firstNodeId == secondNodeId
        continue;
    end

    % Store the edge with ascending node ids so duplicate edges can be removed reliably.
    edgeNodePairs(end + 1, :) = sort([firstNodeId, secondNodeId]); %#ok<AGROW>
end

% Remove duplicate edges because neighboring triangles can sometimes contribute the same connection.
if ~isempty(edgeNodePairs)
    % Keep only one copy of every undirected edge pair.
    edgeNodePairs = unique(edgeNodePairs, 'rows', 'stable');
end

end

%% Node Reuse Helper
% This helper decides whether a segment endpoint should reuse an existing
% graph node or create a new one.
% The idea is to treat endpoints that are very close to each other as the
% same physical location, which helps reconnect small gaps caused by
% numeric noise or segmentation detail.

function [nodeUV, nodeId] = getOrCreateNode(nodeUV, pointUV, endpointMergeTol)
%GETORCREATENODE Reuse a nearby node when possible or append a new one.

% Start by assuming that no existing node matches this point yet.
nodeId = [];

% Try to match the point only when nodes already exist.
if ~isempty(nodeUV)
    % Measure the Euclidean distance from this point to every stored node.
    distanceToNodes = hypot(nodeUV(:, 1) - pointUV(1), nodeUV(:, 2) - pointUV(2));
    % Find the nearest stored node because only the closest node can be merged safely.
    [minDistance, nearestNodeId] = min(distanceToNodes);

    % Reuse the nearest node when it lies inside the requested merge tolerance.
    if minDistance <= endpointMergeTol
        nodeId = nearestNodeId;
        return;
    end
end

% Append a new node because no existing node was close enough to reuse.
nodeUV(end + 1, :) = pointUV; %#ok<AGROW>
% Return the id of the newly appended node.
nodeId = size(nodeUV, 1);

end

%% Connected Component Discovery
% This helper finds groups of nodes that are connected to each other.
% The idea is to break one big graph into smaller independent curve
% pieces, because each connected piece can then be ordered and analyzed on
% its own without mixing unrelated geometry.

function componentNodeSets = splitNodeComponents(nNodes, edgeNodePairs)
%SPLITNODECOMPONENTS Group graph nodes into connected components.

% Build an adjacency list once so breadth-first search can expand through the graph.
adjacency = buildAdjacencyList(nNodes, edgeNodePairs);
% Start every node as unvisited so connected-component search can discover it once.
isVisited = false(nNodes, 1);
% Start with no stored components because they will be discovered by the search.
componentNodeSets = {};

% Loop over every node so disconnected groups are all discovered.
for idxNode = 1:nNodes
    % Skip nodes already assigned to an earlier component.
    if isVisited(idxNode)
        continue;
    end

    % Start the queue with the current seed node.
    queue = idxNode;
    % Mark the seed node as visited immediately so it is not enqueued twice.
    isVisited(idxNode) = true;
    % Start the current component with no collected node ids yet.
    currentComponent = zeros(0, 1);

    % Expand through every reachable neighbor until the queue is empty.
    while ~isempty(queue)
        % Pop the first queued node so breadth-first search stays simple and deterministic.
        currentNode = queue(1);
        % Remove the popped node from the queue.
        queue(1) = [];
        % Append the current node to the component node list.
        currentComponent(end + 1, 1) = currentNode; %#ok<AGROW>

        % Read the current node neighbors from the adjacency list.
        neighbors = adjacency{currentNode};
        % Loop over neighbors so all reachable nodes are discovered.
        for idxNeighbor = 1:numel(neighbors)
            % Read the current neighbor id once for clarity.
            neighborNode = neighbors(idxNeighbor);

            % Queue only neighbors that were not visited before.
            if ~isVisited(neighborNode)
                isVisited(neighborNode) = true;
                queue(end + 1) = neighborNode; %#ok<AGROW>
            end
        end
    end

    % Store the finished component node ids.
    componentNodeSets{end + 1} = currentComponent; %#ok<AGROW>
end

end

%% Graph Cleanup And Adjacency Helpers
% These helpers clean the graph and prepare neighbor lookups.
% One helper removes unused node ids so the graph stays compact, and the
% other builds adjacency lists so traversal code can quickly ask "which
% nodes are connected to this one?".

function [compactNodeUV, compactEdgeNodePairs] = compactGraphNodes(nodeUV, edgeNodePairs)
%COMPACTGRAPHNODES Remove unused nodes and remap edges to a compact node range.

% Read the node ids that still appear in at least one non-degenerate edge.
usedNodeIds = unique(edgeNodePairs(:));
% Keep only the coordinates of nodes that still belong to the graph.
compactNodeUV = nodeUV(usedNodeIds, :);
% Create a lookup table from old node ids to new compact node ids.
oldToNewNodeId = zeros(size(nodeUV, 1), 1);
% Fill the lookup table for every used node.
oldToNewNodeId(usedNodeIds) = 1:numel(usedNodeIds);
% Remap every edge endpoint into the compact node-id range.
compactEdgeNodePairs = [oldToNewNodeId(edgeNodePairs(:, 1)), oldToNewNodeId(edgeNodePairs(:, 2))];

end

function adjacency = buildAdjacencyList(nNodes, edgeNodePairs)
%BUILDADJACENCYLIST Build node neighbors for an undirected graph.

% Create one empty neighbor list per node.
adjacency = cell(nNodes, 1);

% Loop over every edge because each edge adds one neighbor to each endpoint.
for idxEdge = 1:size(edgeNodePairs, 1)
    % Read the first node id of the current edge.
    nodeA = edgeNodePairs(idxEdge, 1);
    % Read the second node id of the current edge.
    nodeB = edgeNodePairs(idxEdge, 2);
    % Register nodeB as a neighbor of nodeA.
    adjacency{nodeA}(end + 1) = nodeB; %#ok<AGROW>
    % Register nodeA as a neighbor of nodeB.
    adjacency{nodeB}(end + 1) = nodeA; %#ok<AGROW>
end

end

%% Curve Ordering Helpers
% These helpers turn a connected graph component into an ordered path of
% nodes.
% The main idea is to pick a stable starting point and then walk from node
% to node using local geometry, so the final order follows the shape of
% the curve instead of behaving like an arbitrary graph listing.

function [orderedNodeIds, isClosedCurve] = orderComponentNodes(nodeUV, edgeNodePairs)
%ORDERCOMPONENTNODES Turn one connected graph component into one ordered node path.

% Read the unique node ids that belong to this component.
componentNodeIds = unique(edgeNodePairs(:));
% Build local adjacency for only the current component.
adjacency = buildAdjacencyList(max(componentNodeIds), edgeNodePairs);
% Measure the degree of each component node because degree identifies open ends and loops.
degreePerNode = zeros(size(componentNodeIds));

% Loop over every component node so its degree can be measured from adjacency.
for idxNode = 1:numel(componentNodeIds)
    % Read the current node id once for clarity.
    nodeId = componentNodeIds(idxNode);
    % Count the neighbors attached to this node.
    degreePerNode(idxNode) = numel(adjacency{nodeId});
end

% Find open-end nodes because open curves start and end where degree equals one.
openEndNodeIds = componentNodeIds(degreePerNode == 1);
% Mark the curve as closed only when no open ends exist.
isClosedCurve = isempty(openEndNodeIds);

% Choose the traversal start node using the requested deterministic rules.
if ~isClosedCurve
    % Read the UV positions of the open-end nodes so the leftmost one can be selected.
    openEndUV = nodeUV(openEndNodeIds, :);
    % Pick the open end with the smallest u value to enforce left-to-right traversal.
    [~, localStartIdx] = min(openEndUV(:, 1));
    startNodeId = openEndNodeIds(localStartIdx);
else
    % Read all component UV positions so the leftmost node can be selected.
    componentUV = nodeUV(componentNodeIds, :);
    % Pick the leftmost node as the deterministic loop start.
    [~, localStartIdx] = min(componentUV(:, 1));
    startNodeId = componentNodeIds(localStartIdx);
end

% Start the ordered path with the chosen start node.
orderedNodeIds = startNodeId;
% Start with no previous node because traversal has not moved yet.
previousNodeId = NaN;
% Start from the chosen start node.
currentNodeId = startNodeId;

% Follow neighbors until the path reaches the end of an open curve or closes a loop.
while true
    % Read all neighbors of the current node.
    neighborNodeIds = adjacency{currentNodeId};

    % Exclude the previous node so traversal continues forward instead of stepping back immediately.
    if ~isnan(previousNodeId)
        neighborNodeIds = neighborNodeIds(neighborNodeIds ~= previousNodeId);
    end

    % Stop when no forward neighbor remains because the open curve reached its end.
    if isempty(neighborNodeIds)
        break;
    end

    % Pick the best next node according to geometry so the traversal stays stable at ambiguous nodes.
    nextNodeId = chooseNextNode(nodeUV, currentNodeId, previousNodeId, neighborNodeIds);

    % Stop when a closed loop would add the start node twice.
    if isClosedCurve && nextNodeId == startNodeId
        break;
    end

    % Append the chosen next node to the ordered path.
    orderedNodeIds(end + 1, 1) = nextNodeId; %#ok<AGROW>
    % Advance the previous-node tracker to the current node.
    previousNodeId = currentNodeId;
    % Advance the current node tracker to the chosen next node.
    currentNodeId = nextNodeId;
end

% Flip open curves when the final path still runs right-to-left after traversal.
if ~isClosedCurve && nodeUV(orderedNodeIds(1), 1) > nodeUV(orderedNodeIds(end), 1)
    orderedNodeIds = flipud(orderedNodeIds);
end

% Flip closed loops when their signed area is clockwise because the requested rule is counterclockwise.
if isClosedCurve
    % Read the ordered loop coordinates so signed area can be computed.
    loopUV = nodeUV(orderedNodeIds, :);
    % Compute the polygon signed area using the shoelace formula without duplicating the first point.
    signedArea = 0.5 * sum(loopUV(:, 1) .* loopUV([2:end, 1], 2) - loopUV([2:end, 1], 1) .* loopUV(:, 2));

    % Reverse the loop order when the signed area is negative, which means clockwise traversal.
    if signedArea < 0
        orderedNodeIds = flipud(orderedNodeIds);
    end
end

end

function nextNodeId = chooseNextNode(nodeUV, currentNodeId, previousNodeId, neighborNodeIds)
%CHOOSENEXTNODE Pick the next graph node using a simple geometric rule.

% When there is only one candidate, choose it directly because there is no ambiguity.
if numel(neighborNodeIds) == 1
    nextNodeId = neighborNodeIds(1);
    return;
end

% Read the current node position because every direction vector starts here.
currentPoint = nodeUV(currentNodeId, :);
% Build candidate direction vectors from the current node to each neighbor.
candidateDirections = nodeUV(neighborNodeIds, :) - currentPoint;
% Measure the norm of each candidate direction so unit vectors can be formed safely.
candidateNorm = hypot(candidateDirections(:, 1), candidateDirections(:, 2));

% When traversal just started, prefer the neighbor with the largest positive u direction.
if isnan(previousNodeId)
    % Score candidates by their u direction first because open curves should move left-to-right.
    score = candidateDirections(:, 1);
    % Break ties by preferring the more upward direction.
    score = score - 1e-6 * candidateDirections(:, 2);
    [~, bestIdx] = max(score);
    nextNodeId = neighborNodeIds(bestIdx);
    return;
end

% Read the previous node position because the incoming direction depends on it.
previousPoint = nodeUV(previousNodeId, :);
% Build the incoming direction vector from the previous node to the current node.
incomingDirection = currentPoint - previousPoint;
% Measure the incoming direction norm once.
incomingNorm = hypot(incomingDirection(1), incomingDirection(2));

% Fall back to the first candidate when the incoming edge is numerically degenerate.
if incomingNorm == 0
    nextNodeId = neighborNodeIds(1);
    return;
end

% Normalize the incoming direction so the angle comparison depends only on direction.
incomingUnit = incomingDirection ./ incomingNorm;
% Start the alignment score at negative infinity so any real candidate wins.
bestScore = -inf;
% Start with the first candidate as a valid default.
bestIdx = 1;

% Loop over every candidate so the most forward continuation can be selected.
for idxCandidate = 1:numel(neighborNodeIds)
    % Skip zero-length candidate directions because they do not define a useful continuation.
    if candidateNorm(idxCandidate) == 0
        continue;
    end

    % Normalize the candidate direction so the score becomes a cosine similarity.
    candidateUnit = candidateDirections(idxCandidate, :) ./ candidateNorm(idxCandidate);
    % Score the candidate by how well it continues the incoming direction.
    score = dot(candidateUnit, incomingUnit);

    % Keep the candidate when it is more aligned than all previous ones.
    if score > bestScore
        bestScore = score;
        bestIdx = idxCandidate;
    end
end

% Return the best-scoring continuation node.
nextNodeId = neighborNodeIds(bestIdx);

end

%% Curve Resampling Helper
% This helper replaces uneven node spacing with a more regular sampling
% along the curve length.
% The idea is that tangent estimation becomes more stable when neighboring
% points are spaced more evenly, especially when the original segment
% lengths vary a lot from one part of the curve to another.

function sampledCurveUV = resampleCurvePoints(orderedNodesUV, sampleSpacing, isClosedCurve, duplicateTol)
%RESAMPLECURVEPOINTS Interpolate an ordered curve to roughly pixel-spaced samples.

% Remove immediate duplicate points first because they would create zero-length segments.
orderedNodesUV = removeAdjacentDuplicatePoints(orderedNodesUV, duplicateTol);

% Return the remaining nodes directly when fewer than two points survive.
if size(orderedNodesUV, 1) < 2
    sampledCurveUV = orderedNodesUV;
    return;
end

% Append the first point for closed loops so resampling also covers the closing edge.
if isClosedCurve
    resampleNodesUV = [orderedNodesUV; orderedNodesUV(1, :)];
else
    % Reuse the original node list for open curves because they do not wrap around.
    resampleNodesUV = orderedNodesUV;
end

% Measure the distance between consecutive nodes along the resampling path.
stepLength = hypot(diff(resampleNodesUV(:, 1)), diff(resampleNodesUV(:, 2)));
% Build the cumulative arc-length coordinate along the same path.
arcLength = [0; cumsum(stepLength)];
% Read the total curve length once because it drives the resampling grid.
totalLength = arcLength(end);

% Return the original nodes when the total length is effectively zero.
if totalLength <= 0
    sampledCurveUV = orderedNodesUV;
    return;
end

% Build sample positions differently for open curves and closed loops.
if ~isClosedCurve
    % Sample from start to end so open curves include both endpoints.
    samplePositions = (0:sampleSpacing:totalLength).';

    % Append the end position when the regular step missed it.
    if samplePositions(end) < totalLength
        samplePositions(end + 1, 1) = totalLength; %#ok<AGROW>
    end
else
    % Sample a closed loop without duplicating the first point at the end.
    samplePositions = (0:sampleSpacing:totalLength).';

    % Drop the repeated end position when the stepping landed exactly on the perimeter.
    if ~isempty(samplePositions) && abs(samplePositions(end) - totalLength) <= max(sampleSpacing, duplicateTol)
        samplePositions(end) = [];
    end

    % Guarantee at least three samples so a closed loop still has usable tangent neighborhoods.
    if numel(samplePositions) < 3
        samplePositions = linspace(0, totalLength, 3 + (totalLength > 0)).';
        samplePositions(end) = [];
    end
end

% Interpolate the u coordinate along arc length.
sampledU = interp1(arcLength, resampleNodesUV(:, 1), samplePositions, 'linear');
% Interpolate the v coordinate along arc length.
sampledV = interp1(arcLength, resampleNodesUV(:, 2), samplePositions, 'linear');
% Pack the interpolated coordinates into one N-by-2 array.
sampledCurveUV = [sampledU, sampledV];

% Remove any adjacent duplicates introduced by interpolation and rounding noise.
sampledCurveUV = removeAdjacentDuplicatePoints(sampledCurveUV, duplicateTol);

end

%% Tangent Estimation Helper
% This helper computes a direction vector at each sampled curve point.
% The idea is to use nearby points to estimate the local curve direction,
% because the tangent tells us whether that part of the curve is aligned
% with the allowed angle range.

function tangentUV = computeCurveTangents(curveUV, isClosedCurve)
%COMPUTECURVETANGENTS Compute a first-derivative tangent at each sampled point.

% Read the number of sampled points once because the derivative logic branches on it.
nPoints = size(curveUV, 1);
% Start with zero tangents so every row stays defined even in short curves.
tangentUV = zeros(nPoints, 2);

% Return immediately when there are no points because there is nothing to differentiate.
if nPoints == 0
    return;
end

% Return immediately when there is only one point because a tangent cannot be estimated from one point.
if nPoints == 1
    return;
end

% Use wrap-around centered differences for every point on a closed loop.
if isClosedCurve
    % Loop over every point so each tangent uses its wrapped neighbors.
    for idxPoint = 1:nPoints
        % Read the previous point index with wrap-around to the last point.
        previousIdx = idxPoint - 1;
        if previousIdx < 1
            previousIdx = nPoints;
        end
        % Read the next point index with wrap-around to the first point.
        nextIdx = idxPoint + 1;
        if nextIdx > nPoints
            nextIdx = 1;
        end
        % Use a centered difference so the tangent follows the local curve direction smoothly.
        tangentUV(idxPoint, :) = curveUV(nextIdx, :) - curveUV(previousIdx, :);
    end
    return;
end

% Use a forward difference at the first point because there is no point before it.
tangentUV(1, :) = curveUV(2, :) - curveUV(1, :);
% Use a backward difference at the last point because there is no point after it.
tangentUV(end, :) = curveUV(end, :) - curveUV(end - 1, :);

% Use centered differences for interior points because they are less biased than one-sided differences.
for idxPoint = 2:nPoints - 1
    tangentUV(idxPoint, :) = curveUV(idxPoint + 1, :) - curveUV(idxPoint - 1, :);
end

end

%% Output Coordinate Conversion Helper
% This helper converts accepted UV points into MATLAB image pixel indices.
% The idea is to make the selected points easy to draw or compare against
% image data, while also clamping them so the final row and column values
% always stay inside valid image bounds.

function pixelPoints = uvPointsToPixels(pointsUV, du, dv, nRows, nCols)
%UVPOINTSTOPIXELS Convert UV points into MATLAB-style [row, col] image pixels.

% Return an empty array directly when no points were selected.
if isempty(pointsUV)
    pixelPoints = zeros(0, 2);
    return;
end

% Convert the continuous u coordinates into 1-based image columns.
pixelCols = floor(pointsUV(:, 1) ./ du) + 1;
% Convert the continuous v coordinates into 1-based image rows.
pixelRows = floor(pointsUV(:, 2) ./ dv) + 1;

% Clamp columns so points on the image border stay inside valid bounds.
pixelCols = min(max(pixelCols, 1), nCols);
% Clamp rows so points on the image border stay inside valid bounds.
pixelRows = min(max(pixelRows, 1), nRows);

% Pack row-column pairs together because the caller uses [row, col] convention.
pixelPoints = [pixelRows, pixelCols];
% Remove duplicate pixels so repeated UV samples on the same pixel do not clutter downstream plots.
pixelPoints = unique(pixelPoints, 'rows', 'stable');

end

%% Duplicate Removal Helper
% This helper removes consecutive points that are effectively the same
% location.
% The idea is to prevent tiny repeated steps from creating zero-length
% segments, unstable interpolation, or unreliable tangent directions in
% the later processing stages.

function uniquePoints = removeAdjacentDuplicatePoints(pointsUV, duplicateTol)
%REMOVEADJACENTDUPLICATEPOINTS Drop consecutive points that are too close together.

% Return the input directly when it has zero or one row because duplicates are impossible then.
if size(pointsUV, 1) <= 1
    uniquePoints = pointsUV;
    return;
end

% Keep the first point because it always starts a valid sequence.
keepMask = true(size(pointsUV, 1), 1);
% Measure the distance between consecutive points.
distanceToPrevious = hypot(diff(pointsUV(:, 1)), diff(pointsUV(:, 2)));
% Drop points that are too close to the previous point.
keepMask(2:end) = distanceToPrevious > duplicateTol;
% Keep only the rows marked as distinct enough from their predecessor.
uniquePoints = pointsUV(keepMask, :);

end
