# ReflexCore 1.0 Architecture Blueprint

**Status — proposal.** ReflexCore 1.0 should take a user task from intent to an independently verified result, recover when a worker disappears, and use verified experience in subsequent runs. The first implementation stays in the existing Rust crate, with one executable, supervised workers, and the current Windows file queue.

## Starting point

| Revision | What to reuse |
| --- | --- |
| [main at 2b3fefd](https://github.com/triple6xseven/ReflexCore/tree/2b3fefd) | Compatible CLI commands, Studio, the queue, and current manifest formats |
| [P0 at 8d8f227](https://github.com/triple6xseven/ReflexCore/tree/8d8f227) | Correlated UIA responses, typed reasons, queue receipts, and cooperative cancellation |
| [Planner and Runtime split at c0c939f](https://github.com/triple6xseven/ReflexCore/commit/c0c939f) | Existing module boundaries. Reconcile the two cancellation implementations during integration so one module owns the protocol |
| [Studio at 434d7ad](https://github.com/triple6xseven/ReflexCore/tree/434d7ad) | Recent queue, diagnostics, and companion views |

In P0, the Goal runner increments its completed-skill count after a successful Flow return. The built-in fixture binds Apply to its Output check using fixed step indices. Integrate and verify the baseline first, then generalize the contract that binds a specific action to its effect. [Goal runner](https://github.com/triple6xseven/ReflexCore/blob/8d8f227/src/agent.rs#L269) · [Flow runner](https://github.com/triple6xseven/ReflexCore/blob/8d8f227/src/flow.rs#L279)

## Six layers

| Layer | Extension point | Input → output | Responsibility |
| --- | --- | --- | --- |
| Cognitive | Optional local Ollama client | User goal and permitted catalog → proposed subtasks | Decompose within a budget. Keep adapter handles in the Runtime |
| Planning | Dijkstra's algorithm in Goal Agent | Observed initial state, goal, applicable skills, and costs → ordered skill versions | Choose a deterministic route. Accept a new planning request when the Runtime observes a change |
| World Model | A module over the observer, UIA, and task-owned artifacts | Observation scope → dated facts | Track freshness and object identity. Distinguish a mismatch from an unavailable source |
| Execution Runtime | Goal runner, Flow, registry, and UIA worker | Plan and task authority → action receipt | Own sequencing, cancellation, deadlines, and adapter selection. Use the existing queue to serialize interactive desktop work |
| Verification | A module over UIA readback and independent file checks | Effect contract, receipt, and fresh observations → finding | Register trusted verifiers. Confirm each mandatory effect and check the final goal |
| Memory & Learning | Existing SQLite and the experimental local neural runtime | Completed attempt, findings, and context → evidence and cost updates | Update experience idempotently. Bound planning adjustments and train weights in a separate invocation |

Begin with modules for shared types, state, verification, and lifecycle. The Windows adapter owns COM calls and native handles. Studio, CLI, and tray remain clients of the existing protocols. Move the old simulator into `legacy_demo` with compatible CLI aliases. Consider a Cargo workspace once a module has a stable API and a second independent consumer.

## Task, run, and effect

The queue job ID remains `task_id`. Direct CLI execution allocates a task ID on entry. `run_id` identifies an attempt, `plan_revision` increments when the plan changes, `effect_id` identifies the intended change, and `action_id` correlates a worker request and response. Use Rust wrappers around the existing string IDs at the Studio and PowerShell boundaries.

| Transition | Runtime condition and action |
| --- | --- |
| Created → Planning → Ready | Validate the goal, schema, authority, skill compatibility, and cost. Pin the plan and skill versions |
| Ready → Executing | Observe fresh preconditions. Check target ownership, cancellation, and deadline. Persist intent before dispatching a mutation |
| Executing → Verifying | Record dispatch information. Check mandatory effects within the adapter's deadline |
| Verifying → Ready / Completed | Continue from fresh state or verify the final goal independently. An empty plan also requires a goal check |
| Blocked / Recovering | Stop the route when a precondition is lost. After observation, allow bounded replanning. Block when the same facts produce the same plan |
| Stopping → Cancelled | Stop issuing actions and wait for cleanup or register its timeout. Keep the execution lane occupied while its worker is still active. Ignore late responses for dispatch decisions |
| Failed / Unknown | Use Failed when the contract is demonstrably unmet. Use Unknown when the effect is unresolved. Permit read-only reconciliation |

The task phase and each effect's outcome are separate fields. A stop after Save can end in Cancelled with an Unknown effect. If one of two required changes is confirmed, Studio can display partial completion and each effect's status. Scripts that exit successfully without effect evidence retain the label *Finished without verification*.

### Journal and restart recovery

The file queue retains authority to start a job. A private journal in the existing SQLite database records events and an attempt-state projection. The attempt owner writes an event and updates the projection in one transaction using a version check. The event key is `(task_id, run_id, sequence)`. Persist `DispatchIntent` before sending a mutation. Stop dispatch if that write fails.

On restart, quarantine the abandoned claim and establish whether its owned worker has exited. Treat an unresolved intent as possibly executed, including when its response was lost. A recovery attempt links back to the original effect and begins with observation. Publish the confirmed terminal result to the queue atomically. If the process crashes after the database commit, repeat publication of the same receipt. An unexpected conflict with an existing outcome stops automated reconciliation. SQLite and the file queue have separate transaction boundaries.

## Observation, skill, and evidence contracts

The first implementation can use two predicates. Targets and artifacts are scoped to the task.

```rust
enum Predicate {
    ControlValueEquals { target: TargetRef, expected: InputRef },
    OwnedFileContentEquals { artifact: ArtifactRef, expected: InputRef },
}

enum Finding {
    Confirmed(EvidenceId),
    Mismatch(EvidenceId),
    Unknown(ReasonCode),
}

trait Observer {
    fn observe(&self, scope: &ObservationScope, budget: &Budget)
        -> Result<Observation, ObservationError>;
}

trait Verifier {
    fn check(&self, claim: &EffectClaim, observation: &Observation) -> Finding;
}
```

**Observation** includes source, scope, target generation, sequence, and time. Use UTC for history and a monotonic clock for local deadlines. Invalidate observation caches on restart. Check UIA window ownership, element identity, and applicable focus constraints just before issuing a mutation. An ordinal path can accelerate lookup. Resolve an ambiguous window or changed control again before execution.

**SkillDescriptor** defines ID, version, category, input types, capabilities, preconditions, mandatory effects, verifier ID, and retry policy. The registry maps the descriptor to a Flow or a built-in adapter. Predicates use a closed set of operations. The trusted catalog chooses the verifier. A skill returns an action receipt and a diagnostic code. One batch result can provide evidence for multiple effects when the verifier identifies each one explicitly. [Existing lab registry](https://github.com/triple6xseven/ReflexCore/blob/8d8f227/src/skill_registry.rs#L22)

**Evidence** binds the task, run, effect, target, predicate, observation, source, and verifier version. The Runtime validates the binding, freshness, and source. An observation made before dispatch can establish that the goal is already satisfied and receives its own outcome in the run record. For effects that settle asynchronously, a pending or negative observation can trigger another read within the deadline. Use Unknown when the deadline expires without sufficient evidence of success or failure.

### End-to-end example — Save

1. The user authorizes saving a test document. The adapter pins the editor, expected content, and destination artifact. For a creation contract, first establish that the destination is absent or acquire the right to create it exclusively.
2. The first skill enters the text and reads it back from the same editor. The second skill checks its own preconditions. A changed window blocks the route before Save is issued.
3. The Runtime records the intent to Save. If the worker exits after dispatch, the effect is Unknown. The adapter independently reopens the pinned output and checks the contents. Confirming artifact identity and all mandatory conditions can complete the goal.
4. After restart, recover the expected result from a versioned test scenario or an approved private source. If the artifact or expected value cannot be resolved, retain Unknown. Allow another mutation only when fresh evidence establishes its preconditions and the contract permits a retry.

## Memory, privacy, and model integration

- **Semantic memory** holds versioned skill and adapter descriptions. **Episodic memory** holds bounded run history. **Procedural memory** holds verified ways to complete a task and the conditions under which they apply. Reuse the catalog and SQLite. Apply retention after open effects are reconciled.
- Key reliability by `skill_id + skill_version + implementation_hash + verifier_version + environment_compatibility`. Keep cost and manifest position out of identity. Migrate old statistics when the old Goal key, slot, and fingerprint map unambiguously. Keep previous rows available during the rollback period.
- Track confirmed successes and failures alongside Unknown, cancellation, recovery, duration, and recency. A unique skill-attempt key prevents double credit on receipt replay. A new verifier or incompatible application version starts a separate cohort. Track the Unknown rate as a measure of observation coverage.
- Export allowlisted IDs, reason codes, versions, timings, and counts. Keep user text, window titles, paths, screenshots, and user-content hashes in their authorized private scope. Give experience and diagnostic exports separate serialization types.
- Ollama may propose a bounded tree of subtasks referencing known skill IDs and typed inputs. Validate depth, node count, cycles, budget, and scope before planning. Admit proposed skills through schema validation, isolated tests, and an explicit catalog update. Structured goals retain a deterministic path when the model is unavailable.

## First product task — Verify a handoff folder

A user selects a folder and a reusable checklist. ReflexCore checks for required files, validates supplied SHA-256 values, and publishes a local report with actionable findings. Use native filesystem reads, stream hashes, and independently reopen the report before issuing a verified receipt. A verified report can say the folder needs attention. Start with a typed checklist and add optional natural-language interpretation once the same checks pass with and without model assistance.

This workflow exercises typed skills, explicit scope, observation, independent verification, and repeatable use of a saved checklist. Take compact observations and live target checks from Hybrid Computer Use, effect verification and measured model-free runs from OpenAdapt, and task-specific evaluators from Windows Agent Arena. [Hybrid Computer Use](https://github.com/microsoft/Hybrid-Computer-Use#how-it-works) · [OpenAdapt Flow](https://github.com/OpenAdaptAI/OpenAdapt/blob/main/packages/flow/README.md) · [Windows Agent Arena task design](https://github.com/microsoft/WindowsAgentArena/blob/main/docs/Develop-Tasks.md)

## Delivery and acceptance

| PR | Scope | Acceptance |
| --- | --- | --- |
| 1. Integration | Reconcile P0, queue, Studio, and Citadel changes on one revision. Bind benchmark results to the run | Reject another run's fresh report. Pass Rust, queue, and Studio smoke tests on the same revision. Check the Portable build in a clean directory |
| 2. Verified Goal | Add the first predicates and effect bindings. Check state between skills and at the final goal | A changed state in the two-step fixture yields zero dispatches of the second skill. Unrelated evidence leaves an effect unresolved. Verify the goal even when the plan is empty |
| 3. Recovery | Persist dispatch intent and versioned snapshots. Reconcile the journal, queue, and cancellation | Inject failures before dispatch, after dispatch, and before receipt publication. Assert zero duplicate irreversible actions and zero new dispatches after accepted cancellation |
| 4. Verified memory | Migrate skill identity and update outcome statistics idempotently | A cost edit keeps the experience. A verifier change isolates it. Replaying a receipt adds zero duplicate records |
| 5. Catalog and decomposition | Add a second controlled environment, capability matching, and bounded model proposals | Compose the same contract with distinct adapters and independent checks. Reject unsupported plans before mutation. Measure quality, latency, and memory with the model enabled and disabled |

For each PR record the revision, environment, sample size, verified outcome counts, p50/p95, and peak memory. Use synthetic workers for protocol and crash windows. Use a short owned Windows fixture for the real adapter when interactive input is authorized. The primary 1.0 acceptance metric is zero false Verified outcomes in tests covering lost evidence, target changes, and worker crashes.
