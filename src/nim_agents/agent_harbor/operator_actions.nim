## What the operator asks an Agent Harbor server to do from the Inbox and
## the Changes panel -- answer, decide, approve, revert, set a priority --
## and from the omnibox composer -- instruct a session or a manager, launch a
## task, start an initiative, stop a session's turn -- as typed values with
## no transport (INV-D-09, INV-D-15, INV-P3-12 … INV-P3-19; INV-C-20 …
## INV-C-23, INV-P2-30, -32, -34, -42, -61).
##
## **Test runs and traces.** The Tests panel and agent panes add four writes:
## run or record tests on platforms, cancel a test run, open a trace in a
## remote replay, download a trace (INV-D-17, INV-D-23, INV-D-25). Their
## routes are only proposed, so `routeOf` answers ("", ""); a test run's and
## a trace's ids travel in `params` (`test-run`, `trace`), so no field is
## added for them.
##
## A view never talks to a server: it builds an `OperatorAction` and hands
## it to its data source, which sends it, answers it from a script, or says
## it cannot. `routeOf` names the REST route an action goes to where Agent
## Harbor serves one, and "" where the route is still only proposed.
##
## **Secrets.** A sudo approval may carry the operator's password. It is a
## `Secret`, whose `$` never prints it: an action's `$` -- what a log or a
## scripted source's record holds -- shows `secret supplied` instead.
## `reveal` is the one way to read it, for a transport.
##
## Signal-free and app-agnostic; identical on the C and JS targets.

import std/[algorithm, sequtils, strutils]

type
  Secret* = object
    ## A value that is never printed (`$` gives `[secret]`).
    value: string

  OperatorActionKind* = enum
    oaAnswerQuestion = "answer-question"
    oaSendInstruction = "send-instruction"     ## after an ended turn
    oaDecidePermission = "decide-permission"   ## an agent's permission options
    oaDecideApproval = "decide-approval"       ## a sudo or network approval
    oaCancelLogin = "cancel-login"
    oaRespondFeedback = "respond-feedback"
    oaSendDraft = "send-draft"
    oaSetPriority = "set-priority"
    oaApproveSpecChange = "approve-spec-change"
    oaRequestSpecChanges = "request-spec-changes"
    oaRevertSpecChange = "revert-spec-change"
    oaApplyStaged = "apply-staged"
    oaDiscardStaged = "discard-staged"
    oaMarkViewing = "mark-viewing"             ## the viewing heartbeat
    oaInstructManager = "instruct-manager"     ## an instruction to a manager agent
    oaLaunchTask = "launch-task"               ## new work, with its launch options
    oaStartInitiative = "start-initiative"     ## a new initiative and its plan
    oaStopSession = "stop-session"             ## stop the turn a session runs
    oaDecideSuggestion = "decide-suggestion"   ## approve or dismiss an agent's suggested UI actions
    oaStartTestRun = "start-test-run"          ## run (or record) tests on platforms
    oaCancelTestRun = "cancel-test-run"        ## cancel a test run's active platform runs
    oaOpenTraceReplay = "open-trace-replay"    ## open a trace in a remote replay
    oaDownloadTrace = "download-trace"         ## download a trace

  ApprovalScope* = enum
    ## What a sudo or network approval asks for; each has its own route.
    asSudo = "sudo"          ## run a command as root
    asNetwork = "network"    ## reach a domain

  ApprovalDecision* = enum
    adApprove = "approve"
    adApproveForSession = "approve_session"
    adDeny = "deny"

  OperatorAction* = object
    kind*: OperatorActionKind
    server*: string        ## the fleet server the item comes from; "" for local
    sessionId*: string
    taskId*: string
    itemId*: string        ## the inbox item the action answers, when one does
    requestId*: string     ## the question, permission, approval, login or feedback id
    text*: string
    choices*: seq[string]
    decision*: string      ## an option id, an `ApprovalDecision`, `approve` / `reject`
    priority*: string      ## `urgent`, `high`, `normal`, `low`
    specPath*: string      ## a spec card's file
    milestoneId*: string
    scope*: ApprovalScope  ## oaDecideApproval: which approval it decides
    password*: Secret
    params*: seq[(string, string)]
      ## A launch's or an initiative's options, by name, in the form's order
      ## (`repository`, `branch`, `agents`, `cron`, `plan`, …).

proc secret*(value: string): Secret = Secret(value: value)
proc reveal*(s: Secret): string = s.value
proc isSet*(s: Secret): bool = s.value.len > 0
proc `$`*(s: Secret): string = (if s.value.len > 0: "[secret]" else: "")
proc `==`*(a, b: Secret): bool = a.value == b.value

