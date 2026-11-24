## The omnibox's result commands: commands that turn the text typed after
## them into rows while the operator types, grouped by the provider that
## answered. Plain Nim, no signals, C and JS: a viewmodel holds a
## `ResultSearch` and publishes it.
##
## **What the omnibox offers here** (`classifyResultQuery`):
##
## - `/search <text>` (`/s <text>`): the text goes to every search provider
##   at once, and their rows are shown grouped by provider, each group
##   filling in as its provider answers (`ResultSearch`);
## - `/ah`, `/ah-`: Agent Harbor's input commands, listed from its discovery
##   (`InputCommand`, `parseDiscovery`);
## - `/ah-<id> <text>` and `/ah<alias> <text>`: one Agent Harbor command run
##   on the text. Agent Harbor guarantees that ids and aliases are unique
##   (agent-harbor `specs/Input-Commands.md`, "Discovery"), so one prefix for
##   ids and one for aliases reach every command, a contributed one included,
##   with no per-command mapping;
## - inside an agent instruction (`/ai …`), a last word that is a sigil being
##   typed: `@` completes agents, repositories and files, `/` workflows and
##   chat capabilities (the Agent Harbor launcher's prompt sigils,
##   agent-harbor `specs/Slint-Tier1-Launcher-PRD.md`, "Prompt Sigils").
##
## **Rules held here, for every front-end:**
##
## - every row shown is of the newest query: an answer for an older query
##   (its generation) changes nothing, and a provider that has not answered
##   the newest query shows no rows, even if it answered an older one
##   (`ResultSearch.begin`, `applyRows`);
## - groups keep the providers' order, whatever answers first;
## - a group shows at most `GroupRowLimit` rows, then says how many more;
## - opening a row goes where its kind says (`openTargetOf`): CodeTracer's
##   editor, a session tab, or the system for a URL CodeTracer cannot open;
## - every ability of Agent Harbor's launcher has an omnibox route
##   (`LauncherAbilities`, `unroutedAbilities`).

import std/[json, strutils]
from ./agent_harbor/activity_words import wireInt

