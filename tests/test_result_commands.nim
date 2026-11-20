## The omnibox's result commands (`nim_agents/result_commands`), native and
## JS: what the field's text asks for (`/s`, `/ah`, `/ah-<id>`,
## `/ah<alias>`, a sigil in an instruction), Agent Harbor's discovery in its
## documented shape, a search over every provider (supersession, the
## providers' order, failures, the eight-row limit), the parts of a title a
## query matched, completions, where opening a row goes, and the launcher's
## abilities each reached by a route.
##
## No test doubles: the module is plain data and reducers, driven as a
## viewmodel drives them. Every expectation is written out by hand from the
## rules in the module comment. The data is invented (an upload client's
## retry work), as everything in this public repository.

import std/[json, strutils, unittest]
import nim_agents/result_commands

const Discovery = """{"commands": [
  {"id": "search", "aliases": ["s"], "title": "Search sessions",
   "description": "Sessions whose prompt, messages or files match the text",
   "kind": "results", "argument": {"placeholder": "words or key:value filters"},
   "surfaces": ["launcher", "webui", "tui", "external"], "source": "builtin"},
  {"id": "search-chats", "aliases": ["sc"], "title": "Search chats",
   "description": "Web chats whose history matches the text", "kind": "results",
   "source": "builtin"},
  {"id": "runbooks", "aliases": ["rb"], "title": "Search runbooks",
   "description": "Runbook sections that mention the text", "kind": "results",
   "surfaces": ["external"], "source": "extension:runbook-index"}
]}"""

proc commands(): seq[InputCommand] =
  let d = parseDiscovery(Discovery, [("runbook-index", "Runbook index")])
  doAssert d.ok, d.error
  d.commands

proc providers(): seq[ProviderInfo] =
  @[ProviderInfo(id: "files", title: "Files", source: "builtin"),
    ProviderInfo(id: "symbols", title: "Symbols", source: "builtin"),
    ProviderInfo(id: "sessions", title: "Agent Harbor sessions", source: "builtin")]

proc row(id, title: string; kind = rkFile; location = ""; url = ""): ResultRow =
  ResultRow(id: id, title: title, kind: kind, location: location, url: url,
            source: "builtin")

suite "what the field asks for":
  test "/search and /s run CodeTracer's search on the rest":
    for input in ["/s retry jitter", "/search retry jitter", "/S retry jitter"]:
      let q = classifyResultQuery(input, commands())
      check q.kind == qkSearch
      check q.text == "retry jitter"

  test "/ah and /ah- list the commands":
    check classifyResultQuery("/ah", commands()).kind == qkAhList
    check classifyResultQuery("/ah-", commands()).kind == qkAhList

  test "/ah-<id> runs a command by its name, /ah<alias> by its alias":
    let byName = classifyResultQuery("/ah-search backoff", commands())
    check byName.kind == qkAhRun
    check byName.command == "search"
    check byName.text == "backoff"
    check not byName.byAlias
    let byAlias = classifyResultQuery("/ahsc backoff", commands())
    check byAlias.kind == qkAhRun
    check byAlias.command == "search-chats"
    check byAlias.byAlias
    check byAlias.typed == "/ahsc"
    # A contributed command is reached the same way: no mapping per command.
    check classifyResultQuery("/ahrb jitter", commands()).command == "runbooks"
    check classifyResultQuery("/ah-runbooks jitter", commands()).command == "runbooks"

  test "a name still being typed lists the commands it starts":
    check classifyResultQuery("/ah-sea", commands()).kind == qkAhList
    check classifyResultQuery("/ahs", commands()).kind == qkAhRun   # `s` is an alias
    check classifyResultQuery("/ahr", commands()).kind == qkAhList
    check commandsMatching(commands(), "/ah-sea").len == 2
    check commandsMatching(commands(), "/ahr").len == 1
    check commandsMatching(commands(), "/ah").len == 3

  test "an unknown name is unknown, with what was typed":
    let q = classifyResultQuery("/ah-sessions backoff", commands())
    check q.kind == qkAhUnknown
    check q.typed == "/ah-sessions"
    check classifyResultQuery("/ahzz backoff", commands()).kind == qkAhUnknown
    # With no commands discovered (Agent Harbor unreachable), still `/ah…`.
    check classifyResultQuery("/ahs backoff", []).kind == qkAhUnknown
    check classifyResultQuery("/ah", []).kind == qkAhList

  test "a sigil being typed at the end of an instruction is a completion":
    let q = classifyResultQuery("/ai Run the retry test with @co", commands())
    check q.kind == qkCompletion
    check q.sigil == '@'
    check q.token == "co"
    check q.tokenStart == "/ai Run the retry test with ".len
    let w = classifyResultQuery("/ai Check the backoff and /", commands())
    check w.kind == qkCompletion
    check w.sigil == '/'
    check w.token == ""
    # A sigil in the middle, or no sigil: an instruction, not a completion.
    check classifyResultQuery("/ai Ask @codex to retry", commands()).kind == qkNone
    check classifyResultQuery("/ai Retry with jitter", commands()).kind == qkNone

  test "anything else is not a result command":
    for input in ["retry", ":grep retry", "/ai", "/sx retry", ""]:
      check classifyResultQuery(input, commands()).kind == qkNone

