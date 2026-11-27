## The run summary's plain-value model (`nim_agents/test_run_model`), native
## and JS: the drill-down gate, the failed-recording state, the short test
## name, durations, the collapsed card's line and the row lookups. Building a
## summary from runner events stays in CodeTracer (D90), so every summary here
## is written out by hand. The data is invented, as everything in this public
## repository.

import std/[options, unittest]
import nim_agents/test_run_model

proc row(testId: string; outcome: TestRunOutcome; tracePath = "";
         attempted = false): TestRunRow =
  TestRunRow(testId: testId, name: displayName(testId), outcome: outcome,
             tracePath: tracePath, recordingAttempted: attempted)

suite "test run model":
  test "a row offers a drill-down only when the runner named a trace":
    check row("t", troPassed, tracePath = "/tmp/a.ct").hasRecording
    check not row("t", troPassed).hasRecording
    check not row("t", troFailed, attempted = true).hasRecording

  test "a failed recording is an attempt with no trace, not merely no trace":
    check row("t", troFailed, attempted = true).recordingFailed
    check not row("t", troPassed).recordingFailed
    check not row("t", troPassed, tracePath = "/tmp/a.ct",
                  attempted = true).recordingFailed

  test "the short name is the selector, then the last segment, then the id":
    check displayName("nim/nim/unittest/tests/a.nim::adds two") == "adds two"
    check displayName("nim/nim/unittest/tests/a.nim") == "a.nim"
    check displayName("plain") == "plain"
    check displayName("trailing::") == "trailing::"
    check displayName("") == ""

  test "durations at the precision a reviewer acts on":
    check formatDurationMs(-1) == ""
    check formatDurationMs(0) == "0ms"
    check formatDurationMs(999) == "999ms"
    check formatDurationMs(1000) == "1.0s"
    check formatDurationMs(1249) == "1.2s"
    check formatDurationMs(1250) == "1.3s"
    check formatDurationMs(59_949) == "59.9s"
    check formatDurationMs(60_000) == "1m 0s"
    check formatDurationMs(125_400) == "2m 5s"

  test "a run with no tests says so in words, never 0 passed":
    var summary = newTestRunSummary()
    check summary.totalTests == 0
    check summary.summaryText == "No tests reported"
    summary.inProgress = true
    check summary.summaryText == "Running tests…"

  test "the collapsed line names only the counts that are not zero":
    var summary = newTestRunSummary()
    summary.rows = @[row("a", troPassed), row("b", troPassed),
                     row("c", troFailed), row("d", troRunning)]
    summary.passed = 2
    summary.failed = 1
    summary.running = 1
    check summary.summaryText == "2 passed, 1 failed, 1 running"
    summary.durationMs = 1500
    check summary.summaryText == "2 passed, 1 failed, 1 running · 1.5s"
    summary.passed = 0
    summary.failed = 0
    summary.running = 0
    summary.errored = 1
    summary.skipped = 2
    summary.cancelled = 3
    summary.durationMs = 0
    check summary.summaryText == "1 errored, 2 skipped, 3 cancelled"

  test "rows are found by test id":
    var summary = newTestRunSummary()
    summary.rows = @[row("a", troPassed), row("b", troFailed)]
    check summary.rowIndex("b") == 1
    check summary.rowIndex("z") == -1
    check summary.rowFor("a").get.outcome == troPassed
    check summary.rowFor("z").isNone

  test "equality compares every field":
    var a = newTestRunSummary()
    a.rows = @[row("a", troPassed)]
    var b = a
    check a == b
    b.rows[0].diagnostics.add TestRunDiagnostic(severity: "error",
                                                message: "boom")
    check a != b
    b = a
    b.scopeDurationMs = 1
    check a != b
