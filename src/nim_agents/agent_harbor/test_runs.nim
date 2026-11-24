## A change's tests run on Agent Harbor's platforms, as signal-free records
## and one reducer (INV-D-17 … INV-D-23, INV-C-09, INV-C-10).
##
## **The model.** A test run is one request: tests, platforms, a record mode
## and a reuse policy. It has one *platform run* per platform, each served by
## one backend (`reprobuild`, `ah-executors`, …) that the server chooses and
## the front-end shows. A platform is a set of executor features (`os.linux`,
## `arch.x86_64`); the sorted set is its identity, and `platformKey` spells it
## `os.linux+arch.x86_64`. A test is named `<runner>/<runner's id>` and keeps
## its id on every platform.
##
## **The reads, in their proposed shapes**, read leniently (an unknown field
## is ignored, an unknown event kind kept):
##
## - `GET /api/v1/test-platforms` (`platformOffersFromJson`): each platform
##   with the backends and runners that serve it and whether each can record,
##   with which recorders, and why not;
## - `GET /api/v1/test-catalog?source=…&platform=…` (`catalogFromJson`): one
##   platform's tests, or that it is still discovering, or why discovery
##   failed;
## - `POST /api/v1/test-runs`'s answer and `GET /api/v1/test-runs/{id}`
##   (`testRunFromJson`): the run with its platform runs and their backends,
##   and any results so far;
## - `GET /api/v1/test-runs/{id}/events` (`testRunEventFromJson`): the run's
##   events, nine kinds, each carrying `testRunId`, `platform` and `backend`.
##
## **The reducer** (`applyTestRunEvent`) keys every event by platform and
## test id, so two platforms never touch each other's cells; keeps the order
## tests first appeared in (the catalog's, when the state was made from it)
## and never sorts; adds a platform run for an event naming a platform the
## run did not create rather than dropping it; tolerates a repeated
## `run-started` for a platform it knows (its finished tests are kept) and a
## `trace-created` before its test's `test-finished`; on a cancelled
## `run-finished` marks every unfinished cell of that platform `cancelled`,
## keeping the finished ones; and on any other `run-finished` makes every
## cell of that platform that heard no event of its test (still `queued`)
## `not run`, `unreached`, since the run ended before reaching it (a
## provisional decision; its words are `UnreachedText`). A later
## `run-started` of that platform queues those cells again. Illegal orders change nothing: an event naming
## no platform, a test's event naming no test, a `test-started` for a cell
## that already has its result (a cancelled cell has none), and a `test-started` or `trace-started` on a
## platform run that has finished (until its next `run-started`). A reused
## result (a test certificate proved the
## test passed at this tree, so it did not run) is `passed` with `reused`
## and never a duration.
##
## **Counts** (`countsOf`) come from the cells, never from `run-finished`'s
## `totals`, unless no test event arrived for that platform (a run cancelled
## before its first test).
##
## **Rules every surface shares**, one function each: the Verification join
## (`joinVerifications`), why Record is disabled on a platform
## (`recordAbsence`), why a platform cannot run at all (`runAbsence`), what
## the open control does (`openModeOf`, the Test Results pane's three modes),
## and the words (`statusWord`, `platformLabel`, `backendLabel`,
## `summaryLine`).
##
## Signal-free and app-agnostic; identical on the C and JS targets.

import std/[algorithm, json, sets, strutils, tables]
import ./[activity_words, review_record]

