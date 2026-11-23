## Links in an agent's messages: traces, recordings and files, as
## signal-free records (INV-D-24, INV-D-25, INV-C-11, INV-P4-01).
##
## **Two kinds of trace link, labelled differently.**
##
## - A trace Agent Harbor holds: `agent-harbor://trace/<id>`, or its https
##   form `https://<the session's server>/trace/<id>`. Opened by a replay
##   started near the trace (`Load trace`), and downloadable.
## - A recording on this machine: `codetracer://recordings/<test>`, opened
##   through CodeTracer's own opening path (`Open recording`); no replay is
##   started and nothing is sent.
##
## Both read the same id grammar: 1 to 128 characters of `A-Z a-z 0-9 . _ -`,
## not `.` or `..`, with nothing after it but an optional query (no
## fragment, space or control character), which is kept. A text that starts like a trace link and breaks the grammar is not a
## link, and `parseTraceReference` says why. An https URL on any other origin
## is never a trace: it stays a plain link. The scheme and the host compare
## without case (RFC 3986 §3.1, §3.2.2:
## https://www.rfc-editor.org/rfc/rfc3986#section-3.1); the id and the path
## compare exactly.
##
## **File links.** A file path in a message is a link only where the
## session's link-span events say so (`linkSpansFromJson`: a span's `start`
## and `end` in the text and its `targets`, each with `exists`, `is_dir`,
## `modified_in_session`, `line` and `col`); the text is never scanned for
## paths. One existing target opens it, several open a menu, none is a
## missing file, and a directory opens nothing.
##
## **`linkSpans`** splits a message into parts whose texts, joined, are the
## message exactly: plain text, trace links of either kind, plain https
## links and file links, deterministically and with no model.
##
## **Replay and download states** (`ReplayState`, `DownloadState`) are what
## a trace's button shows while a replay connects, plays, or is unavailable,
## and while a download runs, is saved or fails.
##
## Signal-free and app-agnostic; identical on the C and JS targets.

import std/[algorithm, json, strutils]
import ./activity_words

type
  TraceKind* = enum
    trkAgentHarbor = "agent-harbor"        ## a trace Agent Harbor holds
    trkLocalRecording = "local-recording"  ## a recording on this machine

  TraceReference* = object
    kind*: TraceKind
    id*: string           ## the trace id, or the recording's test name
    url*: string          ## `agent-harbor://trace/<id>` or `codetracer://recordings/<test>`, with the query
    httpsUrl*: string     ## the https form on the session's server, when known (Agent Harbor only)
    query*: string        ## what follows `?`, without it; "" when none

  TraceParse* = object
    ok*: bool
    reference*: TraceReference
    kind*: TraceKind      ## which kind the text looked like, when not ok
    reason*: string       ## why it is not a link; "" when ok or not link-like at all

  FileTarget* = object
    path*: string
    exists*: bool         ## true when the event does not say
    isDir*: bool
    modifiedInSession*: bool
    line*, column*: int   ## 0 when not given

  FileLinkSpan* = object
    ## A link-span event's span over one message: bytes `start ..< finish`.
    start*, finish*: int
    targets*: seq[FileTarget]

  FileLinkState* = enum
    flUnique = "unique"         ## one existing file: opens it
    flAmbiguous = "ambiguous"   ## several: a menu of targets
    flMissing = "missing"       ## no target exists
    flDirectory = "directory"   ## a directory: opens nothing

  LinkPartKind* = enum
    lpText = "text"
    lpTrace = "trace"     ## a trace link of either kind
    lpUrl = "url"         ## a plain https link
    lpFile = "file"

  LinkPart* = object
    kind*: LinkPartKind
    text*: string                 ## exactly the message's text it covers
    reference*: TraceReference    ## lpTrace
    targets*: seq[FileTarget]     ## lpFile
    reason*: string
      ## lpText that looked like a trace or recording link: why it is not one.

  ReplayPhase* = enum
    rpIdle = "idle"
    rpConnecting = "connecting"
    rpReplaying = "replaying"
    rpUnavailable = "unavailable"

  ReplayState* = object
    phase*: ReplayPhase
    reason*: string       ## rpUnavailable: why
    canRetry*: bool       ## rpUnavailable: false for a trace that is gone

  DownloadPhase* = enum
    dpIdle = "idle"
    dpDownloading = "downloading"
    dpSaved = "saved"
    dpFailed = "failed"

  DownloadState* = object
    phase*: DownloadPhase
    name*: string         ## dpSaved: the file's name
    reason*: string       ## dpFailed: why

