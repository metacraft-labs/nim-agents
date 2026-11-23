## Links in an agent's messages (`nim_agents/agent_harbor/trace_links`),
## native and JS: the two trace-link kinds and their labels, the https form
## on the session's server only, every malformed case and why, queries kept,
## file links from link-span events, a message split into parts that join
## back to it exactly, and the replay and download words.
##
## No test doubles: the inputs are message texts and link-span events in
## their wire shape, written out here and invented (ids, hosts and paths are
## made up). Expectations are written by hand from the module comment.

import std/[json, sequtils, strutils, unittest]
import nim_agents/agent_harbor/trace_links

const
  Origin = "https://ah.example.test"

proc reasonOf(text: string; origin = Origin): string =
  parseTraceReference(text, origin).reason

suite "a trace reference":
  test "the Agent Harbor form, with its https form when the server is known":
    let p = parseTraceReference("agent-harbor://trace/7c1e-a.b_c", Origin)
    check p.ok
    check p.reference.kind == trkAgentHarbor
    check p.reference.id == "7c1e-a.b_c"
    check p.reference.url == "agent-harbor://trace/7c1e-a.b_c"
    check p.reference.httpsUrl == "https://ah.example.test/trace/7c1e-a.b_c"
    check p.reference.query == ""
    let unknown = parseTraceReference("agent-harbor://trace/abc", "")
    check unknown.ok
    check unknown.reference.httpsUrl == ""

  test "the https form on the session's server is the same trace":
    let a = parseTraceReference("https://ah.example.test/trace/abc", Origin)
    let b = parseTraceReference("agent-harbor://trace/abc", Origin)
    check a.ok and b.ok
    check a.reference == b.reference
    # The origin compares without case, given with or without a slash or scheme.
    check parseTraceReference("HTTPS://AH.Example.Test/trace/abc", Origin).reference ==
      b.reference
    check parseTraceReference("https://ah.example.test/trace/abc", "ah.example.test/").ok
    check parseTraceReference("https://ah.example.test:8443/trace/abc",
                              "https://ah.example.test:8443").ok

  test "an https URL anywhere else is never a trace, and says nothing":
    for text in ["https://elsewhere.test/trace/abc",
                 "https://ah.example.test.evil.test/trace/abc",
                 "https://ah.example.test:8443/trace/abc",
                 "https://ah.example.test/traces/abc",
                 "https://ah.example.test/TRACE/abc",
                 "http://ah.example.test/trace/abc"]:
      let p = parseTraceReference(text, Origin)
      check not p.ok
      check p.reason == ""
    # With no known server, no https URL is a trace.
    check not parseTraceReference("https://ah.example.test/trace/abc", "").ok

  test "a query is kept, in both forms":
    let p = parseTraceReference("agent-harbor://trace/abc?at=120&step=4", Origin)
    check p.ok
    check p.reference.id == "abc"
    check p.reference.query == "at=120&step=4"
    check p.reference.url == "agent-harbor://trace/abc?at=120&step=4"
    check p.reference.httpsUrl == "https://ah.example.test/trace/abc?at=120&step=4"
    check parseTraceReference("https://ah.example.test/trace/abc?x=1", Origin).reference.query ==
      "x=1"
    check parseTraceReference("agent-harbor://trace/abc?", Origin).reference.url ==
      "agent-harbor://trace/abc?"

  test "malformed ids are refused, each with why":
    check reasonOf("agent-harbor://trace/") == "the trace id is empty"
    check reasonOf("agent-harbor://trace/?q=1") == "the trace id is empty"
    check reasonOf("agent-harbor://trace/.") == "the trace id may not be `.`"
    check reasonOf("agent-harbor://trace/..") == "the trace id may not be `..`"
    check reasonOf("agent-harbor://trace/" & 'a'.repeat(129)) ==
      "the trace id is longer than 128 characters"
    check parseTraceReference("agent-harbor://trace/" & 'a'.repeat(128), Origin).ok
    check reasonOf("agent-harbor://trace/a%20b") ==
      "the trace id has `%`, outside A-Z, a-z, 0-9, `.`, `_`, `-`"
    check reasonOf("agent-harbor://trace/ab$") ==
      "the trace id has `$`, outside A-Z, a-z, 0-9, `.`, `_`, `-`"
    check reasonOf("agent-harbor://trace/abc/def") == "only a query may follow the trace id"
    check reasonOf("agent-harbor://trace/abc/") == "only a query may follow the trace id"
    check reasonOf("agent-harbor://trace/abc#frag") == "only a query may follow the trace id"
    check reasonOf("agent-harbor://trace/abc?x#frag") == "only a query may follow the trace id"
    check reasonOf("https://ah.example.test/trace/..") == "the trace id may not be `..`"
    check reasonOf("agent-harbor://session/abc") ==
      "an Agent Harbor link names no trace (`agent-harbor://trace/<id>`)"
    check not parseTraceReference("agent-harbor://trace/", Origin).ok
    check reasonOf("plain words") == ""

  test "a CodeTracer recording link is a local recording, never an Agent Harbor trace":
    let p = parseTraceReference("codetracer://recordings/drained_field_fails?pass=5", Origin)
    check p.ok
    check p.reference.kind == trkLocalRecording
    check p.reference.id == "drained_field_fails"
    check p.reference.query == "pass=5"
    check p.reference.url == "codetracer://recordings/drained_field_fails?pass=5"
    check p.reference.httpsUrl == ""            # no https form: it is on this machine
    check reasonOf("codetracer://recordings/") == "the test name is empty"
    check reasonOf("codetracer://recordings/a/b") == "only a query may follow the test name"
    check reasonOf("codetracer://traces/abc") ==
      "a CodeTracer link names no recording (`codetracer://recordings/<test>`)"
    check parseTraceReference("codetracer://recordings/x", Origin).kind == trkLocalRecording

  test "the two kinds are labelled differently, and named by their targets":
    let trace = parseTraceReference("agent-harbor://trace/abc", Origin).reference
    let rec = parseTraceReference("codetracer://recordings/t_1", Origin).reference
    check actionLabel(trace.kind) == "Load trace"
    check actionLabel(rec.kind) == "Open recording"
    check accessibleName(trace) == "Trace abc"
    check accessibleName(rec) == "Recording t_1"
    check notALinkText(trkAgentHarbor, "the trace id is empty") ==
      "Not a trace link: the trace id is empty"
    check notALinkText(trkLocalRecording, "the test name is empty") ==
      "Not a recording link: the test name is empty"

