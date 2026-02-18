## HTTP Router DSL
##
## Provides a Jester/Sinatra-style macro DSL for defining HTTP routes.
##
## Usage:
##   let app = router:
##     get "/":
##       respond 200, "Hello World"
##     post "/users":
##       let data = body()
##       respond 201, "Created: " & data
##     get "/users/{id}":
##       let userId = pathParams["id"]
##       respond 200, "User: " & userId

import std/[macros, tables, strutils, json]
import ../../runtime
import ../../transform
import ../../eventloop
import ./types
import ./router
import ./sse
import ./ws
import ../shared/compression
import ../shared/multipart
import ../middleware/ratelimit
import ./chunked

export types, router, runtime, transform, eventloop, tables, json, sse, ws, compression, multipart, chunked

# ============================================================
# Helper to avoid ident ambiguity
# ============================================================

proc mkIdent(name: string): NimNode {.compileTime.} =
  ## Create an ident node without triggering Nim's ident/newIdentNode overload ambiguity.
  parseExpr(name)

# ============================================================
# Rewrite context (macro hygiene)
# ============================================================

type
  RewriteCtx = object
    reqId: NimNode
    ppId: NimNode
    qpId: NimNode
    headersId: NimNode
    formParsedId: NimNode
    formBodyId: NimNode
    jsonParsedId: NimNode
    jsonBodyId: NimNode
    sseWriterId: NimNode
    wsConnId: NimNode
    streamWriterId: NimNode
    errorId: NimNode

var rewriteCtxStack {.compileTime.}: seq[RewriteCtx]
var rewriteCtxIdCounter {.compileTime.}: int

proc defaultRewriteCtx(): RewriteCtx {.compileTime.} =
  result.reqId = mkIdent("req")
  result.ppId = mkIdent("pathParams")
  result.qpId = mkIdent("queryParams")
  result.headersId = mkIdent("dslHeaders")
  result.formParsedId = mkIdent("dslFormParsed")
  result.formBodyId = mkIdent("dslFormBody")
  result.jsonParsedId = mkIdent("dslJsonParsed")
  result.jsonBodyId = mkIdent("dslJsonBody")
  result.sseWriterId = mkIdent("sseWriter")
  result.wsConnId = mkIdent("wsConn")
  result.streamWriterId = mkIdent("streamWriter")
  result.errorId = mkIdent("dslError")

proc newRewriteCtx(reqId, ppId, qpId: NimNode): RewriteCtx {.compileTime.} =
  let ctxId = rewriteCtxIdCounter
  inc rewriteCtxIdCounter
  let prefix = "cpsDslCtx" & $ctxId & "_"
  result.reqId = reqId
  result.ppId = ppId
  result.qpId = qpId
  result.headersId = mkIdent(prefix & "headers")
  result.formParsedId = mkIdent(prefix & "formParsed")
  result.formBodyId = mkIdent(prefix & "formBody")
  result.jsonParsedId = mkIdent(prefix & "jsonParsed")
  result.jsonBodyId = mkIdent(prefix & "jsonBody")
  result.sseWriterId = mkIdent(prefix & "sseWriter")
  result.wsConnId = mkIdent(prefix & "wsConn")
  result.streamWriterId = mkIdent(prefix & "streamWriter")
  result.errorId = mkIdent(prefix & "error")

# ============================================================
# Handler body rewriting
# ============================================================

