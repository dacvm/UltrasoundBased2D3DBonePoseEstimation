%% Demo 1: split selected frames from a PLUS Sequence Image (.mha) file.
% This section uses an existing sequence file chosen by the user.

% Add this folder to the MATLAB path so the demo can find the helper functions.
addpath(fileparts(mfilename('fullpath')));

% Set this path to the sequence file that you want to split.
% Keeping it as one variable makes the demo easy to reuse with another file.
filepath = 'D:\Documents\BELANDA\SonoSkin\data\dennis_data\2026-13-04_phantom';
filename = 'SequenceRecording_2026-04-13_17-52-51.mha';
sequencePath = fullfile(filepath, filename);

% Choose original MHA frame IDs to split.
% These are zero-based IDs, so [0 2] means Seq_Frame0000 and Seq_Frame0002.
selectedFrameIds = [100 200 300 400];

% Create a new dated output folder for this run.
% This keeps each demo run separate and avoids deleting earlier results.
outputFolder = create_timestamped_demo_folder();

% Split the selected frames into one-frame .mha files.
outputPaths = split_sequence_image_frames(sequencePath, selectedFrameIds, outputFolder);

% Print the files written by the splitter.
fprintf('Source sequence:\n  %s\n\n', sequencePath);
fprintf('Written one-frame files:\n');
for outputIndex = 1:numel(outputPaths)
    fprintf('  %s\n', outputPaths{outputIndex});
end
fprintf('\n');

% Uncomment if you don't need the second demo
return;

%% Demo 2: split selected frames from a PLUS Sequence Image (.mha) file.
% This script creates a tiny synthetic sequence so it can be tested anywhere.

% Create a new dated output folder for this run.
% This keeps synthetic demo files grouped with the output files they created.
outputFolder = create_timestamped_demo_folder();

% Build the path for the synthetic sequence inside the same dated run folder.
% Keeping input and output together makes the demo result easy to inspect.
sequencePath = fullfile(outputFolder, 'DemoSequence.mha');

% Create a small 3-frame test sequence with known image values.
% Frame 0 uses value 11, frame 1 uses value 22, and frame 2 uses value 33.
create_demo_sequence_file(sequencePath);

% Choose original MHA frame IDs to split.
% These are zero-based IDs, so [0 2] means Seq_Frame0000 and Seq_Frame0002.
selectedFrameIds = [0 2];

% Split the selected frames into one-frame .mha files.
outputPaths = split_sequence_image_frames(sequencePath, selectedFrameIds, outputFolder);

% Print the files written by the splitter.
fprintf('Source sequence:\n  %s\n\n', sequencePath);
fprintf('Written one-frame files:\n');
for outputIndex = 1:numel(outputPaths)
    fprintf('  %s\n', outputPaths{outputIndex});
end
fprintf('\n');

% Read each one-frame output back using the existing reader.
% This confirms the new files follow the expected format.
for outputIndex = 1:numel(outputPaths)
    % Parse the output file into the same struct returned for normal sequence files.
    sequence = read_sequence_image(outputPaths{outputIndex});

    % Grab the first and only packet in this one-frame file.
    packet = sequence.packets(1);

    % Print a compact summary that is easy to check in the Command Window.
    fprintf('Output %d summary:\n', outputIndex);
    fprintf('  DimSize: [%d %d %d]\n', sequence.header.DimSize(1), sequence.header.DimSize(2), sequence.header.DimSize(3));
    fprintf('  Timestamp: %.3f\n', packet.Timestamp);
    fprintf('  Unique image value: %d\n\n', unique(packet.Image(:)));
end


%% HELPER: CREATE DEMO SEQUENCE FILE

