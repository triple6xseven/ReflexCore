# Engineering roadmap

| Release | Milestone |
| --- | --- |
| 0.8.1 | Performance Instrumentation |
| 0.8.2 | Native Execution Sessions |
| 0.8.3 | Universal Skill Runtime |
| 0.8.4 | World State Engine |
| 0.8.5 | Adaptive Cognitive Router |
| 0.9 | Continual Learning Engine |
| 1.0 | Unified Cognitive Engine |

0.8.3 begins with **A. Universal Skill Foundation** and **B. Cross-Application Transfer**.
Keep the existing Rust registry, Flow supervisor, isolated UIA worker and queue.
Move exact saved-text verification behind a capability contract. Keep the foreground
Notepad supervisor and the owned background WinForms adapter responsible for their
own mutations. A negative or ambiguous observation must stop progression.

**C. Skill Composition Engine** now binds the editor's verified save to the queue
attempt that requested it. The next Goal edge must recheck the saved artifact
before it authorizes a second skill. Steps, deadlines and cancellation stay
bounded. **D. Skill Discovery and Acquisition** will
admit discovered candidates only after fixture validation and operator approval.
**E. Skill Memory and Compatibility** will namespace experience by binding and
verifier compatibility. **F. Skill SDK and Ecosystem** will validate versioned
manifests against explicitly trusted adapters.

## Phase C qualification and the next implementation

Studio and MCP approvals, immutable attempts, the Notepad consent boundary, and the runtime's readback evidence have passed interactive qualification. Both supervisor crash intervals and the independent editor-to-readback benchmark are documented in UNIVERSAL-SKILL-RUNTIME.md and BENCHMARKS.md. Final release acceptance uses the exact published Windows CI result.

The first Phase D executable checkpoint is read-only candidate discovery. Add a CLI entry that consumes a bounded descriptor from an owned unfamiliar-application fixture. Emit a candidate with its verified application binding, typed inputs and outputs, required capabilities and verifier identity. A fixture with an ambiguous application, an undeclared capability or an absent verifier must be rejected. The command must neither register a candidate nor enqueue work. Admission and execution remain later steps.
