---
name: analyze-hyperparamsweep
description: Analyze the evaluation of one bone-pose hyperparameter sweep experiment and write a findings summary and an interactive local HTML report. Use when the user asks to analyze, interpret, or report on the output of main_bonePoseOptimization_evaluation.m, or invokes /analyze-hyperparamsweep <experimentFolderName>.
---

# Analyze a hyperparameter sweep

Answer three questions about one sweep experiment, backed by numbers:
1. Does the cost function actually align the bone mesh with the ultrasound images?
2. Which hyperparameter values work well, and how sure are we?
3. Where should the next sweep look?

Analyze only the given experiment. Never read or compare with other experiments.

## Inputs
- `experimentFolderName` (required): folder under `output/bonePoseOptimization/experiments/`.
- Focus questions (optional): extra questions from the user, answered in their own section.

## Step 1: Check the inputs exist
In `<experiment>/evaluation/`, these must exist:
- `per_run_evaluation.csv`, `per_combination_evaluation.csv`
- `derived_statistics.csv`
- the figure PNGs (`surfaceRmseBoxplot.png`, `translationRotationErrors.png`,
  `hyperparameterHeatmaps.png`, `optimizerCostVsSurfaceRmse.png`)

If anything is missing, stop and tell the user to run `main_bonePoseOptimization_evaluation.m`.
Do not compute the missing statistics yourself.

## Step 2: Read the context
Read only these files:
- `derived_statistics.csv` first: experiment metadata and the main source for conclusions.
  Columns: `group, statistic, detail, value, unit, definition`.
  - `detail` holds a parameter name, a stop reason, an input role, or a combinationId.
  - Use the `definition` column to understand what each statistic means; don't guess from its name.
- `per_combination_evaluation.csv`: rankings and spread per combination.
- `per_run_evaluation.csv`: only to check specific claims (failures, stop flags, outliers).
- The figure PNGs: to spot visual patterns. Never read numbers off a figure.
- The `literatures/*/notes.md` that mentions this experiment's cost model (`metadata/costModel`),
  to explain what each hyperparameter does. If none mentions it, say so.

Never read any `report.html`.

## Step 3: Answer the analysis checklist
Work through every item. When the data cannot answer an item, write "not answerable" and say why.

Keep two kinds of evidence apart throughout:
- **Ground-truth-free:** what the optimizer and the cost function did (cost, movement, seed agreement).
- **Ground-truth-based:** accuracy (surface RMSE, translation and rotation errors, success rates).
  Always mark these "valid only if the ground truth is accurate". Never take the ground truth for granted.

### A. Optimizer health (check first; it can invalidate everything else)
- Share of runs per stop reason (`fractionRunsStoppedBy`). If most hit the evaluation budget,
  say that the results may reflect the budget, not the cost function.
- Failed, skipped, or unevaluated runs, and whether they cluster in certain combinations.
  Use `errorStage` and `errorMessage` in `per_run_evaluation.csv` to say whether a failure comes
  from the setup (e.g. a file could not be written) or from the optimizer or cost function.
- Search bounds vs start-pose error: compare `initialTranslationErrorMm` and `initialRotationErrorDeg`
  with the `optimizer` bounds (`translationBoundMm`, `rotationBoundDeg`).
  - Error larger than the bound: warn that the true pose is out of reach of the search.
  - Error above 80% of the bound: warn that the true pose is near the edge of the search region.
  This uses the ground truth, so it is a warning with the ground-truth caveat, not a conclusion.

### B. Is the cost function effective?

#### B1. Does the optimization behave? (no ground truth needed)
- `fractionRunsCostDecreased` decides the gate:
  - **< 10% (stuck):** the optimizer almost never found a pose the cost prefers over the start.
    Sections C and D shrink to one line each. Recommend diagnosing the optimizer and the
    cost function before any new sweep. As a hint for that diagnosis, say which parameter
    values the few runs that did move had in common (computed by Claude from `per_run_evaluation.csv`).
  - **10–60% (partial):** do C and D, but warn at the top that only some runs moved,
    so parameter effects are uncertain.
  - **> 60% (healthy):** full analysis.
  Always state which band applied and the number behind it.
- `medianRelativeCostDecrease`: how much the cost dropped in a typical run.
- Movement group (`fractionRunsMoved`, `medianStartToFinalTranslationMm`,
  `medianStartToFinalRotationDeg`): did runs actually leave the start pose?
  It should match `fractionRunsCostDecreased`; if not, say so.
- Seed agreement (`seedSpread` group: `medianSeedPairTranslationMm`, `medianSeedPairRotationDeg`):
  interpret it only after checking movement. When runs barely moved, seeds agreeing means
  they all stayed at the start, not that the cost has a clear minimum.

