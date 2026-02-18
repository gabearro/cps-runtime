## HTTP Router
##
## Route matching, middleware chaining, response helpers, cookie helpers,
## static file serving, content negotiation, and utility middleware for
## the CPS HTTP server.

import std/[tables, strutils, os, uri, json, algorithm, times, base64, atomics]
import ../../runtime
import ../../eventloop
import ../../io/files
import ./types
import ../shared/compression

type
  PathSegmentKind* = enum
    pskLiteral   ## Fixed path segment, e.g. "users"
    pskParam     ## Named parameter, e.g. "{id}" or "{id:int}"
    pskWildcard  ## Matches rest of path, e.g. "*"

  PathSegment* = object
    case kind*: PathSegmentKind
    of pskLiteral:
      value*: string
    of pskParam:
      paramName*: string
      paramType*: string  ## "string", "int", "float", "uuid", "" for untyped
      optional*: bool     ## true if {param?} — only valid as last segment
    of pskWildcard:
      discard

  RouteHandler* = proc(req: HttpRequest, pp: Table[string, string],
                        qp: Table[string, string]): CpsFuture[HttpResponseBuilder] {.closure.}

  Middleware* = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.}

  RouteEntry* = object
    meth*: string                  ## "GET", "POST", etc. or "*" for any
    segments*: seq[PathSegment]
    handler*: RouteHandler
    middlewares*: seq[Middleware]
    compiledMiddlewares*: seq[Middleware]  ## Precomputed chain inputs including before/after.
    hasCompiledMiddlewares*: bool
    name*: string                  ## Optional route name for URL generation

  TrailingSlashBehavior* = enum
    tsbIgnore    ## No normalization (default)
    tsbRedirect  ## 301 redirect to canonical form
    tsbStrip     ## Silently strip trailing slash

  Router* = object
    routes*: seq[RouteEntry]
    globalMiddlewares*: seq[Middleware]  ## Applied to fallback responses (404/auto OPTIONS/etc.).
    notFoundHandler*: HttpHandler
    errorHandler*: proc(req: HttpRequest, err: ref CatchableError): CpsFuture[HttpResponseBuilder] {.closure.}
    beforeMiddlewares*: seq[Middleware]
    afterMiddlewares*: seq[Middleware]
    trailingSlash*: TrailingSlashBehavior
    appState*: RootRef  ## Typed application state (cast at retrieval)
    templateRenderer*: TemplateRenderer  ## Router-scoped renderer used by DSL `render`.
    methodOverrideEnabled*: bool  ## Apply method override before routing

  AcceptEntry* = object
    mediaType*: string
    quality*: float

  RequestExtractionError* = object of CatchableError
    statusCode*: int

proc raiseRequestExtractionError*(statusCode: int, msg: string) {.noreturn.} =
  var err = newException(RequestExtractionError, msg)
  err.statusCode = statusCode
  raise err

# ============================================================
# Path parsing and matching
# ============================================================

proc parsePath*(pattern: string): seq[PathSegment] =
  ## Parse a route pattern like "/users/{id}/posts" or "/users/{id:int}" into segments.
  let cleaned = pattern.strip(chars = {'/'})
  if cleaned.len == 0:
    return @[]
  for part in cleaned.split('/'):
    if part.len == 0:
      continue
    if part == "*":
      result.add PathSegment(kind: pskWildcard)
    elif part.len > 2 and part[0] == '{' and part[^1] == '}':
      var inner = part[1..^2]
      var isOptional = false
      if inner.endsWith("?"):
        isOptional = true
        inner = inner[0..^2]
      let colonIdx = inner.find(':')
      if colonIdx >= 0:
        let pName = inner[0 ..< colonIdx]
        let pType = inner[colonIdx + 1 .. ^1].toLowerAscii
        result.add PathSegment(kind: pskParam, paramName: pName, paramType: pType, optional: isOptional)
      else:
        result.add PathSegment(kind: pskParam, paramName: inner, paramType: "", optional: isOptional)
    else:
      result.add PathSegment(kind: pskLiteral, value: part)

proc segmentsToPattern*(segments: seq[PathSegment]): string =
  ## Reconstruct a route pattern string from segments.
  if segments.len == 0:
    return "/"
  result = ""
  for seg in segments:
    result.add "/"
    case seg.kind
    of pskLiteral:
      result.add seg.value
    of pskParam:
      if seg.paramType.len > 0:
        result.add "{" & seg.paramName & ":" & seg.paramType & "}"
      else:
        result.add "{" & seg.paramName & "}"
    of pskWildcard:
      result.add "*"

proc isValidUuid(s: string): bool =
  ## Check if a string is a valid UUID (8-4-4-4-12 hex format).
  if s.len != 36: return false
  for i, c in s:
    if i in {8, 13, 18, 23}:
      if c != '-': return false
    else:
      if c notin HexDigits: return false
  return true

proc validateParamType(decodedPart: string, paramType: string): bool =
  ## Validate a path segment against its type constraint.
  case paramType
  of "int":
    try: discard parseInt(decodedPart); return true
    except ValueError: return false
  of "float":
    try: discard parseFloat(decodedPart); return true
    except ValueError: return false
  of "uuid":
    return isValidUuid(decodedPart)
  of "alpha":
    for c in decodedPart:
      if c notin Letters: return false
    return decodedPart.len > 0
  of "alnum":
    for c in decodedPart:
      if c notin Letters + Digits: return false
    return decodedPart.len > 0
  of "":
    return true  # No constraint
  else:
    return true  # Unknown constraint — accept

