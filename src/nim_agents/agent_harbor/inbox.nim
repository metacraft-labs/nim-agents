## The operator's inbox -- every item that waits for the operator, in the
## order the server serves it -- as signal-free records and reducers
## (INV-D-13 … INV-D-16, INV-P3-10 … INV-P3-19).
##
## **The server orders the inbox; a front-end never does.** `GET
## /api/v1/inbox` serves the items already ordered, each with its priority,
## its boost, its one-line explanation of why it is where it is, and its
## cache warmth. `inboxFromJson` keeps the items in the order served,
## `applyInboxEvent` keeps the order each event carries, and nothing here
## sorts them (INV-P3-11, INV-D-14). A front-end computes exactly one text of
## its own: the warmth countdown (`warmthChip`), which moves every second
## between two reads.
##
## **Items.** Five kinds are served: a blocked question, an ended turn (the
## agent finished its turn and waits for the next instruction: the idle
## prompt), a permission gate, a login request and an async feedback request
## (the agent keeps working). A kind this front-end does not know yet is kept
## as `ikUnknown` with its wire name, in its place, never dropped. An item is
## named by the pair (`server`, `id`): a fleet's merged inbox tags each item
## with the server it comes from, and ids are unique only on their server.
##
## **The cursor.** Previous and Next walk a cursor the server keeps per user
## (proposed `POST /api/v1/inbox/cursors/{name}/next` and `…/prev`): Next
## goes to the top of the current order, excluding the item on screen, so an
## item already visited is offered again when it is on top; Previous walks
## back through the items visited, not through the order. `InboxCursor` with
## `cursorNext` and `cursorPrev` is that rule, for a data source that stands
## in for such a server; a view never keeps its own order or stack.
##
## **Item pages.** `InboxItemDetail` is what one item's page shows: the
## question and its options, an agent's permission options, sudo and network
## approvals, a login request, a feedback request, a draft answer prepared by
## a manager, the agent's last reply after an ended turn. These are proposed
## shapes, read leniently (`inboxItemDetailFromJson`), until a read serves
## them; `validateAnswer` holds the answer form's rules.
##
## Signal-free and app-agnostic; identical on the C and JS targets.

import std/[json, strutils]
import ./[activity_words, fleet_records, operator_actions]
export ApprovalScope

