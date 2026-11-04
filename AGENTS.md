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
- `src/nim_agents/agent_harbor/`: the Agent Harbor front-end domain, signal-free and app-agnostic: `fleet_records` (wire records), `session_directory` (the sessions a front-end knows, its lifecycle reducer and its policies: effective status, order, label sources), `activity_digest`, `session_replay` (a session at a moment of its history), `initiatives` (plans parsed as Agent Harbor's server parses them, progress events). Import the modules explicitly; `tests/test_agent_harbor_domain.nim` tests them natively and under JS. Choices front-ends make differently are policies here, never one fixed rule; IsoNim viewmodels over them live in nim-agents-isonim-viewmodels.

This repo re-exports lower-level ACP and Agent Harbor surfaces for advanced callers.