proc matchRoute*(segments: seq[PathSegment], path: string): (bool, Table[string, string]) =
  ## Match a request path against route segments. Returns (matched, params).
  ## Applies URL decoding to path segments and validates typed params.
  ## Supports optional trailing params ({param?}).
  var params = initTable[string, string]()
  let cleaned = path.strip(chars = {'/'})
  var parts: seq[string]
  if cleaned.len > 0:
    parts = cleaned.split('/')
  else:
    parts = @[]

  if segments.len == 0 and parts.len == 0:
    return (true, params)

  # Wildcard at end matches any remaining segments
  if segments.len > 0 and segments[^1].kind == pskWildcard:
    if parts.len < segments.len - 1:
      return (false, params)
    for i in 0 ..< segments.len - 1:
      let decodedPart = decodeUrl(parts[i])
      case segments[i].kind
      of pskLiteral:
        if i >= parts.len or decodedPart != segments[i].value:
          return (false, params)
      of pskParam:
        if i >= parts.len:
          return (false, params)
        if not validateParamType(decodedPart, segments[i].paramType):
          return (false, params)
        params[segments[i].paramName] = decodedPart
      of pskWildcard:
        discard
    return (true, params)

  # Check for optional trailing segment
  let hasOptional = segments.len > 0 and
    segments[^1].kind == pskParam and segments[^1].optional
  if hasOptional:
    if parts.len != segments.len and parts.len != segments.len - 1:
      return (false, params)
  else:
    if parts.len != segments.len:
      return (false, params)

  for i in 0 ..< segments.len:
    if i >= parts.len:
      # Only valid if this is the optional trailing segment
      if segments[i].kind == pskParam and segments[i].optional:
        # Don't add param to table — let getOrDefault provide the default
        break
      else:
        return (false, params)
    let decodedPart = decodeUrl(parts[i])
    case segments[i].kind
    of pskLiteral:
      if decodedPart != segments[i].value:
        return (false, params)
    of pskParam:
      if not validateParamType(decodedPart, segments[i].paramType):
        return (false, params)
      params[segments[i].paramName] = decodedPart
    of pskWildcard:
      return (true, params)

  return (true, params)

proc pathWithoutQuery*(path: string): string =
  ## Strip query string from path: "/foo?bar=1" -> "/foo"
  let idx = path.find('?')
  if idx >= 0:
    return path[0 ..< idx]
  return path

proc parseQueryString*(path: string): Table[string, string] =
  ## Parse query parameters from a path or query string with URL decoding.
  ## "/search?q=hello%20world&page=2" -> {"q": "hello world", "page": "2"}
  result = initTable[string, string]()
  let idx = path.find('?')
  if idx < 0:
    return
  let qs = path[idx + 1 .. ^1]
  if qs.len == 0:
    return
  for pair in qs.split('&'):
    if pair.len == 0:
      continue
    let eqIdx = pair.find('=')
    if eqIdx >= 0:
      let key = decodeUrl(pair[0 ..< eqIdx])
      let val = decodeUrl(pair[eqIdx + 1 .. ^1])
      result[key] = val
    else:
      result[decodeUrl(pair)] = ""

proc parseFormBody*(body: string): Table[string, string] =
  ## Parse URL-encoded form body (application/x-www-form-urlencoded).
  ## "name=John%20Doe&age=30" -> {"name": "John Doe", "age": "30"}
  result = initTable[string, string]()
  if body.len == 0:
    return
  for pair in body.split('&'):
    if pair.len == 0:
      continue
    let eqIdx = pair.find('=')
    if eqIdx >= 0:
      let key = decodeUrl(pair[0 ..< eqIdx])
      let val = decodeUrl(pair[eqIdx + 1 .. ^1])
      result[key] = val
    else:
      result[decodeUrl(pair)] = ""

# ============================================================
# JSON body parsing
# ============================================================

proc parseJsonBody*(body: string): JsonNode =
  ## Parse JSON from request body. Raises on invalid JSON.
  parseJson(body)

proc parseIntParam(value: string, source: string, key: string): int =
  if value.len == 0:
    raiseRequestExtractionError(400, "Missing " & source & " parameter: " & key)
  try:
    result = parseInt(value)
  except ValueError:
    raiseRequestExtractionError(400, "Invalid " & source & " parameter '" & key & "'")

proc parseFloatParam(value: string, source: string, key: string): float =
  if value.len == 0:
    raiseRequestExtractionError(400, "Missing " & source & " parameter: " & key)
  try:
    result = parseFloat(value)
  except ValueError:
    raiseRequestExtractionError(400, "Invalid " & source & " parameter '" & key & "'")

proc parseBoolParam(value: string, source: string, key: string): bool =
  if value.len == 0:
    raiseRequestExtractionError(400, "Missing " & source & " parameter: " & key)
  try:
    result = parseBool(value)
  except ValueError:
    raiseRequestExtractionError(400, "Invalid " & source & " parameter '" & key & "'")

proc pathParamValue*(pp: Table[string, string], key: string): string =
  ## Return a required path parameter, raising 400 when missing.
  if key notin pp:
    raiseRequestExtractionError(400, "Missing path parameter: " & key)
  result = pp[key]

proc pathParamInt*(pp: Table[string, string], key: string): int =
  ## Parse a required path parameter as int (400 on invalid/missing).
  parseIntParam(pathParamValue(pp, key), "path", key)

proc pathParamFloat*(pp: Table[string, string], key: string): float =
  ## Parse a required path parameter as float (400 on invalid/missing).
  parseFloatParam(pathParamValue(pp, key), "path", key)

proc pathParamBool*(pp: Table[string, string], key: string): bool =
  ## Parse a required path parameter as bool (400 on invalid/missing).
  parseBoolParam(pathParamValue(pp, key), "path", key)

proc queryParamRequired*(qp: Table[string, string], key: string): string =
  ## Return a required query parameter, raising 400 when missing.
  if key notin qp:
    raiseRequestExtractionError(400, "Missing query parameter: " & key)
  result = qp[key]

proc queryParamInt*(qp: Table[string, string], key: string): int =
  ## Parse a required query parameter as int (400 on invalid/missing).
  parseIntParam(queryParamRequired(qp, key), "query", key)

proc queryParamInt*(qp: Table[string, string], key: string, defaultVal: int): int =
  ## Parse a query parameter as int, falling back to `defaultVal` when missing.
  if key notin qp or qp[key].len == 0:
    return defaultVal
  parseIntParam(qp[key], "query", key)

proc queryParamInt*(qp: Table[string, string], key: string, defaultVal: string): int =
  ## Parse a query parameter as int, using a string default when missing.
  if key notin qp or qp[key].len == 0:
    return parseIntParam(defaultVal, "query", key)
  parseIntParam(qp[key], "query", key)

proc queryParamFloat*(qp: Table[string, string], key: string): float =
  ## Parse a required query parameter as float (400 on invalid/missing).
  parseFloatParam(queryParamRequired(qp, key), "query", key)

proc queryParamFloat*(qp: Table[string, string], key: string, defaultVal: float): float =
  ## Parse a query parameter as float, falling back to `defaultVal` when missing.
  if key notin qp or qp[key].len == 0:
    return defaultVal
  parseFloatParam(qp[key], "query", key)

proc queryParamFloat*(qp: Table[string, string], key: string, defaultVal: string): float =
  ## Parse a query parameter as float, using a string default when missing.
  if key notin qp or qp[key].len == 0:
    return parseFloatParam(defaultVal, "query", key)
  parseFloatParam(qp[key], "query", key)