proc clearSecrets*(action: var OperatorAction) =
  ## Forgets the password once the action is answered.
  action.password = Secret()

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc answerQuestion*(sessionId, requestId: string; text = "";
                     choices: seq[string] = @[]; decision = "";
                     itemId = "", server = ""): OperatorAction =
  ## The answer to an agent's question (free form, choices or a
  ## confirmation's `approve` / `reject`).
  OperatorAction(kind: oaAnswerQuestion, sessionId: sessionId, requestId: requestId,
                 text: text, choices: choices, decision: decision, itemId: itemId,
                 server: server)

proc sendInstruction*(sessionId, text: string; itemId = "", server = ""): OperatorAction =
  ## The next instruction to a session whose turn ended.
  OperatorAction(kind: oaSendInstruction, sessionId: sessionId, text: text,
                 itemId: itemId, server: server)

proc decidePermission*(sessionId, requestId, optionId: string;
                       itemId = "", server = ""): OperatorAction =
  ## One of the agent's permission options (`allow_once`, …), by its id.
  OperatorAction(kind: oaDecidePermission, sessionId: sessionId, requestId: requestId,
                 decision: optionId, itemId: itemId, server: server)

proc decideApproval*(sessionId, requestId: string; decision: ApprovalDecision;
                     scope = asSudo; password = ""; itemId = "",
                     server = ""): OperatorAction =
  ## A sudo or network approval; a sudo password travels as a `Secret`.
  OperatorAction(kind: oaDecideApproval, sessionId: sessionId, requestId: requestId,
                 decision: $decision, scope: scope, password: secret(password),
                 itemId: itemId, server: server)

proc cancelLogin*(sessionId, requestId: string; itemId = "", server = ""): OperatorAction =
  ## Withdraws a login request.
  OperatorAction(kind: oaCancelLogin, sessionId: sessionId, requestId: requestId,
                 itemId: itemId, server: server)

proc respondFeedback*(taskId, feedbackId: string; text = "";
                      choices: seq[string] = @[]; decision = "";
                      sessionId = "", itemId = "", server = ""): OperatorAction =
  ## A response to a feedback request.
  OperatorAction(kind: oaRespondFeedback, taskId: taskId, requestId: feedbackId,
                 text: text, choices: choices, decision: decision,
                 sessionId: sessionId, itemId: itemId, server: server)

proc sendDraft*(sessionId, requestId: string; text = "";
                choices: seq[string] = @[]; itemId = "", server = ""): OperatorAction =
  ## Sends the draft a manager prepared, as it is.
  OperatorAction(kind: oaSendDraft, sessionId: sessionId, requestId: requestId,
                 text: text, choices: choices, itemId: itemId, server: server)

proc setPriority*(sessionId, priority: string; server = ""): OperatorAction =
  OperatorAction(kind: oaSetPriority, sessionId: sessionId, priority: priority,
                 server: server)

proc approveSpecChange*(taskId, milestoneId, specPath, feedbackId: string): OperatorAction =
  ## Approves a pending spec change through the feedback request open for it.
  OperatorAction(kind: oaApproveSpecChange, taskId: taskId, milestoneId: milestoneId,
                 specPath: specPath, requestId: feedbackId)

proc requestSpecChanges*(taskId, milestoneId, specPath, text: string): OperatorAction =
  OperatorAction(kind: oaRequestSpecChanges, taskId: taskId, milestoneId: milestoneId,
                 specPath: specPath, text: text)

proc revertSpecChange*(taskId, milestoneId, specPath: string): OperatorAction =
  OperatorAction(kind: oaRevertSpecChange, taskId: taskId, milestoneId: milestoneId,
                 specPath: specPath)

proc applyStaged*(taskId, specPath: string): OperatorAction =
  OperatorAction(kind: oaApplyStaged, taskId: taskId, specPath: specPath)

proc discardStaged*(taskId, specPath: string): OperatorAction =
  OperatorAction(kind: oaDiscardStaged, taskId: taskId, specPath: specPath)

proc markViewing*(sessionId: string; server = ""): OperatorAction =
  ## "The operator is looking at this session's waiting item now"; sent
  ## every `ViewingHeartbeatMs` while the item is visible.
  OperatorAction(kind: oaMarkViewing, sessionId: sessionId, server: server)

proc instructManager*(managerSessionId, text: string; taskId = "";
                      server = ""): OperatorAction =
  ## An instruction to a manager agent (the manager of the initiative
  ## `taskId`, or Agent Harbor's).
  OperatorAction(kind: oaInstructManager, sessionId: managerSessionId, text: text,
                 taskId: taskId, server: server)