suite "file links":
  let spans = linkSpansFromJson(%*[
    {"kind": 0, "start": 5, "end": 15, "targets": [
      {"path": "src/a.nim", "exists": true, "is_dir": false,
       "modified_in_session": true, "line": 12, "col": 3}]},
    {"kind": 1, "start": 0, "end": 4, "targets": [{"path": "term.txt"}]},
    {"kind": 0, "start": 20, "end": 24, "targets": []},
    {"kind": 0, "start": 30, "end": 34, "targets": [{"path": "x"}, {"exists": true}]}])

  test "link-span events: activity spans with targets only; a target exists unless it says not":
    check spans.len == 2
    check spans[0].start == 5 and spans[0].finish == 15
    check spans[0].targets[0] == FileTarget(path: "src/a.nim", exists: true,
      isDir: false, modifiedInSession: true, line: 12, column: 3)
    check spans[1].targets == @[FileTarget(path: "x", exists: true)]
    check linkSpansFromJson(%*{"spans": [{"kind": 0, "start": 0, "end": 1,
                                          "targets": [{"path": "p"}]}]}).len == 1

  test "unique, ambiguous, missing, directory":
    let a = FileTarget(path: "src/a.nim", exists: true, line: 4)
    let b = FileTarget(path: "lib/a.nim", exists: true)
    let gone = FileTarget(path: "old/a.nim", exists: false)
    let dir = FileTarget(path: "src", exists: true, isDir: true)
    check fileLinkState([a]) == flUnique
    check fileLinkState([a, gone]) == flUnique
    check fileLinkState([a, b]) == flAmbiguous
    check fileLinkState([gone]) == flMissing
    check fileLinkState(newSeq[FileTarget]()) == flMissing
    check fileLinkState([dir]) == flDirectory
    check fileLinkTitle([a, gone]) == "Open src/a.nim:4"
    check fileLinkTitle([gone]) == "File not found in this session"
    check fileLinkTitle([dir]) == "src is a directory; nothing to open"
    check fileLinkTitle([a, b]) == "Several files match; choose one"