proc rewriteHandlerBody(body: NimNode): NimNode =
  ## Recursively rewrite DSL sugar in handler bodies.
  if body.kind == nnkEmpty:
    return body

  let ctx = if rewriteCtxStack.len > 0: rewriteCtxStack[^1] else: defaultRewriteCtx()

  # Handle call/command nodes
  if body.kind in {nnkCall, nnkCommand}:
    let name = if body[0].kind == nnkIdent: $body[0] else: ""
    let hdrsId = ctx.headersId
    let reqId = ctx.reqId
    let ppId = ctx.ppId
    let qpId = ctx.qpId
    let formParsedId = ctx.formParsedId
    let formBodyId = ctx.formBodyId
    let jsonParsedId = ctx.jsonParsedId
    let jsonBodyId = ctx.jsonBodyId
    let sseWriterId = ctx.sseWriterId
    let wsConnId = ctx.wsConnId
    let streamWriterId = ctx.streamWriterId
    let errorId = ctx.errorId

    case name
    of "respond":
      if body.len == 3:
        let code = body[1]
        let respBody = rewriteHandlerBody(body[2])
        return quote do:
          return newResponse(`code`, `respBody`, `hdrsId`)
      elif body.len == 4:
        let code = body[1]
        let respBody = rewriteHandlerBody(body[2])
        let extraHdrs = rewriteHandlerBody(body[3])
        return quote do:
          return newResponse(`code`, `respBody`, `hdrsId` & `extraHdrs`)
      elif body.len == 2:
        let code = body[1]
        return quote do:
          return newResponse(`code`, "", `hdrsId`)

    of "body":
      if body.len == 1:
        return newDotExpr(reqId, mkIdent("body"))

    of "method":
      if body.len == 1:
        return newDotExpr(reqId, mkIdent("meth"))

    of "path":
      if body.len == 1:
        return newDotExpr(reqId, mkIdent("path"))

    of "header":
      if body.len == 2:
        let headerName = body[1]
        return newCall(mkIdent("getHeader"), reqId, headerName)

    of "queryParam":
      if body.len == 2:
        let key = body[1]
        return newCall(newDotExpr(qpId, mkIdent("getOrDefault")), key)
      elif body.len == 3:
        let key = body[1]
        let default = body[2]
        return newCall(newDotExpr(qpId, mkIdent("getOrDefault")), key, default)

    of "pathInt":
      if body.len == 2:
        return newCall(mkIdent("pathParamInt"), ppId, body[1])

    of "pathFloat":
      if body.len == 2:
        return newCall(mkIdent("pathParamFloat"), ppId, body[1])

    of "pathBool":
      if body.len == 2:
        return newCall(mkIdent("pathParamBool"), ppId, body[1])

    of "queryInt":
      if body.len == 2:
        return newCall(mkIdent("queryParamInt"), qpId, body[1])
      elif body.len == 3:
        return newCall(mkIdent("queryParamInt"), qpId, body[1], rewriteHandlerBody(body[2]))

    of "queryFloat":
      if body.len == 2:
        return newCall(mkIdent("queryParamFloat"), qpId, body[1])
      elif body.len == 3:
        return newCall(mkIdent("queryParamFloat"), qpId, body[1], rewriteHandlerBody(body[2]))

    of "queryBool":
      if body.len == 2:
        return newCall(mkIdent("queryParamBool"), qpId, body[1])
      elif body.len == 3:
        return newCall(mkIdent("queryParamBool"), qpId, body[1], rewriteHandlerBody(body[2]))

    of "getCookie":
      if body.len == 2:
        let cookieName = body[1]
        return newCall(mkIdent("getCookie"), reqId, cookieName)

    of "json":
      if body.len == 3:
        let code = body[1]
        let respBody = rewriteHandlerBody(body[2])
        return quote do:
          return jsonResponse(`code`, `respBody`, `hdrsId`)

    of "html":
      if body.len == 3:
        let code = body[1]
        let respBody = rewriteHandlerBody(body[2])
        return quote do:
          return htmlResponse(`code`, `respBody`, `hdrsId`)

    of "text":
      if body.len == 3:
        let code = body[1]
        let respBody = rewriteHandlerBody(body[2])
        return quote do:
          return textResponse(`code`, `respBody`, `hdrsId`)

    of "redirect":
      if body.len == 2:
        let location = body[1]
        return quote do:
          return redirectResponse(`location`)
      elif body.len == 3:
        let code = body[1]
        let location = body[2]
        return quote do:
          return redirectResponse(`location`, `code`)

    of "setCookie":
      if body.len == 3:
        let cookieName = body[1]
        let cookieValue = body[2]
        return newCall(
          newDotExpr(hdrsId, mkIdent("add")),
          newCall(mkIdent("setCookieHeader"), cookieName, cookieValue)
        )
      elif body.len >= 4:
        var args = newCall(mkIdent("setCookieHeader"))
        for i in 1 ..< body.len:
          args.add body[i]
        return newCall(newDotExpr(hdrsId, mkIdent("add")), args)

    # --- Status code shortcut helpers (Phase 2) ---

    of "created":
      if body.len == 2:
        # created "/location"
        let loc = rewriteHandlerBody(body[1])
        return quote do:
          return newResponse(201, "", `hdrsId` & @[("Location", `loc`)])
      elif body.len == 3:
        # created "/location", body
        let loc = rewriteHandlerBody(body[1])
        let respBody = rewriteHandlerBody(body[2])
        return quote do:
          return newResponse(201, `respBody`, `hdrsId` & @[("Location", `loc`)])

    of "noContent":
      return quote do:
        return newResponse(204, "", `hdrsId`)

    of "notModified":
      return quote do:
        return newResponse(304, "", `hdrsId`)

    of "badRequest":
      if body.len == 1:
        return quote do:
          return newResponse(400, "", `hdrsId`)
      elif body.len == 2:
        let respBody = rewriteHandlerBody(body[1])
        return quote do:
          return newResponse(400, `respBody`, `hdrsId`)

    of "unauthorized":
      if body.len == 1:
        return quote do:
          return newResponse(401, "", `hdrsId`)
      elif body.len == 2:
        let respBody = rewriteHandlerBody(body[1])
        return quote do:
          return newResponse(401, `respBody`, `hdrsId`)

    of "forbidden":
      if body.len == 1:
        return quote do:
          return newResponse(403, "", `hdrsId`)
      elif body.len == 2:
        let respBody = rewriteHandlerBody(body[1])
        return quote do:
          return newResponse(403, `respBody`, `hdrsId`)

    of "serverError":
      if body.len == 1:
        return quote do:
          return newResponse(500, "", `hdrsId`)
      elif body.len == 2:
        let respBody = rewriteHandlerBody(body[1])
        return quote do:
          return newResponse(500, `respBody`, `hdrsId`)

    # --- File response helpers (Phase 2) ---

    of "sendFile":
      if body.len == 2:
        let filePath = rewriteHandlerBody(body[1])
        return quote do:
          return await fileResponse(`filePath`)

    of "download":
      if body.len == 2:
        let filePath = rewriteHandlerBody(body[1])
        return quote do:
          return await downloadResponse(`filePath`)
      elif body.len == 3:
        let filePath = rewriteHandlerBody(body[1])
        let fname = rewriteHandlerBody(body[2])
        return quote do:
          return await downloadResponse(`filePath`, `fname`)

    # --- Request context (Phase 2) ---

    of "ctx":
      if body.len == 2:
        let key = body[1]
        return quote do:
          req.context.getOrDefault(`key`)

    of "setCtx":
      if body.len == 3:
        let key = body[1]
        let val = rewriteHandlerBody(body[2])
        return quote do:
          req.context[`key`] = `val`

    # --- Form body parsing (Phase 1) ---

    of "formParam":
      if body.len == 2:
        let key = body[1]
        return quote do:
          block:
            if not `formParsedId`:
              `formBodyId` = parseFormBody(`reqId`.body)
              `formParsedId` = true
            `formBodyId`.getOrDefault(`key`)
      elif body.len == 3:
        let key = body[1]
        let default = body[2]
        return quote do:
          block:
            if not `formParsedId`:
              `formBodyId` = parseFormBody(`reqId`.body)
              `formParsedId` = true
            `formBodyId`.getOrDefault(`key`, `default`)

    of "formParams":
      if body.len == 1:
        return quote do:
          block:
            if not `formParsedId`:
              `formBodyId` = parseFormBody(`reqId`.body)
              `formParsedId` = true
            `formBodyId`

    # --- JSON body parsing (Phase 3) ---

    of "jsonBody":
      if body.len == 1:
        return quote do:
          block:
            if not `jsonParsedId`:
              `jsonBodyId` = parseJsonBody(`reqId`.body)
              `jsonParsedId` = true
            `jsonBodyId`

    # --- Request extraction helpers ---

    of "clientIp":
      if body.len == 1:
        return newCall(mkIdent("extractClientIp"), reqId)

    of "bearerToken":
      if body.len == 1:
        return newCall(mkIdent("extractBearerToken"), reqId)

    of "basicAuth":
      if body.len == 1:
        return newCall(mkIdent("parseBasicAuth"), reqId)

    of "escapeHtml":
      if body.len == 2:
        let s = rewriteHandlerBody(body[1])
        return newCall(mkIdent("escapeHtml"), s)

    # --- Pass (next-route) control flow ---

    of "pass":
      if body.len == 1:
        return quote do:
          return passRouteResponse(`hdrsId`)

    # --- Halt shorthand ---

    of "halt":
      if body.len == 1:
        return quote do:
          return newResponse(200, "", `hdrsId`)
      elif body.len == 2:
        let code = body[1]
        return quote do:
          return newResponse(`code`, "", `hdrsId`)
      elif body.len == 3:
        let code = body[1]
        let respBody = rewriteHandlerBody(body[2])
        return quote do:
          return newResponse(`code`, `respBody`, `hdrsId`)

    # --- ETag helper for dynamic responses ---

    of "etag":
      if body.len == 2:
        let etagVal = rewriteHandlerBody(body[1])
        return quote do:
          if checkEtag(req, `etagVal`):
            return newResponse(304, "", @[("ETag", `etagVal`)])
          `hdrsId`.add ("ETag", `etagVal`)

    # --- Cache-Control helpers ---

    of "cacheControl":
      if body.len == 2:
        let directive = rewriteHandlerBody(body[1])
        return newCall(
          newDotExpr(hdrsId, mkIdent("add")),
          newNimNode(nnkTupleConstr).add(newStrLitNode("Cache-Control"), directive)
        )

    of "noCache":
      if body.len == 1:
        return newCall(
          newDotExpr(hdrsId, mkIdent("add")),
          newNimNode(nnkTupleConstr).add(newStrLitNode("Cache-Control"), newStrLitNode("no-store, no-cache, must-revalidate"))
        )

    # --- JSON body parsing (typed) ---

    of "jsonAs":
      if body.len == 2:
        let typeNode = body[1]
        return quote do:
          block:
            if not `jsonParsedId`:
              `jsonBodyId` = parseJsonBody(`reqId`.body)
              `jsonParsedId` = true
            to(`jsonBodyId`, `typeNode`)

    # --- Multipart DSL keywords ---

    of "upload":
      if body.len == 2:
        let fieldName = body[1]
        return quote do:
          getUploadedFile(req.body, req.getHeader("content-type"), `fieldName`)

    of "uploads":
      if body.len == 2:
        let fieldName = body[1]
        return quote do:
          getUploadedFiles(req.body, req.getHeader("content-type"), `fieldName`)

    of "formField":
      if body.len == 2:
        let fieldName = body[1]
        return quote do:
          getMultipartField(req.body, req.getHeader("content-type"), `fieldName`)

    # --- Error handler keywords ---

    of "errorMessage":
      if body.len == 1:
        return newDotExpr(errorId, mkIdent("msg"))

    of "errorType":
      if body.len == 1:
        return newCall(mkIdent("name"), newCall(mkIdent("typeof"), errorId))

    # --- SSE keywords ---

    of "sendEvent":
      var call = newCall(newDotExpr(sseWriterId, mkIdent("sendEvent")))
      for i in 1 ..< body.len:
        call.add body[i]
      return call

    of "sendComment":
      var call = newCall(newDotExpr(sseWriterId, mkIdent("sendComment")))
      for i in 1 ..< body.len:
        call.add body[i]
      return call

    of "lastEventId":
      return newCall(mkIdent("getHeader"), reqId, newStrLitNode("Last-Event-ID"))

    of "closeSse":
      return newCall(newDotExpr(sseWriterId, mkIdent("close")))

    of "initSse":
      return newCall(mkIdent("initSse"), newDotExpr(reqId, mkIdent("stream")), hdrsId, reqId)

    # --- WebSocket keywords ---

    of "recvMessage":
      return newCall(newDotExpr(wsConnId, mkIdent("recvMessage")))

    of "sendText":
      var call = newCall(newDotExpr(wsConnId, mkIdent("sendText")))
      for i in 1 ..< body.len:
        call.add rewriteHandlerBody(body[i])
      return call

    of "sendBinary":
      var call = newCall(newDotExpr(wsConnId, mkIdent("sendBinary")))
      for i in 1 ..< body.len:
        call.add rewriteHandlerBody(body[i])
      return call

    of "sendPing":
      var call = newCall(newDotExpr(wsConnId, mkIdent("sendPing")))
      for i in 1 ..< body.len:
        call.add rewriteHandlerBody(body[i])
      return call

    of "sendPong":
      var call = newCall(newDotExpr(wsConnId, mkIdent("sendPong")))
      for i in 1 ..< body.len:
        call.add rewriteHandlerBody(body[i])
      return call

    of "sendClose":
      var call = newCall(newDotExpr(wsConnId, mkIdent("sendClose")))
      for i in 1 ..< body.len:
        call.add rewriteHandlerBody(body[i])
      return call

    of "closeWs":
      return newCall(newDotExpr(wsConnId, mkIdent("close")))

    # --- Content negotiation accept block ---

    of "accept":
      if body.len == 2 and body[1].kind == nnkStmtList:
        let acceptBlock = body[1]
        var branches: seq[(string, NimNode)]
        for child in acceptBlock:
          if child.kind in {nnkCall, nnkCommand} and child[0].kind == nnkStrLit:
            let mimeType = $child[0].strVal
            let branchBody = if child.len == 2 and child[1].kind == nnkStmtList:
              rewriteHandlerBody(child[1])
            elif child.len == 2:
              rewriteHandlerBody(child[1])
            else:
              newStmtList()
            branches.add (mimeType, branchBody)

        if branches.len == 0:
          return quote do:
            return newResponse(406, "Not Acceptable", `hdrsId`)

        var available = newNimNode(nnkPrefix).add(ident("@"), newNimNode(nnkBracket))
        for (mime, _) in branches:
          available[1].add newStrLitNode(mime)

        let negotiatedSym = genSym(nskLet, "negotiatedContentType")
        var caseStmt = newNimNode(nnkCaseStmt).add(negotiatedSym)
        for (mime, branchBody) in branches:
          let branchStmt = if branchBody.kind == nnkStmtList: branchBody else: newStmtList(branchBody)
          caseStmt.add newNimNode(nnkOfBranch).add(newStrLitNode(mime), branchStmt)

        caseStmt.add newNimNode(nnkElse).add(newStmtList(
          newNimNode(nnkReturnStmt).add(
            newCall(mkIdent("newResponse"), newIntLitNode(406), newStrLitNode("Not Acceptable"), hdrsId)
          )
        ))

        return quote do:
          let `negotiatedSym` = negotiateContentType(req.getHeader("accept"), `available`)
          `caseStmt`

    # --- Template engine hook ---

    of "render":
      if body.len == 2:
        let templateName = body[1]
        return quote do:
          return renderTemplate(`reqId`, `templateName`, `hdrsId`)
      elif body.len == 3:
        let templateName = body[1]
        let ctx = rewriteHandlerBody(body[2])
        return quote do:
          return renderTemplate(`reqId`, `templateName`, `ctx`, `hdrsId`)

    # --- Auto JSON serialization: json 200, myObject ---
    # Already handled in "json" case above when body is not a string literal
    # The existing handler passes through non-string args which works with $(%*)

    # --- Chunked streaming keywords ---

    of "sendChunk":
      var call = newCall(newDotExpr(streamWriterId, mkIdent("sendChunk")))
      for i in 1 ..< body.len:
        call.add rewriteHandlerBody(body[i])
      return call

    of "endStream":
      return newCall(newDotExpr(streamWriterId, mkIdent("endChunked")))

    of "initStream":
      if body.len == 1:
        return newCall(mkIdent("initChunked"), newDotExpr(reqId, mkIdent("stream")),
                       newIntLitNode(200), hdrsId)
      elif body.len == 2:
        let code = body[1]
        return newCall(mkIdent("initChunked"), newDotExpr(reqId, mkIdent("stream")),
                       code, hdrsId)

    # --- OpenAPI annotation keywords (stripped from handler body) ---

    of "summary", "tag", "description", "deprecated":
      # These are compile-time annotations for OpenAPI spec generation.
      # Strip them from the handler body (they're extracted by the macro).
      return newStmtList()

    # --- Background tasks (Phase 6) ---

    of "background":
      if body.len == 2 and body[1].kind == nnkStmtList:
        let bgBody = rewriteHandlerBody(body[1])
        let bgProcName = genSym(nskProc, "bgTask")
        let bgReqId = mkIdent("req")
        # Generate a CPS proc and schedule it
        return quote do:
          proc `bgProcName`(): CpsVoidFuture {.cps.} =
            `bgBody`
          scheduleCallback(proc() = discard `bgProcName`())

    else:
      discard

  # Handle bracket expr for typed params: pathParam[int]("id"), queryParam[int]("page")
  if body.kind == nnkCall and body[0].kind == nnkBracketExpr:
    let bracketExpr = body[0]
    if bracketExpr[0].kind == nnkIdent:
      let bracketName = $bracketExpr[0]
      if bracketName == "pathParam" and bracketExpr.len == 2 and body.len == 2:
        let typeNode = bracketExpr[1]
        let paramKey = body[1]
        let ppId = mkIdent("pathParams")
        let typeName = if typeNode.kind == nnkIdent: $typeNode else: "string"
        case typeName
        of "int":
          return quote do:
            pathParamInt(`ppId`, `paramKey`)
        of "float":
          return quote do:
            pathParamFloat(`ppId`, `paramKey`)
        of "bool":
          return quote do:
            pathParamBool(`ppId`, `paramKey`)
        else:
          return quote do:
            pathParamValue(`ppId`, `paramKey`)
      elif bracketName == "queryParam" and bracketExpr.len == 2 and body.len >= 2:
        let typeNode = bracketExpr[1]
        let paramKey = body[1]
        let qpId = mkIdent("queryParams")
        let typeName = if typeNode.kind == nnkIdent: $typeNode else: "string"
        if body.len == 3:
          # queryParam[int]("page", "1") — with default
          let default = body[2]
          case typeName
          of "int":
            return quote do:
              queryParamInt(`qpId`, `paramKey`, `default`)
          of "float":
            return quote do:
              queryParamFloat(`qpId`, `paramKey`, `default`)
          of "bool":
            return quote do:
              queryParamBool(`qpId`, `paramKey`, `default`)
          else:
            return quote do:
              `qpId`.getOrDefault(`paramKey`, `default`)
        else:
          case typeName
          of "int":
            return quote do:
              queryParamInt(`qpId`, `paramKey`)
          of "float":
            return quote do:
              queryParamFloat(`qpId`, `paramKey`)
          of "bool":
            return quote do:
              queryParamBool(`qpId`, `paramKey`)
          else:
            return quote do:
              `qpId`.getOrDefault(`paramKey`)
      elif bracketName == "state" and bracketExpr.len == 2 and body.len == 1:
        # state[MyType]() — typed application state
        let typeNode = bracketExpr[1]
        let expectedTypeName = newStrLitNode(repr(typeNode))
        let reqIdState = ctx.reqId
        return quote do:
          block:
            if `reqIdState`.appState.isNil:
              raise newException(ValueError, "router appState is nil; set appState in router")
            if not (`reqIdState`.appState of `typeNode`):
              raise newException(ValueError, "router appState type mismatch; expected " & `expectedTypeName`)
            `typeNode`(`reqIdState`.appState)

  # Handle bare ident annotations (e.g., `deprecated` without args)
  if body.kind == nnkIdent:
    let bareIdent = ($body).toLowerAscii
    if bareIdent == "deprecated":
      return newStmtList()

  # Recurse into children
  result = body.copyNimNode()
  for child in body:
    result.add rewriteHandlerBody(child)

