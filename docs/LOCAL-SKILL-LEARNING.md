# Local skill and learning experiment

The production Rust Goal Agent still plans over verified Flow edges. Its shortest-path routine also composes the lab's motion contracts. The experiment separates the symbolic plan, the settled observation and control adapter, and the numerical selector. It runs by request as a separate invocation of the existing executable. It uses the current private SQLite database.

## Skill contracts

Every lab entry has a stable ID and version, category, precondition and result states, capability requirements, typed inputs, expected effect and verifier. The executable registry composes `motion.probe` with `motion.calibrated`, or uses `motion.fixed` when probing is unavailable. An environment without observation and a bounded actuator gets no path. A failed sample falls back to bounded fixed pulses. The simulator checks the resulting position before advancing the plan.

Use the universal level for the motion contract. Domain-specific FPS/RTS policy belongs above it, and control bindings and outcome schemas belong to the application adapter. CS 1.6 waypoints, the observed map, spawn tolerance and the configured bombsite are environment knowledge. Citadel deployment is an existing RTS-specific backend. The Rust CS practice adapter publishes observed results as `cs16.advance@1`. Its owned actor and fresh sequence are prerequisites. The Windows Flow executor and Citadel bridge retain their existing dispatch. The shared lab planner does not dispatch real CS actions.

## Learning modes

| REFLEX_LEARNING_MODE | Existing Windows Flow route memory | Motion lab |
| --- | --- | --- |
| off | Neither reads nor writes history | A one-shot dry experiment remains available |
| observe | Records results of verified flows and verification failures | A one-shot dry experiment remains available |
| adaptive (default) | Uses and updates the existing cost estimates | The comparison includes a model-free controller that calibrates each run from observed motion |
| neural | Keeps existing deterministic route adaptation | Explicit training and private checkpoint storage are available |

Set the variable in the launching shell. `learning experiment` always runs read-only. To persist a run, set the mode explicitly:

```powershell
$env:REFLEX_LEARNING_MODE = 'neural'
.\target\release\reflexcore.exe learning experiment --persist
.\target\release\reflexcore.exe learning registry
.\target\release\reflexcore.exe learning validate <checkpoint-sha256>
```

The trial data consists of a fixture ID, observed distance, measured progress and observation delay, skill/version, action index, predicted and observed displacement, settled verification and reward. It has no window labels, coordinates, images or user text. The SQLite append and eviction are transactional. The replay buffer keeps up to 1,024 rows per environment, including attempts that did and did not produce verified motion. The two simulated contexts and the real offline CS context are separate. The real CS records retain requested pulse milliseconds, elapsed engine time, wall-clock acknowledgement delay and the measured horizontal displacement. They omit map, coordinates, actor ID, window data and screen captures. A record verifies an acknowledged displacement from 0.75 to 64 units. It does not prove route progress or completion. The registry reports counts per environment and skill. These samples are collected after engine readback and written in a bounded batch after the run. Off leaves the replay unchanged. Live CS observations are not used as MLP training labels. Existing route rows and goal fingerprints retain their format. The table suffix and explicit checkpoint format isolate future incompatible schema changes. A checkpoint is content-addressed and up to four admitted candidates are retained. The loader verifies its SHA-256 and reruns the quality gate. No lab checkpoint is activated in live execution. To restore baseline route selection, launch with `REFLEX_LEARNING_MODE=off`. To compare an earlier lab version, validate its retained hash.

## Model boundary

`learning models` prints the three supported model contracts, including artifact-version sources, license provenance and resource ownership. It reports contracts regardless of the current availability of the optional external backends. The only new executable neural backend is a CPU-only, three-input MLP with a 12-unit hidden layer and three output actions. The existing Rust verifier bounds the final pulse independently of its output. Plain Rust stores the experimentally trained 87 parameters in an approximately 1 KiB versioned JSON checkpoint. Seeded baseline weights are immutable and reproduced from the published seed instead of overwritten. Training uses minibatches of 16 and never runs in the normal executor loop. Training samples replay verified and failed trials with balanced sampling from the earlier and current fixtures. Neither real CS nor real desktop data enters this model.

ReflexVision's detector and Ollama's VLM remain existing independent inference paths. Skill selection and outcome prediction models are still research targets. The experiment does not introduce a generic model server, GPU residency manager, or LoRA loader. PyTorch can export eligible graphs to ONNX for a future ONNX Runtime backend. LoRA needs an explicitly compatible base and backend. Ollama's import flow can package supported adapters against the same base. Its inference API is not a trainer. No LLM weights or adapters changed here. [PyTorch ONNX export](https://docs.pytorch.org/docs/stable/onnx), [ONNX Runtime LoRA](https://onnxruntime.ai/docs/genai/tutorials/finetune.html), [Hugging Face PEFT](https://huggingface.co/docs/transformers/peft), [Ollama model import](https://docs.ollama.com/import).

The registry uses Voyager's reusable skill idea and the Options Framework distinction between initiation, policy and termination. The training labels come from local intervention and independent effect checks in the simulator, following the supervised policy-learning idea from behavioural cloning. The model-free comparator is a measured calibration rule. It does not implement a contextual bandit. Prior-task replay is used to preserve earlier coverage, with retention measured on a separate seed. [Voyager](https://arxiv.org/abs/2305.16291), [Options Framework](https://ics.uci.edu/~dechter/courses/ics-295/winter-2018/papers/Sutton-Precup-Singh-AIJ99.pdf), [Counter-Strike behavioural cloning](https://arxiv.org/abs/2104.04258), [CS2 Deathmatch Bot](https://github.com/MrM0o0/cs2-deathmatch-bot), [Experience Replay for Continual Learning](https://arxiv.org/abs/1811.11682), [Contextual bandits](https://arxiv.org/abs/1003.0146).


The adapter design follows the explicit reset, step and observation pattern in dm_env and the distinction between failed objectives and time limits in Gymnasium. The FPS integration retains a separate observation and controller boundary, as in the small CS2 Deathmatch Bot and the released behavioural-cloning pipeline. The GoldSrc adapter uses owned local engine readbacks for evidence. [dm_env](https://github.com/google-deepmind/dm_env), [Gymnasium](https://github.com/Farama-Foundation/Gymnasium), [CS2 Deathmatch Bot](https://github.com/MrM0o0/cs2-deathmatch-bot), [Counter-Strike Behavioural Cloning repository](https://github.com/TeaPearce/Counter-Strike_Behavioural_Cloning).
