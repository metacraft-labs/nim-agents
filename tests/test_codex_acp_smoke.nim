## Phase C smoke test for the OpenAI Codex ACP adapter
## (``pkgs.codex-acp`` in nixpkgs).
##
## Spawns the real ``codex-acp`` binary via the generic
## :proc:`fromStdioAcpAgent` transport, performs an ACP
## ``initialize`` followed by ``session/new``, and tears the
## subprocess down cleanly.  The ``session/new`` half is the
## load-bearing assertion: ``claude-agent-acp`` regressed there
## under nested CLAUDECODE auth, so we exercise the failing path
## explicitly against the alternative backend.
##
## The test is *skipped* (never failed) when:
##
##   * ``codex-acp`` is not on PATH (enter the isonim dev shell
##     or set ``$ISONIM_CODEX_ACP_CMD``).
##   * the binary spawns but ``initialize`` / ``session/new``
##     reports an authentication error (typically because
##     ``$OPENAI_API_KEY`` is not set / not authorised).
##
## Set ``ISONIM_CODEX_ACP_CMD`` to override the binary (handy
## when wiring a mock for CI without an upstream API call).

when defined(js):
  {.error: "Codex ACP smoke test is native-only.".}

import std/[os, strutils, unittest]
import nim_agents

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

proc looksLikeAuthError(msg: string): bool =
  ## Codex returns "missing API key" / "unauthorized" / "401"
  ## variants when ``$OPENAI_API_KEY`` is unset or rejected.
  ## We treat any of these as "skip, not fail" — the smoke test
  ## proves the JSON-RPC pipe works; downstream auth is not its
  ## contract.
  let lowered = msg.toLowerAscii()
  return lowered.contains("api key") or
         lowered.contains("api_key") or
         lowered.contains("unauthor") or
         lowered.contains("401") or
         lowered.contains("not logged in") or
         lowered.contains("authentication required") or
         lowered.contains("auth_required") or
         lowered.contains("openai_api_key") or
         lowered.contains("missing credentials") or
         lowered.contains("credential")

suite "Codex ACP — initialize + session/new round-trip":
  test "test_initialize_and_session_new_against_real_codex_acp":
    let binary = resolveCodexBinary()
    if binary.len == 0:
      checkpoint "Skipping: codex-acp is not on PATH; enter the isonim " &
        "dev shell (which now exposes pkgs.codex-acp) or set " &
        "ISONIM_CODEX_ACP_CMD."
      skip()
    else:
      # Build the transport explicitly so we can ``close()`` it in
      # ``finally`` no matter which step trips first.  ``fromCodexAcp``
      # encapsulates the same resolution, but it hides the transport
      # inside an AcpClient closure — we want the bare handle here.
      var transport: NativeStdioAcpTransport
      var spawned = false
      try:
        transport = newNativeStdioAcpTransport(binary, @[])
        spawned = true
      except AcpError as e:
        checkpoint "Skipping: could not spawn codex-acp: " & e.msg
        skip()
      if spawned:
        var initialiseOk = false
        var sessionStarted = false
        var sessionId = ""
        var skippedAuth = false
        try:
          var client = newAcpClient(transport)
          try:
            let response = client.initialize(InitializeRequest(
              protocolVersion: 1,
              clientInfo: ClientInfo(name: "isonim-codex-smoke",
                                     version: "0.1.0"),
              clientCapabilities: ClientCapabilities(
                streaming: true,
                images: false,
                audio: false,
                resources: true,
                permissions: true)))
            check response.protocolVersion >= 1
            initialiseOk = true
          except AcpError as e:
            if looksLikeAuthError(e.msg):
              checkpoint "Skipping: codex-acp initialize rejected " &
                "(likely missing OPENAI_API_KEY): " & e.msg
              skippedAuth = true
              skip()
            else:
              raise
          if initialiseOk and not skippedAuth:
            # session/new is the failing-against-claude-agent-acp
            # case we want to prove works against codex-acp.
            try:
              let newSession = client.startSession(
                NewSessionRequest(cwd: getCurrentDir()))
              sessionId = newSession.sessionId
              sessionStarted = true
            except AcpError as e:
              if looksLikeAuthError(e.msg):
                checkpoint "Skipping: codex-acp session/new rejected " &
                  "(likely missing OPENAI_API_KEY): " & e.msg
                skippedAuth = true
                skip()
              else:
                raise
            if not skippedAuth:
              check sessionStarted
              check sessionId.len > 0
        finally:
          try: transport.close() except CatchableError: discard
