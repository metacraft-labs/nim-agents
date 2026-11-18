## The omnibox composer's domain: an instruction typed in a front-end's
## omnibox, the context the window offers with it, the routing agent's
## decision about where it goes and what it cites, the operator's redirects,
## and the deliveries that follow. Plain Nim, no signals, C and JS: a
## viewmodel holds a `ComposerDraft` and publishes it.
##
## **The flow** (one step). The operator types (`setText`); while they
## type, the instruction goes to a routing agent (`beginRouting`) and its
## answer, a `RoutingDecision` (`applyDecision`) or a failure
## (`applyRouteFailure`), is shown live: the destination it chose -- the
## window's agent session, a manager agent, or an agent that performs UI
## actions -- and the context it cites, as chips. Before sending, the
## operator may choose another destination (`choose`) and cite or uncite any
## chip (`toggleContext`); those choices stand when the router answers again
## for a changed text. `Enter` sends at once (`beginSend`) to the destination
## shown; pressed while the router has not answered and the operator has not
## chosen, the instruction is sent as soon as the decision arrives
## (`awaitingRoute`). The deliverer's answer (`applyReceipt`,
## `applyDeliveryFailure`) completes the delivery. After sending, the
## instruction can be redirected: sent again to another destination
## (`sendAgain`); nothing is withdrawn, because a delivered prompt cannot be
## taken back, and the record says it was redirected.
##
## **Rules held here, for every front-end:**
##
## - the destinations are always listed in one fixed order (session,
##   manager, UI action), whatever was decided (`destinationRows`);
## - nothing is cited by default; what is cited is what the decision cites
##   among the items the window offered, plus what the operator cited, less
##   what the operator uncited, never a note (`cited`);
## - a destination the window cannot reach is never routed to, chosen or
##   sent to;
## - an answer that arrives for a step the draft is no longer in changes
##   nothing (the caller's routing or delivery was superseded).
##
## **Launching** a task or **starting an initiative** is a manager delivery
## with an intent (`RouteIntent`) and options (`LaunchOptions`,
## `NewInitiativeForm`), validated here (`validateLaunch`, `validateCron`,
## `validateInitiative`) so every front-end refuses the same input with the
## same words.

import std/strutils