type
  ResultKind* = enum
    rkFile = "file"              ## a file of the project
    rkSymbol = "symbol"          ## a function, a variable
    rkLine = "line"              ## a line of the program's text
    rkSession = "session"        ## an Agent Harbor session
    rkChat = "chat"              ## an Agent Harbor web chat
    rkSpec = "spec"              ## a section of a document
    rkCommand = "command"        ## an Agent Harbor input command (`/ah`)
    rkSuggestion = "suggestion"  ## text to insert into the field
    rkAgent = "agent"            ## an `@` completion
    rkRepository = "repository"  ## an `@` completion
    rkWorkflow = "workflow"      ## a `/` completion
    rkCapability = "capability"  ## a `/` completion (a chat capability)

  ResultRow* = object
    ## One row a provider or a command answered (Input-Commands.md,
    ## "Results and activation"). Every row has its text form (`title`,
    ## `subtitle`), which a front-end that cannot render `html` shows.
    id*: string
    kind*: ResultKind
    title*: string
    subtitle*: string        ## what it is: `function`, `noir-space-ship · Claude · running`
    excerpt*: string         ## where the text matched when the title does not show it
                             ## (a session's message); "" for none
    location*: string        ## where: `src/shield.nr:7`; "" for none
    url*: string             ## `agent-harbor://…` or another URL; "" for none
    insert*: string          ## a suggestion's or a completion's text
    html*: string            ## a rich row's HTML box; "" for none
    htmlHeight*: int         ## the box's height in CSS pixels the source asks for (0: default)
    trusted*: bool           ## its source may run scripts in the box
    source*: string          ## `builtin` or `extension:<id>`

  ProviderState* = enum
    psSearching = "searching"
    psAnswered = "answered"
    psFailed = "failed"

  ProviderGroup* = object
    ## One provider's rows for the newest query.
    id*: string              ## `files`, `symbols`, …
    title*: string           ## `Files`
    source*: string          ## `builtin` or `extension:<id>`
    state*: ProviderState
    rows*: seq[ResultRow]
    error*: string

  ProviderInfo* = object
    id*, title*, source*: string

  ResultSearch* = object
    ## The newest query and every provider's answer to it.
    generation*: int
    text*: string
    groups*: seq[ProviderGroup]

  CommandKind* = enum
    ckResults = "results"         ## things to open
    ckSuggestions = "suggestions" ## text to insert

  InputCommand* = object
    ## An Agent Harbor input command, as its discovery lists it
    ## (Input-Commands.md, "Discovery").
    id*: string
    aliases*: seq[string]
    title*: string
    description*: string
    kind*: CommandKind
    placeholder*: string
    surfaces*: seq[string]
    source*: string          ## `builtin` or `extension:<id>`
    sourceTitle*: string     ## the extension's name (`Spec index`); "" for a built-in

  QueryKind* = enum
    qkNone = "none"            ## not a result command
    qkSearch = "search"        ## `/s <text>`: every provider
    qkAhList = "ah-list"       ## `/ah`, `/ah-<partial>`: the commands
    qkAhRun = "ah-run"         ## `/ah-<id> <text>`, `/ah<alias> <text>`
    qkAhUnknown = "ah-unknown" ## a name no command has
    qkCompletion = "completion" ## a sigil being typed in an instruction

  ResultQuery* = object
    kind*: QueryKind
    text*: string              ## what the command runs on
    command*: string           ## qkAhRun: the command's id
    typed*: string             ## qkAhRun / qkAhUnknown / qkAhList: the name as typed (`/ahs`)
    byAlias*: bool             ## qkAhRun: reached by its alias
    sigil*: char               ## qkCompletion: `@` or `/`
    token*: string             ## qkCompletion: what follows the sigil
    tokenStart*: int           ## qkCompletion: where the sigil is in the instruction

  OpenTarget* = enum
    otNone = "none"
    otEditor = "editor"        ## a file, a symbol, a line: CodeTracer's editor
    otSessionTab = "session-tab" ## an `agent-harbor://` session: a session tab
    otCodeTracer = "codetracer"  ## another `agent-harbor://` URL CodeTracer handles
    otOutside = "outside"      ## a URL CodeTracer cannot open: the system's
    otInsert = "insert"        ## text into the field

  LauncherAbility* = object
    ## One ability of Agent Harbor's launcher (Slint-Tier1-Launcher-PRD.md)
    ## and the omnibox route that reaches it (OMNI-AREQ5).
    ability*: string
    route*: string             ## what the operator types (`/ai `, `/ai @`, `/ahs `)

const
  SearchPrefixes* = ["/search ", "/s "]
    ## CodeTracer's own search (OMNI-AREQ3).
  AhPrefix* = "/ah"
    ## Agent Harbor's commands (OMNI-AREQ2): `/ah-<id>` by name, `/ah<alias>`
    ## by alias.
  AgentPrefix* = "/ai "
    ## An instruction for an agent (the composer).
  GroupRowLimit* = 8
    ## The rows a group shows before `+N more`.
  DefaultHtmlHeight* = 96
    ## A rich row's box when its source names no height (6rem).
  MaxHtmlHeight* = 192
    ## The tallest a box is drawn (12rem); taller content scrolls inside.

  LauncherAbilities* = [
    LauncherAbility(ability: "start a coding task with its options", route: "/ai "),
    LauncherAbility(ability: "start a web chat with a chat capability", route: "/ai /"),
    LauncherAbility(ability: "choose an agent with @", route: "/ai @"),
    LauncherAbility(ability: "choose a repository with @", route: "/ai @"),
    LauncherAbility(ability: "cite a file with @", route: "/ai @"),
    LauncherAbility(ability: "use a workflow with /", route: "/ai /"),
    LauncherAbility(ability: "list the input commands", route: "/ah"),
    LauncherAbility(ability: "run an input command by its name", route: "/ah-search "),
    LauncherAbility(ability: "run an input command by its alias", route: "/ahs "),
    LauncherAbility(ability: "search sessions", route: "/s "),
  ]
    ## Every ability of Agent Harbor's launcher the omnibox offers too, and
    ## how (OMNI-AREQ5: the omnibox is a superset of the launcher).

# ---------------------------------------------------------------------------
# Discovery and results: Agent Harbor's shapes
# ---------------------------------------------------------------------------

proc strOf(n: JsonNode; key: string): string =
  if n.kind == JObject and n.hasKey(key) and n[key].kind == JString: n[key].getStr
  else: ""

proc strsOf(n: JsonNode; key: string): seq[string] =
  if n.kind == JObject and n.hasKey(key) and n[key].kind == JArray:
    for x in n[key]:
      if x.kind == JString: result.add x.getStr

