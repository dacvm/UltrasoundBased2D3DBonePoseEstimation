function normalizedFeature = robustNormalizeFeature( ...
        featureImage, sampleMask, percentiles)
%ROBUSTNORMALIZEFEATURE Scale one image feature using candidate percentiles.
% Percentile clipping avoids a few extreme speckle values controlling all
% confidences, while a constant feature becomes neutral evidence rather than
% producing NaN or forcing rejection.
%
% Inputs:
%   featureImage  : Numeric feature image.
%   sampleMask   : Logical coordinates used to estimate the robust range.
%   percentiles   : [lower,upper] percentile values.
%
% Output:
%   normalizedFeature : Image-sized feature in [0,1], zero outside the mask.

maskValues = double(featureImage(sampleMask));
lowerValue = prctile(maskValues, percentiles(1));
upperValue = prctile(maskValues, percentiles(2));
normalizedFeature = zeros(size(featureImage));

if upperValue <= lowerValue + eps(max(abs([lowerValue, upperValue, 1])))
    % A constant feature carries no preference, so use neutral evidence.
    normalizedFeature(sampleMask) = 0.5;
    return;
end

normalizedFeature = (double(featureImage) - lowerValue) / ...
    (upperValue - lowerValue);
normalizedFeature = min(max(normalizedFeature, 0), 1);
normalizedFeature(~sampleMask) = 0;
end
