% Demo: parse a Sequence Image (.mha) file and inspect the result.
% This script shows how to call read_sequence_image and how to read outputs.

% Build the sample path (this keeps the demo working even if the current folder changes).
sequencePath = fullfile(pwd, 'data', 'SequenceRecording_2026-02-17_21-19-37.mha');

% Parse the sequence file into a MATLAB struct.
sequence = read_sequence_image(sequencePath);

% Print a quick summary of important header fields.
fprintf('Loaded: %s\n', sequencePath);
fprintf('ObjectType: %s\n', sequence.header.ObjectType);
fprintf('NDims: %d\n', sequence.header.NDims);
fprintf('DimSize: [%d %d %d]\n', sequence.header.DimSize(1), sequence.header.DimSize(2), sequence.header.DimSize(3));
fprintf('ElementDataFile: %s\n', sequence.header.ElementDataFile);
fprintf('Packet count: %d\n\n', numel(sequence.packets));

% Grab the first packet so we can inspect the metadata and optionally display the image.
firstPacket = sequence.packets(1);

% Display the entire packet struct in the Command Window.
disp('First packet metadata:');
disp(firstPacket);

% Only attempt to display the image if it was actually loaded.
% (Dummy example files may not contain a real binary payload.)
if ~isempty(firstPacket.Image)
    % Create a new figure window for the image.
    figure('Name', 'First Packet Image');

    % imagesc expects rows/columns; we transpose to display in a common orientation.
    imagesc(firstPacket.Image.');

    % Make pixels square and use grayscale to match ultrasound brightness images.
    axis image;
    colormap gray;

    % Add a title so the figure is self-explanatory.
    title('First Packet Image');
else
    % If no image bytes were loaded, explain why.
    disp('First packet image is empty (example file uses dummy/placeholder payload).');
end