type
  ContextKind* = enum
    ckPane = "pane"            ## the focused pane
    ckSelection = "selection"  ## what is selected in it
    ckFile = "file"            ## the open file and the cursor
    ckReplay = "replay"        ## the replay position
    ckSession = "session"      ## the active session tab
    ckGaze = "gaze"            ## what the operator looked at
    ckAttachment = "attachment" ## added by the operator

  ContextItem* = object
    ## One thing the window offers to cite with an instruction.
    id*: string
    kind*: ContextKind
    label*: string      ## what its chip says
    detail*: string     ## its tooltip
    reference*: string
      ## What an agent resolves: a file and line, a replay position, an
      ## `agent-harbor://` URL. Never screen coordinates.
    excluded*: bool     ## uncited by the operator: never cited
    pinned*: bool       ## cited by the operator, whatever the router says
    note*: bool
      ## A chip that tells the operator something (`Gaze paused`) and is
      ## never cited or switched off.

  TargetKind* = enum
    tkSession = "session"      ## the window's agent session
    tkManager = "manager"      ## a manager agent
    tkUiAction = "ui-action"   ## an agent that performs UI actions

  RouteTarget* = object
    ## A destination as the window can reach it.
    kind*: TargetKind
    id*: string
    label*: string
      ## What it is: the session's title, the manager's initiative, the
      ## front-end that performs the UI action.
    available*: bool
    unavailableReason*: string
    running*: bool
      ## A session running a turn: the row offers to stop it.

  RouteIntent* = enum
    riInstruct = "instruct"
    riLaunchTask = "launch-task"
    riNewInitiative = "new-initiative"

  RoutingDecision* = object
    target*: TargetKind
    intent*: RouteIntent
    reason*: string        ## why the router chose it, in its words
    cited*: seq[string]    ## ids of the context items it cites
    action*: string        ## a UI action: what it will do

  DeliveryState* = enum
    dsSending = "sending"
    dsSent = "sent"
    dsFailed = "failed"

  UiOutcome* = enum
    uoNone = ""
    uoDone = "done"
    uoRefused = "refused"
    uoPartial = "partial"

  Receipt* = object
    ## A deliverer's answer for one delivery.
    notice*: string      ## a launch notice: where the session started
    outcome*: UiOutcome  ## a UI action's outcome
    result*: string      ## what the UI action did, or why it did not

  Delivery* = object
    target*: TargetKind
    state*: DeliveryState
    error*: string
    receipt*: Receipt

  ComposerPhase* = enum
    cpComposing = "composing"
    cpSending = "sending"        ## sent, or waiting for the decision to send
    cpSent = "sent"
    cpSendFailed = "send-failed"

  RouteStatus* = enum
    rsNone = ""                  ## nothing typed, or not asked yet
    rsRouting = "routing"
    rsDecided = "decided"
    rsFailed = "failed"

  ComposerRecord* = object
    ## A sent instruction, as `Recent` lists it.
    text*: string
    intent*: RouteIntent
    deliveries*: seq[Delivery]
    labels*: seq[string]    ## each delivery's destination label, in order

  RowMark* = enum
    rmNone = ""
    rmRouted = "routed"      ## the router's choice, still the one to send
    rmChosen = "chosen"      ## the operator's choice
    rmRouterChoice = "router-choice"
      ## the router's choice after the operator chose another

  DestinationRow* = object
    ## One destination as every front-end lists it.
    target*: TargetKind
    title*: string
    label*: string
    reason*: string        ## the router's reason, or why it is unavailable
    mark*: RowMark
    selected*: bool        ## the one `Enter` sends to
    enabled*: bool         ## it can be chosen (or sent to again)
    delivery*: DeliveryState
    delivered*: bool       ## it has a delivery
    error*: string
    receipt*: Receipt
    canStop*: bool         ## a running session: `Stop agent`
    canSendAgain*: bool    ## sent elsewhere already; `Send to …`

  RunOn* = enum
    roThisMachine = "This machine"
    roExecutor = "Executor"
    roServerChoice = "The server's choice"

  OpenIn* = enum
    oiNewTab = "New tab"
    oiSplit = "Split"
    oiBeside = "Beside"

  Concurrency* = enum
    ccAllowOverlap = "Allow overlap"
    ccForbidOverlap = "Forbid overlap"
    ccReplacePrevious = "Replace previous"

  Misfire* = enum
    mfRunOnce = "Run once, drop catch-up"
    mfRunAll = "Run all, catch up"

  Schedule* = object
    enabled*: bool
    cron*: string
    timezone*: string
    jitterSeconds*: int
    concurrency*: Concurrency
    misfire*: Misfire

  LaunchOptions* = object
    repository*: string
    branch*: string
    agents*: seq[string]
    runOn*: RunOn
    executor*: string
    sessionName*: string   ## blank: the server names it
    openIn*: OpenIn
    focus*: bool
    schedule*: Schedule

  LaunchProblem* = object
    field*: string         ## the field it is about
    text*: string

  IterationMode* = enum
    imOnce = "1"
    imAuto = "auto"
    imCount = "N"

  NewInitiativeForm* = object
    goal*: string
    iteration*: IterationMode
    iterations*: int
    planPath*: string      ## blank: `planFilePreview` names it
    relatedSpecs*: seq[string]

  GazeState* = enum
    gsOff = "off"
    gsTracking = "tracking"
    gsPaused = "paused"

  ComposerDraft* = object
    text*: string
    context*: seq[ContextItem]
    targets*: seq[RouteTarget]
    phase*: ComposerPhase
    route*: RouteStatus
    decided*: bool               ## the router answered with a decision
    decision*: RoutingDecision
    chosen*: TargetKind          ## where `Enter` sends
    operatorChose*: bool         ## `chosen` is the operator's, not the router's
    awaitingRoute*: bool         ## `Enter` was pressed before the decision
    routeError*: string
    deliveries*: seq[Delivery]
    sentText*: string            ## the text the deliveries carry
    sentIntent*: RouteIntent
    recent*: seq[ComposerRecord] ## newest first
    launch*: LaunchOptions
    initiative*: NewInitiativeForm

const
  RecentLimit* = 5
  TargetOrder* = [tkSession, tkManager, tkUiAction]
  Dot = " \xC2\xB7 "

# ---------------------------------------------------------------------------
# Words
# ---------------------------------------------------------------------------

