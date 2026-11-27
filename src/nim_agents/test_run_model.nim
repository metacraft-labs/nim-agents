## nim_agents/test_run_model.nim
##
## AA-2 — a `ct test` execution as the Agent Activity session feed renders it:
## the run summary's plain-value model and its read-only helpers.
##
## Moved from CodeTracer's `viewmodels/test_run_summary_vm.nim` (CTF-M1, D90):
## the Agent Activity viewmodel, now in nim-agents-isonim-viewmodels, holds
## these values. Only the contracts-free half moved. Building a summary from
## the runner's `TestEvent`s (`ingestTestEvent`, `projectTestRun`,
## `parseTestEventLine`, `parseTestRun`) stays in CodeTracer, because
## `ct_test/contracts` is the `ct test` CLI's own wire contract and nim-agents
## never imports it. A host hands the viewmodel its recogniser as a
## `testRunProjector`.
##
## Three rules shape the types below; CodeTracer's `test_run_summary_vm.nim`
## states each one in full, beside the projection that upholds it:
##
## 1. A row's drill-down affordance is a fact about the row, not a guess:
##    `hasRecording` is true only when the runner named a trace path.
## 2. Absent data is stated, never rendered as a zero that reads as success:
##    `summaryText` says "No tests reported" rather than "0 passed".
## 3. A run in flight is distinguishable from a finished one: `inProgress`.
##
## Everything is pure, plain-value and DOM-free, so it is assertable headlessly
## on both Nim backends.

import std/[options, strutils]

type
  TestRunOutcome* = enum
    ## What became of one test.  Wider than the wire's `TestResultStatus`
    ## because a projection of a *partial* stream must be able to say
    ## "started, not finished" — that is the whole point of rule 3 above.
    troRunning = "running"
    troPassed = "passed"
    troFailed = "failed"
    troSkipped = "skipped"
    troErrored = "errored"
    troCancelled = "cancelled"

  TestRunDiagnostic* = object
    ## One recorder/framework diagnostic, reduced to what a feed row shows.
    severity*: string
    message*: string

  TestRunRow* = object
    ## One test inside a run.
    testId*: string
      ## The runner's catalog item id, verbatim.  Stable across events and
      ## used as the row's identity everywhere, including the view's DOM ids.
    name*: string
      ## The short, human-facing name derived from `testId` (see `displayName`).
    outcome*: TestRunOutcome
    durationMs*: int
    output*: string
      ## Captured framework output for this test, in arrival order.  §2.1.2:
      ## "an individual test can be expanded to its status, duration and
      ## captured output."
    diagnostics*: seq[TestRunDiagnostic]
      ## Recorder diagnostics.  §2.1.2 requires these to be *shown* when
      ## recording failed, which is exactly the case where there is no trace.
    tracePath*: string
    traceId*: string
    recordingId*: string
      ## The recording, flattened.  All three are empty unless a
      ## `recording-created` event carried them; see rule 1.
    recordingAttempted*: bool
      ## A `record-started` names this test, so the run was *trying* to
      ## record.  Distinguishes "this run did not record" (no affordance is
      ## expected) from "this run tried to record and failed" (no affordance,
      ## plus diagnostics).

  TestRunSummary* = object
    ## One `ct test` execution.
    runId*: string
    providerId*: string
    commandLine*: string
      ## The command the runner reported in `run-started` / `record-started`.
      ## Quoted, never invented.
    inProgress*: bool
    passed*: int
    failed*: int
    skipped*: int
    errored*: int
    cancelled*: int
    running*: int
    durationMs*: int
    rows*: seq[TestRunRow]
    diagnostics*: seq[TestRunDiagnostic]
      ## Run-level diagnostics — those the runner emitted without a `testId`.
    frameworkOutput*: string
      ## Lines of the stream that were *not* ct-test events, kept verbatim.
      ## §2.1.2: when recording fails "the panel shows the framework output
      ## and recorder diagnostics"; discarding the non-JSON half of a runner's
      ## stdout would throw away precisely the part a human reads.
    openScopes*: int
      ## Run/record scopes started and not yet finished.  Internal to the
      ## incremental projection, but public so a partially-consumed summary
      ## round-trips through a caller that stores it.
    scopeDurationMs*: int
      ## The largest duration any scope-closing event reported, or 0.

proc `==`*(a, b: TestRunDiagnostic): bool {.noSideEffect.} =
  a.severity == b.severity and a.message == b.message

proc `==`*(a, b: TestRunRow): bool {.noSideEffect.} =
  a.testId == b.testId and a.name == b.name and a.outcome == b.outcome and
    a.durationMs == b.durationMs and a.output == b.output and
    a.diagnostics == b.diagnostics and a.tracePath == b.tracePath and
    a.traceId == b.traceId and a.recordingId == b.recordingId and
    a.recordingAttempted == b.recordingAttempted