proc parseDiscovery*(body: string; extensionTitles: openArray[(string, string)] = []):
    tuple[ok: bool; commands: seq[InputCommand]; error: string] =
  ## The commands of `GET /api/v1/input-commands` (Input-Commands.md,
  ## "Discovery"); `extensionTitles` names each extension's id. A body that
  ## is not the documented shape is an error, never an exception. A command
  ## with no id is skipped; so is one whose id or alias repeats an earlier
  ## one (the server never sends that; a front-end does not guess which
  ## one is meant).
  var root: JsonNode
  try:
    root = parseJson(body)
  except CatchableError as e:
    return (false, @[], "the discovery answer is not JSON: " & e.msg)
  except:
    # JavaScript's own parser raises a foreign exception, not a Nim one.
    return (false, @[], "the discovery answer is not JSON")
  if root.kind != JObject or not root.hasKey("commands") or root["commands"].kind != JArray:
    return (false, @[], "the discovery answer has no \"commands\" list")
  var seen: seq[string]
  for c in root["commands"]:
    let id = c.strOf("id")
    if id.len == 0: continue
    let aliases = c.strsOf("aliases")
    var clash = id in seen
    for a in aliases:
      if a in seen or a == id: clash = true
    if clash: continue
    seen.add id
    for a in aliases: seen.add a
    var cmd = InputCommand(id: id, aliases: aliases, title: c.strOf("title"),
                           description: c.strOf("description"),
                           kind: (if c.strOf("kind") == "suggestions": ckSuggestions else: ckResults),
                           surfaces: c.strsOf("surfaces"),
                           source: (let s = c.strOf("source"); if s.len > 0: s else: "builtin"))
    if c.kind == JObject and c.hasKey("argument"):
      cmd.placeholder = c["argument"].strOf("placeholder")
    for (ext, title) in extensionTitles:
      if cmd.source == "extension:" & ext: cmd.sourceTitle = title
    result.commands.add cmd
  result.ok = true

proc parseResult*(node: JsonNode; source: string; trusted: bool): ResultRow =
  ## One result of a `results` frame (Input-Commands.md, "Results and
  ## activation"), from the command `source`, whose boxes may run scripts
  ## when `trusted`.
  let kind = node.strOf("kind")
  result = ResultRow(id: node.strOf("id"), title: node.strOf("title"),
                     subtitle: node.strOf("subtitle"), url: node.strOf("url"),
                     insert: node.strOf("insert"), html: node.strOf("html"),
                     source: source, trusted: trusted)
  result.kind = case kind
                of "session": rkSession
                of "chat": rkChat
                of "file": rkFile
                of "spec": rkSpec
                else: (if result.insert.len > 0: rkSuggestion else: rkSession)
  if node.kind == JObject and node.hasKey("html_height") and node["html_height"].kind == JInt:
    result.htmlHeight = node["html_height"].wireInt

proc isAvailableOn*(cmd: InputCommand; surface: string): bool =
  ## A command lists the surfaces that may offer it; none listed: every one.
  cmd.surfaces.len == 0 or surface in cmd.surfaces

proc sourceLabel*(cmd: InputCommand): string =
  ## Where a command comes from, as a row's tag says it.
  if cmd.source == "builtin" or cmd.source.len == 0: "Agent Harbor"
  elif cmd.sourceTitle.len > 0: cmd.sourceTitle
  else: cmd.source.substr("extension:".len)

proc fullName*(cmd: InputCommand): string = AhPrefix & "-" & cmd.id
proc aliasNames*(cmd: InputCommand): seq[string] =
  for a in cmd.aliases: result.add AhPrefix & a

# ---------------------------------------------------------------------------
# Classifying what the operator typed
# ---------------------------------------------------------------------------

proc afterPrefix(input, prefix: string): (bool, string) =
  if input.toLowerAscii.startsWith(prefix): (true, input[prefix.len .. ^1])
  else: (false, "")

proc sigilAt*(text: string): tuple[found: bool; sigil: char; token: string; start: int] =
  ## The sigil token being typed at the end of `text`: its last word, when
  ## it starts with `@` or `/` and holds no further sigil.
  var start = text.len
  while start > 0 and text[start - 1] notin {' ', '\t', '\n', '\r'}: dec start
  let word = text[start .. ^1]
  if word.len == 0 or word[0] notin {'@', '/'}: return
  let rest = word[1 .. ^1]
  for ch in rest:
    if ch in {'@'}: return
  (true, word[0], rest, start)

