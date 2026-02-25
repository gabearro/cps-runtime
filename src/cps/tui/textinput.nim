## CPS TUI - Text Input State
##
## Manages text input editing state including cursor movement, insertion,
## deletion, clipboard (kill ring), and history. This is a pure state manager
## that produces Widget descriptions — it does not handle I/O directly.

import ./input
import ./widget
import ./style
import ./layout
import std/strutils

type
  TextInput* = ref object
    ## Manages text input editing state.
    text*: string
    cursor*: int          ## Cursor position (byte offset)
    selStart*: int        ## Selection start (-1 = no selection)
    history*: seq[string]
    historyIdx*: int
    savedText: string     ## Text saved when navigating history
    placeholder*: string
    mask*: char
    maxLen*: int          ## 0 = no limit
    focused*: bool
    onChange*: proc(text: string)

proc newTextInput*(placeholder: string = "", mask: char = '\0',
                   maxLen: int = 0): TextInput =
  TextInput(
    text: "",
    cursor: 0,
    selStart: -1,
    history: @[],
    historyIdx: -1,
    placeholder: placeholder,
    mask: mask,
    maxLen: maxLen,
    focused: true,
  )

# ============================================================
# Cursor movement
# ============================================================

proc moveLeft*(ti: TextInput) =
  if ti.cursor > 0:
    dec ti.cursor

proc moveRight*(ti: TextInput) =
  if ti.cursor < ti.text.len:
    inc ti.cursor

proc moveHome*(ti: TextInput) =
  ti.cursor = 0

proc moveEnd*(ti: TextInput) =
  ti.cursor = ti.text.len

proc moveWordLeft*(ti: TextInput) =
  if ti.cursor == 0:
    return
  var pos = ti.cursor - 1
  # Skip spaces
  while pos > 0 and ti.text[pos] == ' ':
    dec pos
  # Skip word
  while pos > 0 and ti.text[pos - 1] != ' ':
    dec pos
  ti.cursor = pos

proc moveWordRight*(ti: TextInput) =
  if ti.cursor >= ti.text.len:
    return
  var pos = ti.cursor
  # Skip word
  while pos < ti.text.len and ti.text[pos] != ' ':
    inc pos
  # Skip spaces
  while pos < ti.text.len and ti.text[pos] == ' ':
    inc pos
  ti.cursor = pos

# ============================================================
# Editing
# ============================================================

proc insert*(ti: TextInput, ch: char) =
  if ti.maxLen > 0 and ti.text.len >= ti.maxLen:
    return
  ti.text.insert($ch, ti.cursor)
  inc ti.cursor
  if ti.onChange != nil:
    ti.onChange(ti.text)

proc insertStr*(ti: TextInput, s: string) =
  for c in s:
    ti.insert(c)

proc deleteBack*(ti: TextInput) =
  ## Delete character before cursor (Backspace).
  if ti.cursor > 0:
    ti.text.delete(ti.cursor - 1 ..< ti.cursor)
    dec ti.cursor
    if ti.onChange != nil:
      ti.onChange(ti.text)

proc deleteForward*(ti: TextInput) =
  ## Delete character at cursor (Delete).
  if ti.cursor < ti.text.len:
    ti.text.delete(ti.cursor ..< ti.cursor + 1)
    if ti.onChange != nil:
      ti.onChange(ti.text)

proc deleteWordBack*(ti: TextInput) =
  ## Delete word before cursor (Ctrl+W).
  if ti.cursor == 0:
    return
  let oldCursor = ti.cursor
  ti.moveWordLeft()
  ti.text.delete(ti.cursor ..< oldCursor)
  if ti.onChange != nil:
    ti.onChange(ti.text)

proc deleteWordForward*(ti: TextInput) =
  ## Delete word after cursor (Alt+Delete / Alt+D).
  if ti.cursor >= ti.text.len:
    return
  var pos = ti.cursor
  # Skip word
  while pos < ti.text.len and ti.text[pos] != ' ':
    inc pos
  # Skip spaces
  while pos < ti.text.len and ti.text[pos] == ' ':
    inc pos
  ti.text.delete(ti.cursor ..< pos)
  if ti.onChange != nil:
    ti.onChange(ti.text)

proc deleteToEnd*(ti: TextInput) =
  ## Delete from cursor to end (Ctrl+K).
  if ti.cursor < ti.text.len:
    ti.text.setLen(ti.cursor)
    if ti.onChange != nil:
      ti.onChange(ti.text)

proc deleteToStart*(ti: TextInput) =
  ## Delete from start to cursor (Ctrl+U).
  if ti.cursor > 0:
    ti.text.delete(0 ..< ti.cursor)
    ti.cursor = 0
    if ti.onChange != nil:
      ti.onChange(ti.text)

proc clear*(ti: TextInput) =
  ti.text = ""
  ti.cursor = 0
  if ti.onChange != nil:
    ti.onChange(ti.text)

