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
    diagnostics: seq[GuiDiagnostic]
    tokens: seq[GuiToken]

proc atEnd(s: LexerState): bool {.inline.} =
  s.idx >= s.input.len

proc peek(s: LexerState, offset = 0): char {.inline.} =
  let pos = s.idx + offset
  if pos < 0 or pos >= s.input.len:
    '\0'
  else:
    s.input[pos]

proc advance(s: var LexerState): char =
  if s.atEnd:
    return '\0'
  result = s.input[s.idx]
  inc s.idx
  if result == '\n':
    inc s.line
    s.col = 1
  else:
    inc s.col

proc addToken(
  s: var LexerState,
  kind: GuiTokenKind,
  text: string,
  startLine: int,
  startCol: int,
  endLine: int,
  endCol: int
) =
  s.tokens.add GuiToken(
    kind: kind,
    lexeme: text,
    range: sourceRange(s.file, startLine, startCol, endLine, endCol)
  )

proc addDiag(
  s: var LexerState,
  startLine: int,
  startCol: int,
  msg: string,
  code: string
) =
  s.diagnostics.add mkDiagnostic(
    s.file,
    startLine,
    startCol,
    gsError,
    msg,
    code
  )

proc isIdentStart(c: char): bool {.inline.} =
  c == '_' or c.isAlphaAscii

proc isIdentBody(c: char): bool {.inline.} =
  c == '_' or c.isAlphaNumeric

# Forward declarations for mutual recursion (lexString calls lexIdentifier/lexNumber)
proc lexIdentifier(s: var LexerState, startLine: int, startCol: int)
proc lexNumber(s: var LexerState, startLine: int, startCol: int)

proc skipLineComment(s: var LexerState) =
  while not s.atEnd and s.peek() != '\n':
    discard s.advance()

proc skipBlockComment(s: var LexerState, startLine: int, startCol: int) =
  discard s.advance()
  discard s.advance()
  while not s.atEnd:
    if s.peek() == '*' and s.peek(1) == '/':
      discard s.advance()
      discard s.advance()
      return
    discard s.advance()
  s.addDiag(startLine, startCol, "unterminated block comment", "GUI_LEX_BLOCK_COMMENT")

proc lexString(s: var LexerState, startLine: int, startCol: int) =
  discard s.advance() # opening quote
  var text = ""
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
          # First interpolation — emit opening part
          hasInterp = true
          s.addToken(gtkStringInterpStart, text, startLine, startCol, s.line, s.col)
        else:
          # Middle interpolation — emit mid part
          s.addToken(gtkStringInterpMid, text, startLine, startCol, s.line, s.col)
        text = ""
        # Now lex tokens until matching ')' for the expression
        var depth = 1
        while not s.atEnd and depth > 0:
          let innerStart = s.line
          let innerCol = s.col
          let ic = s.peek()
          if ic in {' ', '\t', '\r', '\n'}:
            discard s.advance()
            continue
          if ic == '(':
            discard s.advance()
            s.addToken(gtkLParen, "(", innerStart, innerCol, s.line, s.col)
            inc depth
          elif ic == ')':
            discard s.advance()
            dec depth
            if depth == 0:
              break
            s.addToken(gtkRParen, ")", innerStart, innerCol, s.line, s.col)
          elif isIdentStart(ic):
            s.lexIdentifier(innerStart, innerCol)
          elif ic.isDigit:
            s.lexNumber(innerStart, innerCol)
          elif ic == '"':
            s.lexString(innerStart, innerCol)
          elif ic == '.':
            discard s.advance()
            s.addToken(gtkDot, ".", innerStart, innerCol, s.line, s.col)
          elif ic == '+':
            discard s.advance()
            s.addToken(gtkPlus, "+", innerStart, innerCol, s.line, s.col)
          elif ic == '-':
            discard s.advance()
            s.addToken(gtkMinus, "-", innerStart, innerCol, s.line, s.col)
          elif ic == '*':
            discard s.advance()
            s.addToken(gtkStar, "*", innerStart, innerCol, s.line, s.col)
          elif ic == '/':
            discard s.advance()
            s.addToken(gtkSlash, "/", innerStart, innerCol, s.line, s.col)
          elif ic == ',':
            discard s.advance()
            s.addToken(gtkComma, ",", innerStart, innerCol, s.line, s.col)
          elif ic == ':':
            discard s.advance()
            s.addToken(gtkColon, ":", innerStart, innerCol, s.line, s.col)
          elif ic == '[':
            discard s.advance()
            s.addToken(gtkLBracket, "[", innerStart, innerCol, s.line, s.col)
          elif ic == ']':
            discard s.advance()
            s.addToken(gtkRBracket, "]", innerStart, innerCol, s.line, s.col)
          elif ic == '?' and s.peek(1) == '?':
            discard s.advance()
            discard s.advance()
            s.addToken(gtkQuestionQuestion, "??", innerStart, innerCol, s.line, s.col)
          elif ic == '?':
            discard s.advance()
            s.addToken(gtkQuestion, "?", innerStart, innerCol, s.line, s.col)
          elif ic == '=' and s.peek(1) == '=':
            discard s.advance()
            discard s.advance()
            s.addToken(gtkEqualEqual, "==", innerStart, innerCol, s.line, s.col)
          elif ic == '!' and s.peek(1) == '=':
            discard s.advance()
            discard s.advance()
            s.addToken(gtkBangEqual, "!=", innerStart, innerCol, s.line, s.col)
          elif ic == '!':
            discard s.advance()
            s.addToken(gtkBang, "!", innerStart, innerCol, s.line, s.col)
          elif ic == '<' and s.peek(1) == '=':
            discard s.advance()
            discard s.advance()
            s.addToken(gtkLessEqual, "<=", innerStart, innerCol, s.line, s.col)
          elif ic == '<':
            discard s.advance()
            s.addToken(gtkLess, "<", innerStart, innerCol, s.line, s.col)
          elif ic == '>' and s.peek(1) == '=':
            discard s.advance()
            discard s.advance()
            s.addToken(gtkGreaterEqual, ">=", innerStart, innerCol, s.line, s.col)
          elif ic == '>':
            discard s.advance()
            s.addToken(gtkGreater, ">", innerStart, innerCol, s.line, s.col)
          elif ic == '&' and s.peek(1) == '&':
            discard s.advance()
            discard s.advance()
            s.addToken(gtkAndAnd, "&&", innerStart, innerCol, s.line, s.col)
          elif ic == '|' and s.peek(1) == '|':
            discard s.advance()
            discard s.advance()
            s.addToken(gtkOrOr, "||", innerStart, innerCol, s.line, s.col)
          else:
            discard s.advance()
            s.addDiag(innerStart, innerCol,
              "unexpected character '" & $ic & "' in string interpolation",
              "GUI_LEX_INTERP_CHAR")
        if depth > 0:
          s.addDiag(startLine, startCol,
            "unterminated interpolation expression in string",
            "GUI_LEX_INTERP_UNTERM")
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
        else:
          text.add esc
    else:
      text.add s.advance()
  if not terminated:
    s.addDiag(startLine, startCol, "unterminated string literal", "GUI_LEX_STRING")
    return
  if hasInterp:
    s.addToken(gtkStringInterpEnd, text, startLine, startCol, s.line, s.col)
  else:
    s.addToken(gtkString, text, startLine, startCol, s.line, s.col)

