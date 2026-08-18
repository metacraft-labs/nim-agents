## Coverage for :proc:`loadSession` — re-opening an *existing* agent
## session through the backend-agnostic :type:`AgentClient` (RV-6).
##
## ``nim-agents`` could already start a session and read a live one; it
## could not open one that had already finished.  That is what a
## CodeTracer review needs: a review dataset names the session that
## produced it, and opening the review must show what the agent actually
## did — fetched from the backend on demand, never copied into the
## dataset.  The two backends start from very different places, so the
## point of these cases is that a *caller* cannot tell them apart:
##
##   * ACP  — the protocol's ``session/load``, which is optional and must
##     be capability-checked;
##   * Harbor — ``readSessionEvents(sessionId)``, which has always been
##     able to read any session by id.
##
## *Test double justification (workspace policy: every mock must be
## justified in the test file's header).*  Two seams are simulated, both
## of them the ones this repo already uses for every other case in the
## suite, and both of them *real implementations of the boundary* rather
## than behaviour-verifying mocks:
##
##   * :type:`FakeAcpTransport` from ``nim_acp/fake.nim`` — shipped
##     library code that speaks the real JSON-RPC framing through the
##     real encode/decode path.  A real ACP agent is unusable here: it
##     needs credentials and network, costs minutes per case, and cannot
##     be asked to *withhold* the ``loadSession`` capability or to have
##     pruned a session — which three of these cases must observe.
##   * an in-process :type:`HttpTransport` closure for Agent Harbor —
##     the transport seam ``nim-agent-harbor`` is designed around, and
##     the one every Harbor case in ``test_agents.nim`` already uses.
##     It returns real HTTP status codes and a real SSE body, so the
##     production parser, status handling and event mapping all run.
##
## Nothing in the code under test is stubbed: the request encoding, the
## capability bookkeeping, the SSE parse, the event translation and the
## failure classification are the production ones.  Only the remote
## agent is simulated, which is the boundary this repo does not own.

import std/json
import std/strutils
import unittest
import nim_everywhere
import nim_acp
import nim_agents

const HarborSessionEvents =
  "event: message\n" &
  "data: {\"type\":\"thought\",\"message\":\"reading the failing test\"}\n\n" &
  "event: message\n" &
  "data: {\"type\":\"tool_use\",\"tool_name\":\"bash\"," &
  "\"tool_execution_id\":\"tool-3\",\"status\":\"started\"}\n\n" &
  "event: message\n" &
  "data: {\"type\":\"log\",\"message\":\"fixed the off-by-one\"}\n\n" &
  "event: message\n" &
  "data: {\"type\":\"status\",\"status\":\"completed\"}\n\n"

proc harborHistoryTransport(knownSession: string): HttpTransport =
  ## Answers the events endpoint for exactly one session id and 404s for
  ## every other, which is what a pruned session looks like over REST.
  proc(req: HttpRequest): HttpResponse =
    if req.httpMethod == hmGet and
        req.url.contains("/api/v1/sessions/" & knownSession & "/events"):
      return HttpResponse(status: 200, body: HarborSessionEvents)
    HttpResponse(status: 404, body: "session not found")

