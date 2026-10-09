function smoothedImages = smoothUltrasoundImages(imagePlanesRef, sigmaMm)
%SMOOTHULTRASOUNDIMAGES Blur every ultrasound image with a Gaussian in mm.
% The bone echo in a B-mode image is a thin bright band, about 1 mm thick.
% An intensity cost that reads the raw image along the predicted bone line
% only "sees" the echo when the line lies exactly on it, so the cost is flat
% everywhere else and the optimizer gets no hint where to move. Blurring the
% image spreads the echo brightness into its surroundings: a line that is
% slightly off the echo still reads part of it, and the brightness grows as
% the line moves closer. sigmaMm sets how far this hint reaches.
%
% Blurring is slow compared with one cost evaluation, and its result does
% not depend on the candidate pose, so it is done once during preparation.
%
% Inputs:
%   imagePlanesRef - Ultrasound plane struct array. Each element provides
%                    image (stored as [column, row], like everywhere in this
%                    pipeline), W and H (physical width and height in mm),
%                    and nCols and nRows (image size in pixels).
%   sigmaMm        - Nonnegative Gaussian standard deviation in mm. Zero
%                    returns the unblurred images.
%
% Output:
%   smoothedImages - 1-by-nPlanes cell array. Cell k holds the blurred image
%                    of plane k as double, in the same [column, row] layout
%                    and intensity units as the original image.

nPlanes        = numel(imagePlanesRef);
smoothedImages = cell(1, nPlanes);

for planeIndex = 1:nPlanes
    plane = imagePlanesRef(planeIndex);
    image = double(plane.image);

    % sigma is given in mm so it means the same thing for every probe depth
    % setting. Pixels are not square, so each image axis gets its own sigma
    % in pixels. The image is stored as [column, row]: its first dimension
    % runs along the image width and its second along the image height.
    pixelWidthMm      = plane.W / plane.nCols;
    pixelHeightMm     = plane.H / plane.nRows;
    sigmaAlongWidthPx  = sigmaMm / pixelWidthMm;
    sigmaAlongHeightPx = sigmaMm / pixelHeightMm;

    smoothedImages{planeIndex} = blurWithGaussian(image, sigmaAlongWidthPx, sigmaAlongHeightPx);
end
end


%%

function blurredImage = blurWithGaussian(image, sigmaDim1Px, sigmaDim2Px)
%BLURWITHGAUSSIAN Separable Gaussian blur that does not darken the borders.
% image is a 2D double array, sigmaDim1Px and sigmaDim2Px are the standard
% deviations in pixels along its first and second dimension, and
% blurredImage has the same size as image.

if sigmaDim1Px == 0 && sigmaDim2Px == 0
    blurredImage = image;
    return;
end

% A 2D Gaussian is the product of two 1D Gaussians, so blurring along one
% dimension and then the other gives the same result as a full 2D kernel,
% and is much faster.
kernelDim1 = gaussianKernel(sigmaDim1Px);   % column vector: blurs along dim 1
kernelDim2 = gaussianKernel(sigmaDim2Px).'; % row vector: blurs along dim 2

% conv2 treats everything outside the image as zero. Near the border, part
% of the kernel then averages over those zeros and the result becomes too
% dark, which would make bone close to the image edge look weaker than it
% is. Blurring an all-ones image with the same kernels measures exactly how
% much of the kernel fell inside the image at every pixel; dividing by it
% turns the border values back into a proper weighted average.
blurredSum    = conv2(conv2(image, kernelDim1, 'same'), kernelDim2, 'same');
insideWeight  = conv2(conv2(ones(size(image)), kernelDim1, 'same'), kernelDim2, 'same');
blurredImage  = blurredSum ./ insideWeight;
end


function kernel = gaussianKernel(sigmaPx)
%GAUSSIANKERNEL Normalized 1D Gaussian kernel as a column vector.
% sigmaPx is the standard deviation in pixels. A zero sigma returns the
% one-tap kernel 1, which leaves that image dimension unchanged.

if sigmaPx == 0
    kernel = 1;
    return;
end

% Three standard deviations on each side hold more than 99.7% of the
% Gaussian, so the cut-off tails do not change the result noticeably.
halfWidthPx = ceil(3 * sigmaPx);
offsetsPx   = (-halfWidthPx:halfWidthPx).';
kernel      = exp(-offsetsPx.^2 / (2 * sigmaPx^2));
kernel      = kernel / sum(kernel);
end