proc classifyResultQuery*(input: string; commands: openArray[InputCommand]): ResultQuery =
  ## What the field's text asks for. `commands` are Agent Harbor's
  ## (discovered); an empty list still classifies `/ah…` (the list or an
  ## unknown name), so an unreachable Agent Harbor is said, not ignored.
  for p in SearchPrefixes:
    let (hit, rest) = afterPrefix(input, p)
    if hit: return ResultQuery(kind: qkSearch, text: rest.strip)
  let (agent, instruction) = afterPrefix(input, AgentPrefix)
  if agent:
    let s = sigilAt(instruction)
    if s.found:
      return ResultQuery(kind: qkCompletion, sigil: s.sigil, token: s.token,
                         tokenStart: AgentPrefix.len + s.start)
    return ResultQuery(kind: qkNone)
  if not input.toLowerAscii.startsWith(AhPrefix): return ResultQuery(kind: qkNone)
  # `/ah…`: the name runs to the first space.
  let space = input.find(' ')
  let name = (if space < 0: input else: input[0 ..< space]).toLowerAscii
  let text = if space < 0: "" else: input[space + 1 .. ^1].strip
  let typedArgument = space >= 0
  if name == AhPrefix or name == AhPrefix & "-":
    return ResultQuery(kind: qkAhList, typed: name, text: text)
  if name.startsWith(AhPrefix & "-"):
    let id = name[AhPrefix.len + 1 .. ^1]
    for c in commands:
      if c.id == id: return ResultQuery(kind: qkAhRun, command: c.id, typed: name, text: text)
    if not typedArgument:
      # Still typing the name: the commands it starts.
      for c in commands:
        if c.id.startsWith(id): return ResultQuery(kind: qkAhList, typed: name)
    return ResultQuery(kind: qkAhUnknown, typed: name, text: text)
  let alias = name[AhPrefix.len .. ^1]
  for c in commands:
    if alias in c.aliases:
      return ResultQuery(kind: qkAhRun, command: c.id, typed: name, text: text, byAlias: true)
  if not typedArgument:
    for c in commands:
      for a in c.aliases:
        if a.startsWith(alias): return ResultQuery(kind: qkAhList, typed: name)
  ResultQuery(kind: qkAhUnknown, typed: name, text: text)

proc commandsMatching*(commands: openArray[InputCommand]; typed: string;
                       surface = ""): seq[InputCommand] =
  ## The commands `/ah`, `/ah-<start>` or `/ah<alias start>` lists, in
  ## discovery order (built-in first, as the server registers them).
  let t = typed.toLowerAscii
  for c in commands:
    if surface.len > 0 and not c.isAvailableOn(surface): continue
    if t == AhPrefix or t == AhPrefix & "-":
      result.add c
      continue
    if t.startsWith(AhPrefix & "-"):
      if c.id.startsWith(t[AhPrefix.len + 1 .. ^1]): result.add c
      continue
    let a = t[AhPrefix.len .. ^1]
    for x in c.aliases:
      if x.startsWith(a):
        result.add c
        break

proc commandRow*(cmd: InputCommand): ResultRow =
  ## A command as a row of the `/ah` list: choosing it puts its name into
  ## the field.
  ResultRow(id: cmd.id, kind: rkCommand, title: cmd.fullName,
            subtitle: cmd.description, insert: cmd.fullName & " ",
            source: cmd.source)

proc findCommand*(commands: openArray[InputCommand]; id: string): InputCommand =
  for c in commands:
    if c.id == id: return c

# ---------------------------------------------------------------------------
# A search over every provider
# ---------------------------------------------------------------------------

proc begin*(s: var ResultSearch; text: string; providers: openArray[ProviderInfo]): int =
  ## A new query: every provider searching it, no row of the old one kept.
  ## Returns its generation, which every answer names.
  inc s.generation
  s.text = text
  s.groups = @[]
  for p in providers:
    s.groups.add ProviderGroup(id: p.id, title: p.title, source: p.source, state: psSearching)
  s.generation

proc groupIndex(s: ResultSearch; id: string): int =
  for i, g in s.groups:
    if g.id == id: return i
  -1