type
  InboxKind* = enum
    ikBlockedQuestion = "blocked_question"
    ikEndedTurn = "ended_turn"
    ikPermissionGate = "permission_gate"
    ikLoginRequest = "login_request"
    ikAsyncFeedback = "async_feedback"
    ikUnknown = "unknown"   ## a kind this front-end does not know (`kindText`)

  InboxPriority* = enum
    ipUrgent = "urgent"
    ipHigh = "high"
    ipNormal = "normal"
    ipLow = "low"

  WarmthState* = enum
    wsUnknown = "unknown"
    wsWarm = "warm"
    wsExpiring = "expiring"
    wsCold = "cold"
    wsNeutral = "neutral"

  WarmthConfidence* = enum
    wcNone = ""
    wcExact = "exact"
    wcEstimated = "estimated"
    wcLearned = "learned"

  CacheWarmth* = object
    state*: WarmthState
    deadlineMs*: int64       ## 0 when the surface has no deadline
    confidence*: WarmthConfidence

  InboxBoost* = object
    active*: bool            ## false: the item is not boosted
    reason*: string          ## the reason the deadline belongs to
    reasons*: seq[string]    ## every reason that applies (`cache_warm`, `recent`)
    deadlineMs*: int64       ## when the boost ends; 0 for none

  InboxHolder* = enum
    ## Who has an item whose agent died (a proposed field, `heldBy`).
    ihNone = ""
    ihManager = "manager"    ## a manager examines it first
    ihOperator = "operator"  ## it needs the operator

  InboxSession* = object
    id*, title*, host*, agent*, status*: string
    label*: string           ## how every client names the session, as served
    handle*: string          ## the session's handle (`<qualifier>:<name>`), if any

  InboxItemRef* = object
    ## An item's identity: the server it comes from ("" for the local one)
    ## and its id there.
    server*, id*: string

  InboxItem* = object
    id*: string
    server*: string          ## a fleet item's server name; "" for a local item
    kind*: InboxKind
    kindText*: string        ## the wire `kind`, kept for an unknown kind
    session*: InboxSession
    priority*: InboxPriority
    effectivePriority*: InboxPriority
    boost*: InboxBoost
    position*: int           ## 1-based, as served
    explanation*: string     ## the server's one line, shown as served
    enteredAtMs*: int64
    warmth*: CacheWarmth
    question*: string        ## a blocked question's text, when served
    heldBy*: InboxHolder

  DegradedServer* = object
    server*, reason*: string

  InboxSnapshot* = object
    items*: seq[InboxItem]
    generatedAtMs*: int64
    nextChangeAtMs*: int64
    degraded*: seq[DegradedServer]

  InboxEventKind* = enum
    ieAdded = "item.added"
    ieUpdated = "item.updated"
    ieResolved = "item.resolved"
    ieReordered = "order"

  InboxEvent* = object
    ## One change of the inbox, as the proposed inbox stream would send it.
    ## `order`, when `hasOrder`, is the whole order after the event; the
    ## reducer takes it as it is.
    kind*: InboxEventKind
    item*: InboxItem         ## ieAdded, ieUpdated
    target*: InboxItemRef    ## ieResolved
    hasOrder*: bool
    order*: seq[InboxItemRef]

  InboxCursor* = object
    current*: InboxItemRef   ## the item on screen; empty `id` for none
    visited*: seq[InboxItemRef]  ## the items visited before it, oldest first

  QuestionForm* = enum
    qfFreeForm = "free_form"
    qfSingle = "single_choice"
    qfMulti = "multi_choice"
    qfConfirmation = "confirmation"

  AnswerOption* = object
    id*, label*, description*: string

  PermissionOption* = object
    id*, label*: string
    kind*: string            ## `allow_once`, `allow_always`, `reject_once`, `reject_always`

  ApprovalRequest* = object
    requestId*: string
    scope*: ApprovalScope
    command*: string         ## asSudo
    domain*: string          ## asNetwork
    reason*: string

  LoginMode* = enum
    lmLocalDesktop = "local_desktop"  ## a sign-in window opens on this desktop
    lmRemoteView = "remote_view"      ## the sign-in surface is embedded

  LoginState* = enum
    lsPending = "pending"
    lsCancelling = "cancelling"
    lsCompleted = "completed"
    lsFailed = "failed"

  LoginRequest* = object
    requestId*: string
    provider*, prompt*: string
    mode*: LoginMode
    state*: LoginState
    error*: string

  FeedbackType* = enum
    ftQuestion = "question"
    ftOptions = "options"
    ftConfirmation = "confirmation"
    ftInformation = "information"

  Attachment* = object
    name*, kind*, url*: string

  FeedbackRequest* = object
    id*: string
    taskId*: string
    feedbackType*: FeedbackType
    prompt*, context*: string
    options*: seq[AnswerOption]
    minLength*, maxLength*: int  ## 0: no limit
    expiresAtMs*: int64          ## 0: never
    attachments*: seq[Attachment]

  Draft* = object
    present*: bool
    text*: string
    choices*: seq[string]
    rationale*: string
    confidence*: string
    drafter*: string

  InboxItemDetail* = object
    itemId*: string
    sessionId*: string
    kind*: InboxKind
    blocked*: bool                ## the agent stopped on it (a question)
    requestId*: string
    prompt*: string               ## the question, request or reply text
    form*: QuestionForm
    options*: seq[AnswerOption]
    permissionOptions*: seq[PermissionOption]
    approvals*: seq[ApprovalRequest]
    login*: LoginRequest
    feedback*: FeedbackRequest
    draft*: Draft
    lastReply*: string            ## ended turn: the agent's last reply
    familiar*: bool               ## the operator still remembers the session
    executiveSummary*: string     ## shown first when the session is unfamiliar

  Answer* = object
    ## What the operator put in an item's form.
    text*: string
    choices*: seq[string]
    decision*: string             ## a confirmation: `approve` / `reject`