type
  TestPlatform* = object
    features*: seq[string]   ## sorted: the platform's identity
    label*: string           ## `Linux x86-64`; `platformLabel` when not served

  RunnerAbility* = object
    ## One runner a backend runs on a platform.
    runner*: string
    canRecord*: bool
    recorders*: seq[string]
    reason*: string          ## why it cannot record, as the backend says

  BackendOffer* = object
    backend*: string
    runners*: seq[RunnerAbility]

  PlatformOffer* = object
    ## A platform the fleet offers, with every backend that serves it.
    platform*: TestPlatform
    backends*: seq[BackendOffer]

  CatalogState* = enum
    csDiscovering = "discovering"
    csDiscovered = "discovered"
    csFailed = "failed"

  CatalogTest* = object
    id*: string              ## `<runner>/<runner's id>`
    runner*: string
    name*: string
    file*: string
    line*: int               ## 0 when unknown
    platforms*: seq[string]  ## the platform keys whose catalog holds it

  PlatformCatalog* = object
    platform*: TestPlatform
    state*: CatalogState
    reason*: string          ## why discovery failed
    tests*: seq[CatalogTest]

  TestRunEventKind* = enum
    tekRunStarted = "run-started"
    tekTestStarted = "test-started"
    tekOutput = "output"
    tekFailure = "failure"
    tekTestFinished = "test-finished"
    tekTraceStarted = "trace-started"
    tekTraceCreated = "trace-created"
    tekRunFinished = "run-finished"
    tekDiagnostic = "diagnostic"
    tekUnknown = "unknown"   ## a kind this front-end does not know (`kindText`)

  TestLocation* = object
    file*: string
    line*: int               ## 0 when unknown

  TestCounts* = object
    passed*, failed*, skipped*, errored*, cancelled*: int
    reused*: int             ## of `passed`, how many were reused

  TestRunEvent* = object
    kind*: TestRunEventKind
    kindText*: string        ## the wire kind, kept for an unknown one
    eventId*: string         ## the stream's event id, for resuming
    testRunId*: string
    platform*: seq[string]   ## sorted features
    backend*, runner*: string
    testId*: string
    stream*, text*: string   ## `output`
    message*: string         ## `failure`, `diagnostic`
    location*: TestLocation  ## `failure`, when known
    status*: string          ## `test-finished`: passed, failed, skipped, errored
    durationMs*: int64
    hasDuration*: bool
    reused*: bool
    certificate*: string     ## a reused result's certificate reference
    recorder*: string        ## `trace-started`
    trace*: string           ## `trace-created`: the trace reference
    totals*: TestCounts      ## `run-finished`
    hasTotals*: bool
    cancelled*: bool         ## `run-finished` with the cancellation
    reason*: string          ## the cancellation's reason
    level*: string           ## `diagnostic`: info, warning, error

  CellStatus* = enum
    tsNotRun = "not-run"
    tsQueued = "queued"
    tsRunning = "running"
    tsPassed = "passed"
    tsFailed = "failed"
    tsSkipped = "skipped"
    tsErrored = "errored"
    tsCancelled = "cancelled"

  RecordingState* = enum
    recNone = "none"
    recRecording = "recording"
    recRecorded = "recorded"
    recDiscarded = "discarded"   ## it ran, but no recording was kept

  OutputLine* = object
    stream*, text*: string

  Diagnostic* = object
    level*, text*: string

  TestCell* = object
    ## One test on one platform.
    testId*: string
    platform*: string        ## the platform key
    status*: CellStatus
    reused*: bool
    certificate*: string
    durationMs*: int64
    hasDuration*: bool       ## never for a reused result
    failure*: string
    location*: TestLocation
    output*: seq[OutputLine]
    recording*: RecordingState
    recorder*: string
    trace*: string
    backend*, runner*: string
    diagnostics*: seq[Diagnostic]
    unreached*: bool
      ## `not run` because its platform run ended before reaching it (see
      ## `UnreachedText`), not because no run asked for it.

  PlatformRunState* = enum
    prsQueued = "queued"         ## created, before its `run-started`
    prsRunning = "running"
    prsFinished = "finished"
    prsCancelled = "cancelled"

  PlatformRun* = object
    platform*: TestPlatform
    backend*, runner*: string
    state*: PlatformRunState
    diagnostics*: seq[Diagnostic]
    lastEventId*: string
    totals*: TestCounts
    hasTotals*: bool
    sawTestEvent*: bool          ## a test event arrived for this platform
    cancelReason*: string

  RecordMode* = enum
    rmNone = "none"
    rmFailing = "failing"
    rmAll = "all"

  ReusePolicy* = enum
    rpCertified = "certified"
    rpNever = "never"

  TestRunState* = object
    id*: string
    record*: RecordMode
    reuse*: ReusePolicy
    startedMs*: int64            ## when the run was created; -1 when unknown
    platformRuns*: seq[PlatformRun]
    order*: seq[string]          ## test ids, in the order they first appeared
    cells: Table[string, TestCell]
    unknown*: seq[TestRunEvent]  ## events of a kind this front-end does not know

  OpenModeKind* = enum
    ## The open control's modes, the Test Results pane's own words.
    omOpenExisting = "open-existing"     ## enters the trace; runs nothing
    omRefreshAndOpen = "refresh-and-open"  ## records again (Shift), then opens
    omRecordAndOpen = "record-and-open"  ## nothing recorded: records, then opens

  OpenMode* = object
    kind*: OpenModeKind
    absence*: string             ## why it cannot be pressed now; "" when it can

  JoinedVerification* = object
    ## A Verification entry with the catalog test it names, if exactly one.
    entry*: VerificationEntry
    testId*: string              ## "" when not in the catalog
    reason*: string              ## why not, when `testId` is ""

const
  NotInCatalogText* = "not in the catalog"
  NotDiscoveredText* = "not discovered"
  RunInProgressOnPlatformText* = "A run is already in progress on this platform"
  RecordingDiscardedText* = "this test ran, but no recording was kept"
  UnreachedText* = "The run on this platform ended before reaching this test"
    ## Why a test a run asked for is `not run` once that platform run ended
    ## without an event for it (`TestCell.unreached`).
    ## The Test Results pane's sentence for a test that ran and kept no
    ## recording, so both panes say the same.

# ---------------------------------------------------------------------------
# Platforms and words
# ---------------------------------------------------------------------------

proc platformKey*(features: openArray[string]): string =
  ## The platform's identity as one string: its features sorted, joined by
  ## `+` (`arch.x86_64+os.linux`).
  var sortedFeatures = @features
  sortedFeatures.sort()
  sortedFeatures.join("+")

proc platformKey*(platform: TestPlatform): string = platformKey(platform.features)