suite "Agent Harbor's discovery":
  test "the documented shape, with each command's source":
    let c = commands()
    check c.len == 3
    check c[0].id == "search"
    check c[0].aliases == @["s"]
    check c[0].placeholder == "words or key:value filters"
    check c[0].sourceLabel == "Agent Harbor"
    check c[2].sourceLabel == "Runbook index"
    check c[2].fullName == "/ah-runbooks"
    check c[2].aliasNames == @["/ahrb"]
    check c[1].isAvailableOn("anything")          # no surfaces listed
    check not c[2].isAvailableOn("launcher")
    check commandsMatching(c, "/ah", surface = "launcher").len == 2

  test "an answer that is not the shape is an error, not an exception":
    check not parseDiscovery("not json").ok
    check not parseDiscovery("""{"items": []}""").ok
    check parseDiscovery("""{"commands": []}""").ok

  test "a repeated id or alias is not registered twice":
    let d = parseDiscovery("""{"commands": [
      {"id": "search", "aliases": ["s"]}, {"id": "seek", "aliases": ["s"]},
      {"id": "search"}, {"aliases": ["x"]}]}""")
    check d.ok
    check d.commands.len == 1
    check d.commands[0].id == "search"

  test "a disabled extension's command is gone from the next discovery":
    # The server answers the next discovery without it (Input-Commands.md:
    # contributed commands come and go with their extension).
    let i = Discovery.find("  {\"id\": \"runbooks\"")
    let without = parseDiscovery(Discovery[0 ..< i].strip(leading = false).strip(
      leading = false, chars = {','}) & "\n]}").commands
    check without.len == 2
    check classifyResultQuery("/ahrb jitter", commands()).kind == qkAhRun   # the control
    check classifyResultQuery("/ahrb jitter", without).kind == qkAhUnknown
    check commandsMatching(without, "/ah").len == 2

  test "a result row in the documented shape":
    let r = parseResult(parseJson("""{"id": "ses-8f2c", "title": "Retry failed uploads",
      "subtitle": "upload-client · codex · 2h ago", "kind": "session",
      "url": "agent-harbor://task/ses-8f2c", "html": "<b>2 tests</b>", "html_height": 140}"""),
      "builtin", trusted = true)
    check r.kind == rkSession
    check r.url == "agent-harbor://task/ses-8f2c"
    check r.htmlHeight == 140
    check r.trusted

suite "a search over every provider":
  test "groups keep the providers' order, whatever answers first":
    var s: ResultSearch
    let g = s.begin("retry", providers())
    check s.applyRows(g, "sessions", [row("s1", "Retry uploads", rkSession)])
    check s.applyRows(g, "files", [row("f1", "src/retry.py")])
    var order: seq[string]
    for grp in s.groups: order.add grp.id
    check order == @["files", "symbols", "sessions"]
    check s.groups[1].state == psSearching
    check s.answered == 2
    check not s.complete

  test "an answer for an older query changes nothing":
    var s: ResultSearch
    let old = s.begin("retry", providers())
    check s.applyRows(old, "files", [row("f1", "src/retry.py")])
    let newer = s.begin("retry jitter", providers())
    check not s.applyRows(old, "symbols", [row("y1", "retry_once", rkSymbol)])
    check not s.applyFailure(old, "sessions", "timeout")
    # No row of the old query stands under the new one, not even the one
    # its provider answered before.
    check s.totalRows == 0
    for grp in s.groups: check grp.state == psSearching
    check s.applyRows(newer, "files", [row("f2", "src/jitter.py")])
    check s.groups[0].rows[0].id == "f2"

  test "rows arrive in parts until the provider's answer is final":
    var s: ResultSearch
    let g = s.begin("retry", providers())
    check s.applyRows(g, "sessions", [row("s1", "Retry uploads", rkSession)], final = false)
    check s.groups[2].state == psSearching
    check s.applyRows(g, "sessions", [row("s2", "Retry downloads", rkSession)])
    check s.groups[2].rows.len == 2
    check s.groups[2].state == psAnswered
    check not s.applyRows(g, "sessions", [row("s3", "late", rkSession)])
    check s.groups[2].rows.len == 2

  test "a failure keeps no part of the answer and says why":
    var s: ResultSearch
    let g = s.begin("retry", providers())
    check s.applyRows(g, "sessions", [row("s1", "Retry uploads", rkSession)], final = false)
    check s.applyFailure(g, "sessions", "Agent Harbor is not reachable")
    check s.groups[2].rows.len == 0
    check s.groups[2].stateWord == "failed: Agent Harbor is not reachable"
    check s.groups[2].stateRole == "error"

  test "nothing matches only once every provider answered with nothing":
    var s: ResultSearch
    let g = s.begin("warp", providers())
    check s.applyRows(g, "files", [])
    check s.applyRows(g, "symbols", [])
    check not s.nothingMatches          # sessions still searching
    check s.applyRows(g, "sessions", [])
    check s.nothingMatches
    check s.groups[0].stateWord == "no results"
    var f: ResultSearch
    let h = f.begin("warp", providers())
    for p in ["files", "symbols"]: check f.applyRows(h, p, [])
    check f.applyFailure(h, "sessions", "timeout")
    check not f.nothingMatches          # a failure is not "nothing"

  test "a group shows eight rows and says how many more":
    var g = ProviderGroup(id: "files", state: psAnswered)
    for i in 1 .. 11: g.rows.add row("f" & $i, "src/f" & $i & ".py")
    let (rows, more) = g.shownRows
    check rows.len == GroupRowLimit
    check more == 3
    check g.shownRows(alone = true).rows.len == 11
    check g.shownRows(alone = true).more == 0
    check g.stateWord == "11"
    g.state = psSearching
    check g.stateWord == "searching\xE2\x80\xA6"

  test "the parts of a title a query matched":
    check matchSpans("src/upload/retry.py", "retry") == @[(11, 5)]
    check matchSpans("Retry the RETRY", "retry") == @[(0, 5), (10, 5)]
    check matchSpans("upload_retry_once", "retry once") == @[(7, 5), (13, 4)]
    check matchSpans("upload", "") == newSeq[(int, int)]()
    check matches("Retry failed uploads", "uploads retry")
    check not matches("Retry failed uploads", "downloads")

