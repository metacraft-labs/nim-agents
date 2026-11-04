## The sessions an Agent Harbor front-end knows, as signal-free state and a
## reducer: the domain every sessions view is built on, whatever its UI
## pattern (a tab strip, a sidebar list, a fleet table, a terminal status
## line).
##
## A `SessionDirectory` holds every session in the order it was first seen.
## It is fed whole listings (`replaceAll`, the answer to
## `GET /api/v1/sessions`, also what a `resync` frame asks for) and the frames
## of the session lifecycle feed (`applyFrame`,
## `GET /api/v1/session-lifecycle/events`: `session_created`,
## `session_status_changed`, `session_completed`, `session_removed`, and the
## `resync` / `caught_up` control frames).
##
## The choices a front-end may legitimately make differently are policies,
## not fixed rules (`SessionPolicy`):
##
## - `EffectiveStatusPolicy`: whether every wait for a person reads "needs
##   input" (the AH WebUI's rule, inventory INV-P2-13/14/19), or whether an
##   ended turn waiting for the next instruction -- the idle prompt, which
##   Agent Harbor reports as a wait from the agent's stop hook -- reads "idle"
##   and only a session blocked on a question, a permission or a login reads
##   "needs input";
## - `SessionOrder`: the order sessions were launched in (tabs must not jump
##   while one is read), or attention first (a fleet list);
## - the label sources, in preference order, a session is titled from when
##   its prompt is withheld.
##
## Grouping by initiative is `groupByPlan` here, over the plan association a
## session carries (`FleetSession.planId`).

import std/[algorithm, strutils, tables]
import ./fleet_records

export fleet_records

type
  SessionAttention* = enum
    ## What a session asks of the reader, in display priority.
    saNeedsInput = "needs-input" ## blocked on a question, a permission gate
                                 ## or a login; or paused
    saIdle = "idle"              ## its turn ended and it waits for the next
                                 ## instruction (only under `espIdlePromptApart`)
    saRunning = "running"
    saQueued = "queued"
    saFailed = "failed"
    saEnded = "ended"

  InputWaitKind* = enum
    ## Why a live session waits, from `awaiting_input_source`.
    iwNone        ## it does not wait
    iwQuestion    ## the agent asked a question (`…:native-question:N`)
    iwPermission  ## a permission gate
    iwLogin       ## a login request
    iwIdlePrompt  ## the agent's turn ended (`claude-stop-hook` and the like)
    iwEstimated   ## inferred by the server's settle heuristic
    iwPaused      ## paused, with no recorded wait
    iwOther       ## a source this front-end does not know

  EffectiveStatusPolicy* = enum
    espNeedsInputWins  ## every wait for a person is "needs input"
    espIdlePromptApart ## an ended turn is "idle"; other waits "needs input"

  SessionOrder* = enum
    soLaunch    ## first seen, then creation time: a stable order
    soAttention ## needs input, idle, running, queued, failed, ended; most
                ## recently active first within each

  LabelSource* = enum
    lsPrompt = "prompt"
    lsName = "name"
    lsBranch = "branch"
    lsWorkspace = "workspace"
    lsId = "id"

  SessionPolicy* = object
    status*: EffectiveStatusPolicy
    order*: SessionOrder
    labels*: seq[LabelSource]
      ## Tried in order; `lsId` always answers, so it is implied last.

  SessionDirectory* = object
    sessions*: seq[FleetSession]
      ## Every known session, in the order it was first seen.
    revision*: int
      ## Moves on every change, so a view can tell a new state from an old.
    resyncing*: bool
      ## A `resync` frame arrived; the next listing replaces the directory.
    caughtUp*: bool
      ## The feed has replayed its journal (`caught_up`).
    index: Table[string, int]

  SessionGroup* = object
    ## Sessions of one plan, by index into `SessionDirectory.sessions`.
    planId*: string  ## "" for the sessions launched for no plan
    indexes*: seq[int]

const
  DefaultLabelSources* = @[lsPrompt, lsName, lsBranch, lsWorkspace, lsId]

proc defaultSessionPolicy*(): SessionPolicy =
  ## The AH WebUI's choices: every wait reads "needs input", attention first.
  SessionPolicy(status: espNeedsInputWins, order: soAttention,
                labels: DefaultLabelSources)

proc tabStripSessionPolicy*(): SessionPolicy =
  ## A tab strip's choices: tabs keep their launch order, and an ended turn
  ## reads "idle" so the warning mark is kept for a session that is blocked.
  SessionPolicy(status: espIdlePromptApart, order: soLaunch,
                labels: DefaultLabelSources)

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