proc rewriteWithContext(body: NimNode, ctx: RewriteCtx): NimNode {.compileTime.} =
  rewriteCtxStack.add(ctx)
  try:
    result = rewriteHandlerBody(body)
  finally:
    discard rewriteCtxStack.pop()

# ============================================================
# OpenAPI compile-time helpers
# ============================================================

type
  RouteOpenApiSpec = object
    path: string
    httpMethod: string
    summary: string
    tag: string
    description: string
    deprecated: bool
    pathParams: seq[(string, string)]  # (name, type)

proc extractAnnotation(body: NimNode, name: string): string {.compileTime.} =
  ## Extract a string annotation value from a handler body.
  if body.kind != nnkStmtList: return ""
  for child in body:
    if child.kind in {nnkCall, nnkCommand} and child[0].kind == nnkIdent:
      if ($child[0]).toLowerAscii == name:
        if child.len >= 2 and child[1].kind == nnkStrLit:
          return child[1].strVal
  return ""

proc hasAnnotation(body: NimNode, name: string): bool {.compileTime.} =
  ## Check if a handler body contains a bare keyword or call annotation.
  if body.kind != nnkStmtList: return false
  for child in body:
    if child.kind == nnkIdent and ($child).toLowerAscii == name:
      return true
    if child.kind in {nnkCall, nnkCommand} and child[0].kind == nnkIdent:
      if ($child[0]).toLowerAscii == name:
        return true
  return false

proc extractPathParamsFromPattern(pattern: string): seq[(string, string)] {.compileTime.} =
  ## Extract path parameters and their types from a route pattern.
  let cleaned = pattern.strip(chars = {'/'})
  if cleaned.len == 0: return @[]
  for part in cleaned.split('/'):
    if part.len > 2 and part[0] == '{' and part[^1] == '}':
      var inner = part[1..^2]
      if inner.endsWith("?"):
        inner = inner[0..^2]
      let colonIdx = inner.find(':')
      if colonIdx >= 0:
        result.add (inner[0 ..< colonIdx], inner[colonIdx + 1 .. ^1])
      else:
        result.add (inner, "string")

proc patternToOpenApi(pattern: string): string {.compileTime.} =
  ## Convert a route pattern to OpenAPI format (strip type constraints).
  result = ""
  let cleaned = pattern.strip(chars = {'/'})
  if cleaned.len == 0: return "/"
  for part in cleaned.split('/'):
    if part.len == 0: continue
    result.add "/"
    if part.len > 2 and part[0] == '{' and part[^1] == '}':
      var inner = part[1..^2]
      if inner.endsWith("?"):
        inner = inner[0..^2]
      let colonIdx = inner.find(':')
      if colonIdx >= 0:
        inner = inner[0 ..< colonIdx]
      result.add "{" & inner & "}"
    elif part == "*":
      discard  # Skip wildcards in OpenAPI
    else:
      result.add part
  if result.len == 0:
    result = "/"

proc escJsonStr(s: string): string {.compileTime.} =
  ## Escape a string for JSON embedding.
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add c
  result.add "\""

proc generateOpenApiJson(specs: seq[RouteOpenApiSpec],
                          title, version, description: string): string {.compileTime.} =
  ## Generate an OpenAPI 3.0.3 JSON spec string at compile time.
  result = "{"
  result.add "\"openapi\":" & escJsonStr("3.0.3") & ","
  result.add "\"info\":{"
  result.add "\"title\":" & escJsonStr(if title.len > 0: title else: "API") & ","
  result.add "\"version\":" & escJsonStr(version)
  if description.len > 0:
    result.add ",\"description\":" & escJsonStr(description)
  result.add "},"

  # Group specs by OpenAPI path
  type PathGroup = object
    path: string
    specs: seq[RouteOpenApiSpec]
  var groups: seq[PathGroup]
  for spec in specs:
    let oaPath = patternToOpenApi(spec.path)
    var found = false
    for i in 0 ..< groups.len:
      if groups[i].path == oaPath:
        groups[i].specs.add spec
        found = true
        break
    if not found:
      groups.add PathGroup(path: oaPath, specs: @[spec])

  result.add "\"paths\":{"
  var firstPath = true
  for group in groups:
    if not firstPath: result.add ","
    firstPath = false
    result.add escJsonStr(group.path) & ":{"
    var firstOp = true
    for spec in group.specs:
      let meth = if spec.httpMethod == "*": "get" else: spec.httpMethod.toLowerAscii
      if meth in ["get", "post", "put", "delete", "patch", "head", "options"]:
        if not firstOp: result.add ","
        firstOp = false
        result.add escJsonStr(meth) & ":{"
        var parts: seq[string]
        if spec.summary.len > 0:
          parts.add "\"summary\":" & escJsonStr(spec.summary)
        if spec.description.len > 0:
          parts.add "\"description\":" & escJsonStr(spec.description)
        if spec.tag.len > 0:
          parts.add "\"tags\":[" & escJsonStr(spec.tag) & "]"
        if spec.deprecated:
          parts.add "\"deprecated\":true"

        if spec.pathParams.len > 0:
          var paramStr = "\"parameters\":["
          var firstParam = true
          for (pname, ptyp) in spec.pathParams:
            if not firstParam: paramStr.add ","
            firstParam = false
            paramStr.add "{"
            paramStr.add "\"name\":" & escJsonStr(pname) & ","
            paramStr.add "\"in\":\"path\","
            paramStr.add "\"required\":true,"
            case ptyp
            of "int":
              paramStr.add "\"schema\":{\"type\":\"integer\"}"
            of "float":
              paramStr.add "\"schema\":{\"type\":\"number\"}"
            of "uuid":
              paramStr.add "\"schema\":{\"type\":\"string\",\"format\":\"uuid\"}"
            else:
              paramStr.add "\"schema\":{\"type\":\"string\"}"
            paramStr.add "}"
          paramStr.add "]"
          parts.add paramStr

        parts.add "\"responses\":{\"200\":{\"description\":\"Successful response\"}}"
        result.add parts.join(",")
        result.add "}"
    result.add "}"
  result.add "}"  # close paths
  result.add "}"  # close root

# ============================================================
# Helper: build a route handler proc AST
# ============================================================

proc containsSymbol(node: NimNode, sym: NimNode): bool {.compileTime.} =
  if node.kind in {nnkIdent, nnkSym} and $node == $sym:
    return true
  for child in node:
    if containsSymbol(child, sym):
      return true
  false

