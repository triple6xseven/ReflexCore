# Emergency stop and application allowlist

## Emergency stop

Press **Ctrl+Alt+F10** while the ReflexCore tray is running. The tray immediately requests cancellation of the running supervised job and cancels queued jobs. It also broadcasts a project-local stop signal. Shared Control consumes it to release held input and cancel its active session. ReflexVision closes and publishes a stopped observation. The managed CS 1.6 practice panel cancels an active run or aborts a pending server start. The procedure starts cooperatively and consumers check the signal on their timers. Command consumption atomically claims the legacy control file before reading it. For queued workers, Studio shows Stopping until worker termination and the terminal receipt. Cancellation can report an unknown effect when a dispatched action might have completed. The tray starts any required owned-tree fallback asynchronously, and reports timeout if cleanup outlives the deadline. Shared Control, ReflexVision, and the practice panel continue to report their stop state in their own interfaces.

The same action is in the tray under **More → Emergency stop**. When opened independently, ReflexVision attempts to register the hotkey itself and broadcasts the same stop signal. **Stop Capture** only closes ReflexVision. **Ctrl+Alt+P** stops the current tray job. **Stop all · Reflex + Ollama** also requests unloading models from local Ollama, which can affect other clients. Ctrl+Alt+F10 leaves resident Ollama models loaded.

This stop applies to supervised tasks and the modules listening for the signal in this copy of the project. Independent processes and unmanaged command-line sessions retain their own controls. New tasks can be started manually after cancellation.

## Application allowlist

| Feature | Allowed target and checks |
| --- | --- |
| Notepad skill and VisionLoop input demo | The verified foreground Windows Notepad editor for the task, with its unique document token and expected UI Automation editor. Visible input requires opt-in. |
| ReflexVision for CS 1.6 | A selected foreground window owned by process `hl` or `cstrike`. The preview startup probe checks a local listen server owned by that PID with one human player. This grants capture only. |
| Shared Control gameplay input | The supported foreground game or verified Citadel fixture under the existing consent and foreground checks. Only configured gameplay keys are allowed. |
| Managed CS 1.6 practice | The configured isolated loopback test server and the run-owned actor through the practice adapter. |

App names returned by a model do not expand these permissions. The allowlist lives in the adapters and does not accept arbitrary executable names from Studio.
