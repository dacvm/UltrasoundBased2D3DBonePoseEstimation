---
name: comments-storytelling
description: Write or revise code comments so the script reads as a story of logical steps, explaining the reasoning behind each block, with no block left uncommented. Use when writing, reviewing, or commenting MATLAB scripts and functions.
---

# Comments Storytelling

Write comments so that someone reading only the comments understands the whole process, step by step, and why it unfolds in that order.

## Principles

1. **Comment blocks, not lines.** Add one comment above each group of lines that share a single aim. Individual lines inside a commented block do not need their own comment.
2. **Every block gets a comment.** No block of code may be left uncommented, however small or routine it looks. A block is any run of lines serving one purpose, including setup, preallocation, loop bodies, plot formatting, saving, and cleanup.
3. **Explain the reasoning, not the syntax.** Say what the block accomplishes and the logic behind it. Never restate what the code literally does.
4. **Let the comments flow as a narrative.** Each comment should connect to the previous one and lead into the next, using natural transitions ("With the signal cleaned, ...", "Since the peaks are now isolated, ...", "Finally, ...").
5. **Never use label phrases.** Do not write "Why:", "Reason:", "This is needed because", "This is useful for", or similar. Embed the reasoning naturally in the sentence.
6. **Keep it concise.** One to three lines per block. Put `%` comments above the block, not at the end of lines (except for units or short clarifications).

## Blocks that are often missed

Give these the same care as the main logic:

- Variable initialization, constants, and parameter definitions
- Preallocation of arrays before a loop
- Loop bodies and `if`/`switch` branches (each branch deserves its own comment)
- Input validation and error handling
- Plot styling (labels, legends, axes, colors)
- Saving, exporting, and cleanup (`close all`, `clear`, file closing)
- Local functions at the bottom of a file

## Workflow

1. Read the code and identify its distinct stages (load, clean, transform, analyze, plot, save, etc.).
2. Write a short header comment stating the overall goal of the script or function.
3. Add one narrative comment per block so the sequence reads as a story from start to finish.
4. **Coverage check:** scan the file from top to bottom and confirm that every block is preceded by a comment. Any stretch of code with no comment above it must get one.
5. **Story check:** reread only the comments. If they don't tell a coherent story, rewrite the transitions.

## Example 1: Bad vs. good

Bad (restates code, uses label phrases):

```matlab
% Load data
data = readmatrix('signal.csv');
% Remove NaN. Why: NaNs break the filter. Useful for the next step.
data = data(~isnan(data));
% Apply filter
smooth = movmean(data, 5);
```

Good (flows as a story, reasoning embedded):

```matlab
% Estimate the dominant trend of a noisy sensor recording.

% The recording comes from a sensor that occasionally drops samples,
% so we start from the raw file exactly as it was logged.
data = readmatrix('signal.csv');

% Dropped samples appear as NaN and would contaminate every window
% they touch, so they are discarded before any averaging happens.
data = data(~isnan(data));

% With only valid samples left, a short moving average suppresses
% the high-frequency jitter while keeping the slow trend visible.
smooth = movmean(data, 5);
```

## Example 2: Full coverage, including the easily missed blocks

Bad (the main logic is commented, but setup, plotting, and saving are silent):

```matlab
fs = 250;
nTrials = 20;
peakCounts = zeros(1, nTrials);

for k = 1:nTrials
    % Detect peaks in each trial
    ecg = load(sprintf('trial_%02d.mat', k)).ecg;
    peakCounts(k) = numel(findHeartbeats(ecg, fs));
end

figure;
bar(peakCounts);
xlabel('Trial');
ylabel('Beats');
title('Beats per trial');

save('results.mat', 'peakCounts');
```

Good (every block explains its part of the story):

```matlab
% Count heartbeats across all recorded trials and keep the results.

% All trials were recorded at the same rate, so the sampling frequency
% is defined once and shared by every call below.
fs = 250;
nTrials = 20;

% The number of trials is known up front, so the output is allocated
% at its final size instead of growing inside the loop.
peakCounts = zeros(1, nTrials);

% Each trial is processed independently, and its beat count is stored
% at the same index so results stay aligned with trial numbers.
for k = 1:nTrials
    ecg = load(sprintf('trial_%02d.mat', k)).ecg;
    peakCounts(k) = numel(findHeartbeats(ecg, fs));
end

% A bar chart makes trial-to-trial differences easy to spot, and the
% labels let the figure stand on its own in a report.
figure;
bar(peakCounts);
xlabel('Trial');
ylabel('Beats');
title('Beats per trial');

% The counts are saved last so later analyses can reuse them without
% repeating the slow peak detection.
save('results.mat', 'peakCounts');
```

## Example 3: A full MATLAB function

```matlab
function peakTimes = findHeartbeats(ecg, fs)
% Locate heartbeat times in an ECG trace sampled at fs Hz.

% Baseline wander from breathing sits far below the heart rate,
% so a high-pass filter removes it and leaves the beats on a flat line.
[b, a] = butter(2, 0.5 / (fs/2), 'high');
ecg = filtfilt(b, a, ecg);

% The R-peak is the sharpest feature of each beat. Squaring the
% derivative turns it into a tall spike and flattens everything else.
energy = diff(ecg).^2;

% A fixed threshold would fail when amplitude drifts between
% recordings, so it is tied to the signal's own statistics.
threshold = mean(energy) + 3 * std(energy);

% Beats cannot occur faster than roughly 200 per minute, so
% enforcing a minimum gap prevents one beat being counted twice.
minGap = round(0.3 * fs);
[~, locs] = findpeaks(energy, 'MinPeakHeight', threshold, ...
                              'MinPeakDistance', minGap);

% Sample indices are converted to seconds so downstream code
% can work in physical time regardless of the sampling rate.
peakTimes = locs / fs;
end
```