func titleOf*(kind: TargetKind): string =
  ## The row's title, the same in every front-end.
  case kind
  of tkSession: "This session"
  of tkManager: "Manager agent"
  of tkUiAction: "UI action"

func destinationPhrase*(kind: TargetKind): string =
  ## The destination in a sentence: `Sent to this session`, `Send to the
  ## manager agent`, `redirected to the UI-action agent`.
  case kind
  of tkSession: "this session"
  of tkManager: "the manager agent"
  of tkUiAction: "the UI-action agent"

func sendLabel*(intent: RouteIntent): string =
  case intent
  of riInstruct: "Send"
  of riLaunchTask: "Launch"
  of riNewInitiative: "Start initiative"

func firstLineAndMore*(text: string): tuple[first: string, more: int] =
  ## A one-line field's text: the first line, and how many lines follow.
  let lines = text.split('\n')
  (lines[0], lines.len - 1)

func moreLinesLabel*(more: int): string =
  if more <= 0: "" elif more == 1: "+1 line" else: "+" & $more & " lines"

func dwellLabel*(ms: int): string =
  ## `1.4 s`: a gaze dwell, one decimal.
  let tenths = (ms + 50) div 100
  $(tenths div 10) & "." & $(tenths mod 10) & " s"

func gazeChip*(id, objectLabel, reference: string; dwellMs: int): ContextItem =
  ## What the gaze rested on longest while the instruction was typed.
  ContextItem(id: id, kind: ckGaze, label: "Looked at " & objectLabel & Dot &
              dwellLabel(dwellMs), detail: "What you looked at while typing, " &
              "resolved by CodeTracer's gaze tracking", reference: reference)

func gazePausedChip*(): ContextItem =
  ContextItem(id: "gaze-paused", kind: ckGaze, label: "Gaze paused",
              detail: "Gaze tracking is paused; nothing you look at is attached",
              note: true)

func gazeMark*(state: GazeState): tuple[shown: bool, text: string] =
  ## The status line's mark: shown while tracking or paused, never when off.
  case state
  of gsOff: (false, "")
  of gsTracking: (true, "Gaze")
  of gsPaused: (true, "Gaze paused")

# ---------------------------------------------------------------------------
# The draft
# ---------------------------------------------------------------------------

func targetOf*(d: ComposerDraft; kind: TargetKind): RouteTarget =
  for t in d.targets:
    if t.kind == kind: return t
  RouteTarget(kind: kind, available: false,
              unavailableReason: "Not offered in this window")

func isAvailable*(d: ComposerDraft; kind: TargetKind): bool =
  d.targetOf(kind).available

func firstAvailable(d: ComposerDraft): TargetKind =
  result = tkSession
  for kind in TargetOrder:
    if d.isAvailable(kind): return kind

func initDraft*(targets: openArray[RouteTarget];
                context: openArray[ContextItem] = []): ComposerDraft =
  ## A draft over the destinations and context the window offers. The
  ## first available destination is shown until a decision.
  result.targets = @targets
  result.context = @context
  result.phase = cpComposing
  result.chosen = result.firstAvailable

func isBeforeSend*(d: ComposerDraft): bool =
  d.phase == cpComposing or (d.phase == cpSending and d.awaitingRoute)

func intentOf*(d: ComposerDraft): RouteIntent =
  ## The intent of what is being composed or was sent: a launch or a new
  ## initiative goes to a manager only; sent elsewhere it is an instruction.
  if d.phase != cpComposing and not d.awaitingRoute: d.sentIntent
  elif d.decided and d.chosen == tkManager: d.decision.intent
  else: riInstruct

proc dropDecision(d: var ComposerDraft) =
  d.decided = false
  d.decision = RoutingDecision()
  d.routeError = ""
  d.route = rsNone

proc resetChoices(d: var ComposerDraft) =
  ## A new instruction: the operator's destination and citations go.
  d.operatorChose = false
  d.chosen = d.firstAvailable
  for c in d.context.mitems:
    c.excluded = false
    c.pinned = false

proc setText*(d: var ComposerDraft; text: string) =
  ## Typing. The decision made for the old text is dropped (the caller asks
  ## the router again); the operator's own choices stand. After sending,
  ## typing starts the next instruction. Ignored while a delivery runs.
  if d.phase == cpSending: return
  if d.phase in {cpSent, cpSendFailed}:
    d.deliveries = @[]
    d.sentText = ""
    d.dropDecision()
    d.resetChoices()
    d.phase = cpComposing
  elif text == d.text:
    return
  d.text = text
  d.dropDecision()
  if text.strip.len == 0: d.resetChoices()
  elif not d.operatorChose: d.chosen = d.firstAvailable

