import std/strutils
import unittest
import nim_agents

proc isonimEditorConsumerSmoke(): bool =
  let item = textBlock("selected story: Button/Primary")
  item.kind == cbText and item.text.len > 0

proc codeTracerConsumerSmoke(): bool =
  let item = resourceBlock("file:///tmp/trace.json", "application/json")
  item.kind == cbResource and item.uri.startsWith("file://")

suite "consumer smoke tests":
  test "nim_agents_supports_isonim_editor_and_codetracer_consumers":
    check isonimEditorConsumerSmoke()
    check codeTracerConsumerSmoke()