const
  MaxTraceIdLen* = 128
  AgentHarborTracePrefix* = "agent-harbor://trace/"
  LocalRecordingPrefix* = "codetracer://recordings/"
  HttpsPrefix = "https://"
  LoadTraceText* = "Load trace"
  OpenRecordingText* = "Open recording"
  TraceGoneText* = "This trace is no longer stored"
  IdChars = {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'}
  OriginChars = {'a'..'z', '0'..'9', '.', '-', ':', '[', ']'}
  QueryControl = {'\0'..' ', '\x7F'}
    ## Not in a kept query: whitespace and control characters.
  LeadingDelimiters = {'(', '<', '[', '{', '"', '\'', '`'}
  TrailingPunctuation = {'.', ',', ';', ':', '!', '?', ')', ']', '}', '>', '"', '\'', '`'}

# ---------------------------------------------------------------------------
# One reference
# ---------------------------------------------------------------------------

proc idWord(kind: TraceKind): string =
  if kind == trkAgentHarbor: "the trace id" else: "the test name"

proc idProblem(id: string; kind: TraceKind): string =
  ## Why `id` breaks the id grammar, or "".
  let what = idWord(kind)
  if id.len == 0: return what & " is empty"
  if id.len > MaxTraceIdLen:
    return what & " is longer than " & $MaxTraceIdLen & " characters"
  if id == "." or id == "..": return what & " may not be `" & id & "`"
  for c in id:
    if c notin IdChars:
      if c == '/' or c == '#':
        return "only a query may follow " & what
      # A printable character is named; any other byte (a control
      # character, part of a UTF-8 sequence) is not copied into the words.
      let shown = if c in {'!'..'~'}: "`" & $c & "`" else: "a character"
      return what & " has " & shown & ", outside A-Z, a-z, 0-9, `.`, `_`, `-`"
  ""

proc originOf(serverOrigin: string): string =
  ## The session's server origin as `https://host[:port]`, lower case, no
  ## trailing slash; "" when it is not an https origin. Only a host and a
  ## port are accepted after the scheme (letters, digits, `.`, `-`, `:` and
  ## an IPv6 literal's brackets): an origin with a path, user information, a
  ## query or a fragment is none, so no URL can match it by a trick of
  ## spelling.
  var authority = serverOrigin.strip.toLowerAscii
  if authority.startsWith(HttpsPrefix): authority = authority[HttpsPrefix.len .. ^1]
  while authority.endsWith("/"): authority.setLen(authority.len - 1)
  if authority.len == 0 or authority[0] == ':': return ""
  for c in authority:
    if c notin OriginChars: return ""   # another scheme's `/`, `@`, `?`, `#`, …
  HttpsPrefix & authority

proc splitQuery(rest: string): (string, string, bool) =
  ## `<id>?<query>` into id and query; the flag says a `?` was present.
  let q = rest.find('?')
  if q < 0: (rest, "", false) else: (rest[0 ..< q], rest[q + 1 .. ^1], true)

proc build(kind: TraceKind; id, query: string; hasQuery: bool;
           origin: string): TraceReference =
  let suffix = if hasQuery: "?" & query else: ""
  result = TraceReference(kind: kind, id: id, query: query)
  case kind
  of trkAgentHarbor:
    result.url = AgentHarborTracePrefix & id & suffix
    if origin.len > 0: result.httpsUrl = origin & "/trace/" & id & suffix
  of trkLocalRecording:
    result.url = LocalRecordingPrefix & id & suffix

proc parseTraceReference*(text, serverOrigin: string): TraceParse =
  ## Reads `text` as a whole: `agent-harbor://trace/<id>`,
  ## `https://<serverOrigin>/trace/<id>` or `codetracer://recordings/<test>`,
  ## each with an optional query. `serverOrigin` is the session's server
  ## (`https://host[:port]`, or the bare host); "" when unknown, so no https
  ## URL is a trace. When not ok, `reason` says why a text that looked like
  ## one of them is not, and is "" for any other text.
  let lower = text.toLowerAscii
  let origin = originOf(serverOrigin)
  var kind: TraceKind
  var rest: string
  if lower.startsWith(AgentHarborTracePrefix):
    kind = trkAgentHarbor
    rest = text[AgentHarborTracePrefix.len .. ^1]
  elif lower.startsWith(LocalRecordingPrefix):
    kind = trkLocalRecording
    rest = text[LocalRecordingPrefix.len .. ^1]
  elif origin.len > 0 and lower.startsWith(origin & "/") and
      text.continuesWith("/trace/", origin.len):
    # The origin compares without case; the path exactly.
    kind = trkAgentHarbor
    rest = text[origin.len + "/trace/".len .. ^1]
  elif lower.startsWith("agent-harbor://"):
    return TraceParse(kind: trkAgentHarbor,
                      reason: "an Agent Harbor link names no trace (`agent-harbor://trace/<id>`)")
  elif lower.startsWith("codetracer://"):
    return TraceParse(kind: trkLocalRecording,
                      reason: "a CodeTracer link names no recording (`codetracer://recordings/<test>`)")
  else:
    return TraceParse()
  let (id, query, hasQuery) = splitQuery(rest)
  let problem = idProblem(id, kind)
  if problem.len > 0:
    return TraceParse(kind: kind, reason: problem)
  if hasQuery and query.contains('#'):
    return TraceParse(kind: kind, reason: "only a query may follow " & idWord(kind))
  if hasQuery and query.contains(QueryControl):
    return TraceParse(kind: kind, reason: "the query has a space or a control character")
  TraceParse(ok: true, kind: kind, reference: build(kind, id, query, hasQuery, origin))

proc actionLabel*(kind: TraceKind): string =
  ## The button beside a link: `Load trace` for a trace Agent Harbor holds,
  ## `Open recording` for a recording on this machine.
  case kind
  of trkAgentHarbor: LoadTraceText
  of trkLocalRecording: OpenRecordingText

proc accessibleName*(reference: TraceReference): string =
  ## The link's accessible name, naming its target: `Trace <id>`,
  ## `Recording <test>`.
  case reference.kind
  of trkAgentHarbor: "Trace " & reference.id
  of trkLocalRecording: "Recording " & reference.id

proc notALinkText*(kind: TraceKind; reason: string): string =
  ## A malformed link's tooltip: `Not a trace link: <why>`,
  ## `Not a recording link: <why>`.
  (if kind == trkAgentHarbor: "Not a trace link: " else: "Not a recording link: ") & reason

# ---------------------------------------------------------------------------
# File links
# ---------------------------------------------------------------------------

proc fieldInt(node: JsonNode; key: string): int =
  ## An integer field held to the 32-bit range every target's `int` holds; 0
  ## when absent or not a number. `fieldNum(key).int` raises a RangeDefect
  ## under JS on a hostile value (`1e300`), and its float-to-int conversion is
  ## undefined in C past the int64 range, so a wire number is clamped here
  ## before it is converted.
  let value = node.fieldChild(key)
  if value.isNil: return 0
  case value.kind
  of JInt: int(clamp(value.getBiggestInt, int64(low(int32)), int64(high(int32))))
  of JFloat:
    let f = value.getFloat
    if f != f: 0   # NaN
    else: int(clamp(f, float(low(int32)), float(high(int32))))
  else: 0

proc fileTargetFromJson(node: JsonNode): FileTarget =
  if node.isNil or node.kind != JObject: return
  let exists = node.fieldChild("exists")
  FileTarget(path: node.fieldStr("path"),
             exists: exists.isNil or exists.kind != JBool or exists.getBool,
             isDir: node.fieldFlag("is_dir") or node.fieldFlag("isDir"),
             modifiedInSession: node.fieldFlag("modified_in_session") or
               node.fieldFlag("modifiedInSession"),
             line: node.fieldInt("line"),
             column: (if node.fieldInt("col") != 0: node.fieldInt("col")
                      else: node.fieldInt("column")))

proc linkSpansFromJson*(node: JsonNode): seq[FileLinkSpan] =
  ## A message's activity link spans (`kind` 0; a terminal span, `kind` 1,
  ## is not a message's), from an array or an object whose `spans` is one.
  ## A span with no target with a path is dropped.
  var list = node
  if not node.isNil and node.kind == JObject: list = node.fieldChild("spans")
  if list.isNil or list.kind != JArray: return
  for s in list:
    if s.kind != JObject or s.fieldInt("kind") != 0: continue
    var span = FileLinkSpan(start: s.fieldInt("start"), finish: s.fieldInt("end"))
    let targets = s.fieldChild("targets")
    if not targets.isNil and targets.kind == JArray:
      for t in targets:
        let target = fileTargetFromJson(t)
        if target.path.len > 0: span.targets.add target
    if span.targets.len > 0: result.add span

proc fileLinkState*(targets: openArray[FileTarget]): FileLinkState =
  ## What pressing a file link does: open its one existing file, offer a
  ## menu of several, or nothing (missing; a directory).
  var existing: seq[FileTarget]
  for t in targets:
    if t.exists: existing.add t
  if existing.len == 0: flMissing
  elif existing.len > 1: flAmbiguous
  elif existing[0].isDir: flDirectory
  else: flUnique

proc fileLinkTitle*(targets: openArray[FileTarget]): string =
  ## The file link's tooltip.
  case fileLinkState(targets)
  of flMissing: "File not found in this session"
  of flDirectory:
    # The one existing target is the directory; a missing one may precede it.
    for t in targets:
      if t.exists: return t.path & " is a directory; nothing to open"
    ""
  of flAmbiguous: "Several files match; choose one"
  of flUnique:
    for t in targets:
      if t.exists:
        return "Open " & t.path & (if t.line > 0: ":" & $t.line else: "")
    ""

# ---------------------------------------------------------------------------
# A message as parts
# ---------------------------------------------------------------------------

proc tokenEnd(text: string; start: int): int =
  ## The end of the URL-like token at `start`: the first whitespace, with
  ## trailing punctuation left to the prose -- unless that punctuation is
  ## all that follows a `/` (`trace/..`), when it is the token's own.
  result = start
  while result < text.len and text[result] notin Whitespace: inc result
  let full = result
  while result > start and text[result - 1] in TrailingPunctuation: dec result
  if result < full and result > start and text[result - 1] == '/': result = full

proc linkStartAt(lower: string; i: int): bool =
  ## Whether a link-like token may start at `i`: a known scheme, at the
  ## text's start or after whitespace or an opening delimiter.
  if i > 0 and lower[i - 1] notin Whitespace and lower[i - 1] notin LeadingDelimiters:
    return false
  for scheme in ["agent-harbor://", "codetracer://", HttpsPrefix]:
    if lower.continuesWith(scheme, i): return true
  false

proc addText(parts: var seq[LinkPart]; text: string) =
  if text.len == 0: return
  if parts.len > 0 and parts[^1].kind == lpText and parts[^1].reason.len == 0:
    parts[^1].text.add text
  else:
    parts.add LinkPart(kind: lpText, text: text)

proc urlParts(parts: var seq[LinkPart]; text, serverOrigin: string) =
  ## Trace, recording and https links in a stretch of text with no file link.
  let lower = text.toLowerAscii
  var plainStart = 0
  var i = 0
  while i < text.len:
    if not linkStartAt(lower, i):
      inc i
      continue
    let finish = tokenEnd(text, i)
    if finish <= i:
      inc i
      continue
    let token = text[i ..< finish]
    let parse = parseTraceReference(token, serverOrigin)
    parts.addText(text[plainStart ..< i])
    if parse.ok:
      parts.add LinkPart(kind: lpTrace, text: token, reference: parse.reference)
    elif parse.reason.len > 0:
      parts.add LinkPart(kind: lpText, text: token,
                         reason: notALinkText(parse.kind, parse.reason))
    elif lower.continuesWith(HttpsPrefix, i) and token.len > HttpsPrefix.len:
      parts.add LinkPart(kind: lpUrl, text: token)
    else:
      parts.addText(token)
    plainStart = finish
    i = finish
  parts.addText(text[plainStart .. ^1])

proc linkSpans*(text, serverOrigin: string;
                fileSpans: openArray[FileLinkSpan] = []): seq[LinkPart] =
  ## A message as parts whose texts, joined, are `text`. File links come
  ## from `fileSpans` (byte ranges inside the text; one outside it, empty, or
  ## overlapping an earlier span is dropped, the earliest start winning);
  ## the rest is read for trace, recording and https links.
  var spans: seq[FileLinkSpan]
  for s in fileSpans:
    if s.targets.len > 0 and s.start >= 0 and s.finish <= text.len and s.start < s.finish:
      spans.add s
  spans.sort(proc (a, b: FileLinkSpan): int = cmp(a.start, b.start))
  var cursor = 0
  for s in spans:
    if s.start < cursor: continue
    result.urlParts(text[cursor ..< s.start], serverOrigin)
    result.add LinkPart(kind: lpFile, text: text[s.start ..< s.finish], targets: s.targets)
    cursor = s.finish
  result.urlParts(text[cursor .. ^1], serverOrigin)

proc joinedText*(parts: openArray[LinkPart]): string =
  ## The parts' texts joined: the message as it was.
  for p in parts: result.add p.text

# ---------------------------------------------------------------------------
# Replay and download
# ---------------------------------------------------------------------------

proc unavailable*(reason: string; canRetry = true): ReplayState =
  ReplayState(phase: rpUnavailable, reason: reason, canRetry: canRetry)

proc unavailableText*(state: ReplayState): string =
  ## `Replay unavailable: <reason>`, or "" when it is not unavailable.
  if state.phase == rpUnavailable: "Replay unavailable: " & state.reason else: ""

proc downloadText*(state: DownloadState): string =
  ## `Downloading…`, `Saved <name>`, `Download failed: <reason>`, or "".
  case state.phase
  of dpIdle: ""
  of dpDownloading: "Downloading\xE2\x80\xA6"
  of dpSaved: "Saved " & state.name
  of dpFailed: "Download failed: " & state.reason
