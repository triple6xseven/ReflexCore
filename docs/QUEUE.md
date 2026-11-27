# Supervised desktop queue

From the Agent page, submit a Rust UI Automation demo, a new-file Notepad task or the same task with local vision. Keep the target editor in the foreground. Studio adds the manifest in-process. The tray launches a hidden PowerShell worker. Studio shows **Verified** only for an accepted receipt from the built-in Goal or Notepad producer. A custom script returning zero appears as **Finished without verification**.

## Ownership and recovery

Pending and running manifests live in the project's private data/bridge directory. Each two-line manifest records RUN or REVIEW and one local tasks/ script basename. The existing Submit-ReflexJob.ps1 CLI remains compatible. Submission and claim use same-directory or same-volume renames. A Windows session mutex serializes queued workers, including a surviving worker from a previous tray process. Direct CLI programs and other applications do their own coordination.

The tray accepts new RUN entries automatically. REVIEW entries and pending work that predates the tray session need operator approval. The Studio command applies to the selected ID. On startup the tray marks remaining running claims interrupted and removes old approval markers. An interrupted job may have produced a partial effect. Inspect its output before submitting another task.

Cancellation of a pending job moves it to terminal history. A guarded Notepad job checks its claim, scoped cancellation and foreground between stages and before input. During HTTP inference the client polls at 150 ms and cancels an outstanding request. Model cleanup and receipt recording can take longer. The queued Rust UIA demo checks its cancellation marker before dispatch, during worker supervision and between steps. An in-flight action can have an unknown effect. The tray first waits for cooperative cancellation, then starts taskkill asynchronously for eligible owned worker trees. Notepad is cooperative throughout. If cleanup times out while the worker is still active, the tray reports the timeout and holds the execution lane.

The terminal manifest retains its original two header lines and can contain a third line with a bounded JSON receipt. The receipt uses schema `reflexcore.task.receipt.v1`, a task ID and run ID, a stage, outcome, verification state and reason code. A legacy two-line receipt remains readable. Recovery marks abandoned claims interrupted without replaying them. The history retains up to 100 terminal manifests. Studio caches terminal labels and receipts, and shows a running claim with a cancellation marker as **Stopping**. No model or separate scheduler service runs to poll this queue.

## Windows acceptance

For the built-in WinForms saved-text and Notepad jobs, the tray assigns a new
run ID when it claims the job. A verified history entry requires the expected
task, run, editor and versioned disk-readback evidence, plus successful worker
exit. If cancellation is accepted before publication, the queue records the
cancellation even if the file has already been saved. Paths and document text
stay out of terminal receipts.

The foreground Notepad jobs ask Windows to pass activation permission to the
specific worker. The editor must still find one visible matching document and
observe it in the foreground before sending input. The background WinForms
job never requests foreground permission.

Run tasks/Test-Queue.ps1 for recovery, fresh approval, cross-process exclusion, failure, cancellation, stop-all and bounded history. With a release executable, `-UiaFixture` runs the single owned WinForms Goal and checks the verified receipt. `Measure-TaskStop.ps1` compares the stop handler and terminal latency with a synthetic worker, using `-SourceRoot` for an older checkout. With a release executable, -AllowInput also executes actual WinForms and Unicode Notepad fixtures. Add -VisualCancellation to cancel a real model request and check the resulting empty file. Cancelled visible fixtures remain in the local fixtures directory for inspection. The Studio -UiSmoke exercises the queue buttons against an isolated temporary store.

## Folder workflows

The existing tray queue supervises both handoff checks and approved extension renames. Extension renames cooperate with scoped cancellation between moves. Handoff summary counts and rename counts are available in terminal receipts. Report locations and workflow inputs remain in private sidecars. Select a completed handoff check in Studio to open its correlated report or preview the next step after a verified Ready result. See [Verify a Handoff Folder](HANDOFF-FOLDER.md).

Composition discovery currently advertises direct CLI execution. The queue still rejects attempts to invoke compose-text through a job manifest pending exact-plan Studio approval.