const
  EmptyInboxText* = "Nothing is waiting for you."
  NoOptionsText* = "No options were provided for this question."
  EmptyResponseText* = "Response cannot be empty"
  SelectOptionText* = "Please select at least one option"
  SelectOneText* = "Please select only one option"
  ExpiredText* = "This request has expired"
  DecideText* = "Please approve or reject"

# ---------------------------------------------------------------------------
# Identity and words
# ---------------------------------------------------------------------------

proc refOf*(item: InboxItem): InboxItemRef = InboxItemRef(server: item.server, id: item.id)

proc isNone*(r: InboxItemRef): bool = r.id.len == 0

proc indexOf*(snapshot: InboxSnapshot; r: InboxItemRef): int =
  for i, item in snapshot.items:
    if item.refOf == r: return i
  -1

proc orderOf*(snapshot: InboxSnapshot): seq[InboxItemRef] =
  for item in snapshot.items: result.add item.refOf

proc waitWordKindOf*(kind: InboxKind): WaitWordKind =
  case kind
  of ikBlockedQuestion, ikUnknown: wwQuestion
  of ikEndedTurn: wwEndedTurn
  of ikPermissionGate: wwPermission
  of ikLoginRequest: wwLogin
  of ikAsyncFeedback: wwFeedback

proc kindWord*(item: InboxItem): string =
  ## An inbox row's words for the kind (`needs your answer`, …), the same as
  ## a tab's tooltip and a timeline say for the same wait
  ## (`activity_words.waitWords`). An unknown kind reads as its wire name.
  if item.kind == ikUnknown:
    item.kindText.replace('_', ' ')
  else:
    waitWords(waitWordKindOf(item.kind))

proc isBlocked*(item: InboxItem): bool =
  ## Whether the agent stopped on the item (everything but an async feedback
  ## request): the inbox control's amber count. Feedback is its second ink.
  item.kind != ikAsyncFeedback

proc countText*(count: int): string =
  ## The inbox control's count: `3 waiting`; "" for none.
  if count <= 0: "" else: $count & " waiting"

proc controlTitle*(count: int): string =
  ## The inbox control's title: `3 tasks need input`, `1 task needs input`,
  ## `No input required`.
  if count <= 0: "No input required"
  elif count == 1: "1 task needs input"
  else: $count & " tasks need input"

proc pendingCountText*(count: int): string =
  ## A session's pending-request mark: `Needs Follow-up` for one request,
  ## `N pending` for several, "" for none (INV-P2-21).
  if count <= 0: "" elif count == 1: "Needs Follow-up" else: $count & " pending"

proc positionText*(snapshot: InboxSnapshot; onScreen: InboxItemRef): string =
  ## `2 of 5` while the item on screen is in the inbox, `5 waiting`
  ## otherwise, "" for an empty inbox.
  if snapshot.items.len == 0: return ""
  let at = snapshot.indexOf(onScreen)
  if at < 0: countText(snapshot.items.len)
  else: $(at + 1) & " of " & $snapshot.items.len

proc priorityChip*(item: InboxItem): string =
  ## `urgent`, `high`, `low` (the effective level), with `, raised` while a
  ## boost holds; nothing for a `normal` item that is not boosted.
  if item.effectivePriority == ipNormal and not item.boost.active: return ""
  $item.effectivePriority & (if item.boost.active: ", raised" else: "")

