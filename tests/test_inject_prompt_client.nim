## Inject-prompt wrapper tests at the :type:`AgentClient` surface
## (CMP-M3b).
##
## The :type:`AgentClient` thin-wraps the underlying ACP transport's
## queue.  These tests pin the contract:
##
##   * For the ACP backend, ``injectPrompt`` / ``peekQueuedInjections``
##     / ``takeQueuedInjections`` pass straight through to the
##     transport-level queue.  We build the client via
##     :proc:`fromCodexAcp` to exercise the production path; if
##     ``codex-acp`` is not on PATH the test is skipped — never failed
##     — same convention as the other Codex smoke test.
##   * For the Harbor backend, all three procs raise :type:`AcpError`
##     with "not supported" in the message because Harbor's HTTP/SSE
##     model doesn't have an obvious inject point yet.

when defined(js):
  {.error: "Inject-prompt client tests are native-only.".}

import std/[os, strutils, unittest]
import nim_everywhere
import nim_agents

# --------------------------------------------------------------------------- #
#  Codex resolver — identical to test_codex_acp_smoke.
# --------------------------------------------------------------------------- #

const candidateBinaries = ["codex-acp"]

proc resolveCodexBinary(): string =
  let envOverride = getEnv("ISONIM_CODEX_ACP_CMD")
  if envOverride.len > 0:
    let resolved =
      if fileExists(envOverride): envOverride
      else: findExe(envOverride)
    return resolved
  for c in candidateBinaries:
    let resolved = findExe(c)
    if resolved.len > 0:
      return resolved
  ""

# --------------------------------------------------------------------------- #
#  Suite.
# --------------------------------------------------------------------------- #

suite "AgentClient inject-prompt wrappers":

  test "test_agent_client_inject_through_acp_backend":
    ## Build an :type:`AgentClient` over a real (or stubbed) codex-acp
    ## transport; inject text; peek + take through the AgentClient
    ## API; assert pass-through to the underlying transport's queue.
    ##
    ## Skipped — never failed — when codex-acp is not on PATH (same
    ## convention as ``test_codex_acp_smoke``).
    let binary = resolveCodexBinary()
    if binary.len == 0:
      checkpoint "Skipping: codex-acp is not on PATH; enter the isonim " &
        "dev shell or set ISONIM_CODEX_ACP_CMD."
      skip()
    else:
      var spawned = false
      var transport: NativeStdioAcpTransport
      try:
        transport = newNativeStdioAcpTransport(binary, @[])
        spawned = true
      except AcpError as e:
        checkpoint "Skipping: could not spawn codex-acp: " & e.msg
        skip()
      if spawned:
        try:
          var agents = fromAcp(newAcpClient(transport))
          # No session/new round-trip needed — the injection queue is a
          # pure client-side data structure keyed by session id, so we
          # can use any string here.
          let sid = "test-session-abc"
          agents.injectPrompt(sid, "follow up: please add a test")
          agents.injectPrompt(sid, "and a comment")
          # Peek must not drain.
          let peeked = agents.peekQueuedInjections(sid)
          check peeked.len == 2
          check peeked[0] == "follow up: please add a test"
          check peeked[1] == "and a comment"
          # Peek again returns the same thing.
          check agents.peekQueuedInjections(sid).len == 2
          # Take drains FIFO.
          let drained = agents.takeQueuedInjections(sid)
          check drained.len == 2
          check drained[0] == "follow up: please add a test"
          check drained[1] == "and a comment"
          # Subsequent take is empty.
          check agents.takeQueuedInjections(sid).len == 0
          # The underlying transport's queue sees the same view.
          check transport.peekQueuedInjections(sid).len == 0
        finally:
          try: transport.close() except CatchableError: discard

  test "test_agent_client_inject_harbor_raises_acp_error":
    ## Harbor backend: inject / take / peek all raise
    ## :type:`AcpError` with "not supported" in the message.  Uses a
    ## stub harbor URL — we never actually round-trip, the wrappers
    ## reject before any HTTP call would fire.
    proc nullTransport(req: HttpRequest): HttpResponse =
      HttpResponse(status: 404, body: "not found")
    var agents = fromHarbor(newHarborClient("http://localhost:0",
                                            nullTransport))
    try:
      agents.injectPrompt("sid", "hello")
      check false  # unreachable
    except AcpError as e:
      check e.msg.toLowerAscii().contains("not supported")
    try:
      discard agents.takeQueuedInjections("sid")
      check false
    except AcpError as e:
      check e.msg.toLowerAscii().contains("not supported")
    try:
      discard agents.peekQueuedInjections("sid")
      check false
    except AcpError as e:
      check e.msg.toLowerAscii().contains("not supported")
