## A change's diff -- the files a session or branch changed, with their
## hunks -- as signal-free records, for a Changes panel's Code tab and for
## the spec cards that are read from the diff.
##
## `parseUnifiedDiff` reads `git diff` output
## (https://git-scm.com/docs/diff-format, "Generating patch text with -p";
## https://git-scm.com/docs/git-diff#_combined_diff_format is not handled:
## a front-end diffs one base against one head). It understands the extended
## header lines git writes (`new file mode`, `deleted file mode`,
## `rename from` / `rename to`, `similarity index`, `Binary files … differ`,
## `GIT binary patch`) and reads each hunk by the line counts in its
## `@@ -a,b +c,d @@` header, so a removed line that itself starts with `--`
## (shown as `--- …`) is never mistaken for a file header.
##
## A diff can be taken relative to the merge base with the landing branch, so
## it holds the committed work of the branch as well as the uncommitted end
## state (INV-D-12). `mergeBaseRelative` joins a committed and an
## uncommitted diff into that one file list and marks each file and hunk with
## where it comes from.
##
## Signal-free and app-agnostic; identical on the C and JS targets.

import std/strutils

type
  ChangeStatus* = enum
    ## A file's change, as the VCS panel letters it.
    csAdded = "A"
    csModified = "M"
    csDeleted = "D"
    csRenamed = "R"

  ChangeOrigin* = enum
    ## Where a file's or a hunk's change is: in the branch's commits, in the
    ## working tree, or (a file only) in both.
    coCommitted = "committed"
    coUncommitted = "uncommitted"
    coBoth = "both"

  DiffLineKind* = enum
    dlContext   ## ` ` an unchanged line
    dlAdded     ## `+`
    dlRemoved   ## `-`
    dlNoNewline ## `\ No newline at end of file`

  DiffLine* = object
    kind*: DiffLineKind
    text*: string      ## the line without its one-character prefix
    oldLine*: int      ## its number in the old file; 0 for an added line
    newLine*: int      ## its number in the new file; 0 for a removed line

  DiffHunk* = object
    oldStart*, oldCount*, newStart*, newCount*: int
    section*: string   ## the text git prints after the second `@@`
    origin*: ChangeOrigin
    lines*: seq[DiffLine]

  ChangedFile* = object
    path*: string      ## the path after the change (before it, for a delete)
    oldPath*: string   ## a rename's previous path; "" otherwise
    status*: ChangeStatus
    binary*: bool
    similarity*: int   ## a rename's `similarity index`, in percent; 0 if absent
    added*, removed*: int
    origin*: ChangeOrigin
    hasHunks*: bool    ## false for a file list read without its hunks
    hunks*: seq[DiffHunk]

  ChangeDiff* = object
    files*: seq[ChangedFile]

  DiffTotals* = object
    files*, added*, removed*: int

  StatusFilter* = enum
    ## The Code tab's status filter.
    sfAll = "All"
    sfAdded = "Added"
    sfModified = "Modified"
    sfDeleted = "Deleted"
    sfRenamed = "Renamed"

const
  Minus* = "\xE2\x88\x92"
    ## U+2212, the minus sign every `+a −r` count uses (as the activity lines).
  NoChangesText* = "No changes"
  NoDiffDataText* = "No diff data"
  NoMatchingFilesText* = "No files match the current filters"

# ---------------------------------------------------------------------------
# Parsing `git diff`
# ---------------------------------------------------------------------------

proc unquoteGitPath(text: string): string =
  ## git writes a path with unusual characters as a C-style quoted string
  ## (`"a/tab\there"`, octal escapes for bytes >= 0x80; `core.quotePath`).
  ## A bare path is returned as it is.
  let t = text.strip
  if t.len < 2 or t[0] != '"' or t[^1] != '"': return t
  var i = 1
  while i < t.len - 1:
    let c = t[i]
    if c == '\\' and i + 1 < t.len - 1:
      let n = t[i + 1]
      case n
      of 'n': result.add '\n'; i += 2
      of 't': result.add '\t'; i += 2
      of '"': result.add '"'; i += 2
      of '\\': result.add '\\'; i += 2
      of '0'..'7':
        var value = 0
        var j = i + 1
        while j < t.len - 1 and j < i + 4 and t[j] in {'0'..'7'}:
          value = value * 8 + (ord(t[j]) - ord('0'))
          inc j
        result.add chr(value and 0xFF)
        i = j
      else: result.add n; i += 2
    else:
      result.add c
      inc i

proc stripSidePrefix(path: string): string =
  ## `a/src/x.nim` and `b/src/x.nim` -> `src/x.nim`; `/dev/null` stays.
  if path.len > 2 and path[1] == '/' and path[0] in {'a', 'b', 'c', 'i', 'w', 'o'}:
    path[2 .. ^1]
  else: path