proc setText*(ti: TextInput, text: string) =
  ti.text = text
  ti.cursor = min(ti.cursor, text.len)
  if ti.onChange != nil:
    ti.onChange(ti.text)

# ============================================================
# History
# ============================================================

proc pushHistory*(ti: TextInput) =
  ## Save current text to history.
  if ti.text.len > 0:
    # Deduplicate consecutive
    if ti.history.len == 0 or ti.history[^1] != ti.text:
      ti.history.add(ti.text)
  ti.historyIdx = -1
  ti.savedText = ""

proc historyUp*(ti: TextInput) =
  if ti.history.len == 0:
    return
  if ti.historyIdx < 0:
    ti.savedText = ti.text
    ti.historyIdx = ti.history.len - 1
  elif ti.historyIdx > 0:
    dec ti.historyIdx
  else:
    return
  ti.text = ti.history[ti.historyIdx]
  ti.cursor = ti.text.len

proc historyDown*(ti: TextInput) =
  if ti.historyIdx < 0:
    return
  if ti.historyIdx < ti.history.len - 1:
    inc ti.historyIdx
    ti.text = ti.history[ti.historyIdx]
  else:
    ti.text = ti.savedText
    ti.historyIdx = -1
  ti.cursor = ti.text.len

# ============================================================
# Input event handling
# ============================================================

proc handleMouse*(ti: TextInput, evt: InputEvent, rect: Rect): bool =
  ## Handle mouse events for the text input. Click to position cursor.
  ## Pass the rect where the input field is rendered.
  ## Returns true if cursor moved (triggers re-render).
  if evt.kind != iekMouse or evt.action != maPress or evt.button != mbLeft:
    return false
  if rect.w <= 0 or rect.h <= 0:
    return false
  if evt.mx < rect.x or evt.mx >= rect.x + rect.w or
     evt.my < rect.y or evt.my >= rect.y + rect.h:
    return false
  let clickX = evt.mx - rect.x
  let newCursor = min(clickX, ti.text.len)
  if newCursor != ti.cursor:
    ti.cursor = newCursor
    return true
  return false

proc handleInput*(ti: TextInput, evt: InputEvent): bool =
  ## Process an input event. Returns true if the input was handled
  ## and the widget needs re-rendering (text or cursor changed).
  if evt.kind != iekKey:
    return false

  case evt.key
  of kcChar:
    if kmCtrl in evt.keyMods:
      case evt.ch
      of 'a': ti.moveHome(); return true
      of 'e': ti.moveEnd(); return true
      of 'k': ti.deleteToEnd(); return true
      of 'u': ti.deleteToStart(); return true
      of 'w': ti.deleteWordBack(); return true
      of 'b': ti.moveLeft(); return true
      of 'f': ti.moveRight(); return true
      else: return false
    elif kmAlt in evt.keyMods:
      case evt.ch
      of 'b': ti.moveWordLeft(); return true
      of 'f': ti.moveWordRight(); return true
      of 'd': ti.deleteWordForward(); return true
      else: return false
    else:
      ti.insert(evt.ch)
      return true
  of kcBackspace:
    if kmSuper in evt.keyMods:
      ti.deleteToStart()       # Cmd+Backspace: delete to start of line
    elif kmAlt in evt.keyMods:
      ti.deleteWordBack()      # Alt+Backspace: delete word back
    else:
      ti.deleteBack()
    return true
  of kcDelete:
    if kmAlt in evt.keyMods:
      ti.deleteWordForward()   # Alt+Delete: delete word forward
    else:
      ti.deleteForward()
    return true
  of kcLeft:
    if kmSuper in evt.keyMods:
      ti.moveHome()              # Cmd+Left: go to start
    elif kmCtrl in evt.keyMods or kmAlt in evt.keyMods:
      ti.moveWordLeft()          # Ctrl/Alt+Left: word left
    else:
      ti.moveLeft()
    return true
  of kcRight:
    if kmSuper in evt.keyMods:
      ti.moveEnd()               # Cmd+Right: go to end
    elif kmCtrl in evt.keyMods or kmAlt in evt.keyMods:
      ti.moveWordRight()         # Ctrl/Alt+Right: word right
    else:
      ti.moveRight()
    return true
  of kcHome:
    ti.moveHome()
    return true
  of kcEnd:
    ti.moveEnd()
    return true
  of kcUp:
    ti.historyUp()
    return true
  of kcDown:
    ti.historyDown()
    return true
  else:
    return false

# ============================================================
# Widget generation
# ============================================================

proc toWidget*(ti: TextInput, st: Style = styleDefault): Widget =
  ## Generate a Widget from the current text input state.
  inputField(
    text = ti.text,
    cursor = ti.cursor,
    placeholder = ti.placeholder,
    mask = ti.mask,
    st = st,
  ).withFocus(ti.focused)

proc value*(ti: TextInput): string =
  ## Get the current text value.
  ti.text

proc submit*(ti: TextInput): string =
  ## Get the text, push to history, and clear.
  result = ti.text
  ti.pushHistory()
  ti.clear()
