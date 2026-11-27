## The inbox cursor of nim-agents: the approved cursor rules (Next to the top
## excluding the item on screen; Prev back along the items visited that still
## wait, wrapping to the last item; an item that leaves is on no cursor), the
## targets of the next presses they give (`aheadOf`), the cursor's wire shapes
## (a read with `?cursor=`, a move's answer, the inbox stream's frames), and
## `FastCursor`, the front-end's half of fast Next and Prev: a press switches
## at once from what it holds and the server's bookkeeping follows.
##
## Every input is JSON written out here, in the shape of the REST contract's
## text. A case that rests on a shape the contract does not spell out says so
## in its name: "(shape guessed: …)".

import std/[json, unittest]
import nim_agents/agent_harbor/[inbox, inbox_cursor]

proc r(id: string): InboxItemRef = InboxItemRef(id: id)

proc refs(ids: varargs[string]): seq[InboxItemRef] =
  for id in ids: result.add r(id)

proc snapshotOf(ids: varargs[string]): InboxSnapshot =
  for i, id in ids:
    result.items.add InboxItem(id: id, position: i + 1,
                               session: InboxSession(id: "s-" & id))

proc ahead(next, prev: seq[InboxItemRef]; basedOn: int64): CursorAhead =
  CursorAhead(next: next, prev: prev, basedOn: basedOn, known: true)

suite "the approved cursor rules":
  test "Next goes to the top, excluding the item on screen, and pushes the item left":
    var c: InboxCursor
    let order = refs("a", "b", "c")
    check walkNext(order, c) == (true, r("a"))
    check walkNext(order, c) == (true, r("b"))
    check walkNext(order, c) == (true, r("a"))
    check c.visited == refs("a", "b")

  test "Prev returns along the visited stack":
    var c: InboxCursor
    let order = refs("a", "b", "c")
    discard walkNext(order, c)                   # a
    discard walkNext(refs("c", "a", "b"), c)     # c
    check walkPrev(order, c) == (true, r("a"))
    check c.visited.len == 0

  test "Prev skips and discards visited items that left the inbox":
    var c: InboxCursor
    discard walkNext(refs("a", "b", "c"), c)     # a
    discard walkNext(refs("b", "a", "c"), c)     # b
    discard walkNext(refs("c", "a", "b"), c)     # c; visited a, b
    # `b` was answered meanwhile: Prev skips it and lands on `a`.
    check walkPrev(refs("c", "a"), c) == (true, r("a"))
    check c.visited.len == 0

  test "Prev at the first item, with nothing left on the stack, wraps to the last":
    var c: InboxCursor
    discard walkNext(refs("a", "b", "c"), c)     # a, nothing visited before
    check walkPrev(refs("a", "b", "c"), c) == (true, r("c"))
    # On the last item with nothing visited, Prev stays.
    check walkPrev(refs("a", "b", "c"), c) == (false, r("c"))

  test "an item that leaves the inbox is on no cursor; Next starts from the top":
    var c: InboxCursor
    discard walkNext(refs("a", "b"), c)          # a
    discard walkNext(refs("a", "b"), c)          # b; visited a
    check walkNext(refs("a", "c"), c) == (true, r("a"))   # b left
    # The item that left was not pushed: only `a` is behind.
    check c.visited == refs("a")

  test "with no item at all nothing moves and the cursor is on nothing":
    var c = InboxCursor(current: r("a"), visited: refs("b"))
    check walkNext(newSeq[InboxItemRef](), c) == (false, InboxItemRef())
    check walkPrev(newSeq[InboxItemRef](), c) == (false, InboxItemRef())
    check c.current.isNone

suite "the targets of the next presses":
  test "a fresh cursor over three items":
    let a = aheadOf(refs("a", "b", "c"), InboxCursor())
    check a.next == refs("a", "b", "a")
    check a.prev == refs("c")

  test "mid-walk: Next continues from the item on screen, Prev runs down the stack and wraps":
    var c: InboxCursor
    discard walkNext(refs("a", "b", "c"), c)     # a
    discard walkNext(refs("a", "b", "c"), c)     # b; visited a
    let a = aheadOf(refs("a", "b", "c"), c, depth = 3)
    check a.next == refs("a", "b", "a")
    check a.prev == refs("a", "c")                 # pop a, then wrap to c, then stay
    # Computing the targets moves nothing.
    check c.current == r("b")
    check c.visited == refs("a")

  test "one item: Next has nowhere to go, Prev wraps onto it once":
    let a = aheadOf(refs("a"), InboxCursor())
    check a.next == refs("a")
    check a.prev == refs("a")
    let onIt = aheadOf(refs("a"), InboxCursor(current: r("a")))
    check onIt.next.len == 0
    check onIt.prev.len == 0

  test "nothing waiting: nothing ahead":
    let a = aheadOf(newSeq[InboxItemRef](), InboxCursor())
    check a.next.len == 0
    check a.prev.len == 0

