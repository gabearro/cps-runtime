## GUI DSL lexer.

import std/strutils
import ./types

type
  GuiTokenKind* = enum
    gtkEof,
    gtkIdentifier,
    gtkString,
    gtkInt,
    gtkFloat,
    gtkBool,
    gtkLBrace,
    gtkRBrace,
    gtkLParen,
    gtkRParen,
    gtkLBracket,
    gtkRBracket,
    gtkComma,
    gtkColon,
    gtkDot,
    gtkEqual,
    gtkPlus,
    gtkMinus,
    gtkStar,
    gtkSlash,
    gtkArrow,
    gtkQuestion,
    gtkSemicolon,
    gtkBang,
    gtkEqualEqual,
    gtkBangEqual,
    gtkLess,
    gtkLessEqual,
    gtkGreater,
    gtkGreaterEqual,
    gtkAndAnd,
    gtkOrOr,
    gtkQuestionQuestion,
    gtkDotDotDot,
    gtkDotDotLess,
    gtkAt,              # @ for annotations
    gtkBackslash,       # \ for key path expressions
    gtkDollar,          # $ for binding prefix / shorthand params
    gtkHash,            # # for preprocessor directives (#if, #else, #endif)
    gtkStringInterpStart,  # opening part of interpolated string "...\(
    gtkStringInterpMid,    # middle part )...\(
    gtkStringInterpEnd     # closing part )..."

  GuiToken* = object
    kind*: GuiTokenKind
    lexeme*: string
    range*: GuiSourceRange

proc tokenKindText*(k: GuiTokenKind): string =
  case k
  of gtkEof: "eof"
  of gtkIdentifier: "identifier"
  of gtkString: "string"
  of gtkInt: "int"
  of gtkFloat: "float"
  of gtkBool: "bool"
  of gtkLBrace: "{"
  of gtkRBrace: "}"
  of gtkLParen: "("
  of gtkRParen: ")"
  of gtkLBracket: "["
  of gtkRBracket: "]"
  of gtkComma: ","
  of gtkColon: ":"
  of gtkDot: "."
  of gtkEqual: "="
  of gtkPlus: "+"
  of gtkMinus: "-"
  of gtkStar: "*"
  of gtkSlash: "/"
  of gtkArrow: "->"
  of gtkQuestion: "?"
  of gtkSemicolon: ";"
  of gtkBang: "!"
  of gtkEqualEqual: "=="
  of gtkBangEqual: "!="
  of gtkLess: "<"
  of gtkLessEqual: "<="
  of gtkGreater: ">"
  of gtkGreaterEqual: ">="
  of gtkAndAnd: "&&"
  of gtkOrOr: "||"
  of gtkQuestionQuestion: "??"
  of gtkDotDotDot: "..."
  of gtkDotDotLess: "..<"
  of gtkAt: "@"
  of gtkBackslash: "\\"
  of gtkDollar: "$"
  of gtkHash: "#"
  of gtkStringInterpStart: "string_interp_start"
  of gtkStringInterpMid: "string_interp_mid"
  of gtkStringInterpEnd: "string_interp_end"

type
  LexerState = object
    file: string
    input: string
    idx: int
    line: int
    col: int
    markLine: int   # token start position
    markCol: int
    markIdx: int
    diagnostics: seq[GuiDiagnostic]
    tokens: seq[GuiToken]

proc atEnd(s: LexerState): bool {.inline.} =
  s.idx >= s.input.len

proc peek(s: LexerState, offset = 0): char {.inline.} =
  let pos = s.idx + offset
  if pos >= s.input.len: '\0' else: s.input[pos]

proc advance(s: var LexerState): char {.inline.} =
  if s.atEnd:
    return '\0'
  result = s.input[s.idx]
  inc s.idx
  if result == '\n':
    inc s.line
    s.col = 1
  else:
    inc s.col

proc mark(s: var LexerState) {.inline.} =
  s.markLine = s.line
  s.markCol = s.col
  s.markIdx = s.idx

proc addToken(s: var LexerState, kind: GuiTokenKind, text: string) {.inline.} =
  s.tokens.add GuiToken(
    kind: kind,
    lexeme: text,
    range: sourceRange(s.file, s.markLine, s.markCol, s.line, s.col)
  )

proc addTokenAt(
  s: var LexerState,
  kind: GuiTokenKind,
  text: string,
  startLine, startCol: int
) {.inline.} =
  s.tokens.add GuiToken(
    kind: kind,
    lexeme: text,
    range: sourceRange(s.file, startLine, startCol, s.line, s.col)
  )

proc addDiag(s: var LexerState, msg: string, code: string) {.inline.} =
  s.diagnostics.add mkDiagnostic(
    s.file, s.markLine, s.markCol, gsError, msg, code
  )

proc isIdentStart(c: char): bool {.inline.} =
  c == '_' or c.isAlphaAscii

