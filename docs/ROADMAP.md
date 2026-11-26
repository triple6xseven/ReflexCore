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

**C. Skill Composition Engine** will map typed outputs to Goal edges with bounded
steps, deadlines and cancellation. **D. Skill Discovery and Acquisition** will
admit discovered candidates only after fixture validation and operator approval.
**E. Skill Memory and Compatibility** will namespace experience by binding and
verifier compatibility. **F. Skill SDK and Ecosystem** will validate versioned
manifests against explicitly trusted adapters. Review transfer evidence before C.
