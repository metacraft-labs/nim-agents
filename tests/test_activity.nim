## Production opt-in activity reducer, native and JS, plus actual REST DTO ->
## safe AgentEvent JSON -> decoded event -> reducer. No mocks: inputs are event
## data, not a replacement client/VM. Verify identity, authorship, turn isolation,
## merged tool results, streamed content, private-field omission and real metrics.
import std/[unittest, json, strutils]
import nim_agents
import nim_agents/[activity, activity_presentation]

suite "Opt-in agent activity":
  test "file edit description survives safe REST wire and message fallback":
    for description in [%"Use shared spacing and preserve the title.", newJNull(), %*{"token": "PRIVATE_PAYLOAD"}]:
      let payload = %*{"type": "file_edit", "file_path": "stories/hero.nim",
        "lines_added": 4, "lines_removed": 2, "message": "Legacy message",
        "description": description, "credential": "PRIVATE_CREDENTIAL"}
      let wire = harborEventToAgentEvent("s", eventFromJson(payload)).toJson()
      let decoded = agentEventFromJson(wire)
      let expected = if description.kind == JString: description.getStr() else: "Legacy message"
      check decoded.kind == aekFileEdit
      check decoded.text == expected
      check not ($wire).contains("PRIVATE_PAYLOAD")
      check not ($wire).contains("PRIVATE_CREDENTIAL")
      var timeline: ActivityTimeline
      check timeline.reduce(decoded)
      check timeline.entries[^1].text == expected
      check timeline.entries[^1].data.raw == nil
      check timeline.entries[^1].data.filePath == "stories/hero.nim"
      check timeline.entries[^1].data.linesAdded == 4
      check timeline.entries[^1].data.linesRemoved == 2

  test "reported connection status is presentation only with heartbeat and terminal semantics intact":
    proc running(id: string): AgentEvent =
      agentEventFromJson(harborEventToAgentEvent("s", eventFromJson(%*{
        "type": "status", "status": "running", "eventId": id})).toJson())
    let event = running("first")
    check event.status == "running"
    check event.state == acsStreaming
    var timeline: ActivityTimeline
    check timeline.reduce(event)
    check timeline.entries[^1].status == "streaming"
    check timeline.entries[^1].data.state == acsStreaming
    check activityPresentation(timeline.entries[^1]).status == "running"
    check activityPresentation(timeline.entries[^1]).tone == "attention"
    let revision = timeline.revision
    check not timeline.reduce(running("heartbeat"))
    check not timeline.reduce(running("heartbeat"))
    check timeline.revision == revision
    check timeline.reduce(AgentEvent(kind: aekThoughtChunk, text: "Working", status: "running"))
    check activityPresentation(timeline.entries[^1]).status == "streaming"
    check timeline.reduce(AgentEvent(kind: aekMessageChunk, text: "Result"))
    check timeline.reduce(AgentEvent(kind: aekCompleted, stopReason: srEndTurn))
    check timeline.entries[1].status == "completed"
    check timeline.entries[2].status == "completed"
    check activityPresentation(timeline.entries[1]).status == "completed"
    check activityPresentation(ActivityEntry(kind: aekConnection,
      status: "connected", data: AgentEvent(state: acsConnected))).status == "connected"

  test "wire preserves typed input provenance without content guessing":
    var timeline: ActivityTimeline
    timeline.beginTurn("same text")
    let human = harborEventToAgentEvent("session", eventFromJson(%*{
      "type": "user_input", "content": "same text", "token": "secret-value"}))
    check human.sourceType == "user_input"
    check not ($human.toJson()).contains("secret-value")
    timeline.reduce(agentEventFromJson(human.toJson()))
    timeline.reduce(AgentEvent(kind: aekMessageChunk, text: "same text"))
    timeline.reduce(AgentEvent(kind: aekMessageChunk, text: " user: literal"))
    check timeline.entries.len == 2
    check timeline.entries[1].role == arAssistant
    check timeline.entries[1].text == "same text user: literal"
  test "tool results update one stable card but repeated IDs in later turns stay separate":
    var timeline: ActivityTimeline
    timeline.beginTurn("first")
    timeline.reduce(AgentEvent(kind: aekToolCall, toolCallId: "tool1",
      toolName: "build", status: "running", toolArguments: "{}"))
    let id = timeline.entries[^1].id
    timeline.reduce(AgentEvent(kind: aekToolCallUpdate, toolCallId: "tool1",
      status: "failed", text: "compiler rejected source"))
    check timeline.entries.len == 2
    check timeline.entries[1].id == id
    check timeline.entries[1].title == "build"
    check timeline.entries[1].status == "failed"
    timeline.beginTurn("retry")
    timeline.reduce(AgentEvent(kind: aekToolCall, toolCallId: "tool1", toolName: "build"))
    check timeline.entries.len == 4
    check timeline.entries[3].id != id
    check timeline.entries[1].status == "failed"
  test "actual tool wire updates keep safe semantic aggregate and provenance current":
    proc decoded(payload: JsonNode): AgentEvent =
      let wire = harborEventToAgentEvent("session", eventFromJson(payload)).toJson()
      check not ($wire).contains("PRIVATE_TOOL_SECRET")
      agentEventFromJson(wire)
    var timeline: ActivityTimeline
    timeline.beginTurn("build")
    timeline.reduce(decoded(%*{"type":"tool_use", "eventId":"use-1",
      "tool_execution_id":"tool-1", "tool_name":"compile", "status":"running",
      "tool_args":{"command":"nim c app.nim", "env":{"TOKEN":"PRIVATE_TOOL_SECRET"}}}))
    let id = timeline.entries[^1].id
    check timeline.entries[^1].data.raw == nil
    timeline.reduce(decoded(%*{"type":"tool_use", "eventId":"use-2",
      "tool_execution_id":"tool-1", "tool_name":"compile revised", "status":"running",
      "tool_args":{"command":"nim c story.nim", "password":"PRIVATE_TOOL_SECRET"}}))
    check timeline.entries[^1].title == "compile revised"
    check timeline.entries[^1].data.toolName == "compile revised"
    check timeline.entries[^1].detail.contains("nim c story.nim")
    check timeline.entries[^1].data.toolArguments == timeline.entries[^1].detail
    let failed = decoded(%*{"type":"tool_result", "eventId":"result-1",
      "tool_execution_id":"tool-1", "status":"failed",
      "tool_output":"Error: undeclared identifier", "config":{"secret":"PRIVATE_TOOL_SECRET"}})
    timeline.reduce(failed)
    let entry = timeline.entries[^1]
    check timeline.entries.len == 2
    check entry.id == id
    check entry.turn == 1
    check entry.kind == aekToolCall # Stable card category, latest event remains typed below.
    check entry.data.kind == aekToolCallUpdate
    check entry.status == "failed"
    check entry.data.status == entry.status
    check entry.text == "Error: undeclared identifier"
    check entry.data.text == entry.text
    check entry.title == "compile revised"
    check entry.data.toolName == entry.title
    check entry.data.toolArguments == entry.detail
    check entry.data.toolArguments.contains("nim c story.nim")
    check entry.data.toolCallId == entry.toolCallId
    check entry.data.sessionId == "session"
    check entry.data.sourceType == "tool_result"
    check entry.data.eventId == "result-1"
    check entry.data.raw == nil
    check not ($entry.data.toJson()).contains("PRIVATE_TOOL_SECRET")
    let revision = timeline.revision
    check not timeline.reduce(failed)
    check timeline.revision == revision
    # A distinct durable envelope with identical visible fields updates semantic
    # provenance but must not announce new visible output or create another card.
    timeline.reduce(decoded(%*{"type":"tool_result", "eventId":"result-2",
      "tool_execution_id":"tool-1", "status":"failed", "tool_output":entry.text}))
    check timeline.revision == revision
    check timeline.entries[^1].data.eventId == "result-2"
    let firstTurnData = $timeline.entries[^1].data.toJson()
    timeline.beginTurn("retry")
    timeline.reduce(decoded(%*{"type":"tool_use", "eventId":"next-turn",
      "tool_execution_id":"tool-1", "tool_name":"retry compile", "status":"running"}))
    check timeline.entries.len == 4
    check timeline.entries[^1].id != id
    check timeline.entries[^1].turn == 2
    check $timeline.entries[1].data.toJson() == firstTurnData
    check timeline.entries[1].status == "failed"

  test "optional safe tool presentation metadata replaces only when supplied":
    # Explicit typed presentation fields are a reducer boundary, not invented
    # Harbor DTO fields: production normalizers own their allowlist. Empty means
    # omitted; a nonempty supplied field list replaces the previous snapshot.
    var timeline: ActivityTimeline
    timeline.reduce(agentEventFromJson(AgentEvent(kind: aekToolCall, toolCallId: "t",
      toolName: "build", toolArguments: "{}", presentationFields: @[
        AgentPresentationField(name: "stage",value: "source")]).toJson()))
    let before = timeline.revision
    timeline.reduce(agentEventFromJson(AgentEvent(kind: aekToolCallUpdate,toolCallId: "t",
      presentationFields: @[AgentPresentationField(name: "stage",value: "check")]).toJson()))
    check timeline.entries.len == 1
    check timeline.entries[0].data.presentationFields == @[AgentPresentationField(name: "stage",value: "check")]
    check timeline.revision == before + 1
    timeline.reduce(agentEventFromJson(AgentEvent(kind: aekToolCallUpdate,toolCallId: "t").toJson()))
    check timeline.entries[0].data.presentationFields == @[AgentPresentationField(name: "stage",value: "check")]
    check timeline.revision == before + 1

  test "durable stream identity deduplicates replay while equal chunks remain content":
    var timeline: ActivityTimeline
    let event = AgentEvent(sessionId: "a", eventId: "21", kind: aekMessageChunk, text: "x")
    timeline.reduce(event)
    timeline.reduce(event)
    timeline.reduce(AgentEvent(sessionId: "a", eventId: "22", kind: aekMessageChunk, text: "x"))
    check timeline.entries[0].text == "xx"
  test "safe tool arguments and usage survive native browser projection":
    let tool = harborEventToAgentEvent("session", eventFromJson(%*{
      "type": "tool_use", "tool_name": "run", "tool_execution_id": "t",
      "tool_args": {"command": "isonim editor state", "env": {"TOKEN": "secret"},
        "nested": {"password": "secret2"}}, "settings": {"secret": "hidden"}}))
    let wire = tool.toJson()
    check not ($wire).contains("secret2")
    check not ($wire).contains("hidden")
    check not ($wire).contains("TOKEN")
    check agentEventFromJson(wire).toolArguments.contains("isonim editor state")
    let llm = harborEventToAgentEvent("session", eventFromJson(%*{
      "type": "llm_request", "model": "actual-model", "usage": {
        "input_tokens": 13, "output_tokens": 7}, "servingCredentialAccount": "private-account"}))
    var timeline: ActivityTimeline
    timeline.reduce(agentEventFromJson(llm.toJson()))
    check timeline.entries[0].data.model == "actual-model"
    check timeline.entries[0].data.inputTokens == 13
    check timeline.entries[0].data.outputTokens == 7
    check not ($llm.toJson()).contains("private-account")
  test "every recognized kind has a meaningful entry and safe unknown types remain visible":
    for kind in AgentEventKind:
      var timeline: ActivityTimeline
      timeline.reduce(AgentEvent(kind: kind, text: "content", status: "running",
        planEntries: @["First", "Second"], filePath: "story.nim", diff: "+added"))
      check timeline.entries.len == 1
      check timeline.entries[0].kind == kind
    var unknown: ActivityTimeline
    unknown.reduce(agentEventFromJson(harborEventToAgentEvent("s", eventFromJson(%*{
      "type": "future_event", "message": "Useful event", "config": {"token": "private"}})).toJson()))
    check unknown.entries[0].text == "Useful event"
    check unknown.entries[0].data.sourceType == "future_event"
  test "questions expose a truthful unavailable response notice":
    var timeline: ActivityTimeline
    timeline.reduce(agentEventFromJson(harborEventToAgentEvent("s", eventFromJson(%*{
      "type": "agent_question", "prompt": "Which story?", "request": "request-id"})).toJson()))
    check timeline.entries[0].data.question == "Which story?"
    check timeline.entries[0].text == "Which story?"
    check timeline.entries[0].data.sourceType == "agent_question"

  test "optional plan entries decode without crashing and malformed data stays diagnostic":
    let message = agentEventFromJson(%*{"kind": "message_chunk", "text": "usable"})
    check message.kind == aekMessageChunk
    check message.planEntries.len == 0
    var timeline: ActivityTimeline
    timeline.reduce(message)
    check timeline.entries[0].text == "usable"
    let malformed = agentEventFromJson(%*{"kind": "plan", "planEntries": {"wrong": "shape"}})
    check malformed.kind == aekError
    check malformed.text == "Malformed agent plan entries"
    check malformed.stopReason == srError
  test "missing usage metrics are unknown and structured argument strings are filtered":
    let absent = harborEventToAgentEvent("s", eventFromJson(%*{
      "type": "llm_request", "model": "reported", "usage": {"source": "unknown"}}))
    check not absent.hasUsage
    let partial = harborEventToAgentEvent("s", eventFromJson(%*{
      "type": "llm_request", "usage": {"outputTokens": 7, "source": "provider_reported"}}))
    check partial.hasUsage
    check partial.inputTokens == -1
    check partial.outputTokens == 7
    check agentEventFromJson(partial.toJson()).usageSource == "provider_reported"
    let stringArgs = harborEventToAgentEvent("s", eventFromJson(%*{
      "type": "tool_use", "tool_args": "{\"command\":\"build\",\"env\":{\"SECRET\":\"hidden-value\"}}"}))
    check stringArgs.toolArguments.contains("build")
    check not stringArgs.toolArguments.contains("hidden-value")
  test "full REST union wait login and context metadata survives safe wire":
    let question = harborEventToAgentEvent("s", eventFromJson(%*{
      "type": "agent_question", "request": "q1", "kind": "choice",
      "prompt": "Which story?", "options": [{"label": "Home", "id": "h"}],
      "credential": "do-not-copy"}))
    let decoded = agentEventFromJson(question.toJson())
    check decoded.question == "Which story?"
    check decoded.presentationFields.len == 3
    check decoded.presentationFields[2].value == "Home"
    check not ($question.toJson()).contains("do-not-copy")
    let login = harborEventToAgentEvent("s", eventFromJson(%*{
      "type": "login_required", "provider": "chatgpt", "request": "login1",
      "surface": "https://private.invalid/?token=do-not-copy"}))
    check agentEventFromJson(login.toJson()).presentationFields[0].value == "chatgpt"
    check not ($login.toJson()).contains("private.invalid")
    let context = harborEventToAgentEvent("s", eventFromJson(%*{
      "type": "context_files", "kind": "snapshot", "totalCount": 1,
      "files": [{"path": "stories.nim", "config": {"secret": "hidden"}}]}))
    check agentEventFromJson(context.toJson()).presentationFields[^1].value == "stories.nim"
    check not ($context.toJson()).contains("hidden")
  test "session REST lifecycle and recovery types stay recognized and private":
    for source in ["session_started", "session_awaiting_input", "session_resumed",
        "session_ended", "proxy_credential_rotated", "proxy_rate_limit_absorbed",
        "dispatcher_restarted", "anti_halting_resume_confirmed", "session_leadership_migrated",
        "participant", "context_injection", "fleet_host", "fleet_fence", "orchestration",
        "delegation", "file_read", "link_spans"]:
      let event = harborEventToAgentEvent("s", eventFromJson(%*{
        "type": source, "message": "actual message", "accountRotatedTo": "private-account",
        "kind": "running", "outcome": "completed", "token": "secret-value"}))
      let decoded = agentEventFromJson(event.toJson())
      check decoded.sourceType == source
      check not ($event.toJson()).contains("private-account")
      check not ($event.toJson()).contains("secret-value")
      var timeline: ActivityTimeline
      timeline.reduce(decoded)
      check timeline.entries.len == 1

  test "visible revision ignores typed input and exact replay but records new chunks":
    var timeline: ActivityTimeline
    timeline.beginTurn("hello")
    let initial = timeline.revision
    let ack = AgentEvent(sessionId: "s", eventId: "ack", kind: aekStatus,
      sourceType: "user_input", text: "hello")
    check not timeline.reduce(ack)
    check timeline.revision == initial
    check not timeline.reduce(ack)
    let chunk = AgentEvent(sessionId: "s", eventId: "first", kind: aekMessageChunk, text: "reply")
    check timeline.reduce(chunk)
    check timeline.revision == initial + 1
    check not timeline.reduce(chunk)
    check timeline.revision == initial + 1
    check timeline.reduce(AgentEvent(sessionId: "s", eventId: "second", kind: aekMessageChunk, text: "reply"))
    check timeline.revision == initial + 2
    check timeline.entries[^1].text == "replyreply"
    check not timeline.reduce(AgentEvent(kind: aekMessageChunk))
    check timeline.revision == initial + 2

  test "Harbor lifecycle heartbeats preserve contiguous words and actual transitions":
    proc status(id, value: string): AgentEvent =
      agentEventFromJson(harborEventToAgentEvent("s", eventFromJson(%*{
        "type":"status", "status":value, "eventId":id})).toJson())
    check status("first", "running").kind == aekConnection
    var timeline: ActivityTimeline
    timeline.beginTurn("first")
    check timeline.reduce(status("first", "running"))
    check timeline.reduce(AgentEvent(kind: aekMessageChunk, sessionId: "s", text: "EAC_ROLE_"))
    let visible = timeline.revision
    check not timeline.reduce(status("heartbeat", "running"))
    check timeline.revision == visible
    check not timeline.reduce(status("heartbeat", "running")) # ignored heartbeat retains durable replay identity
    check timeline.reduce(AgentEvent(kind: aekMessageChunk, sessionId: "s", text: "GUIDANCE"))
    check timeline.entries[^1].text == "EAC_ROLE_GUIDANCE"
    check timeline.entries.len == 3
    check timeline.reduce(AgentEvent(kind: aekStatus, sourceType: "status", sessionId: "s", status: "paused"))
    check timeline.entries[^1].status == "paused"
    check timeline.reduce(AgentEvent(kind: aekStatus, sourceType: "status", sessionId: "s", status: "paused", text: "actual explanation"))
    check timeline.entries[^1].text == "actual explanation"
    check timeline.reduce(AgentEvent(kind: aekStatus, sourceType: "login_required", sessionId: "s", status: "paused"))
    timeline.beginTurn("second")
    check timeline.reduce(AgentEvent(kind: aekStatus, sourceType: "status", sessionId: "s", status: "paused"))
    check timeline.entries[^1].turn == 2

  test "meaningful lifecycle resets plain heartbeat state in same turn and session":
    for transition in [AgentEvent(kind: aekCompleted, stopReason: srEndTurn),
        AgentEvent(kind: aekError, text: "provider failed"),
        AgentEvent(kind: aekCancelled, stopReason: srCancelled),
        AgentEvent(kind: aekConnection, state: acsConnecting, text: "reconnecting"),
        AgentEvent(kind: aekStatus, sourceType: "session_resumed", text: "resumed"),
        AgentEvent(kind: aekStatus, sourceType: "status", status: "running", text: "actual new detail")]:
      var timeline: ActivityTimeline
      timeline.beginTurn("request")
      let running = AgentEvent(kind: aekConnection, sourceType: "status", sessionId: "s", status: "running", state: acsStreaming)
      check timeline.reduce(running)
      check timeline.reduce(transition)
      check timeline.reduce(running)
      let latest = timeline.entries[^1].id
      check not timeline.reduce(running)
      check timeline.entries[^1].id == latest
      var other = running
      other.sessionId = "other"
      check timeline.reduce(other)
      check timeline.reduce(running)
