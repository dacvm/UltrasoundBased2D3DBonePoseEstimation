function resultFilePath = getRunResultFilePath(experimentFolder, combinationId, seed)
%GETRUNRESULTFILEPATH Return where one sweep run stores its runResult.mat.
% This function builds the path of the result file of one run (one
% hyperparameter combination with one seed) inside an experiment folder:
%   <experimentFolder>/runs/<combinationId>/seed_<seed>/runResult.mat
%
% Why it is needed:
%   The sweep writes run files in this layout, a resumed sweep looks for
%   them again, and the evaluation script loads them. All three must agree
%   on the layout, so the rule lives here once instead of in three copies.
%
%   Callers should always rebuild the path with this function rather than
%   reuse a path saved in a summary or run file. A saved path is absolute,
%   so it becomes wrong as soon as the experiment folder is copied to
%   another machine or moved to another folder.
%
% Input:
%   experimentFolder - Folder of one experiment, the one that holds
%                      experiment_plan.mat, summary.mat and runs/.
%   combinationId    - Combination name from the experiment plan, for
%                      example "combination_0001" (string or char).
%   seed             - Random seed of the run, for example 2001 (integer).
%
% Output:
%   resultFilePath   - Full path of the run's runResult.mat (char). The
%                      file itself may not exist yet, for example before
%                      the run has been saved.

seedFolderName = sprintf('seed_%d', seed);
resultFilePath = fullfile(experimentFolder, 'runs', char(combinationId), seedFolderName, 'runResult.mat');
end
