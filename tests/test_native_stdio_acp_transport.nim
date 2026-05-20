## Phase A smoke test for ``NativeStdioAcpTransport``.
##
## Spawns the real ``claude-code-acp`` (a.k.a. ``claude-agent-acp`` after
## the upstream rename) ACP server, performs a JSON-RPC ``initialize``
## round-trip, and tears the subprocess down cleanly. The test is
## skipped — never failed — when the binary is not on ``PATH``, so
## developers running outside the dev shell don't trip over it.
##
## Set ``ISONIM_ACP_AGENT_CMD`` to override the binary (handy when
## wiring an ACP stub for CI).
when defined(js):
  {.error: "Native stdio ACP transport tests are native-only.".}

import std/[os, unittest]
import nim_agents

const candidateBinaries = ["claude-code-acp", "claude-agent-acp"]

proc resolveAcpBinary(): string =
  let envOverride = getEnv("ISONIM_ACP_AGENT_CMD")
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

suite "NativeStdioAcpTransport against real claude-code-acp":
  test "initialize round-trips against the real binary":
    let binary = resolveAcpBinary()
    if binary.len == 0:
      checkpoint "Skipping: neither claude-code-acp nor claude-agent-acp is on PATH; " &
        "enter the isonim dev shell or set ISONIM_ACP_AGENT_CMD."
      skip()
    else:
      var transport: NativeStdioAcpTransport
      var spawned = false
      try:
        transport = newNativeStdioAcpTransport(binary, @[])
        spawned = true
      except AcpError as e:
        checkpoint "Skipping: could not spawn ACP server: " & e.msg
        skip()
      if spawned:
        try:
          var client = newAcpClient(transport)
          let response = client.initialize(InitializeRequest(
            protocolVersion: 1,
            clientInfo: ClientInfo(name: "isonim-smoke", version: "0.1.0"),
            clientCapabilities: ClientCapabilities(
              streaming: true,
              images: false,
              audio: false,
              resources: true,
              permissions: true)))
          check response.protocolVersion >= 1
          # claude-agent-acp advertises a non-empty capabilities map. We
          # don't pin individual flags because they evolve with the SDK.
          let caps = response.agentCapabilities
          let anyCapability = caps.streaming or caps.text or caps.images or
            caps.audio or caps.resources or caps.permissions or caps.terminal or
            caps.filesystemRead or caps.filesystemWrite
          check anyCapability
        finally:
          transport.close()

  test "spawn failure surfaces as AcpError when the binary is missing":
    expect AcpError:
      discard newNativeStdioAcpTransport(
        "definitely-not-a-real-acp-binary-" & $getCurrentProcessId(), @[])