func cited*(d: ComposerDraft): seq[ContextItem] =
  ## What the instruction carries: the decision's citations and the
  ## operator's, less what the operator uncited; never a note.
  for c in d.context:
    if c.note or c.excluded: continue
    if c.pinned or (d.decided and c.id in d.decision.cited):
      result.add c

func isCited*(d: ComposerDraft; id: string): bool =
  for c in d.cited:
    if c.id == id: return true
  false

proc toggleContext*(d: var ComposerDraft; id: string): bool =
  ## Cites a chip that is not cited, uncites one that is, before sending.
  ## The choice stands when the router answers again. A note cannot be
  ## cited.
  if not d.isBeforeSend: return false
  let wasCited = d.isCited(id)
  for c in d.context.mitems:
    if c.id == id and not c.note:
      c.excluded = wasCited
      c.pinned = not wasCited
      return true
  false

proc addContext*(d: var ComposerDraft; item: ContextItem): bool =
  ## An item the operator attaches (the "add context" items): cited, since
  ## the operator chose it. Replaces an item with the same id.
  if not d.isBeforeSend or item.id.len == 0: return false
  var attached = item
  if not attached.note: attached.pinned = true
  for c in d.context.mitems:
    if c.id == item.id:
      c = attached
      return true
  d.context.add attached
  true

func citable*(d: ComposerDraft; id: string): bool =
  for c in d.context:
    if c.id == id: return not c.note
  false

proc beginRouting*(d: var ComposerDraft): bool =
  ## The instruction goes to the routing agent (as the operator types).
  ## False for an empty instruction, or once it is sent.
  if d.text.strip.len == 0: return false
  if d.phase != cpComposing: return false
  d.dropDecision()
  d.route = rsRouting
  true

proc applyDecision*(d: var ComposerDraft; decision: RoutingDecision): bool =
  ## The router's answer, shown at once. Its citations are kept only for
  ## items the window offered (never a note). The destination becomes the
  ## router's unless the operator chose one. A decision for a destination
  ## the window cannot reach is a routing failure. When `Enter` was waiting
  ## for it, the delivery starts (the caller sends to `chosen`).
  if d.route != rsRouting: return false
  if not d.isAvailable(decision.target):
    d.route = rsFailed
    d.routeError = "The router chose " & titleOf(decision.target).toLowerAscii &
                   ", which this window cannot reach: " &
                   d.targetOf(decision.target).unavailableReason
    if d.awaitingRoute:
      d.awaitingRoute = false
      d.phase = cpComposing
    return true
  var accepted = decision
  accepted.cited = @[]
  for id in decision.cited:
    if d.citable(id) and id notin accepted.cited: accepted.cited.add id
  d.decision = accepted
  d.decided = true
  d.route = rsDecided
  if not d.operatorChose: d.chosen = decision.target
  true

proc applyRouteFailure*(d: var ComposerDraft; reason: string): bool =
  ## The router could not decide: the destination shown stays (the first
  ## available one, or the operator's), and `Enter` was waiting is released
  ## so the operator sees why before anything is sent.
  if d.route != rsRouting: return false
  d.route = rsFailed
  d.routeError = reason
  if d.awaitingRoute:
    d.awaitingRoute = false
    d.phase = cpComposing
  true

func chosenByOperator*(d: ComposerDraft): bool =
  ## The operator chose a destination the router did not.
  d.operatorChose and (not d.decided or d.chosen != d.decision.target)

proc choose*(d: var ComposerDraft; kind: TargetKind): bool =
  ## Redirect before sending: `kind` becomes the destination, and stays it
  ## when the router answers again. The router's decision is kept, so its
  ## row still says so.
  if d.phase != cpComposing or not d.isAvailable(kind): return false
  d.chosen = kind
  d.operatorChose = true
  true

proc validateLaunch*(o: LaunchOptions): seq[LaunchProblem]
proc validateInitiative*(f: NewInitiativeForm): seq[LaunchProblem]

proc sendProblems*(d: ComposerDraft): seq[LaunchProblem] =
  ## Why `Enter` cannot send now: the launch or initiative form's problems.
  case d.intentOf
  of riLaunchTask: validateLaunch(d.launch)
  of riNewInitiative: validateInitiative(d.initiative)
  of riInstruct: @[]

