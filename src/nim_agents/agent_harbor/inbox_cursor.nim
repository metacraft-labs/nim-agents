## The inbox cursor seen from a front-end: the cursor's wire shapes and the
## front-end's half of fast Next and Prev (agent-harbor's REST contract,
## "Inbox cursors" and its proposed "Fast Next and Prev").
##
## **Wire shapes.** Everything the cursor puts on the wire is read here, so a
## change of the wire is made here alone: the cursor block and `ahead` of a
## `GET /api/v1/inbox?cursor=<name>` read (`inboxReadFromJson`), a move's
## answer (`cursorAnswerFromJson`), and the frames of the inbox stream
## `GET /api/v1/inbox/events` (`inboxNoticeOf`), which notify and carry no
## items: `resync` (read the inbox again) and `changed` (what changed, and
## with the `cursor` reason the caller's cursors' moves). Two of these
## shapes are not spelled out by the contract and are read as guessed until a
## server serves them: the read's `cursor` block (`name`, `itemId`,
## `visitedDepth`, `cursorVersion`) and an `ahead` on each entry of a frame's
## `cursors`. Every reader is lenient and never raises.
##
## **Targets in advance.** `ahead` is where the next three Next presses and
## the next three Prev presses would land if nothing changed, computed by the
## cursor rules (`inbox.walkNext`, `inbox.walkPrev`); `aheadOf` computes
## it the same way for a source that stands in for a server.
##
## **A press never waits** (`FastCursor`). A press switches at once to the
## first target the cursor holds for its direction, if the inbox still lists
## it, and returns the post to send behind it (`expectedVersion`, the version
## its targets were based on, and `landedOn`, the item switched to). The
## targets held then follow the press by the same rules: after Next, the
## item left is the first Prev target; after Prev, the Next targets are
## worked out from the order held, since Next depends only on the order and
## the item on screen. A press with no target held, or whose target has left
## the inbox, waits for the answer (`pending`), and so does every press after
## it until that answer comes.
##
## **Reconciling.** Answers come back in the order the posts went out. The
## server's targets are taken only once every post has been answered, since
## an answer to an earlier press describes a place the screen has already
## left. The item on screen never moves for an answer to a press that
## switched: when the server landed elsewhere, the screen stays and the next
## press continues from the server's targets. It moves for the answer to a
## press that waited, and for a move told on the stream that is newer than
## every answer (another device's), when nothing is in flight and the inbox
## holds that item.
##
## Signal-free and app-agnostic; identical on the C and JS targets.

import std/json
import ./[activity_words, fleet_records, inbox]

const AheadDepth* = 3
  ## How many presses each way the server hands out in advance.

type
  PressDirection* = enum
    pdNext = "next"
    pdPrev = "prev"

  CursorAhead* = object
    ## The targets of the next presses, as the server computed them.
    known*: bool             ## the answer carried them
    next*, prev*: seq[InboxItemRef]
    basedOn*: int64          ## the `cursorVersion` they were computed at

  CursorState* = object
    ## Where a cursor is, as a read with `?cursor=` says.
    known*: bool             ## the read carried a cursor
    name*: string
    item*: InboxItemRef      ## none when the cursor is on nothing
    visitedDepth*: int
    cursorVersion*: int64

  InboxRead* = object
    ## A `GET /api/v1/inbox` read: the items, and with `?cursor=` the cursor.
    snapshot*: InboxSnapshot
    cursor*: CursorState
    ahead*: CursorAhead

  CursorAnswer* = object
    ## The answer to `POST …/cursors/{name}/next` or `…/prev`.
    hasItem*: bool           ## false: nothing to move to (`item` null)
    item*: InboxItem
    visitedDepth*: int
    cursorVersion*: int64
    ahead*: CursorAhead

  CursorNotice* = object
    ## One cursor's move, as a `changed` frame tells it.
    name*: string
    item*: InboxItemRef
    cursorVersion*: int64
    ahead*: CursorAhead

  InboxNoticeKind* = enum
    inResync = "resync"
    inChanged = "changed"
    inOther = "other"        ## another event, or data that could not be read

  InboxNotice* = object
    ## One frame of the inbox stream.
    kind*: InboxNoticeKind
    id*: string              ## `<epoch>:<seq>`
    epoch*: string
    sequence*: int64
    reason*: string          ## resync: `connected`, `reconnected`, `recovered`
    entered*, left*, claims*: seq[InboxItemRef]
    reasons*: seq[string]
    cursors*: seq[CursorNotice]
    nextChangeAtMs*: int64

  CursorPost* = object
    ## What a press sends behind it.
    direction*: PressDirection
    expectedVersion*: int64  ## -1: the front-end holds no version
    landedOn*: string        ## "": the press waits for the answer

  PressOutcome* = object
    posts*: bool             ## a post is to be sent (false: nothing waits)
    switched*: bool          ## the screen moved at once, to `target`
    pending*: bool           ## the press waits for its answer
    target*: InboxItemRef
    post*: CursorPost

  Reconciled* = object
    moveTo*: InboxItemRef    ## the item the screen moved to; none for none

  FastCursor* = object
    onScreen*: InboxItemRef
    ahead: CursorAhead       ## the targets held, shifted by each press
    version: int64           ## the server version the targets came from
    known: bool              ## the server's position has been read once
    waits: seq[bool]         ## per post in flight: whether its press waited

