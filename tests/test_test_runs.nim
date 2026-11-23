## The test-run domain (`nim_agents/agent_harbor/test_runs`), native and JS:
## the platforms, catalogs and events in their proposed shapes, the reducer's
## rules (order, platform keys, repeated and out-of-order events,
## cancellation, reuse, counts), the Verification join, why Record or a run
## is unavailable on a platform, the open control's modes, and the words.
##
## No test doubles: every input is the JSON a test-run read or stream would
## carry, written out here and invented (the runners, tests, ids and traces
## are made up). Expectations are written by hand from the rules in the
## module comment, never computed through the module.

import std/[json, sequtils, unittest]
import nim_agents/agent_harbor/[review_record, test_runs]

const
  Linux = ["os.linux", "arch.x86_64"]
  Mac = ["os.macos", "arch.aarch64"]
  Windows = ["os.windows", "arch.x86_64"]
  RunId = "run-7f3a"

proc ev(kind: string; platform: openArray[string]; fields: JsonNode = nil;
        backend = "reprobuild"; runId = RunId): TestRunEvent =
  ## One event as the stream sends it, with the fields every event carries.
  var node = %*{"kind": kind, "testRunId": runId, "platform": platform,
                "backend": backend, "runner": "pytest"}
  if not fields.isNil:
    for k, v in fields.pairs: node[k] = v
  testRunEventFromJson(node)

proc started(p: openArray[string]; test: string): TestRunEvent =
  ev("test-started", p, %*{"testId": test})

proc finished(p: openArray[string]; test, status: string; ms = 10;
              reused = false): TestRunEvent =
  ev("test-finished", p, %*{"testId": test, "status": status, "durationMs": ms,
                            "reused": reused})

template apply(state: var TestRunState; events: varargs[TestRunEvent]) =
  ## A template, not a proc: a `check` inside a plain proc would not fail the
  ## test it runs in.
  for e in events: check state.applyTestRunEvent(e)

proc statuses(state: TestRunState; platform: openArray[string]): seq[string] =
  ## Each test's status word on one platform, in the state's order.
  for id in state.order: result.add $state.cell(platformKey(platform), id).status

const
  # The catalog's order is neither alphabetical nor by status, so any sort
  # moves it.
  Tests = ["pytest/tests/test_routes.py::test_put", "pytest/tests/test_cache.py::test_evict",
           "pytest/tests/test_routes.py::test_get", "cargo/cache::hits"]

proc newRun(record = rmNone; platforms: seq[seq[string]] = @[@Linux, @Mac]): TestRunState =
  var ps: seq[TestPlatform]
  for p in platforms: ps.add testPlatform(p)
  initTestRunState(RunId, Tests, ps, ["reprobuild", "ah-executors"], record)

