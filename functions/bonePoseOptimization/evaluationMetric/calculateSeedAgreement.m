function seedAgreementTable = calculateSeedAgreement(perRunTable, T_bone_ref_estimates)
%CALCULATESEEDAGREEMENT Measure how close the seeds of each combination end up.
% This function compares the final poses of all seeds that share the same
% hyperparameter combination. For every pair of evaluated seeds it measures
% the translation and rotation between their final poses, and it keeps the
% median over all pairs. It is needed to judge repeatability without the
% ground truth: seeds that end close together mean the cost function has
% one clear minimum there, while seeds that scatter mean it does not.
%
% Inputs:
%   perRunTable          - One row per run, after evaluation. Needs the
%                          combinationId and evaluationStatus columns.
%   T_bone_ref_estimates - Cell array with one final 4-by-4 bone-to-reference
%                          transform per perRunTable row (empty for runs
%                          that were not evaluated).
%
% Output:
%   seedAgreementTable   - One row per combination with columns
%                          combinationId, medianSeedPairTranslationMm, and
%                          medianSeedPairRotationDeg. A combination with
%                          fewer than two evaluated seeds has NaN values.

% Keep the combinations in the order they first appear in the run table.
combinationIds       = unique(string(perRunTable.combinationId), 'stable');
numberOfCombinations = numel(combinationIds);

medianSeedPairTranslationMm = nan(numberOfCombinations, 1);
medianSeedPairRotationDeg   = nan(numberOfCombinations, 1);

for combinationIndex = 1:numberOfCombinations

    % Collect the final poses of the evaluated seeds of this combination.
    % Runs that failed or were skipped have no final pose to compare.
    isEvaluatedSeed = string(perRunTable.combinationId) == combinationIds(combinationIndex) & ...
                      perRunTable.evaluationStatus == "evaluated";
    seedPoses = T_bone_ref_estimates(isEvaluatedSeed);

    % Compare every seed with every later seed, so each pair is measured
    % once (5 seeds give 10 pairs). The pose-distance functions are the
    % same ones used for the errors; here one seed's pose plays the role
    % of the reference.
    pairTranslationMm = [];
    pairRotationDeg   = [];
    for firstSeedIndex = 1:numel(seedPoses)
        for secondSeedIndex = (firstSeedIndex + 1):numel(seedPoses)
            pairTranslationMm(end + 1) = calculateTranslationErrorMm(seedPoses{firstSeedIndex}, seedPoses{secondSeedIndex}); %#ok<AGROW>
            pairRotationDeg(end + 1)   = calculateRotationErrorDeg(seedPoses{firstSeedIndex}, seedPoses{secondSeedIndex}); %#ok<AGROW>
        end
    end

    % The median keeps one outlying seed from dominating the result. With
    % fewer than two seeds there are no pairs, and median([]) gives NaN.
    medianSeedPairTranslationMm(combinationIndex) = median(pairTranslationMm);
    medianSeedPairRotationDeg(combinationIndex)   = median(pairRotationDeg);
end

seedAgreementTable = table(combinationIds, medianSeedPairTranslationMm, medianSeedPairRotationDeg, ...
    'VariableNames', {'combinationId', 'medianSeedPairTranslationMm', 'medianSeedPairRotationDeg'});
end
