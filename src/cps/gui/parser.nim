## GUI DSL parser and module loader (with include/glob support).

import std/[os, strutils, algorithm, sets]
import ./types
import ./ast
import ./lexer

type
  ParserState = object
    file: string
    tokens: seq[GuiToken]
    idx: int
    diagnostics: seq[GuiDiagnostic]
    noTrailingClosures: bool  ## Suppress trailing closure parsing (e.g., in if conditions)

const
  topDeclKeywords = [
    "include", "app", "tokens", "model", "enum", "state", "action",
    "reducer", "navigation", "component", "modifier", "escape", "bridge", "window",
    "settings"
  ]

proc curr(p: ParserState): GuiToken {.inline.} =
  if p.idx < p.tokens.len:
    p.tokens[p.idx]
  else:
    p.tokens[^1]

proc prev(p: ParserState): GuiToken {.inline.} =
  if p.idx <= 0:
    p.tokens[0]
  else:
    p.tokens[p.idx - 1]

proc peekToken(p: ParserState, offset: int): GuiToken {.inline.} =
  let pos = p.idx + offset
  if pos >= 0 and pos < p.tokens.len:
    p.tokens[pos]
  else:
    p.tokens[^1]

proc atEnd(p: ParserState): bool {.inline.} =
  p.curr.kind == gtkEof

proc atKind(p: ParserState, kind: GuiTokenKind): bool {.inline.} =
  p.curr.kind == kind

proc atIdent(p: ParserState, value: string): bool {.inline.} =
  p.curr.kind == gtkIdentifier and p.curr.lexeme == value

proc advance(p: var ParserState): GuiToken =
  if not p.atEnd:
    inc p.idx
  p.prev

proc matchKind(p: var ParserState, kind: GuiTokenKind): bool =
  if p.atKind(kind):
    discard p.advance()
    return true
  false

proc addDiag(p: var ParserState, range: GuiSourceRange, message: string, code: string) =
  p.diagnostics.add mkDiagnostic(range, gsError, message, code)

proc addDiagTok(p: var ParserState, tok: GuiToken, message: string, code: string) =
  p.addDiag(tok.range, message, code)

proc expectKind(p: var ParserState, kind: GuiTokenKind, context: string): GuiToken =
  if p.atKind(kind):
    return p.advance()
  let tok = p.curr
  p.addDiagTok(
    tok,
    "expected " & tokenKindText(kind) & " " & context & ", got " & tokenKindText(tok.kind),
    "GUI_PARSE_EXPECT"
  )
  tok

proc expectIdentifier(p: var ParserState, context: string): GuiToken =
  if p.atKind(gtkIdentifier):
    return p.advance()
  let tok = p.curr
  p.addDiagTok(tok, "expected identifier " & context, "GUI_PARSE_IDENT")
  tok

proc optionalDelimiter(p: var ParserState) =
  discard p.matchKind(gtkComma)
  discard p.matchKind(gtkSemicolon)

proc synchronizeToDeclBoundary(p: var ParserState) =
  while not p.atEnd:
    if p.atKind(gtkRBrace):
      return
    if p.curr.kind == gtkIdentifier and p.curr.lexeme in topDeclKeywords:
      return
    discard p.advance()

proc parseIdentifierPath(p: var ParserState): tuple[path: seq[string], range: GuiSourceRange] =
  let first = p.expectIdentifier("in identifier path")
  result.path.add first.lexeme
  result.range = first.range
  while p.matchKind(gtkDot):
    let nextPart = p.expectIdentifier("after '.'")
    result.path.add nextPart.lexeme
    result.range.stop = nextPart.range.stop

proc parseExpression(p: var ParserState): GuiExpr

proc parseCallArgList(p: var ParserState): tuple[args: seq[GuiExpr], named: seq[GuiNamedArg]] =
  if p.matchKind(gtkRParen):
    return

  while not p.atEnd and not p.atKind(gtkRParen):
    if p.atKind(gtkIdentifier) and p.peekToken(1).kind == gtkColon:
      let nameTok = p.advance()
      discard p.expectKind(gtkColon, "after named argument")
      let valueExpr = p.parseExpression()
      result.named.add GuiNamedArg(name: nameTok.lexeme, value: valueExpr, range: nameTok.range)
    else:
      result.args.add p.parseExpression()

    if p.matchKind(gtkComma):
      continue
    break

  discard p.expectKind(gtkRParen, "to close argument list")

proc parsePrimary(p: var ParserState): GuiExpr =
  let tok = p.curr
  case tok.kind
  of gtkString:
    discard p.advance()
    exprString(tok.lexeme, tok.range)
  of gtkStringInterpStart:
    # String interpolation: "text \(expr) text \(expr) text"
    # Tokens: InterpStart expr InterpMid expr InterpEnd
    discard p.advance()
    var parts: seq[string] = @[tok.lexeme]
    var exprs: seq[GuiExpr] = @[]
    exprs.add p.parseExpression()
    while p.atKind(gtkStringInterpMid):
      let midTok = p.advance()
      parts.add midTok.lexeme
      exprs.add p.parseExpression()
    let endTok = p.expectKind(gtkStringInterpEnd, "to close interpolated string")
    parts.add endTok.lexeme
    GuiExpr(
      kind: geInterpolatedString,
      range: sourceRange(
        tok.range.start.file,
        tok.range.start.line, tok.range.start.col,
        endTok.range.stop.line, endTok.range.stop.col
      ),
      parts: parts,
      expressions: exprs
    )
  of gtkInt:
    discard p.advance()
    var parsed = 0'i64
    try:
      parsed = parseBiggestInt(tok.lexeme)
    except ValueError:
      parsed = 0'i64
      p.addDiagTok(tok, "invalid int literal '" & tok.lexeme & "'", "GUI_PARSE_INT")
    exprInt(parsed, tok.range)
  of gtkFloat:
    discard p.advance()
    var parsed = 0.0
    try:
      parsed = parseFloat(tok.lexeme)
    except ValueError:
      parsed = 0.0
      p.addDiagTok(tok, "invalid float literal '" & tok.lexeme & "'", "GUI_PARSE_FLOAT")
    exprFloat(parsed, tok.range)
  of gtkBool:
    discard p.advance()
    exprBool(tok.lexeme == "true", tok.range)
  of gtkIdentifier:
    discard p.advance()
    if tok.lexeme == "null":
      return exprNull(tok.range)
    exprIdent(tok.lexeme, tok.range)
  of gtkLParen:
    discard p.advance()
    let e = p.parseExpression()
    discard p.expectKind(gtkRParen, "to close expression")
    e
  of gtkLBracket:
    discard p.advance()
    var arr = GuiExpr(kind: geArrayLit, range: tok.range)
    while not p.atEnd and not p.atKind(gtkRBracket):
      arr.items.add p.parseExpression()
      if p.matchKind(gtkComma):
        continue
      break
    let endTok = p.expectKind(gtkRBracket, "to close array literal")
    arr.range.stop = endTok.range.stop
    arr
  of gtkLBrace:
    discard p.advance()
    # Disambiguate: closure vs map literal.
    # Empty braces {} → empty map literal
    if p.atKind(gtkRBrace):
      let endTok = p.advance()
      GuiExpr(kind: geMapLit, range: sourceRange(
        tok.range.start.file,
        tok.range.start.line, tok.range.start.col,
        endTok.range.stop.line, endTok.range.stop.col
      ))
    else:
      # Lookahead to distinguish closure from map:
      #   closure: { ident in ... } or { ident, ident in ... } or { body_expr }
      #   map:     { ident: value } or { string: value }
      var isClosure = false
      var isMap = false
      # Check for map pattern: first token is ident/string followed by ':'
      if (p.atKind(gtkIdentifier) or p.atKind(gtkString)) and
          p.peekToken(1).kind == gtkColon:
        isMap = true
      # Check for closure pattern: ident(s) followed by 'in' keyword
      if not isMap and p.atKind(gtkIdentifier):
        var lookIdx = 0
        while p.peekToken(lookIdx).kind == gtkIdentifier:
          if p.peekToken(lookIdx).lexeme == "in":
            isClosure = true
            break
          inc lookIdx
          if p.peekToken(lookIdx).kind == gtkComma:
            inc lookIdx  # skip comma between params
        if not isClosure:
          # No 'in' found, so it's a closure body expression (no params)
          isClosure = true

      if isMap:
        var mapExpr = GuiExpr(kind: geMapLit, range: tok.range)
        while not p.atEnd and not p.atKind(gtkRBrace):
          var key = ""
          var keyRange = p.curr.range
          if p.atKind(gtkString) or p.atKind(gtkIdentifier):
            let keyTok = p.advance()
            key = keyTok.lexeme
            keyRange = keyTok.range
          else:
            p.addDiagTok(p.curr, "expected map key (string or identifier)", "GUI_PARSE_MAP_KEY")
            discard p.advance()

          discard p.expectKind(gtkColon, "after map key")
          let valueExpr = p.parseExpression()
          mapExpr.entries.add GuiMapEntry(key: key, value: valueExpr, range: keyRange)

          if p.matchKind(gtkComma):
            continue
          break

        let endTok = p.expectKind(gtkRBrace, "to close map literal")
        mapExpr.range.stop = endTok.range.stop
        mapExpr
      else:
        # Parse as closure: { params in body } or { body }
        var closureParams: seq[string] = @[]
        # Check if there's a param list followed by 'in'
        var hasParamList = false
        if p.atKind(gtkIdentifier) and p.curr.lexeme != "in":
          var lookIdx = 0
          while p.peekToken(lookIdx).kind == gtkIdentifier and
              p.peekToken(lookIdx).lexeme != "in":
            inc lookIdx
            if p.peekToken(lookIdx).kind == gtkComma:
              inc lookIdx
          if p.peekToken(lookIdx).kind == gtkIdentifier and
              p.peekToken(lookIdx).lexeme == "in":
            hasParamList = true
        if hasParamList:
          while p.atKind(gtkIdentifier) and p.curr.lexeme != "in":
            closureParams.add p.advance().lexeme
            discard p.matchKind(gtkComma)
          # consume 'in'
          if p.atIdent("in"):
            discard p.advance()
        let bodyExpr = p.parseExpression()
        let endTok = p.expectKind(gtkRBrace, "to close closure")
        GuiExpr(
          kind: geClosure,
          range: sourceRange(
            tok.range.start.file,
            tok.range.start.line, tok.range.start.col,
            endTok.range.stop.line, endTok.range.stop.col
          ),
          closureParams: closureParams,
          closureBody: bodyExpr
        )
  of gtkBackslash:
    # Key path expression: \Type.member or \.member
    discard p.advance()  # consume '\'
    var rootType = ""
    var members: seq[string] = @[]
    if p.atKind(gtkIdentifier):
      # Could be \Type.member or \Type (root type given)
      rootType = p.advance().lexeme
    # Parse .member chain
    while p.matchKind(gtkDot):
      if p.atKind(gtkIdentifier):
        members.add p.advance().lexeme
      else:
        members.add "self"
        break
    # Handle \.self shorthand — rootType would be empty, first member from above
    GuiExpr(
      kind: geKeyPath,
      range: sourceRange(
        tok.range.start.file,
        tok.range.start.line, tok.range.start.col,
        p.prev.range.stop.line, p.prev.range.stop.col
      ),
      keyPathRoot: rootType,
      keyPathMembers: members
    )
  of gtkDollar:
    discard p.advance()  # consume '$'
    if p.atKind(gtkInt):
      # $0, $1 etc. — Swift shorthand closure parameter
      let numTok = p.advance()
      GuiExpr(
        kind: geShorthandParam,
        range: sourceRange(
          tok.range.start.file,
          tok.range.start.line, tok.range.start.col,
          numTok.range.stop.line, numTok.range.stop.col
        ),
        intVal: (try: parseBiggestInt(numTok.lexeme) except ValueError: 0)
      )
    elif p.atKind(gtkIdentifier):
      # $variableName — binding prefix
      let nameTok = p.advance()
      GuiExpr(
        kind: geBindingPrefix,
        range: sourceRange(
          tok.range.start.file,
          tok.range.start.line, tok.range.start.col,
          nameTok.range.stop.line, nameTok.range.stop.col
        ),
        ident: nameTok.lexeme
      )
    else:
      p.addDiagTok(p.curr, "expected identifier or number after '$'", "GUI_PARSE_DOLLAR")
      exprNull(tok.range)
  of gtkDot:
    # .identifier — Swift enum dot-syntax (e.g. .leading, .center, .easeInOut)
    if p.peekToken(1).kind == gtkIdentifier:
      discard p.advance()  # consume '.'
      let nameTok = p.advance()  # consume identifier
      # Support chained dots: .easeInOut(duration: 0.3) etc via parsePostfix
      GuiExpr(
        kind: geEnumValue,
        range: sourceRange(
          tok.range.start.file,
          tok.range.start.line, tok.range.start.col,
          nameTok.range.stop.line, nameTok.range.stop.col
        ),
        ident: nameTok.lexeme
      )
    else:
      p.addDiagTok(tok, "expected identifier after '.' in enum value", "GUI_PARSE_EXPR")
      discard p.advance()
      exprNull(tok.range)
  else:
    p.addDiagTok(tok, "expected expression", "GUI_PARSE_EXPR")
    discard p.advance()
    exprNull(tok.range)

