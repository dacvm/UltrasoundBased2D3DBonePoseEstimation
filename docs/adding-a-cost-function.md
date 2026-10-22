# Adding a new cost function

**Naming a cost model.** Give each cost model a descriptive name and no version suffix. Use `intensityLine`, not `intensityLine_v2`. A version number says only that something changed. A descriptive name says what changed, so a reader can tell two models apart without opening the code.

- Use one camelCase name everywhere: the registry key and `cost.model` (`<name>`), the evaluator (`cost_<name>.m`), the validator (`validate_cost_<name>.m`), the test file (`testBonePoseCost<Name>.m`), and the config templates (`optconfig_oneSweep_<name>.json`, `optconfig_hyperparamSweep_<name>.json`).
- Start with the evidence the model uses, then add what is special about it. For example, `intensityLine` scores image intensity along the predicted bone line, and `ICPLike` scores a point-to-mesh distance.
- Name a combined model by joining its parts in a fixed order, intensity term first: `intensityICP`, `intensityPIMLOP`.
- If you change the behaviour of an existing model and want to keep the old one for comparison, give the new model a name that describes the change, for example `intensityLineGradient` or `PIMLOPWeighted`. Do not add `_v2`. Move the retired model to `costModels/legacy/` once nothing uses it.
- Do not change the meaning of an existing name. Results saved under that name would no longer match the code.

1. **Create an evaluator in `functions/bonePoseOptimization/costModels/`.** Use the interface `[cost, details] = cost_<name>(poseVector, data, config)`. Perform file loading and other reusable preparation before optimization, not inside this frequently called function. Return one finite numeric scalar, keep the convention that lower is better, and place useful intermediate values in `details` so a saved best pose can be inspected.

   ```matlab
   function [cost, details] = cost_example(poseVector, data, config)
   %COST_EXAMPLE Evaluate one candidate pose with the example model.
   % This evaluator converts the candidate pose into one finite objective so
   % the shared CMA-ES framework can optimize a new source of evidence.
   %
   % Inputs:
   %   poseVector - Six-value perturbation around the initial CT pose.
   %   data       - Prepared inputs reused by every candidate evaluation.
   %   config     - Scalar runtime settings, including cost.parameters.
   %
   % Outputs:
   %   cost       - Finite scalar objective value; lower is better.
   %   details    - Diagnostic values needed to inspect this evaluation.

   % Convert and evaluate the candidate here using prepared data and scalar settings.
   % Replace this placeholder with the model's actual calculation.
   cost = 0;

   % Save enough context to explain the returned scalar after optimization.
   details.costSettings = config.cost.parameters;
   details.status = 'example_cost_computed';
   end
   ```

2. **Create its matching validator beside the evaluator.** Use the interface `[fixedParameters, hyperparameters] = validate_cost_<name>(fixedParameters, hyperparameters)`. Require the exact supported field names, validate every value, convert fixed values to scalar doubles (a fixed value may also be a short numeric vector, such as the three P-IMLOP standard deviations), and normalize each hyperparameter candidate list to a row vector. Rebuild the output structs in the order in which their fields should appear in experiment tables. An empty struct is valid when the model has no fixed parameters or no hyperparameters.

3. **Register the model in `getBonePoseCostDefinition.m`.** Add one `switch` case that assigns the public model name, evaluator, validator, and input requirement:

   ```matlab
   case 'example'
       definition.modelName                   = 'example';
       definition.evaluateFcn                 = @cost_example;
       definition.validateExperimentConfigFcn = @validate_cost_example;
       definition.requiresBoneSurface         = false;
   ```

   Set `requiresBoneSurface` to `true` only when the evaluator needs the aligned measurements from `boneSurfaceMatFile`. If a model needs other prepared data that the framework does not yet provide, extend `prepareBonePoseOptimizationInputs` once so the data is loaded and validated before CMA-ES starts.

4. **Create or copy a JSON configuration.** Set `cost.model` to the registered name. Put one scalar value per fixed parameter under `fixedParameters` and one or more candidate values per sweepable parameter under `hyperparameters`:

   ```json
   "cost": {
     "model": "example",
     "fixedParameters": {
       "fixedScale": 1.0
     },
     "hyperparameters": {
       "exampleWeight": [0.25, 0.5, 0.75]
     }
   }
   ```
