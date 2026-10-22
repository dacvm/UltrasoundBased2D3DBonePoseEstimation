# Processing workflow

The one-sweep and hyperparameter-sweep scripts share the same configuration, planning, input-preparation, optimizer, and cost-dispatch framework. The sweep runner adds loops over parameter combinations and random seeds, plus immediate result saving. The following sequence shows the main function calls; display-only calls in the interactive one-sweep script are omitted.

```mermaid
sequenceDiagram
    actor User
    participant Runner as One-sweep script or experiment runner
    participant Config as Configuration functions
    participant Registry as getBonePoseCostDefinition
    participant Inputs as prepareBonePoseOptimizationInputs
    participant Optimizer as runBonePoseOptimization / CMA-ES
    participant Dispatcher as bonePoseCostFunction
    participant Model as Cost evaluator

    User->>Runner: Run one-sweep or hyperparameter-sweep script
    Runner->>Config: createBonePoseOptimizationExperimentConfig(JSON)
    Config->>Registry: Resolve model and validator
    Registry-->>Config: Evaluator, validator, and input requirements
    Config->>Config: Validate fixed parameters and hyperparameter arrays
    Runner->>Config: createBonePoseOptimizationExperimentPlan(experimentSpec)
    Config->>Config: Expand parameter combinations and repeat seeds

    loop Each parameter combination (exactly one for one-sweep)
        Runner->>Config: createBonePoseOptimizationRunConfig(...)
        Runner->>Inputs: Prepare estimation and validation data once
        Runner->>Dispatcher: Evaluate the initial pose
        loop Each random seed (exactly one for one-sweep)
            Runner->>Optimizer: Optimize with the seed-specific config
            loop Every CMA-ES candidate pose
                Optimizer->>Dispatcher: bonePoseCostFunction(poseVector, data, config)
                Dispatcher->>Registry: Resolve config.cost.model
                Registry-->>Dispatcher: Evaluator handle
                Dispatcher->>Model: Evaluate candidate geometry and objective
                Model-->>Dispatcher: Scalar cost and diagnostic details
                Dispatcher-->>Optimizer: Cost, where lower is better
            end
            Optimizer-->>Runner: Best pose, transforms, cost, and diagnostics
            alt Hyperparameter sweep
                Runner->>Dispatcher: Re-evaluate the best pose for details
                Runner->>Runner: Save runResult and refresh summary
            else Interactive one-sweep
                Runner->>Runner: Display and retain results in the workspace
            end
        end
    end
```

At configuration time, `createBonePoseOptimizationExperimentConfig` asks the registry for the selected model's validator. The validator separates values that stay fixed from arrays that should be swept. `createBonePoseOptimizationExperimentPlan` then builds every combination, and `createBonePoseOptimizationRunConfig` merges one combination into `config.cost.parameters`, the scalar structure seen by a cost evaluator.

At optimization time, CMA-ES changes only the six-value local pose perturbation. `bonePoseCostFunction` is the stable public dispatcher: it reads `config.cost.model`, resolves the registered evaluator, and forwards the pose, prepared data, and scalar configuration. Consequently, the optimizer and runner do not need model-specific branches.
