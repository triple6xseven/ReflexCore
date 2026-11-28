# 0.8 integration baseline

The integration target is `integration/reflexcore-08`. Use [ROADMAP](ROADMAP.md) for scope, [the original 1.0 proposal](architecture/REFLEXCORE-1.0.md) for intended boundaries and [the branch audit](BRANCH-AUDIT.md) for ancestry and dispositions. The blueprint is the unmodified document from `756871d`. Features in the blueprint require their own acceptance. This integration has no release tag. The published Windows preview comes from `c972406`.

## Component map

- Native execution owns UIA isolation, identity, cancellation and independent verification. The opt-in session worker and process baseline descend from `efa3436` and instrumentation from `53bb69b`. [Runtime](COGNITIVE-RUNTIME.md) and [measurements](BENCHMARKS.md).
- Phase C at `2b92bff` adds an approved composition queue, typed execution and terminal readback. Rust owns effects and receipts, Studio and MCP submit to the queue. The shell never promotes an interrupted publication to verified. [Contracts and reproductions](UNIVERSAL-SKILL-RUNTIME.md), [queue](QUEUE.md).
- The developer observer, Revision Guard and durable catalogue descend from `448d55e`. Git selects evidence by branch and blob. SQLite holds reconstructible retrieval state and private worktree-local checkpoints. Repository evidence carries no execution authority. [Observer protocol](CODEX-INTEGRATION.md), [MCP tools](MCP.md).
- Studio hosts the Windows operator interface. Model services are optional. Offline lab and companion experiments retain separate identities, inputs and qualification. Existing experiments inherited from main are available under their original constraints.
- The installed operator runtime is independent of this source branch. The previously deployed `819ac84` lacks tasks/compose-text.ps1. Its separate MCP queue must refuse submission. A matched runtime, worker and Studio checkout supports the approved workflow. Neither source integration nor plugin installation deploys a Windows runtime.

## Skill inventory

Rust serializes IDs, versions, typed inputs, effects, capability sets, restrictions and verifier names from `src/skill_registry.rs`. Run `reflexcore learning registry` (or MCP `list_skills`) for the executable contract; editor binding checks use `learning bind`. The operator also has application-specific workflow actions, such as handoff verification, which use their own queue manifests.

- `artifact.verify_saved_text@1` consumes an owned saved file and expected text, requires owned_artifact and reopen_disk, and emits typed evidence from bounded ordinal disk readback. WinForms supports foreground/background, Notepad requires foreground consent. Verified on the Phase C fixtures.
- Composition v1 binds editor.create_document, artifact.verify_saved_text, artifact.derive_text and artifact.verify_derived. Four or six steps consume only verified predecessor artifacts. Explicit create/read/derive/publish authority is required. See `src/skill_registry/composition.rs`, `tasks/Test-TextComposition.ps1` and the terminal crash cases in `tasks/Test-Handoff.ps1`.
- `motion.probe@1`, `motion.fixed@1`, `motion.calibrated@1` and `cs16.advance@1` are experimental motion operations. Probe observes response, fixed and calibrated pulses verify settled position, the GoldSrc pulse requires the owned practice adapter and fresh displacement. Registry tests cover capability refusal. Their outcomes apply only to the named fixture.

The five Codex skills are instructions shipped together with the plugin. Version follows the plugin manifest. Each requires the operator's configured local MCP.

| Skill | When to invoke and example | Evidence and restriction |
| --- | --- | --- |
| reflex-continue | Continue an active engineering milestone | get_development_context with cwd, branch and component. Compare HEAD and next operation. |
| reflex-resume | Recover an interrupted test | Same worktree-bound tool. Reconcile outstanding operations and exact pending CI before repetition. |
| reflex-validate | Check the release used by the current change | get_validation_evidence with cwd and branch. Verify binary and fixture evidence independently. |
| release-check | Check a configured release folder | list_projects, submit_saved_handoff or submit_handoff_check, get_task_result. Studio approval precedes execution. |
| offline-lab-evidence | Explain a published offline run | list_lab_runs, list_combat_runs, get_combat_run, compare_combat_runs. Reads compatible observations only. |

## Qualification and release

On Windows run `cargo test --locked`, `cargo build --release --locked`, and `dotnet build ui/ReflexCore.Studio.csproj -c Release`. Run the queue and observer checks listed in .github/workflows/windows-runtime.yml. On an unlocked desktop run the Control Center with -UiSmoke. Run `tasks/Test-Handoff.ps1 -Mcp -Composition` on an unlocked desktop (or add -BackgroundCompositionOnly for the owned background binding) for approved submission, negative inputs and terminal readback. Compare measurements only on matching inputs, authority and verification. The Windows preview packaging procedure is separate; see [distribution](WINDOWS-DOWNLOADS.md). Keep private queue data, models and operating configuration outside the source package. See [the repository licence](../LICENSE) and [companion asset terms](COMPANION-ASSET-LICENSE.md); individual assets and model licences apply independently.

