## nim_agents/diff_walk.nim
##
## One walk over a unified diff's raw lines: each line's kind and the old and
## new line numbers CodeTracer's VCS panel and DeepReview panel show. Moved
## from CodeTracer's `agentic_session_vm.nim` (`diffRows`,
## `deepReviewLines`, CTF-M1 slice 8), whose two copies counted the same way
## and differed only in what they did with a hunk header; CodeTracer's
## adapters now map these lines to its two row types.
##
## The numbering is the one those panels show today, kept exactly: both
## counters start at 0; a hunk header advances neither (it is not read for its
## `@@ -a,b +c,d @@` starts); an added line advances the new count, a removed
## line the old one; every other line -- the `---` / `+++` file headers,
## `\ No newline at end of file`, and the empty string a trailing newline
## leaves -- advances both. It is not the numbering of the files themselves
## (`agent_harbor/change_diff.parseUnifiedDiff` reads the hunk headers for
## that); codetracer-pm issue
## `2026-11-26-agent-workspace-diffs-number-lines-from-zero-not-from-the-hunk.md`
## records the difference.

import std/strutils

type
  WalkedLineKind* = enum
    wlHunk     ## a `@@` hunk header
    wlAdded    ## `+`, but not a `+++` file header
    wlRemoved  ## `-`, but not a `---` file header
    wlContext  ## everything else

  WalkedLine* = object
    kind*: WalkedLineKind
    content*: string   ## the raw line, its prefix included
    oldLine*: int      ## the old count; 0 on an added line
    newLine*: int      ## the new count; 0 on a removed line

proc kindOf*(line: string): WalkedLineKind =
  ## The kind of one raw diff line.
  if line.startsWith("@@"): wlHunk
  elif line.startsWith("+") and not line.startsWith("+++"): wlAdded
  elif line.startsWith("-") and not line.startsWith("---"): wlRemoved
  else: wlContext

proc walkDiffLines*(diff: string): seq[WalkedLine] =
  ## Every line of `diff` (split as `strutils.splitLines` splits it), with its
  ## kind and the counts described above.
  var oldLine = 0
  var newLine = 0
  for line in diff.splitLines():
    let kind = line.kindOf()
    case kind
    of wlHunk:
      result.add WalkedLine(kind: kind, content: line, oldLine: oldLine,
                            newLine: newLine)
    of wlAdded:
      inc newLine
      result.add WalkedLine(kind: kind, content: line, oldLine: 0,
                            newLine: newLine)
    of wlRemoved:
      inc oldLine
      result.add WalkedLine(kind: kind, content: line, oldLine: oldLine,
                            newLine: 0)
    of wlContext:
      inc oldLine
      inc newLine
      result.add WalkedLine(kind: kind, content: line, oldLine: oldLine,
                            newLine: newLine)
