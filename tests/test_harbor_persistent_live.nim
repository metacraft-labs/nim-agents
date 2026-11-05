## Opt-in real Harbor REST/provider integration. No substituted HTTP or provider.
## The harness supplies an isolated server and a provider command; barriers allow
## it to verify the actual model-worker PID/starttime stays alive between turns.
import std/[os, strutils, json]
import nim_agents

let url = getEnv("ISONIM_TEST_HARBOR_URL")
let provider = getEnv("ISONIM_TEST_ACP_PROVIDER")
let artifacts = getEnv("ISONIM_TEST_ARTIFACTS")
doAssert url.len > 0 and provider.len > 0 and artifacts.len > 0
createDir(artifacts)
var client = fromHarbor(newNativeHarborClient(url))
var workspace = defaultWorkspaceContext(artifacts)
workspace.workingCopyMode = "in_place"
var args: seq[string]
for arg in parseJson(getEnv("ISONIM_TEST_ACP_ARGS", "[]")):
  args.add arg.getStr()
let session = client.createSession(AgentStartMode(workspace: workspace,
  allowNetwork: true,
  acpAgent: acpAgentConfig(provider, args),
  prompt: @[textBlock("Remember the token ISONIM_CONTEXT_7309 for this conversation. Reply only with that token.")]))
writeFile(artifacts / "session-id", session.id)
var messages = ""
let callback: AgentEventCallback = proc(event: AgentEvent) {.gcsafe.} =
  {.cast(gcsafe).}:
    let log = open(artifacts / "events.jsonl", fmAppend)
    log.writeLine($toJson(event))
    log.close()
    if event.kind == aekMessageChunk: messages.add event.text
let first = client.streamAgentTurn(session, callback)
doAssert first.stopReason == srEndTurn
doAssert session.runtime.lifecycle == aslReady
doAssert session.runtime.turn == atsCompleted
doAssert messages.contains("ISONIM_CONTEXT_7309")
writeFile(artifacts / "first-complete", messages)
for attempt in 0 ..< 1200:
  if fileExists(artifacts / "continue"): break
  sleep(100)
doAssert fileExists(artifacts / "continue"), "Harness did not verify process continuity"
messages = ""
let second = client.sendPromptStreaming(session,
  @[textBlock("What token did I ask you to remember? Reply with that token and the instruction sentinel from your system instructions. Do not read files or use tools.")], callback)
doAssert second.stopReason == srEndTurn
doAssert messages.contains("ISONIM_CONTEXT_7309")
doAssert messages.contains("ISONIM_SYSTEM_9182")
writeFile(artifacts / "second-complete", messages)
for attempt in 0 ..< 1200:
  if fileExists(artifacts / "close"): break
  sleep(100)
doAssert fileExists(artifacts / "close")
client.closeSession(session)
doAssert session.runtime.lifecycle == aslClosed
writeFile(artifacts / "closed", session.id)