proc headerPath(rest: string): string =
  ## The path of a `--- …` / `+++ …` line, without a trailing timestamp that
  ## plain `diff -u` appends after a tab.
  var p = rest
  let tab = p.find('\t')
  if tab >= 0 and not p.startsWith("\""): p = p[0 ..< tab]
  stripSidePrefix(unquoteGitPath(p))

proc gitHeaderPaths(rest: string): tuple[a, b: string] =
  ## The two paths of `diff --git a/X b/Y`. A path with spaces is ambiguous
  ## in this line; git resolves it with the `---`/`+++` or `rename` lines
  ## that follow, which override what is read here.
  let t = rest.strip
  if t.startsWith("\""):
    let close = t.find("\" ", 1)
    if close > 0:
      return (stripSidePrefix(unquoteGitPath(t[0 .. close])),
              stripSidePrefix(unquoteGitPath(t[close + 2 .. ^1])))
  # Unquoted: the two halves are equal for anything but a rename, so split
  # at the middle " b/" when there is one.
  let mid = t.find(" b/")
  if mid > 0:
    return (stripSidePrefix(t[0 ..< mid]), stripSidePrefix(t[mid + 1 .. ^1]))
  let space = t.find(' ')
  if space > 0:
    return (stripSidePrefix(t[0 ..< space]), stripSidePrefix(t[space + 1 .. ^1]))
  (stripSidePrefix(t), stripSidePrefix(t))

proc parseRange(text: string): tuple[start, count: int] =
  ## `12,3` -> (12, 3); `12` -> (12, 1) (git omits a count of 1).
  let comma = text.find(',')
  try:
    if comma < 0: (parseInt(text), 1)
    else: (parseInt(text[0 ..< comma]), parseInt(text[comma + 1 .. ^1]))
  except ValueError:
    (0, 0)

proc parseHunkHeader(line: string; hunk: var DiffHunk): bool =
  ## `@@ -a,b +c,d @@ section`; false for anything else.
  if not line.startsWith("@@ -"): return false
  let close = line.find(" @@", 4)
  if close < 0: return false
  let ranges = line[3 ..< close].splitWhitespace()
  if ranges.len != 2 or not ranges[0].startsWith("-") or not ranges[1].startsWith("+"):
    return false
  let (os, oc) = parseRange(ranges[0][1 .. ^1])
  let (ns, nc) = parseRange(ranges[1][1 .. ^1])
  hunk = DiffHunk(oldStart: os, oldCount: oc, newStart: ns, newCount: nc,
                  section: line[close + 3 .. ^1].strip)
  true

