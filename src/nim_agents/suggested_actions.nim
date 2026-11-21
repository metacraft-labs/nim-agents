## Suggested UI actions: a session's agent proposes actions for the
## operator's front-end to perform, the operator approves some of them or
## dismisses them, and the session's timeline keeps one line saying what was
## decided. Plain Nim, no signals, C and JS: a viewmodel holds a
## `SuggestionDecision` and publishes it.
##
## **Where they come from.** Agent Harbor's UI broker carries an agent's
## `suggest_actions` request to the operator's active front-end (agent-harbor
## `specs/UI-Introspection-and-Steering-Broker.md`, "suggest_actions",
## FES-AREQ6): one or more actions taken from the **action vocabulary** the
## front-end advertises in its descriptor (open a resource by URL, show a
## panel, arrange a layout, focus a session tab), each with arguments, and
## the agent's one-line reason. The front-end shows them as one non-modal
## approval block (approve all, approve some, dismiss); approved actions run
## as if the operator had invoked them; actions the operator's configuration
## auto-approves (`auto_approve_actions`, as `"<front-end>:<action>"`) run
## without the block and are listed in the session's activity afterwards.
##
## **Rules held here, for every front-end:**
##
## - an action the front-end cannot perform (outside its vocabulary, or one
##   it cannot do now, with the reason) is never checked and never approved
##   (`cannotPerform`, `toggle`, `beginApprove`);
## - every action the front-end can perform starts checked; the operator
##   unchecks the ones to leave out (`toggle`);
## - the approve button reads `Approve` when every performable action is
##   checked and `Approve N of M` when only some are, M counting the
##   performable actions only; with none checked it is disabled with its
##   reason (`approveLabel`, `approveDisabledReason`);
## - a suggestion is decided once: after `beginApprove` or `dismiss`, no
##   toggle and no second decision changes it;
## - the decided suggestion is one timeline line, with each approved
##   action's outcome under it at level 1 (`recordLines`): `Approved 2 UI
##   actions`, `Dismissed 2 suggested UI actions` (quiet), `Ran 1 UI action`
##   with a quiet `auto-approved`, each outcome under it.
##
## The words are CodeTracer's prototype wording (codetracer-pm
## `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## D23); the decision itself is sent back to Agent Harbor as an
## `OperatorAction` (`operator_actions.decideSuggestion`).

import std/strutils
import ./instruction_composer

export instruction_composer

type
  VocabularyAction* = enum
    ## The actions CodeTracer's front-end descriptor advertises
    ## (codetracer-pm `spec/GUI/Agent-Harbor-Front-End.md`, "Suggested UI
    ## actions").
    vaOpenUrl = "open-url"              ## open a trace or resource URL in a new tab
    vaShowPanel = "show-panel"          ## show a panel
    vaArrangeLayout = "arrange-layout"  ## arrange the layout
    vaFocusSession = "focus-session"    ## focus a session tab

  SuggestedAction* = object
    ## One action of a suggestion.
    id*: string
    action*: string
      ## The vocabulary action it asks for (`open-url`, …); an action the
      ## front-end does not advertise may arrive and is refused.
    args*: seq[(string, string)]
    description*: string
      ## What it does, as the block lists it: `Open the recording of
      ## drained_field_fails in a new tab, at pass 5`.
    doneText*: string
      ## What it did, for its outcome line when the performer says no more
      ## than "done": `Opened the recording of …`.
    unavailable*: string
      ## Non-empty: the front-end advertises the action but cannot perform
      ## it now, and this says why.

  ActionSuggestion* = object
    ## An agent's `suggest_actions` request.
    requestId*: string
    sessionId*: string
    reason*: string       ## the agent's one-line reason
    actions*: seq[SuggestedAction]

  SuggestionPhase* = enum
    spPending = "pending"          ## the block waits on the operator
    spApproving = "approving"      ## approved; the actions are being performed
    spApproved = "approved"        ## every approved action has its outcome
    spDismissed = "dismissed"
    spAutoApproved = "auto-approved"  ## performed without the block

  ActionOutcome* = object
    id*: string
    receipt*: Receipt
    failure*: string     ## the performer could not be asked: why

  SuggestionDecision* = object
    ## The operator's decision about one suggestion.
    suggestion*: ActionSuggestion
    vocabulary*: seq[string]
    unchecked: seq[string]        ## performable actions the operator unchecked
    phase*: SuggestionPhase
    approvedIds*: seq[string]     ## the actions approved, in the block's order
    outcomes*: seq[ActionOutcome] ## in the order they arrived
    replyError*: string
      ## Non-empty: telling Agent Harbor what was decided failed, and why.

  RecordLine* = object
    ## One line of a decided suggestion's record, in a timeline's terms.
    text*: string
    role*: string        ## `body`, `quiet`, `warning`, `error`
    level*: int          ## 0 the decision, 1 an action's outcome
    tag*: string         ## a quiet word after the text (`auto-approved`)

