## CodeTracer's agent tabs as data (`nim_agents/agent_tabs`), native and JS:
## the session a tab id names, and the caption a tab shows. Plain values;
## every expectation is written out by hand. The data is invented, as
## everything in this public repository.

import std/unittest
import nim_agents/agent_tabs

proc tab(tabId: string; title = ""; done = 0; total = 0): AgentServiceSessionEntry =
  AgentServiceSessionEntry(tabId: tabId, title: title,
    milestonesCompleted: done, milestonesTotal: total)

suite "agent tabs":
  test "a tab id names its session, or an empty entry":
    let state = AgentSessionsState(activeTabId: "t2",
      sessions: @[tab("t1", "Parser"), tab("t2", "Lexer")])
    check state.findSession("t2").title == "Lexer"
    check state.findSession("t1").title == "Parser"
    check state.findSession("t9").tabId == ""
    check AgentSessionsState().findSession("t1").tabId == ""

  test "a caption is the title, else the tab id, else Agent task":
    check tab("t1", "Fix the parser").captionForSession == "Fix the parser"
    check tab("t1").captionForSession == "t1"
    check tab("").captionForSession == "Agent task"

  test "a caption carries the plan's progress when there is a plan":
    check tab("t1", "Fix the parser", 2, 5).captionForSession ==
      "Fix the parser 2/5"
    check tab("t1", "Fix the parser", 0, 3).captionForSession ==
      "Fix the parser 0/3"
    check tab("t1", "Fix the parser", 4, 0).captionForSession ==
      "Fix the parser"

  test "a new tab starts disconnected on the ACP backend":
    let s = AgentServiceSessionEntry()
    check s.backend == asbAcp
    check s.lifecycle == aslDisconnected
    check s.events.len == 0
