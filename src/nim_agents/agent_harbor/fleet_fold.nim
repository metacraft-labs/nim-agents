## A fleet list that follows the fleet after its first listing, as signal-free
## state and a reducer: the domain a fleet overview is built on when its
## sessions start, change and end under it (a live feed, or a recorded run
## played back).
##
## A `FleetFold` starts from one listing (`initFleetFold`, the answer to
## `GET /api/v1/sessions`) and folds three kinds of frame (`FleetFrame`):
##
## - a lifecycle frame (`GET /api/v1/session-lifecycle/events`), folded by the
##   tab strip's own reducer (`SessionDirectory.applyFrame`): a session
##   starting, changing state, ending or being removed;
## - one session's listing entry (`GET /api/v1/sessions/{id}`), what a
##   front-end reads when a `session_created` frame names a session it holds
##   only as a stub (`SessionDirectory.upsert`);
## - one event of a session's event stream, folded by the step a session
##   replayed to a moment repeats (`session_replay.foldEvent`): it appends the
##   session's activity and says whether the session now waits on a question.
##   A wait the listing reports for another reason (the agent's turn ended, an
##   estimated wait, a permission) stays until the operator's input reaches
##   the session or a later listing entry or lifecycle frame says otherwise.
##
## The status is the lifecycle feed's. A `status` event in a session's stream
## repeats a frame the feed carries, so the fold keeps it as activity and
## leaves the status to the feed (a late duplicate cannot move a session
## back).
##
## After every change the fold recomputes what a fleet list shows besides the
## sessions themselves: the changed session's activity digest
## (`sessionDigest`), the count per category, the total, and the fold's clock
## (`capturedAtMs`, the moment relative times are measured from). Folding a
## run's frames from its first listing therefore gives the fleet a listing
## taken at the last frame's moment would give.
##
## A frame the fold cannot use is reported, not guessed at (`FoldOutcome`): a
## frame without a session id or with an unknown kind, an event that is not a
## JSON object, an event or removal for a session the fold does not hold, and
## a frame older than what the fold already holds for its session (an
## event whose place in the history was folded already, a lifecycle frame or
## listing entry stamped before the session's last update).

import std/[json, tables]
import ./[fleet_records, session_directory, session_replay, activity_digest]

export fleet_records, session_directory, activity_digest

type
  FleetFrameKind* = enum
    ffLifecycle = "lifecycle" ## a lifecycle-feed frame
    ffSession = "session"     ## one session's listing entry
    ffEvent = "event"         ## one event of a session's event stream

  FleetFrame* = object
    ## One change to a fleet, as a live feed or a played-back run delivers it.
    atMs*: int64
      ## When it happened; 0 to take the moment from the frame itself (the
      ## lifecycle frame's `at`, the event's timestamp, the entry's update).
    case kind*: FleetFrameKind
    of ffLifecycle:
      lifecycle*: LifecycleFrame
    of ffSession:
      session*: FleetSession
    of ffEvent:
      sessionId*: string
      event*: JsonNode
        ## The event as the stream sends it (`type`, `timestamp` in
        ## microseconds since the session started, and its own fields).
      ordinal*: int
        ## The event's 1-based place in the session's history; 0 when the
        ## source does not know it, and the fold counts the events it folded.

  FoldOutcome* = enum
    ## What folding one frame did.
    foApplied = "applied"                ## the fleet changed
    foUnchanged = "unchanged"            ## the frame repeats what is known
    foUnknownSession = "unknown session" ## about a session the fold lacks
    foStale = "stale"                    ## older than what the fold holds
    foMalformed = "malformed"            ## no session id, or an unknown kind

  FleetFold* = object
    capturedAtMs*: int64
      ## The fold's clock: the latest moment it has folded. Relative times
      ## ("12m ago", a live session's duration) are measured from it.
    sourceLabel*: string
    total*: int
      ## The sessions the server reports in all (at least those held).
    counts*: array[FleetCategory, int]
      ## Held sessions per category, recomputed on every change.
    dir: SessionDirectory
    digests: Table[string, seq[DigestLine]]
    folded: Table[string, int]
      ## Per session, the place in its history of the last event folded.