suite "the cursor's wire shapes":
  test "a read with ?cursor= keeps the items in order and carries the cursor (shape guessed: the cursor block)":
    let read = inboxReadFromJson(parseJson("""{
      "items": [{"id": "a@1", "kind": "ended_turn", "session": {"id": "a"}},
                {"id": "b@1", "kind": "blocked_question", "session": {"id": "b"}}],
      "cursor": {"name": "default", "itemId": "b@1", "visitedDepth": 2, "cursorVersion": 7},
      "ahead": {"next": ["a@1"], "prev": ["a@1", "b@1"], "basedOn": 7}}"""))
    check read.snapshot.orderOf == refs("a@1", "b@1")
    check read.cursor.known
    check read.cursor.name == "default"
    check read.cursor.item == r("b@1")
    check read.cursor.visitedDepth == 2
    check read.cursor.cursorVersion == 7
    check read.ahead.known
    check read.ahead.next == refs("a@1")
    check read.ahead.prev == refs("a@1", "b@1")
    check read.ahead.basedOn == 7

  test "a read without a cursor knows none, and a null itemId is on nothing":
    let plain = inboxReadFromJson(parseJson("""{"items": []}"""))
    check not plain.cursor.known
    check not plain.ahead.known
    let fresh = inboxReadFromJson(parseJson(
      """{"items": [], "cursor": {"name": "default", "itemId": null, "cursorVersion": 0}}"""))
    check fresh.cursor.known
    check fresh.cursor.item.isNone

  test "a move's answer: the item landed on, the version, the stack's depth and ahead":
    let answer = cursorAnswerFromJson(parseJson("""{
      "item": {"id": "a@1", "kind": "ended_turn", "session": {"id": "a", "label": "A"}},
      "visitedDepth": 1, "cursorVersion": 4,
      "ahead": {"next": ["b@1"], "prev": [], "basedOn": 4}}"""))
    check answer.hasItem
    check answer.item.id == "a@1"
    check answer.item.session.label == "A"
    check answer.cursorVersion == 4
    check answer.visitedDepth == 1
    check answer.ahead.next == refs("b@1")
    check answer.ahead.prev.len == 0
    let none = cursorAnswerFromJson(parseJson("""{"item": null, "cursorVersion": 4}"""))
    check not none.hasItem

  test "the stream's resync and changed frames":
    let resync = inboxNoticeOf("resync", """{"epoch":"e1","seq":1,"reason":"reconnected","nextChangeAt":"2026-11-24T21:03:40Z"}""", "e1:1")
    check resync.kind == inResync
    check resync.reason == "reconnected"
    check resync.epoch == "e1"
    check resync.sequence == 1
    check resync.id == "e1:1"
    check resync.nextChangeAtMs > 0
    let changed = inboxNoticeOf("changed", """{"epoch":"e1","seq":2,"entered":["c@1"],"left":["a@1"],"claims":["b@1"],"reasons":["entered","left","claim"]}""", "e1:2")
    check changed.kind == inChanged
    check changed.entered == refs("c@1")
    check changed.left == refs("a@1")
    check changed.claims == refs("b@1")
    check changed.reasons == @["entered", "left", "claim"]
    check changed.cursors.len == 0

  test "a cursor move told on the stream (shape guessed: ahead on each cursors entry)":
    let moved = inboxNoticeOf("changed", """{"epoch":"e1","seq":3,"reasons":["cursor"],
      "cursors":[{"name":"default","itemId":"b@1","cursorVersion":5,
                  "ahead":{"next":["a@1"],"prev":["c@1"],"basedOn":5}},
                 {"name":"ci-7","itemId":null,"cursorVersion":2}]}""", "e1:3")
    check moved.cursors.len == 2
    let (found, notice) = moved.cursorNoticeFor("default")
    check found
    check notice.item == r("b@1")
    check notice.cursorVersion == 5
    check notice.ahead.known
    check notice.ahead.next == refs("a@1")
    let (foundOther, other) = moved.cursorNoticeFor("ci-7")
    check foundOther
    check other.item.isNone
    check not other.ahead.known
    check not moved.cursorNoticeFor("missing")[0]

  test "a frame of another kind, or data that is not JSON, is kept as other and never raises":
    check inboxNoticeOf("keep-alive", "", "").kind == inOther
    check inboxNoticeOf("changed", "not json", "e1:9").kind == inOther
    check inboxNoticeOf("changed", "[1]", "e1:9").kind == inOther