proc platformLabel*(features: openArray[string]): string =
  ## `Linux x86-64`, `macOS arm64`, `Windows x86-64`; features it does not
  ## know are joined as written, after the ones it does.
  var os, arch: string
  var rest: seq[string]
  for f in features:
    case f
    of "os.linux": os = "Linux"
    of "os.macos", "os.darwin": os = "macOS"
    of "os.windows": os = "Windows"
    of "arch.x86_64", "arch.amd64": arch = "x86-64"
    of "arch.aarch64", "arch.arm64": arch = "arm64"
    else: rest.add f
  rest.sort()
  var parts: seq[string]
  if os.len > 0: parts.add os
  if arch.len > 0: parts.add arch
  parts.add rest
  parts.join(" ")

proc testPlatform*(features: openArray[string]; label = ""): TestPlatform =
  var sortedFeatures = @features
  sortedFeatures.sort()
  TestPlatform(features: sortedFeatures,
               label: (if label.len > 0: label else: platformLabel(features)))

proc backendLabel*(backend: string): string =
  ## The backend's chip: its id as the server names it, `unknown backend`
  ## when it names none.
  if backend.len > 0: backend else: "unknown backend"

proc statusWord*(status: CellStatus): string =
  case status
  of tsNotRun: "not run"
  of tsQueued: "queued"
  of tsRunning: "running"
  of tsPassed: "passed"
  of tsFailed: "failed"
  of tsSkipped: "skipped"
  of tsErrored: "errored"
  of tsCancelled: "cancelled"

proc isFinal*(status: CellStatus): bool =
  status in {tsPassed, tsFailed, tsSkipped, tsErrored, tsCancelled}

const TestEventKinds = {tekTestStarted, tekOutput, tekFailure, tekTestFinished,
                        tekTraceStarted, tekTraceCreated}
  ## The kinds that are about one test and name it by `testId`.

proc runnerOf*(testId: string): string =
  ## The runner prefix of a test id (`pytest/tests/a.py::t` → `pytest`).
  let slash = testId.find('/')
  if slash > 0: testId[0 ..< slash] else: ""

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

proc firstStr(node: JsonNode; keys: openArray[string]): string =
  for key in keys:
    let value = node.fieldStr(key)
    if value.len > 0: return value
  ""

proc featuresOf(node: JsonNode): seq[string] =
  ## A platform as an array of features, or an object with `features`.
  var list = node
  if not node.isNil and node.kind == JObject: list = node.fieldChild("features")
  if list.isNil or list.kind != JArray: return
  for f in list:
    if f.kind == JString and f.getStr.len > 0: result.add f.getStr
  result.sort()

proc flagOf(node: JsonNode; keys: openArray[string]): bool =
  for key in keys:
    if node.fieldFlag(key): return true
  false

