## Real native threads and TCP HTTP exercise admission and terminal-state races.
## Only Harbor is a controlled protocol peer so streams can stop at exact barriers;
## clients, shared runtime locks and stream completion execute production code.
import std/[os, osproc, streams, tempfiles, strutils, atomics, times]
import nim_agents

type Work = object
  session: AgentSession
  url: string
  done: Atomic[bool]
  failed: Atomic[bool]
proc promptThread(work: ptr Work) {.thread.} =
  {.cast(gcsafe).}:
    try:
      var client = fromHarbor(newNativeHarborClient(work.url))
      discard client.sendPrompt(work.session, @[textBlock("followup")])
    except CatchableError:
      work.failed.store(true)
    work.done.store(true)
proc closeThread(work: ptr Work) {.thread.} =
  {.cast(gcsafe).}:
    try:
      var client = fromHarbor(newNativeHarborClient(work.url))
      client.closeSession(work.session)
    except CatchableError:
      work.failed.store(true)
    work.done.store(true)
proc barrier(path: string) =
  let deadline = epochTime()+10
  while not fileExists(path):
    doAssert epochTime()<deadline, path
    sleep(2)
for terminal in ["paused", "failed"]:
  let root = createTempDir("harbor-thread-race-", "")
  writeFile(root/"terminal",terminal)
  let peer = startProcess("python3", args = @[currentSourcePath().parentDir/"harbor_lifecycle_peer.py",root], options={poUsePath,poStdErrToStdOut})
  try:
    let url = "http://127.0.0.1:" & peer.outputStream.readLine().strip()
    var client = fromHarbor(newNativeHarborClient(url))
    let session = client.createSession(AgentStartMode(workspace: defaultWorkspaceContext(root),
      prompt: @[textBlock("first")], acpAgent: acpAgentConfig("provider")))
    discard client.streamAgentTurn(session,nil)
    var work = Work(session:session,url:url)
    var worker: Thread[ptr Work]
    createThread(worker,promptThread,addr work)
    barrier(root/"admitted")
    doAssert not work.done.load(), "nonstream returned before terminal event"
    var rejected = false
    try: discard client.sendPrompt(session,@[textBlock("competing")])
    except HarborError: rejected = true
    doAssert rejected
    doAssert readFile(root/"deliveries") == "prompt\n"
    var closing = Work(session:session,url:url)
    var closingWorker: Thread[ptr Work]
    createThread(closingWorker,closeThread,addr closing)
    let closeDeadline = epochTime()+10
    while session.runtime.lifecycle != aslClosing:
      doAssert epochTime()<closeDeadline
      sleep(2)
    doAssert not fileExists(root/"stopped"), "close overtook admitted delivery"
    writeFile(root/"release-admission", "")
    joinThread(closingWorker)
    doAssert not closing.failed.load()
    doAssert fileExists(root/"stopped")
    doAssert session.runtime.lifecycle == aslClosed
    writeFile(root/"release","")
    joinThread(worker)
    doAssert not work.failed.load()
    doAssert session.runtime.lifecycle == aslClosed
    doAssert session.runtime.turn == atsIdle
    let callbackSession = client.createSession(AgentStartMode(workspace: defaultWorkspaceContext(root),
      prompt: @[textBlock("callback close")], acpAgent: acpAgentConfig("provider")))
    var closer = fromHarbor(newNativeHarborClient(url))
    var closedFromCallback = false
    let callback: AgentEventCallback = proc(event: AgentEvent) {.gcsafe.} =
      {.cast(gcsafe).}:
        if not closedFromCallback:
          closer.closeSession(callbackSession)
          closedFromCallback = true
    discard client.streamAgentTurn(callbackSession, callback)
    doAssert closedFromCallback
    doAssert callbackSession.runtime.lifecycle == aslClosed
    echo "PASS concurrent admission and close racing ",terminal," ",root
  finally:
    peer.terminate(); discard peer.waitForExit(); peer.close()