suite "nim-agents loadSession":
  test "agents_load_session_replays_an_acp_session_by_id":
    ## The ACP arm: a session the agent already holds comes back as
    ## ordinary :type:`AgentEvent` values — the same type
    ## :proc:`readAgentEvents` produces for a live session, so a caller
    ## renders a finished session and a running one with one code path.
    let fake = newFakeAcpTransport()
    fake.scriptSession("session-abc", @[
      thoughtChunk("reading the failing test"),
      toolCall("tool-3", "Run tests", """{"cmd":"just test"}"""),
      toolCallUpdate("tool-3", "completed", "12 passed"),
      messageChunk("fixed the off-by-one"),
      statusUpdate("completed")
    ])
    var client = fromAcp(newAcpClient(fake))

    let loaded = client.loadSession("session-abc", cwd = "/work/repo")
    check loaded.state == aslsLoaded
    check loaded.session.id == "session-abc"
    check loaded.session.backend == abkAcp
    check loaded.message.len == 0
    check loaded.events.len == 5
    check loaded.events[0].kind == aekThoughtChunk
    check loaded.events[0].text == "reading the failing test"
    check loaded.events[1].kind == aekToolCall
    check loaded.events[1].toolCallId == "tool-3"
    check loaded.events[1].toolName == "Run tests"
    check loaded.events[2].kind == aekToolCallUpdate
    check loaded.events[2].status == "completed"
    check loaded.events[3].kind == aekMessageChunk
    check loaded.events[3].text == "fixed the off-by-one"
    check loaded.events[4].kind == aekCompleted
    for event in loaded.events:
      check event.sessionId == "session-abc"

  test "agents_load_session_negotiates_the_acp_handshake_itself":
    ## ACP requires ``initialize`` before any other method and the
    ## capability check needs its answer, but a caller that only wants to
    ## read a finished session should not have to know that.  The wire
    ## proves the handshake happened.
    let fake = newFakeAcpTransport()
    fake.scriptSession("session-abc", @[messageChunk("replayed")])
    var client = fromAcp(newAcpClient(fake))
    check not fake.initialized
    let loaded = client.loadSession("session-abc")
    check fake.initialized
    check loaded.state == aslsLoaded
    check loaded.events.len == 1

  test "agents_load_session_reports_an_agent_that_cannot_replay_sessions":
    ## An agent without the optional capability is an *explicit* state,
    ## not an empty transcript: "this agent cannot replay sessions" is a
    ## different fact from "the agent did nothing", and a caller must be
    ## able to say which it is.
    let fake = newFakeAcpTransport()
    fake.supportsLoadSession = false
    fake.scriptSession("session-abc", @[messageChunk("unreachable")])
    var client = fromAcp(newAcpClient(fake))

    let loaded = client.loadSession("session-abc")
    check loaded.state == aslsUnsupported
    check loaded.events.len == 0
    check loaded.message.len > 0
    check loaded.message.contains("loadSession")
    # Refused before the wire — the agent was never asked.
    check fake.loadedSessions.len == 0

  test "agents_load_session_reports_a_pruned_acp_session":
    ## The other unresolvable case, and it must be distinguishable from
    ## the one above: the agent answered, and its answer was "no such
    ## session".
    let fake = newFakeAcpTransport()
    var client = fromAcp(newAcpClient(fake))
    let loaded = client.loadSession("session-long-gone")
    check loaded.state == aslsUnavailable
    check loaded.events.len == 0
    check loaded.message.contains("session-long-gone")

  test "agents_load_session_distinguishes_an_empty_session_from_a_missing_one":
    ## A session the agent holds but which carries nothing loads
    ## *successfully* with no events.  Conflating this with a failure
    ## (or a failure with this) is the defect the state enum exists to
    ## prevent.
    let fake = newFakeAcpTransport()
    fake.scriptSession("session-empty", @[])
    var client = fromAcp(newAcpClient(fake))
    let loaded = client.loadSession("session-empty")
    check loaded.state == aslsLoaded
    check loaded.events.len == 0
    check loaded.message.len == 0

  test "agents_load_session_reads_a_harbor_session_by_id":
    ## The Harbor arm of the *same* API: a different protocol, the same
    ## return value.  The assertions below are deliberately the shape of
    ## the ACP ones.
    var client = fromHarbor(newHarborClient("http://harbor.invalid",
      harborHistoryTransport("session-harbor")))
    let loaded = client.loadSession("session-harbor", cwd = "/work/repo")
    check loaded.state == aslsLoaded
    check loaded.session.id == "session-harbor"
    check loaded.session.backend == abkHarbor
    check loaded.events.len == 4
    check loaded.events[0].kind == aekThoughtChunk
    check loaded.events[0].text == "reading the failing test"
    check loaded.events[1].kind == aekToolCall
    check loaded.events[1].toolCallId == "tool-3"
    check loaded.events[2].kind == aekMessageChunk
    check loaded.events[2].text == "fixed the off-by-one"
    check loaded.events[3].kind == aekCompleted
    for event in loaded.events:
      check event.sessionId == "session-harbor"

  test "agents_load_session_reports_a_missing_harbor_session":
    ## Harbor's 404 becomes the same explicit unavailable state the ACP
    ## arm produces, so a caller's rendering does not branch on backend.
    var client = fromHarbor(newHarborClient("http://harbor.invalid",
      harborHistoryTransport("session-harbor")))
    let loaded = client.loadSession("session-elsewhere")
    check loaded.state == aslsUnavailable
    check loaded.events.len == 0
    check loaded.message.len > 0

  test "agents_load_session_state_renders_as_a_stable_string":
    ## The state crosses a process boundary in CodeTracer (``ct``
    ## resolves the session, the renderer paints it), so its spelling is
    ## part of the contract rather than an implementation detail.
    check $aslsLoaded == "loaded"
    check $aslsUnsupported == "unsupported"
    check $aslsUnavailable == "unavailable"
    check parseAgentSessionLoadState("unsupported") == aslsUnsupported
    check parseAgentSessionLoadState("nonsense") == aslsUnavailable

  test "agents_load_session_events_survive_a_json_round_trip":
    ## The same boundary: the resolved transcript is handed to another
    ## process as JSON, so the projection has to be lossless for the
    ## fields a conversation view renders.
    let fake = newFakeAcpTransport()
    fake.scriptSession("session-json", @[
      toolCall("tool-9", "Edit file", """{"path":"src/main.nim"}"""),
      messageChunk("done")
    ])
    var client = fromAcp(newAcpClient(fake))
    let loaded = client.loadSession("session-json")
    let node = loaded.toJson()
    check node["state"].getStr() == "loaded"
    check node["sessionId"].getStr() == "session-json"
    check node["backend"].getStr() == "acp"
    check node["events"].len == 2
    check node["events"][0]["kind"].getStr() == "tool_call"
    check node["events"][0]["toolName"].getStr() == "Edit file"
    check node["events"][1]["text"].getStr() == "done"

    let restored = agentSessionLoadFromJson(node)
    check restored.state == aslsLoaded
    check restored.session.id == "session-json"
    check restored.session.backend == abkAcp
    check restored.events.len == 2
    check restored.events[0].kind == aekToolCall
    check restored.events[0].toolName == "Edit file"
    check restored.events[1].text == "done"