suite "FastCursor: a press never waits on the server":
  setup:
    let three = snapshotOf("a", "b", "c")
    var fc = newFastCursor()
    discard fc.reconcileRead(CursorState(known: true, name: "default", cursorVersion: 0),
                     ahead(refs("a", "b", "a"), refs("c"), 0))

  test "with three items waiting, Next walks them in the server's order, at once":
    let p1 = fc.press(three, pdNext)
    check p1.switched
    check not p1.pending
    check p1.target == r("a")
    check fc.onScreen == r("a")
    check p1.post.direction == pdNext
    check p1.post.expectedVersion == 0
    check p1.post.landedOn == "a"
    let p2 = fc.press(three, pdNext)
    check p2.target == r("b")
    check p2.post.expectedVersion == 0   # still the version the ahead was based on
    check fc.inFlight == 2

  test "Prev returns along the items visited, from what the cursor holds":
    discard fc.press(three, pdNext)      # a
    discard fc.press(three, pdNext)      # b
    let back = fc.press(three, pdPrev)
    check back.switched
    check back.target == r("a")
    # And Next from `a` is the top excluding `a`, worked out from the order held.
    check fc.press(three, pdNext).target == r("b")

  test "Prev at the first item wraps to the last":
    let wrapped = fc.press(three, pdPrev)
    check wrapped.switched
    check wrapped.target == r("c")

  test "a press past what ahead holds is pending, and the answer puts its item on screen":
    let order = snapshotOf("a", "b", "c", "d")
    discard fc.reconcileRead(CursorState(known: true, name: "default", cursorVersion: 0),
                     ahead(refs("a", "b", "a"), refs("d"), 0))
    discard fc.press(order, pdPrev)       # d
    let p = fc.press(order, pdPrev)       # the prev targets are used up
    check not p.switched
    check p.pending
    check fc.pending
    check fc.onScreen == r("d")
    check p.post.landedOn == ""
    # The first post's answer: the server agrees on `d`.
    check fc.reconcileAnswer(CursorAnswer(hasItem: true, item: InboxItem(id: "d"),
      cursorVersion: 1, ahead: ahead(refs("a"), refs("d"), 1))).moveTo.isNone
    # The waiting post's answer: the server stayed on `d`; nothing pends.
    let settled = fc.reconcileAnswer(CursorAnswer(hasItem: true, item: InboxItem(id: "d"),
      cursorVersion: 2, ahead: ahead(refs("a"), refs("d"), 2)))
    check not fc.pending
    check settled.moveTo.isNone           # already on screen
    check fc.inFlight == 0

  test "a pending press whose answer lands elsewhere moves the screen there":
    var lone = newFastCursor()
    let p = lone.press(three, pdNext)     # no ahead at all yet
    check p.pending
    let landed = lone.reconcileAnswer(CursorAnswer(hasItem: true, item: InboxItem(id: "a"),
      cursorVersion: 1, ahead: ahead(refs("b"), refs("c"), 1)))
    check landed.moveTo == r("a")
    check lone.onScreen == r("a")
    check lone.press(three, pdNext).target == r("b")

  test "an ahead target that left the inbox makes the press wait rather than guess":
    let shrunk = snapshotOf("b", "c")     # `a` was answered elsewhere
    let p = fc.press(shrunk, pdNext)
    check p.pending
    check not p.switched

  test "a server that disagrees never moves the item on screen; the next press follows the server":
    discard fc.press(three, pdNext)       # a
    let r1 = fc.reconcileAnswer(CursorAnswer(hasItem: true, item: InboxItem(id: "b"),
      cursorVersion: 1, ahead: ahead(refs("c"), refs("b"), 1)))
    check r1.moveTo.isNone
    check fc.onScreen == r("a")
    check fc.press(three, pdNext).target == r("c")

  test "answers to earlier presses do not overwrite the targets of later ones":
    discard fc.press(three, pdNext)       # a
    discard fc.press(three, pdNext)       # b
    # The answer to the first press: its ahead is from `a`, not from `b`.
    discard fc.reconcileAnswer(CursorAnswer(hasItem: true, item: InboxItem(id: "a"),
      cursorVersion: 1, ahead: ahead(refs("b", "a", "b"), refs("c"), 1)))
    check fc.press(three, pdNext).target == r("a")   # from `b`, by the order held

  test "a move made on another device moves the screen when the operator has not pressed since":
    let other = fc.reconcileNotice(CursorNotice(name: "default", item: r("b"),
      cursorVersion: 1, ahead: ahead(refs("a"), refs("c"), 1)), three)
    check other.moveTo == r("b")
    check fc.onScreen == r("b")
    check fc.press(three, pdNext).target == r("a")

  test "a move told on the stream while this front-end's own presses are in flight leaves the screen alone":
    discard fc.press(three, pdNext)       # a, posted, unanswered
    # Another device's newer move to another item: the operator's own press
    # wins, and its answer, not the frame, settles the cursor.
    let elsewhere = fc.reconcileNotice(CursorNotice(name: "default", item: r("c"),
      cursorVersion: 5, ahead: ahead(refs("a"), refs("b"), 5)), three)
    check elsewhere.moveTo.isNone
    check fc.onScreen == r("a")
    check fc.heldAhead.next == refs("b", "a")
    let told = fc.reconcileNotice(CursorNotice(name: "default", item: r("a"),
      cursorVersion: 1, ahead: ahead(refs("b"), refs("c"), 1)), three)
    check told.moveTo.isNone
    check fc.onScreen == r("a")
    # The same move's answer arrives after its frame: nothing moves either.
    check fc.reconcileAnswer(CursorAnswer(hasItem: true, item: InboxItem(id: "a"),
      cursorVersion: 1, ahead: ahead(refs("b"), refs("c"), 1))).moveTo.isNone
    # A stale frame (an older version) changes nothing.
    check fc.reconcileNotice(CursorNotice(name: "default", item: r("c"),
      cursorVersion: 0), three).moveTo.isNone
    check fc.onScreen == r("a")

  test "a remote move to an item this front-end does not hold is not followed":
    check fc.reconcileNotice(CursorNotice(name: "default", item: r("z"),
      cursorVersion: 1), three).moveTo.isNone

  test "right after the inbox changed, a press waits rather than switch to a target of the order before":
    # An item arrives on top: by the targets held Next would go to `a`, but
    # the server's Next goes to the new top.
    let four = snapshotOf("n", "a", "b", "c")
    fc.forgetAhead()
    check not fc.heldAhead.known
    let p = fc.press(four, pdNext)
    check p.posts
    check p.pending
    check not p.switched
    check fc.onScreen.isNone
    let landed = fc.reconcileAnswer(CursorAnswer(hasItem: true, item: InboxItem(id: "n"),
      cursorVersion: 1, ahead: ahead(refs("a", "n", "a"), refs("c"), 1)))
    check landed.moveTo == r("n")
    check fc.press(four, pdNext).target == r("a")   # targets again, from the answer

  test "a refused post releases the press that waited for it, and the screen stays":
    for i in 0 ..< 4: discard fc.press(three, pdNext)   # a, b, a; the fourth waits
    check fc.pending
    check fc.inFlight == 4
    fc.reconcileFailure()                 # the first post refused
    check fc.inFlight == 3
    check fc.pending                      # the fourth still waits
    fc.reconcileFailure()
    fc.reconcileFailure()
    fc.reconcileFailure()
    check not fc.pending
    check fc.inFlight == 0
    check fc.onScreen == r("a")
    fc.reconcileFailure()                 # nothing in flight: nothing happens
    check fc.inFlight == 0

  test "negative control: with no items, a press neither switches nor posts":
    let empty = snapshotOf()
    let p = fc.press(empty, pdNext)
    check not p.switched
    check not p.pending
    check not p.posts
    check not fc.press(empty, pdPrev).posts
    check fc.inFlight == 0
