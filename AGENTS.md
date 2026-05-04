# nim-agents

Shared composition layer over ACP and Agent Harbor.

Commands:
- `just build`: compile native and JS targets.
- `just test`: run native and JS tests.
- `just lint`: run Nim and Nix checks.
- `just format`: format Nim and Nix sources.

Structure:
- `src/nim_agents/client.nim`: common prompt/session abstraction.
- `tests/test_consumers.nim`: direct IsoNim Editor and CodeTracer-style import smoke tests.

This repo re-exports lower-level ACP and Agent Harbor surfaces for advanced callers.