proc inputWaitKind*(session: FleetSession): InputWaitKind =
  ## What a live session waits for. Agent Harbor names the wait by its source:
  ## a request id `<session>:<kind>:<n>` (`native-question`,
  ## `permission-request`, `login-request`), a hook (`claude-stop-hook`: the
  ## turn ended), or `settle` when it only inferred the wait.
  if not session.status.isActive: return iwNone
  if not session.awaitingInput:
    return if session.status == fsPaused: iwPaused else: iwNone
  let source = session.awaitingInputSource.toLowerAscii
  if "settle" in source: iwEstimated
  elif "stop-hook" in source or "stop hook" in source or "idle" in source or
      "turn-end" in source or "end-turn" in source: iwIdlePrompt
  elif "question" in source: iwQuestion
  elif "permission" in source or "approval" in source: iwPermission
  elif "login" in source: iwLogin
  else: iwOther

proc attentionOf*(session: FleetSession;
                  policy = espNeedsInputWins): SessionAttention =
  ## The session's effective state under `policy`. A session that waits for
  ## a person outranks its wire status in both policies; they differ only on
  ## an ended turn.
  let wait = session.inputWaitKind
  if wait != iwNone:
    if wait == iwIdlePrompt and policy == espIdlePromptApart: saIdle
    else: saNeedsInput
  else:
    case session.status
    of fsRunning, fsProvisioning, fsResuming, fsPausing, fsStopping: saRunning
    of fsQueued: saQueued
    of fsFailed, fsCancelled: saFailed
    of fsPaused: saNeedsInput
    else: saEnded

proc statusLabelOf*(session: FleetSession;
                    policy = espNeedsInputWins): string =
  ## The status word a front-end shows. Under `espNeedsInputWins` this is
  ## `effectiveStatusLabel` exactly; under `espIdlePromptApart` an ended turn
  ## reads "idle".
  case session.attentionOf(policy)
  of saIdle: "idle"
  of saNeedsInput:
    if session.inputWaitKind == iwEstimated: "needs input (estimated)"
    else: "needs input"
  else: session.effectiveStatusLabel

proc waitDescription*(session: FleetSession): string =
  ## A tooltip's words for why the session waits; "" when it does not.
  case session.inputWaitKind
  of iwNone: ""
  of iwQuestion: "the agent asked a question"
  of iwPermission: "the agent asks for a permission"
  of iwLogin: "the agent needs a login"
  of iwIdlePrompt: "the agent finished its turn and waits for the next instruction"
  of iwEstimated: "the agent seems to wait (estimated from its silence)"
  of iwPaused: "the session is paused"
  of iwOther: "waiting for: " & session.awaitingInputSource

# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------

proc shortIdOf*(id: string): string =
  if id.len > 8: id[0 ..< 8] else: id

proc titleOf*(session: FleetSession;
              sources: openArray[LabelSource] = DefaultLabelSources):
    tuple[text: string, source: LabelSource] =
  ## What a session is called, from the first of `sources` that has a value:
  ## the prompt's first line; when the prompt is withheld or empty, what a
  ## person calls the session -- its name, branch, workspace; and only when
  ## nothing is known, `Session <short id>`. Every session gets a title.
  for source in sources:
    case source
    of lsPrompt:
      if session.prompt.strip.len > 0:
        return (session.prompt.strip.splitLines()[0], lsPrompt)
    of lsName:
      if session.name.strip.len > 0: return (session.name.strip, lsName)
    of lsBranch:
      if session.branch.strip.len > 0: return (session.branch.strip, lsBranch)
    of lsWorkspace:
      if session.workspaceName.strip.len > 0:
        return (session.workspaceName.strip, lsWorkspace)
    of lsId:
      break
  ("Session " & shortIdOf(session.id), lsId)

proc originLabel*(origin: string): string =
  ## A front-end id as a reader names it; an id this front-end does not know
  ## is shown as it is.
  case origin.toLowerAscii
  of "": ""
  of "cli": "CLI"
  of "ah-lite", "lite": "ah-lite"
  of "webui", "ah-webui", "web": "WebUI"
  of "tui", "ah-tui": "TUI"
  of "gui", "ah-gui": "AH app"
  of "telegram": "Telegram"
  of "codetracer": "CodeTracer"
  else: origin

proc originShortLabel*(origin: string): string =
  ## The origin as a tab has room for it: `CLI`, `Web`, `TUI`, `Lite`,
  ## `App`, `Tg`, `CT`; an unknown id cut to six characters.
  case origin.toLowerAscii
  of "": ""
  of "cli": "CLI"
  of "ah-lite", "lite": "Lite"
  of "webui", "ah-webui", "web": "Web"
  of "tui", "ah-tui": "TUI"
  of "gui", "ah-gui": "App"
  of "telegram": "Tg"
  of "codetracer": "CT"
  else: (if origin.len > 6: origin[0 ..< 6] else: origin)