const
  LifecycleSessionKinds = ["session_created", "session_status_changed",
                           "session_completed", "session_removed"]

proc lifecycleFrame*(frame: LifecycleFrame; atMs = 0'i64): FleetFrame =
  FleetFrame(kind: ffLifecycle, lifecycle: frame, atMs: atMs)

proc sessionFrame*(session: FleetSession; atMs = 0'i64): FleetFrame =
  FleetFrame(kind: ffSession, session: session, atMs: atMs)

proc eventFrame*(sessionId: string; event: JsonNode; ordinal = 0;
                 atMs = 0'i64): FleetFrame =
  FleetFrame(kind: ffEvent, sessionId: sessionId, event: event,
             ordinal: ordinal, atMs: atMs)

proc `$`*(frame: FleetFrame): string =
  ## A frame as a failing check names it: its kind, session and moment.
  case frame.kind
  of ffLifecycle:
    let f = frame.lifecycle
    result = "lifecycle " & (if f.kind.len > 0: f.kind else: f.event) &
      " " & f.sessionId & (if f.status.len > 0: " -> " & f.status else: "")
  of ffSession:
    result = "listing entry " & frame.session.id & " (" &
      frame.session.rawStatus & ")"
  of ffEvent:
    result = "event #" & $frame.ordinal & " of " & frame.sessionId
    if not frame.event.isNil and frame.event.kind == JObject:
      result.add " (" & frame.event{"type"}.getStr & ")"
  if frame.atMs > 0: result.add " at " & $frame.atMs

# ---------------------------------------------------------------------------
# Reading the fold
# ---------------------------------------------------------------------------

proc len*(fold: FleetFold): int = fold.dir.len

proc find*(fold: FleetFold; id: string): int =
  ## The session's index in `sessions`, or -1.
  fold.dir.find(id)

proc sessions*(fold: FleetFold): seq[FleetSession] =
  ## Every held session, in the order first seen.
  fold.dir.sessions

proc revision*(fold: FleetFold): int =
  ## Moves on every change, so a view can tell a new state from an old.
  fold.dir.revision

proc resyncing*(fold: FleetFold): bool =
  ## A `resync` frame arrived; the next listing (`initFleetFold`) replaces
  ## the fold.
  fold.dir.resyncing

proc digestOf*(fold: FleetFold; id: string): seq[DigestLine] =
  ## The session's activity digest as last recomputed; empty for a session
  ## the fold does not hold.
  fold.digests.getOrDefault(id)

proc snapshot*(fold: FleetFold): FleetSnapshot =
  ## The fleet as a listing taken at the fold's clock.
  FleetSnapshot(capturedAtMs: fold.capturedAtMs, sourceLabel: fold.sourceLabel,
                total: fold.total, sessions: fold.dir.sessions)

# ---------------------------------------------------------------------------
# The reducer
# ---------------------------------------------------------------------------

proc refreshDigest(fold: var FleetFold; id: string) =
  let at = fold.dir.find(id)
  if at >= 0:
    fold.digests[id] = sessionDigest(fold.dir.sessions[at])
  else:
    fold.digests.del id
    fold.folded.del id

proc recount(fold: var FleetFold) =
  fold.counts = categoryCounts(fold.dir.sessions)
  fold.total = max(fold.total, fold.dir.len)

proc advanceClock(fold: var FleetFold; atMs: int64) =
  fold.capturedAtMs = max(fold.capturedAtMs, atMs)

proc initFleetFold*(snapshot: FleetSnapshot): FleetFold =
  ## A fold holding one listing, in the listing's order, with every
  ## session's digest and the counts computed: the fleet exactly as the
  ## listing shows it.
  result = FleetFold(capturedAtMs: snapshot.capturedAtMs,
                     sourceLabel: snapshot.sourceLabel, total: snapshot.total,
                     dir: initSessionDirectory(snapshot.sessions),
                     digests: initTable[string, seq[DigestLine]](),
                     folded: initTable[string, int]())
  for session in result.dir.sessions:
    result.digests[session.id] = sessionDigest(session)
  result.recount()

proc initFleetFold*(): FleetFold =
  ## An empty fleet, before any listing.
  initFleetFold(FleetSnapshot())

proc applyLifecycle(fold: var FleetFold; frame: LifecycleFrame;
                    atMs: int64): FoldOutcome =
  if frame.event notin ["resync", "caught_up"]:
    if frame.sessionId.len == 0 or frame.kind notin LifecycleSessionKinds:
      return foMalformed
    let at = fold.dir.find(frame.sessionId)
    if at < 0 and frame.kind == "session_removed":
      return foUnknownSession
    if at >= 0 and frame.atMs > 0 and
        frame.atMs < fold.dir.sessions[at].updatedAtMs:
      return foStale
  let before = fold.dir.len
  if not fold.dir.applyFrame(frame): return foUnchanged
  # A session the frame introduced (a stub) or removed moves the total too.
  fold.total = max(0, fold.total + fold.dir.len - before)
  if frame.sessionId.len > 0: fold.refreshDigest(frame.sessionId)
  fold.recount()
  fold.advanceClock(if atMs > 0: atMs else: frame.atMs)
  foApplied

proc applyListing(fold: var FleetFold; session: FleetSession;
                  atMs: int64): FoldOutcome =
  if session.id.len == 0: return foMalformed
  let at = fold.dir.find(session.id)
  if at >= 0 and session.updatedAtMs < fold.dir.sessions[at].updatedAtMs:
    return foStale
  if fold.dir.upsert(session): inc fold.total
  fold.refreshDigest(session.id)
  fold.recount()
  fold.advanceClock(if atMs > 0: atMs else: session.updatedAtMs)
  foApplied

proc applyEvent(fold: var FleetFold; sessionId: string; event: JsonNode;
                ordinal: int; atMs: int64): FoldOutcome =
  if sessionId.len == 0 or event.isNil or event.kind != JObject:
    return foMalformed
  let at = fold.dir.find(sessionId)
  if at < 0: return foUnknownSession
  let seen = fold.folded.getOrDefault(sessionId, 0)
  if ordinal > 0 and ordinal <= seen: return foStale
  let place = if ordinal > 0: ordinal else: seen + 1
  let session = fold.dir.sessions[at]
  let startMs = if session.startedAtMs > 0: session.startedAtMs
                else: session.createdAtMs
  fold.dir.sessions[at].foldEvent(event, place, startMs, takeStatus = false)
  fold.folded[sessionId] = place
  inc fold.dir.revision
  # The appended activity changes what the row's digest says.
  fold.refreshDigest(sessionId)
  fold.recount()
  fold.advanceClock(if atMs > 0: atMs else: event.eventTimeMs(startMs))
  foApplied

proc apply*(fold: var FleetFold; frame: FleetFrame): FoldOutcome =
  ## Folds one frame in. Only `foApplied` changes the fold; every other
  ## outcome leaves it, its clock included, as it was.
  case frame.kind
  of ffLifecycle: fold.applyLifecycle(frame.lifecycle, frame.atMs)
  of ffSession: fold.applyListing(frame.session, frame.atMs)
  of ffEvent: fold.applyEvent(frame.sessionId, frame.event, frame.ordinal,
                              frame.atMs)

proc applyFrame*(fold: var FleetFold; frame: LifecycleFrame): FoldOutcome =
  ## A lifecycle frame from the feed, as the tab strip's reducer takes it.
  fold.apply(lifecycleFrame(frame))