proc queryParamBool*(qp: Table[string, string], key: string): bool =
  ## Parse a required query parameter as bool (400 on invalid/missing).
  parseBoolParam(queryParamRequired(qp, key), "query", key)

proc queryParamBool*(qp: Table[string, string], key: string, defaultVal: bool): bool =
  ## Parse a query parameter as bool, falling back to `defaultVal` when missing.
  if key notin qp or qp[key].len == 0:
    return defaultVal
  parseBoolParam(qp[key], "query", key)

proc queryParamBool*(qp: Table[string, string], key: string, defaultVal: string): bool =
  ## Parse a query parameter as bool, using a string default when missing.
  if key notin qp or qp[key].len == 0:
    return parseBoolParam(defaultVal, "query", key)
  parseBoolParam(qp[key], "query", key)

# ============================================================
# Request extraction helpers
# ============================================================

proc extractClientIp*(req: HttpRequest): string =
  ## Extract client IP from X-Forwarded-For, X-Real-IP headers, or "unknown".
  let forwarded = req.getHeader("x-forwarded-for")
  if forwarded.len > 0:
    return forwarded.split(',')[0].strip()
  let realIp = req.getHeader("x-real-ip")
  if realIp.len > 0:
    return realIp
  return "unknown"

proc extractBearerToken*(req: HttpRequest): string =
  ## Extract Bearer token from Authorization header. Returns "" if not present.
  let auth = req.getHeader("authorization")
  if auth.toLowerAscii.startsWith("bearer "):
    return auth[7 .. ^1].strip()
  return ""

proc parseBasicAuth*(req: HttpRequest): (string, string) =
  ## Parse Basic auth credentials from Authorization header.
  ## Returns (username, password). Returns ("", "") if not present or invalid.
  let auth = req.getHeader("authorization")
  if not auth.toLowerAscii.startsWith("basic "):
    return ("", "")
  let encoded = auth[6 .. ^1].strip()
  try:
    let decoded = base64.decode(encoded)
    let colonIdx = decoded.find(':')
    if colonIdx < 0:
      return ("", "")
    return (decoded[0 ..< colonIdx], decoded[colonIdx + 1 .. ^1])
  except ValueError:
    return ("", "")

proc escapeHtml*(s: string): string =
  ## Escape HTML special characters to prevent XSS.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#x27;"
    else: result.add c

proc checkEtag*(req: HttpRequest, etag: string): bool =
  ## Check If-None-Match header against an ETag. Returns true if client has fresh copy.
  let ifNoneMatch = req.getHeader("if-none-match")
  if ifNoneMatch.len > 0:
    # Handle comma-separated list of ETags
    for part in ifNoneMatch.split(','):
      if part.strip() == etag or part.strip() == "*":
        return true
  return false

# ============================================================
# Content negotiation
# ============================================================

proc parseAcceptHeader*(header: string): seq[AcceptEntry] =
  ## Parse an Accept header into entries sorted by quality (descending).
  if header.len == 0:
    return @[]
  for part in header.split(','):
    let trimmed = part.strip()
    if trimmed.len == 0:
      continue
    let semiIdx = trimmed.find(';')
    var mediaType: string
    var quality = 1.0
    if semiIdx >= 0:
      mediaType = trimmed[0 ..< semiIdx].strip().toLowerAscii
      let params = trimmed[semiIdx + 1 .. ^1].strip()
      for param in params.split(';'):
        let p = param.strip()
        if p.startsWith("q="):
          try:
            quality = parseFloat(p[2 .. ^1])
          except ValueError:
            quality = 1.0
    else:
      mediaType = trimmed.toLowerAscii
    if mediaType.len == 0:
      continue
    if quality < 0.0:
      quality = 0.0
    elif quality > 1.0:
      quality = 1.0
    result.add AcceptEntry(mediaType: mediaType, quality: quality)
  result.sort(proc(a, b: AcceptEntry): int = cmp(b.quality, a.quality))

proc negotiateContentType*(acceptHeader: string, available: seq[string]): string =
  ## Match the best content type from `available` based on an Accept header.
  ## Returns "" if no match (406 Not Acceptable).
  if available.len == 0:
    return ""
  let entries = parseAcceptHeader(acceptHeader)
  if entries.len == 0:
    return available[0]
  var availableLower: seq[string]
  for avail in available:
    availableLower.add avail.toLowerAscii
  for entry in entries:
    if entry.quality <= 0.0:
      continue
    for i in 0 ..< availableLower.len:
      let availLower = availableLower[i]
      if entry.mediaType == availLower or entry.mediaType == "*/*":
        return available[i]
      # Partial match: text/* matches text/html
      if entry.mediaType.endsWith("/*"):
        let prefix = entry.mediaType[0 ..< entry.mediaType.len - 2]
        if availLower.startsWith(prefix & "/"):
          return available[i]
  return ""

# ============================================================
# Middleware chaining
# ============================================================

proc chainMiddleware*(middlewares: seq[Middleware], finalHandler: HttpHandler): HttpHandler =
  ## Chain middlewares around a final handler, building from inside out.
  ## Uses closure factory to avoid capture-by-reference gotcha in loops.
  if middlewares.len == 0:
    return finalHandler

  var current = finalHandler

  # Build from last middleware to first
  proc makeWrapped(mw: Middleware, inner: HttpHandler): HttpHandler =
    result = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      mw(req, inner)

  for i in countdown(middlewares.len - 1, 0):
    current = makeWrapped(middlewares[i], current)

  return current

# ============================================================
# Response helpers
# ============================================================

