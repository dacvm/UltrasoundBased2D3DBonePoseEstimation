# Analyzing a sweep with Claude

After a hyperparameter sweep, the evaluation script gives you tables and figures. This page explains how to let Claude Code read them for you and write a short summary and an interactive report. It is done by a project skill called `analyze-hyperparamsweep`.

The skill tries to answer three questions about one experiment:

1. Does the cost function move the bone mesh toward the right pose?
2. Which hyperparameter values work well, and how sure can we be?
3. Where should the next sweep look?

## 1. Before you run it

The skill only reads files. It does not run MATLAB. So first run the two MATLAB steps:

1. `main_bonePoseOptimization_hyperparamSweep.m` runs the optimizations (see [Running the project](running.md)).
2. `main_bonePoseOptimization_evaluation.m` turns the results into tables and figures.

After step 2, the experiment's `evaluation/` folder must contain these files:

| File | What it holds |
| --- | --- |
| `per_run_evaluation.csv` | One row per optimizer run. |
| `per_combination_evaluation.csv` | One row per combination of settings, summed up over its seeds. |
| `derived_statistics.csv` | The numbers the analysis is built on, each with a one-line definition. |
| `evaluation_tables.js` | The same numbers in a form the HTML report can load. |
| Four `.png` figures | The MATLAB figures: box plot, error plot, heatmaps, and cost vs. RMSE. |

If something is missing, the skill stops and tells you to run the evaluation script.

## 2. How to run it

Start a Claude Code session in the repository root and type:

```
/analyze-hyperparamsweep <experimentFolderName>
```

`<experimentFolderName>` is the folder name under `output/bonePoseOptimization/experiments/`, for example `intensityPIMLOP_20261015_161737_663`.

You can add your own questions after the folder name, for example "is the smoothing sigma worth sweeping?". The skill answers them in a separate section.

The skill looks at one experiment only. It does not compare experiments with each other.

## 3. What you get

The skill writes two files into the experiment's `evaluation/` folder:

- **`findings.md`**: a short summary (under 400 words below its header). It is a quick record of what this experiment showed.
- **`report.html`**: an interactive report. Open it by double-clicking; it works offline and needs no installation. It loads `evaluation_tables.js` and the PNGs from the same folder, so keep the folder together.

Both files are generated. Do not edit them by hand; run the skill again instead. A new run overwrites them.

## 4. The sections of `report.html`

| Section | What it shows |
| --- | --- |
| Header | The experiment name and its setup: cost model, data files, start pose, swept parameters, and number of seeds. |
| Verdict | The two main answers. First: does the optimization behave? This part does not use the ground truth. Second: is the result accurate? This part does use the ground truth. |
| Optimizer health | What the optimizer did: why runs stopped, how many runs failed, how many runs moved away from the start pose, and whether the seeds ended in the same place. It also checks whether the true pose is within the optimizer's search bounds. |
| Accuracy | How close the results are to the ground truth: surface RMSE, translation and rotation errors, and the share of runs that meet the targets. It has two interactive charts: hover a point for details, and click to highlight a combination. |
| Hyperparameters | How much each parameter changes the result, with the MATLAB heatmaps. |
| Combinations | A table of every combination, ranked by median surface RMSE. Click a header to sort, or a row to highlight it in the charts. |
| Next step | What to do next: a new grid to try, or what to check first when something is wrong. |
| Limitations | What this experiment cannot tell you. |
| Focus questions | Answers to your own questions. It only appears when you asked some. |
| All statistics | Every row of `derived_statistics.csv` with its definition, so you can check any number. |

Sections that use the ground truth are marked with a yellow warning box. The numbers in them are only valid if the ground truth is accurate.

## 5. Good to know

- **The data goes to Claude.** To analyze the results, Claude reads the CSV files and figures, so their content is sent to Anthropic during the session. The report itself stays on your computer.
- **The skill can be wrong.** Check important conclusions against the numbers in "All statistics" before you act on them.

## 6. Changing the skill

The skill lives in `.claude/skills/analyze-hyperparamsweep/`:

| File | What it controls |
| --- | --- |
| `SKILL.md` | The instructions Claude follows: what to read, what to check, and how to write. |
| `findingsTemplate.md` | The layout of `findings.md`. |
| `reportTemplate.html` | The layout, charts, and styling of `report.html`. |

To try out a new report design without real results, run `devs/reportDesign/makeFakeEvaluationTables.m`. It writes fake tables and figures to `output/reportDesign/`.