proc startDelivery(d: var ComposerDraft) =
  d.sentText = d.text
  d.sentIntent = d.intentOf
  d.deliveries = @[Delivery(target: d.chosen, state: dsSending)]
  d.awaitingRoute = false
  d.phase = cpSending

proc beginSend*(d: var ComposerDraft): bool =
  ## `Enter`: the instruction is sent at once to the destination shown. If
  ## the router is still deciding and the operator chose nothing, it is sent
  ## as soon as the decision arrives (`awaitingRoute`; `deliveryReady` then
  ## says so). Refused for an empty instruction, an unreachable destination,
  ## or a form with problems.
  if d.phase != cpComposing or d.text.strip.len == 0: return false
  if d.route == rsRouting and not d.operatorChose:
    d.awaitingRoute = true
    d.phase = cpSending
    return true
  if not d.isAvailable(d.chosen): return false
  if d.sendProblems.len > 0: return false
  d.startDelivery()
  true

proc deliveryReady*(d: var ComposerDraft): bool =
  ## After a decision arrived for an `Enter` that waited for it: starts the
  ## delivery, true when the caller should now send to `chosen`. A form with
  ## problems stops it, so the operator sees the form.
  if not (d.phase == cpSending and d.awaitingRoute and d.route == rsDecided):
    return false
  if d.sendProblems.len > 0:
    d.awaitingRoute = false
    d.phase = cpComposing
    return false
  d.startDelivery()
  true

proc record(d: var ComposerDraft) =
  ## The sent instruction in `Recent`: added on its first completed
  ## delivery, updated by the next ones.
  var rec = ComposerRecord(text: d.sentText, intent: d.sentIntent,
                           deliveries: d.deliveries)
  for del in d.deliveries:
    rec.labels.add d.targetOf(del.target).label
  if d.recent.len > 0 and d.recent[0].text == rec.text and
      d.recent[0].deliveries.len > 0 and
      d.recent[0].deliveries.len <= rec.deliveries.len and
      d.recent[0].deliveries[0].target == rec.deliveries[0].target:
    d.recent[0] = rec
  else:
    d.recent.insert(rec, 0)
    if d.recent.len > RecentLimit: d.recent.setLen RecentLimit

proc settle(d: var ComposerDraft) =
  ## The phase once no delivery is still sending.
  for del in d.deliveries:
    if del.state == dsSending: return
  var anySent = false
  for del in d.deliveries:
    if del.state == dsSent: anySent = true
  # Failed while any delivery has failed and not been retried, so `retry`
  # can reach it whichever delivery failed.
  var anyFailed = false
  for del in d.deliveries:
    if del.state == dsFailed: anyFailed = true
  d.phase = if anyFailed: cpSendFailed else: cpSent
  if anySent:
    d.text = ""
    d.record()

proc applyReceipt*(d: var ComposerDraft; target: TargetKind;
                   receipt: Receipt): bool =
  ## The deliverer delivered to `target`.
  for del in d.deliveries.mitems:
    if del.target == target and del.state == dsSending:
      del.state = dsSent
      del.receipt = receipt
      d.settle()
      return true
  false

proc applyDeliveryFailure*(d: var ComposerDraft; target: TargetKind;
                           reason: string): bool =
  for del in d.deliveries.mitems:
    if del.target == target and del.state == dsSending:
      del.state = dsFailed
      del.error = reason
      d.settle()
      return true
  false

proc retry*(d: var ComposerDraft): tuple[ok: bool, target: TargetKind] =
  ## Sends a failed delivery again: the first one that failed, whose target
  ## is answered so the caller delivers to exactly that destination. One
  ## retry per call; with two failed deliveries, the second waits for the
  ## next call.
  if d.phase != cpSendFailed: return (false, tkSession)
  for del in d.deliveries.mitems:
    if del.state == dsFailed:
      del.state = dsSending
      del.error = ""
      d.phase = cpSending
      return (true, del.target)
  (false, tkSession)

proc sendAgain*(d: var ComposerDraft; kind: TargetKind): bool =
  ## Redirect after sending: the same instruction is sent to `kind` too.
  ## The earlier deliveries stay; a destination already delivered to is not
  ## sent to twice.
  if d.phase notin {cpSent, cpSendFailed}: return false
  if not d.isAvailable(kind): return false
  for del in d.deliveries:
    if del.target == kind: return false
  d.deliveries.add Delivery(target: kind, state: dsSending)
  d.phase = cpSending
  true