proc jsonResponse*(code: int, body: string,
                    extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  var headers = @[("Content-Type", "application/json")]
  for h in extraHeaders:
    headers.add h
  newResponse(code, body, headers)

proc htmlResponse*(code: int, body: string,
                    extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  var headers = @[("Content-Type", "text/html; charset=utf-8")]
  for h in extraHeaders:
    headers.add h
  newResponse(code, body, headers)

proc textResponse*(code: int, body: string,
                    extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  var headers = @[("Content-Type", "text/plain; charset=utf-8")]
  for h in extraHeaders:
    headers.add h
  newResponse(code, body, headers)

proc redirectResponse*(location: string, code: int = 302): HttpResponseBuilder =
  newResponse(code, "", @[("Location", location)])

# ============================================================
# Template engine hook
# ============================================================

var activeTemplateRenderer*: TemplateRenderer = nil

proc setTemplateRenderer*(renderer: TemplateRenderer) =
  ## Set a process-global template renderer fallback.
  activeTemplateRenderer = renderer

proc setTemplateRenderer*(router: var Router, renderer: TemplateRenderer) =
  ## Set a router-scoped template renderer.
  router.templateRenderer = renderer

proc renderTemplate*(req: HttpRequest, name: string,
                     extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  ## Render a template by name with no variables, returning an HTML response.
  let renderer =
    if req.templateRenderer != nil: req.templateRenderer
    else: activeTemplateRenderer
  if renderer != nil:
    let body = renderer(name, newJObject())
    return htmlResponse(200, body, extraHeaders)
  return newResponse(500, "No template renderer configured")

proc renderTemplate*(req: HttpRequest, name: string, vars: JsonNode,
                     extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  ## Render a template by name with variables, returning an HTML response.
  let renderer =
    if req.templateRenderer != nil: req.templateRenderer
    else: activeTemplateRenderer
  if renderer != nil:
    let body = renderer(name, vars)
    return htmlResponse(200, body, extraHeaders)
  return newResponse(500, "No template renderer configured")

# ============================================================
# Cookie helpers
# ============================================================

proc getCookie*(req: HttpRequest, name: string): string =
  ## Parse a named cookie from the Cookie header.
  let cookieHeader = req.getHeader("cookie")
  if cookieHeader.len == 0:
    return ""
  for pair in cookieHeader.split(';'):
    let trimmed = pair.strip()
    let eqIdx = trimmed.find('=')
    if eqIdx >= 0:
      let key = trimmed[0 ..< eqIdx].strip()
      if key == name:
        return trimmed[eqIdx + 1 .. ^1].strip()
  return ""

proc setCookieHeader*(name: string, value: string,
                       maxAge: int = -1, path: string = "/",
                       httpOnly: bool = false, secure: bool = false,
                       sameSite: string = ""): (string, string) =
  ## Build a Set-Cookie header tuple.
  var cookie = name & "=" & value
  if path.len > 0:
    cookie &= "; Path=" & path
  if maxAge >= 0:
    cookie &= "; Max-Age=" & $maxAge
  if httpOnly:
    cookie &= "; HttpOnly"
  if secure:
    cookie &= "; Secure"
  if sameSite.len > 0:
    cookie &= "; SameSite=" & sameSite
  result = ("Set-Cookie", cookie)

# ============================================================
# Static file serving
# ============================================================

proc guessContentType*(path: string): string =
  ## Guess MIME type from file extension.
  let ext = path.splitFile().ext.toLowerAscii
  case ext
  of ".html", ".htm": "text/html; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".js", ".mjs": "application/javascript; charset=utf-8"
  of ".json": "application/json"
  of ".xml": "application/xml"
  of ".txt": "text/plain; charset=utf-8"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".ico": "image/x-icon"
  of ".woff": "font/woff"
  of ".woff2": "font/woff2"
  of ".ttf": "font/ttf"
  of ".pdf": "application/pdf"
  of ".zip": "application/zip"
  of ".wasm": "application/wasm"
  of ".mp4": "video/mp4"
  of ".webm": "video/webm"
  of ".mp3": "audio/mpeg"
  of ".ogg": "audio/ogg"
  of ".webp": "image/webp"
  of ".avif": "image/avif"
  else: "application/octet-stream"

proc hasFileExtension(path: string): bool =
  ## Check if a path has a file extension (e.g., .html, .js).
  let (_, _, ext) = path.splitFile()
  ext.len > 0

proc serveStaticFile*(fsDir: string, urlPrefix: string,
                       reqPath: string, req: HttpRequest = HttpRequest(),
                       maxAge: int = 3600,
                       fallbackFile: string = ""): CpsFuture[HttpResponseBuilder] =
  ## Serve a static file with ETag/Last-Modified/Cache-Control support.
  ## Returns 404 if not found. Blocks ".." traversal.
  ## If fallbackFile is set and the requested file doesn't exist and the
  ## request has no file extension, serves the fallback (SPA mode).
  let fut = newCpsFuture[HttpResponseBuilder]()

  # Strip URL prefix from request path
  var relPath = reqPath
  if relPath.startsWith(urlPrefix):
    relPath = relPath[urlPrefix.len .. ^1]
  relPath = relPath.strip(chars = {'/'})

  # Block path traversal
  if ".." in relPath:
    fut.complete(newResponse(403, "Forbidden"))
    return fut

  var filePath = fsDir / relPath

  if not fileExists(filePath):
    # SPA fallback: if no file extension, try serving fallback file
    if fallbackFile.len > 0 and not hasFileExtension(relPath):
      let fallbackPath = fsDir / fallbackFile
      if fileExists(fallbackPath):
        filePath = fallbackPath
      else:
        fut.complete(newResponse(404, "Not Found"))
        return fut
    else:
      fut.complete(newResponse(404, "Not Found"))
      return fut

  let contentType = guessContentType(filePath)

  # Generate ETag from file info
  var etag = ""
  var lastModified = ""
  try:
    let info = getFileInfo(filePath)
    let size = info.size
    let mtime = info.lastWriteTime.toUnix()
    etag = "W/\"" & toHex(size) & "-" & toHex(mtime) & "\""
    lastModified = $info.lastWriteTime.utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
  except OSError:
    discard

  # Check If-None-Match
  if etag.len > 0:
    let ifNoneMatch = req.getHeader("if-none-match")
    if ifNoneMatch.len > 0 and ifNoneMatch == etag:
      fut.complete(newResponse(304, "", @[
        ("ETag", etag),
        ("Cache-Control", "public, max-age=" & $maxAge)
      ]))
      return fut

  let capturedEtag = etag
  let capturedLastModified = lastModified
  let capturedMaxAge = maxAge
  let capturedContentType = contentType

  # Use asyncReadFile and chain result
  let readFut = asyncReadFile(filePath)
  readFut.addCallback(proc() =
    if readFut.hasError():
      fut.complete(newResponse(500, "Internal Server Error"))
    else:
      let data = readFut.read()
      var headers = @[("Content-Type", capturedContentType)]
      if capturedEtag.len > 0:
        headers.add ("ETag", capturedEtag)
      if capturedLastModified.len > 0:
        headers.add ("Last-Modified", capturedLastModified)
      headers.add ("Cache-Control", "public, max-age=" & $capturedMaxAge)
      fut.complete(newResponse(200, data, headers))
  )
  return fut

# ============================================================
# File response helpers
# ============================================================

proc fileResponse*(filePath: string, contentType: string = ""): CpsFuture[HttpResponseBuilder] =
  ## Read a file and return it as a response. Sets Content-Type from extension.
  let ct = if contentType.len > 0: contentType else: guessContentType(filePath)
  let readFut = asyncReadFile(filePath)
  let resultFut = newCpsFuture[HttpResponseBuilder]()
  let capturedCt = ct
  readFut.addCallback(proc() =
    if readFut.hasError():
      resultFut.complete(newResponse(404, "Not Found"))
    else:
      let data = readFut.read()
      resultFut.complete(newResponse(200, data, @[("Content-Type", capturedCt)]))
  )
  return resultFut

proc downloadResponse*(filePath: string, filename: string = ""): CpsFuture[HttpResponseBuilder] =
  ## Read a file and return it as a download (Content-Disposition: attachment).
  let fname = if filename.len > 0: filename else: extractFilename(filePath)
  let readFut = asyncReadFile(filePath)
  let resultFut = newCpsFuture[HttpResponseBuilder]()
  let capturedFname = fname
  readFut.addCallback(proc() =
    if readFut.hasError():
      resultFut.complete(newResponse(404, "Not Found"))
    else:
      let data = readFut.read()
      let ct = guessContentType(filePath)
      resultFut.complete(newResponse(200, data, @[
        ("Content-Type", ct),
        ("Content-Disposition", "attachment; filename=\"" & capturedFname & "\"")
      ]))
  )
  return resultFut

# ============================================================
# Route listing
# ============================================================

proc listRoutes*(router: Router): string =
  ## Return a human-readable listing of all routes.
  for route in router.routes:
    let meth = if route.meth == "*": "ANY" else: route.meth
    let pattern = segmentsToPattern(route.segments)
    let name = if route.name.len > 0: " [" & route.name & "]" else: ""
    result.add meth & "\t" & pattern & name & "\n"

proc setAppState*(router: var Router, state: RootRef) =
  ## Attach typed application state to this router.
  router.appState = state

# ============================================================
# Named route URL generation
# ============================================================

proc urlFor*(router: Router, name: string,
              params: Table[string, string] = initTable[string, string]()): string =
  ## Generate a URL for a named route by filling in path parameters.
  for route in router.routes:
    if route.name == name:
      result = ""
      for seg in route.segments:
        result.add "/"
        case seg.kind
        of pskLiteral:
          result.add seg.value
        of pskParam:
          if seg.paramName in params:
            result.add encodeUrl(params[seg.paramName], usePlus = false)
          else:
            result.add "{" & seg.paramName & "}"
        of pskWildcard:
          result.add "*"
      if result.len == 0:
        result = "/"
      return result
  return ""

# ============================================================
# Router dispatch
# ============================================================

proc dispatch*(router: Router, req: HttpRequest): CpsFuture[HttpResponseBuilder] =
  ## Find a matching route and invoke its handler with middleware chain.
  ## Supports error recovery, pass (next-route), HEAD/OPTIONS auto-generation,
  ## and trailing slash normalization.
  var req = req  # mutable copy for method override
  if req.context.isNil:
    req.context = newTable[string, string]()
  req.appState = router.appState
  req.templateRenderer = router.templateRenderer
  if router.methodOverrideEnabled:
    let overrideHeader = req.getHeader("x-http-method-override")
    if overrideHeader.len > 0:
      req.meth = overrideHeader.toUpperAscii
    elif req.meth == "POST":
      let ct = req.getHeader("content-type")
      if ct.toLowerAscii.startsWith("application/x-www-form-urlencoded"):
        let form = parseFormBody(req.body)
        let methodVal = form.getOrDefault("_method")
        if methodVal.len > 0:
          req.meth = methodVal.toUpperAscii
  let cleanPath = pathWithoutQuery(req.path)
  let qp = parseQueryString(req.path)

  let capturedErrorHandler = router.errorHandler
  let capturedBeforeMw = router.beforeMiddlewares
  let capturedGlobalMw = router.globalMiddlewares
  let capturedAfterMw = router.afterMiddlewares
  let fallbackMw = capturedBeforeMw & capturedGlobalMw & capturedAfterMw

  # Helper: run a handler through middleware + centralized error recovery.
  proc invokeWithRecovery(middlewares: seq[Middleware], finalHandler: HttpHandler,
                          r: HttpRequest): CpsFuture[HttpResponseBuilder] =
    let chained = chainMiddleware(middlewares, finalHandler)
    let handlerFut = chained(r)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    handlerFut.addCallback(proc() =
      if handlerFut.hasError():
        let err = handlerFut.getError()
        if capturedErrorHandler != nil:
          let errFut = capturedErrorHandler(r, err)
          errFut.addCallback(proc() =
            if errFut.hasError():
              resultFut.complete(newResponse(500, "Internal Server Error"))
            else:
              resultFut.complete(errFut.read())
          )
        elif err of RequestExtractionError:
          let rex = cast[ref RequestExtractionError](err)
          resultFut.complete(newResponse(rex.statusCode, rex.msg))
        elif err of JsonParsingError:
          resultFut.complete(newResponse(400, "Invalid JSON body"))
        else:
          resultFut.complete(newResponse(500, "Internal Server Error"))
      else:
        resultFut.complete(handlerFut.read())
    )
    return resultFut

  # Helper: invoke a route with full middleware chain + error recovery
  proc invokeRoute(route: RouteEntry, r: HttpRequest,
                    pp: Table[string, string],
                    capturedQp: Table[string, string]): CpsFuture[HttpResponseBuilder] =
    let capturedHandler = route.handler
    let routePattern = segmentsToPattern(route.segments)
    let inner: HttpHandler = proc(r2: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      capturedHandler(r2, pp, capturedQp)
    let allMw =
      if route.hasCompiledMiddlewares: route.compiledMiddlewares
      else: capturedBeforeMw & route.middlewares & capturedAfterMw
    var routedReq = r
    routedReq.context["route_pattern"] = routePattern
    invokeWithRecovery(allMw, inner, routedReq)

  # Helper: invoke fallback handlers (404/OPTIONS/notFound) through global middleware.
  proc invokeFallback(finalHandler: HttpHandler): CpsFuture[HttpResponseBuilder] =
    invokeWithRecovery(fallbackMw, finalHandler, req)

  proc allowMethodsForPath(path: string): seq[string] =
    for route in router.routes:
      let (matched, _) = matchRoute(route.segments, path)
      if not matched:
        continue
      if route.meth == "*":
        return @["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
      if route.meth notin result:
        result.add route.meth
    if "GET" in result and "HEAD" notin result:
      result.add "HEAD"
    if result.len > 0 and "OPTIONS" notin result:
      result.add "OPTIONS"

  # 0. Trailing slash redirect — must happen before route matching
  #    because matchRoute strips trailing slashes.
  #    Run through fallback middleware chain for consistent headers/logging.
  if router.trailingSlash == tsbRedirect and cleanPath.len > 1 and cleanPath.endsWith("/"):
    let altPath = cleanPath[0..^2]
    for route in router.routes:
      if route.meth != req.meth and route.meth != "*": continue
      let (matched, _) = matchRoute(route.segments, altPath)
      if matched:
        let redir = if req.path.find('?') >= 0:
          altPath & req.path[req.path.find('?') .. ^1]
        else: altPath
        let redirectHandler: HttpHandler =
          proc(_: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
            let fut = newCpsFuture[HttpResponseBuilder]()
            fut.complete(redirectResponse(redir, 301))
            return fut
        return invokeFallback(redirectHandler)

  # Fallback proc: HEAD auto-gen, OPTIONS auto-gen, trailing slash, not found
  proc handleFallbacks(): CpsFuture[HttpResponseBuilder] =
    # HEAD auto-generation: fall back to GET routes
    if req.meth == "HEAD":
      for i in 0 ..< router.routes.len:
        let route = router.routes[i]
        if route.meth != "GET": continue
        let (matched, pp) = matchRoute(route.segments, cleanPath)
        if matched:
          let getFut = invokeRoute(route, req, pp, qp)
          let resultFut = newCpsFuture[HttpResponseBuilder]()
          getFut.addCallback(proc() =
            if getFut.hasError():
              resultFut.fail(getFut.getError())
            else:
              var resp = getFut.read()
              resp.headers.add ("Content-Length", $resp.body.len)
              resp.body = ""
              resultFut.complete(resp)
          )
          return resultFut

    # OPTIONS auto-generation: collect allowed methods
    if req.meth == "OPTIONS":
      var methods: seq[string]
      for route in router.routes:
        let (matched, _) = matchRoute(route.segments, cleanPath)
        if matched:
          if route.meth == "*":
            methods = @["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
            break
          elif route.meth notin methods:
            methods.add route.meth
      if methods.len > 0:
        if "GET" in methods and "HEAD" notin methods:
          methods.add "HEAD"
        let allowValue = methods.join(", ")
        let autoOptionsHandler: HttpHandler =
          proc(_: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
            let fut = newCpsFuture[HttpResponseBuilder]()
            fut.complete(newResponse(204, "", @[
              ("Allow", allowValue),
              ("Content-Length", "0")
            ]))
            return fut
        return invokeFallback(autoOptionsHandler)

    # Trailing slash strip mode
    if router.trailingSlash == tsbStrip:
      let hasTrailing = cleanPath.endsWith("/") and cleanPath.len > 1
      let altPath = if hasTrailing: cleanPath[0..^2] else: cleanPath & "/"
      for i in 0 ..< router.routes.len:
        let route = router.routes[i]
        if route.meth != req.meth and route.meth != "*": continue
        let (matched, pp) = matchRoute(route.segments, altPath)
        if matched:
          return invokeRoute(route, req, pp, qp)

    # Method exists for the path, but not this method: 405 + Allow
    if req.meth != "OPTIONS":
      let allowMethods = allowMethodsForPath(cleanPath)
      if allowMethods.len > 0:
        let allowValue = allowMethods.join(", ")
        let auto405Handler: HttpHandler =
          proc(_: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
            let fut = newCpsFuture[HttpResponseBuilder]()
            fut.complete(newResponse(405, "Method Not Allowed", @[
              ("Allow", allowValue)
            ]))
            return fut
        return invokeFallback(auto405Handler)

    # Not found
    if router.notFoundHandler != nil:
      return invokeFallback(router.notFoundHandler)
    let defaultNotFound: HttpHandler =
      proc(_: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        let fut = newCpsFuture[HttpResponseBuilder]()
        fut.complete(newResponse(404, "Not Found"))
        return fut
    return invokeFallback(defaultNotFound)

  # 1. Collect all matching routes for this method+path
  var matchedRoutes: seq[(RouteEntry, Table[string, string])]
  for route in router.routes:
    if route.meth != req.meth and route.meth != "*": continue
    let (matched, pp) = matchRoute(route.segments, cleanPath)
    if matched:
      matchedRoutes.add (route, pp)

  if matchedRoutes.len == 0:
    return handleFallbacks()

  # 2. Try routes in order with "pass" support
  proc chainRoutes(idx: int): CpsFuture[HttpResponseBuilder] =
    if idx >= matchedRoutes.len:
      return handleFallbacks()
    let (route, pp) = matchedRoutes[idx]
    let routeFut = invokeRoute(route, req, pp, qp)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    let capturedIdx = idx
    routeFut.addCallback(proc() =
      if routeFut.hasError():
        resultFut.fail(routeFut.getError())
      else:
        let resp = routeFut.read()
        if resp.control == rcPassRoute or resp.statusCode == -1:
          let nextFut = chainRoutes(capturedIdx + 1)
          nextFut.addCallback(proc() =
            if nextFut.hasError():
              resultFut.fail(nextFut.getError())
            else:
              resultFut.complete(nextFut.read())
          )
        else:
          resultFut.complete(resp)
    )
    return resultFut

  return chainRoutes(0)

proc toHandler*(router: Router): HttpHandler =
  ## Convert a Router into an HttpHandler closure for use with the server.
  let r = router
  result = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    dispatch(r, req)

# ============================================================
# Sub-router mounting
# ============================================================

proc mountRouter*(parent: var Router, prefix: string, child: Router,
                  middlewares: seq[Middleware] = @[]) =
  ## Mount a child router at the given prefix. Requests to prefix/* are
  ## dispatched to the child router with the prefix stripped.
  let capturedChild = child
  let capturedPrefix = prefix.strip(chars = {'/'})
  let pattern = "/" & capturedPrefix & "/*"
  let handler: RouteHandler = proc(req: HttpRequest, pp: Table[string, string],
                                    qp: Table[string, string]): CpsFuture[HttpResponseBuilder] {.closure.} =
    var modReq = req
    let prefix = "/" & capturedPrefix
    if modReq.path.startsWith(prefix):
      modReq.path = modReq.path[prefix.len .. ^1]
      if modReq.path.len == 0:
        modReq.path = "/"
    dispatch(capturedChild, modReq)

  parent.routes.add RouteEntry(
    meth: "*",
    segments: parsePath(pattern),
    handler: handler,
    middlewares: middlewares
  )

proc mountHandler*(parent: var Router, prefix: string, handler: HttpHandler,
                   middlewares: seq[Middleware] = @[]) =
  ## Mount an HttpHandler at the given prefix.
  let capturedHandler = handler
  let capturedPrefix = prefix.strip(chars = {'/'})
  let pattern = "/" & capturedPrefix & "/*"
  let routeHandler: RouteHandler = proc(req: HttpRequest, pp: Table[string, string],
                                         qp: Table[string, string]): CpsFuture[HttpResponseBuilder] {.closure.} =
    var modReq = req
    let prefix = "/" & capturedPrefix
    if modReq.path.startsWith(prefix):
      modReq.path = modReq.path[prefix.len .. ^1]
      if modReq.path.len == 0:
        modReq.path = "/"
    capturedHandler(modReq)

  parent.routes.add RouteEntry(
    meth: "*",
    segments: parsePath(pattern),
    handler: routeHandler,
    middlewares: middlewares
  )

# ============================================================
# Example / built-in middleware
# ============================================================

proc logMiddleware*(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] =
  ## Simple logging middleware — echoes method+path, calls next, echoes status.
  echo req.meth & " " & req.path
  let fut = next(req)
  let resultFut = newCpsFuture[HttpResponseBuilder]()
  fut.addCallback(proc() =
    if fut.hasError():
      echo "  -> ERROR: " & fut.getError().msg
      resultFut.fail(fut.getError())
    else:
      let resp = fut.read()
      echo "  -> " & $resp.statusCode
      resultFut.complete(resp)
  )
  return resultFut

proc corsMiddleware*(allowOrigin: string = "*"): Middleware =
  ## Simple CORS middleware that adds Access-Control-Allow-Origin.
  let origin = allowOrigin
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let fut = next(req)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    fut.addCallback(proc() =
      if fut.hasError():
        resultFut.fail(fut.getError())
      else:
        var resp = fut.read()
        resp.headers.add ("Access-Control-Allow-Origin", origin)
        resultFut.complete(resp)
    )
    return resultFut

proc corsMiddleware*(allowOrigins: seq[string],
                      allowMethods: seq[string] = @["GET", "POST", "PUT", "DELETE", "PATCH"],
                      allowHeaders: seq[string] = @[],
                      exposeHeaders: seq[string] = @[],
                      allowCredentials: bool = false,
                      maxAge: int = 0): Middleware =
  ## Full CORS middleware with all options.
  let capturedOrigins = allowOrigins
  let capturedMethods = allowMethods
  let capturedAllowHeaders = allowHeaders
  let capturedExposeHeaders = exposeHeaders
  let capturedCredentials = allowCredentials
  let capturedMaxAge = maxAge
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let reqOrigin = req.getHeader("origin")

    # Check if origin is allowed
    var originAllowed = false
    var matchedOrigin = ""
    var needsVaryOrigin = false
    if capturedOrigins.len == 1 and capturedOrigins[0] == "*":
      if capturedCredentials:
        # Wildcard + credentials must reflect concrete origin.
        if reqOrigin.len > 0:
          originAllowed = true
          matchedOrigin = reqOrigin
          needsVaryOrigin = true
      else:
        originAllowed = true
        matchedOrigin = "*"
    elif reqOrigin.len > 0:
      for o in capturedOrigins:
        if o == reqOrigin:
          originAllowed = true
          matchedOrigin = reqOrigin
          break

    if not originAllowed:
      return next(req)

    # Preflight request
    if req.meth == "OPTIONS":
      let resultFut = newCpsFuture[HttpResponseBuilder]()
      var headers: seq[(string, string)]
      headers.add ("Access-Control-Allow-Origin", matchedOrigin)
      headers.add ("Access-Control-Allow-Methods", capturedMethods.join(", "))
      if capturedAllowHeaders.len > 0:
        headers.add ("Access-Control-Allow-Headers", capturedAllowHeaders.join(", "))
      else:
        # Reflect request headers
        let reqHeaders = req.getHeader("access-control-request-headers")
        if reqHeaders.len > 0:
          headers.add ("Access-Control-Allow-Headers", reqHeaders)
      if capturedCredentials:
        headers.add ("Access-Control-Allow-Credentials", "true")
      if needsVaryOrigin:
        headers.add ("Vary", "Origin")
      if capturedMaxAge > 0:
        headers.add ("Access-Control-Max-Age", $capturedMaxAge)
      headers.add ("Content-Length", "0")
      resultFut.complete(newResponse(204, "", headers))
      return resultFut

    # Normal request — add CORS headers to response
    let fut = next(req)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    let capturedMatchedOrigin = matchedOrigin
    fut.addCallback(proc() =
      if fut.hasError():
        resultFut.fail(fut.getError())
      else:
        var resp = fut.read()
        resp.headers.add ("Access-Control-Allow-Origin", capturedMatchedOrigin)
        if capturedCredentials:
          resp.headers.add ("Access-Control-Allow-Credentials", "true")
        if needsVaryOrigin:
          resp.headers.add ("Vary", "Origin")
        if capturedExposeHeaders.len > 0:
          resp.headers.add ("Access-Control-Expose-Headers", capturedExposeHeaders.join(", "))
        resultFut.complete(resp)
    )
    return resultFut

proc securityHeadersMiddleware*(
    hsts: int = 31536000,
    noSniff: bool = true,
    frameOptions: string = "DENY",
    xssProtection: bool = true,
    referrerPolicy: string = "strict-origin-when-cross-origin"
): Middleware =
  ## Add common security headers to all responses.
  let capturedHsts = hsts
  let capturedNoSniff = noSniff
  let capturedFrameOptions = frameOptions
  let capturedXssProtection = xssProtection
  let capturedReferrerPolicy = referrerPolicy
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let fut = next(req)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    fut.addCallback(proc() =
      if fut.hasError():
        resultFut.fail(fut.getError())
      else:
        var resp = fut.read()
        if capturedHsts > 0:
          resp.headers.add ("Strict-Transport-Security",
            "max-age=" & $capturedHsts & "; includeSubDomains")
        if capturedNoSniff:
          resp.headers.add ("X-Content-Type-Options", "nosniff")
        if capturedFrameOptions.len > 0:
          resp.headers.add ("X-Frame-Options", capturedFrameOptions)
        if capturedXssProtection:
          resp.headers.add ("X-XSS-Protection", "1; mode=block")
        if capturedReferrerPolicy.len > 0:
          resp.headers.add ("Referrer-Policy", capturedReferrerPolicy)
        resultFut.complete(resp)
    )
    return resultFut

var requestIdCounter* {.global.}: Atomic[uint64]

proc requestIdMiddleware*(headerName: string = "X-Request-ID"): Middleware =
  ## Add a request ID to each request/response. Uses existing header if present.
  let capturedHeader = headerName
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    var modReq = req
    if modReq.context.isNil:
      modReq.context = newTable[string, string]()
    var reqId = modReq.getHeader(capturedHeader)
    if reqId.len == 0:
      let idNum = requestIdCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
      reqId = "req-" & $idNum
      modReq.headers.add (capturedHeader, reqId)
    modReq.context[capturedHeader] = reqId
    let fut = next(modReq)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    let capturedReqId = reqId
    fut.addCallback(proc() =
      if fut.hasError():
        resultFut.fail(fut.getError())
      else:
        var resp = fut.read()
        resp.headers.add (capturedHeader, capturedReqId)
        resultFut.complete(resp)
    )
    return resultFut

proc bodySizeLimitMiddleware*(maxBytes: int): Middleware =
  ## Reject requests with Content-Length exceeding maxBytes (413 Payload Too Large).
  let capturedMax = maxBytes
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let clHeader = req.getHeader("content-length")
    if clHeader.len > 0:
      try:
        let cl = parseInt(clHeader)
        if cl > capturedMax:
          let fut = newCpsFuture[HttpResponseBuilder]()
          fut.complete(newResponse(413, "Payload Too Large"))
          return fut
      except ValueError:
        discard
    if req.body.len > capturedMax:
      let fut = newCpsFuture[HttpResponseBuilder]()
      fut.complete(newResponse(413, "Payload Too Large"))
      return fut
    return next(req)

proc timeoutMiddleware*(timeoutMs: int): Middleware =
  ## Wrap handler with a timeout — returns 504 Gateway Timeout if handler doesn't
  ## complete within timeoutMs milliseconds.
  let capturedTimeout = timeoutMs
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let handlerFut = next(req)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    var completed: Atomic[bool]
    completed.store(false, moRelaxed)

    # Set up timeout timer
    let loop = getEventLoop()
    loop.registerTimer(capturedTimeout, proc() =
      var expected = false
      if completed.compareExchange(expected, true, moAcquireRelease, moAcquire):
        resultFut.complete(newResponse(504, "Gateway Timeout"))
    )

    handlerFut.addCallback(proc() =
      var expected = false
      if completed.compareExchange(expected, true, moAcquireRelease, moAcquire):
        if handlerFut.hasError():
          resultFut.fail(handlerFut.getError())
        else:
          resultFut.complete(handlerFut.read())
    )
    return resultFut

proc accessLogMiddleware*(format: string = "combined"): Middleware =
  ## Structured access log middleware. Logs method, path, status, and duration.
  let capturedFormat = format
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let startTime = epochTime()
    let capturedMethod = req.meth
    let capturedPath = req.path
    let capturedIp = extractClientIp(req)
    let fut = next(req)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    fut.addCallback(proc() =
      let duration = (epochTime() - startTime) * 1000.0
      if fut.hasError():
        echo capturedIp & " " & capturedMethod & " " & capturedPath & " 500 " & $duration.int & "ms"
        resultFut.fail(fut.getError())
      else:
        let resp = fut.read()
        if capturedFormat == "combined":
          let ua = req.getHeader("user-agent")
          echo capturedIp & " " & capturedMethod & " " & capturedPath & " " & $resp.statusCode & " " & $duration.int & "ms \"" & ua & "\""
        else:
          echo capturedIp & " " & capturedMethod & " " & capturedPath & " " & $resp.statusCode & " " & $duration.int & "ms"
        resultFut.complete(resp)
    )
    return resultFut

proc methodOverrideMiddleware*(): Middleware =
  ## Override HTTP method from _method form field or X-HTTP-Method-Override header.
  ## Useful for browsers that only support GET/POST.
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    var modReq = req
    # Check header first
    let overrideHeader = req.getHeader("x-http-method-override")
    if overrideHeader.len > 0:
      modReq.meth = overrideHeader.toUpperAscii
    elif req.meth == "POST":
      # Check _method form field
      let ct = req.getHeader("content-type")
      if ct.toLowerAscii.startsWith("application/x-www-form-urlencoded"):
        let form = parseFormBody(req.body)
        let methodVal = form.getOrDefault("_method")
        if methodVal.len > 0:
          modReq.meth = methodVal.toUpperAscii
    return next(modReq)

proc compressionMiddleware*(minBodySize: int = 256,
                            level: CompressionLevel = clDefault): Middleware =
  ## Factory returning a compression middleware that gzip/deflate/br/zstd
  ## compresses response bodies based on Accept-Encoding.
  let capturedMinSize = minBodySize
  let capturedLevel = level
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let fut = next(req)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    let capturedReq = req
    fut.addCallback(proc() =
      if fut.hasError():
        resultFut.fail(fut.getError())
        return

      var resp = fut.read()

      # Skip: control responses (SSE/WebSocket/pass/continue), no-content, not-modified
      if resp.control != rcNone or resp.statusCode == 0 or resp.statusCode == 204 or resp.statusCode == 304:
        resultFut.complete(resp)
        return

      # Skip: body too small
      if resp.body.len < capturedMinSize:
        resultFut.complete(resp)
        return

      # Skip: already has Content-Encoding
      if resp.getResponseHeader("content-encoding").len > 0:
        resultFut.complete(resp)
        return

      # Skip: content-type not compressible
      let ct = resp.getResponseHeader("content-type")
      if ct.len > 0 and not isCompressible(ct):
        resultFut.complete(resp)
        return

      # Parse Accept-Encoding from request
      let aeHeader = capturedReq.getHeader("accept-encoding")
      if aeHeader.len == 0:
        resultFut.complete(resp)
        return

      let accepted = parseAcceptEncoding(aeHeader)
      let enc = bestEncoding(accepted)
      if enc == ceIdentity:
        resultFut.complete(resp)
        return

      # Compress
      try:
        let compressed = compress(resp.body, enc, capturedLevel)
        # Only use compressed version if it's actually smaller
        if compressed.len < resp.body.len:
          resp.body = compressed
          resp.headers.add ("Content-Encoding", encodingName(enc))
          resp.headers.add ("Vary", "Accept-Encoding")
          # Remove any existing Content-Length (will be recalculated)
          var newHeaders: seq[(string, string)]
          for (k, v) in resp.headers:
            if k.toLowerAscii != "content-length":
              newHeaders.add (k, v)
          resp.headers = newHeaders
      except CompressionError:
        discard  # Fall through with uncompressed response

      resultFut.complete(resp)
    )
    return resultFut