# ---------------------------------------------------------------------------
# The reducer
# ---------------------------------------------------------------------------

proc initSessionDirectory*(): SessionDirectory =
  SessionDirectory(index: initTable[string, int]())

proc reindex(dir: var SessionDirectory) =
  dir.index.clear()
  for i, session in dir.sessions:
    dir.index[session.id] = i

proc len*(dir: SessionDirectory): int = dir.sessions.len

proc find*(dir: SessionDirectory; id: string): int =
  ## The session's index, or -1.
  dir.index.getOrDefault(id, -1)

proc replaceAll*(dir: var SessionDirectory; sessions: openArray[FleetSession]) =
  ## A whole listing. Sessions already known keep their place (a tab does not
  ## move because the list was re-read); new ones follow in creation order;
  ## sessions the listing no longer has are dropped. Ends a resync.
  var fresh = initTable[string, FleetSession]()
  for session in sessions: fresh[session.id] = session
  var kept: seq[FleetSession]
  for session in dir.sessions:
    if session.id in fresh:
      kept.add fresh[session.id]
      fresh.del session.id
  var added: seq[FleetSession]
  for session in sessions:
    if session.id in fresh: added.add session
  added.sort proc(a, b: FleetSession): int =
    result = cmp(a.createdAtMs, b.createdAtMs)
    if result == 0: result = cmp(a.id, b.id)
  dir.sessions = kept & added
  dir.reindex()
  dir.resyncing = false
  inc dir.revision

proc applyFrame*(dir: var SessionDirectory; frame: LifecycleFrame): bool =
  ## Folds one lifecycle frame in; true when the directory changed. A frame
  ## about a session the directory has not seen adds a stub (its id, status
  ## and agent), which the next listing fills in.
  case frame.event
  of "resync":
    dir.resyncing = true
    inc dir.revision
    return true
  of "caught_up":
    if dir.caughtUp: return false
    dir.caughtUp = true
    inc dir.revision
    return true
  else: discard
  if frame.sessionId.len == 0: return false
  let at = dir.find(frame.sessionId)
  case frame.kind
  of "session_removed":
    if at < 0: return false
    dir.sessions.delete(at)
    dir.reindex()
  of "session_created", "session_status_changed", "session_completed":
    if at < 0:
      var stub = FleetSession(id: frame.sessionId, rawStatus: frame.status,
                              status: parseFleetStatus(frame.status),
                              agentSoftware: frame.agent,
                              createdAtMs: frame.atMs, updatedAtMs: frame.atMs)
      if frame.kind == "session_completed": stub.endedAtMs = frame.atMs
      dir.sessions.add stub
      dir.index[stub.id] = dir.sessions.high
    else:
      if dir.sessions[at].rawStatus == frame.status and
          frame.kind != "session_completed":
        return false
      dir.sessions[at].rawStatus = frame.status
      dir.sessions[at].status = parseFleetStatus(frame.status)
      if frame.atMs > 0: dir.sessions[at].updatedAtMs = frame.atMs
      if frame.kind == "session_completed":
        dir.sessions[at].endedAtMs = frame.atMs
        dir.sessions[at].awaitingInput = false
      elif not dir.sessions[at].status.isActive:
        dir.sessions[at].awaitingInput = false
  else:
    return false
  inc dir.revision
  true

proc lastActivityMs*(session: FleetSession): int64 =
  result = max(session.updatedAtMs, max(session.startedAtMs, session.createdAtMs))
  for event in session.recent:
    result = max(result, event.timestampMs)

proc orderedIndexes*(sessions: openArray[FleetSession];
                     policy: SessionPolicy): seq[int] =
  ## Indexes of `sessions` in the policy's order. `soLaunch` keeps the given
  ## order (the directory's first-seen order); `soAttention` sorts by
  ## attention, then most recent activity, the id breaking ties so the order
  ## is total.
  for i in 0 ..< sessions.len: result.add i
  if policy.order == soAttention:
    let status = policy.status
    var keyed: seq[(int, int64, string, int)]
    for i in result:
      keyed.add (ord(sessions[i].attentionOf(status)),
                 -sessions[i].lastActivityMs, sessions[i].id, i)
    keyed.sort()
    result.setLen 0
    for entry in keyed: result.add entry[3]