proc isIdentBody(c: char): bool {.inline.} =
  c == '_' or c.isAlphaNumeric

# Forward declarations
proc lexIdentifier(s: var LexerState)
proc lexNumber(s: var LexerState)
proc lexString(s: var LexerState)

proc skipLineComment(s: var LexerState) =
  while not s.atEnd and s.peek() != '\n':
    discard s.advance()

proc skipBlockComment(s: var LexerState) =
  discard s.advance()
  discard s.advance()
  while not s.atEnd:
    if s.peek() == '*' and s.peek(1) == '/':
      discard s.advance()
      discard s.advance()
      return
    discard s.advance()
  s.addDiag("unterminated block comment", "GUI_LEX_BLOCK_COMMENT")

proc matchesWord(s: LexerState, offset: int, word: string): bool {.inline.} =
  ## Check if input at idx+offset matches `word` followed by a non-identifier char.
  for i in 0 ..< word.len:
    if s.peek(offset + i) != word[i]:
      return false
  not s.peek(offset + word.len).isIdentBody

proc lexOperatorOrPunct(s: var LexerState, errCode: string): bool =
  ## Lex operators shared between top-level and interpolation contexts.
  ## Caller must have called mark() before this. Returns true if consumed.
  let c = s.peek()
  case c
  of '+':
    discard s.advance()
    s.addToken(gtkPlus, "+")
  of '*':
    discard s.advance()
    s.addToken(gtkStar, "*")
  of '/':
    discard s.advance()
    s.addToken(gtkSlash, "/")
  of ',':
    discard s.advance()
    s.addToken(gtkComma, ",")
  of ':':
    discard s.advance()
    s.addToken(gtkColon, ":")
  of '[':
    discard s.advance()
    s.addToken(gtkLBracket, "[")
  of ']':
    discard s.advance()
    s.addToken(gtkRBracket, "]")
  of '.':
    discard s.advance()
    s.addToken(gtkDot, ".")
  of '-':
    discard s.advance()
    s.addToken(gtkMinus, "-")
  of '?':
    discard s.advance()
    if s.peek() == '?':
      discard s.advance()
      s.addToken(gtkQuestionQuestion, "??")
    else:
      s.addToken(gtkQuestion, "?")
  of '=':
    discard s.advance()
    if s.peek() == '=':
      discard s.advance()
      s.addToken(gtkEqualEqual, "==")
    else:
      s.addToken(gtkEqual, "=")
  of '!':
    discard s.advance()
    if s.peek() == '=':
      discard s.advance()
      s.addToken(gtkBangEqual, "!=")
    else:
      s.addToken(gtkBang, "!")
  of '<':
    discard s.advance()
    if s.peek() == '=':
      discard s.advance()
      s.addToken(gtkLessEqual, "<=")
    else:
      s.addToken(gtkLess, "<")
  of '>':
    discard s.advance()
    if s.peek() == '=':
      discard s.advance()
      s.addToken(gtkGreaterEqual, ">=")
    else:
      s.addToken(gtkGreater, ">")
  of '&':
    if s.peek(1) == '&':
      discard s.advance()
      discard s.advance()
      s.addToken(gtkAndAnd, "&&")
    else:
      discard s.advance()
      s.addDiag("unexpected character '&'", errCode)
  of '|':
    if s.peek(1) == '|':
      discard s.advance()
      discard s.advance()
      s.addToken(gtkOrOr, "||")
    else:
      discard s.advance()
      s.addDiag("unexpected character '|'", errCode)
  else:
    return false
  return true

proc lexInterpExpr(s: var LexerState) =
  ## Lex tokens inside a string interpolation \(...) expression.
  var depth = 1
  while not s.atEnd and depth > 0:
    let ic = s.peek()
    if ic == ' ' or ic == '\t' or ic == '\r' or ic == '\n':
      discard s.advance()
      continue
    s.mark()
    if ic == '(':
      discard s.advance()
      s.addToken(gtkLParen, "(")
      inc depth
    elif ic == ')':
      discard s.advance()
      dec depth
      if depth == 0:
        break
      s.addToken(gtkRParen, ")")
    elif isIdentStart(ic):
      s.lexIdentifier()
    elif ic.isDigit:
      s.lexNumber()
    elif ic == '"':
      s.lexString()
    elif not s.lexOperatorOrPunct("GUI_LEX_INTERP_CHAR"):
      discard s.advance()
      s.addDiag("unexpected character '" & $ic & "' in string interpolation",
        "GUI_LEX_INTERP_CHAR")
  if depth > 0:
    s.addDiag("unterminated interpolation expression in string",
      "GUI_LEX_INTERP_UNTERM")