const
  CodeTracerFrontEnd* = "codetracer"
    ## The front-end id CodeTracer's descriptor names (the `<front-end>`
    ## half of an `auto_approve_actions` entry).
  CodeTracerVocabulary* = [$vaOpenUrl, $vaShowPanel, $vaArrangeLayout, $vaFocusSession]
  ApproveLabel* = "Approve"
  DismissLabel* = "Dismiss"
  ApprovingLabel* = "Performing the approved actions…"
  ChooseAnActionReason* = "Choose an action to approve"
  NothingPerformableReason* = "CodeTracer cannot perform any of these actions"
  AutoApprovedTag* = "auto-approved"
  ReplyFailedPrefix* = "Could not tell the agent: "

proc plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

proc newDecision*(suggestion: ActionSuggestion;
                  vocabulary: openArray[string] = CodeTracerVocabulary;
                  autoApproved = false): SuggestionDecision =
  ## A suggestion waiting on the operator, every performable action checked;
  ## or, `autoApproved`, one the operator's configuration lets the
  ## front-end perform without asking (every performable action approved).
  result = SuggestionDecision(suggestion: suggestion, vocabulary: @vocabulary)
  if autoApproved:
    result.phase = spAutoApproved
    for a in suggestion.actions:
      if result.vocabulary.find(a.action) >= 0 and a.unavailable.len == 0:
        result.approvedIds.add a.id

proc indexOf(d: SuggestionDecision; id: string): int =
  for i, a in d.suggestion.actions:
    if a.id == id: return i
  -1

proc actionOf*(d: SuggestionDecision; id: string): SuggestedAction =
  let i = d.indexOf(id)
  if i >= 0: d.suggestion.actions[i] else: SuggestedAction()

proc cannotPerform*(d: SuggestionDecision; id: string): string =
  ## Why the front-end cannot perform the action, or "" when it can. An
  ## action outside the vocabulary is refused with that reason, as the
  ## broker refuses it.
  let i = d.indexOf(id)
  if i < 0: return "no action named " & id
  let a = d.suggestion.actions[i]
  if d.vocabulary.find(a.action) < 0:
    return "CodeTracer does not offer the action " & a.action
  a.unavailable

proc performable*(d: SuggestionDecision; id: string): bool =
  d.cannotPerform(id).len == 0

proc isChecked*(d: SuggestionDecision; id: string): bool =
  ## Whether the action is checked: performable and not unchecked. Once
  ## approved, the approved ones.
  case d.phase
  of spPending: d.performable(id) and id notin d.unchecked
  of spApproving, spApproved, spAutoApproved: id in d.approvedIds
  of spDismissed: false

proc isDecided*(d: SuggestionDecision): bool = d.phase != spPending

proc toggle*(d: var SuggestionDecision; id: string): bool =
  ## Checks or unchecks a performable action while the suggestion waits.
  ## Returns whether anything changed: an action the front-end cannot
  ## perform, an unknown id, or a decided suggestion changes nothing.
  if d.phase != spPending or not d.performable(id): return false
  let i = d.unchecked.find(id)
  if i >= 0: d.unchecked.delete(i) else: d.unchecked.add id
  true

proc performableCount*(d: SuggestionDecision): int =
  for a in d.suggestion.actions:
    if d.performable(a.id): inc result

proc checkedIds*(d: SuggestionDecision): seq[string] =
  ## The checked actions, in the block's order.
  for a in d.suggestion.actions:
    if d.isChecked(a.id): result.add a.id

proc canApprove*(d: SuggestionDecision): bool =
  d.phase == spPending and d.checkedIds.len > 0

proc approveLabel*(d: SuggestionDecision): string =
  ## `Approve` when every performable action is checked (or none is, the
  ## button then disabled), `Approve N of M` when only some are.
  let checked = d.checkedIds.len
  let total = d.performableCount
  if checked > 0 and checked < total: ApproveLabel & " " & $checked & " of " & $total
  else: ApproveLabel

proc approveDisabledReason*(d: SuggestionDecision): string =
  ## Why `Approve` is disabled while the suggestion waits; "" when it is not.
  if d.phase != spPending or d.checkedIds.len > 0: return ""
  if d.performableCount == 0: NothingPerformableReason else: ChooseAnActionReason

proc beginApprove*(d: var SuggestionDecision): bool =
  ## Approves the checked actions: they are to be performed, in the block's
  ## order. Returns false (and changes nothing) unless the suggestion waits
  ## and at least one action is checked.
  if not d.canApprove: return false
  d.approvedIds = d.checkedIds
  d.phase = spApproving
  true

proc dismiss*(d: var SuggestionDecision): bool =
  ## Dismisses the whole suggestion; nothing is performed.
  if d.phase != spPending: return false
  d.phase = spDismissed
  true

