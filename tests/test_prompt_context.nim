## The prompt's "add context" attachments (`nim_agents/prompt_context`),
## native and JS: the header a prompt with attachments carries, the
## spelling of the editor selection's path, the lines a selection covers and
## how a path is attached once.
##
## The module is pure data and functions; every expectation is written out by
## hand. Moved with the module from CodeTracer's
## `test_plat54_agent_activity` ("the header a prompt with attachments
## carries"), which keeps its view-model half.

import std/unittest
import nim_agents/prompt_context

suite "prompt context":
  test "the header a prompt with attachments carries":
    check contextPromptText("fix it", []) == "fix it"
    check contextPromptText("fix it", ["src/a.nim", "src/a.nim:3-5"]) ==
       "Context paths:\n- src/a.nim\n- src/a.nim:3-5\n\nfix it"
    check editorSelectionContext("src/a.nim", 5, 3) == "src/a.nim:3-5"
    check editorSelectionContext("src/a.nim", 7, 7) == "src/a.nim:7"
    check editorSelectionContext("", 1, 2) == ""
    check withContextPath(["a"], "a") == @["a"]
    check withContextPath(["a"], " b ") == @["a", "b"]
    check withContextPath(["a"], "   ") == @["a"]

  test "the lines the desktop's Monaco ranges cover":
    # A range that ends at the start of a line does not cover that line.
    check selectedLinesOf([(startLine: 3, startColumn: 1, endLine: 5,
                            endColumn: 1)], 9) == (first: 3, last: 4)
    check selectedLinesOf([(startLine: 3, startColumn: 2, endLine: 5,
                            endColumn: 3)], 9) == (first: 3, last: 5)
    # Nothing selected: the caret's line. Several ranges: all of them.
    check selectedLinesOf([(startLine: 4, startColumn: 2, endLine: 4,
                            endColumn: 2)], 4) == (first: 4, last: 4)
    check selectedLinesOf([(startLine: 7, startColumn: 1, endLine: 7,
                            endColumn: 4),
                           (startLine: 2, startColumn: 1, endLine: 3,
                            endColumn: 2)], 1) == (first: 2, last: 7)
    check selectedLinesOf([], 6) == (first: 6, last: 6)

  test "the add menu's labels keep the desktop's order":
    check [aciUpload.label, aciFilesFolders.label, aciEditorSelection.label,
           aciRecording.label] ==
          ["Upload attachment", "Files & folders", "Editor selection",
           "Recording / trace"]