proc parsePostfix(p: var ParserState): GuiExpr =
  var base = p.parsePrimary()

  while not p.atEnd:
    # Optional chaining: expr?.member (only when ? and . are adjacent, no space)
    if p.atKind(gtkQuestion) and p.peekToken(1).kind == gtkDot:
      let qTok = p.curr
      let dotTok = p.peekToken(1)
      # Only treat as optional chaining if ? and . are adjacent (same line, no space)
      if qTok.range.stop.line != dotTok.range.start.line or
          qTok.range.stop.col != dotTok.range.start.col:
        break  # Not optional chaining; let ternary parser handle the ?
      discard p.advance()  # consume '?'
      discard p.advance()  # consume '.'
      let memberTok = p.expectIdentifier("after '?.'")
      base = GuiExpr(
        kind: geMember,
        range: sourceRange(
          base.range.start.file,
          base.range.start.line,
          base.range.start.col,
          memberTok.range.stop.line,
          memberTok.range.stop.col
        ),
        left: base,
        ident: memberTok.lexeme,
        isOptional: true
      )
      continue

    if p.matchKind(gtkDot):
      let memberTok = p.expectIdentifier("after '.'")
      base = GuiExpr(
        kind: geMember,
        range: sourceRange(
          base.range.start.file,
          base.range.start.line,
          base.range.start.col,
          memberTok.range.stop.line,
          memberTok.range.stop.col
        ),
        left: base,
        ident: memberTok.lexeme
      )
      # Eagerly resolve token reference sugar: token.<group>.<name>
      # so that chained calls like token.color.accent.opacity(0.12)
      # become geTokenRef("color","accent").opacity(0.12) instead of
      # leaving `token` as an unresolved ident.
      let tpath = memberPath(base)
      if tpath.len == 3 and tpath[0] == "token":
        base = GuiExpr(
          kind: geTokenRef,
          range: base.range,
          tokenGroup: tpath[1],
          tokenName: tpath[2]
        )
      continue

    if p.matchKind(gtkLParen):
      let parsedArgs = p.parseCallArgList()
      let closeParenLine = p.prev.range.stop.line
      var callArgs = parsedArgs.args
      let callNamed = parsedArgs.named
      # Trailing closure: f(args) { ... } — only on same line as closing paren
      # Suppressed in if/while/for conditions to avoid consuming the body's { as a closure
      if p.atKind(gtkLBrace) and p.curr.range.start.line == closeParenLine and not p.noTrailingClosures:
        discard p.advance() # consume '{'
        var closureParams: seq[string] = @[]
        var hasParamList = false
        if p.atKind(gtkIdentifier) and p.curr.lexeme != "in":
          var lookIdx = 0
          while p.peekToken(lookIdx).kind == gtkIdentifier and
              p.peekToken(lookIdx).lexeme != "in":
            inc lookIdx
            if p.peekToken(lookIdx).kind == gtkComma:
              inc lookIdx
          if p.peekToken(lookIdx).kind == gtkIdentifier and
              p.peekToken(lookIdx).lexeme == "in":
            hasParamList = true
        if hasParamList:
          while p.atKind(gtkIdentifier) and p.curr.lexeme != "in":
            closureParams.add p.advance().lexeme
            discard p.matchKind(gtkComma)
          if p.atIdent("in"):
            discard p.advance()
        let bodyExpr = p.parseExpression()
        let endTok = p.expectKind(gtkRBrace, "to close trailing closure")
        let trailingClosure = GuiExpr(
          kind: geClosure,
          range: sourceRange(
            base.range.start.file,
            base.range.start.line, base.range.start.col,
            endTok.range.stop.line, endTok.range.stop.col
          ),
          closureParams: closureParams,
          closureBody: bodyExpr
        )
        callArgs.add trailingClosure
      base = GuiExpr(
        kind: geCall,
        range: sourceRange(
          base.range.start.file,
          base.range.start.line,
          base.range.start.col,
          p.prev.range.stop.line,
          p.prev.range.stop.col
        ),
        callee: base,
        args: callArgs,
        namedArgs: callNamed
      )
      continue

    # Array/dictionary subscript: expr[index]
    if p.matchKind(gtkLBracket):
      let indexExpr = p.parseExpression()
      let closeBracket = p.expectKind(gtkRBracket, "to close subscript")
      base = GuiExpr(
        kind: geSubscript,
        range: sourceRange(
          base.range.start.file,
          base.range.start.line,
          base.range.start.col,
          closeBracket.range.stop.line,
          closeBracket.range.stop.col
        ),
        left: base,
        right: indexExpr
      )
      continue

    # Postfix force unwrap: expr!
    # Only if ! is adjacent to the previous token (no space)
    if p.atKind(gtkBang):
      let bangTok = p.curr
      if base.range.stop.line == bangTok.range.start.line and
          base.range.stop.col == bangTok.range.start.col:
        discard p.advance()
        base = GuiExpr(
          kind: geForceUnwrap,
          range: sourceRange(
            base.range.start.file,
            base.range.start.line, base.range.start.col,
            bangTok.range.stop.line, bangTok.range.stop.col
          ),
          left: base
        )
        continue

    break

  # Token reference sugar: token.<group>.<name>
  let path = memberPath(base)
  if path.len == 3 and path[0] == "token":
    base = GuiExpr(
      kind: geTokenRef,
      range: base.range,
      tokenGroup: path[1],
      tokenName: path[2]
    )

  base

