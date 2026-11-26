## nim_agents/agent_tabs.nim
##
## CodeTracer's agentic-coding tabs as data, with no UI and no signals: the
## backend and lifecycle of each tab's session, its events and evidence, and
## the tab list with its active tab. Moved from CodeTracer's
## `viewmodel/store/types.nim` (CTF-M1 slice 7) with `findSession` and
## `captionForSession` from `agentic_session_vm.nim`; `store/types` re-exports
## it. CTF-M3 folds `AgentSessionsState` into `SessionDirectory` (D87).
##
## The comments below are the ones the types carried in CodeTracer.

type
  AgentServiceBackend* = enum
    ## Backend used by a CodeTracer agentic session.  Kept independent from
    ## nim-agents so the store remains a renderer-neutral data model.
    asbAcp
    asbHarbor

  AgentServiceLifecycle* = enum
    ## Normalized lifecycle shown by tabs, caption progress, and activity.
    aslDisconnected
    aslConnecting
    aslRunning
    aslCompleted
    aslCancelled
    aslError

  AgentServiceEventKind* = enum
    aseConnection
    aseMessage
    aseThought
    asePlan
    aseTool
    aseFileEdit
    aseDiff
    aseWorkspace
    aseProgress
    aseCompleted
    aseCancelled
    aseError
    aseStatus

  AgentServiceEvidenceState* = enum
    asesNone
    asesReady
    asesNoRecording
    asesFailedTests
    asesMalformedMetadata
    asesDiffTraceMismatch

  AgentServiceEventEntry* = object
    id*: string
    kind*: AgentServiceEventKind
    text*: string
    status*: string
    toolName*: string
    toolCallId*: string
      ## AA-3 — `AgentEvent.toolCallId`, kept so a *live* session can pair a
      ## tool call with the update that reports its outcome exactly as a
      ## replayed one can (`ReviewSessionEvent.toolCallId`).  Without it the
      ## two paths would answer "did this command succeed?" differently.
    filePath*: string
    diff*: string
    milestoneCompleted*: int
    milestoneTotal*: int

  AgentServiceEvidenceFileEntry* = object
    path*: string
    status*: string
    linesAdded*: int
    linesRemoved*: int
    diff*: string

  AgentServiceEvidenceEntry* = object
    traceId*: string
    tracePath*: string
    testName*: string
    testCommand*: string
    workspacePath*: string
    datasetPath*: string
      ## RV-7 — the `review.json` this evidence handed over, as resolved by
      ## `ct agent evidence <PATH>`.  Kept so a session can be re-opened on
      ## the dataset itself rather than on the summary projected out of it.
    state*: AgentServiceEvidenceState
    statusMessage*: string
    files*: seq[AgentServiceEvidenceFileEntry]

  AgentServiceSessionEntry* = object
    ## One agentic-coding tab/session tracked by the shared ViewModel store.
    tabId*: string
    sessionId*: string
    taskId*: string
    backend*: AgentServiceBackend
    lifecycle*: AgentServiceLifecycle
    title*: string
    prompt*: string
    evidenceCommand*: string
    workspacePath*: string
    workingCopyMode*: string
    milestonesCompleted*: int
    milestonesTotal*: int
    events*: seq[AgentServiceEventEntry]
    evidence*: AgentServiceEvidenceEntry

  AgentSessionsState* = object
    activeTabId*: string
    sessions*: seq[AgentServiceSessionEntry]

proc findSession*(state: AgentSessionsState; tabId: string):
    AgentServiceSessionEntry =
  ## The session of tab `tabId`, or an empty entry when no tab has that id.
  for session in state.sessions:
    if session.tabId == tabId:
      return session
  AgentServiceSessionEntry()

proc captionForSession*(session: AgentServiceSessionEntry): string =
  ## A tab's caption: its title, else its tab id, else "Agent task", followed
  ## by the plan's progress (`2/5`) when the session follows a plan.
  result =
    if session.title.len > 0: session.title
    elif session.tabId.len > 0: session.tabId
    else: "Agent task"
  if session.milestonesTotal > 0:
    result.add " " & $session.milestonesCompleted & "/" &
      $session.milestonesTotal