# ---------------------------------------------------------------------------
# The targets of the next presses
# ---------------------------------------------------------------------------

proc nextTargets(order: openArray[InboxItemRef]; cursor: InboxCursor;
                 depth: int): seq[InboxItemRef] =
  var c = cursor
  for _ in 1 .. depth:
    let (moved, item) = walkNext(order, c)
    if not moved: break
    result.add item

proc prevTargets(order: openArray[InboxItemRef]; cursor: InboxCursor;
                 depth: int): seq[InboxItemRef] =
  var c = cursor
  for _ in 1 .. depth:
    let (moved, item) = walkPrev(order, c)
    if not moved: break
    result.add item

proc aheadOf*(order: openArray[InboxItemRef]; cursor: InboxCursor;
              depth = AheadDepth; basedOn = 0'i64): CursorAhead =
  ## Where the next `depth` Next presses and the next `depth` Prev presses
  ## would land from `cursor`, by the cursor rules. `cursor` is not moved.
  CursorAhead(known: true, basedOn: basedOn,
              next: nextTargets(order, cursor, depth),
              prev: prevTargets(order, cursor, depth))

# ---------------------------------------------------------------------------
# Wire shapes
# ---------------------------------------------------------------------------

proc refOfWire(node: JsonNode): InboxItemRef =
  ## An item id as the cursor names it: a string, or `{server, id}`.
  if node.isNil: return
  case node.kind
  of JString: InboxItemRef(id: node.getStr)
  of JObject: InboxItemRef(server: node.fieldStr("server"), id: node.fieldStr("id"))
  else: InboxItemRef()

proc refsOf(node: JsonNode; key: string): seq[InboxItemRef] =
  let list = node.fieldChild(key)
  if list.isNil or list.kind != JArray: return
  for x in list:
    let r = refOfWire(x)
    if not r.isNone: result.add r

proc aheadFromJson*(node: JsonNode): CursorAhead =
  ## `{"next": [ids], "prev": [ids], "basedOn": <cursorVersion>}`; not
  ## `known` when absent or not an object.
  if node.isNil or node.kind != JObject: return
  CursorAhead(known: true, next: node.refsOf("next"), prev: node.refsOf("prev"),
              basedOn: node.fieldNum("basedOn"))

proc cursorStateFromJson*(node: JsonNode): CursorState =
  ## The cursor block of a read with `?cursor=` (shape guessed: `name`,
  ## `itemId`, `visitedDepth`, `cursorVersion`); not `known` when absent.
  if node.isNil or node.kind != JObject: return
  CursorState(known: true, name: node.fieldStr("name"),
              item: refOfWire(node.fieldChild("itemId")),
              visitedDepth: node.fieldInt("visitedDepth"),
              cursorVersion: node.fieldNum("cursorVersion"))

proc inboxReadFromJson*(node: JsonNode): InboxRead =
  ## A `GET /api/v1/inbox` read, the items in the order served.
  InboxRead(snapshot: inboxFromJson(node),
            cursor: cursorStateFromJson(node.fieldChild("cursor")),
            ahead: aheadFromJson(node.fieldChild("ahead")))

proc cursorAnswerFromJson*(node: JsonNode): CursorAnswer =
  ## A move's answer: `{"item": <item> | null, "visitedDepth",
  ## "cursorVersion", "ahead"}`.
  let item = node.fieldChild("item")
  result = CursorAnswer(visitedDepth: node.fieldInt("visitedDepth"),
                        cursorVersion: node.fieldNum("cursorVersion"),
                        ahead: aheadFromJson(node.fieldChild("ahead")))
  if not item.isNil and item.kind == JObject:
    result.hasItem = true
    result.item = inboxItemFromJson(item)

proc cursorNoticeFromJson(node: JsonNode): CursorNotice =
  CursorNotice(name: node.fieldStr("name"),
               item: refOfWire(node.fieldChild("itemId")),
               cursorVersion: node.fieldNum("cursorVersion"),
               ahead: aheadFromJson(node.fieldChild("ahead")))

proc parseData(data: string): JsonNode =
  ## The frame's data as JSON, or nil. On the JS backend `parseJson` throws
  ## the engine's own `SyntaxError`, which only a bare `except` catches.
  try:
    result = parseJson(data)
  except:
    result = nil

proc inboxNoticeOf*(event, data, id: string): InboxNotice =
  ## One frame of the inbox stream, from its SSE fields. An event of another
  ## name, or data that is not a JSON object, reads as `inOther`.
  result = InboxNotice(kind: inOther, id: id)
  let kind = case event
    of "resync": inResync
    of "changed": inChanged
    else: inOther
  if kind == inOther: return
  let node = parseData(data)
  if node.isNil or node.kind != JObject: return
  result.kind = kind
  result.epoch = node.fieldStr("epoch")
  result.sequence = node.fieldNum("seq")
  result.reason = node.fieldStr("reason")
  result.entered = node.refsOf("entered")
  result.left = node.refsOf("left")
  result.claims = node.refsOf("claims")
  let reasons = node.fieldChild("reasons")
  if not reasons.isNil and reasons.kind == JArray:
    for x in reasons:
      if x.kind == JString: result.reasons.add x.getStr
  let cursors = node.fieldChild("cursors")
  if not cursors.isNil and cursors.kind == JArray:
    for x in cursors:
      if x.kind == JObject: result.cursors.add cursorNoticeFromJson(x)
  result.nextChangeAtMs = parseIsoMs(node.fieldStr("nextChangeAt"))

proc cursorNoticeFor*(notice: InboxNotice; name: string): (bool, CursorNotice) =
  ## The move of the cursor `name` the frame tells, if it tells one.
  for c in notice.cursors:
    if c.name == name: return (true, c)
  (false, CursorNotice())

# ---------------------------------------------------------------------------
# FastCursor
# ---------------------------------------------------------------------------

proc newFastCursor*(): FastCursor = FastCursor(version: -1)

proc inFlight*(fc: FastCursor): int =
  ## The posts sent and not answered yet.
  fc.waits.len

proc pending*(fc: FastCursor): bool =
  ## A press waits for its answer.
  for w in fc.waits:
    if w: return true
  false

proc holds(snapshot: InboxSnapshot; r: InboxItemRef): bool =
  not r.isNone and snapshot.indexOf(r) >= 0

proc press*(fc: var FastCursor; snapshot: InboxSnapshot;
            direction: PressDirection): PressOutcome =
  ## One press of Next or Prev. Switches at once when the cursor holds a
  ## target for it that the inbox still lists; otherwise the press waits.
  ## Either way the outcome names the post to send. With nothing waiting in
  ## the inbox nothing is posted.
  if snapshot.items.len == 0: return
  result.posts = true
  result.post = CursorPost(direction: direction, expectedVersion: fc.version)
  let targets = if direction == pdNext: fc.ahead.next else: fc.ahead.prev
  if fc.pending or targets.len == 0 or not snapshot.holds(targets[0]):
    result.pending = true
    fc.waits.add true
    return
  let target = targets[0]
  let left = fc.onScreen
  case direction
  of pdNext:
    fc.ahead.next = targets[1 .. ^1]
    if snapshot.holds(left):
      var prev = @[left] & fc.ahead.prev
      if prev.len > AheadDepth: prev.setLen(AheadDepth)
      fc.ahead.prev = prev
  of pdPrev:
    fc.ahead.prev = targets[1 .. ^1]
    fc.ahead.next = nextTargets(snapshot.orderOf, InboxCursor(current: target),
                                AheadDepth)
  fc.onScreen = target
  fc.waits.add false
  result.switched = true
  result.target = target
  result.post.landedOn = target.id

proc takeServer(fc: var FastCursor; version: int64; ahead: CursorAhead) =
  fc.known = true
  fc.version = version
  if ahead.known: fc.ahead = ahead

proc reconcileAnswer*(fc: var FastCursor; answer: CursorAnswer): Reconciled =
  ## The answer to the oldest post in flight.
  if fc.waits.len == 0: return
  let waited = fc.waits[0]
  fc.waits.delete(0)
  if waited and answer.hasItem and answer.item.refOf != fc.onScreen:
    fc.onScreen = answer.item.refOf
    result.moveTo = fc.onScreen
  if fc.waits.len == 0 and answer.cursorVersion >= fc.version:
    fc.takeServer(answer.cursorVersion, answer.ahead)

proc forgetAhead*(fc: var FastCursor) =
  ## The inbox changed (an item entered, left or moved): the targets held
  ## were computed from the order before it, so the next press waits for the
  ## server instead of switching to one of them. An answer or a read brings
  ## new ones.
  fc.ahead = CursorAhead()

proc reconcileFailure*(fc: var FastCursor) =
  ## The oldest post in flight was refused or never answered: it is no longer
  ## in flight, and a press that waited for it waits no more. The screen
  ## stays where it is; the caller reads the cursor again to learn where the
  ## server has it.
  if fc.waits.len > 0: fc.waits.delete(0)

proc reconcileNotice*(fc: var FastCursor; notice: CursorNotice;
                      snapshot: InboxSnapshot): Reconciled =
  ## A move of this cursor told on the inbox stream. Ignored while posts are
  ## in flight (their answers carry the same moves, in order) and when not
  ## newer than what the cursor holds; otherwise taken, and the screen
  ## follows when the inbox holds the item.
  if fc.waits.len > 0: return
  if fc.known and notice.cursorVersion <= fc.version: return
  fc.takeServer(notice.cursorVersion, notice.ahead)
  if snapshot.holds(notice.item) and notice.item != fc.onScreen:
    fc.onScreen = notice.item
    result.moveTo = notice.item

proc reconcileRead*(fc: var FastCursor; cursor: CursorState;
                    ahead: CursorAhead): Reconciled =
  ## A read of the inbox with `?cursor=`. The first one puts the screen where
  ## the cursor is (a front-end that opens later joins the walk where it is);
  ## a later one takes the server's targets when nothing is in flight, and
  ## moves the screen only for a newer version, as a stream notice does.
  if not cursor.known or fc.waits.len > 0: return
  if fc.known and cursor.cursorVersion < fc.version: return
  let newer = not fc.known or cursor.cursorVersion > fc.version
  fc.takeServer(cursor.cursorVersion, ahead)
  if newer and cursor.item != fc.onScreen:
    fc.onScreen = cursor.item
    result.moveTo = cursor.item

proc heldAhead*(fc: FastCursor): CursorAhead =
  ## The targets the cursor holds now (for a view that shows them, and tests).
  fc.ahead