proc lexNumber(s: var LexerState, startLine: int, startCol: int) =
  var text = ""
  var seenDot = false
  while true:
    let c = s.peek()
    if c.isDigit:
      text.add s.advance()
      continue
    if c == '.' and not seenDot and s.peek(1).isDigit:
      seenDot = true
      text.add s.advance()
      continue
    break
  if seenDot:
    s.addToken(gtkFloat, text, startLine, startCol, s.line, s.col)
  else:
    s.addToken(gtkInt, text, startLine, startCol, s.line, s.col)

proc lexIdentifier(s: var LexerState, startLine: int, startCol: int) =
  var text = ""
  text.add s.advance()
  while isIdentBody(s.peek()):
    text.add s.advance()
  if text == "true" or text == "false":
    s.addToken(gtkBool, text, startLine, startCol, s.line, s.col)
  else:
    s.addToken(gtkIdentifier, text, startLine, startCol, s.line, s.col)

proc lexGui*(file: string, input: string): tuple[tokens: seq[GuiToken], diagnostics: seq[GuiDiagnostic]] =
  var s = LexerState(file: file, input: input, idx: 0, line: 1, col: 1)

  while not s.atEnd:
    let startLine = s.line
    let startCol = s.col
    let c = s.peek()

    if c in {' ', '\t', '\r', '\n'}:
      discard s.advance()
      continue

    if c == '#':
      # #if / #else are platform conditional directives, not comments
      if s.peek(1) in {'i', 'e'}:  # #if, #else
        discard s.advance()
        s.addToken(gtkHash, "#", startLine, startCol, s.line, s.col)
      else:
        s.skipLineComment()
      continue

    if c == '/' and s.peek(1) == '/':
      s.skipLineComment()
      continue

    if c == '/' and s.peek(1) == '*':
      s.skipBlockComment(startLine, startCol)
      continue

    if isIdentStart(c):
      s.lexIdentifier(startLine, startCol)
      continue

    if c.isDigit:
      s.lexNumber(startLine, startCol)
      continue

    case c
    of '"':
      s.lexString(startLine, startCol)
    of '{':
      discard s.advance()
      s.addToken(gtkLBrace, "{", startLine, startCol, s.line, s.col)
    of '}':
      discard s.advance()
      s.addToken(gtkRBrace, "}", startLine, startCol, s.line, s.col)
    of '(':
      discard s.advance()
      s.addToken(gtkLParen, "(", startLine, startCol, s.line, s.col)
    of ')':
      discard s.advance()
      s.addToken(gtkRParen, ")", startLine, startCol, s.line, s.col)
    of '[':
      discard s.advance()
      s.addToken(gtkLBracket, "[", startLine, startCol, s.line, s.col)
    of ']':
      discard s.advance()
      s.addToken(gtkRBracket, "]", startLine, startCol, s.line, s.col)
    of ',':
      discard s.advance()
      s.addToken(gtkComma, ",", startLine, startCol, s.line, s.col)
    of ':':
      discard s.advance()
      s.addToken(gtkColon, ":", startLine, startCol, s.line, s.col)
    of '.':
      if s.peek(1) == '.' and s.peek(2) == '.':
        discard s.advance()
        discard s.advance()
        discard s.advance()
        s.addToken(gtkDotDotDot, "...", startLine, startCol, s.line, s.col)
      elif s.peek(1) == '.' and s.peek(2) == '<':
        discard s.advance()
        discard s.advance()
        discard s.advance()
        s.addToken(gtkDotDotLess, "..<", startLine, startCol, s.line, s.col)
      else:
        discard s.advance()
        s.addToken(gtkDot, ".", startLine, startCol, s.line, s.col)
    of '=':
      discard s.advance()
      if s.peek() == '=':
        discard s.advance()
        s.addToken(gtkEqualEqual, "==", startLine, startCol, s.line, s.col)
      else:
        s.addToken(gtkEqual, "=", startLine, startCol, s.line, s.col)
    of '!':
      discard s.advance()
      if s.peek() == '=':
        discard s.advance()
        s.addToken(gtkBangEqual, "!=", startLine, startCol, s.line, s.col)
      else:
        s.addToken(gtkBang, "!", startLine, startCol, s.line, s.col)
    of '+':
      discard s.advance()
      s.addToken(gtkPlus, "+", startLine, startCol, s.line, s.col)
    of '-':
      if s.peek(1) == '>':
        discard s.advance()
        discard s.advance()
        s.addToken(gtkArrow, "->", startLine, startCol, s.line, s.col)
      else:
        discard s.advance()
        s.addToken(gtkMinus, "-", startLine, startCol, s.line, s.col)
    of '*':
      discard s.advance()
      s.addToken(gtkStar, "*", startLine, startCol, s.line, s.col)
    of '/':
      discard s.advance()
      s.addToken(gtkSlash, "/", startLine, startCol, s.line, s.col)
    of '?':
      discard s.advance()
      if s.peek() == '?':
        discard s.advance()
        s.addToken(gtkQuestionQuestion, "??", startLine, startCol, s.line, s.col)
      else:
        s.addToken(gtkQuestion, "?", startLine, startCol, s.line, s.col)
    of '<':
      discard s.advance()
      if s.peek() == '=':
        discard s.advance()
        s.addToken(gtkLessEqual, "<=", startLine, startCol, s.line, s.col)
      else:
        s.addToken(gtkLess, "<", startLine, startCol, s.line, s.col)
    of '>':
      discard s.advance()
      if s.peek() == '=':
        discard s.advance()
        s.addToken(gtkGreaterEqual, ">=", startLine, startCol, s.line, s.col)
      else:
        s.addToken(gtkGreater, ">", startLine, startCol, s.line, s.col)
    of '&':
      if s.peek(1) == '&':
        discard s.advance()
        discard s.advance()
        s.addToken(gtkAndAnd, "&&", startLine, startCol, s.line, s.col)
      else:
        let bad = s.advance()
        s.addDiag(startLine, startCol, "unexpected character '" & $bad & "'", "GUI_LEX_CHAR")
    of '|':
      if s.peek(1) == '|':
        discard s.advance()
        discard s.advance()
        s.addToken(gtkOrOr, "||", startLine, startCol, s.line, s.col)
      else:
        let bad = s.advance()
        s.addDiag(startLine, startCol, "unexpected character '" & $bad & "'", "GUI_LEX_CHAR")
    of ';':
      discard s.advance()
      s.addToken(gtkSemicolon, ";", startLine, startCol, s.line, s.col)
    of '@':
      discard s.advance()
      s.addToken(gtkAt, "@", startLine, startCol, s.line, s.col)
    of '\\':
      # Backslash outside of string context → key path prefix
      discard s.advance()
      s.addToken(gtkBackslash, "\\", startLine, startCol, s.line, s.col)
    of '$':
      discard s.advance()
      s.addToken(gtkDollar, "$", startLine, startCol, s.line, s.col)
    of '#':
      discard s.advance()
      s.addToken(gtkHash, "#", startLine, startCol, s.line, s.col)
    else:
      let bad = s.advance()
      s.addDiag(startLine, startCol, "unexpected character '" & $bad & "'", "GUI_LEX_CHAR")

  s.addToken(gtkEof, "", s.line, s.col, s.line, s.col)
  (s.tokens, s.diagnostics)