suite "completions in an instruction":
  test "a name that starts with the token first, then a word, then anywhere":
    let rows = completionRows(rkAgent, '@', ["Opencode", "Codex", "Claude"], "co")
    var titles: seq[string]
    for r in rows: titles.add r.title
    check titles == @["@Codex", "@Opencode"]
    check completionRows(rkFile, '@', ["src/retry.py", "README.md"], "re").len == 2
    check completionRows(rkAgent, '@', ["Codex", "Claude"], "").len == 2
    check completionRows(rkAgent, '@', ["Codex"], "zz").len == 0

  test "inserting a completion replaces the token and adds a space":
    let input = "/ai Run the retry test with @co"
    let q = classifyResultQuery(input, [])
    let r = completionRows(rkAgent, '@', ["Codex"], "co")[0]
    check insertCompletion(input, q, r) == "/ai Run the retry test with @Codex "
    check openTargetOf(r) == otInsert

suite "opening a row":
  test "each kind goes where it says":
    check openTargetOf(row("f", "src/retry.py", location = "src/retry.py:1")) == otEditor
    check openTargetOf(row("y", "retry_once", rkSymbol, "src/retry.py:12")) == otEditor
    check openTargetOf(row("s", "Retry uploads", rkSession,
                           url = "agent-harbor://task/ses-1")) == otSessionTab
    check openTargetOf(row("c", "A chat", rkChat, url = "agent-harbor://chat/c-1")) == otCodeTracer
    check openTargetOf(row("d", "Runbook: retries", rkSpec,
                           url = "https://runbooks.example.invalid/retries")) == otOutside
    check openTargetOf(ResultRow(kind: rkSuggestion, insert: "retry ")) == otInsert
    check openTargetOf(ResultRow(kind: rkSpec)) == otNone

  test "what the header says once a row is opened":
    let f = row("f", "retry.py", location = "src/retry.py:12")
    check openedLine(f, otEditor) == "Opened src/retry.py:12"
    let s = row("s", "Retry uploads", rkSession, url = "agent-harbor://task/ses-1")
    check openedLine(s, otSessionTab) == "Opened Retry uploads as a tab"
    let d = row("d", "Runbook", rkSpec, url = "https://runbooks.example.invalid/r")
    check openedLine(d, otOutside) == "Opened outside CodeTracer: https://runbooks.example.invalid/r"

suite "a rich row's box":
  test "an untrusted source's scripts are taken out; a trusted one's are kept":
    let html = "<p>Steps</p><SCRIPT type=x>alert(1)</script><b>2</b><script>x"
    check withoutScripts(html) == "<p>Steps</p><b>2</b>"
    check withoutScripts("<p>no script</p>") == "<p>no script</p>"
    check boxHtml(ResultRow(html: html, trusted: false)) == "<p>Steps</p><b>2</b>"
    check boxHtml(ResultRow(html: html, trusted: true)) == html

suite "the launcher's abilities (OMNI-AREQ5)":
  test "every ability is reached by a route the omnibox handles":
    check unroutedAbilities(LauncherAbilities, commands()).len == 0

  test "an ability with no route is reported by name":
    let abilities = @[LauncherAbility(ability: "run a command by its alias", route: "/ahzz "),
                      LauncherAbility(ability: "search sessions", route: "/s ")]
    check unroutedAbilities(abilities, commands()) == @["run a command by its alias"]
    # With nothing discovered, the commands' routes are unrouted, by name.
    let missing = unroutedAbilities(LauncherAbilities, [])
    check "run an input command by its name" in missing
    check "run an input command by its alias" in missing
    check "list the input commands" notin missing