proc countdownText*(ms: int64): string =
  ## `3:12`, `0:05`, `1:02:03`; never negative.
  let total = max(0'i64, ms) div 1000
  let h = total div 3600
  let m = (total mod 3600) div 60
  let s = total mod 60
  proc two(x: int64): string = (if x < 10: "0" else: "") & $x
  if h > 0: $h & ":" & two(m) & ":" & two(s) else: $m & ":" & two(s)

proc warmthChip*(warmth: CacheWarmth; nowMs: int64): string =
  ## The warmth chip: `warm 3:12` counting down to the cache's deadline
  ## (`exact` and `estimated` confidence), `likely warm` for a `learned`
  ## estimate, `warm` with no deadline, `expiring`, `cold`; nothing for a
  ## surface where timing costs nothing (`neutral`) or that is `unknown`.
  case warmth.state
  of wsWarm:
    if warmth.confidence == wcLearned: "likely warm"
    elif warmth.deadlineMs > 0: "warm " & countdownText(warmth.deadlineMs - nowMs)
    else: "warm"
  of wsExpiring: "expiring"
  of wsCold: "cold"
  of wsNeutral, wsUnknown: ""

proc holderText*(item: InboxItem): string =
  ## `with the Manager` / `needs you` for an item whose agent died.
  case item.heldBy
  of ihManager: "with the Manager"
  of ihOperator: "needs you"
  of ihNone: ""

# ---------------------------------------------------------------------------
# Wire decoding
# ---------------------------------------------------------------------------

proc str(node: JsonNode; key: string): string = node.fieldStr(key)

proc int0(node: JsonNode; key: string): int = node.fieldNum(key).int

proc arr(node: JsonNode; key: string): seq[JsonNode] =
  let v = node.fieldChild(key)
  if not v.isNil and v.kind == JArray:
    for x in v: result.add x

proc parsePriority*(text: string; default = ipNormal): InboxPriority =
  case text.toLowerAscii
  of "urgent": ipUrgent
  of "high": ipHigh
  of "normal": ipNormal
  of "low": ipLow
  else: default

proc parseKind*(text: string): InboxKind =
  for k in InboxKind:
    if k != ikUnknown and $k == text: return k
  ikUnknown

proc cacheWarmthFromJson*(node: JsonNode): CacheWarmth =
  result.state = case node.str("state")
    of "warm": wsWarm
    of "expiring": wsExpiring
    of "cold": wsCold
    of "neutral": wsNeutral
    else: wsUnknown
  result.deadlineMs = parseIsoMs(node.str("deadline"))
  result.confidence = case node.str("confidence")
    of "exact": wcExact
    of "estimated": wcEstimated
    of "learned": wcLearned
    else: wcNone

proc inboxItemFromJson*(node: JsonNode): InboxItem =
  ## One served item, read leniently.
  let kindText = node.str("kind")
  let s = node.fieldChild("session")
  let handle = s.fieldChild("handle")
  result = InboxItem(
    id: node.str("id"), server: node.str("server"),
    kind: parseKind(kindText), kindText: kindText,
    session: InboxSession(id: s.str("id"), title: s.str("title"), host: s.str("host"),
                          agent: s.str("agent"), status: s.str("status"),
                          label: s.str("label"),
                          handle: if not handle.isNil and handle.kind == JString: handle.getStr
                                  else: handle.str("display")),
    priority: parsePriority(node.str("priority")),
    position: node.int0("position"), explanation: node.str("explanation"),
    enteredAtMs: parseIsoMs(node.str("enteredAt")),
    warmth: cacheWarmthFromJson(node.fieldChild("cacheWarmth")),
    question: node.str("question"))
  result.effectivePriority = parsePriority(node.str("effectivePriority"), result.priority)
  let boost = node.fieldChild("boost")
  if not boost.isNil and boost.kind == JObject:
    result.boost = InboxBoost(active: true, reason: boost.str("reason"),
                              deadlineMs: parseIsoMs(boost.str("deadline")))
    for r in boost.arr("reasons"):
      if r.kind == JString: result.boost.reasons.add r.getStr
  result.heldBy = case node.str("heldBy")
    of "manager": ihManager
    of "operator": ihOperator
    else: ihNone
  if result.session.label.len == 0:
    result.session.label = result.session.title

proc inboxFromJson*(node: JsonNode): InboxSnapshot =
  ## The served inbox, its items in the order served (never re-sorted; an
  ## item of an unknown kind kept in its place).
  result = InboxSnapshot(generatedAtMs: parseIsoMs(node.str("generatedAt")),
                         nextChangeAtMs: parseIsoMs(node.str("nextChangeAt")))
  for item in node.arr("items"):
    if item.kind == JObject: result.items.add inboxItemFromJson(item)
  for d in node.arr("degraded"):
    result.degraded.add DegradedServer(server: d.str("server"), reason: d.str("reason"))

proc itemRefFromJson(node: JsonNode): InboxItemRef =
  if node.kind == JString: InboxItemRef(id: node.getStr)
  else: InboxItemRef(server: node.str("server"), id: node.str("id"))

proc inboxEventFromJson*(node: JsonNode): InboxEvent =
  ## One event of the proposed inbox stream: `{"type": "item.added", "item":
  ## {...}, "order": [...]}`; `item.resolved` names its item by `id` (and
  ## `server`) or by `item`. `order` lists ids, or `{server, id}` objects.
  let t = node.str("type")
  result.kind = case t
    of "item.added": ieAdded
    of "item.updated": ieUpdated
    of "item.resolved": ieResolved
    else: ieReordered
  let item = node.fieldChild("item")
  if not item.isNil and item.kind == JObject:
    result.item = inboxItemFromJson(item)
    result.target = result.item.refOf
  if node.str("id").len > 0:
    result.target = InboxItemRef(server: node.str("server"), id: node.str("id"))
  let order = node.fieldChild("order")
  if not order.isNil and order.kind == JArray:
    result.hasOrder = true
    for r in order: result.order.add itemRefFromJson(r)

# ---------------------------------------------------------------------------
# The reducer
# ---------------------------------------------------------------------------

proc renumber(snapshot: var InboxSnapshot) =
  for i, item in snapshot.items.mpairs: item.position = i + 1

proc arrange(snapshot: var InboxSnapshot; order: openArray[InboxItemRef]) =
  ## The items in the order given, as given. An item the order leaves out
  ## keeps its place after the ordered ones (a stream that names only part
  ## of the order never makes an item vanish); a ref with no item is skipped.
  var arranged: seq[InboxItem]
  var taken = newSeq[bool](snapshot.items.len)
  for r in order:
    let at = snapshot.indexOf(r)
    if at >= 0 and not taken[at]:
      arranged.add snapshot.items[at]
      taken[at] = true
  for i, item in snapshot.items:
    if not taken[i]: arranged.add item
  snapshot.items = arranged

proc applyInboxEvent*(snapshot: var InboxSnapshot; event: InboxEvent): bool =
  ## One stream event folded into the inbox. True when the inbox changed.
  ## The order after the event is the order the event carries: an added item
  ## goes where its `position` puts it (at the end without one), an updated
  ## one stays where it is, and a carried `order` arranges the items exactly
  ## so. Nothing here compares priorities: the server ordered them.
  let before = snapshot
  case event.kind
  of ieAdded:
    let at = snapshot.indexOf(event.item.refOf)
    if at >= 0:
      snapshot.items[at] = event.item
    else:
      let pos = event.item.position
      if pos >= 1 and pos <= snapshot.items.len:
        snapshot.items.insert(event.item, pos - 1)
      else:
        snapshot.items.add event.item
  of ieUpdated:
    let at = snapshot.indexOf(event.item.refOf)
    if at >= 0: snapshot.items[at] = event.item
    else: snapshot.items.add event.item
  of ieResolved:
    let at = snapshot.indexOf(event.target)
    if at >= 0: snapshot.items.delete(at)
  of ieReordered:
    discard
  if event.hasOrder: snapshot.arrange(event.order)
  snapshot.renumber()
  snapshot.items != before.items

# ---------------------------------------------------------------------------
# The cursor (what a server keeps per user and cursor name)
# ---------------------------------------------------------------------------

proc cursorNext*(order: openArray[InboxItemRef]; cursor: var InboxCursor):
    tuple[moved: bool, item: InboxItemRef] =
  ## Next: the top of the current order, excluding the item on screen. The
  ## item left is pushed on the visited stack. Nothing moves when no other
  ## item waits.
  for r in order:
    if r != cursor.current:
      if not cursor.current.isNone: cursor.visited.add cursor.current
      cursor.current = r
      return (true, r)
  (false, cursor.current)

proc cursorPrev*(cursor: var InboxCursor): tuple[moved: bool, item: InboxItemRef] =
  ## Previous: back to the item visited last (whether or not it still
  ## waits), popping it from the stack; nothing moves when none was visited.
  if cursor.visited.len == 0: return (false, cursor.current)
  cursor.current = cursor.visited.pop()
  (true, cursor.current)

proc canPrev*(cursor: InboxCursor): bool = cursor.visited.len > 0

# ---------------------------------------------------------------------------
# Item pages
# ---------------------------------------------------------------------------

proc optionsFromJson(nodes: seq[JsonNode]): seq[AnswerOption] =
  for o in nodes:
    if o.kind == JString:
      result.add AnswerOption(id: o.getStr, label: o.getStr)
    else:
      let id = o.str("id")
      let label = o.str("label")
      result.add AnswerOption(id: if id.len > 0: id else: label,
                              label: if label.len > 0: label else: id,
                              description: o.str("description"))

proc permissionLabel*(kind: string): string =
  ## The button words of an agent's permission option kind.
  case kind
  of "allow_once": "Allow once"
  of "allow_always": "Allow always"
  of "reject_once": "Reject once"
  of "reject_always": "Reject always"
  else: kind.replace('_', ' ').capitalizeAscii

proc inboxItemDetailFromJson*(node: JsonNode): InboxItemDetail =
  ## One item's page, read leniently from the proposed shape.
  result = InboxItemDetail(itemId: node.str("itemId"), sessionId: node.str("sessionId"),
                           kind: parseKind(node.str("kind")),
                           blocked: node.fieldFlag("blocked"),
                           requestId: node.str("requestId"), prompt: node.str("prompt"),
                           lastReply: node.str("lastReply"),
                           familiar: node.fieldFlag("familiar"),
                           executiveSummary: node.str("executiveSummary"))
  result.form = case node.str("form")
    of "single_choice": qfSingle
    of "multi_choice": qfMulti
    of "confirmation": qfConfirmation
    else: qfFreeForm
  result.options = optionsFromJson(node.arr("options"))
  for p in node.arr("permissionOptions"):
    let kind = p.str("kind")
    let label = p.str("label")
    result.permissionOptions.add PermissionOption(
      id: p.str("id"), kind: kind, label: if label.len > 0: label else: permissionLabel(kind))
  for a in node.arr("approvals"):
    result.approvals.add ApprovalRequest(
      requestId: a.str("requestId"),
      scope: if a.str("scope") == "network": asNetwork else: asSudo,
      command: a.str("command"), domain: a.str("domain"), reason: a.str("reason"))
  let login = node.fieldChild("login")
  if not login.isNil and login.kind == JObject:
    result.login = LoginRequest(requestId: login.str("requestId"),
                                provider: login.str("provider"), prompt: login.str("prompt"),
                                mode: if login.str("mode") == "remote_view": lmRemoteView
                                      else: lmLocalDesktop,
                                error: login.str("error"))
    result.login.state = case login.str("state")
      of "cancelling": lsCancelling
      of "completed": lsCompleted
      of "failed": lsFailed
      else: lsPending
  let fb = node.fieldChild("feedback")
  if not fb.isNil and fb.kind == JObject:
    result.feedback = FeedbackRequest(id: fb.str("id"), taskId: fb.str("taskId"),
                                      prompt: fb.str("prompt"), context: fb.str("context"),
                                      options: optionsFromJson(fb.arr("options")),
                                      minLength: fb.int0("minLength"),
                                      maxLength: fb.int0("maxLength"),
                                      expiresAtMs: parseIsoMs(fb.str("expiresAt")))
    result.feedback.feedbackType = case fb.str("type")
      of "options": ftOptions
      of "confirmation": ftConfirmation
      of "information": ftInformation
      else: ftQuestion
    for a in fb.arr("attachments"):
      result.feedback.attachments.add Attachment(name: a.str("name"), kind: a.str("kind"),
                                                 url: a.str("url"))
  let d = node.fieldChild("draft")
  if not d.isNil and d.kind == JObject:
    result.draft = Draft(present: true, text: d.str("text"), rationale: d.str("rationale"),
                         confidence: d.str("confidence"), drafter: d.str("drafter"))
    for c in d.arr("choices"):
      if c.kind == JString: result.draft.choices.add c.getStr

proc bannerText*(detail: InboxItemDetail): string =
  ## A question page's banner.
  if detail.blocked: "Agent has stopped and is waiting for your answer"
  else: "Agent is waiting for an answer"

proc approvalSummary*(request: ApprovalRequest): string =
  ## `<command> in order to: <reason>` / `<domain> in order to: <reason>`.
  let what = if request.scope == asNetwork: request.domain else: request.command
  if request.reason.len > 0: what & " in order to: " & request.reason else: what

proc isExpired*(request: FeedbackRequest; nowMs: int64): bool =
  request.expiresAtMs > 0 and nowMs >= request.expiresAtMs

proc checkChoices(options: openArray[AnswerOption]; choices: openArray[string];
                  single: bool): string =
  if choices.len == 0: return SelectOptionText
  if single and choices.len > 1: return SelectOneText
  for c in choices:
    var known = false
    for o in options:
      if o.id == c: known = true
    if not known: return "Unknown option: " & c
  ""

proc checkText(text: string; minLength, maxLength: int): string =
  let t = text.strip
  if t.len == 0: return EmptyResponseText
  if minLength > 0 and t.len < minLength:
    return "Response must be at least " & $minLength & " characters"
  if maxLength > 0 and t.len > maxLength:
    return "Response must be at most " & $maxLength & " characters"
  ""

proc validateAnswer*(detail: InboxItemDetail; answer: Answer; nowMs: int64): string =
  ## Why the answer cannot be sent, in the words the form shows under it;
  ## "" when it can. A feedback request checks its type's rules and its
  ## expiry; a question checks its form; an ended turn needs an instruction.
  ## Permission and approval decisions are buttons and always valid.
  case detail.kind
  of ikAsyncFeedback:
    let fb = detail.feedback
    if fb.isExpired(nowMs): return ExpiredText
    case fb.feedbackType
    of ftQuestion: checkText(answer.text, fb.minLength, fb.maxLength)
    of ftOptions: checkChoices(fb.options, answer.choices, single = false)
    of ftConfirmation:
      if answer.decision in ["approve", "reject"]: "" else: DecideText
    of ftInformation: ""
  of ikBlockedQuestion, ikUnknown:
    case detail.form
    of qfFreeForm: checkText(answer.text, 0, 0)
    of qfSingle:
      if detail.options.len == 0: NoOptionsText
      else: checkChoices(detail.options, answer.choices, single = true)
    of qfMulti:
      if detail.options.len == 0: NoOptionsText
      else: checkChoices(detail.options, answer.choices, single = false)
    of qfConfirmation:
      if answer.decision in ["approve", "reject"]: "" else: DecideText
  of ikEndedTurn: checkText(answer.text, 0, 0)
  of ikPermissionGate, ikLoginRequest: ""