## Continuation

Recover the active objective, operation status and CI by exact SHA from the approved integration worktree. Consult the roadmap when no declaration is available. The Phase D experiment is on a separate branch. Its failed CI step must be reconciled before consideration for integration. Production skill acquisition, compatibility learning, generalized world modelling and an external skill SDK remain unqualified.

## Local acceptance record

At consolidation there were 27 remote heads, 31 pre-existing local branches and 17 original registered worktrees. Four trees had existing changes. Recovery refs and private backups were created before integration. Local main was at 2b3fefd and origin/main at 9ff7177. The single published Windows release was v0.7.1-alpha.2-windows.1. No dependency or asset licence changed.

The combined checkout passed a locked Rust release build, 132 Rust tests (two ignored), Studio compilation and UI smoke, queue recovery and cancellation, supervisor loss during the terminal move, MCP background composition with two independently reopened outputs, developer provenance, worktree/branch and memory isolation, schema-1 rebuild and partitioned lookup. Packaging the ordinary handoff fixture exposed an unconditional developer guard dependency; the bridge now loads the guard only for developer tools. The matched-runtime fixture checks actual MCP submission and changed approval rejection. The installed split runtime continues to refuse unsupported composition.

Foreground Notepad returned process_failed twice. An isolated adapter diagnostic identified foreground_unavailable. The refusal preserved the destination; a live foreground success on this combination remains outstanding. Historical Phase C and current checkout qualification are distinct. No game or companion policy changed. A relative Markdown link check covered 36 files (local file targets only).

A fresh Codex client exposed a host-dependent failure in Windows PowerShell module lookup. An inherited module path prevented the observer delegate from resolving Get-FileHash. The launcher now imports the system utility module from its own PSHOME. The worktree recovery regression exercises an isolated module search path. Installed stdio recovery after the fix returned the intended branch, pending CI identity and active integration policy; the bound preflight reply measured 2,687 UTF-8 JSON bytes.

Checking the same clean binary from Windows PowerShell 5.1 and PowerShell 7 exposed a second integration defect. Culture-sensitive path sorting produced different source fingerprints. New stamps use ordinal path ordering; existing v1 stamps retain their original comparison rules. The fixture includes punctuation-sensitive paths and checks the peer shell when installed.

## Main stabilization checkpoint

Use main for future development after the promotion checks. The integration branch holds candidate revisions until qualification. The downloadable Windows preview at `c972406` has its own release documentation.

- Preserve the verified Phase C source baseline and repair the known foreground and discovery boundaries independently.
- Port the installed overlay and hidden startup files from `819ac84`. The overlay and startup controls are documented in [Companion & Widgets](REFLEXCOMPANION.md).
- Qualify discovery separately and keep acquisition dependent on independent effect evidence and operator review.
- Validate local runtime and startup migration independently from source promotion. Check the runtime's Studio, worker, queue and provenance together.
- Recover active work and exact CI from the observer. If an installed workflow is unavailable, consult [MCP compatibility](MCP.md) and the [roadmap](ROADMAP.md).

The direct deterministic Notepad adapter verified an owned Unicode file with zero model calls. A separate queue run refused safely. A diagnostic of the real tray launch recorded AllowSetForegroundWindow returning false for the worker PID. Windows requires the grantor to have foreground authority. Queued Notepad therefore remains conditional on the approved editor becoming the verified foreground target. No activation rights or input checks were relaxed. See [Windows foreground permission](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-allowsetforegroundwindow).

## Bounded Phase D discovery candidate

Use the release executable with `learning discover` and pipe the contents of `examples/discover-document-preview.json` to standard input. The native runtime validates the descriptor, checks its declared capabilities and retains the independent verifier identity. It opens only the owned hidden preview fixture and reads its Output value. The result has candidate status and pending effect verification. It has no executable registration or queue authority. Windows PowerShell streams with and without a UTF-8 BOM use the same 4,096-byte input budget.

Windows run 46163044852 passed on the isolated fix at `0178173`. The integrated Windows workflow repeats the nine unattended rejection cases, including BOM validation and bounding. Run `tasks/Test-SkillDiscovery.ps1 -Interactive` on an unlocked desktop to qualify the owned preview binding and foreground preservation.