proc groupByPlan*(sessions: openArray[FleetSession]; order: openArray[int];
                  planOrder: openArray[string]): seq[SessionGroup] =
  ## The sessions of `order`, grouped by the plan each was launched for, the
  ## groups in `planOrder` (plans with no session are kept, empty: a running
  ## initiative with no session is a state worth seeing), then the plans
  ## `planOrder` does not name, then the sessions launched for no plan.
  var byPlan = initTable[string, int]()
  for plan in planOrder:
    if plan notin byPlan:
      byPlan[plan] = result.len
      result.add SessionGroup(planId: plan)
  var loose = SessionGroup(planId: "")
  for i in order:
    let plan = sessions[i].planId
    if plan.len == 0:
      loose.indexes.add i
    else:
      if plan notin byPlan:
        byPlan[plan] = result.len
        result.add SessionGroup(planId: plan)
      result[byPlan[plan]].indexes.add i
  if loose.indexes.len > 0: result.add loose

proc attentionCounts*(sessions: openArray[FleetSession];
                      indexes: openArray[int];
                      policy = espNeedsInputWins): array[SessionAttention, int] =
  for i in indexes: inc result[sessions[i].attentionOf(policy)]

proc moveSession*(dir: var SessionDirectory; id: string; toIndex: int): bool =
  ## Moves a session to `toIndex` of the first-seen order (an operator
  ## dragging a tab); true when it moved.
  let at = dir.find(id)
  if at < 0: return false
  let target = max(0, min(toIndex, dir.sessions.high))
  if target == at: return false
  let session = dir.sessions[at]
  dir.sessions.delete(at)
  dir.sessions.insert(session, target)
  dir.reindex()
  inc dir.revision
  true

# ---------------------------------------------------------------------------
# Initiatives' state, and the inbox order
# ---------------------------------------------------------------------------

type
  InitiativeState* = enum
    ## What an initiative's tab says at a glance (agent-harbor Glossary
    ## "Initiative"; CodeTracer AHF "Initiative tabs").
    isNeedsInput = "needs-input" ## a session of it waits on a question
    isBlocked = "blocked"        ## a milestone is blocked and nothing runs
    isWorking = "working"        ## a session of it is running or queued
    isIdle = "idle"              ## nothing of it runs and its plan is not done
    isEnded = "ended"            ## its plan is done and nothing of it runs

proc initiativeStateOf*(attentions: openArray[SessionAttention];
                        blockedMilestones: int;
                        planDone = false): InitiativeState =
  ## Needing a person outranks working; a blocked milestone shows only when
  ## nothing works around it; with nothing running, an initiative whose plan
  ## is done has ended and any other is idle (it waits for work, whether its
  ## sessions ended or wait for an instruction).
  var counts: array[SessionAttention, int]
  for a in attentions: inc counts[a]
  if counts[saNeedsInput] > 0: isNeedsInput
  elif counts[saRunning] + counts[saQueued] > 0: isWorking
  elif blockedMilestones > 0: isBlocked
  elif planDone: isEnded
  else: isIdle

proc planDone*(completed, total: int): bool =
  ## Every milestone completed (a plan with none is not done).
  total > 0 and completed >= total

proc inboxOrder*(sessions: openArray[FleetSession];
                 policy = espIdlePromptApart): seq[int] =
  ## The sessions that wait for the operator -- blocked ones first, then
  ## ended turns -- the longest waiting first: the order Next walks. A
  ## stand-in for Agent Harbor's inbox order until a front-end reads it from
  ## the server; the same walk serves both.
  var keyed: seq[(int, int64, string, int)]
  for i, s in sessions:
    let a = s.attentionOf(policy)
    if a in {saNeedsInput, saIdle}:
      keyed.add (ord(a), s.lastActivityMs, s.id, i)
  keyed.sort()
  for k in keyed: result.add k[3]

proc inboxStep*(order: openArray[int]; current, delta: int): int =
  ## The item `delta` steps from `current` in `order` (wrapping); the first
  ## (or last) item when `current` is not in the order; -1 for an empty
  ## inbox.
  if order.len == 0: return -1
  var at = -1
  for i, item in order:
    if item == current: at = i
  if at < 0:
    return if delta >= 0: order[0] else: order[^1]
  order[((at + delta) mod order.len + order.len) mod order.len]

proc resumeSession*(dir: var SessionDirectory; id: string; atMs = 0'i64): bool =
  ## The operator's input reached a waiting session (its events say so:
  ## `session_resumed`, `user_input`): it no longer waits and runs again.
  ## True when that changed it.
  let at = dir.find(id)
  if at < 0: return false
  if not dir.sessions[at].awaitingInput and dir.sessions[at].status != fsPaused:
    return false
  dir.sessions[at].awaitingInput = false
  dir.sessions[at].awaitingInputSource = ""
  dir.sessions[at].status = fsRunning
  dir.sessions[at].rawStatus = "running"
  if atMs > 0: dir.sessions[at].updatedAtMs = atMs
  inc dir.revision
  true