proc outcomeOf*(d: SuggestionDecision; id: string): (bool, ActionOutcome) =
  for o in d.outcomes:
    if o.id == id: return (true, o)
  (false, ActionOutcome())

proc applyOutcome*(d: var SuggestionDecision; id: string; receipt: Receipt) =
  ## The performer's answer for an approved action. Answers for actions not
  ## approved, or a second answer for one, change nothing. When the last
  ## approved action has its outcome, an approving suggestion is approved.
  if d.phase notin {spApproving, spAutoApproved} or id notin d.approvedIds: return
  if d.outcomeOf(id)[0]: return
  d.outcomes.add ActionOutcome(id: id, receipt: receipt)
  if d.phase == spApproving and d.outcomes.len == d.approvedIds.len:
    d.phase = spApproved

proc applyPerformFailure*(d: var SuggestionDecision; id: string; reason: string) =
  ## The performer could not be asked for an approved action: recorded as
  ## refused with the reason.
  d.applyOutcome(id, Receipt(outcome: uoRefused, result: reason))

proc allPerformed*(d: SuggestionDecision): bool =
  d.outcomes.len == d.approvedIds.len

proc applyReplyFailure*(d: var SuggestionDecision; reason: string) =
  ## Telling Agent Harbor what was decided failed. The decision stands (the
  ## actions were performed, or the block dismissed); the record says so.
  d.replyError = reason

proc outcomeText*(action: SuggestedAction; receipt: Receipt): string =
  ## An approved action's outcome line: what it did, why it was refused, or
  ## how much of it was done.
  case receipt.outcome
  of uoDone, uoNone:
    if receipt.result.len > 0: receipt.result
    elif action.doneText.len > 0: action.doneText
    else: action.description
  of uoRefused:
    "Refused: " & (if receipt.result.len > 0: receipt.result else: action.description)
  of uoPartial: receipt.result

proc outcomeRole*(receipt: Receipt): string =
  case receipt.outcome
  of uoDone, uoNone: "body"
  of uoRefused, uoPartial: "warning"

proc recordHeadline*(d: SuggestionDecision): string =
  ## The decided suggestion's line; "" while it waits or is being performed.
  case d.phase
  of spPending, spApproving: ""
  of spApproved: "Approved " & plural(d.approvedIds.len, "UI action", "UI actions")
  of spDismissed:
    "Dismissed " & plural(d.suggestion.actions.len, "suggested UI action",
                          "suggested UI actions")
  of spAutoApproved:
    "Ran " & plural(d.approvedIds.len, "UI action", "UI actions")

proc recordLines*(d: SuggestionDecision): seq[RecordLine] =
  ## The decided suggestion as timeline lines: the decision, then each
  ## approved action's outcome at level 1 (several auto-approved actions
  ## likewise), then, if telling the agent failed, why, at level 1.
  let headline = d.recordHeadline
  if headline.len == 0: return
  case d.phase
  of spDismissed:
    result.add RecordLine(text: headline, role: "quiet")
  of spAutoApproved:
    result.add RecordLine(text: headline, role: "body", tag: AutoApprovedTag)
  else:
    result.add RecordLine(text: headline, role: "body")
  if d.phase in {spApproved, spAutoApproved}:
    for id in d.approvedIds:
      let (has, o) = d.outcomeOf(id)
      if not has: continue
      let a = d.actionOf(id)
      result.add RecordLine(text: outcomeText(a, o.receipt), role: outcomeRole(o.receipt),
                            level: 1)
  if d.replyError.len > 0:
    result.add RecordLine(text: ReplyFailedPrefix & d.replyError, role: "error", level: 1)

proc autoApproves*(autoApproveActions: openArray[string]; action: string;
                   frontEnd = CodeTracerFrontEnd): bool =
  ## Whether an `auto_approve_actions` list lets `frontEnd` perform `action`
  ## without asking: its entries are `"<front-end>:<action>"`, so an entry
  ## for another front-end's action of the same name does not.
  (frontEnd & ":" & action) in autoApproveActions

proc splitAutoApproved*(suggestion: ActionSuggestion;
                        autoApproveActions: openArray[string];
                        frontEnd = CodeTracerFrontEnd): (ActionSuggestion, ActionSuggestion) =
  ## The suggestion's actions the configuration auto-approves, and the rest,
  ## each as a suggestion of its own with the same request, session and
  ## reason (either may hold no action).
  var auto = suggestion
  var asked = suggestion
  auto.actions = @[]
  asked.actions = @[]
  for a in suggestion.actions:
    if autoApproves(autoApproveActions, a.action, frontEnd): auto.actions.add a
    else: asked.actions.add a
  (auto, asked)

proc describe*(d: SuggestionDecision): string =
  ## One line naming the decision, for a log or a test.
  result = $d.phase & " checked=[" & d.checkedIds.join(",") & "]"
  if d.approvedIds.len > 0: result.add " approved=[" & d.approvedIds.join(",") & "]"