proc launchTask*(text: string; params: seq[(string, string)];
                 managerSessionId = ""; server = ""): OperatorAction =
  ## New work: the instruction and its launch options, sent through the
  ## manager agent that routes it.
  OperatorAction(kind: oaLaunchTask, sessionId: managerSessionId, text: text,
                 params: params, server: server)

proc startInitiative*(goal: string; params: seq[(string, string)];
                      managerSessionId = ""; server = ""): OperatorAction =
  ## A new initiative: its goal and its plan's options.
  OperatorAction(kind: oaStartInitiative, sessionId: managerSessionId, text: goal,
                 params: params, server: server)

proc stopSession*(sessionId: string; server = ""): OperatorAction =
  ## Stops the turn the session is running.
  OperatorAction(kind: oaStopSession, sessionId: sessionId, server: server)

proc decideSuggestion*(sessionId, requestId, decision: string;
                       approvedIds: seq[string] = @[]; server = ""): OperatorAction =
  ## The operator's decision about an agent's `suggest_actions` request
  ## (agent-harbor `specs/UI-Introspection-and-Steering-Broker.md`):
  ## `decision` is `approve` (with the ids of the actions approved, in
  ## `choices`) or `dismiss`.
  OperatorAction(kind: oaDecideSuggestion, sessionId: sessionId, requestId: requestId,
                 decision: decision, choices: approvedIds, server: server)

proc startTestRun*(sessionId: string; tests, platforms: seq[string];
                   record, reuse: string; server = ""): OperatorAction =
  ## A test run over the session's change: the test ids (`<runner>/<id>`) in
  ## `choices`, each platform as `("platform", <features joined by "+">)` in
  ## `params` (`os.linux+arch.x86_64`), then `("record", …)` (`none`,
  ## `failing`, `all`) and `("reuse", …)` (`certified`, `never`). Proposed
  ## route: `POST /api/v1/test-runs`.
  var params: seq[(string, string)]
  for platform in platforms: params.add ("platform", platform)
  params.add ("record", record)
  params.add ("reuse", reuse)
  OperatorAction(kind: oaStartTestRun, sessionId: sessionId, choices: tests,
                 params: params, server: server)

proc cancelTestRun*(testRunId: string; sessionId = "", server = ""): OperatorAction =
  ## Cancels every platform run of the test run still active, as
  ## `("test-run", <id>)` in `params`. Proposed route:
  ## `DELETE /api/v1/test-runs/{id}`.
  OperatorAction(kind: oaCancelTestRun, sessionId: sessionId,
                 params: @[("test-run", testRunId)], server: server)

proc openTraceReplay*(traceId: string; sessionId = "", server = ""): OperatorAction =
  ## Opens the trace in a replay started near it, as `("trace", <id>)` in
  ## `params`. Agent Harbor names no route for it yet.
  OperatorAction(kind: oaOpenTraceReplay, sessionId: sessionId,
                 params: @[("trace", traceId)], server: server)

proc downloadTrace*(traceId: string; sessionId = "", server = ""): OperatorAction =
  ## Downloads the trace, as `("trace", <id>)` in `params`. Agent Harbor
  ## names no route for it yet.
  OperatorAction(kind: oaDownloadTrace, sessionId: sessionId,
                 params: @[("trace", traceId)], server: server)

proc paramValues(action: OperatorAction; name: string): seq[string] =
  ## Every value of the parameter `name`, in order.
  for (key, value) in action.params:
    if key == name: result.add value

proc paramOf(action: OperatorAction; name: string): string =
  ## The first value of the parameter `name`, or "".
  for (key, value) in action.params:
    if key == name: return value
  ""

const ViewingHeartbeatMs* = 20_000
  ## How often a visible item's page repeats `markViewing`.

# ---------------------------------------------------------------------------
# Routes, targets, records
# ---------------------------------------------------------------------------