#### B2. Is the result accurate? (uses ground truth)
Start this subsection with: "These numbers are valid only if the ground truth is accurate."
- Final surface RMSE against `initialSurfaceRmseMm`: `fractionRunsSurfaceRmseImproved`,
  `medianSurfaceRmseImprovementMm`.
- Success rate (surface RMSE ≤ 1 mm) and clinical rate (translation ≤ 1 mm and rotation ≤ 1°).
- `spearmanBestCostVsSurfaceRmse`: a weak signal only, because cost scales differ between
  combinations. Never base the verdict on it alone.
- State the limitation: all runs start from one pose, so this tests one starting point only.

#### Verdict (two parts; same section name in findings.md and report.html)
1. **Does the optimization behave?** behaves / partly / stuck, from B1.
2. **Is the result accurate?** accurate / partly / not accurate, from B2, with the ground-truth caveat.
Support each part with two or three numbers.

### C. Which hyperparameters work?
Start with: "Parameter effects are measured in surface RMSE, so they are valid only if the
ground truth is accurate."
- Top combinations by median surface RMSE. Report the IQR next to each.
  With only a few seeds, say when the top combinations' IQRs overlap so they can't be told apart.
  Check whether a combination ranks high only because more of its seeds moved away from the start;
  if so, say that its rank reflects movement, not a better cost.
- Effect size of each parameter (`parameterEffect/surfaceRmseRangeMm`). Say which parameters
  matter and which barely do.
- Interactions seen in the heatmaps (e.g. the best value of one parameter depends on another).
- Whether the good region is broad (robust) or a single sharp best combination (fragile).
- Translation and rotation errors: do they agree with surface RMSE?

### D. Where to search next
- For each parameter whose best value is on the edge of the grid (`gridEdge` rows),
  say which way to extend.
- Parameters with negligible effect: suggest fixing them to save runtime.
- Propose a concrete next grid (values for each parameter, number of seeds) and estimate its runtime
  from the median runtime per run.
- If section A or B says the problem is the optimizer or the cost function, say so,
  and don't just propose another grid.

## Step 4: Writing rules
- Every claim cites a number and where it comes from (a statistic name or a combinationId).
- Separate what the data shows ("median RMSE 8.7 mm") from interpretation ("likely because...").
- Mark anything Claude computed itself, rather than read from a CSV, as "(computed by Claude)".
- Use the parameter names from the CSV; don't assume a specific cost model.
- Write in plain language for a reader who knows the project but not this experiment.

## Step 5: Write findings.md
Write `<experiment>/evaluation/findings.md` from `findingsTemplate.md` in this skill folder.
- Fill the header only from the `metadata` and `startPose` rows of `derived_statistics.csv`.
  Keep the header to its five fields.
- Follow the `<!-- -->` instructions in the template and leave them out of the written file.
- Keep the text below the header under 400 words.
- Overwrite it on every run; it is generated and never edited by hand.

## Step 6: Write report.html
The report needs `evaluation_tables.js` in `<experiment>/evaluation/` (all numbers, written by MATLAB).
If it is missing, skip this step and say so in the chat reply.

Copy `reportTemplate.html` from this skill folder to `<experiment>/evaluation/report.html`.
Then replace only the `window.REPORT_TEXT = { ... };` block; do not change anything else.
- Never type numbers into the page's tiles, charts, or tables: the page computes them from
  `evaluation_tables.js`, and the behaviour verdict follows the gate automatically.
- `accuracyVerdict`: exactly one of `"accurate"`, `"partly"`, `"not accurate"`.
- `behaveSentence`, `accuracySentence`: the two verdict sentences from `findings.md`.
- `health` (sections A and B1), `accuracy` (B2), `hyperparameters` (C): short `<p>` paragraphs.
- `nextSteps` (D): an `<ol>` list. `limitations`: a `<ul>` list. `focus`: answers to focus
  questions, or empty to hide that section.
- Strings are JavaScript template literals: write simple HTML (`<p>`, `<ul>`, `<li>`, `<code>`,
  `<strong>`) and never use a backtick inside the text.
- Keep the text consistent with `findings.md`; the page may say more, never something different.

The page works offline with no libraries; it loads `evaluation_tables.js` and the PNGs from its own
folder, so the evaluation folder must stay together.

## Step 7: Reply in chat
A short summary: the two-part verdict, the gate band, the best combination, the recommended next
step, and the paths to `findings.md` (and `report.html`). Don't repeat the whole report.

## Domain context
- Success: surface RMSE ≤ 1 mm.
- Clinically acceptable: translation error ≤ 1 mm and rotation error ≤ 1°.

## Constraints
- Write only inside `<experiment>/evaluation/`.
- Never modify `data/`, the CSVs, or other experiments' files.
- Don't run MATLAB, optimizations, or the evaluation script.
