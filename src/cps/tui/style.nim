## CPS TUI - Terminal Styling
##
## ANSI/SGR escape sequences for colors, attributes, and cursor control.
## Supports 4-bit, 8-bit, and 24-bit (true color) modes.

type
  ColorKind* = enum
    ckNone        ## No color (use terminal default)
    ckBasic       ## 4-bit color (0-15)
    ckPalette     ## 8-bit palette color (0-255)
    ckTrueColor   ## 24-bit RGB

  Color* = object
    case kind*: ColorKind
    of ckNone: discard
    of ckBasic:
      basic*: uint8        ## 0-7 normal, 8-15 bright
    of ckPalette:
      index*: uint8        ## 0-255 palette index
    of ckTrueColor:
      r*, g*, b*: uint8    ## RGB components

  TextAttr* = enum
    taBold
    taDim
    taItalic
    taUnderline
    taStrikethrough
    taBlink
    taReverse
    taHidden

  Style* = object
    fg*: Color
    bg*: Color
    attrs*: set[TextAttr]

proc `==`*(a, b: Color): bool =
  if a.kind != b.kind: return false
  case a.kind
  of ckNone: true
  of ckBasic: a.basic == b.basic
  of ckPalette: a.index == b.index
  of ckTrueColor: a.r == b.r and a.g == b.g and a.b == b.b

proc `==`*(a, b: Style): bool =
  a.fg == b.fg and a.bg == b.bg and a.attrs == b.attrs

type
  BorderStyle* = enum
    bsNone
    bsSingle        ## ┌─┐│└─┘
    bsDouble        ## ╔═╗║╚═╝
    bsRounded       ## ╭─╮│╰─╯
    bsBold          ## ┏━┓┃┗━┛
    bsAscii         ## +-+|+-+

  BorderChars* = object
    topLeft*, topRight*, bottomLeft*, bottomRight*: string
    horizontal*, vertical*: string

# ============================================================
# Color constructors
# ============================================================

proc noColor*(): Color =
  Color(kind: ckNone)

proc color*(idx: uint8): Color =
  ## 4-bit color by index (0-15).
  Color(kind: ckBasic, basic: idx)

proc palette*(idx: uint8): Color =
  ## 8-bit palette color (0-255).
  Color(kind: ckPalette, index: idx)

proc rgb*(r, g, b: uint8): Color =
  Color(kind: ckTrueColor, r: r, g: g, b: b)

proc hex*(code: uint32): Color =
  ## Create RGB color from hex code like 0xFF5733.
  rgb(uint8((code shr 16) and 0xFF),
      uint8((code shr 8) and 0xFF),
      uint8(code and 0xFF))

# Named basic colors
const
  clDefault* = Color(kind: ckNone)
  clBlack* = Color(kind: ckBasic, basic: 0)
  clRed* = Color(kind: ckBasic, basic: 1)
  clGreen* = Color(kind: ckBasic, basic: 2)
  clYellow* = Color(kind: ckBasic, basic: 3)
  clBlue* = Color(kind: ckBasic, basic: 4)
  clMagenta* = Color(kind: ckBasic, basic: 5)
  clCyan* = Color(kind: ckBasic, basic: 6)
  clWhite* = Color(kind: ckBasic, basic: 7)
  clBrightBlack* = Color(kind: ckBasic, basic: 8)
  clBrightRed* = Color(kind: ckBasic, basic: 9)
  clBrightGreen* = Color(kind: ckBasic, basic: 10)
  clBrightYellow* = Color(kind: ckBasic, basic: 11)
  clBrightBlue* = Color(kind: ckBasic, basic: 12)
  clBrightMagenta* = Color(kind: ckBasic, basic: 13)
  clBrightCyan* = Color(kind: ckBasic, basic: 14)
  clBrightWhite* = Color(kind: ckBasic, basic: 15)

# ============================================================
# Style constructors
# ============================================================

proc style*(fg: Color = clDefault, bg: Color = clDefault,
            attrs: set[TextAttr] = {}): Style =
  Style(fg: fg, bg: bg, attrs: attrs)

proc bold*(s: Style): Style =
  result = s
  result.attrs.incl(taBold)

proc dim*(s: Style): Style =
  result = s
  result.attrs.incl(taDim)

proc italic*(s: Style): Style =
  result = s
  result.attrs.incl(taItalic)

proc underline*(s: Style): Style =
  result = s
  result.attrs.incl(taUnderline)

proc reverse*(s: Style): Style =
  result = s
  result.attrs.incl(taReverse)

proc fg*(s: Style, c: Color): Style =
  result = s
  result.fg = c

proc bg*(s: Style, c: Color): Style =
  result = s
  result.bg = c

const
  styleDefault* = Style(fg: clDefault, bg: clDefault, attrs: {})
  styleBold* = Style(fg: clDefault, bg: clDefault, attrs: {taBold})