proc addParserCacheLocals(stmts: var NimNode, rewrittenBody: NimNode,
                          ctx: RewriteCtx) {.compileTime.} =
  ## Rewritten helpers access parser caches directly by identifier name.
  let needsFormCache =
    containsSymbol(rewrittenBody, ctx.formParsedId) or
    containsSymbol(rewrittenBody, ctx.formBodyId)
  if needsFormCache:
    stmts.add newVarStmt(ctx.formParsedId, newLit(false))
    stmts.add newVarStmt(ctx.formBodyId, parseExpr("initTable[string, string]()"))

  let needsJsonCache =
    containsSymbol(rewrittenBody, ctx.jsonParsedId) or
    containsSymbol(rewrittenBody, ctx.jsonBodyId)
  if needsJsonCache:
    stmts.add newVarStmt(ctx.jsonParsedId, newLit(false))
    stmts.add newVarStmt(ctx.jsonBodyId, newCall(mkIdent("newJNull")))

proc buildHandlerProc(handlerName: NimNode, rewrittenBody: NimNode,
                      ctx: RewriteCtx): NimNode {.compileTime.} =
  ## Build a CPS handler proc from rewritten body.
  let reqId = ctx.reqId
  let ppId = ctx.ppId
  let qpId = ctx.qpId

  var handlerBodyStmts = newStmtList()
  handlerBodyStmts.add newVarStmt(ctx.headersId, newCall(newNimNode(nnkBracketExpr).add(mkIdent("newSeq"), newNimNode(nnkPar).add(mkIdent("string"), mkIdent("string")))))
  addParserCacheLocals(handlerBodyStmts, rewrittenBody, ctx)
  if rewrittenBody.kind == nnkStmtList:
    for child in rewrittenBody:
      handlerBodyStmts.add child
  else:
    handlerBodyStmts.add rewrittenBody
  handlerBodyStmts.add newNimNode(nnkReturnStmt).add(
    newCall(mkIdent("newResponse"), newIntLitNode(200), newStrLitNode(""), ctx.headersId)
  )

  result = newProc(
    name = handlerName,
    params = [
      newNimNode(nnkBracketExpr).add(mkIdent("CpsFuture"), mkIdent("HttpResponseBuilder")),
      newIdentDefs(reqId, mkIdent("HttpRequest")),
      newIdentDefs(ppId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string"))),
      newIdentDefs(qpId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string")))
    ],
    body = handlerBodyStmts,
    pragmas = newNimNode(nnkPragma).add(mkIdent("cps"))
  )

# ============================================================
# Helper: parse named arguments from route definition
# ============================================================

proc extractRouteNameArg(stmt: NimNode): string {.compileTime.} =
  ## Check if a route definition has a name = "..." argument.
  ## e.g., get "/users/{id}", name = "user_detail":
  for i in 1 ..< stmt.len:
    if stmt[i].kind == nnkExprEqExpr:
      if stmt[i][0].kind == nnkIdent and $stmt[i][0] == "name":
        return $stmt[i][1].strVal
  return ""

# ============================================================
# The router macro
# ============================================================

macro router*(body: untyped): untyped =
  ## Define routes using a DSL. Returns an HttpHandler.
  let routesSym = genSym(nskVar, "routes")
  let globalMwSym = genSym(nskVar, "globalMiddlewares")
  let beforeMwSym = genSym(nskVar, "beforeMiddlewares")
  let afterMwSym = genSym(nskVar, "afterMiddlewares")
  let trailingSlashSym = genSym(nskVar, "trailingSlash")

  var stmts = newStmtList()

  # Declare route list, middleware lists, and config
  let methodOverrideSym = genSym(nskVar, "methodOverrideEnabled")

  stmts.add quote do:
    var `routesSym`: seq[RouteEntry]
    var `globalMwSym`: seq[Middleware]
    var `beforeMwSym`: seq[Middleware]
    var `afterMwSym`: seq[Middleware]
    var `trailingSlashSym`: TrailingSlashBehavior = tsbIgnore
    var `methodOverrideSym`: bool = false

  var notFoundNode: NimNode = nil
  var errorHandlerNode: NimNode = nil
  var routeIdx = 0
  # OpenAPI spec generation state
  var apiSpecs: seq[RouteOpenApiSpec]
  var apiTitle = ""
  var apiVersion = "1.0.0"
  var apiDescription = ""
  var generateOpenApi = false
  var openApiPublic = false
  var appStateExpr: NimNode = nil
  var templateRendererExpr: NimNode = nil

  proc processStatements(stmtList: NimNode, prefix: string,
                          groupMwSym: NimNode, isRootScope: bool) =
    for stmt in stmtList:
      if stmt.kind == nnkDiscardStmt:
        continue

      if stmt.kind in {nnkCall, nnkCommand}:
        let cmdName = if stmt[0].kind == nnkIdent: ($stmt[0]).toLowerAscii else: ""

        case cmdName
        of "get", "post", "put", "delete", "patch", "head", "options", "any":
          let httpMethod = if cmdName == "any": "*" else: cmdName.toUpperAscii
          var pattern: string
          var handlerBody: NimNode
          var routeName: string = ""

          # Check for named route: get "/path", name = "foo":
          if stmt.len >= 3:
            # Find the stmt list (handler body) — it's the last arg
            var bodyIdx = -1
            for i in countdown(stmt.len - 1, 1):
              if stmt[i].kind == nnkStmtList:
                bodyIdx = i
                break
            if bodyIdx < 0:
              error("Route requires a body", stmt)
              continue

            # Pattern must be a string literal.
            if stmt[1].kind != nnkStrLit:
              error("Route path must be a string literal, e.g. get \"/users\":", stmt[1])
              continue
            pattern = prefix & $stmt[1].strVal

            handlerBody = stmt[bodyIdx]

            # Check for name= argument
            for i in 1 ..< stmt.len:
              if stmt[i].kind == nnkExprEqExpr and stmt[i][0].kind == nnkIdent and $stmt[i][0] == "name":
                routeName = $stmt[i][1].strVal

          elif stmt.len == 2 and stmt[1].kind == nnkStmtList:
            pattern = prefix & "/"
            handlerBody = stmt[1]
          else:
            error("Invalid route syntax", stmt)
            continue

          # Extract OpenAPI annotations before rewriting
          if generateOpenApi:
            apiSpecs.add RouteOpenApiSpec(
              path: pattern,
              httpMethod: httpMethod,
              summary: extractAnnotation(handlerBody, "summary"),
              tag: extractAnnotation(handlerBody, "tag"),
              description: extractAnnotation(handlerBody, "description"),
              deprecated: hasAnnotation(handlerBody, "deprecated"),
              pathParams: extractPathParamsFromPattern(pattern)
            )

          let reqId = mkIdent("req")
          let ppId = mkIdent("pathParams")
          let qpId = mkIdent("queryParams")
          let rwCtx = newRewriteCtx(reqId, ppId, qpId)
          let rewrittenBody = rewriteWithContext(handlerBody, rwCtx)
          let handlerName = genSym(nskProc, "routeHandler_" & $routeIdx)
          inc routeIdx

          let patternLit = newStrLitNode(pattern)
          let methodLit = newStrLitNode(httpMethod)
          let nameLit = newStrLitNode(routeName)

          stmts.add buildHandlerProc(handlerName, rewrittenBody, rwCtx)

          stmts.add quote do:
            `routesSym`.add RouteEntry(
              meth: `methodLit`,
              segments: parsePath(`patternLit`),
              handler: `handlerName`,
              middlewares: `globalMwSym` & `groupMwSym`,
              name: `nameLit`
            )

        of "sse":
          # SSE route: registers as GET, generates handler with SseWriter
          var pattern: string
          var handlerBody: NimNode

          if stmt.len == 3:
            if stmt[1].kind != nnkStrLit:
              error("sse path must be a string literal", stmt[1])
              continue
            pattern = prefix & $stmt[1].strVal
            handlerBody = stmt[2]
          elif stmt.len == 2 and stmt[1].kind == nnkStmtList:
            pattern = prefix & "/"
            handlerBody = stmt[1]
          else:
            error("Invalid sse route syntax", stmt)
            continue

          let reqId = mkIdent("req")
          let ppId = mkIdent("pathParams")
          let qpId = mkIdent("queryParams")
          let rwCtx = newRewriteCtx(reqId, ppId, qpId)
          let rewrittenBody = rewriteWithContext(handlerBody, rwCtx)
          let handlerName = genSym(nskProc, "sseHandler_" & $routeIdx)
          inc routeIdx

          let patternLit = newStrLitNode(pattern)

          var handlerBodyStmts = newStmtList()
          handlerBodyStmts.add newVarStmt(rwCtx.headersId, newCall(newNimNode(nnkBracketExpr).add(mkIdent("newSeq"), newNimNode(nnkPar).add(mkIdent("string"), mkIdent("string")))))
          addParserCacheLocals(handlerBodyStmts, rewrittenBody, rwCtx)
          handlerBodyStmts.add newNimNode(nnkLetSection).add(
            newNimNode(nnkIdentDefs).add(
              rwCtx.sseWriterId,
              newEmptyNode(),
              newCall(mkIdent("await"), newCall(mkIdent("initSse"), newDotExpr(reqId, mkIdent("stream")), rwCtx.headersId, reqId))
            )
          )
          if rewrittenBody.kind == nnkStmtList:
            for child in rewrittenBody:
              handlerBodyStmts.add child
          else:
            handlerBodyStmts.add rewrittenBody
          handlerBodyStmts.add newNimNode(nnkReturnStmt).add(
            newCall(mkIdent("sseResponse"))
          )

          let handlerProc = newProc(
            name = handlerName,
            params = [
              newNimNode(nnkBracketExpr).add(mkIdent("CpsFuture"), mkIdent("HttpResponseBuilder")),
              newIdentDefs(reqId, mkIdent("HttpRequest")),
              newIdentDefs(ppId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string"))),
              newIdentDefs(qpId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string")))
            ],
            body = handlerBodyStmts,
            pragmas = newNimNode(nnkPragma).add(mkIdent("cps"))
          )
          stmts.add handlerProc

          stmts.add quote do:
            `routesSym`.add RouteEntry(
              meth: "GET",
              segments: parsePath(`patternLit`),
              handler: `handlerName`,
              middlewares: `globalMwSym` & `groupMwSym`
            )

        of "ws":
          # WebSocket route: registers as GET, generates handler with WebSocket
          var pattern: string
          var handlerBody: NimNode

          if stmt.len == 3:
            if stmt[1].kind != nnkStrLit:
              error("ws path must be a string literal", stmt[1])
              continue
            pattern = prefix & $stmt[1].strVal
            handlerBody = stmt[2]
          elif stmt.len == 2 and stmt[1].kind == nnkStmtList:
            pattern = prefix & "/"
            handlerBody = stmt[1]
          else:
            error("Invalid ws route syntax", stmt)
            continue

          let reqId = mkIdent("req")
          let ppId = mkIdent("pathParams")
          let qpId = mkIdent("queryParams")
          let rwCtx = newRewriteCtx(reqId, ppId, qpId)
          let rewrittenBody = rewriteWithContext(handlerBody, rwCtx)
          let handlerName = genSym(nskProc, "wsHandler_" & $routeIdx)
          inc routeIdx

          let patternLit = newStrLitNode(pattern)

          var handlerBodyStmts = newStmtList()
          handlerBodyStmts.add newVarStmt(rwCtx.headersId, newCall(newNimNode(nnkBracketExpr).add(mkIdent("newSeq"), newNimNode(nnkPar).add(mkIdent("string"), mkIdent("string")))))
          addParserCacheLocals(handlerBodyStmts, rewrittenBody, rwCtx)
          handlerBodyStmts.add newNimNode(nnkLetSection).add(
            newNimNode(nnkIdentDefs).add(
              rwCtx.wsConnId,
              newEmptyNode(),
              newCall(mkIdent("await"), newCall(mkIdent("acceptWebSocket"), reqId, rwCtx.headersId))
            )
          )
          if rewrittenBody.kind == nnkStmtList:
            for child in rewrittenBody:
              handlerBodyStmts.add child
          else:
            handlerBodyStmts.add rewrittenBody
          handlerBodyStmts.add newNimNode(nnkReturnStmt).add(
            newCall(mkIdent("wsResponse"))
          )

          let handlerProc = newProc(
            name = handlerName,
            params = [
              newNimNode(nnkBracketExpr).add(mkIdent("CpsFuture"), mkIdent("HttpResponseBuilder")),
              newIdentDefs(reqId, mkIdent("HttpRequest")),
              newIdentDefs(ppId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string"))),
              newIdentDefs(qpId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string")))
            ],
            body = handlerBodyStmts,
            pragmas = newNimNode(nnkPragma).add(mkIdent("cps"))
          )
          stmts.add handlerProc

          stmts.add quote do:
            `routesSym`.add RouteEntry(
              meth: "GET",
              segments: parsePath(`patternLit`),
              handler: `handlerName`,
              middlewares: `globalMwSym` & `groupMwSym`
            )

        of "use":
          if stmt.len != 2:
            error("use expects exactly one middleware expression", stmt)
            continue
          let mwExpr = stmt[1]
          if isRootScope:
            stmts.add quote do:
              `globalMwSym`.add `mwExpr`
          else:
            stmts.add quote do:
              `groupMwSym`.add `mwExpr`

        of "compress":
          if stmt.len == 1:
            if isRootScope:
              stmts.add quote do:
                `globalMwSym`.add compressionMiddleware()
            else:
              stmts.add quote do:
                `groupMwSym`.add compressionMiddleware()
          elif stmt.len == 2:
            let minSize = stmt[1]
            if isRootScope:
              stmts.add quote do:
                `globalMwSym`.add compressionMiddleware(minBodySize = `minSize`)
            else:
              stmts.add quote do:
                `groupMwSym`.add compressionMiddleware(minBodySize = `minSize`)
          else:
            error("compress expects either no arguments or one min body size argument", stmt)

        of "group":
          if stmt.len != 3:
            error("group requires a prefix string and a body", stmt)
            continue
          if stmt[1].kind != nnkStrLit:
            error("group prefix must be a string literal", stmt[1])
            continue
          let groupPrefix = prefix & $stmt[1].strVal
          let groupBody = stmt[2]
          let newGroupMwSym = genSym(nskVar, "groupMw")
          stmts.add quote do:
            var `newGroupMwSym`: seq[Middleware] = `groupMwSym`
          processStatements(groupBody, groupPrefix, newGroupMwSym, false)

        of "servestatic":
          # serveStatic "/prefix", "dir"
          # or serveStatic "/prefix", "dir": fallback "index.html"
          if stmt.len < 3:
            error("serveStatic requires a URL prefix and filesystem directory", stmt)
            continue
          if stmt[1].kind != nnkStrLit:
            error("serveStatic URL prefix must be a string literal", stmt[1])
            continue
          let urlPrefix = prefix & $stmt[1].strVal
          let fsDirExpr = stmt[2]
          var fallbackFile = newStrLitNode("")

          # Check for block body with fallback option
          if stmt.len == 4 and stmt[3].kind == nnkStmtList:
            for child in stmt[3]:
              if child.kind in {nnkCall, nnkCommand}:
                let childName = if child[0].kind == nnkIdent: ($child[0]).toLowerAscii else: ""
                if childName == "fallback" and child.len == 2:
                  fallbackFile = child[1]

          let handlerName = genSym(nskProc, "staticHandler_" & $routeIdx)
          inc routeIdx
          let urlPrefixLit = newStrLitNode(urlPrefix)
          let patternLit = newStrLitNode(urlPrefix & "/*")

          stmts.add quote do:
            proc `handlerName`(req: HttpRequest, pathParams: Table[string, string],
                                queryParams: Table[string, string]): CpsFuture[HttpResponseBuilder] {.closure.} =
              serveStaticFile(`fsDirExpr`, `urlPrefixLit`, pathWithoutQuery(req.path), req, fallbackFile = `fallbackFile`)

          stmts.add quote do:
            `routesSym`.add RouteEntry(
              meth: "GET",
              segments: parsePath(`patternLit`),
              handler: `handlerName`,
              middlewares: `globalMwSym` & `groupMwSym`
            )

        of "notfound":
          if not isRootScope:
            error("notFound must be declared at router root scope (outside groups)", stmt)
            continue
          if stmt.len != 2 or stmt[1].kind != nnkStmtList:
            error("notFound expects a block body", stmt)
            continue
          let reqId = mkIdent("req")
          let ppId = mkIdent("pathParams")
          let qpId = mkIdent("queryParams")
          let rwCtx = newRewriteCtx(reqId, ppId, qpId)
          let rewrittenBody = rewriteWithContext(stmt[1], rwCtx)
          let handlerName = genSym(nskProc, "notFoundHandler")
          stmts.add buildHandlerProc(handlerName, rewrittenBody, rwCtx)
          notFoundNode = handlerName

        of "onerror":
          if not isRootScope:
            error("onError must be declared at router root scope (outside groups)", stmt)
            continue
          if stmt.len != 2 or stmt[1].kind != nnkStmtList:
            error("onError expects a block body", stmt)
            continue
          # Generate error handler CPS proc with access to `error` variable
          let reqId = mkIdent("req")
          let ppId = mkIdent("pathParams")
          let qpId = mkIdent("queryParams")
          let rwCtx = newRewriteCtx(reqId, ppId, qpId)
          let rewrittenBody = rewriteWithContext(stmt[1], rwCtx)
          let handlerName = genSym(nskProc, "errorHandler")
          let errorId = rwCtx.errorId

          var handlerBodyStmts = newStmtList()
          handlerBodyStmts.add newVarStmt(rwCtx.headersId, newCall(newNimNode(nnkBracketExpr).add(mkIdent("newSeq"), newNimNode(nnkPar).add(mkIdent("string"), mkIdent("string")))))
          addParserCacheLocals(handlerBodyStmts, rewrittenBody, rwCtx)
          if rewrittenBody.kind == nnkStmtList:
            for child in rewrittenBody:
              handlerBodyStmts.add child
          else:
            handlerBodyStmts.add rewrittenBody
          handlerBodyStmts.add newNimNode(nnkReturnStmt).add(
            newCall(mkIdent("newResponse"), newIntLitNode(500), newStrLitNode("Internal Server Error"), rwCtx.headersId)
          )

          let handlerProc = newProc(
            name = handlerName,
            params = [
              newNimNode(nnkBracketExpr).add(mkIdent("CpsFuture"), mkIdent("HttpResponseBuilder")),
              newIdentDefs(reqId, mkIdent("HttpRequest")),
              newIdentDefs(errorId, newNimNode(nnkRefTy).add(mkIdent("CatchableError"))),
              newIdentDefs(ppId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string"))),
              newIdentDefs(qpId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string")))
            ],
            body = handlerBodyStmts,
            pragmas = newNimNode(nnkPragma).add(mkIdent("cps"))
          )
          stmts.add handlerProc
          errorHandlerNode = handlerName

        of "before":
          # before: body → generates a before-middleware
          # The body is a CPS proc. If it calls `respond`, it short-circuits.
          # If it falls through, a control response signals "continue".
          let reqId = mkIdent("req")
          let ppId = mkIdent("pathParams")
          let qpId = mkIdent("queryParams")
          let rwCtx = newRewriteCtx(reqId, ppId, qpId)
          let rewrittenBody = rewriteWithContext(stmt[1], rwCtx)
          let beforeProcName = genSym(nskProc, "beforeCheck_" & $routeIdx)
          inc routeIdx

          var bodyStmts = newStmtList()
          bodyStmts.add newVarStmt(rwCtx.headersId, newCall(newNimNode(nnkBracketExpr).add(mkIdent("newSeq"), newNimNode(nnkPar).add(mkIdent("string"), mkIdent("string")))))
          addParserCacheLocals(bodyStmts, rewrittenBody, rwCtx)
          if rewrittenBody.kind == nnkStmtList:
            for child in rewrittenBody:
              bodyStmts.add child
          else:
            bodyStmts.add rewrittenBody
          # Sentinel return means "continue"
          bodyStmts.add newNimNode(nnkReturnStmt).add(
            newCall(mkIdent("continueResponse"))
          )

          let beforeProc = newProc(
            name = beforeProcName,
            params = [
              newNimNode(nnkBracketExpr).add(mkIdent("CpsFuture"), mkIdent("HttpResponseBuilder")),
              newIdentDefs(reqId, mkIdent("HttpRequest")),
              newIdentDefs(ppId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string"))),
              newIdentDefs(qpId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string")))
            ],
            body = bodyStmts,
            pragmas = newNimNode(nnkPragma).add(mkIdent("cps"))
          )
          stmts.add beforeProc

          # Generate middleware wrapper
          let mwName = genSym(nskLet, "beforeMw")
          stmts.add quote do:
            let `mwName`: Middleware = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
              let emptyPp = initTable[string, string]()
              let emptyQp = parseQueryString(req.path)
              let checkFut = `beforeProcName`(req, emptyPp, emptyQp)
              let resultFut = newCpsFuture[HttpResponseBuilder]()
              checkFut.addCallback(proc() =
                if checkFut.hasError():
                  resultFut.fail(checkFut.getError())
                else:
                  let resp = checkFut.read()
                  if resp.control == rcContinue or resp.statusCode == 0:
                    # Continue to next handler
                    let nextFut = next(req)
                    nextFut.addCallback(proc() =
                      if nextFut.hasError():
                        resultFut.fail(nextFut.getError())
                      else:
                        resultFut.complete(nextFut.read())
                    )
                  else:
                    # Short-circuit with this response
                    resultFut.complete(resp)
              )
              return resultFut
            `beforeMwSym`.add `mwName`

        of "after":
          # after: body → generates an after-middleware
          # The body has access to statusCode, responseBody, responseHeaders via the response.
          let reqId = mkIdent("req")
          let rwCtx = newRewriteCtx(reqId, mkIdent("pathParams"), mkIdent("queryParams"))
          let rewrittenBody = rewriteWithContext(stmt[1], rwCtx)
          let afterProcName = genSym(nskProc, "afterProc_" & $routeIdx)
          inc routeIdx
          let respId = mkIdent("resp")

          # The after proc takes req and resp, can modify resp, returns resp
          var bodyStmts = newStmtList()
          bodyStmts.add newVarStmt(rwCtx.headersId, newCall(newNimNode(nnkBracketExpr).add(mkIdent("newSeq"), newNimNode(nnkPar).add(mkIdent("string"), mkIdent("string")))))
          addParserCacheLocals(bodyStmts, rewrittenBody, rwCtx)
          # Make statusCode, responseBody, responseHeaders available
          bodyStmts.add newNimNode(nnkLetSection).add(
            newIdentDefs(mkIdent("statusCode"), newEmptyNode(), newDotExpr(respId, mkIdent("statusCode"))))
          bodyStmts.add newNimNode(nnkLetSection).add(
            newIdentDefs(mkIdent("responseBody"), newEmptyNode(), newDotExpr(respId, mkIdent("body"))))
          bodyStmts.add newNimNode(nnkLetSection).add(
            newIdentDefs(mkIdent("responseHeaders"), newEmptyNode(), newDotExpr(respId, mkIdent("headers"))))
          if rewrittenBody.kind == nnkStmtList:
            for child in rewrittenBody:
              bodyStmts.add child
          else:
            bodyStmts.add rewrittenBody
          bodyStmts.add newNimNode(nnkReturnStmt).add(respId)

          let afterProc = newProc(
            name = afterProcName,
            params = [
              newNimNode(nnkBracketExpr).add(mkIdent("CpsFuture"), mkIdent("HttpResponseBuilder")),
              newIdentDefs(reqId, mkIdent("HttpRequest")),
              newIdentDefs(respId, mkIdent("HttpResponseBuilder"))
            ],
            body = bodyStmts,
            pragmas = newNimNode(nnkPragma).add(mkIdent("cps"))
          )
          stmts.add afterProc

          # Generate middleware wrapper
          let mwName = genSym(nskLet, "afterMw")
          stmts.add quote do:
            let `mwName`: Middleware = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
              let fut = next(req)
              let resultFut = newCpsFuture[HttpResponseBuilder]()
              fut.addCallback(proc() =
                if fut.hasError():
                  resultFut.fail(fut.getError())
                else:
                  let resp = fut.read()
                  let afterFut = `afterProcName`(req, resp)
                  afterFut.addCallback(proc() =
                    if afterFut.hasError():
                      resultFut.fail(afterFut.getError())
                    else:
                      resultFut.complete(afterFut.read())
                  )
              )
              return resultFut
            `afterMwSym`.add `mwName`

        of "cors":
          # cors block: parse settings and generate corsMiddleware call
          if stmt.len == 2 and stmt[1].kind == nnkStmtList:
            var originsNode: NimNode = nil
            var methodsNode: NimNode = nil
            var headersNode: NimNode = nil
            var exposeNode: NimNode = nil
            var credentialsNode: NimNode = nil
            var maxAgeNode: NimNode = nil

            for child in stmt[1]:
              if child.kind notin {nnkCall, nnkCommand}:
                error("Invalid cors option syntax", child)
                continue
              let childName = if child[0].kind == nnkIdent: ($child[0]).toLowerAscii else: ""
              case childName
              of "origins":
                if child.len < 2:
                  error("cors origins expects at least one origin", child)
                  continue
                var items = newNimNode(nnkPrefix).add(ident("@"), newNimNode(nnkBracket))
                for i in 1 ..< child.len:
                  items[1].add child[i]
                originsNode = items
              of "methods":
                if child.len < 2:
                  error("cors methods expects at least one method", child)
                  continue
                var items = newNimNode(nnkPrefix).add(ident("@"), newNimNode(nnkBracket))
                for i in 1 ..< child.len:
                  items[1].add child[i]
                methodsNode = items
              of "headers":
                if child.len < 2:
                  error("cors headers expects at least one header", child)
                  continue
                var items = newNimNode(nnkPrefix).add(ident("@"), newNimNode(nnkBracket))
                for i in 1 ..< child.len:
                  items[1].add child[i]
                headersNode = items
              of "expose":
                if child.len < 2:
                  error("cors expose expects at least one header", child)
                  continue
                var items = newNimNode(nnkPrefix).add(ident("@"), newNimNode(nnkBracket))
                for i in 1 ..< child.len:
                  items[1].add child[i]
                exposeNode = items
              of "credentials":
                if child.len != 2:
                  error("cors credentials expects exactly one boolean argument", child)
                  continue
                credentialsNode = child[1]
              of "maxage":
                if child.len != 2:
                  error("cors maxAge expects exactly one integer argument", child)
                  continue
                maxAgeNode = child[1]
              else:
                error("Unknown cors option: " & childName, child)

            # Build the corsMiddleware call
            var corsCall = newCall(mkIdent("corsMiddleware"))
            if originsNode != nil:
              corsCall.add newNimNode(nnkExprEqExpr).add(mkIdent("allowOrigins"), originsNode)
            else:
              corsCall.add newNimNode(nnkExprEqExpr).add(mkIdent("allowOrigins"), parseExpr("""@["*"]"""))
            if methodsNode != nil:
              corsCall.add newNimNode(nnkExprEqExpr).add(mkIdent("allowMethods"), methodsNode)
            if headersNode != nil:
              corsCall.add newNimNode(nnkExprEqExpr).add(mkIdent("allowHeaders"), headersNode)
            if exposeNode != nil:
              corsCall.add newNimNode(nnkExprEqExpr).add(mkIdent("exposeHeaders"), exposeNode)
            if credentialsNode != nil:
              corsCall.add newNimNode(nnkExprEqExpr).add(mkIdent("allowCredentials"), credentialsNode)
            if maxAgeNode != nil:
              corsCall.add newNimNode(nnkExprEqExpr).add(mkIdent("maxAge"), maxAgeNode)

            stmts.add quote do:
              `globalMwSym`.add `corsCall`
          else:
            # Simple cors with default: cors "*"
            if stmt.len == 2:
              let origin = stmt[1]
              stmts.add quote do:
                `globalMwSym`.add corsMiddleware(`origin`)
            elif stmt.len == 1:
              stmts.add quote do:
                `globalMwSym`.add corsMiddleware()
            else:
              error("cors expects: cors, cors <origin>, or cors: <options>", stmt)

        of "secure":
          # secure or secure block with overrides
          if stmt.len == 1:
            stmts.add quote do:
              `globalMwSym`.add securityHeadersMiddleware()
          elif stmt.len == 2 and stmt[1].kind == nnkStmtList:
            var hstsNode: NimNode = nil
            var noSniffNode: NimNode = nil
            var frameNode: NimNode = nil
            var xssNode: NimNode = nil
            var referrerNode: NimNode = nil

            for child in stmt[1]:
              if child.kind notin {nnkCall, nnkCommand}:
                error("Invalid secure option syntax", child)
                continue
              let childName = if child[0].kind == nnkIdent: ($child[0]).toLowerAscii else: ""
              case childName
              of "hsts":
                if child.len != 2:
                  error("secure hsts expects exactly one integer argument", child)
                  continue
                hstsNode = child[1]
              of "nosniff":
                if child.len != 2:
                  error("secure noSniff expects exactly one boolean argument", child)
                  continue
                noSniffNode = child[1]
              of "frameoptions":
                if child.len != 2:
                  error("secure frameOptions expects exactly one string argument", child)
                  continue
                frameNode = child[1]
              of "xssprotection":
                if child.len != 2:
                  error("secure xssProtection expects exactly one boolean argument", child)
                  continue
                xssNode = child[1]
              of "referrerpolicy":
                if child.len != 2:
                  error("secure referrerPolicy expects exactly one string argument", child)
                  continue
                referrerNode = child[1]
              else:
                error("Unknown secure option: " & childName, child)

            var secCall = newCall(mkIdent("securityHeadersMiddleware"))
            if hstsNode != nil:
              secCall.add newNimNode(nnkExprEqExpr).add(mkIdent("hsts"), hstsNode)
            if noSniffNode != nil:
              secCall.add newNimNode(nnkExprEqExpr).add(mkIdent("noSniff"), noSniffNode)
            if frameNode != nil:
              secCall.add newNimNode(nnkExprEqExpr).add(mkIdent("frameOptions"), frameNode)
            if xssNode != nil:
              secCall.add newNimNode(nnkExprEqExpr).add(mkIdent("xssProtection"), xssNode)
            if referrerNode != nil:
              secCall.add newNimNode(nnkExprEqExpr).add(mkIdent("referrerPolicy"), referrerNode)

            stmts.add quote do:
              `globalMwSym`.add `secCall`
          else:
            error("secure expects no arguments or a configuration block", stmt)

        of "requestid":
          if stmt.len == 1:
            stmts.add quote do:
              `globalMwSym`.add requestIdMiddleware()
          elif stmt.len == 2:
            let headerName = stmt[1]
            stmts.add quote do:
              `globalMwSym`.add requestIdMiddleware(`headerName`)
          else:
            error("requestId expects either no args or one header name", stmt)

        of "ratelimit":
          # rateLimit 100, 60 or rateLimit 100, 60, "X-API-Key"
          if stmt.len == 3 or stmt.len == 4:
            let maxReqs = stmt[1]
            let windowSecs = stmt[2]
            if stmt.len == 4:
              let headerKey = stmt[3]
              stmts.add quote do:
                `globalMwSym`.add rateLimitMiddleware(`maxReqs`, `windowSecs`, extractHeader(`headerKey`))
            else:
              stmts.add quote do:
                `globalMwSym`.add rateLimitMiddleware(`maxReqs`, `windowSecs`)
          else:
            error("rateLimit expects: rateLimit <maxRequests>, <windowSeconds>[, <headerName>]", stmt)

        of "maxbodysize":
          if stmt.len == 2:
            let maxBytes = stmt[1]
            stmts.add quote do:
              `globalMwSym`.add bodySizeLimitMiddleware(`maxBytes`)
          else:
            error("maxBodySize expects exactly one integer argument", stmt)

        of "timeout":
          if stmt.len == 2:
            let timeoutMs = stmt[1]
            stmts.add quote do:
              `globalMwSym`.add timeoutMiddleware(`timeoutMs`)
          else:
            error("timeout expects exactly one integer argument (milliseconds)", stmt)

        of "accesslog":
          if stmt.len == 1:
            stmts.add quote do:
              `globalMwSym`.add accessLogMiddleware()
          elif stmt.len == 2:
            let format = stmt[1]
            stmts.add quote do:
              `globalMwSym`.add accessLogMiddleware(`format`)
          else:
            error("accessLog expects zero args or one format string argument", stmt)

        of "methodoverride":
          if stmt.len == 1:
            stmts.add quote do:
              `methodOverrideSym` = true
          else:
            error("methodOverride takes no arguments", stmt)

        of "healthcheck":
          # healthCheck "/health" or healthCheck "/health", "OK"
          if stmt.len == 2 or stmt.len == 3:
            if stmt[1].kind != nnkStrLit:
              error("healthCheck path must be a string literal", stmt[1])
              continue
            let healthPath = prefix & $stmt[1].strVal
            let healthPathLit = newStrLitNode(healthPath)
            let healthBody = if stmt.len >= 3: stmt[2] else: newStrLitNode("OK")
            let handlerName = genSym(nskProc, "healthCheck_" & $routeIdx)
            inc routeIdx
            stmts.add quote do:
              proc `handlerName`(req: HttpRequest, pathParams: Table[string, string],
                                  queryParams: Table[string, string]): CpsFuture[HttpResponseBuilder] {.closure.} =
                let fut = newCpsFuture[HttpResponseBuilder]()
                fut.complete(newResponse(200, `healthBody`, @[("Content-Type", "text/plain")]))
                return fut
              `routesSym`.add RouteEntry(
                meth: "GET",
                segments: parsePath(`healthPathLit`),
                handler: `handlerName`,
                middlewares: `globalMwSym` & `groupMwSym`
              )
          else:
            error("healthCheck expects: healthCheck <path>[, <body>]", stmt)

        of "route":
          # Multi-method: route ["GET", "POST"], "/path":
          if stmt.len >= 3:
            var methodsNode: NimNode
            var patternNode: NimNode
            var bodyNode: NimNode
            if stmt[1].kind == nnkBracket:
              methodsNode = stmt[1]
              patternNode = stmt[2]
              bodyNode = if stmt.len >= 4: stmt[3] else: newStmtList()
            else:
              error("route requires a method list like [\"GET\", \"POST\"]", stmt)
              continue

            let reqId = mkIdent("req")
            let ppId = mkIdent("pathParams")
            let qpId = mkIdent("queryParams")
            let rwCtx = newRewriteCtx(reqId, ppId, qpId)
            let rewrittenBody = rewriteWithContext(bodyNode, rwCtx)
            let handlerName = genSym(nskProc, "routeHandler_" & $routeIdx)
            inc routeIdx
            if patternNode.kind != nnkStrLit:
              error("route path must be a string literal", patternNode)
              continue
            let patternStr = prefix & $patternNode.strVal
            let patternLit = newStrLitNode(patternStr)

            stmts.add buildHandlerProc(handlerName, rewrittenBody, rwCtx)

            for i in 0 ..< methodsNode.len:
              let methodNode = methodsNode[i]
              if methodNode.kind != nnkStrLit:
                error("route method list entries must be string literals", methodNode)
                continue
              var methodName = methodNode.strVal.toUpperAscii
              if methodName == "ANY":
                methodName = "*"
              if methodName notin ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "*"]:
                error("Unsupported HTTP method in route [...]: " & methodNode.strVal, methodNode)
                continue
              let methodLit = newStrLitNode(methodName)
              stmts.add quote do:
                `routesSym`.add RouteEntry(
                  meth: `methodLit`,
                  segments: parsePath(`patternLit`),
                  handler: `handlerName`,
                  middlewares: `globalMwSym` & `groupMwSym`
                )
          else:
            error("route expects at least a method list and path", stmt)

        of "trailingslash":
          if stmt.len == 2:
            let mode = if stmt[1].kind == nnkIdent: ($stmt[1]).toLowerAscii else: ""
            case mode
            of "redirect":
              stmts.add quote do:
                `trailingSlashSym` = tsbRedirect
            of "strip":
              stmts.add quote do:
                `trailingSlashSym` = tsbStrip
            of "ignore":
              stmts.add quote do:
                `trailingSlashSym` = tsbIgnore
            else:
              error("trailingSlash expects: redirect, strip, or ignore", stmt)

        of "mount":
          # mount "/prefix", someRouter
          # mount "/prefix", someHandler
          if stmt.len == 3:
            let mountPrefix =
              if stmt[1].kind == nnkStrLit:
                newStrLitNode(prefix & $stmt[1].strVal)
              elif prefix.len == 0:
                stmt[1]
              else:
                newCall(bindSym"&", newStrLitNode(prefix), stmt[1])
            let mountTarget = stmt[2]
            # Generate code that tries mountRouter first (if Router type), else mountHandler
            stmts.add quote do:
              when `mountTarget` is Router:
                var routerCopy = Router(
                  routes: `routesSym`,
                  globalMiddlewares: `globalMwSym`,
                  beforeMiddlewares: `beforeMwSym`,
                  afterMiddlewares: `afterMwSym`,
                  trailingSlash: `trailingSlashSym`,
                  methodOverrideEnabled: `methodOverrideSym`
                )
                mountRouter(routerCopy, `mountPrefix`, `mountTarget`, `globalMwSym` & `groupMwSym`)
                `routesSym` = routerCopy.routes
              elif `mountTarget` is HttpHandler:
                var routerCopy = Router(
                  routes: `routesSym`,
                  globalMiddlewares: `globalMwSym`,
                  beforeMiddlewares: `beforeMwSym`,
                  afterMiddlewares: `afterMwSym`,
                  trailingSlash: `trailingSlashSym`,
                  methodOverrideEnabled: `methodOverrideSym`
                )
                mountHandler(routerCopy, `mountPrefix`, `mountTarget`, `globalMwSym` & `groupMwSym`)
                `routesSym` = routerCopy.routes
              else:
                {.error: "mount target must be Router or HttpHandler".}
          else:
            error("mount expects: mount <prefix>, <Router|HttpHandler>", stmt)

        of "onstart":
          error("onStart is not supported in `router` (it returns HttpHandler). Register lifecycle hooks on HttpServer.", stmt)

        of "onshutdown":
          error("onShutdown is not supported in `router` (it returns HttpHandler). Register lifecycle hooks on HttpServer.", stmt)

        of "accept":
          # Content negotiation block inside a route handler
          # This is handled by rewriteHandlerBody - but at top level
          # it's used inside a handler, so just pass through
          stmts.add stmt

        of "stream":
          # Chunked streaming route: registers as GET by default.
          # generates handler with ChunkedWriter.
          var streamMethod = "GET"
          var pattern: string
          var handlerBody: NimNode

          if stmt.len == 4 and stmt[1].kind == nnkStrLit and stmt[2].kind == nnkStrLit:
            streamMethod = stmt[1].strVal.toUpperAscii
            pattern = prefix & $stmt[2].strVal
            handlerBody = stmt[3]
          elif stmt.len == 3:
            if stmt[1].kind != nnkStrLit:
              error("stream path must be a string literal", stmt[1])
              continue
            pattern = prefix & $stmt[1].strVal
            handlerBody = stmt[2]
          elif stmt.len == 2 and stmt[1].kind == nnkStmtList:
            pattern = prefix & "/"
            handlerBody = stmt[1]
          else:
            error("Invalid stream route syntax", stmt)
            continue

          let reqId = mkIdent("req")
          let ppId = mkIdent("pathParams")
          let qpId = mkIdent("queryParams")
          let rwCtx = newRewriteCtx(reqId, ppId, qpId)
          let rewrittenBody = rewriteWithContext(handlerBody, rwCtx)
          let handlerName = genSym(nskProc, "streamHandler_" & $routeIdx)
          inc routeIdx

          let methodLit = newStrLitNode(streamMethod)
          let patternLit = newStrLitNode(pattern)

          var handlerBodyStmts = newStmtList()
          handlerBodyStmts.add newVarStmt(rwCtx.headersId, newCall(newNimNode(nnkBracketExpr).add(mkIdent("newSeq"), newNimNode(nnkPar).add(mkIdent("string"), mkIdent("string")))))
          addParserCacheLocals(handlerBodyStmts, rewrittenBody, rwCtx)
          # Initialize chunked writer: let streamWriter = await initChunked(req.stream, 200, dslHeaders)
          handlerBodyStmts.add newNimNode(nnkLetSection).add(
            newNimNode(nnkIdentDefs).add(
              rwCtx.streamWriterId,
              newEmptyNode(),
              newCall(mkIdent("await"), newCall(mkIdent("initChunked"),
                newDotExpr(reqId, mkIdent("stream")),
                newIntLitNode(200),
                rwCtx.headersId))
            )
          )
          if rewrittenBody.kind == nnkStmtList:
            for child in rewrittenBody:
              handlerBodyStmts.add child
          else:
            handlerBodyStmts.add rewrittenBody
          # Auto-end the chunked response
          handlerBodyStmts.add newCall(mkIdent("await"),
            newCall(newDotExpr(rwCtx.streamWriterId, mkIdent("endChunked"))))
          handlerBodyStmts.add newNimNode(nnkReturnStmt).add(
            newCall(mkIdent("streamResponse"))
          )

          let handlerProc = newProc(
            name = handlerName,
            params = [
              newNimNode(nnkBracketExpr).add(mkIdent("CpsFuture"), mkIdent("HttpResponseBuilder")),
              newIdentDefs(reqId, mkIdent("HttpRequest")),
              newIdentDefs(ppId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string"))),
              newIdentDefs(qpId, newNimNode(nnkBracketExpr).add(mkIdent("Table"), mkIdent("string"), mkIdent("string")))
            ],
            body = handlerBodyStmts,
            pragmas = newNimNode(nnkPragma).add(mkIdent("cps"))
          )
          stmts.add handlerProc

          stmts.add quote do:
            `routesSym`.add RouteEntry(
              meth: `methodLit`,
              segments: parsePath(`patternLit`),
              handler: `handlerName`,
              middlewares: `globalMwSym` & `groupMwSym`
            )

        of "renderer":
          # Set the template renderer: renderer myRendererProc
          if stmt.len == 2:
            templateRendererExpr = stmt[1]
          else:
            error("renderer expects exactly one renderer proc expression", stmt)

        of "openapi":
          if not isRootScope:
            error("openapi must be declared at router root scope (outside groups)", stmt)
            continue
          # Enable OpenAPI spec generation with metadata
          generateOpenApi = true
          if stmt.len == 2 and stmt[1].kind == nnkStmtList:
            for child in stmt[1]:
              if child.kind in {nnkCall, nnkCommand} and child[0].kind == nnkIdent:
                let childName = ($child[0]).toLowerAscii
                case childName
                of "title":
                  if child.len >= 2 and child[1].kind == nnkStrLit:
                    apiTitle = child[1].strVal
                  else:
                    error("openapi title expects a string literal", child)
                of "version":
                  if child.len >= 2 and child[1].kind == nnkStrLit:
                    apiVersion = child[1].strVal
                  else:
                    error("openapi version expects a string literal", child)
                of "description":
                  if child.len >= 2 and child[1].kind == nnkStrLit:
                    apiDescription = child[1].strVal
                  else:
                    error("openapi description expects a string literal", child)
                of "public":
                  if child.len >= 2:
                    let boolNode = child[1]
                    if boolNode.kind == nnkIdent and ($boolNode).toLowerAscii in ["true", "false"]:
                      openApiPublic = ($boolNode).toLowerAscii == "true"
                    else:
                      error("openapi public expects true or false", child)
                  else:
                    error("openapi public expects true or false", child)
                else:
                  error("Unknown openapi option: " & childName, child)
              else:
                error("Invalid openapi option syntax", child)
          elif stmt.len != 1:
            error("openapi expects no arguments or a configuration block", stmt)

        of "appstate":
          # appState myStateRef
          if stmt.len == 2:
            appStateExpr = stmt[1]
          else:
            error("appState expects exactly one state reference", stmt)

        else:
          stmts.add stmt

      elif stmt.kind == nnkIdent:
        # Handle bare keywords like `secure`, `requestId`
        let bareName = ($stmt).toLowerAscii
        case bareName
        of "secure":
          stmts.add quote do:
            `globalMwSym`.add securityHeadersMiddleware()
        of "requestid":
          stmts.add quote do:
            `globalMwSym`.add requestIdMiddleware()
        else:
          stmts.add stmt

      elif stmt.kind in {nnkAsgn, nnkLetSection, nnkVarSection}:
        stmts.add stmt
      else:
        stmts.add stmt

  let rootGroupMwSym = genSym(nskVar, "rootGroupMiddlewares")
  stmts.add quote do:
    var `rootGroupMwSym`: seq[Middleware]
  processStatements(body, "", rootGroupMwSym, true)

  # Generate OpenAPI spec and register /openapi.json endpoint
  if generateOpenApi:
    let specJson = generateOpenApiJson(apiSpecs, apiTitle, apiVersion, apiDescription)
    let specLit = newStrLitNode(specJson)
    let specHandlerName = genSym(nskProc, "openapiHandler")
    if openApiPublic:
      stmts.add quote do:
        proc `specHandlerName`(req: HttpRequest, pathParams: Table[string, string],
                                queryParams: Table[string, string]): CpsFuture[HttpResponseBuilder] {.closure.} =
          let fut = newCpsFuture[HttpResponseBuilder]()
          fut.complete(newResponse(200, `specLit`, @[("Content-Type", "application/json")]))
          return fut
        `routesSym`.add RouteEntry(
          meth: "GET",
          segments: parsePath("/openapi.json"),
          handler: `specHandlerName`,
          middlewares: @[],
          compiledMiddlewares: @[],
          hasCompiledMiddlewares: true
        )
    else:
      stmts.add quote do:
        proc `specHandlerName`(req: HttpRequest, pathParams: Table[string, string],
                                queryParams: Table[string, string]): CpsFuture[HttpResponseBuilder] {.closure.} =
          let fut = newCpsFuture[HttpResponseBuilder]()
          fut.complete(newResponse(200, `specLit`, @[("Content-Type", "application/json")]))
          return fut
        `routesSym`.add RouteEntry(
          meth: "GET",
          segments: parsePath("/openapi.json"),
          handler: `specHandlerName`,
          middlewares: `globalMwSym`
        )

  # Precompute per-route middleware composition once at router build time.
  stmts.add quote do:
    for i in 0 ..< `routesSym`.len:
      if not `routesSym`[i].hasCompiledMiddlewares:
        `routesSym`[i].compiledMiddlewares =
          `beforeMwSym` & `routesSym`[i].middlewares & `afterMwSym`
        `routesSym`[i].hasCompiledMiddlewares = true

  let routerSym = genSym(nskLet, "router")
  let appStateNode = if appStateExpr != nil: appStateExpr else: newNilLit()
  let templateRendererNode = if templateRendererExpr != nil: templateRendererExpr else: newNilLit()

  # Build Router construction
  var routerConstruction = quote do:
    let `routerSym` = Router(
      routes: `routesSym`,
      globalMiddlewares: `globalMwSym`,
      beforeMiddlewares: `beforeMwSym`,
      afterMiddlewares: `afterMwSym`,
      trailingSlash: `trailingSlashSym`,
      methodOverrideEnabled: `methodOverrideSym`,
      appState: `appStateNode`,
      templateRenderer: `templateRendererNode`
    )

  # Wire notFoundHandler if present
  if notFoundNode != nil:
    let nfSym = notFoundNode
    routerConstruction = quote do:
      let `routerSym` = Router(
        routes: `routesSym`,
        globalMiddlewares: `globalMwSym`,
        beforeMiddlewares: `beforeMwSym`,
        afterMiddlewares: `afterMwSym`,
        trailingSlash: `trailingSlashSym`,
        methodOverrideEnabled: `methodOverrideSym`,
        appState: `appStateNode`,
        templateRenderer: `templateRendererNode`,
        notFoundHandler: proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          let emptyPp = initTable[string, string]()
          let emptyQp = initTable[string, string]()
          `nfSym`(req, emptyPp, emptyQp)
      )

  # Wire errorHandler if present
  if errorHandlerNode != nil:
    let ehSym = errorHandlerNode
    if notFoundNode != nil:
      let nfSym = notFoundNode
      routerConstruction = quote do:
        let `routerSym` = Router(
          routes: `routesSym`,
          globalMiddlewares: `globalMwSym`,
          beforeMiddlewares: `beforeMwSym`,
          afterMiddlewares: `afterMwSym`,
          trailingSlash: `trailingSlashSym`,
          methodOverrideEnabled: `methodOverrideSym`,
          appState: `appStateNode`,
          templateRenderer: `templateRendererNode`,
          notFoundHandler: proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
            let emptyPp = initTable[string, string]()
            let emptyQp = initTable[string, string]()
            `nfSym`(req, emptyPp, emptyQp),
          errorHandler: proc(req: HttpRequest, err: ref CatchableError): CpsFuture[HttpResponseBuilder] {.closure.} =
            let emptyPp = initTable[string, string]()
            let emptyQp = initTable[string, string]()
            `ehSym`(req, err, emptyPp, emptyQp)
        )
    else:
      routerConstruction = quote do:
        let `routerSym` = Router(
          routes: `routesSym`,
          globalMiddlewares: `globalMwSym`,
          beforeMiddlewares: `beforeMwSym`,
          afterMiddlewares: `afterMwSym`,
          trailingSlash: `trailingSlashSym`,
          methodOverrideEnabled: `methodOverrideSym`,
          appState: `appStateNode`,
          templateRenderer: `templateRendererNode`,
          errorHandler: proc(req: HttpRequest, err: ref CatchableError): CpsFuture[HttpResponseBuilder] {.closure.} =
            let emptyPp = initTable[string, string]()
            let emptyQp = initTable[string, string]()
            `ehSym`(req, err, emptyPp, emptyQp)
        )

  stmts.add routerConstruction

  stmts.add quote do:
    toHandler(`routerSym`)

  result = newBlockStmt(stmts)

macro routerObj*(body: untyped): untyped =
  ## Define routes using the DSL and return a Router object.
  ## Useful when callers need route introspection, mounting, or manual composition.
  result = getAst(router(body))

  var stmtList: NimNode = nil
  if result.kind == nnkBlockStmt and result.len >= 2 and result[^1].kind == nnkStmtList:
    stmtList = result[^1]
  elif result.kind == nnkStmtList:
    stmtList = result

  if stmtList.isNil or stmtList.len == 0:
    error("internal error: unexpected routerObj expansion shape", body)

  let tail = stmtList[^1]
  if tail.kind == nnkCall and tail.len == 2 and
      tail[0].kind in {nnkIdent, nnkSym} and $tail[0] == "toHandler":
    stmtList[^1] = tail[1]
  else:
    error("internal error: routerObj could not rewrite router expansion tail", tail)