proc routeOf*(action: OperatorAction): tuple[verb, path: string] =
  ## The REST route the action goes to where Agent Harbor serves one; ("",
  ## "") while it is only proposed (a login's cancel, the spec-card actions).
  let s = action.sessionId
  case action.kind
  of oaAnswerQuestion, oaDecidePermission, oaSendDraft:
    ("POST", "/api/v1/sessions/" & s & "/feedback/" & action.requestId & "/respond")
  of oaSendInstruction, oaInstructManager: ("POST", "/api/v1/sessions/" & s & "/prompt")
  of oaStopSession: ("POST", "/api/v1/sessions/" & s & "/stop")
  of oaLaunchTask: ("POST", "/api/v1/tasks")
  of oaDecideApproval:
    # The two approval kinds have their own collections.
    if action.scope == asNetwork:
      ("POST", "/api/v1/sessions/" & s & "/domain-approvals/" & action.requestId & "/decision")
    else:
      ("POST", "/api/v1/sessions/" & s & "/sudo-approvals/" & action.requestId & "/decision")
  of oaRespondFeedback:
    ("POST", "/api/v1/tasks/" & action.taskId & "/feedback/" & action.requestId & "/respond")
  of oaSetPriority: ("PATCH", "/api/v1/sessions/" & s)
  of oaMarkViewing: ("PUT", "/api/v1/sessions/" & s & "/viewing")
  of oaCancelLogin, oaApproveSpecChange, oaRequestSpecChanges, oaRevertSpecChange,
     oaApplyStaged, oaDiscardStaged, oaStartInitiative: ("", "")
  # Agent Harbor documents the request (`suggest_actions`) but no route for
  # the front-end's answer yet: proposed only.
  of oaDecideSuggestion: ("", "")
  # The test-run writes are only proposed: `POST /api/v1/test-runs` (start)
  # and `DELETE /api/v1/test-runs/{id}` (cancel). Opening a trace in a remote
  # replay and downloading one have no route named yet.
  of oaStartTestRun, oaCancelTestRun, oaOpenTraceReplay, oaDownloadTrace: ("", "")

proc targetOf*(action: OperatorAction): string =
  ## What the action acts on; one action per target is in flight at a time.
  case action.kind
  of oaApproveSpecChange, oaRequestSpecChanges, oaRevertSpecChange,
     oaApplyStaged, oaDiscardStaged:
    "spec:" & action.taskId & ":" & action.specPath
  of oaSetPriority: "priority:" & action.server & ":" & action.sessionId
  of oaMarkViewing: "viewing:" & action.server & ":" & action.sessionId
  # A stop is never queued behind the instruction it may be stopping, and
  # each launch or new initiative is new work, not a second press on the
  # manager's one request: their own keys. The same launch pressed twice
  # keeps one key, so it is not sent twice.
  of oaStopSession: "stop:" & action.server & ":" & action.sessionId
  of oaLaunchTask: "launch:" & action.server & ":" & action.sessionId & ":" & action.text
  of oaStartInitiative:
    "initiative:" & action.server & ":" & action.sessionId & ":" & action.text
  # The same request pressed twice is one action: the tests and platforms
  # are keyed as sets (sorted), so their order does not make a second one.
  # A run and a record of the same tests on the same platforms share it too:
  # one start per tests-and-platforms is in flight at a time.
  # Each id is quoted (`escape`), so an id holding the separator cannot make
  # two different requests one target (`["a,b"]` is not `["a", "b"]`).
  of oaStartTestRun:
    "testrun:" & action.server & ":" & action.sessionId & ":" &
      action.choices.sorted.mapIt(it.escape).join(",") & ":" &
      action.paramValues("platform").sorted.mapIt(it.escape).join(",")
  of oaCancelTestRun: "cancel:" & action.server & ":" & action.paramOf("test-run")
  of oaOpenTraceReplay: "replay:" & action.server & ":" & action.paramOf("trace")
  of oaDownloadTrace: "download:" & action.server & ":" & action.paramOf("trace")
  else:
    if action.itemId.len > 0: "item:" & action.server & ":" & action.itemId
    else: "request:" & action.server & ":" & action.sessionId & ":" & action.requestId

proc `$`*(action: OperatorAction): string =
  ## One line naming the action and its fields, for a log or a scripted
  ## source's record. A password is never in it: `secret supplied`.
  var parts = @[$action.kind]
  template field(name: string; value: string) =
    if value.len > 0: parts.add name & "=" & value
  field("server", action.server)
  field("session", action.sessionId)
  field("task", action.taskId)
  field("item", action.itemId)
  field("request", action.requestId)
  field("milestone", action.milestoneId)
  field("spec", action.specPath)
  field("decision", action.decision)
  if action.kind == oaDecideApproval: parts.add "scope=" & $action.scope
  field("priority", action.priority)
  if action.choices.len > 0: parts.add "choices=" & action.choices.join(",")
  for (name, value) in action.params: field(name, value)
  if action.text.len > 0: parts.add "text=" & action.text.escape
  if action.password.isSet: parts.add "secret supplied"
  parts.join(" ")