proc recall*(d: var ComposerDraft; index: int): bool =
  ## A `Recent` instruction back in the field, to edit and send again.
  if index < 0 or index >= d.recent.len: return false
  if d.phase == cpSending: return false
  let text = d.recent[index].text
  d.setText("")
  d.setText(text)
  true

func destinationRows*(d: ComposerDraft): seq[DestinationRow] =
  ## The destinations in their fixed order, each with its state.
  let before = d.isBeforeSend
  for kind in TargetOrder:
    let t = d.targetOf(kind)
    var row = DestinationRow(target: kind, title: titleOf(kind), label: t.label)
    if not t.available:
      row.reason = t.unavailableReason
    elif d.decided and d.decision.target == kind:
      row.reason = d.decision.reason
      if kind == tkUiAction and d.decision.action.len > 0:
        row.label = d.decision.action
    for del in d.deliveries:
      if del.target == kind:
        row.delivered = true
        row.delivery = del.state
        row.error = del.error
        row.receipt = del.receipt
    if before:
      let typed = d.text.strip.len > 0
      # Selected once there is a destination to send to: the router has
      # answered (or failed, leaving the first available one), or the
      # operator chose. While the router decides, no row is selected.
      let settled = d.route in {rsDecided, rsFailed} or d.operatorChose
      row.selected = typed and settled and d.chosen == kind and t.available
      row.enabled = typed and t.available and d.phase == cpComposing
      if typed and d.decided and d.decision.target == kind:
        row.mark = if d.chosen == kind: rmRouted else: rmRouterChoice
      elif typed and d.chosen == kind and d.chosenByOperator:
        row.mark = rmChosen
    else:
      row.selected = row.delivered
      row.canSendAgain = d.phase in {cpSent, cpSendFailed} and
                         not row.delivered and t.available
      row.enabled = row.canSendAgain
    row.canStop = kind == tkSession and t.available and t.running
    result.add row

func headerLine*(d: ComposerDraft): string =
  ## The sheet's first line: where the instruction is in its flow.
  let others = "\xE2\x86\x91\xE2\x86\x93 another destination"
  case d.phase
  of cpComposing:
    if d.text.strip.len == 0:
      "Type an instruction. Enter sends it where it shows; " & others & "."
    else:
      case d.route
      of rsRouting: "Routing\xE2\x80\xA6" & Dot & "Enter sends it when routed"
      of rsFailed: "Could not route: " & d.routeError
      of rsDecided, rsNone:
        if d.chosenByOperator: "Enter sends it where you chose"
        else: "Enter sends it" & Dot & others
  of cpSending:
    if d.awaitingRoute: "Routing\xE2\x80\xA6" & Dot & "sends when routed"
    else: "Sending\xE2\x80\xA6"
  of cpSent: "Sent"
  of cpSendFailed: "Failed to send"

func citesLine*(d: ComposerDraft): string =
  ## What the instruction cites, said once: "" with nothing typed.
  if d.phase == cpComposing and d.text.strip.len == 0: return ""
  if d.phase == cpComposing and d.route in {rsNone, rsRouting} and
      d.cited.len == 0: return ""
  let cited = d.cited
  if cited.len == 0: return "Cites nothing from this window"
  var labels: seq[string]
  for c in cited: labels.add c.label
  "Cites " & labels.join(", ")

func deliveryLine*(d: ComposerDraft; rec: ComposerRecord): string =
  ## `Sent to this session · redirected to the manager agent`, the words a
  ## record and a sent sheet use.
  var parts: seq[string]
  for i, del in rec.deliveries:
    let who = destinationPhrase(del.target)
    let verb = case del.state
               of dsSent: (if i == 0: "Sent to " else: "redirected to ")
               of dsFailed: (if i == 0: "Failed to send to " else: "failed to redirect to ")
               of dsSending: (if i == 0: "Sending to " else: "redirecting to ")
    parts.add verb & who
  parts.join(Dot)

func outcomeLine*(r: Receipt): string =
  ## A UI action's result, or a launch's notice, in words.
  case r.outcome
  of uoNone: r.notice
  of uoDone: r.result
  of uoRefused: "Refused: " & r.result
  of uoPartial: r.result