suite "a message as parts":
  test "the parts join back to the message exactly":
    let texts = [
      "",
      "no links here",
      "See agent-harbor://trace/abc.",
      "(agent-harbor://trace/abc) and https://ah.example.test/trace/def, then codetracer://recordings/t1?pass=5!",
      "bad: agent-harbor://trace/ and https://elsewhere.test/x",
      "x://y agent-harbor://trace/a b"]
    for text in texts:
      check linkSpans(text, Origin).joinedText == text

  test "trace links of both kinds, each its own part, trailing punctuation left to the prose":
    let text = "Failing run: agent-harbor://trace/abc. Local: codetracer://recordings/t1?pass=5, done"
    let parts = linkSpans(text, Origin)
    check parts.mapIt(it.kind) == @[lpText, lpTrace, lpText, lpTrace, lpText]
    check parts[1].text == "agent-harbor://trace/abc"
    check parts[1].reference.kind == trkAgentHarbor
    check parts[2].text == ". Local: "
    check parts[3].text == "codetracer://recordings/t1?pass=5"
    check parts[3].reference.kind == trkLocalRecording
    check parts[4].text == ", done"

  test "the https form on this server is a trace; elsewhere a plain link":
    let parts = linkSpans("a https://ah.example.test/trace/abc b https://elsewhere.test/trace/abc",
                          Origin)
    check parts.mapIt(it.kind) == @[lpText, lpTrace, lpText, lpUrl]
    check parts[1].reference.id == "abc"
    check parts[3].text == "https://elsewhere.test/trace/abc"
    check linkSpans("https://ah.example.test/trace/abc", "").mapIt(it.kind) == @[lpUrl]

  test "a malformed link stays text, with why":
    let parts = linkSpans("see agent-harbor://trace/.. now", Origin)
    check parts.mapIt(it.kind) == @[lpText, lpText, lpText]
    check parts[1].text == "agent-harbor://trace/.."
    check parts[1].reason == "Not a trace link: the trace id may not be `..`"
    check parts[0].reason == "" and parts[2].reason == ""
    let rec = linkSpans("codetracer://recordings/", Origin)
    check rec.len == 1
    check rec[0].reason == "Not a recording link: the test name is empty"

  test "a link starts only at a word's start":
    let parts = linkSpans("xagent-harbor://trace/abc", Origin)
    check parts.mapIt(it.kind) == @[lpText]

  test "file links from the spans, with links read around them":
    let text = "Edited src/a.nim, see agent-harbor://trace/abc"
    let spans = @[FileLinkSpan(start: 7, finish: 16,
                               targets: @[FileTarget(path: "src/a.nim", exists: true)])]
    let parts = linkSpans(text, Origin, spans)
    check parts.mapIt(it.kind) == @[lpText, lpFile, lpText, lpTrace]
    check parts[1].text == "src/a.nim"
    check parts[1].targets[0].path == "src/a.nim"
    check parts.joinedText == text

  test "file spans outside the text, empty, or overlapping are dropped; the earliest wins":
    let t = @[FileTarget(path: "p", exists: true)]
    let text = "abcdefghij"
    let parts = linkSpans(text, Origin, [
      FileLinkSpan(start: 2, finish: 5, targets: t),
      FileLinkSpan(start: 4, finish: 8, targets: t),      # overlaps the first
      FileLinkSpan(start: 6, finish: 6, targets: t),      # empty
      FileLinkSpan(start: 8, finish: 11, targets: t),     # past the end
      FileLinkSpan(start: 0, finish: 1, targets: @[])])   # no target
    check parts.mapIt(it.kind) == @[lpText, lpFile, lpText]
    check parts[1].text == "cde"
    check parts.joinedText == text

suite "replay and download":
  test "the states' words":
    check unavailable("executor offline").unavailableText ==
      "Replay unavailable: executor offline"
    check unavailable("executor offline").canRetry
    let gone = unavailable(TraceGoneText, canRetry = false)
    check not gone.canRetry
    check gone.unavailableText == "Replay unavailable: This trace is no longer stored"
    check ReplayState(phase: rpReplaying).unavailableText == ""
    check DownloadState(phase: dpDownloading).downloadText == "Downloading\xE2\x80\xA6"
    check DownloadState(phase: dpSaved, name: "abc.ct").downloadText == "Saved abc.ct"
    check DownloadState(phase: dpFailed, reason: "disk full").downloadText ==
      "Download failed: disk full"
    check DownloadState().downloadText == ""