proc parseUnary(p: var ParserState): GuiExpr =
  if p.matchKind(gtkBang):
    let opTok = p.prev
    let rhs = p.parseUnary()
    return GuiExpr(
      kind: geCall,
      range: sourceRange(
        opTok.range.start.file,
        opTok.range.start.line,
        opTok.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      callee: exprIdent("not", opTok.range),
      args: @[rhs]
    )

  if p.matchKind(gtkMinus):
    let opTok = p.prev
    let rhs = p.parseUnary()
    return GuiExpr(
      kind: geBinary,
      range: sourceRange(
        opTok.range.start.file,
        opTok.range.start.line,
        opTok.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      left: exprInt(0, opTok.range),
      right: rhs,
      op: "-"
    )
  if p.matchKind(gtkPlus):
    return p.parseUnary()
  p.parsePostfix()

proc parseMulDiv(p: var ParserState): GuiExpr =
  var expr = p.parseUnary()
  while p.atKind(gtkStar) or p.atKind(gtkSlash):
    let opTok = p.advance()
    let rhs = p.parseUnary()
    expr = GuiExpr(
      kind: geBinary,
      range: sourceRange(
        expr.range.start.file,
        expr.range.start.line,
        expr.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      left: expr,
      right: rhs,
      op: opTok.lexeme
    )
  expr

proc parseAddSub(p: var ParserState): GuiExpr =
  var expr = p.parseMulDiv()
  while p.atKind(gtkPlus) or p.atKind(gtkMinus):
    let opTok = p.advance()
    let rhs = p.parseMulDiv()
    expr = GuiExpr(
      kind: geBinary,
      range: sourceRange(
        expr.range.start.file,
        expr.range.start.line,
        expr.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      left: expr,
      right: rhs,
      op: opTok.lexeme
    )
  expr

proc parseRangeExpr(p: var ParserState): GuiExpr =
  var expr = p.parseAddSub()
  while p.atKind(gtkDotDotDot) or p.atKind(gtkDotDotLess):
    let opTok = p.advance()
    let rhs = p.parseAddSub()
    expr = GuiExpr(
      kind: geBinary,
      range: sourceRange(
        expr.range.start.file,
        expr.range.start.line,
        expr.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      left: expr,
      right: rhs,
      op: opTok.lexeme
    )
  expr

proc parseComparison(p: var ParserState): GuiExpr =
  var expr = p.parseRangeExpr()
  while p.atKind(gtkLess) or p.atKind(gtkLessEqual) or
      p.atKind(gtkGreater) or p.atKind(gtkGreaterEqual):
    let opTok = p.advance()
    let rhs = p.parseRangeExpr()
    expr = GuiExpr(
      kind: geBinary,
      range: sourceRange(
        expr.range.start.file,
        expr.range.start.line,
        expr.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      left: expr,
      right: rhs,
      op: opTok.lexeme
    )
  expr

proc parseTypeCast(p: var ParserState): GuiExpr =
  var expr = p.parseComparison()
  # Handle: expr as Type, expr as? Type, expr as! Type, expr is Type
  while true:
    if p.atIdent("as"):
      let asTok = p.advance()
      var castOp = "as"
      if p.atKind(gtkQuestion):
        discard p.advance()
        castOp = "as?"
      elif p.atKind(gtkBang):
        discard p.advance()
        castOp = "as!"
      let typeTok = p.expectIdentifier("for type name in cast")
      var typeName = typeTok.lexeme
      # Handle dotted type names: Type.SubType
      while p.matchKind(gtkDot):
        let next = p.expectIdentifier("after '.' in type name")
        typeName.add "." & next.lexeme
      expr = GuiExpr(
        kind: geTypeCast,
        range: sourceRange(
          expr.range.start.file, expr.range.start.line, expr.range.start.col,
          p.prev.range.stop.line, p.prev.range.stop.col
        ),
        left: expr,
        ident: typeName,
        op: castOp
      )
    elif p.atIdent("is"):
      discard p.advance()
      let typeTok = p.expectIdentifier("for type name in type check")
      var typeName = typeTok.lexeme
      while p.matchKind(gtkDot):
        let next = p.expectIdentifier("after '.' in type name")
        typeName.add "." & next.lexeme
      expr = GuiExpr(
        kind: geTypeCheck,
        range: sourceRange(
          expr.range.start.file, expr.range.start.line, expr.range.start.col,
          p.prev.range.stop.line, p.prev.range.stop.col
        ),
        left: expr,
        ident: typeName
      )
    else:
      break
  expr

proc parseEquality(p: var ParserState): GuiExpr =
  var expr = p.parseTypeCast()
  while p.atKind(gtkEqualEqual) or p.atKind(gtkBangEqual):
    let opTok = p.advance()
    let rhs = p.parseTypeCast()
    expr = GuiExpr(
      kind: geBinary,
      range: sourceRange(
        expr.range.start.file,
        expr.range.start.line,
        expr.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      left: expr,
      right: rhs,
      op: opTok.lexeme
    )
  expr

proc parseAnd(p: var ParserState): GuiExpr =
  var expr = p.parseEquality()
  while p.atKind(gtkAndAnd):
    let opTok = p.advance()
    let rhs = p.parseEquality()
    expr = GuiExpr(
      kind: geBinary,
      range: sourceRange(
        expr.range.start.file,
        expr.range.start.line,
        expr.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      left: expr,
      right: rhs,
      op: opTok.lexeme
    )
  expr

proc parseOr(p: var ParserState): GuiExpr =
  var expr = p.parseAnd()
  while p.atKind(gtkOrOr):
    let opTok = p.advance()
    let rhs = p.parseAnd()
    expr = GuiExpr(
      kind: geBinary,
      range: sourceRange(
        expr.range.start.file,
        expr.range.start.line,
        expr.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      left: expr,
      right: rhs,
      op: opTok.lexeme
    )
  expr

proc parseNilCoalescing(p: var ParserState): GuiExpr =
  var expr = p.parseOr()
  while p.atKind(gtkQuestionQuestion):
    let opTok = p.advance()
    let rhs = p.parseOr()
    expr = GuiExpr(
      kind: geBinary,
      range: sourceRange(
        expr.range.start.file,
        expr.range.start.line,
        expr.range.start.col,
        rhs.range.stop.line,
        rhs.range.stop.col
      ),
      left: expr,
      right: rhs,
      op: opTok.lexeme
    )
  expr

proc parseTernary(p: var ParserState): GuiExpr =
  var condExpr = p.parseNilCoalescing()
  if not p.matchKind(gtkQuestion):
    return condExpr

  let trueExpr = p.parseNilCoalescing()
  discard p.expectKind(gtkColon, "in ternary expression")
  let falseExpr = p.parseTernary()
  GuiExpr(
    kind: geCall,
    range: sourceRange(
      condExpr.range.start.file,
      condExpr.range.start.line,
      condExpr.range.start.col,
      falseExpr.range.stop.line,
      falseExpr.range.stop.col
    ),
    callee: exprIdent("select", condExpr.range),
    args: @[condExpr, trueExpr, falseExpr]
  )

proc parseExpression(p: var ParserState): GuiExpr =
  p.parseTernary()

proc parseTypeInner(p: var ParserState, context: string): tuple[text: string, range: GuiSourceRange]

proc parseTypeAtom(p: var ParserState, context: string): tuple[text: string, range: GuiSourceRange] =
  if p.atKind(gtkIdentifier):
    let firstTok = p.expectIdentifier(context)
    result.text = firstTok.lexeme
    result.range = firstTok.range

    while p.matchKind(gtkDot):
      let nextTok = p.expectIdentifier("for qualified type name")
      result.text.add "."
      result.text.add nextTok.lexeme
      result.range.stop = nextTok.range.stop

    if p.matchKind(gtkLess):
      var genericArgs: seq[string] = @[]
      if not p.atKind(gtkGreater):
        while not p.atEnd and not p.atKind(gtkGreater):
          let arg = parseTypeInner(p, "for generic type argument")
          genericArgs.add arg.text
          result.range.stop = arg.range.stop
          if p.matchKind(gtkComma):
            continue
          break
      let closeTok = p.expectKind(gtkGreater, "to close generic type arguments")
      result.text.add "<" & genericArgs.join(", ") & ">"
      result.range.stop = closeTok.range.stop
    return

  if p.matchKind(gtkLBracket):
    let startTok = p.prev
    let firstType = parseTypeInner(p, "for bracketed type")
    if p.matchKind(gtkColon):
      let valueType = parseTypeInner(p, "for dictionary value type")
      let closeTok = p.expectKind(gtkRBracket, "to close dictionary type")
      result.text = "[" & firstType.text & ":" & valueType.text & "]"
      result.range = sourceRange(
        startTok.range.start.file,
        startTok.range.start.line,
        startTok.range.start.col,
        closeTok.range.stop.line,
        closeTok.range.stop.col
      )
    else:
      let closeTok = p.expectKind(gtkRBracket, "to close bracketed type")
      result.text = "[" & firstType.text & "]"
      result.range = sourceRange(
        startTok.range.start.file,
        startTok.range.start.line,
        startTok.range.start.col,
        closeTok.range.stop.line,
        closeTok.range.stop.col
      )
    return

  if p.matchKind(gtkLParen):
    let startTok = p.prev
    var parts: seq[string] = @[]
    if not p.atKind(gtkRParen):
      while not p.atEnd and not p.atKind(gtkRParen):
        let partType = parseTypeInner(p, "for tuple element type")
        parts.add partType.text
        if p.matchKind(gtkComma):
          continue
        break
    let closeTok = p.expectKind(gtkRParen, "to close tuple type")
    result.text = "(" & parts.join(", ") & ")"
    result.range = sourceRange(
      startTok.range.start.file,
      startTok.range.start.line,
      startTok.range.start.col,
      closeTok.range.stop.line,
      closeTok.range.stop.col
    )
    return

  let badTok = p.curr
  p.addDiagTok(badTok, "expected type reference " & context, "GUI_PARSE_TYPE")
  discard p.advance()
  result.text = "Any"
  result.range = badTok.range

proc parseTypeInner(p: var ParserState, context: string): tuple[text: string, range: GuiSourceRange] =
  result = parseTypeAtom(p, context)

  while p.matchKind(gtkLBracket):
    let closeTok = p.expectKind(gtkRBracket, "after array type suffix")
    result.text.add "[]"
    result.range.stop = closeTok.range.stop

  while p.matchKind(gtkQuestion):
    let qTok = p.prev
    result.text.add "?"
    result.range.stop = qTok.range.stop

proc parseTypeRef(p: var ParserState, context: string): tuple[text: string, range: GuiSourceRange] =
  parseTypeInner(p, context)

proc parseParamList(p: var ParserState): seq[GuiParamDecl] =
  if not p.matchKind(gtkLParen):
    return

  if p.matchKind(gtkRParen):
    return

  while not p.atEnd and not p.atKind(gtkRParen):
    var isBinding = false
    if p.atKind(gtkAt) and p.peekToken(1).kind == gtkIdentifier and p.peekToken(1).lexeme == "Binding":
      discard p.advance()  # consume '@'
      discard p.advance()  # consume 'Binding'
      isBinding = true

    let nameTok = p.expectIdentifier("for parameter name")
    discard p.expectKind(gtkColon, "after parameter name")
    let typ = p.parseTypeRef("for parameter type")
    result.add GuiParamDecl(
      name: nameTok.lexeme,
      typ: typ.text,
      isBinding: isBinding,
      range: sourceRange(
        nameTok.range.start.file,
        nameTok.range.start.line,
        nameTok.range.start.col,
        typ.range.stop.line,
        typ.range.stop.col
      )
    )

    if p.matchKind(gtkComma):
      continue
    break

  discard p.expectKind(gtkRParen, "to close parameter list")

proc parseFieldDecl(p: var ParserState): GuiFieldDecl =
  let nameTok = p.expectIdentifier("for field name")
  discard p.expectKind(gtkColon, "after field name")
  let typ = p.parseTypeRef("for field type")

  var defaultExpr = exprNull(typ.range)
  if p.matchKind(gtkEqual):
    defaultExpr = p.parseExpression()

  result = GuiFieldDecl(
    name: nameTok.lexeme,
    typ: typ.text,
    defaultValue: defaultExpr,
    range: sourceRange(
      nameTok.range.start.file,
      nameTok.range.start.line,
      nameTok.range.start.col,
      typ.range.stop.line,
      typ.range.stop.col
    )
  )
  p.optionalDelimiter()

proc parseEnumDecl(p: var ParserState): GuiEnumDecl =
  let nameTok = p.expectIdentifier("for enum name")
  result = GuiEnumDecl(name: nameTok.lexeme, range: nameTok.range)
  # Optional raw type and protocol conformance: enum Tab: String, CaseIterable { ... }
  if p.matchKind(gtkColon):
    let firstType = p.expectIdentifier("for enum raw type or protocol")
    result.rawType = firstType.lexeme
    while p.matchKind(gtkComma):
      let proto = p.expectIdentifier("for enum protocol conformance")
      result.protocols.add proto.lexeme
  discard p.expectKind(gtkLBrace, "after enum name")
  while not p.atEnd and not p.atKind(gtkRBrace):
    let caseTok = p.expectIdentifier("for enum case name")
    var caseDecl = GuiEnumCaseDecl(name: caseTok.lexeme, range: caseTok.range)
    caseDecl.params = p.parseParamList()
    # Optional raw value: case home = "Home"
    if p.matchKind(gtkEqual):
      caseDecl.rawValue = p.parseExpression()
    result.cases.add caseDecl
    p.optionalDelimiter()
  discard p.expectKind(gtkRBrace, "to close enum block")

proc parseActionDecl(p: var ParserState): GuiActionDecl =
  let actionTok = p.expectIdentifier("for action name")
  result = GuiActionDecl(name: actionTok.lexeme, owner: gaoSwift, range: actionTok.range)
  result.params = p.parseParamList()

  if p.atIdent("owner"):
    discard p.advance()
    let ownerTok = p.expectIdentifier("for action owner")
    case ownerTok.lexeme.toLowerAscii()
    of "swift":
      result.owner = gaoSwift
    of "nim":
      result.owner = gaoNim
    of "both":
      result.owner = gaoBoth
    else:
      p.addDiagTok(
        ownerTok,
        "unsupported action owner '" & ownerTok.lexeme & "' (expected swift|nim|both)",
        "GUI_PARSE_ACTION_OWNER"
      )
  p.optionalDelimiter()

proc parseBridgeDecl(p: var ParserState): GuiBridgeDecl =
  result = GuiBridgeDecl(range: p.curr.range)
  discard p.expectKind(gtkLBrace, "after 'bridge'")

  while not p.atEnd and not p.atKind(gtkRBrace):
    let keyTok = p.expectIdentifier("for bridge field")
    discard p.expectKind(gtkColon, "after bridge field key")

    if keyTok.lexeme == "nimEntry":
      let pathTok = p.expectKind(gtkString, "for bridge nimEntry value")
      result.nimEntry = pathTok.lexeme
    else:
      p.addDiagTok(keyTok, "unsupported bridge field '" & keyTok.lexeme & "'", "GUI_PARSE_BRIDGE_FIELD")
      discard p.parseExpression()

    p.optionalDelimiter()

  discard p.expectKind(gtkRBrace, "to close bridge block")

proc parseWindowDecl(p: var ParserState): GuiWindowDecl =
  result = GuiWindowDecl(range: p.curr.range)
  discard p.expectKind(gtkLBrace, "after 'window'")

  while not p.atEnd and not p.atKind(gtkRBrace):
    let keyTok = p.expectIdentifier("for window field")
    discard p.expectKind(gtkColon, "after window field key")

    case keyTok.lexeme
    of "title":
      let valueExpr = p.parseExpression()
      if valueExpr.kind == geStringLit:
        result.title = valueExpr.strVal
        result.hasTitle = true
      else:
        p.addDiagTok(keyTok, "window.title expects a string literal", "GUI_PARSE_WINDOW_TITLE")

    of "closeAppOnLastWindowClose":
      let valueExpr = p.parseExpression()
      if valueExpr.kind == geBoolLit:
        result.closeAppOnLastWindowClose = valueExpr.boolVal
        result.hasClosePolicy = true
      else:
        p.addDiagTok(
          keyTok,
          "window.closeAppOnLastWindowClose expects a bool literal",
          "GUI_PARSE_WINDOW_CLOSE_POLICY"
        )

    of "showTitleBar":
      let valueExpr = p.parseExpression()
      if valueExpr.kind == geBoolLit:
        result.showTitleBar = valueExpr.boolVal
        result.hasShowTitleBar = true
      else:
        p.addDiagTok(
          keyTok,
          "window.showTitleBar expects a bool literal",
          "GUI_PARSE_WINDOW_TITLE_BAR"
        )

    of "suppressDefaultMenus":
      let valueExpr = p.parseExpression()
      if valueExpr.kind == geBoolLit:
        result.suppressDefaultMenus = valueExpr.boolVal
        result.hasSuppressDefaultMenus = true
      else:
        p.addDiagTok(
          keyTok,
          "window.suppressDefaultMenus expects a bool literal",
          "GUI_PARSE_WINDOW_SUPPRESS_MENUS"
        )

    of "width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight":
      let valueExpr = p.parseExpression()
      var parsedValue = 0.0
      case valueExpr.kind
      of geIntLit:
        parsedValue = valueExpr.intVal.float64
      of geFloatLit:
        parsedValue = valueExpr.floatVal
      else:
        p.addDiagTok(keyTok, "window." & keyTok.lexeme & " expects a numeric literal", "GUI_PARSE_WINDOW_DIM")
      case keyTok.lexeme
      of "width":
        result.width = parsedValue
        result.hasWidth = true
      of "height":
        result.height = parsedValue
        result.hasHeight = true
      of "minWidth":
        result.minWidth = parsedValue
        result.hasMinWidth = true
      of "minHeight":
        result.minHeight = parsedValue
        result.hasMinHeight = true
      of "maxWidth":
        result.maxWidth = parsedValue
        result.hasMaxWidth = true
      of "maxHeight":
        result.maxHeight = parsedValue
        result.hasMaxHeight = true
      else:
        discard

    else:
      p.addDiagTok(keyTok, "unsupported window field '" & keyTok.lexeme & "'", "GUI_PARSE_WINDOW_FIELD")
      discard p.parseExpression()

    p.optionalDelimiter()

  discard p.expectKind(gtkRBrace, "to close window block")

proc parseTokensBlock(p: var ParserState): seq[GuiTokenDecl] =
  discard p.expectKind(gtkLBrace, "after 'tokens'")

  while not p.atEnd and not p.atKind(gtkRBrace):
    let grpTok = p.expectIdentifier("for token group")
    discard p.expectKind(gtkDot, "between token group and token name")
    let nameTok = p.expectIdentifier("for token name")
    discard p.expectKind(gtkEqual, "after token name")
    let valueExpr = p.parseExpression()
    result.add GuiTokenDecl(
      group: grpTok.lexeme,
      name: nameTok.lexeme,
      value: valueExpr,
      range: grpTok.range
    )
    p.optionalDelimiter()

  discard p.expectKind(gtkRBrace, "to close tokens block")

proc parseModelDecl(p: var ParserState): GuiModelDecl =
  let nameTok = p.expectIdentifier("for model name")
  result = GuiModelDecl(name: nameTok.lexeme, range: nameTok.range)
  # Optional protocol conformance: model User: Identifiable, Hashable { ... }
  if p.matchKind(gtkColon):
    while p.atKind(gtkIdentifier):
      result.protocols.add p.advance().lexeme
      if not p.matchKind(gtkComma):
        break
  discard p.expectKind(gtkLBrace, "after model name")
  while not p.atEnd and not p.atKind(gtkRBrace):
    # Support @Published annotation on model fields
    if p.atKind(gtkAt) and p.peekToken(1).kind == gtkIdentifier and
        p.peekToken(1).lexeme == "Published":
      discard p.advance()  # consume '@'
      discard p.advance()  # consume 'Published'
      var field = p.parseFieldDecl()
      field.isPublished = true
      result.fields.add field
    else:
      result.fields.add p.parseFieldDecl()
  discard p.expectKind(gtkRBrace, "to close model block")

proc parseStateBlock(p: var ParserState): seq[GuiFieldDecl] =
  discard p.expectKind(gtkLBrace, "after 'state'")
  while not p.atEnd and not p.atKind(gtkRBrace):
    if p.atIdent("computed"):
      discard p.advance()  # consume 'computed'
      var field = p.parseFieldDecl()
      field.isComputed = true
      result.add field
    else:
      result.add p.parseFieldDecl()
  discard p.expectKind(gtkRBrace, "to close state block")

proc parseEmitCommand(p: var ParserState, startTok: GuiToken): GuiReducerStmt =
  let cmdPath = p.parseIdentifierPath()
  let cmdName = cmdPath.path.join(".")

  var parsedArgs: tuple[args: seq[GuiExpr], named: seq[GuiNamedArg]]
  if p.matchKind(gtkLParen):
    parsedArgs = p.parseCallArgList()
    if parsedArgs.args.len > 0:
      p.addDiag(
        startTok.range,
        "emit command requires named arguments only",
        "GUI_PARSE_EMIT_NAMED"
      )

  result = GuiReducerStmt(
    kind: grsEmit,
    commandName: cmdName,
    commandArgs: parsedArgs.named,
    range: startTok.range
  )
  p.optionalDelimiter()

proc parseReducerStmt(p: var ParserState): GuiReducerStmt =
  if p.atIdent("set"):
    let startTok = p.advance()
    let fieldTok = p.expectIdentifier("after 'set'")
    discard p.expectKind(gtkEqual, "after field name in set statement")
    let valueExpr = p.parseExpression()
    result = GuiReducerStmt(
      kind: grsSet,
      fieldName: fieldTok.lexeme,
      valueExpr: valueExpr,
      range: startTok.range
    )
    # Optional: withAnimation .easeInOut
    if p.atIdent("withAnimation"):
      discard p.advance()
      result.animationExpr = p.parseExpression()
    p.optionalDelimiter()
    return

  if p.atIdent("emit"):
    let startTok = p.advance()
    return p.parseEmitCommand(startTok)

  p.addDiagTok(p.curr, "unsupported reducer statement", "GUI_PARSE_REDUCER_STMT")
  discard p.advance()
  GuiReducerStmt(kind: grsEmit, range: p.prev.range)

proc parseReducerCase(p: var ParserState): GuiReducerCase =
  let onTok = p.expectIdentifier("for reducer case keyword")
  if onTok.lexeme != "on":
    p.addDiagTok(onTok, "expected 'on' in reducer case", "GUI_PARSE_REDUCER_ON")

  let actionTok = p.expectIdentifier("for reducer action name")
  result = GuiReducerCase(actionName: actionTok.lexeme, range: onTok.range)

  if p.matchKind(gtkLParen):
    if not p.atKind(gtkRParen):
      while not p.atEnd and not p.atKind(gtkRParen):
        let bindTok = p.expectIdentifier("for reducer binding")
        result.bindNames.add bindTok.lexeme
        if p.matchKind(gtkComma):
          continue
        break
    discard p.expectKind(gtkRParen, "to close reducer binding list")

  discard p.expectKind(gtkLBrace, "to open reducer case body")
  while not p.atEnd and not p.atKind(gtkRBrace):
    result.statements.add p.parseReducerStmt()
  discard p.expectKind(gtkRBrace, "to close reducer case body")

proc parseReducerBlock(p: var ParserState): seq[GuiReducerCase] =
  discard p.expectKind(gtkLBrace, "after 'reducer'")
  while not p.atEnd and not p.atKind(gtkRBrace):
    if p.atIdent("on"):
      result.add p.parseReducerCase()
    else:
      p.addDiagTok(p.curr, "expected 'on' reducer case", "GUI_PARSE_REDUCER_CASE")
      p.synchronizeToDeclBoundary()
      if p.atKind(gtkRBrace):
        break
  discard p.expectKind(gtkRBrace, "to close reducer block")

proc parseUiNode(p: var ParserState): GuiUiNode

proc parseUiArgList(p: var ParserState): tuple[args: seq[GuiExpr], named: seq[GuiNamedArg]] =
  if not p.matchKind(gtkLParen):
    return
  p.parseCallArgList()

proc parseConditionalNode(p: var ParserState): GuiUiNode

proc parseSwitchNode(p: var ParserState): GuiUiNode

proc parseUiNodeOrConditional(p: var ParserState): GuiUiNode

proc parsePlatformConditional(p: var ParserState): GuiUiNode =
  ## Parse: #if os(iOS) { ... } #else { ... }
  discard p.advance()  # consume '#'
  discard p.advance()  # consume 'if'
  # Parse condition like os(iOS), os(macOS), targetEnvironment(simulator)
  var condStr = ""
  let condTok = p.expectIdentifier("for platform condition")
  condStr = condTok.lexeme
  if p.matchKind(gtkLParen):
    let argTok = p.expectIdentifier("for platform condition argument")
    condStr.add "(" & argTok.lexeme & ")"
    discard p.expectKind(gtkRParen, "to close platform condition")
  result = GuiUiNode(
    name: "__platform_if__",
    isPlatformConditional: true,
    platformCondition: condStr,
    range: condTok.range
  )
  discard p.expectKind(gtkLBrace, "after platform condition")
  while not p.atEnd and not p.atKind(gtkRBrace):
    result.children.add p.parseUiNodeOrConditional()
  discard p.expectKind(gtkRBrace, "to close platform if body")
  # Optional #else block
  if p.atKind(gtkHash) and p.peekToken(1).kind == gtkIdentifier and
      p.peekToken(1).lexeme == "else":
    discard p.advance()  # consume '#'
    discard p.advance()  # consume 'else'
    discard p.expectKind(gtkLBrace, "after #else")
    while not p.atEnd and not p.atKind(gtkRBrace):
      result.platformElseChildren.add p.parseUiNodeOrConditional()
    discard p.expectKind(gtkRBrace, "to close #else body")

proc parseUiNodeOrConditional(p: var ParserState): GuiUiNode =
  if p.atIdent("if"):
    return p.parseConditionalNode()
  if p.atIdent("switch"):
    return p.parseSwitchNode()
  if p.atKind(gtkHash) and p.peekToken(1).kind == gtkIdentifier and
      p.peekToken(1).lexeme == "if":
    return p.parsePlatformConditional()
  p.parseUiNode()

proc parseConditionalBranch(p: var ParserState): GuiUiNode =
  ## Parse: if condition { ... } or if let name = expr { ... }
  ## Also supports chaining: if let a = x, let b = y, condition { ... }
  let ifTok = p.advance() # consume 'if'

  # Check for if-let binding: if let name = expr [, ...] { ... }
  if p.atIdent("let"):
    let savedNoTrailing = p.noTrailingClosures
    p.noTrailingClosures = true
    var clauses: seq[GuiIfLetClause] = @[]
    # Parse first let clause
    discard p.advance() # consume 'let'
    let nameTok = p.expectIdentifier("for if-let binding name")
    discard p.expectKind(gtkEqual, "in if-let binding")
    let valueExpr = p.parseExpression()
    clauses.add GuiIfLetClause(
      isBinding: true,
      bindName: nameTok.lexeme,
      bindExpr: valueExpr,
      range: nameTok.range
    )
    # Parse additional comma-separated clauses
    while p.matchKind(gtkComma):
      if p.atIdent("let"):
        discard p.advance() # consume 'let'
        let nextName = p.expectIdentifier("for if-let binding name")
        discard p.expectKind(gtkEqual, "in if-let binding")
        let nextExpr = p.parseExpression()
        clauses.add GuiIfLetClause(
          isBinding: true,
          bindName: nextName.lexeme,
          bindExpr: nextExpr,
          range: nextName.range
        )
      else:
        # Boolean condition clause
        let condExpr = p.parseExpression()
        clauses.add GuiIfLetClause(
          isBinding: false,
          bindExpr: condExpr,
          range: condExpr.range
        )
    result = GuiUiNode(
      name: "__if__",
      isConditional: true,
      isIfLet: true,
      letName: clauses[0].bindName,
      letExpr: clauses[0].bindExpr,
      ifLetClauses: clauses,
      range: ifTok.range
    )
    p.noTrailingClosures = savedNoTrailing
    discard p.expectKind(gtkLBrace, "after if-let expression")
    while not p.atEnd and not p.atKind(gtkRBrace):
      result.children.add p.parseUiNodeOrConditional()
    discard p.expectKind(gtkRBrace, "to close if-let body")
    return

  let savedNoTrailing = p.noTrailingClosures
  p.noTrailingClosures = true
  let condition = p.parseExpression()
  p.noTrailingClosures = savedNoTrailing
  result = GuiUiNode(
    name: "__if__",
    isConditional: true,
    condition: condition,
    range: ifTok.range
  )
  discard p.expectKind(gtkLBrace, "after if condition")
  while not p.atEnd and not p.atKind(gtkRBrace):
    result.children.add p.parseUiNodeOrConditional()
  discard p.expectKind(gtkRBrace, "to close if body")

proc parseConditionalNode(p: var ParserState): GuiUiNode =
  ## Parse: if condition { children } else if condition { children } else { children }
  result = p.parseConditionalBranch()

  # Parse else-if / else chains (all attached to the outer node)
  while p.atIdent("else"):
    discard p.advance() # consume 'else'
    if p.atIdent("if"):
      # else if branch — parse only the condition+body, not the else chain
      let elifNode = p.parseConditionalBranch()
      result.elseIfBranches.add elifNode
    else:
      # else branch (terminal)
      discard p.expectKind(gtkLBrace, "after else")
      while not p.atEnd and not p.atKind(gtkRBrace):
        result.elseChildren.add p.parseUiNodeOrConditional()
      discard p.expectKind(gtkRBrace, "to close else body")
      break

proc parseSwitchNode(p: var ParserState): GuiUiNode =
  ## Parse: switch expr { case .val: nodes... case .val2: nodes... default: nodes... }
  let switchTok = p.advance() # consume 'switch'
  let switchExpr = p.parseExpression()
  result = GuiUiNode(
    name: "__switch__",
    isSwitch: true,
    switchExpr: switchExpr,
    range: switchTok.range
  )
  discard p.expectKind(gtkLBrace, "after switch expression")

  while not p.atEnd and not p.atKind(gtkRBrace):
    if p.atIdent("case"):
      let caseTok = p.advance() # consume 'case'
      var patterns: seq[GuiExpr] = @[]
      var letBindings: seq[string] = @[]

      # Parse case pattern(s): .value, .value2, or pattern(let name)
      while true:
        let pattern = p.parseExpression()
        patterns.add pattern
        # Check for associated value let bindings: case .detail(let id)
        # Already handled by the expression parser as a call expr
        if pattern.kind == geCall and pattern.args.len > 0:
          for arg in pattern.args:
            if arg.kind == geIdent:
              letBindings.add arg.ident
        if not p.matchKind(gtkComma):
          break

      discard p.expectKind(gtkColon, "after case pattern")

      var caseBody: seq[GuiUiNode] = @[]
      while not p.atEnd and not p.atKind(gtkRBrace) and
            not p.atIdent("case") and not p.atIdent("default"):
        caseBody.add p.parseUiNodeOrConditional()

      result.cases.add GuiSwitchCase(
        patterns: patterns,
        letBindings: letBindings,
        isDefault: false,
        body: caseBody,
        range: caseTok.range
      )

    elif p.atIdent("default"):
      let defTok = p.advance() # consume 'default'
      discard p.expectKind(gtkColon, "after default")
      var defaultBody: seq[GuiUiNode] = @[]
      while not p.atEnd and not p.atKind(gtkRBrace) and
            not p.atIdent("case"):
        defaultBody.add p.parseUiNodeOrConditional()
      result.cases.add GuiSwitchCase(
        isDefault: true,
        body: defaultBody,
        range: defTok.range
      )
    else:
      p.addDiagTok(p.curr, "expected 'case' or 'default' inside switch block", "GUI_PARSE_SWITCH")
      break

  discard p.expectKind(gtkRBrace, "to close switch body")

proc parseUiNode(p: var ParserState): GuiUiNode =
  # Handle conditional views
  if p.atIdent("if"):
    return p.parseConditionalNode()

  # Guard: if we don't see an identifier, skip the token to avoid infinite loops
  if not p.atKind(gtkIdentifier):
    let tok = p.advance()
    p.addDiagTok(tok, "expected view name (identifier), got " & tokenKindText(tok.kind), "GUI_PARSE_VIEW")
    return GuiUiNode(name: "__error__", range: tok.range)

  let headPath = p.parseIdentifierPath()
  let nodeName = headPath.path.join(".")
  var args: seq[GuiExpr] = @[]
  var namedArgs: seq[GuiNamedArg] = @[]

  if p.atKind(gtkLParen):
    let parsedArgs = p.parseUiArgList()
    args = parsedArgs.args
    namedArgs = parsedArgs.named

  var children: seq[GuiUiNode] = @[]
  if p.matchKind(gtkLBrace):
    while not p.atEnd and not p.atKind(gtkRBrace):
      children.add p.parseUiNodeOrConditional()
    discard p.expectKind(gtkRBrace, "to close UI child block")

  var modifiers: seq[GuiModifierDecl] = @[]
  while p.matchKind(gtkDot):
    let modNameTok = p.expectIdentifier("for modifier name")
    var modArgs: seq[GuiExpr] = @[]
    var modNamed: seq[GuiNamedArg] = @[]
    var modChildren: seq[GuiUiNode] = @[]
    var modRange = modNameTok.range
    if p.atKind(gtkLParen):
      let parsedArgs = p.parseUiArgList()
      modArgs = parsedArgs.args
      modNamed = parsedArgs.named
      modRange.stop = p.prev.range.stop
    if p.matchKind(gtkLBrace):
      while not p.atEnd and not p.atKind(gtkRBrace):
        modChildren.add p.parseUiNodeOrConditional()
      let endTok = p.expectKind(gtkRBrace, "to close modifier block")
      modRange.stop = endTok.range.stop
    modifiers.add GuiModifierDecl(
      name: modNameTok.lexeme,
      args: modArgs,
      namedArgs: modNamed,
      children: modChildren,
      range: modRange
    )

  GuiUiNode(
    name: nodeName,
    args: args,
    namedArgs: namedArgs,
    children: children,
    modifiers: modifiers,
    range: headPath.range
  )

proc parseViewModifierDecl(p: var ParserState): GuiViewModifierDecl =
  let nameTok = p.expectIdentifier("for modifier name")
  result = GuiViewModifierDecl(name: nameTok.lexeme, range: nameTok.range)
  discard p.expectKind(gtkLBrace, "to open modifier body")
  while not p.atEnd and not p.atKind(gtkRBrace):
    if p.matchKind(gtkDot):
      let modNameTok = p.expectIdentifier("for modifier name")
      var modArgs: seq[GuiExpr] = @[]
      var modNamed: seq[GuiNamedArg] = @[]
      var modChildren: seq[GuiUiNode] = @[]
      var modRange = modNameTok.range
      if p.atKind(gtkLParen):
        let parsedArgs = p.parseUiArgList()
        modArgs = parsedArgs.args
        modNamed = parsedArgs.named
        modRange.stop = p.prev.range.stop
      if p.matchKind(gtkLBrace):
        while not p.atEnd and not p.atKind(gtkRBrace):
          modChildren.add p.parseUiNodeOrConditional()
        let endTok = p.expectKind(gtkRBrace, "to close modifier block")
        modRange.stop = endTok.range.stop
      result.modifiers.add GuiModifierDecl(
        name: modNameTok.lexeme,
        args: modArgs,
        namedArgs: modNamed,
        children: modChildren,
        range: modRange
      )
    else:
      p.addDiagTok(p.curr, "expected '.' for modifier in modifier block", "GUI_PARSE_VIEWMOD")
      discard p.advance()
  discard p.expectKind(gtkRBrace, "to close modifier body")

proc parseComponentDecl(p: var ParserState): GuiComponentDecl =
  let nameTok = p.expectIdentifier("for component name")
  result = GuiComponentDecl(name: nameTok.lexeme, range: nameTok.range)
  result.params = p.parseParamList()

  discard p.expectKind(gtkLBrace, "to open component body")

  # Parse @State declarations and @Environment bindings at the top of the body
  while not p.atEnd and not p.atKind(gtkRBrace):
    if p.atKind(gtkAt):
      let atTok = p.advance()  # consume '@'
      if p.atIdent("AppStorage") or p.atIdent("SceneStorage"):
        let wrapperName = p.curr.lexeme
        let wrapperKind = if wrapperName == "AppStorage": gpwAppStorage else: gpwSceneStorage
        discard p.advance()  # consume wrapper name
        # Parse ("key")
        discard p.expectKind(gtkLParen, "after @" & wrapperName)
        let keyTok = p.expectKind(gtkString, "for storage key")
        discard p.expectKind(gtkRParen, "to close @" & wrapperName)
        let varName = p.expectIdentifier("for @" & wrapperName & " variable name")
        discard p.expectKind(gtkColon, "after variable name")
        let typ = p.parseTypeRef("for variable type")
        var defaultExpr: GuiExpr = nil
        if p.matchKind(gtkEqual):
          defaultExpr = p.parseExpression()
        result.localState.add GuiLocalStateDecl(
          name: varName.lexeme,
          typ: typ.text,
          wrapper: wrapperKind,
          storageKey: keyTok.lexeme,
          defaultValue: defaultExpr,
          range: atTok.range
        )
        p.optionalDelimiter()
        continue
      elif p.atIdent("Namespace"):
        discard p.advance()  # consume 'Namespace'
        let varName = p.expectIdentifier("for @Namespace variable name")
        result.localState.add GuiLocalStateDecl(
          name: varName.lexeme,
          typ: "Namespace.ID",
          wrapper: gpwNamespace,
          range: atTok.range
        )
        p.optionalDelimiter()
        continue
      elif p.atIdent("State") or p.atIdent("FocusState") or p.atIdent("GestureState") or
          p.atIdent("StateObject") or
          p.atIdent("ObservedObject") or p.atIdent("EnvironmentObject") or
          p.atIdent("AccessibilityFocusState"):
        let wrapperName = p.curr.lexeme
        let wrapperKind = case wrapperName
          of "State": gpwState
          of "FocusState": gpwFocusState
          of "GestureState": gpwGestureState
          of "StateObject": gpwStateObject
          of "ObservedObject": gpwObservedObject
          of "EnvironmentObject": gpwEnvironmentObject
          of "AccessibilityFocusState": gpwAccessibilityFocusState
          else: gpwState
        discard p.advance()  # consume wrapper name
        # Optional 'var' or 'let' keyword (Swift-style: @State var x: T)
        if p.atIdent("var") or p.atIdent("let"):
          discard p.advance()
        let varName = p.expectIdentifier("for @" & wrapperName & " variable name")
        discard p.expectKind(gtkColon, "after variable name")
        let typ = p.parseTypeRef("for variable type")
        var defaultExpr: GuiExpr = nil
        if p.matchKind(gtkEqual):
          defaultExpr = p.parseExpression()
        result.localState.add GuiLocalStateDecl(
          name: varName.lexeme,
          typ: typ.text,
          wrapper: wrapperKind,
          defaultValue: defaultExpr,
          range: atTok.range
        )
        p.optionalDelimiter()
        continue
      elif p.atIdent("Environment"):
        discard p.advance()  # consume 'Environment'
        discard p.expectKind(gtkLParen, "after @Environment")
        # Expect \.<keyPath>
        var keyPath = ""
        if p.matchKind(gtkDot):
          let kpTok = p.expectIdentifier("for environment key path")
          keyPath = kpTok.lexeme
        else:
          # Also accept a string like "colorScheme"
          let kpTok = p.expectIdentifier("for environment key path")
          keyPath = kpTok.lexeme
        discard p.expectKind(gtkRParen, "to close @Environment")
        # Optional: var localName: Type
        var localName = keyPath
        var typ = "Any"
        if p.atIdent("var") or p.atIdent("let"):
          discard p.advance()
          let nameTok2 = p.expectIdentifier("for environment local name")
          localName = nameTok2.lexeme
          if p.matchKind(gtkColon):
            let typParsed = p.parseTypeRef("for environment variable type")
            typ = typParsed.text
        elif p.atKind(gtkIdentifier) and p.peekToken(1).kind == gtkColon:
          let nameTok2 = p.advance()
          localName = nameTok2.lexeme
          discard p.advance()  # consume ':'
          let typParsed = p.parseTypeRef("for environment variable type")
          typ = typParsed.text
        result.envBindings.add GuiEnvBinding(
          localName: localName,
          keyPath: keyPath,
          typ: typ,
          range: atTok.range
        )
        p.optionalDelimiter()
        continue
      else:
        p.addDiagTok(p.curr, "expected 'State' or 'Environment' after '@'", "GUI_PARSE_AT")
        discard p.advance()
        continue
    elif p.atIdent("let"):
      let letTok = p.advance()  # consume 'let'
      let varName = p.expectIdentifier("for let binding name")
      var typ = ""
      if p.matchKind(gtkColon):
        let typParsed = p.parseTypeRef("for let binding type")
        typ = typParsed.text
      discard p.expectKind(gtkEqual, "after let binding name")
      let valueExpr = p.parseExpression()
      result.letBindings.add GuiLetBinding(
        name: varName.lexeme,
        typ: typ,
        value: valueExpr,
        range: letTok.range
      )
      p.optionalDelimiter()
      continue
    else:
      break

  while not p.atEnd and not p.atKind(gtkRBrace):
    result.body.add p.parseUiNodeOrConditional()
  discard p.expectKind(gtkRBrace, "to close component body")

proc parseTabDecl(p: var ParserState): GuiTabDecl =
  let idTok = p.expectIdentifier("for tab id")
  result = GuiTabDecl(id: idTok.lexeme, range: idTok.range)
  discard p.expectKind(gtkLParen, "after tab id")

  if not p.atKind(gtkRParen):
    while not p.atEnd and not p.atKind(gtkRParen):
      let keyTok = p.expectIdentifier("for tab field")
      discard p.expectKind(gtkColon, "after tab field key")
      let valTok = p.expectIdentifier("for tab field value")

      case keyTok.lexeme
      of "root":
        result.rootComponent = valTok.lexeme
      of "stack":
        result.stack = valTok.lexeme
      else:
        p.addDiagTok(keyTok, "unsupported tab field '" & keyTok.lexeme & "'", "GUI_PARSE_TAB_FIELD")

      if p.matchKind(gtkComma):
        continue
      break

  discard p.expectKind(gtkRParen, "to close tab declaration")
  p.optionalDelimiter()

proc parseRouteDecl(p: var ParserState): GuiRouteDecl =
  let idTok = p.expectIdentifier("for route id")
  result = GuiRouteDecl(id: idTok.lexeme, range: idTok.range)
  discard p.expectKind(gtkLParen, "after route id")

  if not p.atKind(gtkRParen):
    while not p.atEnd and not p.atKind(gtkRParen):
      let keyTok = p.expectIdentifier("for route field")
      discard p.expectKind(gtkColon, "after route field key")
      let valTok = p.expectIdentifier("for route field value")
      if keyTok.lexeme == "component":
        result.component = valTok.lexeme
      else:
        p.addDiagTok(keyTok, "unsupported route field '" & keyTok.lexeme & "'", "GUI_PARSE_ROUTE_FIELD")

      if p.matchKind(gtkComma):
        continue
      break

  discard p.expectKind(gtkRParen, "to close route declaration")
  p.optionalDelimiter()

proc parseTabsBlock(p: var ParserState): seq[GuiTabDecl] =
  discard p.expectKind(gtkLBrace, "after 'tabs'")
  while not p.atEnd and not p.atKind(gtkRBrace):
    if p.atIdent("tab"):
      discard p.advance()
      result.add p.parseTabDecl()
    else:
      p.addDiagTok(p.curr, "expected 'tab' inside tabs block", "GUI_PARSE_TABS")
      p.synchronizeToDeclBoundary()
      if p.atKind(gtkRBrace):
        break
  discard p.expectKind(gtkRBrace, "to close tabs block")

proc parseStackDecl(p: var ParserState): GuiStackDecl =
  let nameTok = p.expectIdentifier("for stack name")
  result = GuiStackDecl(name: nameTok.lexeme, range: nameTok.range)
  discard p.expectKind(gtkLBrace, "after stack name")

  while not p.atEnd and not p.atKind(gtkRBrace):
    if p.atIdent("route"):
      discard p.advance()
      result.routes.add p.parseRouteDecl()
    else:
      p.addDiagTok(p.curr, "expected 'route' in stack block", "GUI_PARSE_STACK_ROUTE")
      p.synchronizeToDeclBoundary()
      if p.atKind(gtkRBrace):
        break

  discard p.expectKind(gtkRBrace, "to close stack block")

proc parseNavigationBlock(p: var ParserState, tabs: var seq[GuiTabDecl], stacks: var seq[GuiStackDecl]) =
  discard p.expectKind(gtkLBrace, "after 'navigation'")
  while not p.atEnd and not p.atKind(gtkRBrace):
    if p.atIdent("tabs"):
      discard p.advance()
      tabs.add p.parseTabsBlock()
      continue

    if p.atIdent("stack"):
      discard p.advance()
      stacks.add p.parseStackDecl()
      continue

    p.addDiagTok(p.curr, "expected 'tabs' or 'stack' in navigation block", "GUI_PARSE_NAV")
    p.synchronizeToDeclBoundary()
    if p.atKind(gtkRBrace):
      break

  discard p.expectKind(gtkRBrace, "to close navigation block")

proc parseEscapeDecl(p: var ParserState): GuiEscapeDecl =
  let modeTok = p.expectIdentifier("for escape mode")
  if modeTok.lexeme != "swiftFile":
    p.addDiagTok(modeTok, "only escape swiftFile is supported", "GUI_PARSE_ESCAPE_MODE")
  let fileTok = p.expectKind(gtkString, "for escape swift file path")
  result = GuiEscapeDecl(swiftFile: fileTok.lexeme, range: modeTok.range)
  p.optionalDelimiter()

proc parseDeclBody(
  p: var ParserState,
  prog: var GuiProgram,
  localIncludes: var seq[string],
  inAppBlock: bool
)

proc parseAppDecl(p: var ParserState, prog: var GuiProgram, localIncludes: var seq[string]) =
  let appNameTok = p.expectIdentifier("for app name")
  if appNameTok.lexeme.len > 0:
    if prog.appName.len == 0:
      prog.appName = appNameTok.lexeme
    elif prog.appName != appNameTok.lexeme:
      p.addDiagTok(
        appNameTok,
        "multiple app names found ('" & prog.appName & "' and '" & appNameTok.lexeme & "')",
        "GUI_PARSE_APP_DUP"
      )

  if p.matchKind(gtkLBrace):
    while not p.atEnd and not p.atKind(gtkRBrace):
      p.parseDeclBody(prog, localIncludes, inAppBlock = true)
    discard p.expectKind(gtkRBrace, "to close app block")
  else:
    p.optionalDelimiter()

proc parseDeclBody(
  p: var ParserState,
  prog: var GuiProgram,
  localIncludes: var seq[string],
  inAppBlock: bool
) =
  if p.atKind(gtkEof):
    return

  if p.atIdent("include"):
    let kwTok = p.advance()
    if inAppBlock:
      p.addDiagTok(kwTok, "include is only allowed at module top-level", "GUI_PARSE_INCLUDE_SCOPE")
    let includeTok = p.expectKind(gtkString, "after include")
    if includeTok.lexeme.len > 0:
      prog.includes.add includeTok.lexeme
      localIncludes.add includeTok.lexeme
    p.optionalDelimiter()
    return

  if p.atIdent("app"):
    discard p.advance()
    p.parseAppDecl(prog, localIncludes)
    return

  if p.atIdent("tokens"):
    discard p.advance()
    prog.tokens.add p.parseTokensBlock()
    return

  if p.atIdent("model"):
    discard p.advance()
    prog.models.add p.parseModelDecl()
    return

  if p.atIdent("state"):
    discard p.advance()
    prog.stateFields.add p.parseStateBlock()
    return

  if p.atIdent("enum"):
    discard p.advance()
    prog.enums.add p.parseEnumDecl()
    return

  if p.atIdent("action"):
    discard p.advance()
    prog.actions.add p.parseActionDecl()
    return

  if p.atIdent("reducer"):
    discard p.advance()
    prog.reducerCases.add p.parseReducerBlock()
    return

  if p.atIdent("navigation"):
    discard p.advance()
    p.parseNavigationBlock(prog.tabs, prog.stacks)
    return

  if p.atIdent("component"):
    discard p.advance()
    prog.components.add p.parseComponentDecl()
    return

  if p.atIdent("modifier"):
    discard p.advance()
    prog.viewModifiers.add p.parseViewModifierDecl()
    return

  if p.atIdent("escape"):
    discard p.advance()
    prog.escapes.add p.parseEscapeDecl()
    return

  if p.atIdent("bridge"):
    discard p.advance()
    let parsedBridge = p.parseBridgeDecl()
    if prog.bridge.nimEntry.len > 0 and parsedBridge.nimEntry.len > 0 and prog.bridge.nimEntry != parsedBridge.nimEntry:
      p.addDiag(
        parsedBridge.range,
        "multiple bridge nimEntry declarations found",
        "GUI_PARSE_BRIDGE_DUP"
      )
    elif parsedBridge.nimEntry.len > 0:
      prog.bridge = parsedBridge
    return

  if p.atIdent("window"):
    discard p.advance()
    let parsedWindow = p.parseWindowDecl()
    if prog.window.hasWidth and parsedWindow.hasWidth:
      p.addDiag(parsedWindow.range, "duplicate window.width declaration", "GUI_PARSE_WINDOW_DUP")
    if prog.window.hasHeight and parsedWindow.hasHeight:
      p.addDiag(parsedWindow.range, "duplicate window.height declaration", "GUI_PARSE_WINDOW_DUP")
    if prog.window.hasMinWidth and parsedWindow.hasMinWidth:
      p.addDiag(parsedWindow.range, "duplicate window.minWidth declaration", "GUI_PARSE_WINDOW_DUP")
    if prog.window.hasMinHeight and parsedWindow.hasMinHeight:
      p.addDiag(parsedWindow.range, "duplicate window.minHeight declaration", "GUI_PARSE_WINDOW_DUP")
    if prog.window.hasMaxWidth and parsedWindow.hasMaxWidth:
      p.addDiag(parsedWindow.range, "duplicate window.maxWidth declaration", "GUI_PARSE_WINDOW_DUP")
    if prog.window.hasMaxHeight and parsedWindow.hasMaxHeight:
      p.addDiag(parsedWindow.range, "duplicate window.maxHeight declaration", "GUI_PARSE_WINDOW_DUP")
    if prog.window.hasTitle and parsedWindow.hasTitle:
      p.addDiag(parsedWindow.range, "duplicate window.title declaration", "GUI_PARSE_WINDOW_DUP")
    if prog.window.hasClosePolicy and parsedWindow.hasClosePolicy:
      p.addDiag(
        parsedWindow.range,
        "duplicate window.closeAppOnLastWindowClose declaration",
        "GUI_PARSE_WINDOW_DUP"
      )
    if prog.window.hasShowTitleBar and parsedWindow.hasShowTitleBar:
      p.addDiag(
        parsedWindow.range,
        "duplicate window.showTitleBar declaration",
        "GUI_PARSE_WINDOW_DUP"
      )
    if prog.window.hasSuppressDefaultMenus and parsedWindow.hasSuppressDefaultMenus:
      p.addDiag(
        parsedWindow.range,
        "duplicate window.suppressDefaultMenus declaration",
        "GUI_PARSE_WINDOW_DUP"
      )

    if parsedWindow.hasWidth:
      prog.window.width = parsedWindow.width
      prog.window.hasWidth = true
    if parsedWindow.hasHeight:
      prog.window.height = parsedWindow.height
      prog.window.hasHeight = true
    if parsedWindow.hasMinWidth:
      prog.window.minWidth = parsedWindow.minWidth
      prog.window.hasMinWidth = true
    if parsedWindow.hasMinHeight:
      prog.window.minHeight = parsedWindow.minHeight
      prog.window.hasMinHeight = true
    if parsedWindow.hasMaxWidth:
      prog.window.maxWidth = parsedWindow.maxWidth
      prog.window.hasMaxWidth = true
    if parsedWindow.hasMaxHeight:
      prog.window.maxHeight = parsedWindow.maxHeight
      prog.window.hasMaxHeight = true
    if parsedWindow.hasTitle:
      prog.window.title = parsedWindow.title
      prog.window.hasTitle = true
    if parsedWindow.hasClosePolicy:
      prog.window.closeAppOnLastWindowClose = parsedWindow.closeAppOnLastWindowClose
      prog.window.hasClosePolicy = true
    if parsedWindow.hasShowTitleBar:
      prog.window.showTitleBar = parsedWindow.showTitleBar
      prog.window.hasShowTitleBar = true
    if parsedWindow.hasSuppressDefaultMenus:
      prog.window.suppressDefaultMenus = parsedWindow.suppressDefaultMenus
      prog.window.hasSuppressDefaultMenus = true
    prog.window.range = parsedWindow.range
    return

  if p.atIdent("settings"):
    discard p.advance()
    let compName = p.expectIdentifier("for settings component name")
    prog.settingsComponent = compName.lexeme
    return

  p.addDiagTok(p.curr, "unexpected top-level token", "GUI_PARSE_DECL")
  p.synchronizeToDeclBoundary()
  if not p.atKind(gtkEof) and not p.atKind(gtkRBrace):
    discard p.advance()

proc parseOneFile(
  file: string,
  content: string,
  prog: var GuiProgram
): tuple[diagnostics: seq[GuiDiagnostic], includes: seq[string]] =
  let (tokens, lexDiags) = lexGui(file, content)
  result.diagnostics.add lexDiags

  var p = ParserState(file: file, tokens: tokens, idx: 0)
  while not p.atEnd:
    p.parseDeclBody(prog, result.includes, inAppBlock = false)

  result.diagnostics.add p.diagnostics

proc hasGlobChars(path: string): bool {.inline.} =
  for c in path:
    if c in {'*', '?', '['}:
      return true
  false

proc matchesSimpleGlob(filename, pattern: string): bool =
  ## Matches a filename against a simple glob pattern (supports only `*`).
  ## Used instead of walkPattern which relies on C-level glob() unavailable
  ## at Nim compile time.
  if pattern == "*":
    return true
  if '*' notin pattern:
    return filename == pattern
  # Split on '*' and check prefix/suffix
  let parts = pattern.split('*')
  if parts.len == 2:
    # "prefix*suffix" pattern (e.g. "*.gui", "test_*")
    let prefix = parts[0]
    let suffix = parts[1]
    return filename.startsWith(prefix) and filename.endsWith(suffix) and
           filename.len >= prefix.len + suffix.len
  # Fallback: just check if it contains all literal parts in order
  var pos = 0
  for part in parts:
    if part.len == 0: continue
    let idx = filename.find(part, pos)
    if idx < 0: return false
    pos = idx + part.len
  true

proc resolveIncludePaths(baseFile: string, pattern: string): seq[string] =
  let baseDir = baseFile.parentDir()
  let joined = if pattern.isAbsolute: pattern else: baseDir / pattern

  if hasGlobChars(joined):
    # Use walkDir + manual matching instead of walkPattern (which uses C glob()
    # and fails at Nim compile time).
    let dir = joined.parentDir()
    let filePattern = joined.extractFilename()
    if dir.dirExists:
      for kind, path in walkDir(dir):
        if kind in {pcFile, pcLinkToFile}:
          let fname = path.extractFilename()
          if matchesSimpleGlob(fname, filePattern) and
             fname.toLowerAscii().endsWith(".gui"):
            result.add normalizedPath(path)
  else:
    let normalized = normalizedPath(joined)
    if normalized.fileExists:
      result.add normalized

  result.sort(cmp[string])

proc visitGuiFile(
  path: string,
  prog: var GuiProgram,
  diagnostics: var seq[GuiDiagnostic],
  visited: var HashSet[string]
) =
  if path in visited:
    return
  visited.incl path
  prog.loadedFiles.add path

  if not path.fileExists:
    diagnostics.add mkDiagnostic(path, 1, 1, gsError, "file not found", "GUI_PARSE_FILE")
    return

  var content = ""
  try:
    content = readFile(path)
  except CatchableError as e:
    diagnostics.add mkDiagnostic(path, 1, 1, gsError, "failed to read file: " & e.msg, "GUI_PARSE_IO")
    return

  let parsed = parseOneFile(path, content, prog)
  diagnostics.add parsed.diagnostics

  for incPattern in parsed.includes:
    let paths = resolveIncludePaths(path, incPattern)
    if paths.len == 0:
      diagnostics.add mkDiagnostic(
        path,
        1,
        1,
        gsError,
        "include pattern matched no files: " & incPattern,
        "GUI_PARSE_INCLUDE"
      )
    for resolved in paths:
      visitGuiFile(resolved, prog, diagnostics, visited)

proc extractSwiftViewNames(swiftContent: string): seq[string] =
  ## Extract struct names conforming to View from a Swift file.
  ## Matches patterns like: struct FooView: View {
  ##   or: struct FooView : View {
  ##   or: struct FooView: SomeProtocol, View {
  for line in swiftContent.splitLines():
    let stripped = line.strip()
    if not stripped.startsWith("struct "):
      continue
    let afterStruct = stripped[7..^1].strip()
    let colonIdx = afterStruct.find(':')
    if colonIdx < 0:
      continue
    let structName = afterStruct[0 ..< colonIdx].strip()
    if structName.len == 0 or structName[0] < 'A' or structName[0] > 'Z':
      continue
    # Check if "View" appears in the conformance list
    let conformances = afterStruct[colonIdx + 1 .. ^1].strip()
    for part in conformances.split(','):
      let trimmed = part.strip()
      # Strip everything after { or where
      var proto = trimmed
      let braceIdx = proto.find('{')
      if braceIdx >= 0:
        proto = proto[0 ..< braceIdx].strip()
      let whereIdx = proto.find("where")
      if whereIdx >= 0:
        proto = proto[0 ..< whereIdx].strip()
      if proto in ["View", "NSViewRepresentable", "UIViewRepresentable"]:
        result.add structName
        break

proc parseGuiProgram*(entryFile: string): tuple[program: GuiProgram, diagnostics: seq[GuiDiagnostic]] =
  let normalizedEntry = normalizedPath(entryFile)
  var prog = GuiProgram(entryFile: normalizedEntry)
  var diagnostics: seq[GuiDiagnostic] = @[]
  var visited: HashSet[string]

  visitGuiFile(normalizedEntry, prog, diagnostics, visited)

  # Extract view names from escape Swift files
  let entryDir = normalizedEntry.parentDir()
  for esc in prog.escapes:
    if esc.swiftFile.len > 0:
      let swiftPath = if esc.swiftFile.isAbsolute: esc.swiftFile
                      else: entryDir / esc.swiftFile
      if swiftPath.fileExists:
        try:
          let content = readFile(swiftPath)
          for viewName in extractSwiftViewNames(content):
            prog.escapeViewNames.add viewName
        except CatchableError:
          discard

  result = (prog, diagnostics)
