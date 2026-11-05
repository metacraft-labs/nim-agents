# nim-agents

`nim-agents` composes `nim-acp` and `nim-agent-harbor` behind a small common interface while preserving access to the raw lower-level clients.

It is intended for direct use from IsoNim Editor, CodeTracer, and other Nim consumers.

### Optional activity state

`import nim_agents/activity` adds a renderer-free conversation reducer. Hosts
provide their own signals and view adapters. `ActivityTimeline.beginTurn` records
an admitted local prompt, and `reduce` consumes normalized `AgentEvent` values.
Tool updates preserve a card identity within a turn; later turns may reuse a tool
ID. Durable event IDs suppress replay. Fixed display labels and editor permission
policy belong to the host view. The default `nim_agents` import remains unchanged.

Tool activity cards retain their initial entry ID, turn and category. Their `data`
is the safe normalized aggregate of the latest tool event: kind, event ID and
source discriminator describe that update; status/output/name/arguments mirror
the card. Empty optional name, arguments, output or status preserve the last
supplied value. Nonempty presentation fields replace their prior snapshot; an
empty list preserves it. Missing session ID preserves session context. Raw frames
remain absent. Provenance-only updates do not change the visible revision.