proc parseUnifiedDiff*(text: string; origin = coCommitted): ChangeDiff =
  ## Every file of a `git diff` (or plain `diff -u`) output, in the order the
  ## diff lists them, each with its status, its `+a −r` counts and its
  ## hunks. `origin` marks every file and hunk (a working-tree diff is
  ## `coUncommitted`).
  let lines = text.splitLines()
  var i = 0
  var file: ChangedFile
  var open = false
  template flush() =
    if open:
      result.files.add file
      open = false
  template start(filePath: string) =
    flush()
    file = ChangedFile(path: filePath, status: csModified, origin: origin,
                       hasHunks: true)
    open = true
  while i < lines.len:
    let line = lines[i]
    if line.startsWith("diff --git "):
      let (a, b) = gitHeaderPaths(line["diff --git ".len .. ^1])
      start(b)
      if a != b: file.oldPath = a
      inc i
      continue
    if line.startsWith("--- ") and i + 1 < lines.len and lines[i + 1].startsWith("+++ "):
      let oldP = headerPath(line[4 .. ^1])
      let newP = headerPath(lines[i + 1][4 .. ^1])
      if not open: start(if newP == "/dev/null": oldP else: newP)
      if oldP == "/dev/null":
        file.status = csAdded
        file.path = newP
        file.oldPath = ""
      elif newP == "/dev/null":
        file.status = csDeleted
        file.path = oldP
        file.oldPath = ""
      elif file.status != csRenamed:
        file.path = newP
        file.oldPath = ""
      i += 2
      continue
    if not open:
      inc i
      continue
    if line.startsWith("new file mode"):
      file.status = csAdded
      file.oldPath = ""
    elif line.startsWith("deleted file mode"):
      file.status = csDeleted
      if file.oldPath.len > 0: file.path = file.oldPath
      file.oldPath = ""
    elif line.startsWith("rename from "):
      file.status = csRenamed
      file.oldPath = unquoteGitPath(line["rename from ".len .. ^1])
    elif line.startsWith("rename to "):
      file.status = csRenamed
      file.path = unquoteGitPath(line["rename to ".len .. ^1])
    elif line.startsWith("similarity index "):
      try: file.similarity = parseInt(line["similarity index ".len .. ^1].strip(chars = {'%', ' '}))
      except ValueError: discard
    elif line.startsWith("Binary files ") or line.startsWith("GIT binary patch"):
      file.binary = true
    else:
      var hunk: DiffHunk
      if parseHunkHeader(line, hunk):
        hunk.origin = origin
        var oldLeft = hunk.oldCount
        var newLeft = hunk.newCount
        var oldNo = hunk.oldStart
        var newNo = hunk.newStart
        inc i
        # Read exactly the lines the header counts (and the `\` markers that
        # may follow any of them).
        while i < lines.len and (oldLeft > 0 or newLeft > 0 or
                                 lines[i].startsWith("\\")):
          let l = lines[i]
          if l.len == 0:
            # A blank context line whose leading space an editor stripped.
            hunk.lines.add DiffLine(kind: dlContext, oldLine: oldNo, newLine: newNo)
            inc oldNo; inc newNo; dec oldLeft; dec newLeft
          else:
            case l[0]
            of ' ':
              hunk.lines.add DiffLine(kind: dlContext, text: l[1 .. ^1],
                                      oldLine: oldNo, newLine: newNo)
              inc oldNo; inc newNo; dec oldLeft; dec newLeft
            of '+':
              hunk.lines.add DiffLine(kind: dlAdded, text: l[1 .. ^1], newLine: newNo)
              inc newNo; dec newLeft; inc file.added
            of '-':
              hunk.lines.add DiffLine(kind: dlRemoved, text: l[1 .. ^1], oldLine: oldNo)
              inc oldNo; dec oldLeft; inc file.removed
            of '\\':
              hunk.lines.add DiffLine(kind: dlNoNewline, text: l[1 .. ^1].strip)
            else:
              break   # a truncated hunk: stop at the first line it cannot hold
          inc i
        file.hunks.add hunk
        continue
    inc i
  flush()

# ---------------------------------------------------------------------------
# Totals and the summary line
# ---------------------------------------------------------------------------

proc totals*(diff: ChangeDiff): DiffTotals =
  result.files = diff.files.len
  for f in diff.files:
    result.added += f.added
    result.removed += f.removed

proc countsText*(added, removed: int): string =
  ## `+12 −3`, the VCS panel's per-file counts.
  "+" & $added & " " & Minus & $removed

proc summaryText*(diff: ChangeDiff; hasData = true): string =
  ## The diff's summary line (INV-P3-02): `3 files changed +12 −3`,
  ## `1 file changed +1 −0`, `No changes`, or `No diff data` when the diff
  ## could not be read (`hasData` false).
  if not hasData: return NoDiffDataText
  let t = diff.totals
  if t.files == 0: return NoChangesText
  $t.files & (if t.files == 1: " file changed " else: " files changed ") &
    countsText(t.added, t.removed)

proc rollUpText*(diff: ChangeDiff; ended, readOk: bool): string =
  ## A session's `+a −r` roll-up beside its name (INV-P2-18): `3 files +12 −3`
  ## for an ended session with changes; "" -- hidden -- for a running
  ## session (its diff still moves), a failed read and a change of nothing.
  if not ended or not readOk: return ""
  let t = diff.totals
  if t.files == 0: return ""
  $t.files & (if t.files == 1: " file " else: " files ") & countsText(t.added, t.removed)

# ---------------------------------------------------------------------------
# Committed and uncommitted together
# ---------------------------------------------------------------------------