# ---------------------------------------------------------------------------
# Launch options
# ---------------------------------------------------------------------------

type CronField = tuple[name: string, lo, hi: int, names: seq[string]]

const
  MonthNames = @["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG",
                 "SEP", "OCT", "NOV", "DEC"]
  DayNames = @["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

func cronFields(): array[5, CronField] =
  [("minute", 0, 59, @[]), ("hour", 0, 23, @[]), ("day of the month", 1, 31, @[]),
   ("month", 1, 12, MonthNames), ("day of the week", 0, 7, DayNames)]

func smallNumber(digits: string): int =
  ## The value of a run of decimal digits, or -1 when it has more than four
  ## significant digits: larger than any cron field allows, and never handed
  ## to `parseInt`, which raises past `int`'s range ("99999999999999999999").
  var i = 0
  while i < digits.len - 1 and digits[i] == '0': inc i
  if digits.len - i > 4: return -1
  parseInt(digits[i .. ^1])

func cronValue(f: CronField; s: string): tuple[ok: bool, value: int, problem: string] =
  if s.len == 0:
    return (false, 0, "The " & f.name & " field has an empty value")
  var digits = true
  for ch in s:
    if ch notin {'0' .. '9'}: digits = false
  if digits:
    let v = smallNumber(s)
    if v < f.lo or v > f.hi:
      return (false, 0, "The " & f.name & " field allows " & $f.lo & "-" & $f.hi &
                        "; " & s & " is out of range")
    return (true, v, "")
  let up = s.toUpperAscii
  for i, n in f.names:
    if n == up:
      return (true, i + (if f.name == "month": 1 else: 0), "")
  (false, 0, "The " & f.name & " field: " & s & " is not a number" &
             (if f.names.len > 0: " or a name" else: ""))

func validateCron*(expr: string): string =
  ## "" for a valid five-field cron expression (minute, hour, day of the
  ## month, month, day of the week: numbers, `*`, ranges `a-b`, lists
  ## `a,b`, steps `/n`, month and day names), else the first problem.
  let fields = expr.strip.splitWhitespace
  if fields.len != 5:
    return "A cron expression has five fields (minute hour day month " &
           "weekday); this one has " & $fields.len
  let spec = cronFields()
  for i, field in fields:
    let f = spec[i]
    for item in field.split(','):
      var body = item
      let slash = item.find('/')
      if slash >= 0:
        let step = item[slash + 1 .. ^1]
        body = item[0 ..< slash]
        var ok = step.len > 0
        for ch in step:
          if ch notin {'0' .. '9'}: ok = false
        if not ok or smallNumber(step) == 0:
          return "The " & f.name & " field: the step in " & item &
                 " is not a positive number"
        let n = smallNumber(step)
        if n < 0 or n > f.hi:
          return "The " & f.name & " field: the step in " & item &
                 " is out of range (1-" & $f.hi & ")"
      if body == "*": continue
      let dash = body.find('-')
      if dash > 0:
        let a = f.cronValue(body[0 ..< dash])
        if not a.ok: return a.problem
        let b = f.cronValue(body[dash + 1 .. ^1])
        if not b.ok: return b.problem
        if a.value > b.value:
          return "The " & f.name & " field: the range " & body & " runs backwards"
      else:
        let v = f.cronValue(body)
        if not v.ok: return v.problem
  ""

func validTimezone(tz: string): bool =
  if tz == "UTC": return true
  let slash = tz.find('/')
  if slash <= 0 or slash == tz.len - 1: return false
  for ch in tz:
    if ch notin {'A' .. 'Z', 'a' .. 'z', '_', '/', '-', '+', '0' .. '9'}:
      return false
  true

proc validateLaunch*(o: LaunchOptions): seq[LaunchProblem] =
  ## Every problem of a launch form, in the form's order.
  if o.repository.strip.len == 0:
    result.add LaunchProblem(field: "repository", text: "Choose a repository")
  if o.agents.len == 0:
    result.add LaunchProblem(field: "agents", text: "Choose at least one agent")
  if o.runOn == roExecutor and o.executor.strip.len == 0:
    result.add LaunchProblem(field: "executor", text: "Choose an executor")
  if o.schedule.enabled:
    let cron = validateCron(o.schedule.cron)
    if cron.len > 0:
      result.add LaunchProblem(field: "cron", text: cron)
    if not validTimezone(o.schedule.timezone):
      result.add LaunchProblem(field: "timezone",
        text: "Use a time zone name such as Europe/Sofia or UTC")
    if o.schedule.jitterSeconds < 0 or o.schedule.jitterSeconds > 3600:
      result.add LaunchProblem(field: "jitter",
        text: "Jitter is between 0 and 3600 seconds")

func slugOf*(goal: string): string =
  ## The plan file's name from the goal's first words: lower case,
  ## letters and digits, words joined by `-`, at most six words.
  var words: seq[string]
  var cur = ""
  for ch in goal.toLowerAscii:
    if ch in {'a' .. 'z', '0' .. '9'}:
      cur.add ch
    elif cur.len > 0:
      words.add cur
      cur = ""
  if cur.len > 0: words.add cur
  if words.len > 6: words.setLen 6
  words.join("-")

func planFilePreview*(f: NewInitiativeForm; date: string): string =
  ## The plan file the initiative writes: its own path, or
  ## `milestones/<date>-<slug>.milestones.org`.
  if f.planPath.strip.len > 0: return f.planPath.strip
  let slug = slugOf(f.goal)
  "milestones/" & date & "-" & (if slug.len > 0: slug else: "initiative") &
    ".milestones.org"

proc validateInitiative*(f: NewInitiativeForm): seq[LaunchProblem] =
  if f.goal.strip.len == 0:
    result.add LaunchProblem(field: "goal", text: "Say what the initiative is for")
  if f.iteration == imCount and f.iterations < 1:
    result.add LaunchProblem(field: "iterations",
      text: "The number of iterations is at least 1")
  let p = f.planPath.strip
  if p.len > 0:
    if p.startsWith("/") or p.startsWith("~") or "\\" in p or
        p.split('/').contains(".."):
      result.add LaunchProblem(field: "plan",
        text: "The plan file is a path inside the workspace")
    elif not p.endsWith(".milestones.org"):
      result.add LaunchProblem(field: "plan",
        text: "A plan file ends in .milestones.org")

const ContextHeading* = "Context from the operator's window:"
  ## The first line of the header an instruction carries when it cites
  ## something (the Agent Activity prompt's `Context paths:` header's twin).

func deliveredText*(text: string; cited: openArray[ContextItem]): string =
  ## What a destination receives: the instruction after a header naming
  ## each cited item by its reference and label, or the instruction alone
  ## when nothing is cited --
  ##
  ##     Context from the operator's window:
  ##     - src/shield.nr:7 (src/shield.nr:7)
  ##     - replay:noir#iterate_asteroids/2 (Pass 2 of iterate_asteroids)
  ##
  ##     <text>
  if cited.len == 0: return text
  result = ContextHeading & "\n"
  for c in cited:
    let ref0 = if c.reference.len > 0: c.reference else: c.label
    result.add "- " & ref0 & (if c.label.len > 0 and c.label != ref0: " (" & c.label & ")" else: "") & "\n"
  result.add "\n"
  result.add text

func launchParams*(o: LaunchOptions): seq[(string, string)] =
  ## A launch's options, named, in the form's order; blank ones left out
  ## (a blank session name lets the server name it).
  template put(name, value: string) =
    if value.len > 0: result.add (name, value)
  put("repository", o.repository)
  put("branch", o.branch)
  put("agents", o.agents.join(","))
  put("run-on", $o.runOn)
  if o.runOn == roExecutor: put("executor", o.executor)
  put("session-name", o.sessionName)
  put("open-in", $o.openIn & (if o.focus: ", focused" else: ""))
  if o.schedule.enabled:
    put("cron", o.schedule.cron)
    put("timezone", o.schedule.timezone)
    put("jitter-seconds", $o.schedule.jitterSeconds)
    put("concurrency", $o.schedule.concurrency)
    put("misfire", $o.schedule.misfire)

func initiativeParams*(f: NewInitiativeForm; date: string): seq[(string, string)] =
  ## A new initiative's options, named: its iteration mode and its plan file
  ## as the preview names it, and its related specs.
  result.add ("iterations", if f.iteration == imCount: $f.iterations else: $f.iteration)
  result.add ("plan", planFilePreview(f, date))
  if f.relatedSpecs.len > 0: result.add ("related-specs", f.relatedSpecs.join(","))
