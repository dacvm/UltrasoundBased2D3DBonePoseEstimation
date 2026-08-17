function peakIndex = findFirstPeak(values)
%FINDFIRSTPEAK Find the first local maximum in a one-dimensional response.
% The global maximum is used only when a monotonic or very short response has
% no local maximum, matching the extraction plan's explicit fallback.
%
% Input:
%   values    : Non-empty numeric vector ordered from shallow to deep.
%
% Output:
%   peakIndex : One-based index of the selected peak within values.

values = values(:);
numberOfValues = numel(values);
if numberOfValues == 1
    peakIndex = 1;
    return;
end

if values(1) >= values(2)
    peakIndex = 1;
    return;
end

for valueIndex = 2:(numberOfValues - 1)
    if values(valueIndex) >= values(valueIndex - 1) && ...
            values(valueIndex) > values(valueIndex + 1)
        peakIndex = valueIndex;
        return;
    end
end

if values(end) > values(end - 1)
    peakIndex = numberOfValues;
else
    [~, peakIndex] = max(values);
end
end
