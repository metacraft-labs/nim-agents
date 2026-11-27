## The two ways a viewmodel asks its host to open something
## (`nim_agents/trace_open`, `nim_agents/review_open`), native and JS: a
## request reaches the host's proc unchanged, and a viewmodel with no host, or
## a host with no proc, gets silence rather than a crash. The data is invented,
## as everything in this public repository.

import std/unittest
import nim_agents/[review_open, trace_open]

suite "open services":
  test "a trace request reaches the host unchanged":
    var seen: seq[TraceOpenRequest]
    let service = TraceOpenService(
      openProc: proc(request: TraceOpenRequest) = seen.add request)
    let request = TraceOpenRequest(tracePath: "/tmp/t.ct", traceId: "7",
                                   recordingId: "r-1", testId: "a::b",
                                   policy: topNewTab)
    service.openTrace request
    check seen.len == 1
    check seen[0] == request

  test "the open policy is spelt as the CLI spells it":
    check $topCurrentTab == "current-tab"
    check $topNewTab == "new-tab"

  test "a trace request with no host is silence":
    TraceOpenService(nil).openTrace TraceOpenRequest(tracePath: "/tmp/t.ct")
    TraceOpenService().openTrace TraceOpenRequest(tracePath: "/tmp/t.ct")

  test "a review request reaches the host unchanged":
    var seen: seq[ReviewDatasetRequest]
    let service = ReviewOpenService(
      requestProc: proc(request: ReviewDatasetRequest) = seen.add request)
    let request = ReviewDatasetRequest(anchorId: "m-3",
                                       datasetPath: "out/review.json",
                                       kind: rdrOpen)
    service.requestDataset request
    check seen.len == 1
    check seen[0] == request

  test "the request kinds are spelt as the wire spells them":
    check $rdrInspect == "inspect"
    check $rdrOpen == "open"

  test "a review request with no host is silence":
    ReviewOpenService(nil).requestDataset ReviewDatasetRequest(datasetPath: "x")
    ReviewOpenService().requestDataset ReviewDatasetRequest(datasetPath: "x")
