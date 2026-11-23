# Supervised desktop queue

From the Agent page, submit a Rust UI Automation demo, a new-file Notepad task or the same task with local vision. Keep the target editor in the foreground. Studio adds the manifest in-process. The tray launches a hidden PowerShell worker and reports its exit status. Only the two Notepad wrappers and the built-in UIA fixture provide their respective independent effect checks. A completed custom script means it returned zero.

## Ownership and recovery

Pending and running manifests live in the project's private data/bridge directory. Each two-line manifest records RUN or REVIEW and one local tasks/ script basename. The existing Submit-ReflexJob.ps1 CLI remains compatible. Submission and claim use same-directory or same-volume renames. A Windows session mutex serializes queued workers, including a surviving worker from a previous tray process. Direct CLI programs and other applications do their own coordination.

The tray accepts new RUN entries automatically. REVIEW entries and pending work that predates the tray session need operator approval. The Studio command applies to the selected ID. On startup the tray marks remaining running claims interrupted and removes old approval markers. An interrupted job may have produced a partial effect. Inspect its output before submitting another task.

Cancellation of a pending job moves it to terminal history. A guarded Notepad job checks its claim, scoped cancellation and foreground between stages and before input. During HTTP inference the client polls at 150 ms and cancels an outstanding request. Model cleanup and receipt recording can take longer. The supervised UIA demo also checks its claim and cancellation marker from inside the Rust Flow, with owned-child cleanup. The tray retains its existing process-tree stop. The emergency stop also cancels waiting jobs within its existing stop-all scope.

The history holds the newest 100 valid terminal receipts by submission ID. The visible table reads only local time, an allowlisted task label and status. Private history stores the local task basename. Studio caches terminal task labels while the Agent page is visible. No model or separate scheduler service runs to poll this queue.

## Windows acceptance

Run tasks/Test-Queue.ps1 for recovery, fresh approval, cross-process exclusion, failure, cancellation, stop-all and bounded history. With a release executable, -AllowInput also executes actual WinForms and Unicode Notepad fixtures. Add -VisualCancellation to cancel a real model request and check the resulting empty file. Cancelled visible fixtures remain in the local fixtures directory for inspection. The Studio -UiSmoke exercises the queue buttons against an isolated temporary store.