proc mergeBaseRelative*(committed, uncommitted: ChangeDiff): ChangeDiff =
  ## One file list for a branch's change relative to its merge base: the
  ## committed files in their order, each marked `coBoth` when the working
  ## tree changes it further, then the files only the working tree changes.
  ## A file in both carries both diffs' hunks, each marked with its origin,
  ## committed first, and its status is the status relative to the base:
  ##
  ## - the working tree deletes it: deleted (at its path in the base, for a
  ##   committed rename) -- or, when the branch added it, it is in neither
  ##   the base nor the end state, and is not listed at all;
  ## - the branch deleted it and the working tree adds it back: modified;
  ## - the working tree renames it: the end path, renamed from the base path
  ##   (a file the branch added stays added);
  ## - otherwise the committed status.
  ##
  ## Its counts are the two diffs' counts added, the lines a reviewer reads
  ## in the two diffs in turn; a server that composes the base-relative diff
  ## itself serves the composed counts instead.
  var used = newSeq[bool](uncommitted.files.len)
  for c in committed.files:
    var f = c
    f.origin = coCommitted
    for h in f.hunks.mitems: h.origin = coCommitted
    var dropped = false
    for j, u in uncommitted.files:
      if used[j]: continue
      if u.path == c.path or (u.status == csRenamed and u.oldPath == c.path):
        used[j] = true
        f.origin = coBoth
        case u.status
        of csDeleted:
          case c.status
          of csAdded: dropped = true
          of csRenamed:
            f.status = csDeleted
            f.path = c.oldPath
            f.oldPath = ""
          else: f.status = csDeleted
        of csAdded:
          if c.status == csDeleted: f.status = csModified
        of csRenamed:
          f.path = u.path
          if c.status == csModified:
            f.status = csRenamed
            f.oldPath = u.oldPath
        of csModified: discard
        f.binary = f.binary or u.binary
        f.added += u.added
        f.removed += u.removed
        f.hasHunks = c.hasHunks and u.hasHunks
        for h in u.hunks:
          var uh = h
          uh.origin = coUncommitted
          f.hunks.add uh
        break
    if not dropped: result.files.add f
  for j, u in uncommitted.files:
    if used[j]: continue
    var f = u
    f.origin = coUncommitted
    for h in f.hunks.mitems: h.origin = coUncommitted
    result.files.add f

# ---------------------------------------------------------------------------
# Key source files, filters, one file
# ---------------------------------------------------------------------------

proc normalizedPlanPath(path: string): string =
  ## A plan's key-source path as a repository path: `=…=` markup, a leading
  ## `./` and leading `../` segments removed.
  result = path.strip
  if result.len >= 2 and result[0] == '=' and result[^1] == '=':
    result = result[1 .. ^2]
  while result.startsWith("./") or result.startsWith("../"):
    result = result[(if result.startsWith("./"): 2 else: 3) .. ^1]

proc isKeyFile*(file: ChangedFile; keySourceFiles: openArray[string]): bool =
  ## Whether a plan's key source file names this file. Plans name files
  ## from where the plan lives (`../isonim/src/x.nim`) and a diff from the
  ## repository root (`src/x.nim`), so a path matches when, without its
  ## leading `./` and `../` segments, it equals the file's path or one ends
  ## with `/` and the other.
  for key in keySourceFiles:
    let k = normalizedPlanPath(key)
    if k.len == 0: continue
    for p in [file.path, file.oldPath]:
      if p.len == 0: continue
      if k == p or k.endsWith("/" & p) or p.endsWith("/" & k): return true
  false

proc orderKeyFilesFirst*(files: openArray[ChangedFile];
                         keySourceFiles: openArray[string]): seq[ChangedFile] =
  ## The files with the plan's key source files first; both groups keep the
  ## diff's order.
  for f in files:
    if f.isKeyFile(keySourceFiles): result.add f
  for f in files:
    if not f.isKeyFile(keySourceFiles): result.add f

proc matches*(file: ChangedFile; status: StatusFilter): bool =
  case status
  of sfAll: true
  of sfAdded: file.status == csAdded
  of sfModified: file.status == csModified
  of sfDeleted: file.status == csDeleted
  of sfRenamed: file.status == csRenamed

proc filterFiles*(files: openArray[ChangedFile]; status = sfAll;
                  query = ""): seq[ChangedFile] =
  ## The files a status filter and a search box (`Search files…`, a
  ## case-insensitive part of the path or a rename's old path) keep, in
  ## their order. An empty result is shown as `NoMatchingFilesText`.
  let q = query.strip.toLowerAscii
  for f in files:
    if not f.matches(status): continue
    if q.len > 0 and q notin f.path.toLowerAscii and q notin f.oldPath.toLowerAscii:
      continue
    result.add f

proc fileIndex*(diff: ChangeDiff; path: string): int =
  ## The index of the file at `path` (its path after the change, or a
  ## rename's old path); -1 when the diff does not change it.
  for i, f in diff.files:
    if f.path == path: return i
  for i, f in diff.files:
    if f.oldPath == path: return i
  -1

proc specDiff*(diff: ChangeDiff; path: string): tuple[found: bool, file: ChangedFile] =
  ## One spec file's part of the change (its hunks), for a spec card's Diff
  ## side; `found` is false when the change does not touch it.
  let at = diff.fileIndex(path)
  if at < 0: (false, ChangedFile()) else: (true, diff.files[at])

proc positionText*(index, total: int): string =
  ## `3 of 22`, a file's place among the files shown; "" when none is.
  if index < 0 or total <= 0: "" else: $(index + 1) & " of " & $total
