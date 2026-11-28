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

## Integration checkpoint

Phase C closed at `2b92bff`. [Windows CI 46078707512](https://github.com/triple6xseven/ReflexCore/actions/runs/46078707512) passed on the same revision as the independent orchestration and terminal-commit qualification. The [integration map](INTEGRATION.md) defines the development baseline and the installed runtime boundary.

**Next implementation step:** qualify one discovered binding with independent effect validation on an owned fixture. The read-only discovery candidate was ported after source-branch Windows CI at `0178173`. Check integrated Windows CI before treating the discovery command as qualified. Admission requires independent effect validation and operator review. Phases E and F remain planned.
