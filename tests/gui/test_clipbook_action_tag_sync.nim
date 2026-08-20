import std/strutils

proc appStateConstName(name: string): string =
  if name.len == 0:
    return ""
  result = "fld" & $name[0].toUpperAscii
  if name.len > 1:
    result.add(name[1 .. ^1])

proc actionName(line: string): string =
  let stripped = line.strip()
  if not stripped.startsWith("action "):
    return ""
  var rest = stripped["action ".len .. ^1]
  let paren = rest.find('(')
  let space = rest.find(' ')
  var stop = rest.len
  if paren >= 0:
    stop = min(stop, paren)
  if space >= 0:
    stop = min(stop, space)
  rest[0 ..< stop]

proc stateName(line: string): string =
  let stripped = line.strip()
  if stripped.len == 0 or stripped.startsWith("#") or stripped.startsWith("computed "):
    return ""
  let colon = stripped.find(':')
  if colon < 0:
    return ""
  stripped[0 ..< colon].strip()

proc bridgeConst(line, prefix: string): tuple[name: string, value: int] =
  let stripped = line.strip()
  if not stripped.startsWith(prefix) or "=" notin stripped:
    return (name: "", value: -1)
  let parts = stripped.split("=", 1)
  let name = parts[0].strip()
  var rawValue = parts[1].strip()
  let tick = rawValue.find('\'')
  if tick >= 0:
    rawValue = rawValue[0 ..< tick]
  let comment = rawValue.find('#')
  if comment >= 0:
    rawValue = rawValue[0 ..< comment]
  (name: name, value: parseInt(rawValue.strip()))

proc bridgeTag(line: string): tuple[name: string, value: int] =
  let parsed = bridgeConst(line, "tag")
  if parsed.name.len == 0:
    return parsed
  (name: parsed.name["tag".len .. ^1], value: parsed.value)

proc bridgeField(line: string): tuple[name: string, value: int] =
  bridgeConst(line, "fld")

let appPath = "examples/gui/clipbook/app.gui"
let bridgePath = "examples/gui/clipbook/bridge.nim"

var actions: seq[string]
var fields: seq[string]
var inState = false
var stateDepth = 0
for line in lines(appPath):
  let stripped = line.strip()
  if stripped == "state {":
    inState = true
    stateDepth = 1
    continue
  if inState:
    if "{" in stripped:
      inc stateDepth
    if "}" in stripped:
      dec stateDepth
      if stateDepth <= 0:
        inState = false
      continue
    let name = stateName(line)
    if name.len > 0:
      fields.add(appStateConstName(name))

  let name = actionName(line)
  if name.len > 0:
    actions.add(name)

var tags: seq[tuple[name: string, value: int]]
var bridgeFields: seq[tuple[name: string, value: int]]
var inActionTags = false
var inFieldIds = false
for line in lines(bridgePath):
  if "Action tags" in line:
    inActionTags = true
    continue
  if inActionTags and "Binary field IDs" in line:
    inActionTags = false
    inFieldIds = true
    continue
  if inFieldIds and "Binary wire value types" in line:
    break
  if inActionTags:
    let tag = bridgeTag(line)
    if tag.name.len > 0:
      tags.add(tag)
  elif inFieldIds:
    let field = bridgeField(line)
    if field.name.len > 0:
      bridgeFields.add(field)

assert actions.len == tags.len,
  "ClipBook bridge action count mismatch: app.gui=" & $actions.len &
    " bridge.nim=" & $tags.len

for i, action in actions:
  assert tags[i].name == action,
    "ClipBook bridge action mismatch at index " & $i &
      ": app.gui=" & action & " bridge.nim=" & tags[i].name
  assert tags[i].value == i,
    "ClipBook bridge tag value mismatch for " & action &
      ": expected " & $i & " got " & $tags[i].value

assert fields.len == bridgeFields.len,
  "ClipBook bridge field count mismatch: app.gui=" & $fields.len &
    " bridge.nim=" & $bridgeFields.len

for i, field in fields:
  assert bridgeFields[i].name == field,
    "ClipBook bridge field mismatch at index " & $i &
      ": app.gui=" & field & " bridge.nim=" & bridgeFields[i].name
  assert bridgeFields[i].value == i + 1,
    "ClipBook bridge field value mismatch for " & field &
      ": expected " & $(i + 1) & " got " & $bridgeFields[i].value

echo "PASS: ClipBook action tags and field IDs match app.gui"