# ============================================================
# Border character sets
# ============================================================

proc borderChars*(bs: BorderStyle): BorderChars =
  case bs
  of bsNone:
    BorderChars(topLeft: " ", topRight: " ", bottomLeft: " ", bottomRight: " ",
                horizontal: " ", vertical: " ")
  of bsSingle:
    BorderChars(topLeft: "┌", topRight: "┐", bottomLeft: "└", bottomRight: "┘",
                horizontal: "─", vertical: "│")
  of bsDouble:
    BorderChars(topLeft: "╔", topRight: "╗", bottomLeft: "╚", bottomRight: "╝",
                horizontal: "═", vertical: "║")
  of bsRounded:
    BorderChars(topLeft: "╭", topRight: "╮", bottomLeft: "╰", bottomRight: "╯",
                horizontal: "─", vertical: "│")
  of bsBold:
    BorderChars(topLeft: "┏", topRight: "┓", bottomLeft: "┗", bottomRight: "┛",
                horizontal: "━", vertical: "┃")
  of bsAscii:
    BorderChars(topLeft: "+", topRight: "+", bottomLeft: "+", bottomRight: "+",
                horizontal: "-", vertical: "|")

# ============================================================
# ANSI escape generation
# ============================================================

proc fgAnsi*(c: Color): string =
  case c.kind
  of ckNone: ""
  of ckBasic:
    if c.basic < 8: "\e[" & $(30 + c.basic.int) & "m"
    else: "\e[" & $(90 + (c.basic.int - 8)) & "m"
  of ckPalette: "\e[38;5;" & $c.index.int & "m"
  of ckTrueColor: "\e[38;2;" & $c.r.int & ";" & $c.g.int & ";" & $c.b.int & "m"

proc bgAnsi*(c: Color): string =
  case c.kind
  of ckNone: ""
  of ckBasic:
    if c.basic < 8: "\e[" & $(40 + c.basic.int) & "m"
    else: "\e[" & $(100 + (c.basic.int - 8)) & "m"
  of ckPalette: "\e[48;5;" & $c.index.int & "m"
  of ckTrueColor: "\e[48;2;" & $c.r.int & ";" & $c.g.int & ";" & $c.b.int & "m"

proc attrAnsi*(attr: TextAttr): string =
  case attr
  of taBold: "\e[1m"
  of taDim: "\e[2m"
  of taItalic: "\e[3m"
  of taUnderline: "\e[4m"
  of taStrikethrough: "\e[9m"
  of taBlink: "\e[5m"
  of taReverse: "\e[7m"
  of taHidden: "\e[8m"

proc toAnsi*(s: Style): string =
  ## Generate the ANSI escape sequence for this style.
  result = ""
  for attr in s.attrs:
    result.add(attrAnsi(attr))
  result.add(fgAnsi(s.fg))
  result.add(bgAnsi(s.bg))

const resetAnsi* = "\e[0m"

proc styled*(text: string, s: Style): string =
  ## Wrap text in ANSI style escapes + reset.
  let prefix = s.toAnsi()
  if prefix.len == 0:
    text
  else:
    prefix & text & resetAnsi

# ============================================================
# Cursor / screen escape sequences
# ============================================================

proc moveTo*(x, y: int): string =
  ## CSI sequence to move cursor (1-based row,col).
  "\e[" & $(y + 1) & ";" & $(x + 1) & "H"

const
  hideCursor* = "\e[?25l"
  showCursor* = "\e[?25h"
  clearScreen* = "\e[2J"
  clearLine* = "\e[2K"
  enterAltScreen* = "\e[?1049h"
  leaveAltScreen* = "\e[?1049l"
  enableMouse* = "\e[?1000h\e[?1002h\e[?1006h"   ## Button + motion + SGR
  disableMouse* = "\e[?1006l\e[?1002l\e[?1000l"
  enableBracketedPaste* = "\e[?2004h"
  disableBracketedPaste* = "\e[?2004l"
  disableAutoWrap* = "\e[?7l"      ## DECAWM reset — chars past right edge are dropped
  enableAutoWrap* = "\e[?7h"       ## DECAWM set — chars past right edge wrap to next line
  beginSyncUpdate* = "\e[?2026h"   ## DEC private mode 2026 — terminal buffers output
  endSyncUpdate* = "\e[?2026l"     ## Terminal renders buffered output atomically

# ============================================================
# Clipboard via OSC 52
# ============================================================

import std/base64

proc osc52Copy*(text: string): string =
  ## OSC 52 escape sequence to set the system clipboard.
  ## Supported by iTerm2, Kitty, WezTerm, Alacritty, foot, tmux, etc.
  "\e]52;c;" & encode(text) & "\a"