proc stringsOf(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray: return
  for v in node:
    if v.kind == JString: result.add v.getStr

proc runnerAbilityFromJson(node: JsonNode): RunnerAbility =
  if node.kind == JString: return RunnerAbility(runner: node.getStr)
  RunnerAbility(runner: node.firstStr(["id", "runner"]),
                canRecord: node.flagOf(["canRecord", "can_record"]),
                recorders: stringsOf(node.fieldChild("recorders")),
                reason: node.firstStr(["reason", "recordReason", "record_reason"]))

proc platformOfferFromJson*(node: JsonNode): PlatformOffer =
  ## One offered platform: `features` (or `platform`), an optional `label`,
  ## `backends` each with its `id` and `runners` (`id`, `canRecord`,
  ## `recorders`, `reason`).
  if node.isNil or node.kind != JObject: return
  var features = featuresOf(node.fieldChild("features"))
  if features.len == 0: features = featuresOf(node.fieldChild("platform"))
  result.platform = testPlatform(features, node.fieldStr("label"))
  let backends = node.fieldChild("backends")
  if backends.isNil or backends.kind != JArray: return
  for b in backends:
    if b.kind != JObject: continue
    var offer = BackendOffer(backend: b.firstStr(["id", "backend"]))
    let runners = b.fieldChild("runners")
    if not runners.isNil and runners.kind == JArray:
      for r in runners:
        if r.kind in {JObject, JString}: offer.runners.add runnerAbilityFromJson(r)
    result.backends.add offer

proc platformOffersFromJson*(node: JsonNode): seq[PlatformOffer] =
  ## `GET /api/v1/test-platforms`: an array of platforms, or an object whose
  ## `platforms` is one. Order kept.
  var list = node
  if not node.isNil and node.kind == JObject: list = node.fieldChild("platforms")
  if list.isNil or list.kind != JArray: return
  for p in list:
    let offer = platformOfferFromJson(p)
    if offer.platform.features.len > 0: result.add offer

proc nameOf(id, runner: string): string =
  ## A test's name from its id: the id without its `<runner>/` prefix, or the
  ## whole id when it has no such prefix.
  if runner.len > 0 and id.len > runner.len and id.startsWith(runner & "/"):
    id[runner.len + 1 .. ^1]
  else: id

proc catalogTestFromJson(node: JsonNode; platformKey: string): CatalogTest =
  if node.kind == JString:
    let id = node.getStr
    return CatalogTest(id: id, runner: runnerOf(id), name: nameOf(id, runnerOf(id)),
                       platforms: @[platformKey])
  let id = node.fieldStr("id")
  result = CatalogTest(id: id, runner: node.fieldStr("runner"),
                       name: node.fieldStr("name"), file: node.fieldStr("file"),
                       line: node.fieldInt("line"), platforms: @[platformKey])
  if result.runner.len == 0: result.runner = runnerOf(id)
  if result.name.len == 0: result.name = nameOf(id, result.runner)

proc catalogFromJson*(node: JsonNode): PlatformCatalog =
  ## One platform's catalog: `platform`, `state` (`discovering`,
  ## `discovered`, `failed`; `discovered` when absent and tests are given),
  ## `reason`, `tests` (each `id`, `runner`, `name`, `file`, `line`, or a
  ## bare id). Order kept.
  if node.isNil or node.kind != JObject: return
  result.platform = testPlatform(featuresOf(node.fieldChild("platform")))
  result.reason = node.fieldStr("reason")
  case node.fieldStr("state")
  of "discovering": result.state = csDiscovering
  of "failed": result.state = csFailed
  of "discovered": result.state = csDiscovered
  else:
    result.state = if result.reason.len > 0: csFailed else: csDiscovered
  let key = platformKey(result.platform)
  let tests = node.fieldChild("tests")
  if tests.isNil or tests.kind != JArray: return
  for t in tests:
    if t.kind in {JObject, JString}:
      let test = catalogTestFromJson(t, key)
      if test.id.len > 0: result.tests.add test

proc mergeCatalogs*(catalogs: openArray[PlatformCatalog]): seq[CatalogTest] =
  ## Every test of every platform's catalog, once, in the order first seen
  ## (the catalogs' order, then each catalog's), with the platforms that
  ## hold it.
  var at = initTable[string, int]()
  for catalog in catalogs:
    let key = platformKey(catalog.platform)
    for test in catalog.tests:
      if test.id in at:
        let i = at[test.id]
        if key notin result[i].platforms: result[i].platforms.add key
      else:
        at[test.id] = result.len
        var t = test
        t.platforms = @[key]
        result.add t

proc locationOf(node: JsonNode): TestLocation =
  ## A failure's location: an object (`file`, `line`), a `file:line` string,
  ## or null.
  if node.isNil: return
  case node.kind
  of JObject:
    TestLocation(file: node.firstStr(["file", "path"]), line: node.fieldInt("line"))
  of JString:
    let text = node.getStr
    let colon = text.rfind(':')
    if colon > 0:
      try:
        return TestLocation(file: text[0 ..< colon], line: parseInt(text[colon + 1 .. ^1]))
      except ValueError:
        discard
    TestLocation(file: text)
  else: TestLocation()

proc countsFromJson(node: JsonNode): TestCounts =
  TestCounts(passed: node.fieldInt("passed"), failed: node.fieldInt("failed"),
             skipped: node.fieldInt("skipped"), errored: node.fieldInt("errored"),
             cancelled: node.fieldInt("cancelled"), reused: node.fieldInt("reused"))

proc testRunEventFromJson*(node: JsonNode): TestRunEvent =
  ## One event of a run's stream, in its proposed shape: `kind`,
  ## `testRunId`, `platform` (the features), `backend`, `runner`, `testId`
  ## and the kind's own fields (`stream`, `text`; `message`, `location`;
  ## `status`, `durationMs`, `reused`, `certificate`; `recorder`; `trace`;
  ## `totals`, `cancelled`, `reason`; `level`). The stream's event id is
  ## `id` (or `eventId`). A kind it does not know is kept as `tekUnknown`.
  if node.isNil or node.kind != JObject: return TestRunEvent(kind: tekUnknown)
  let kindText = node.fieldStr("kind")
  var kind = tekUnknown
  for k in TestRunEventKind:
    if k != tekUnknown and $k == kindText: kind = k
  result = TestRunEvent(kind: kind, kindText: kindText,
                        eventId: node.firstStr(["id", "eventId"]),
                        testRunId: node.fieldStr("testRunId"),
                        platform: featuresOf(node.fieldChild("platform")),
                        backend: node.fieldStr("backend"),
                        runner: node.fieldStr("runner"),
                        testId: node.fieldStr("testId"),
                        stream: node.fieldStr("stream"), text: node.fieldStr("text"),
                        message: node.fieldStr("message"),
                        location: locationOf(node.fieldChild("location")),
                        status: node.fieldStr("status"),
                        reused: node.fieldFlag("reused"),
                        certificate: node.fieldStr("certificate"),
                        recorder: node.fieldStr("recorder"),
                        trace: node.fieldStr("trace"),
                        reason: node.fieldStr("reason"),
                        level: node.fieldStr("level"))
  let duration = node.fieldChild("durationMs")
  if not duration.isNil and duration.kind in {JInt, JFloat}:
    result.durationMs = node.fieldNum("durationMs")
    result.hasDuration = true
  let totals = node.fieldChild("totals")
  if not totals.isNil and totals.kind == JObject:
    result.totals = countsFromJson(totals)
    result.hasTotals = true
  let cancelled = node.fieldChild("cancelled")
  if not cancelled.isNil:
    # `cancelled: true`, or an object naming the cancellation's reason.
    case cancelled.kind
    of JBool: result.cancelled = cancelled.getBool
    of JObject:
      result.cancelled = true
      if result.reason.len == 0: result.reason = cancelled.fieldStr("reason")
    of JString:
      result.cancelled = true
      if result.reason.len == 0: result.reason = cancelled.getStr
    else: discard
  if node.fieldStr("status") == "cancelled" and kind == tekRunFinished:
    result.cancelled = true

# ---------------------------------------------------------------------------
# The run's state and its reducer
# ---------------------------------------------------------------------------

proc cellKey(platform, testId: string): string = platform & "\t" & testId

proc platformIndex(state: TestRunState; key: string): int =
  for i, run in state.platformRuns:
    if platformKey(run.platform) == key: return i
  -1

proc addPlatform(state: var TestRunState; features: openArray[string];
                 backend = ""): int =
  ## The platform run of `features`, created queued when the run has none.
  let key = platformKey(features)
  result = state.platformIndex(key)
  if result < 0:
    state.platformRuns.add PlatformRun(platform: testPlatform(features),
                                       backend: backend, state: prsQueued)
    result = state.platformRuns.high
  elif backend.len > 0 and state.platformRuns[result].backend.len == 0:
    state.platformRuns[result].backend = backend

proc noteTest(state: var TestRunState; testId: string) =
  if testId.len > 0 and testId notin state.order: state.order.add testId

proc initTestRunState*(id: string; tests: openArray[string];
                       platforms: openArray[TestPlatform];
                       backends: openArray[string] = [];
                       record = rmNone; reuse = rpCertified;
                       startedMs = -1'i64): TestRunState =
  ## A run as created: its tests in the order given (the catalog's) and one
  ## queued platform run per platform, with the backend assigned to it
  ## (`backends[i]` for `platforms[i]`, when given). Every requested test is
  ## queued on every platform.
  result = TestRunState(id: id, record: record, reuse: reuse, startedMs: startedMs)
  for i, platform in platforms:
    let backend = if i < backends.len: backends[i] else: ""
    discard result.addPlatform(platform.features, backend)
    if platform.label.len > 0: result.platformRuns[^1].platform.label = platform.label
  for test in tests:
    result.noteTest(test)
    for run in result.platformRuns:
      let key = platformKey(run.platform)
      result.cells[cellKey(key, test)] = TestCell(testId: test, platform: key,
        status: tsQueued, backend: run.backend)

proc cell*(state: TestRunState; platform, testId: string): TestCell =
  ## The cell of `testId` on the platform key `platform`; `tsNotRun` when the
  ## run never asked for or heard of it.
  state.cells.getOrDefault(cellKey(platform, testId),
    TestCell(testId: testId, platform: platform, status: tsNotRun))

proc hasCell*(state: TestRunState; platform, testId: string): bool =
  cellKey(platform, testId) in state.cells

proc cellsOf*(state: TestRunState; testId: string): seq[TestCell] =
  ## One cell per platform run, in the platform runs' order.
  for run in state.platformRuns:
    result.add state.cell(platformKey(run.platform), testId)

proc cellFor(state: var TestRunState; platformRun: int; testId: string): TestCell =
  ## A copy of the cell of `testId` on platform run `platformRun`, made
  ## (not run) when the run has none, with the run's backend and runner.
  let run = state.platformRuns[platformRun]
  let key = platformKey(run.platform)
  let k = cellKey(key, testId)
  if k notin state.cells:
    state.cells[k] = TestCell(testId: testId, platform: key, status: tsNotRun)
  state.noteTest(testId)
  result = state.cells[k]
  if run.backend.len > 0: result.backend = run.backend
  if run.runner.len > 0 and result.runner.len == 0: result.runner = run.runner

proc statusOf(word: string): CellStatus =
  case word
  of "passed", "pass", "ok": tsPassed
  of "failed", "fail": tsFailed
  of "skipped", "skip", "ignored": tsSkipped
  of "cancelled", "canceled": tsCancelled
  else: tsErrored   # `errored`, and a status this front-end does not know

proc recordingWanted(record: RecordMode; cell: TestCell): bool =
  ## Whether a run in record mode `record` asked for this finished test to
  ## be recorded.
  case record
  of rmNone: false
  of rmAll: cell.status in {tsPassed, tsFailed, tsErrored} and not cell.reused
  of rmFailing: cell.status in {tsFailed, tsErrored}

proc applyTestRunEvent*(state: var TestRunState; event: TestRunEvent): bool =
  ## Folds one event; true when the state changed. An event of another run
  ## is ignored. See the module comment for the rules.
  if event.testRunId.len > 0 and state.id.len > 0 and event.testRunId != state.id:
    return false
  if event.kind == tekUnknown:
    state.unknown.add event
    return true
  # Every event names its platform, and a test's events their test: one that
  # does not cannot be keyed, so it changes nothing (never a cell or a
  # platform run without a name).
  if event.platform.len == 0: return false
  if event.testId.len == 0 and event.kind in TestEventKinds: return false
  let p = state.addPlatform(event.platform, event.backend)
  template run: untyped = state.platformRuns[p]
  # A platform run that has finished hears nothing new start until its next
  # `run-started`: a late `test-started` or `trace-started` is stale.
  if run.state in {prsFinished, prsCancelled} and
      event.kind in {tekTestStarted, tekTraceStarted}:
    return false
  # A start never undoes a result: a `test-started` that arrives after its
  # `test-finished`, or twice, leaves a finished cell as it is. A cancelled
  # cell is not a result: a platform run started again may run it.
  if event.kind == tekTestStarted and
      state.cell(platformKey(run.platform), event.testId).status in
        {tsPassed, tsFailed, tsSkipped, tsErrored}:
    return false
  if event.eventId.len > 0: run.lastEventId = event.eventId
  if event.runner.len > 0 and run.runner.len == 0: run.runner = event.runner
  if event.testId.len > 0 and event.kind != tekDiagnostic:
    run.sawTestEvent = true
  result = true
  case event.kind
  of tekRunStarted:
    # Repeated for a platform it knows: running again, its cells kept, and
    # the tests an earlier end left unreached are queued again.
    run.state = prsRunning
    if event.runner.len > 0: run.runner = event.runner
    let key = platformKey(run.platform)
    for k, c in state.cells.mpairs:
      if c.platform == key and c.unreached:
        c.unreached = false
        c.status = tsQueued
  of tekTestStarted:
    if run.state == prsQueued: run.state = prsRunning
    var c = state.cellFor(p, event.testId)
    c.status = tsRunning
    state.cells[cellKey(c.platform, c.testId)] = c
  of tekOutput:
    var c = state.cellFor(p, event.testId)
    c.output.add OutputLine(stream: event.stream, text: event.text)
    state.cells[cellKey(c.platform, c.testId)] = c
  of tekFailure:
    var c = state.cellFor(p, event.testId)
    c.failure = event.message
    c.location = event.location
    state.cells[cellKey(c.platform, c.testId)] = c
  of tekTestFinished:
    var c = state.cellFor(p, event.testId)
    c.status = statusOf(event.status)
    c.unreached = false   # a late result is the test's own
    c.reused = event.reused and c.status == tsPassed
    if c.reused:
      # Not run: a certificate proved it. No duration, whatever was sent.
      c.certificate = event.certificate
      c.hasDuration = false
      c.durationMs = 0
    else:
      c.hasDuration = event.hasDuration
      c.durationMs = event.durationMs
    state.cells[cellKey(c.platform, c.testId)] = c
  of tekTraceStarted:
    var c = state.cellFor(p, event.testId)
    if c.recording != recRecorded: c.recording = recRecording
    c.recorder = event.recorder
    state.cells[cellKey(c.platform, c.testId)] = c
  of tekTraceCreated:
    # It may come before its test's `test-finished`; the cell keeps it.
    var c = state.cellFor(p, event.testId)
    c.recording = recRecorded
    c.trace = event.trace
    state.cells[cellKey(c.platform, c.testId)] = c
  of tekRunFinished:
    run.totals = event.totals
    run.hasTotals = event.hasTotals
    let key = platformKey(run.platform)
    if event.cancelled:
      run.state = prsCancelled
      run.cancelReason = event.reason
      for k, c in state.cells.mpairs:
        if c.platform == key and c.status in {tsQueued, tsRunning}:
          c.status = tsCancelled
    else:
      run.state = prsFinished
      # A test the run asked for and never reached (no event of it arrived)
      # did not run: it is `not run`, with why, never left `queued`.
      for k, c in state.cells.mpairs:
        if c.platform == key and c.status == tsQueued:
          c.status = tsNotRun
          c.unreached = true
    # A recording started and never created, or one the run asked for and
    # never got, was not kept (the Test Results pane's discarded state).
    let wanted = state.record
    for k, c in state.cells.mpairs:
      if c.platform != key: continue
      if c.recording == recRecording or
          (c.recording == recNone and wanted.recordingWanted(c)):
        c.recording = recDiscarded
  of tekDiagnostic:
    let d = Diagnostic(level: (if event.level.len > 0: event.level else: "warning"),
                       text: (if event.message.len > 0: event.message else: event.text))
    if event.testId.len > 0:
      var c = state.cellFor(p, event.testId)
      c.diagnostics.add d
      state.cells[cellKey(c.platform, c.testId)] = c
    else:
      run.diagnostics.add d
  of tekUnknown: discard

proc testRunFromJson*(node: JsonNode): TestRunState =
  ## The creation answer and `GET /api/v1/test-runs/{id}`: `id`, `record`,
  ## `reuse`, `tests` (ids, or `all`), `createdMs`, and `platformRuns` (each
  ## `platform`, `backend`, `runner`, `state`, and its `results` so far: each
  ## `testId`, `status`, `durationMs`, `reused`, `certificate`, `message`,
  ## `trace`).
  if node.isNil or node.kind != JObject: return
  var tests: seq[string]
  let testsNode = node.fieldChild("tests")
  if not testsNode.isNil and testsNode.kind == JArray: tests = stringsOf(testsNode)
  var platforms: seq[TestPlatform]
  var backends: seq[string]
  let runs = node.fieldChild("platformRuns")
  if not runs.isNil and runs.kind == JArray:
    for r in runs:
      if r.kind != JObject: continue
      let features = featuresOf(r.fieldChild("platform"))
      if features.len == 0: continue
      platforms.add testPlatform(features)
      backends.add r.fieldStr("backend")
  var record = rmNone
  for m in RecordMode:
    if $m == node.fieldStr("record"): record = m
  let reuse = if node.fieldStr("reuse") == "never": rpNever else: rpCertified
  let created = node.fieldChild("createdMs")
  result = initTestRunState(node.fieldStr("id"), tests, platforms, backends, record,
                            reuse, (if created.isNil: -1'i64 else: node.fieldNum("createdMs")))
  if runs.isNil or runs.kind != JArray: return
  for r in runs:
    if r.kind != JObject: continue
    let features = featuresOf(r.fieldChild("platform"))
    if features.len == 0: continue
    let p = result.addPlatform(features, r.fieldStr("backend"))
    if r.fieldStr("runner").len > 0: result.platformRuns[p].runner = r.fieldStr("runner")
    for s in PlatformRunState:
      if $s == r.fieldStr("state"): result.platformRuns[p].state = s
    let results = r.fieldChild("results")
    if results.isNil or results.kind != JArray: continue
    for t in results:
      if t.kind != JObject: continue
      var e = testRunEventFromJson(t)
      e.testRunId = result.id
      e.platform = features
      e.backend = ""
      if t.fieldStr("message").len > 0:
        e.kind = tekFailure
        discard result.applyTestRunEvent(e)
      if t.fieldStr("status").len > 0:
        e.kind = tekTestFinished
        discard result.applyTestRunEvent(e)
      if e.trace.len > 0:
        e.kind = tekTraceCreated
        discard result.applyTestRunEvent(e)

# ---------------------------------------------------------------------------
# Counts and words over a run
# ---------------------------------------------------------------------------

proc add(counts: var TestCounts; status: CellStatus; reused: bool) =
  case status
  of tsPassed:
    inc counts.passed
    if reused: inc counts.reused
  of tsFailed: inc counts.failed
  of tsSkipped: inc counts.skipped
  of tsErrored: inc counts.errored
  of tsCancelled: inc counts.cancelled
  else: discard

proc `+`(a, b: TestCounts): TestCounts =
  TestCounts(passed: a.passed + b.passed, failed: a.failed + b.failed,
             skipped: a.skipped + b.skipped, errored: a.errored + b.errored,
             cancelled: a.cancelled + b.cancelled, reused: a.reused + b.reused)

proc countsOf*(state: TestRunState; platform: string): TestCounts =
  ## One platform run's counts, from its cells; its served `totals` only when
  ## no test event arrived for it.
  let i = state.platformIndex(platform)
  if i < 0: return
  let run = state.platformRuns[i]
  if not run.sawTestEvent and run.hasTotals: return run.totals
  for testId in state.order:
    if state.hasCell(platform, testId):
      let c = state.cell(platform, testId)
      result.add(c.status, c.reused)

proc countsOf*(state: TestRunState): TestCounts =
  ## The whole run's counts: every platform run's, summed.
  for run in state.platformRuns:
    result = result + state.countsOf(platformKey(run.platform))

proc countsText*(counts: TestCounts): string =
  ## `9 passed (3 reused) · 2 failed · 1 skipped`; only the non-zero ones.
  var parts: seq[string]
  if counts.passed > 0:
    parts.add $counts.passed & " passed" &
      (if counts.reused > 0: " (" & $counts.reused & " reused)" else: "")
  if counts.failed > 0: parts.add $counts.failed & " failed"
  if counts.errored > 0: parts.add $counts.errored & " errored"
  if counts.skipped > 0: parts.add $counts.skipped & " skipped"
  if counts.cancelled > 0: parts.add $counts.cancelled & " cancelled"
  parts.join(" \xC2\xB7 ")

proc isActive*(run: PlatformRun): bool = run.state in {prsQueued, prsRunning}

proc isActive*(state: TestRunState): bool =
  for run in state.platformRuns:
    if run.isActive: return true
  false

const RollupOrder = [tsErrored, tsFailed, tsCancelled, tsRunning, tsQueued,
                     tsPassed, tsSkipped, tsNotRun]
  ## One test's status across platforms is the first of these any platform
  ## has: a failure anywhere is the test's, and a pass beats a skip.

proc rollupOf*(state: TestRunState; testId: string): CellStatus =
  ## One test's status across the run's platforms (`RollupOrder`).
  var seen: set[CellStatus]
  for c in state.cellsOf(testId): seen.incl c.status
  for s in RollupOrder:
    if s in seen: return s
  tsNotRun

proc summaryLine*(state: TestRunState): string =
  ## The session timeline's line for a test run (one word per test, across
  ## platforms): `Ran 6 tests on 2 platforms: 4 passed, 1 failed, 1 skipped`;
  ## while any platform is active, `Running 6 tests on 2 platforms` and the
  ## results so far.
  var counts: TestCounts
  for testId in state.order: counts.add(state.rollupOf(testId), false)
  let n = state.order.len
  let m = state.platformRuns.len
  let head = (if state.isActive: "Running " else: "Ran ") & $n &
    (if n == 1: " test" else: " tests") & " on " & $m &
    (if m == 1: " platform" else: " platforms")
  var parts: seq[string]
  if counts.passed > 0: parts.add $counts.passed & " passed"
  if counts.failed > 0: parts.add $counts.failed & " failed"
  if counts.errored > 0: parts.add $counts.errored & " errored"
  if counts.skipped > 0: parts.add $counts.skipped & " skipped"
  if counts.cancelled > 0: parts.add $counts.cancelled & " cancelled"
  if parts.len == 0: head else: head & ": " & parts.join(", ")

# ---------------------------------------------------------------------------
# The Verification join
# ---------------------------------------------------------------------------

proc joinVerifications*(catalog: openArray[CatalogTest];
                        verifications: openArray[VerificationEntry]): seq[JoinedVerification] =
  ## Each Verification entry with the catalog test it names: the test whose
  ## id ends in `/` and the entry's test name, or whose name equals it. More
  ## than one such test is no match (a wrong test's status is worse than
  ## none), and a substring is never a match. Entries keep their order.
  for entry in verifications:
    var matches = initOrderedSet[string]()
    let name = entry.testName.strip
    if name.len > 0:
      for test in catalog:
        if test.id.endsWith("/" & name) or test.name == name:
          matches.incl test.id
    var joined = JoinedVerification(entry: entry)
    if matches.len == 1:
      for id in matches: joined.testId = id
    elif matches.len == 0:
      joined.reason = "No test in the catalog is named " & name
    else:
      joined.reason = $matches.len & " tests in the catalog match " & name
    result.add joined

# ---------------------------------------------------------------------------
# What a platform can do
# ---------------------------------------------------------------------------

proc runAbsence*(offers: openArray[PlatformOffer]; features: openArray[string]): string =
  ## Why no run can start on the platform `features`: "" when a backend
  ## serves it; otherwise the refusal, naming the features no offered
  ## platform has beside the ones it shares most
  ## (`No backend serves os.windows arch.aarch64: missing arch.aarch64`).
  let key = platformKey(features)
  let wanted = @features   # worded in the order asked; compared as a set
  let named = "No backend serves " & wanted.join(" ")
  var best = -1
  var bestShared = -1
  for i, offer in offers:
    if platformKey(offer.platform) == key:
      return (if offer.backends.len > 0: "" else: named)
    var shared = 0
    for f in wanted:
      if f in offer.platform.features: inc shared
    if shared > bestShared:
      best = i
      bestShared = shared
  var missing: seq[string]
  for f in wanted:
    if best < 0 or f notin offers[best].platform.features: missing.add f
  named & ": missing " & missing.join(" ")

proc recordAbsence*(offer: PlatformOffer; runner = ""): string =
  ## Why Record is disabled on the offered platform for `runner` ("" for any
  ## runner): "" when some backend's runner can record there; otherwise the
  ## backend's own reason, or one naming the runner and the platform.
  let label = if offer.platform.label.len > 0: offer.platform.label
              else: platformLabel(offer.platform.features)
  if offer.backends.len == 0: return "No backend serves " & label
  var reason = ""
  var runs = false
  for backend in offer.backends:
    for ability in backend.runners:
      if runner.len > 0 and ability.runner != runner: continue
      runs = true
      if ability.canRecord: return ""
      if reason.len == 0: reason = ability.reason
  if reason.len > 0: reason
  elif not runs and runner.len > 0: "No backend runs " & runner & " on " & label
  else: "No recorder for " & (if runner.len > 0: runner & " " else: "") & "on " & label

proc openModeOf*(cell: TestCell; offer: PlatformOffer; shiftHeld: bool): OpenMode =
  ## What the open control does on this cell now, the Test Results pane's
  ## rule: with no recording, record and open (Shift is not consulted); with
  ## one, Shift records again and opens; otherwise open the existing trace,
  ## which runs nothing and is never blocked. The two recording modes are
  ## unavailable while the platform runs the test, or where it cannot record.
  if cell.recording != recRecorded or cell.trace.len == 0:
    result.kind = omRecordAndOpen
  elif shiftHeld:
    result.kind = omRefreshAndOpen
  else:
    return OpenMode(kind: omOpenExisting)
  if cell.status in {tsQueued, tsRunning}:
    result.absence = RunInProgressOnPlatformText
  else:
    result.absence = recordAbsence(offer, cell.runner)
