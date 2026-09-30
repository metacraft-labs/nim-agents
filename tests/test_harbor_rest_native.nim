## Real loopback HTTP/SSE integration test for the native Harbor backend.
## A controlled Python protocol peer replaces only the remote Harbor service:
## deterministic fragmentation, callback barriers, and exact request assertions
## cannot be obtained from a paid model. HTTP, sockets, the Nim stream parser,
## common event conversion, cursor reuse, and explicit session closure are all real.
## Every run retains its unique directory and HTTP log on failure.
import std/[os, osproc, streams, tempfiles, strutils, unittest]
import nim_agents

proc main() =
  let root = createTempDir("nim-harbor-rest-", "")
  let peer = startProcess("python3", args = @[
    currentSourcePath().parentDir / "harbor_rest_fixture.py", root],
    options = {poUsePath, poStdErrToStdOut})
  defer:
    peer.terminate()
    discard peer.waitForExit()
    peer.close()
  let port = peer.outputStream.readLine().strip()

  suite "native Harbor REST through nim-agents":
    test "fragmented stream is live and subsequent turns resume without replay":
      var client = fromHarbor(newNativeHarborClient("http://127.0.0.1:" & port))
      let config = AgentStartMode(workspace: defaultWorkspaceContext(root),
        prompt: @[textBlock("first")],
        acpAgent: HarborAcpAgentConfig(software: "claude"))
      let session = client.startSession(config)
      check session.id == "session"
      check session.taskId == "task"
      var messages: seq[string]
      let callback: AgentEventCallback = proc(event: AgentEvent) {.gcsafe.} =
        {.cast(gcsafe).}:
          if event.kind == aekMessageChunk:
            messages.add event.text
            writeFile(root / event.text, "callback received before terminal frame")
      check client.streamAgentTurn(session, callback).stopReason == srEndTurn
      check session.eventCursor.value == 2
      check client.sendPromptStreaming(session, @[textBlock("second")], callback).stopReason == srEndTurn
      check session.eventCursor.value == 5
      check messages == @["first", "second"]
      expect HarborError:
        discard client.sendPromptStreaming(session, @[textBlock("reject")], callback)
      check messages == @["first", "second"]
      expect HarborError:
        client.cancelTurn(session)
      check not fileExists(root / "stopped")
      client.closeSession(session)
      check fileExists(root / "stopped")
      echo "REST integration log: ", root / "http.log"

main()