proc lexString(s: var LexerState) =
  let strStartLine = s.markLine
  let strStartCol = s.markCol
  discard s.advance() # opening quote
  var text = newStringOfCap(32)
  var terminated = false
  var hasInterp = false
  while not s.atEnd:
    let c = s.peek()
    case c
    of '"':
      discard s.advance()
      terminated = true
      break
    of '\\':
      discard s.advance()
      let esc = s.peek()
      if esc == '(':
        # String interpolation: \(expr)
        discard s.advance()
        if not hasInterp:
          hasInterp = true
          s.addTokenAt(gtkStringInterpStart, text, strStartLine, strStartCol)
        else:
          s.addTokenAt(gtkStringInterpMid, text, strStartLine, strStartCol)
        text = newStringOfCap(32)
        s.lexInterpExpr()
        continue
      else:
        discard s.advance()
        case esc
        of 'n': text.add '\n'
        of 'r': text.add '\r'
        of 't': text.add '\t'
        of '"': text.add '"'
        of '\\': text.add '\\'
        of '0': text.add '\0'
        else: text.add esc
    else:
      text.add s.advance()
  if not terminated:
    s.markLine = strStartLine
    s.markCol = strStartCol
    s.addDiag("unterminated string literal", "GUI_LEX_STRING")
    return
  if hasInterp:
    s.addTokenAt(gtkStringInterpEnd, text, strStartLine, strStartCol)
  else:
    s.addTokenAt(gtkString, text, strStartLine, strStartCol)

proc lexNumber(s: var LexerState) =
  let startIdx = s.markIdx
  var seenDot = false
  while true:
    let c = s.peek()
    if c.isDigit:
      discard s.advance()
    elif c == '.' and not seenDot and s.peek(1).isDigit:
      seenDot = true
      discard s.advance()
    else:
      break
  let text = s.input[startIdx ..< s.idx]
  if seenDot:
    s.addToken(gtkFloat, text)
  else:
    s.addToken(gtkInt, text)

proc lexIdentifier(s: var LexerState) =
  let startIdx = s.markIdx
  discard s.advance()
  while isIdentBody(s.peek()):
    discard s.advance()
  let text = s.input[startIdx ..< s.idx]
  if text == "true" or text == "false":
    s.addToken(gtkBool, text)
  else:
    s.addToken(gtkIdentifier, text)

proc lexGui*(file: string, input: string): tuple[tokens: seq[GuiToken], diagnostics: seq[GuiDiagnostic]] =
  var s = LexerState(file: file, input: input, idx: 0, line: 1, col: 1)

  while not s.atEnd:
    let c = s.peek()

    if c == ' ' or c == '\t' or c == '\r' or c == '\n':
      discard s.advance()
      continue

    s.mark()

    if c == '#':
      if s.matchesWord(1, "if") or s.matchesWord(1, "else") or s.matchesWord(1, "endif"):
        discard s.advance()
        s.addToken(gtkHash, "#")
      else:
        s.skipLineComment()
      continue

    if c == '/' and s.peek(1) == '/':
      s.skipLineComment()
      continue

    if c == '/' and s.peek(1) == '*':
      s.skipBlockComment()
      continue

    if isIdentStart(c):
      s.lexIdentifier()
      continue

    if c.isDigit:
      s.lexNumber()
      continue

    case c
    of '"':
      s.lexString()
    of '{':
      discard s.advance()
      s.addToken(gtkLBrace, "{")
    of '}':
      discard s.advance()
      s.addToken(gtkRBrace, "}")
    of '(':
      discard s.advance()
      s.addToken(gtkLParen, "(")
    of ')':
      discard s.advance()
      s.addToken(gtkRParen, ")")
    of '.':
      if s.peek(1) == '.' and s.peek(2) == '.':
        discard s.advance()
        discard s.advance()
        discard s.advance()
        s.addToken(gtkDotDotDot, "...")
      elif s.peek(1) == '.' and s.peek(2) == '<':
        discard s.advance()
        discard s.advance()
        discard s.advance()
        s.addToken(gtkDotDotLess, "..<")
      else:
        discard s.advance()
        s.addToken(gtkDot, ".")
    of '-':
      if s.peek(1) == '>':
        discard s.advance()
        discard s.advance()
        s.addToken(gtkArrow, "->")
      else:
        discard s.advance()
        s.addToken(gtkMinus, "-")
    of ';':
      discard s.advance()
      s.addToken(gtkSemicolon, ";")
    of '@':
      discard s.advance()
      s.addToken(gtkAt, "@")
    of '\\':
      discard s.advance()
      s.addToken(gtkBackslash, "\\")
    of '$':
      discard s.advance()
      s.addToken(gtkDollar, "$")
    else:
      if not s.lexOperatorOrPunct("GUI_LEX_CHAR"):
        let bad = s.advance()
        s.addDiag("unexpected character '" & $bad & "'", "GUI_LEX_CHAR")

  s.mark()
  s.addToken(gtkEof, "")
  (move s.tokens, move s.diagnostics)