proc applyRows*(s: var ResultSearch; generation: int; provider: string;
                rows: openArray[ResultRow]; final = true): bool =
  ## A provider's rows for the query of `generation`, appended to what it
  ## answered so far; `final`: it answered the query whole. False (and
  ## nothing changes) for an older query, an unknown provider, or a provider
  ## that already finished.
  if generation != s.generation: return false
  let i = s.groupIndex(provider)
  if i < 0 or s.groups[i].state != psSearching: return false
  s.groups[i].rows.add rows
  if final: s.groups[i].state = psAnswered
  true

proc applyFailure*(s: var ResultSearch; generation: int; provider, error: string): bool =
  ## A provider's failure for the query of `generation`; the rows it sent
  ## before failing are dropped (a part of an answer would read as all of it).
  if generation != s.generation: return false
  let i = s.groupIndex(provider)
  if i < 0 or s.groups[i].state != psSearching: return false
  s.groups[i].state = psFailed
  s.groups[i].error = error
  s.groups[i].rows = @[]
  true

proc answered*(s: ResultSearch): int =
  for g in s.groups:
    if g.state != psSearching: inc result

proc totalRows*(s: ResultSearch): int =
  for g in s.groups: result += g.rows.len

proc complete*(s: ResultSearch): bool = s.answered == s.groups.len

proc nothingMatches*(s: ResultSearch): bool =
  ## Every provider answered and none has a row: one line says so, in place
  ## of the groups.
  if s.groups.len == 0 or not s.complete: return false
  for g in s.groups:
    if g.state == psFailed or g.rows.len > 0: return false
  true

proc shownRows*(g: ProviderGroup; alone = false): tuple[rows: seq[ResultRow]; more: int] =
  ## The rows a group shows: all when shown alone, else the first
  ## `GroupRowLimit`, with how many more it holds.
  if alone or g.rows.len <= GroupRowLimit: (g.rows, 0)
  else: (g.rows[0 ..< GroupRowLimit], g.rows.len - GroupRowLimit)

proc stateWord*(g: ProviderGroup): string =
  ## The group's state, in the slot at the right of its title.
  case g.state
  of psSearching: "searching\xE2\x80\xA6"
  of psFailed: "failed: " & g.error
  of psAnswered:
    if g.rows.len == 0: "no results" else: $g.rows.len

proc stateRole*(g: ProviderGroup): string =
  case g.state
  of psSearching: "quiet"
  of psFailed: "error"
  of psAnswered: (if g.rows.len == 0: "quiet" else: "caption")

# ---------------------------------------------------------------------------
# Matching and the parts of a title the query matched
# ---------------------------------------------------------------------------

proc matchSpans*(title, query: string): seq[(int, int)] =
  ## Where `query` (case ignored) occurs in `title`, as (start, length) byte
  ## spans, left to right, never overlapping; each word of the query on its
  ## own when the whole does not occur.
  let t = title.toLowerAscii
  let q = query.strip.toLowerAscii
  if q.len == 0: return
  var parts = @[q]
  if t.find(q) < 0: parts = q.splitWhitespace
  var taken = newSeq[bool](t.len)
  for part in parts:
    if part.len == 0: continue
    var at = t.find(part)
    while at >= 0:
      var free = true
      for k in at ..< at + part.len:
        if taken[k]: free = false
      if free:
        for k in at ..< at + part.len: taken[k] = true
      at = t.find(part, at + part.len)
  var i = 0
  while i < t.len:
    if taken[i]:
      var j = i
      while j < t.len and taken[j]: inc j
      result.add (i, j - i)
      i = j
    else: inc i

proc matches*(text, query: string): bool =
  ## Every word of `query` occurs in `text`, case ignored.
  let t = text.toLowerAscii
  for w in query.toLowerAscii.splitWhitespace:
    if t.find(w) < 0: return false
  true

# ---------------------------------------------------------------------------
# Completions in an instruction
# ---------------------------------------------------------------------------

proc completionRank(name, token: string): int =
  ## 0: `name` starts with `token`; 1: one of its words does; 2: it holds
  ## it; -1: no match. Case ignored; an empty token matches everything.
  let n = name.toLowerAscii
  let t = token.toLowerAscii
  if t.len == 0 or n.startsWith(t): return 0
  for w in n.split({'-', '_', '/', '.', ' '}):
    if w.startsWith(t): return 1
  if n.find(t) >= 0: 2 else: -1