function create_demo_sequence_file(sequencePath)
%CREATE_DEMO_SEQUENCE_FILE Write a tiny valid uncompressed MET_UCHAR MHA sequence.

    % Use line feed newlines to keep the synthetic header simple and portable.
    nl = newline;

    % Use one simple identity transform for every frame.
    % The reader expects 16 values for transform metadata fields.
    identityTransformText = '1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1';

    % Keep the image tiny so the binary payload is easy to reason about.
    frameWidth = 3;
    frameHeight = 2;
    numberOfFrames = 3;

    % Build the header text exactly like a PLUS local sequence file.
    % ElementDataFile = LOCAL is last because binary image bytes start after it.
    headerText = [ ...
        'ObjectType = Image' nl ...
        'NDims = 3' nl ...
        'BinaryData = True' nl ...
        'BinaryDataByteOrderMSB = False' nl ...
        'CompressedData = False' nl ...
        'Kinds = domain domain list' nl ...
        'TransformMatrix = 1 0 0 0 1 0 0 0 1' nl ...
        sprintf('DimSize = %d %d %d', frameWidth, frameHeight, numberOfFrames) nl ...
        'Offset = 0 0 0' nl ...
        'CenterOfRotation = 0 0 0' nl ...
        'AnatomicalOrientation = RAI' nl ...
        'ElementSpacing = 1 1 1' nl ...
        'ElementType = MET_UCHAR' nl ...
        'UltrasoundImageOrientation = MFA' nl ...
        'UltrasoundImageType = BRIGHTNESS' nl ...
        'Seq_Frame0000_ProbeToTrackerDeviceTransform = ' identityTransformText nl ...
        'Seq_Frame0000_ProbeToTrackerDeviceTransformStatus = OK' nl ...
        'Seq_Frame0000_Timestamp = 0.100' nl ...
        'Seq_Frame0000_ImageStatus = OK' nl ...
        'Seq_Frame0001_ProbeToTrackerDeviceTransform = ' identityTransformText nl ...
        'Seq_Frame0001_ProbeToTrackerDeviceTransformStatus = OK' nl ...
        'Seq_Frame0001_Timestamp = 0.200' nl ...
        'Seq_Frame0001_ImageStatus = OK' nl ...
        'Seq_Frame0002_ProbeToTrackerDeviceTransform = ' identityTransformText nl ...
        'Seq_Frame0002_ProbeToTrackerDeviceTransformStatus = OK' nl ...
        'Seq_Frame0002_Timestamp = 0.300' nl ...
        'Seq_Frame0002_ImageStatus = OK' nl ...
        'ElementDataFile = LOCAL' nl];

    % Build three frame payloads with different values so the split is obvious.
    bytesPerFrame = frameWidth * frameHeight;
    payloadBytes = uint8([ ...
        11 * ones(1, bytesPerFrame), ...
        22 * ones(1, bytesPerFrame), ...
        33 * ones(1, bytesPerFrame)]);

    % Open the synthetic file in binary mode so the payload bytes are unchanged.
    fid = fopen(sequencePath, 'wb');
    if fid < 0
        error('Could not create demo sequence file: %s', sequencePath);
    end

    % Ensure the file handle closes even if a write fails.
    cleanup = onCleanup(@() fclose(fid));

    % Write the ASCII-compatible header first.
    fwrite(fid, uint8(headerText), 'uint8');

    % Write the binary image payload immediately after the header.
    fwrite(fid, payloadBytes, 'uint8');
end


%% HELPER: CREATE DEMO FOLDER WITH TIMESTAMP

function demoFolder = create_timestamped_demo_folder()
%CREATE_TIMESTAMPED_DEMO_FOLDER Create one dated folder for a demo run.

    % Store all runs under one stable parent folder in the system temp directory.
    demoRootFolder = fullfile(pwd, 'split_sequence_image_frames_demo');

    % Keep trying until the current second gives us a folder name that is not used yet.
    % This matters because Demo 1 and Demo 2 can run less than one second apart.
    while true
        % Format the run folder as YYYY-MM-DD_hh-mm-ss using a 24-hour clock.
        timeStampText = char(datetime('now', 'Format', 'yyyy-MM-dd_HH-mm-ss'));

        % Build the final run folder where the sequence files will be written.
        demoFolder = fullfile(demoRootFolder, timeStampText);

        % Create and return the folder once the timestamp is unused.
        if ~isfolder(demoFolder)
            mkdir(demoFolder);
            return;
        end

        % Wait for the next timestamp instead of adding a suffix to the required name format.
        pause(1);
    end
end
