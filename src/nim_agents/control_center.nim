## The control center's rules: the tab a front-end opens to launch tasks and
## initiatives and to follow every initiative at once (CodeTracer
## Agent-Harbor-Front-End "The control center"). Plain Nim, C and JS, no
## signals; a viewmodel publishes it.
##
## The control center adds no flow of its own. It lays out what other parts
## already decide:
##
## - **Launching** is the instruction composer's (`instruction_composer`):
##   the same draft, the same launch and initiative forms and their
##   validation, the same delivery to Agent Harbor. What the control center
##   adds is that the operator, not the routing agent, says what is being
##   started (`LaunchMode`: a task or an initiative); the composer's
##   `chooseIntent` records that choice.
## - **Recent launches** are the composer's `Recent` records that launched
##   something (`recentLaunches`), newest first, each with the notice Agent
##   Harbor answered (where the session started) or why it failed.
## - **Waiting** sessions are the ones that wait for the operator, in inbox
##   order (`session_directory.inboxOrder`): the order `Next` walks.
## - **Layout** (`layoutFor`): two columns, launching on the left and the
##   overview on the right; one column below a narrow width, launching first.
##
## The words are here so that every front-end says the same thing.

import std/strutils
import ./instruction_composer

export instruction_composer

type
  LaunchMode* = enum
    ## What the operator is starting from the control center.
    lmTask = "task"             ## a task: one session
    lmInitiative = "initiative" ## an initiative: a plan run by a manager

  ControlCenterLayout* = enum
    clTwoColumns = "two"  ## launching on the left, the overview on the right
    clOneColumn = "one"   ## one column, launching first

  RecentLaunch* = object
    ## One launch as the control center lists it.
    text*: string     ## the instruction's first line
    mode*: LaunchMode
    target*: string   ## where it went: the manager's label, "" when unknown
    line*: string     ## the notice, `Launching…`, or why it failed
    failed*: bool
    pending*: bool    ## still waiting for Agent Harbor's answer

const
  ControlCenterTitle* = "Control Center"
  NewTaskLabel* = "New task"
  NewInitiativeLabel* = "New initiative"
  LaunchHeading* = "Launch"
  RecentLaunchesHeading* = "Recent launches"
  NoRecentLaunchesWords* = "Nothing launched from here yet."
  WaitingHeading* = "Waiting for you"
  NothingWaitingWords* = "No session waits for you."
  NoInitiativesWords* = "No initiatives yet."
    ## P2a's wording rule for an empty list: what is absent, in a sentence.
  LaunchingWords* = "Launching\xE2\x80\xA6"
  Dot = " \xC2\xB7 "

func intentOf*(mode: LaunchMode): RouteIntent =
  case mode
  of lmTask: riLaunchTask
  of lmInitiative: riNewInitiative

func modeOf*(intent: RouteIntent): LaunchMode =
  ## The mode of a launch record (`riInstruct` is not a launch; it reads as
  ## a task so a caller never has to handle a third case).
  if intent == riNewInitiative: lmInitiative else: lmTask

func modeLabel*(mode: LaunchMode): string =
  case mode
  of lmTask: NewTaskLabel
  of lmInitiative: NewInitiativeLabel

func layoutFor*(width, narrowBelow: int): ControlCenterLayout =
  ## One column below `narrowBelow` (the renderer's unit: pixels or cells),
  ## launching first; two columns otherwise.
  if width < narrowBelow: clOneColumn else: clTwoColumns

func isLaunch*(record: ComposerRecord): bool =
  record.intent in {riLaunchTask, riNewInitiative}

func launchLine*(record: ComposerRecord): tuple[line: string, failed, pending: bool] =
  ## What became of a launch: Agent Harbor's notice (`Started on hub-a ·
  ## executor linux-x64-4 · session 5c1a3e70`), `Launching…` while it has
  ## not answered, or `Could not launch: <why>`. A launch is delivered once,
  ## to a manager, so its first delivery says it all.
  if record.deliveries.len == 0: return (LaunchingWords, false, true)
  let d = record.deliveries[0]
  case d.state
  of dsSending: (LaunchingWords, false, true)
  of dsFailed:
    let verb = if record.intent == riNewInitiative: "Could not start: " else: "Could not launch: "
    (verb & (if d.error.len > 0: d.error else: "no answer"), true, false)
  of dsSent:
    if d.receipt.notice.len > 0: (d.receipt.notice, false, false)
    elif record.intent == riNewInitiative: ("Started", false, false)
    else: ("Launched", false, false)

func recentLaunches*(records: openArray[ComposerRecord];
                     limit = RecentLimit): seq[RecentLaunch] =
  ## The records that launched a task or started an initiative, in the
  ## order given (the composer keeps them newest first), at most `limit`.
  ## Instructions to a session or a manager are not launches and are left
  ## out.
  for record in records:
    if result.len >= limit: break
    if not record.isLaunch: continue
    let (line, failed, pending) = record.launchLine
    result.add RecentLaunch(text: firstLineAndMore(record.text).first,
                            mode: modeOf(record.intent),
                            target: (if record.labels.len > 0: record.labels[0] else: ""),
                            line: line, failed: failed, pending: pending)

func recentLine*(launch: RecentLaunch): string =
  ## `Manager of Shield model hardening · Started on hub-a · …`: where it
  ## went, then what became of it.
  if launch.target.len > 0: launch.target & Dot & launch.line else: launch.line

func waitingCountText*(count: int): string =
  ## The waiting list's count, where a panel's head has its summary: `3
  ## sessions`, `1 session`; "" when nothing waits.
  if count <= 0: "" elif count == 1: "1 session" else: $count & " sessions"

func managerLabel*(initiativeTitle: string): string =
  ## The destination a launch for an initiative goes to.
  "Manager of " & initiativeTitle

func noInitiativeLabel*(): string =
  ## The launch form's choice for work outside every initiative.
  "No initiative"

func launchForLabel*(initiativeTitle: string): string =
  ## The send button's tooltip: where the launch goes.
  if initiativeTitle.strip.len == 0: "Launch outside every initiative"
  else: "Launch for " & initiativeTitle