suite "reading the proposed shapes":
  test "platform offers: features, backends, runners, recording and its reason":
    let offers = platformOffersFromJson(%*{"platforms": [
      {"features": ["os.linux", "arch.x86_64"], "backends": [
        {"id": "reprobuild", "runners": [{"id": "pytest", "canRecord": true,
                                          "recorders": ["py-rec"]}]},
        {"id": "ah-executors", "runners": ["cargo"]}]},
      {"platform": {"features": ["os.windows", "arch.x86_64"]}, "label": "Windows (CI)",
       "backends": [{"backend": "reprobuild", "runners": [
         {"runner": "pytest", "can_record": false,
          "reason": "No recorder for pytest on Windows x86-64"}]}]},
      {"features": []}]})
    check offers.len == 2                       # a platform with no features is dropped
    check offers[0].platform.features == @["arch.x86_64", "os.linux"]
    check offers[0].platform.label == "Linux x86-64"
    check offers[0].backends.mapIt(it.backend) == @["reprobuild", "ah-executors"]
    check offers[0].backends[0].runners[0].canRecord
    check offers[0].backends[0].runners[0].recorders == @["py-rec"]
    check offers[0].backends[1].runners[0].runner == "cargo"
    check not offers[0].backends[1].runners[0].canRecord
    check offers[1].platform.label == "Windows (CI)"
    check offers[1].backends[0].runners[0].reason == "No recorder for pytest on Windows x86-64"
    check platformOffersFromJson(%*[{"features": ["os.linux"]}]).len == 1
    check platformOffersFromJson(newJNull()).len == 0

  test "a catalog: discovering, discovered, failed; ids, names and files; order kept":
    let c = catalogFromJson(%*{"platform": Linux, "state": "discovered", "tests": [
      {"id": "pytest/tests/test_routes.py::test_put", "name": "test_put",
       "file": "tests/test_routes.py", "line": 12},
      "cargo/cache::hits", {"name": "no id"}]})
    check c.state == csDiscovered
    check c.tests.mapIt(it.id) == @["pytest/tests/test_routes.py::test_put", "cargo/cache::hits"]
    check c.tests[0].runner == "pytest"
    check c.tests[0].line == 12
    check c.tests[1].runner == "cargo"
    check c.tests[1].name == "cache::hits"
    check c.tests[0].platforms == @[platformKey(Linux)]
    check catalogFromJson(%*{"platform": Mac, "state": "discovering"}).state == csDiscovering
    let failed = catalogFromJson(%*{"platform": Windows, "reason": "runner crashed"})
    check failed.state == csFailed
    check failed.reason == "runner crashed"

  test "catalogs merge in the order first seen, with the platforms holding each test":
    let a = catalogFromJson(%*{"platform": Linux, "tests": ["pytest/b", "pytest/a"]})
    let b = catalogFromJson(%*{"platform": Mac, "tests": ["pytest/c", "pytest/a"]})
    let merged = mergeCatalogs([a, b])
    check merged.mapIt(it.id) == @["pytest/b", "pytest/a", "pytest/c"]
    check merged[1].platforms == @[platformKey(Linux), platformKey(Mac)]
    check merged[2].platforms == @[platformKey(Mac)]

  test "events: every kind's fields; an unknown kind is kept by name":
    let f = ev("failure", Linux, %*{"testId": "pytest/t", "message": "assert 1 == 2",
                                    "location": {"file": "tests/t.py", "line": 4}, "id": "e-9"})
    check f.kind == tekFailure
    check f.eventId == "e-9"
    check f.platform == @["arch.x86_64", "os.linux"]     # sorted: the identity
    check f.location == TestLocation(file: "tests/t.py", line: 4)
    check ev("failure", Linux, %*{"location": "tests/t.py:7"}).location ==
      TestLocation(file: "tests/t.py", line: 7)
    check ev("failure", Linux, %*{"location": nil}).location == TestLocation()
    let done = finished(Linux, "pytest/t", "passed", 31)
    check done.hasDuration and done.durationMs == 31
    check not ev("test-finished", Linux, %*{"status": "passed"}).hasDuration
    let totals = ev("run-finished", Linux, %*{"totals": {"passed": 3, "failed": 1}})
    check totals.hasTotals and totals.totals.passed == 3 and totals.totals.failed == 1
    check ev("run-finished", Linux, %*{"cancelled": true}).cancelled
    let why = ev("run-finished", Linux, %*{"cancelled": {"reason": "operator"}})
    check why.cancelled and why.reason == "operator"
    check ev("run-finished", Linux, %*{"status": "cancelled"}).cancelled
    check not ev("run-finished", Linux).cancelled
    let odd = ev("test-paused", Linux)
    check odd.kind == tekUnknown
    check odd.kindText == "test-paused"
    check ev("trace-created", Linux, %*{"trace": "agent-harbor://trace/abc"}).trace ==
      "agent-harbor://trace/abc"

  test "a run as created: its platform runs queued on their backends, every test queued":
    let run = testRunFromJson(%*{"id": RunId, "record": "failing", "reuse": "never",
      "tests": Tests, "createdMs": 5000, "platformRuns": [
        {"platform": Linux, "backend": "reprobuild"},
        {"platform": {"features": Mac}, "backend": "ah-executors", "state": "running",
         "results": [{"testId": Tests[1], "status": "failed", "durationMs": 9,
                      "message": "boom"}]}]})
    check run.id == RunId
    check run.record == rmFailing
    check run.reuse == rpNever
    check run.startedMs == 5000
    check run.platformRuns.mapIt(it.backend) == @["reprobuild", "ah-executors"]
    check run.platformRuns.mapIt(it.state) == @[prsQueued, prsRunning]
    check run.order == @Tests
    check run.statuses(Linux) == @["queued", "queued", "queued", "queued"]
    check run.cell(platformKey(Mac), Tests[1]).status == tsFailed
    check run.cell(platformKey(Mac), Tests[1]).failure == "boom"
    check run.cell(platformKey(Mac), Tests[1]).backend == "ah-executors"