proc completionRows*(kind: ResultKind; sigil: char; names: openArray[string];
                     token: string): seq[ResultRow] =
  ## The names `token` completes, best first (stable within a rank), each
  ## inserting `<sigil><name>`.
  for rank in 0 .. 2:
    for n in names:
      if completionRank(n, token) == rank:
        result.add ResultRow(id: $kind & ":" & n, kind: kind, title: $sigil & n,
                             insert: $sigil & n, source: "builtin")

proc insertCompletion*(input: string; q: ResultQuery; row: ResultRow): string =
  ## `input` with the sigil token being typed replaced by `row`'s text and a
  ## space after it, so the next word can follow (the launcher's rule).
  if q.kind != qkCompletion or row.insert.len == 0: return input
  input[0 ..< min(q.tokenStart, input.len)] & row.insert & " "

# ---------------------------------------------------------------------------
# Opening a row
# ---------------------------------------------------------------------------

proc openTargetOf*(row: ResultRow): OpenTarget =
  ## Where opening `row` goes (Commands-And-Omnibox, "Result commands": a
  ## file, a symbol, a replay position, an `agent-harbor://` URL through
  ## CodeTracer's URL handling; a URL it cannot open, to the system).
  if row.kind in {rkSuggestion, rkCommand, rkAgent, rkRepository, rkWorkflow,
                  rkCapability} and row.insert.len > 0:
    return otInsert
  if row.url.len > 0:
    let u = row.url.toLowerAscii
    if u.startsWith("agent-harbor://"):
      if row.kind == rkSession or u.startsWith("agent-harbor://task/") or
          u.startsWith("agent-harbor://sessions/"): return otSessionTab
      return otCodeTracer
    return otOutside
  if row.kind in {rkFile, rkSymbol, rkLine} and (row.location.len > 0 or row.title.len > 0):
    return otEditor
  otNone

proc openedLine*(row: ResultRow; target: OpenTarget): string =
  ## What the header says once `row` was opened.
  case target
  of otEditor: "Opened " & (if row.location.len > 0: row.location else: row.title)
  of otSessionTab: "Opened " & row.title & " as a tab"
  of otCodeTracer: "Opened " & row.title
  of otOutside: "Opened outside CodeTracer: " & row.url
  of otInsert: ""
  of otNone: "Nothing to open for " & row.title

proc withoutScripts*(html: string): string =
  ## `html` with every `<script>` element taken out (its tags and what they
  ## hold), case ignored; an unclosed one is cut to the end.
  let lower = html.toLowerAscii
  var at = 0
  while at < html.len:
    let open = lower.find("<script", at)
    if open < 0:
      result.add html[at .. ^1]
      break
    result.add html[at ..< open]
    let close = lower.find("</script", open)
    if close < 0: break
    let gt = lower.find('>', close)
    at = if gt < 0: html.len else: gt + 1

proc boxHtml*(row: ResultRow): string =
  ## What a rich row's box is given: the row's HTML, without its scripts
  ## when its source is not trusted to run them. The box's sandbox refuses
  ## them anyway (Input-Commands.md, "Results and activation"); taking them
  ## out first also keeps a refused script from being reported as an error
  ## in the front-end's console.
  if row.trusted: row.html else: withoutScripts(row.html)

const OpenedOutside* = "Opened outside CodeTracer"
  ## A row passed on to the system says it under its title.

# ---------------------------------------------------------------------------
# The launcher's abilities (OMNI-AREQ5)
# ---------------------------------------------------------------------------

proc routeIsHandled*(route: string; commands: openArray[InputCommand]): bool =
  ## The omnibox handles what `route` starts: a result command, an
  ## Agent Harbor command it knows, a sigil completion, or an instruction.
  let q = classifyResultQuery(route, commands)
  case q.kind
  of qkSearch, qkAhList, qkAhRun, qkCompletion: true
  of qkAhUnknown: false
  of qkNone: route.toLowerAscii.startsWith(AgentPrefix)

proc unroutedAbilities*(abilities: openArray[LauncherAbility];
                        commands: openArray[InputCommand]): seq[string] =
  ## The abilities whose route the omnibox does not handle, by name.
  for a in abilities:
    if not routeIsHandled(a.route, commands): result.add a.ability
