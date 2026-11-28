---
name: reflex-resume
description: Recover an explicitly interrupted ReflexCore development task.
---

Call get_development_context once for the intended component and session. Use the declared next step as historical intent, subject to the current request. Inspect the referenced source if the revision changed. Resolve ambiguous sessions with the operator. Independently inspect any unfinished effect before considering a retry.

Use known_revision only when this session still holds that packet. Apply changes and removals to that packet. If the previous packet is unavailable, ask the tool for the complete current packet. Prefer exact operation identifiers when reconciling pending work.

At task start or recovery, pass the actual session cwd, intended branch, and preflight=yes to get_development_context. Use component=universal for Universal Skill Runtime. Use historical_head only for an intentionally detached exact revision. A branch mismatch requires inspecting the intended worktree before doing any edits. Behind, diverged, offline, and unknown results must remain visible in your decision. Recheck at a worktree, instruction, or integration change. Avoid remote checks and recovery calls for unrelated work.

When the subject is known, request memory_topic. To locate a relevant decision, pass memory_query with a component, relative dependency path, skill ID or short tag on the same bound get_development_context call. Use the cited commit and validity state. Skip retrieval for unrelated tasks. If the local checkpoint is absent, consult docs/ROADMAP.md on the verified branch and distinguish historical acceptance from pending CI.

For repository integration, confirm the qualified main revision and inspect live branch rules before publication. Continue validation on a review branch. Use a pull request and reconcile the exact head's checks before a permitted merge.