suite "hostile input":
  test "control characters, non-ASCII bytes and a query's spaces are refused, and never copied":
    check reasonOf("agent-harbor://trace/a\x00b") ==
      "the trace id has a character, outside A-Z, a-z, 0-9, `.`, `_`, `-`"
    check reasonOf("agent-harbor://trace/caf\xC3\xA9") ==
      "the trace id has a character, outside A-Z, a-z, 0-9, `.`, `_`, `-`"
    check reasonOf("codetracer://recordings/t\x1B[31m") ==
      "the test name has a character, outside A-Z, a-z, 0-9, `.`, `_`, `-`"
    check reasonOf("agent-harbor://trace/abc?x=\x07") ==
      "the query has a space or a control character"
    check reasonOf("agent-harbor://trace/abc?x y") ==
      "the query has a space or a control character"
    check parseTraceReference("agent-harbor://trace/abc?q=caf\xC3\xA9", Origin).ok

  test "a server origin that is not a bare host and port is no origin":
    for origin in ["https://ah.example.test/path", "https://user@ah.example.test",
                   "https://ah.example.test?x", "https://ah.example.test#f",
                   "https://", "ah example", "\x00", "https://ah.example.test\\x"]:
      checkpoint "origin " & origin.escape
      let p = parseTraceReference("https://ah.example.test/trace/abc", origin)
      check not p.ok
      check parseTraceReference("agent-harbor://trace/abc", origin).reference.httpsUrl == ""
    # A user-information or look-alike host never reaches the session's server.
    for text in ["https://ah.example.test@evil.test/trace/abc",
                 "https://evil.test/ah.example.test/trace/abc",
                 "https://ah.example.test./trace/abc"]:
      check not parseTraceReference(text, Origin).ok
    check parseTraceReference("https://[::1]:8443/trace/abc", "https://[::1]:8443").ok

  test "any text splits into parts that join back to it, without raising":
    var texts = @["agent-harbor://", "codetracer://", "https://", "(((", "agent-harbor://trace/",
                  "\x00agent-harbor://trace/a\x00", "https://ah.example.test/trace/",
                  "agent-harbor://trace/" & 'a'.repeat(10_000),
                  "\xFF\xFE https://x \xC3", ")agent-harbor://trace/a.)", "'codetracer://recordings/t'"]
    var noise = ""
    for i in 0 ..< 2_000:
      noise.add ["agent-harbor://trace/", " ", "https://", "codetracer://recordings/",
                 ".", "?", "#", "a", "(", "\t"][i mod 10]
    texts.add noise
    for text in texts:
      let parts = linkSpans(text, Origin)
      check parts.joinedText == text
    check linkSpans(")agent-harbor://trace/a.)", Origin).mapIt(it.kind) == @[lpText]
    let quoted = linkSpans("'codetracer://recordings/t'", Origin)
    check quoted.mapIt(it.kind) == @[lpText, lpTrace, lpText]
    check quoted[1].reference.id == "t"

  test "file spans: negative, inverted, past the end or sharing a start; the first listed wins":
    let a = @[FileTarget(path: "a", exists: true)]
    let b = @[FileTarget(path: "b", exists: true)]
    let text = "0123456789"
    let parts = linkSpans(text, Origin, [
      FileLinkSpan(start: -3, finish: 2, targets: a),
      FileLinkSpan(start: 6, finish: 4, targets: a),
      FileLinkSpan(start: 3, finish: high(int), targets: a),
      FileLinkSpan(start: 1, finish: 3, targets: a),
      FileLinkSpan(start: 1, finish: 5, targets: b)])
    check parts.mapIt(it.kind) == @[lpText, lpFile, lpText]
    check parts[1].text == "12"
    check parts[1].targets == a
    check parts.joinedText == text
    # Link-span events with fields of the wrong kind or out of range read as no span.
    let spans = linkSpansFromJson(%*[
      {"kind": 0, "start": "1", "end": 3, "targets": [{"path": "p"}]},
      {"kind": 0, "start": 1e300, "end": -1e300, "targets": [{"path": "p"}]},
      {"kind": 0, "start": 0, "end": 2, "targets": "p"},
      {"kind": 0, "start": 0, "end": 2, "targets": [7, nil, {"path": 3}]},
      42, nil])
    check linkSpans("abcdef", Origin, spans).joinedText == "abcdef"
    check spans.allIt(it.targets.len > 0)

  test "a directory's title names the directory, wherever it is listed":
    let gone = FileTarget(path: "old", exists: false)
    let dir = FileTarget(path: "src", exists: true, isDir: true)
    check fileLinkState([gone, dir]) == flDirectory
    check fileLinkTitle([gone, dir]) == "src is a directory; nothing to open"