suite "the reducer":
  test "the catalog's order is kept, never sorted, as results arrive":
    var run = newRun()
    run.apply(started(Linux, Tests[3]), finished(Linux, Tests[3], "failed"),
              started(Linux, Tests[0]), finished(Linux, Tests[0], "passed"),
              started(Linux, Tests[2]), finished(Linux, Tests[2], "skipped"))
    check run.order == @Tests
    check run.statuses(Linux) == @["passed", "queued", "skipped", "failed"]

  test "events of two platforms never touch each other's cells":
    var run = newRun()
    run.apply(started(Linux, Tests[0]), finished(Linux, Tests[0], "passed", 12),
              started(Mac, Tests[0]),
              ev("failure", Mac, %*{"testId": Tests[0], "message": "timeout"}),
              finished(Mac, Tests[0], "failed", 3000))
    let linux = run.cell(platformKey(Linux), Tests[0])
    let mac = run.cell(platformKey(Mac), Tests[0])
    check linux.status == tsPassed
    check linux.durationMs == 12
    check linux.failure == ""
    check mac.status == tsFailed
    check mac.failure == "timeout"
    check mac.durationMs == 3000
    check run.cellsOf(Tests[0]).mapIt(it.status) == @[tsPassed, tsFailed]

  test "an event naming a platform the run did not create adds it":
    var run = newRun()
    run.apply(ev("run-started", Windows, backend = "ah-executors"),
              started(Windows, Tests[1]))
    check run.platformRuns.len == 3
    check run.platformRuns[2].platform.label == "Windows x86-64"
    check run.platformRuns[2].backend == "ah-executors"
    check run.platformRuns[2].state == prsRunning
    check run.cell(platformKey(Windows), Tests[1]).status == tsRunning
    check run.cell(platformKey(Windows), Tests[0]).status == tsNotRun

  test "a run in the shape of the synthetic fixture set, one platform, recorded":
    # The two generated synthetic runs' shape: one platform run, its tests
    # one after another, a failure, a skip, a recorded test, `totals`.
    let id = "synthetic-units"
    let p = Linux
    var run = initTestRunState(id, [], [])
    for line in [
        %*{"kind": "run-started", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct"},
        %*{"kind": "test-started", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct", "testId": "ct/a.py::t1"},
        %*{"kind": "test-finished", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct", "testId": "ct/a.py::t1", "status": "passed", "durationMs": 12, "reused": false},
        %*{"kind": "test-started", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct", "testId": "ct/a.py::t2"},
        %*{"kind": "failure", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct", "testId": "ct/a.py::t2", "message": "assert 3.2808 == 3.28084", "location": nil},
        %*{"kind": "test-finished", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct", "testId": "ct/a.py::t2", "status": "failed", "durationMs": 31, "reused": false},
        %*{"kind": "test-finished", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct", "testId": "ct/a.py::t3", "status": "skipped", "durationMs": 0, "reused": false},
        %*{"kind": "trace-started", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct", "testId": "ct/a.py::t1", "recorder": "ct"},
        %*{"kind": "trace-created", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct", "testId": "ct/a.py::t1", "trace": "agent-harbor://trace/synthetic-trace-units"},
        %*{"kind": "run-finished", "testRunId": id, "platform": p, "backend": "local-ct", "runner": "ct", "totals": {"passed": 1, "failed": 1, "skipped": 1}}]:
      check run.applyTestRunEvent(testRunEventFromJson(line))
    check run.order == @["ct/a.py::t1", "ct/a.py::t2", "ct/a.py::t3"]
    check run.statuses(p) == @["passed", "failed", "skipped"]
    check run.platformRuns.len == 1
    check run.platformRuns[0].state == prsFinished
    check run.platformRuns[0].backend == "local-ct"
    let t1 = run.cell(platformKey(p), "ct/a.py::t1")
    check t1.recording == recRecorded
    check t1.trace == "agent-harbor://trace/synthetic-trace-units"
    check t1.recorder == "ct"
    check run.cell(platformKey(p), "ct/a.py::t2").failure == "assert 3.2808 == 3.28084"
    check run.countsOf == TestCounts(passed: 1, failed: 1, skipped: 1)

  test "an event of another run is ignored":
    var run = newRun()
    check not run.applyTestRunEvent(ev("test-started", Linux, %*{"testId": Tests[0]},
                                       runId = "run-other"))
    check run.cell(platformKey(Linux), Tests[0]).status == tsQueued

  test "counts are the cells', not `totals`, once a test reported":
    var run = newRun()
    run.apply(ev("run-started", Linux), started(Linux, Tests[0]),
              finished(Linux, Tests[0], "passed"), finished(Linux, Tests[1], "failed"),
              ev("run-finished", Linux, %*{"totals": {"passed": 40, "failed": 0}}))
    check run.countsOf(platformKey(Linux)) == TestCounts(passed: 1, failed: 1)
    check run.countsOf(platformKey(Linux)).countsText == "1 passed \xC2\xB7 1 failed"

  test "`totals` count for a platform no test event reached":
    var run = newRun()
    run.apply(ev("run-finished", Mac, %*{"totals": {"passed": 0, "cancelled": 4},
                                         "cancelled": true}))
    check run.countsOf(platformKey(Mac)) == TestCounts(cancelled: 4)

  test "a trace-created before its test-finished is kept":
    var run = newRun(rmAll)
    run.apply(started(Linux, Tests[0]),
              ev("trace-created", Linux, %*{"testId": Tests[0], "trace": "agent-harbor://trace/t-1"}),
              finished(Linux, Tests[0], "failed"), ev("run-finished", Linux))
    let c = run.cell(platformKey(Linux), Tests[0])
    check c.status == tsFailed
    check c.recording == recRecorded
    check c.trace == "agent-harbor://trace/t-1"

  test "an unknown kind is kept, not dropped":
    var run = newRun()
    check run.applyTestRunEvent(ev("test-retried", Linux, %*{"testId": Tests[0]}))
    check run.unknown.len == 1
    check run.unknown[0].kindText == "test-retried"
    check run.cell(platformKey(Linux), Tests[0]).status == tsQueued

  test "a repeated run-started keeps the platform's finished tests":
    var run = newRun()
    run.apply(ev("run-started", Linux), finished(Linux, Tests[0], "passed"),
              ev("run-finished", Linux), ev("run-started", Linux),
              finished(Linux, Tests[1], "failed"))
    check run.statuses(Linux) == @["passed", "failed", "queued", "queued"]
    check run.platformRuns[0].state == prsRunning

  test "a cancellation ends the platform's unfinished cells, keeping finished ones":
    var run = newRun()
    run.apply(ev("run-started", Linux), finished(Linux, Tests[0], "passed"),
              started(Linux, Tests[1]), started(Mac, Tests[0]),
              ev("run-finished", Linux, %*{"cancelled": {"reason": "operator"}}))
    check run.statuses(Linux) == @["passed", "cancelled", "cancelled", "cancelled"]
    check run.platformRuns[0].state == prsCancelled
    check run.platformRuns[0].cancelReason == "operator"
    # The other platform is untouched.
    check run.cell(platformKey(Mac), Tests[0]).status == tsRunning
    check run.platformRuns[1].state == prsRunning
    check run.isActive

  test "a reused result is passed, reused, with its certificate and never a duration":
    var run = newRun()
    run.apply(ev("test-finished", Linux, %*{"testId": Tests[0], "status": "passed",
                 "durationMs": 250, "reused": true, "certificate": "cert-91"}),
              finished(Linux, Tests[1], "passed", 40))
    let reused = run.cell(platformKey(Linux), Tests[0])
    check reused.status == tsPassed
    check reused.reused
    check reused.certificate == "cert-91"
    check not reused.hasDuration
    check reused.durationMs == 0
    let ran = run.cell(platformKey(Linux), Tests[1])
    check not ran.reused and ran.hasDuration and ran.durationMs == 40
    check run.countsOf(platformKey(Linux)) == TestCounts(passed: 2, reused: 1)
    check run.countsOf(platformKey(Linux)).countsText == "2 passed (1 reused)"
    # A failure is never "reused", whatever the flag says.
    run.apply(ev("test-finished", Linux, %*{"testId": Tests[2], "status": "failed",
                                            "reused": true, "durationMs": 5}))
    check not run.cell(platformKey(Linux), Tests[2]).reused

  test "a recording started and not created, or asked for and not made, was not kept":
    var run = newRun(rmFailing)
    run.apply(ev("trace-started", Linux, %*{"testId": Tests[0], "recorder": "py-rec"}),
              finished(Linux, Tests[0], "failed"), finished(Linux, Tests[1], "failed"),
              finished(Linux, Tests[2], "passed"), ev("run-finished", Linux))
    check run.cell(platformKey(Linux), Tests[0]).recording == recDiscarded
    check run.cell(platformKey(Linux), Tests[1]).recording == recDiscarded
    check run.cell(platformKey(Linux), Tests[2]).recording == recNone  # not asked for
    var plain = newRun()
    plain.apply(finished(Linux, Tests[1], "failed"), ev("run-finished", Linux))
    check plain.cell(platformKey(Linux), Tests[1]).recording == recNone

  test "diagnostics: a run's under its platform, a test's under its cell":
    var run = newRun()
    run.apply(ev("diagnostic", Linux, %*{"message": "executor slow", "level": "warning"}),
              ev("diagnostic", Linux, %*{"testId": Tests[0], "message": "flaky", "level": "info"}))
    check run.platformRuns[0].diagnostics == @[Diagnostic(level: "warning", text: "executor slow")]
    check run.cell(platformKey(Linux), Tests[0]).diagnostics ==
      @[Diagnostic(level: "info", text: "flaky")]

  test "output lines keep their stream, in order":
    var run = newRun()
    run.apply(ev("output", Linux, %*{"testId": Tests[0], "stream": "stdout", "text": "a"}),
              ev("output", Linux, %*{"testId": Tests[0], "stream": "stderr", "text": "b"}))
    check run.cell(platformKey(Linux), Tests[0]).output ==
      @[OutputLine(stream: "stdout", text: "a"), OutputLine(stream: "stderr", text: "b")]

suite "the Verification join":
  let catalog = mergeCatalogs([catalogFromJson(%*{"platform": Linux, "tests": [
    {"id": "pytest/tests/test_routes.py::test_put", "name": "test_put"},
    {"id": "pytest/tests/test_cache.py::test_evict", "name": "test_evict"},
    {"id": "cargo/cache::hits", "name": "hits"},
    {"id": "cargo/cache::misses", "name": "hits"}]})])

  proc entry(name: string): VerificationEntry =
    VerificationEntry(milestoneId: "M1", testName: name)

  test "by the id's suffix, or by the exact name":
    let joined = joinVerifications(catalog, [entry("tests/test_routes.py::test_put"),
                                             entry("test_evict")])
    check joined[0].testId == "pytest/tests/test_routes.py::test_put"
    check joined[1].testId == "pytest/tests/test_cache.py::test_evict"
    check joined[0].entry.milestoneId == "M1"

  test "two matches is no match; a substring is never a match; empty is none":
    let joined = joinVerifications(catalog, [entry("hits"), entry("evict"),
                                             entry("test_routes.py"), entry("  ")])
    check joined.mapIt(it.testId) == @["", "", "", ""]
    check joined[0].reason == "2 tests in the catalog match hits"
    check joined[1].reason == "No test in the catalog is named evict"
    check joined[2].testId == ""

suite "what a platform can do":
  let offers = platformOffersFromJson(%*[
    {"features": Linux, "backends": [{"id": "reprobuild", "runners": [
      {"id": "pytest", "canRecord": true}, {"id": "cargo"}]}]},
    {"features": Windows, "backends": [{"id": "reprobuild", "runners": [
      {"id": "pytest", "canRecord": false, "reason": "No recorder for pytest on Windows x86-64"}]}]},
    {"features": Mac, "backends": []}])

  test "Record is disabled with the backend's reason, or one naming what is missing":
    check offers[0].recordAbsence("pytest") == ""
    check offers[0].recordAbsence() == ""                 # some runner can record
    check offers[0].recordAbsence("cargo") == "No recorder for cargo on Linux x86-64"
    check offers[0].recordAbsence("go") == "No backend runs go on Linux x86-64"
    check offers[1].recordAbsence("pytest") == "No recorder for pytest on Windows x86-64"
    check offers[1].recordAbsence() == "No recorder for pytest on Windows x86-64"
    check offers[2].recordAbsence("pytest") == "No backend serves macOS arm64"

  test "an unservable platform is refused, naming the missing features":
    check offers.runAbsence(Linux) == ""
    check offers.runAbsence(["os.windows", "arch.aarch64"]) ==
      "No backend serves os.windows arch.aarch64: missing arch.aarch64"
    check offers.runAbsence(["os.freebsd", "arch.riscv64"]) ==
      "No backend serves os.freebsd arch.riscv64: missing os.freebsd arch.riscv64"
    check offers.runAbsence(Mac) == "No backend serves os.macos arch.aarch64"
    check newSeq[PlatformOffer]().runAbsence(Linux) ==
      "No backend serves os.linux arch.x86_64: missing os.linux arch.x86_64"

  test "the open control's modes, the Test Results pane's rule":
    let key = platformKey(Linux)
    let recorded = TestCell(platform: key, status: tsFailed, recording: recRecorded,
                            trace: "agent-harbor://trace/t-1", runner: "pytest")
    let none = TestCell(platform: key, status: tsPassed, runner: "pytest")
    let discarded = TestCell(platform: key, status: tsPassed, recording: recDiscarded,
                             runner: "pytest")
    let running = TestCell(platform: key, status: tsRunning, runner: "pytest")
    let runningRecorded = TestCell(platform: key, status: tsRunning,
      recording: recRecorded, trace: "agent-harbor://trace/t-1", runner: "pytest")
    # (cell, offer, shift) -> (mode, absence)
    check openModeOf(recorded, offers[0], false) == OpenMode(kind: omOpenExisting)
    check openModeOf(recorded, offers[0], true) == OpenMode(kind: omRefreshAndOpen)
    check openModeOf(none, offers[0], false) == OpenMode(kind: omRecordAndOpen)
    check openModeOf(none, offers[0], true) == OpenMode(kind: omRecordAndOpen)
    check openModeOf(discarded, offers[0], false) == OpenMode(kind: omRecordAndOpen)
    # Opening what exists runs nothing, so nothing blocks it.
    check openModeOf(runningRecorded, offers[0], false) == OpenMode(kind: omOpenExisting)
    check openModeOf(runningRecorded, offers[0], true) ==
      OpenMode(kind: omRefreshAndOpen, absence: RunInProgressOnPlatformText)
    check openModeOf(running, offers[0], false) ==
      OpenMode(kind: omRecordAndOpen, absence: RunInProgressOnPlatformText)
    check openModeOf(none, offers[1], false) ==
      OpenMode(kind: omRecordAndOpen, absence: "No recorder for pytest on Windows x86-64")
    check openModeOf(recorded, offers[1], false) == OpenMode(kind: omOpenExisting)
    check $omOpenExisting == "open-existing"
    check $omRefreshAndOpen == "refresh-and-open"
    check $omRecordAndOpen == "record-and-open"

suite "words":
  test "platform labels, status words and backend chips":
    check platformLabel(Linux) == "Linux x86-64"
    check platformLabel(Mac) == "macOS arm64"
    check platformLabel(Windows) == "Windows x86-64"
    check platformLabel(["os.linux", "arch.riscv64", "gpu.cuda"]) == "Linux arch.riscv64 gpu.cuda"
    check platformKey(Linux) == "arch.x86_64+os.linux"
    check platformKey(["os.linux", "arch.x86_64"]) == platformKey(["arch.x86_64", "os.linux"])
    check CellStatus.toSeq.mapIt(statusWord(it)) == @["not run", "queued", "running",
      "passed", "failed", "skipped", "errored", "cancelled"]
    check backendLabel("ah-executors") == "ah-executors"
    check backendLabel("") == "unknown backend"
    check runnerOf("pytest/tests/a.py::t") == "pytest"
    check runnerOf("bare") == ""

  test "the summary line: one word per test, across platforms":
    var run = newRun()
    check run.summaryLine == "Running 4 tests on 2 platforms"
    run.apply(finished(Linux, Tests[0], "passed"), finished(Mac, Tests[0], "failed"),
              finished(Linux, Tests[1], "passed"), finished(Mac, Tests[1], "passed"),
              finished(Linux, Tests[2], "skipped"), finished(Mac, Tests[2], "passed"),
              finished(Linux, Tests[3], "skipped"), finished(Mac, Tests[3], "skipped"),
              ev("run-finished", Linux), ev("run-finished", Mac))
    check not run.isActive
    check run.rollupOf(Tests[0]) == tsFailed
    check run.rollupOf(Tests[2]) == tsPassed
    check run.summaryLine == "Ran 4 tests on 2 platforms: 2 passed, 1 failed, 1 skipped"
    var one = initTestRunState(RunId, ["pytest/x"], [testPlatform(Linux)])
    one.apply(finished(Linux, "pytest/x", "errored"))
    check one.summaryLine == "Running 1 test on 1 platform: 1 errored"

suite "illegal orders and malformed input":
  test "a test-started never undoes a result, whether late or repeated":
    var run = newRun()
    run.apply(ev("run-started", Linux), finished(Linux, Tests[0], "passed", 7))
    check not run.applyTestRunEvent(started(Linux, Tests[0]))
    check run.cell(platformKey(Linux), Tests[0]).status == tsPassed
    check run.cell(platformKey(Linux), Tests[0]).durationMs == 7
    # A second start of a running test is no change either way: still running.
    run.apply(started(Linux, Tests[1]))
    discard run.applyTestRunEvent(started(Linux, Tests[1]))
    check run.cell(platformKey(Linux), Tests[1]).status == tsRunning
    # A finish after a finish is the newer result.
    run.apply(finished(Linux, Tests[1], "failed"), finished(Linux, Tests[1], "passed"))
    check run.cell(platformKey(Linux), Tests[1]).status == tsPassed

  test "a finished or cancelled platform run hears no new start until it starts again":
    var run = newRun(rmAll)
    run.apply(ev("run-started", Linux), started(Linux, Tests[0]),
              ev("run-finished", Linux, %*{"cancelled": true}))
    check run.cell(platformKey(Linux), Tests[1]).status == tsCancelled
    check not run.applyTestRunEvent(started(Linux, Tests[1]))
    check not run.applyTestRunEvent(ev("trace-started", Linux, %*{"testId": Tests[0]}))
    check run.cell(platformKey(Linux), Tests[1]).status == tsCancelled
    # The cancelled test was never asked a recording of a result, and the
    # late trace-started does not start one.
    check run.cell(platformKey(Linux), Tests[0]).recording == recNone
    check run.platformRuns[0].state == prsCancelled
    # Its next run-started opens it again.
    run.apply(ev("run-started", Linux), started(Linux, Tests[2]))
    check run.cell(platformKey(Linux), Tests[2]).status == tsRunning

  test "an event naming no platform, or a test event naming no test, changes nothing":
    var run = newRun()
    let before = run
    for node in [%*{"kind": "test-started", "testRunId": RunId, "testId": Tests[0]},
                 %*{"kind": "test-started", "testRunId": RunId, "platform": [],
                    "testId": Tests[0]},
                 %*{"kind": "run-started", "testRunId": RunId, "platform": "os.linux"},
                 %*{"kind": "test-finished", "testRunId": RunId, "platform": Linux,
                    "status": "passed"},
                 %*{"kind": "trace-created", "testRunId": RunId, "platform": Linux,
                    "testId": "", "trace": "agent-harbor://trace/x"},
                 %*{"kind": "output", "testRunId": RunId, "platform": Linux, "text": "x"}]:
      check not run.applyTestRunEvent(testRunEventFromJson(node))
    check run.platformRuns.len == before.platformRuns.len
    check run.order == before.order
    check run.statuses(Linux) == before.statuses(Linux)
    check run.countsOf == before.countsOf

  test "hostile JSON never raises, and reads as nothing or as the fields it has":
    for node in [newJNull(), %*[], %*42, %*"run", %*{"kind": 7}, %*{"platform": {"features": 3}},
                 %*{"kind": "test-finished", "platform": [1, nil, "os.linux"],
                    "testId": "t", "durationMs": "long", "totals": [1],
                    "location": 5, "cancelled": 1},
                 %*{"kind": "failure", "location": "file.py:99999999999999999999999"},
                 %*{"kind": "failure", "location": ":"},
                 %*{"kind": "run-finished", "platform": Linux, "durationMs": 1e300,
                    "totals": {"passed": 1e300, "failed": -1e300, "skipped": 1e10}},
                 %*{"platform": Linux, "tests": [{"id": "a/b", "line": 1e300}],
                    "location": {"file": "f", "line": -1e300}}]:
      var run = newRun()
      discard run.applyTestRunEvent(testRunEventFromJson(node))
      discard platformOffersFromJson(node)
      discard catalogFromJson(node)
      discard testRunFromJson(node)
    let e = testRunEventFromJson(%*{"kind": "test-finished", "platform": [1, nil, "os.linux"],
                                    "durationMs": "long", "location": "a.py:x"})
    check e.platform == @["os.linux"]
    check not e.hasDuration
    check e.location == TestLocation(file: "a.py:x")
    check testRunEventFromJson(%*{"kind": "failure",
      "location": "f.py:99999999999999999999999"}).location.line == 0
    # A number past what every target's `int` holds is held at the bound.
    let huge = testRunEventFromJson(%*{"kind": "run-finished", "platform": Linux,
      "totals": {"passed": 1e300, "failed": -1e300}, "location": {"line": 1e300}})
    check huge.totals.passed == int(high(int32))
    check huge.totals.failed == int(low(int32))
    check huge.location.line == int(high(int32))

  test "a catalog test with no runner prefix keeps its whole id as its name":
    let catalog = catalogFromJson(%*{"platform": Linux, "tests": [
      "bare_test", {"id": "plain"}, {"id": "other/x", "runner": "pytest"},
      {"id": "pytest/a::t"}]})
    check catalog.tests.mapIt(it.name) == @["bare_test", "plain", "other/x", "a::t"]
    check catalog.tests.mapIt(it.runner) == @["", "", "pytest", "pytest"]
