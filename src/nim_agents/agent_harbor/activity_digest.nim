## A session's recent activity reduced to the few lines a session row or tab
## tooltip has room for: repeats collapsed, low-information events (status
## changes, resumptions, the routine "waiting for input" of an ended turn)
## ranked below the events that say what the session is doing or why it
## stopped. Signal-free; any sessions view uses it.
##
## Ranking is a policy (`ActivityRanking`): `arInformative` prefers the most
## informative recent event (a failure, a question, a log line the agent
## wrote), `arNewest` keeps plain recency, which is what a raw event feed
## shows.

import std/strutils
import ./fleet_records

export fleet_records

type
  ActivityRanking* = enum
    arInformative ## most informative first, recency breaking ties
    arNewest      ## newest first

  DigestLine* = object
    text*: string
    level*: string         ## a log line's level (`error` is shown as one)
    kind*: FleetActivityKind
    count*: int            ## how many collapsed events the line stands for
    newestMs*: int64
    informative*: bool     ## not a routine status, resumption or wait line

proc informationRank*(event: FleetActivity): int =
  ## Higher says more. A scrubbed or empty line says nothing.
  if event.text.strip.len == 0 or event.text.startsWith("[scrubbed"): return 0
  case event.kind
  of fakLog:
    if event.level == "error": 9
    elif event.level == "warn": 7
    else: 6
  of fakQuestion: 8
  of fakToolResult:
    if event.level == "error": 8 else: 4
  of fakToolUse, fakFileEdit, fakPlan: 6
  of fakFileRead, fakUserInput, fakOrchestration: 5
  of fakOther: 4
  of fakThought: 3
  of fakAntiHalting: 3
  of fakAwaitingInput: 2
  of fakStatus: 2
  of fakResumed: 1

proc digestActivity*(recentOldestFirst: openArray[FleetActivity];
                     ranking = arInformative;
                     currentStatus = ""): seq[DigestLine] =
  ## Every distinct line of `recentOldestFirst` once, with the number of
  ## events it stands for (identical text and level collapse wherever they
  ## occur, not only when adjacent: a session that resumed three times between
  ## two waits reads "Resumed by human ×3"), ordered by `ranking`. Given the
  ## `currentStatus` a row already shows, status events are left out: one
  ## that repeats it says nothing, and an older one contradicts it (a failed
  ## row reading "Status: running").
  for i in countdown(recentOldestFirst.high, 0):
    let event = recentOldestFirst[i]
    let rank = informationRank(event)
    if rank == 0: continue
    if event.kind == fakStatus and currentStatus.len > 0: continue
    var merged = false
    for line in result.mitems:
      if line.text == event.text and line.level == event.level:
        inc line.count
        merged = true
        break
    if not merged:
      result.add DigestLine(text: event.text, level: event.level,
                            kind: event.kind, count: 1,
                            newestMs: event.timestampMs,
                            informative: rank >= 4)
  if ranking == arInformative:
    # A stable insertion sort by rank: equal ranks keep newest-first order.
    for i in 1 ..< result.len:
      var j = i
      while j > 0 and informationRank(FleetActivity(kind: result[j].kind,
          text: result[j].text, level: result[j].level)) >
          informationRank(FleetActivity(kind: result[j - 1].kind,
          text: result[j - 1].text, level: result[j - 1].level)):
        swap(result[j], result[j - 1])
        dec j

proc lineText*(line: DigestLine): string =
  ## The line as shown: `Resumed by human ×3`.
  if line.count > 1: line.text & " \xC3\x97" & $line.count else: line.text