proc `==`*(a, b: TestRunSummary): bool {.noSideEffect.} =
  a.runId == b.runId and a.providerId == b.providerId and
    a.commandLine == b.commandLine and a.inProgress == b.inProgress and
    a.passed == b.passed and a.failed == b.failed and
    a.skipped == b.skipped and a.errored == b.errored and
    a.cancelled == b.cancelled and a.running == b.running and
    a.durationMs == b.durationMs and a.rows == b.rows and
    a.diagnostics == b.diagnostics and
    a.frameworkOutput == b.frameworkOutput and
    a.openScopes == b.openScopes and a.scopeDurationMs == b.scopeDurationMs

proc hasRecording*(row: TestRunRow): bool {.noSideEffect.} =
  ## Whether this row can be drilled into.
  ##
  ## The single gate for the drill-down affordance, so "shown" and "works"
  ## cannot drift apart (§2.1.2).  A recording exists when the runner said so
  ## *and* named a path; a `recording-created` without one would be a broken
  ## trace tab, which the spec ranks below offering nothing.
  row.tracePath.len > 0

proc recordingFailed*(row: TestRunRow): bool {.noSideEffect.} =
  ## The run tried to record this test and no trace came of it.
  ##
  ## This is the state §2.1.2 singles out: "If recording failed before a trace
  ## was produced, the panel shows the framework output and recorder
  ## diagnostics, and must **not** offer a trace to open."  It is deliberately
  ## *not* the same as `not hasRecording` — a plain `ct test run` records
  ## nothing and has failed at nothing.
  row.recordingAttempted and row.tracePath.len == 0

proc displayName*(testId: string): string {.noSideEffect.} =
  ## The short name for a catalog item id.
  ##
  ## Ids are `provider/language/framework/file::selector`
  ## (`contracts.makeTestItemId`), and the selector is the part a human
  ## recognises.  Falls back to the last path segment, then to the id itself,
  ## because an unrecognised id shape must still render as *something* — a
  ## blank row is indistinguishable from a missing one.
  let separator = testId.rfind("::")
  if separator >= 0 and separator + 2 < testId.len:
    return testId[separator + 2 .. ^1]
  let slash = testId.rfind('/')
  if slash >= 0 and slash + 1 < testId.len:
    return testId[slash + 1 .. ^1]
  testId

proc formatDurationMs*(durationMs: int): string {.noSideEffect.} =
  ## A duration, at the precision a reviewer can act on.
  ##
  ## Sub-second runs are reported in milliseconds because that is the unit the
  ## runner measures in; anything longer rounds, because trailing milliseconds
  ## on a two-minute suite are noise.
  if durationMs < 0:
    return ""
  if durationMs < 1000:
    return $durationMs & "ms"
  if durationMs < 60_000:
    let tenths = (durationMs + 50) div 100
    return $(tenths div 10) & "." & $(tenths mod 10) & "s"
  let totalSeconds = (durationMs + 500) div 1000
  $(totalSeconds div 60) & "m " & $(totalSeconds mod 60) & "s"

proc newTestRunSummary*(): TestRunSummary =
  TestRunSummary(rows: @[], diagnostics: @[])

proc rowIndex*(summary: TestRunSummary; testId: string): int =
  ## The index of the row for `testId`, or -1.
  for i, row in summary.rows:
    if row.testId == testId:
      return i
  -1

proc totalTests*(summary: TestRunSummary): int {.noSideEffect.} =
  summary.rows.len

proc summaryText*(summary: TestRunSummary): string {.noSideEffect.} =
  ## The one line the collapsed card shows.
  ##
  ## Obeys AA-1's preserved rule literally: a run that reported no tests says
  ## so in words rather than printing "0 passed", because a zero there reads
  ## as a suite that ran clean.  See `Agent-Activity-Panel.milestones.org`,
  ## AA-1 deliverable 4, and `review_entry.coverageText`, which returns an
  ## empty badge for the same reason.
  var parts: seq[string] = @[]
  if summary.rows.len == 0:
    if summary.inProgress:
      return "Running tests…"
    return "No tests reported"
  if summary.passed > 0:
    parts.add $summary.passed & " passed"
  if summary.failed > 0:
    parts.add $summary.failed & " failed"
  if summary.errored > 0:
    parts.add $summary.errored & " errored"
  if summary.skipped > 0:
    parts.add $summary.skipped & " skipped"
  if summary.cancelled > 0:
    parts.add $summary.cancelled & " cancelled"
  if summary.running > 0:
    parts.add $summary.running & " running"
  result = parts.join(", ")
  if summary.durationMs > 0:
    result.add " · " & formatDurationMs(summary.durationMs)

proc rowFor*(summary: TestRunSummary; testId: string): Option[TestRunRow]
    {.noSideEffect.} =
  let index = summary.rowIndex(testId)
  if index < 0: none(TestRunRow) else: some(summary.rows[index])
