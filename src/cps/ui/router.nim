## CPS UI Router

import std/[tables, strutils, uri, algorithm, parseutils]
when not defined(wasm):
  import std/times
import ./types
import ./vdom
import ./dombridge
import ./scheduler

type
  RouteParams* = Table[string, string]
  QueryParamsAll* = Table[string, seq[string]]

  RouteLoadState* = enum
    rlsPending,
    rlsReady,
    rlsError,
    rlsRedirect

  RouteLoad* = ref object
    state*: RouteLoadState
    data*: ref RootObj
    error*: string
    redirectTo*: string
    replace*: bool
    token: int64

  LegacyRouteLoader* = proc(params: RouteParams): ref RootObj {.closure.}
  LegacyRouteAction* = proc(params: RouteParams, payload: string): ref RootObj {.closure.}

  RouteLoader* = proc(params: RouteParams): RouteLoad {.closure.}
  RouteAction* = proc(params: RouteParams, payload: string): RouteLoad {.closure.}
  PendingBoundaryProc* = proc(): VNode {.closure.}

  NavigationStateKind* = enum
    nskIdle,
    nskLoading,
    nskSubmitting,
    nskError

  NavigationState* = object
    kind*: NavigationStateKind
    path*: string
    error*: string
    isRevalidating*: bool
    submissionPath*: string

  RouteDef* = ref object
    path*: string
    render*: proc(params: RouteParams): VNode {.closure.}
    children*: seq[RouteDef]
    loader*: RouteLoader
    action*: RouteAction
    pendingBoundary*: PendingBoundaryProc

  NavigateOptions* = object
    replace*: bool

  FormSerializeProc* = proc(ev: UiEvent): string {.closure.}

  FormOptions* = object
    replace*: bool
    `method`*: string
    enctype*: string
    serialize*: FormSerializeProc

  RouterOptions* = object
    maxDataEntries*: int
    cacheTtlMs*: int64

  Router* = ref object
    routes*: seq[RouteDef]
    notFound*: ComponentProc
    currentPath*: string
    currentParams*: RouteParams
    currentQuery*: Table[string, string]
    currentQueryAll*: QueryParamsAll
    currentDataKey*: string
    routeData*: Table[string, ref RootObj]
    routeDataTouchedAt*: Table[string, int64]
    routeDataPath*: Table[string, string]
    routeDataLru*: seq[string]
    routeLoads*: Table[string, RouteLoad]
    routeLoadTokens*: Table[string, int64]
    nextLoadToken*: int64
    navState*: NavigationState
    revalidationRequested*: bool
    pendingSubmissionPath*: string
    pendingSubmissionPayload*: string
    pendingSubmissionReplace*: bool
    pendingSubmission*: bool
    actionLoad*: RouteLoad
    actionLoadToken*: int64
    nextActionToken*: int64
    opts*: RouterOptions

  MatchResult = object
    matched: bool
    consumed: int
    score: int
    params: RouteParams
    chain: seq[RouteDef]

  PathTokenKind = enum
    ptkLiteral
    ptkParam
    ptkWildcard

  PathToken = object
    case kind: PathTokenKind
    of ptkLiteral:
      value: string
    of ptkParam:
      name: string
      valueType: string
      optional: bool
    of ptkWildcard:
      discard

  RouteDataBox[T] = ref object of RootObj
    value: T

var
  routerStack: seq[Router] = @[]
  lastResolvedRouter: Router = nil

proc loadReady*(data: ref RootObj): RouteLoad =
  RouteLoad(
    state: rlsReady,
    data: data,
    error: "",
    redirectTo: "",
    replace: false,
    token: 0
  )

proc routeDataBox*[T](value: T): ref RootObj =
  when T is ref RootObj:
    value
  else:
    RouteDataBox[T](value: value)

proc loadReady*[T](data: T): RouteLoad =
  when T is ref RootObj:
    loadReady(cast[ref RootObj](data))
  else:
    loadReady(routeDataBox(data))

proc loadPending*(): RouteLoad =
  RouteLoad(
    state: rlsPending,
    data: nil,
    error: "",
    redirectTo: "",
    replace: false,
    token: 0
  )

proc loadError*(message: string): RouteLoad =
  RouteLoad(
    state: rlsError,
    data: nil,
    error: message,
    redirectTo: "",
    replace: false,
    token: 0
  )

proc loadRedirect*(to: string, replace = false): RouteLoad =
  RouteLoad(
    state: rlsRedirect,
    data: nil,
    error: "",
    redirectTo: to,
    replace: replace,
    token: 0
  )

proc resolveLoad*(load: RouteLoad, data: ref RootObj) =
  if load == nil:
    return
  load.data = data
  load.error = ""
  load.redirectTo = ""
  load.replace = false
  load.state = rlsReady
  requestFlush(ulTransition)

proc rejectLoad*(load: RouteLoad, message: string) =
  if load == nil:
    return
  load.error = message
  load.redirectTo = ""
  load.data = nil
  load.replace = false
  load.state = rlsError
  requestFlush(ulTransition)

proc redirectLoad*(load: RouteLoad, to: string, replace = false) =
  if load == nil:
    return
  load.redirectTo = to
  load.replace = replace
  load.data = nil
  load.error = ""
  load.state = rlsRedirect
  requestFlush(ulTransition)

converter toRouteLoader*(loader: LegacyRouteLoader): RouteLoader =
  if loader == nil:
    return nil
  proc wrapped(params: RouteParams): RouteLoad =
    loadReady(loader(params))
  wrapped

converter toRouteAction*(action: LegacyRouteAction): RouteAction =
  if action == nil:
    return nil
  proc wrapped(params: RouteParams, payload: string): RouteLoad =
    loadReady(action(params, payload))
  wrapped

proc copyParams(src: RouteParams): RouteParams =
  result = initTable[string, string]()
  for k, v in src:
    result[k] = v

proc copyQuery(src: Table[string, string]): Table[string, string] =
  result = initTable[string, string]()
  for k, v in src:
    result[k] = v

proc copyQueryAll(src: QueryParamsAll): QueryParamsAll =
  result = initTable[string, seq[string]]()
  for k, values in src:
    result[k] = values

proc normalizePath(path: string): string

proc decodeQueryPart(value: string): string =
  if value.len == 0:
    return ""
  decodeUrl(value, true)

proc decodePathPart(value: string): string =
  if value.len == 0:
    return ""
  decodeUrl(value, false)

proc splitPathAndQuery(input: string): tuple[path: string, query: string] =
  let q = input.find('?')
  if q < 0:
    (input, "")
  else:
    (input[0 ..< q], input[q + 1 .. ^1])

proc normalizePath(path: string): string =
  var p = path.strip()
  if p.len == 0:
    return "/"
  if not p.startsWith("/"):
    p = "/" & p
  while p.len > 1 and p.endsWith("/"):
    p.setLen(p.len - 1)
  p

proc pathSegments(path: string): seq[string] =
  let p = normalizePath(path)
  if p == "/":
    return @[]
  for seg in p.split('/'):
    if seg.len > 0:
      result.add decodePathPart(seg)

proc parseQueryTables(queryText: string): tuple[single: Table[string, string], all: QueryParamsAll] =
  result.single = initTable[string, string]()
  result.all = initTable[string, seq[string]]()
  if queryText.len == 0:
    return
  for pair in queryText.split('&'):
    if pair.len == 0:
      continue
    let eq = pair.find('=')
    var key = ""
    var value = ""
    if eq < 0:
      key = decodeQueryPart(pair)
    else:
      key = decodeQueryPart(pair[0 ..< eq])
      value = decodeQueryPart(pair[eq + 1 .. ^1])
    result.single[key] = value
    if key in result.all:
      result.all[key].add value
    else:
      result.all[key] = @[value]

proc parseQueryTable(queryText: string): Table[string, string] =
  parseQueryTables(queryText).single

proc normalizedPort(scheme, port: string): string =
  if port.len > 0:
    return port
  case scheme.toLowerAscii()
  of "http":
    "80"
  of "https":
    "443"
  else:
    ""

proc tryParseIntNoExcept(value: string, parsed: var int): bool =
  if value.len == 0:
    return false

  var i = 0
  var sign = 1'i64
  if value[i] == '+' or value[i] == '-':
    if value[i] == '-':
      sign = -1
    inc i

  if i >= value.len:
    return false

  var acc = 0'i64
  var hasDigit = false
  while i < value.len:
    let ch = value[i]
    if ch == '_':
      inc i
      continue
    if ch < '0' or ch > '9':
      return false
    hasDigit = true
    let digit = int64(ord(ch) - ord('0'))
    if acc > (high(int64) - digit) div 10:
      return false
    acc = acc * 10 + digit
    inc i

  if not hasDigit:
    return false

  let signed = acc * sign
  if signed < int64(low(int)) or signed > int64(high(int)):
    return false
  parsed = int(signed)
  true

proc tryParseFloatNoExcept(value: string, parsed: var float): bool =
  if value.len == 0:
    return false
  parseutils.parseFloat(value, parsed) == value.len

proc tryParseBoolNoExcept(value: string, parsed: var bool): bool =
  case normalize(value)
  of "y", "yes", "true", "1", "on":
    parsed = true
    true
  of "n", "no", "false", "0", "off":
    parsed = false
    true
  else:
    false

proc normalizeNavigationInput(input: string): tuple[ok: bool, href: string, path: string] =
  let raw = input.strip()
  if raw.len == 0:
    return (true, "/", "/")

  let lower = raw.toLowerAscii()
  if raw[0] == '#' or raw.startsWith("//") or
     lower.startsWith("mailto:") or lower.startsWith("tel:") or
     lower.startsWith("javascript:") or lower.startsWith("data:"):
    return (false, raw, "")

  if lower.startsWith("http://") or lower.startsWith("https://"):
    let originRaw = locationOrigin().strip()
    if originRaw.len == 0:
      return (false, raw, "")
    let targetUri = parseUri(raw)
    let originUri = parseUri(originRaw)
    let sameOrigin =
      targetUri.scheme.toLowerAscii() == originUri.scheme.toLowerAscii() and
      targetUri.hostname.toLowerAscii() == originUri.hostname.toLowerAscii() and
      normalizedPort(targetUri.scheme, targetUri.port) == normalizedPort(originUri.scheme, originUri.port)
    if not sameOrigin:
      return (false, raw, "")

    var fullPath = targetUri.path
    if fullPath.len == 0:
      fullPath = "/"
    if targetUri.query.len > 0:
      fullPath.add("?" & targetUri.query)
    return (true, raw, normalizePath(fullPath))

  let (pathPart, queryPart) = splitPathAndQuery(raw)
  let normalized = normalizePath(pathPart)
  let fullPath =
    if queryPart.len > 0:
      normalized & "?" & queryPart
    else:
      normalized
  (true, fullPath, fullPath)

proc routeChainKey(chain: seq[RouteDef]): string =
  if chain.len == 0:
    return "root"
  for i, route in chain:
    if i > 0:
      result.add(">")
    if route == nil:
      result.add("nil")
      continue
    result.add(normalizePath(route.path))
    result.add("#")
    result.add($cast[uint](route))

proc routeDataKey(
  routeChainKey: string,
  params: RouteParams,
  query: Table[string, string],
  queryAll: QueryParamsAll
): string =
  result = routeChainKey

  if params.len > 0:
    var paramKeys: seq[string] = @[]
    for k in params.keys:
      paramKeys.add k
    paramKeys.sort()
    for key in paramKeys:
      result.add("|p:")
      result.add(key)
      result.add("=")
      result.add(params.getOrDefault(key, ""))

  if queryAll.len > 0:
    var queryKeys: seq[string] = @[]
    for k in queryAll.keys:
      queryKeys.add k
    queryKeys.sort()
    for key in queryKeys:
      let values = queryAll.getOrDefault(key, @[])
      if values.len == 0:
        result.add("|q:")
        result.add(key)
        result.add("=")
      else:
        for idx, value in values:
          result.add("|q:")
          result.add(key)
          result.add("[")
          result.add($idx)
          result.add("]=")
          result.add(value)
  elif query.len > 0:
    var queryKeys: seq[string] = @[]
    for k in query.keys:
      queryKeys.add k
    queryKeys.sort()
    for key in queryKeys:
      result.add("|q:")
      result.add(key)
      result.add("=")
      result.add(query.getOrDefault(key, ""))

proc routeDataKey(
  routeChainKey: string,
  params: RouteParams,
  query: Table[string, string]
): string =
  routeDataKey(routeChainKey, params, query, initTable[string, seq[string]]())

proc parseIntParam(value: string, source: string, key: string): int =
  if value.len == 0:
    raise newException(ValueError, "Missing " & source & " parameter: " & key)
  if not tryParseIntNoExcept(value, result):
    raise newException(ValueError, "Invalid " & source & " parameter '" & key & "'")

proc parseFloatParam(value: string, source: string, key: string): float =
  if value.len == 0:
    raise newException(ValueError, "Missing " & source & " parameter: " & key)
  if not tryParseFloatNoExcept(value, result):
    raise newException(ValueError, "Invalid " & source & " parameter '" & key & "'")

proc parseBoolParam(value: string, source: string, key: string): bool =
  if value.len == 0:
    raise newException(ValueError, "Missing " & source & " parameter: " & key)
  if not tryParseBoolNoExcept(value, result):
    raise newException(ValueError, "Invalid " & source & " parameter '" & key & "'")

proc pathParamValue*(pp: RouteParams, key: string): string =
  if key notin pp:
    raise newException(ValueError, "Missing path parameter: " & key)
  pp[key]

proc pathParamInt*(pp: RouteParams, key: string): int =
  parseIntParam(pathParamValue(pp, key), "path", key)

proc pathParamFloat*(pp: RouteParams, key: string): float =
  parseFloatParam(pathParamValue(pp, key), "path", key)

proc pathParamBool*(pp: RouteParams, key: string): bool =
  parseBoolParam(pathParamValue(pp, key), "path", key)

proc queryParamRequired*(qp: Table[string, string], key: string): string =
  if key notin qp:
    raise newException(ValueError, "Missing query parameter: " & key)
  qp[key]

proc queryParamInt*(qp: Table[string, string], key: string): int =
  parseIntParam(queryParamRequired(qp, key), "query", key)

proc queryParamInt*(qp: Table[string, string], key: string, defaultVal: int): int =
  if key notin qp or qp[key].len == 0:
    return defaultVal
  parseIntParam(qp[key], "query", key)

proc queryParamInt*(qp: Table[string, string], key: string, defaultVal: string): int =
  if key notin qp or qp[key].len == 0:
    return parseIntParam(defaultVal, "query", key)
  parseIntParam(qp[key], "query", key)

proc queryParamFloat*(qp: Table[string, string], key: string): float =
  parseFloatParam(queryParamRequired(qp, key), "query", key)

proc queryParamFloat*(qp: Table[string, string], key: string, defaultVal: float): float =
  if key notin qp or qp[key].len == 0:
    return defaultVal
  parseFloatParam(qp[key], "query", key)

proc queryParamFloat*(qp: Table[string, string], key: string, defaultVal: string): float =
  if key notin qp or qp[key].len == 0:
    return parseFloatParam(defaultVal, "query", key)
  parseFloatParam(qp[key], "query", key)

proc queryParamBool*(qp: Table[string, string], key: string): bool =
  parseBoolParam(queryParamRequired(qp, key), "query", key)

proc queryParamBool*(qp: Table[string, string], key: string, defaultVal: bool): bool =
  if key notin qp or qp[key].len == 0:
    return defaultVal
  parseBoolParam(qp[key], "query", key)

proc queryParamBool*(qp: Table[string, string], key: string, defaultVal: string): bool =
  if key notin qp or qp[key].len == 0:
    return parseBoolParam(defaultVal, "query", key)
  parseBoolParam(qp[key], "query", key)

proc queryParamAll*(qpAll: QueryParamsAll, key: string): seq[string] =
  qpAll.getOrDefault(key, @[])

proc queryParamAllInt*(qpAll: QueryParamsAll, key: string): seq[int] =
  for value in queryParamAll(qpAll, key):
    result.add parseIntParam(value, "query", key)

proc queryParamAllFloat*(qpAll: QueryParamsAll, key: string): seq[float] =
  for value in queryParamAll(qpAll, key):
    result.add parseFloatParam(value, "query", key)

proc queryParamAllBool*(qpAll: QueryParamsAll, key: string): seq[bool] =
  for value in queryParamAll(qpAll, key):
    result.add parseBoolParam(value, "query", key)

proc isValidUuid(s: string): bool =
  if s.len != 36:
    return false
  for i, c in s:
    if i in {8, 13, 18, 23}:
      if c != '-':
        return false
    else:
      if c notin HexDigits:
        return false
  true

proc validateParamType(value: string, paramType: string): bool =
  case paramType
  of "int":
    var parsed = 0
    return tryParseIntNoExcept(value, parsed)
  of "float":
    var parsed = 0.0
    return tryParseFloatNoExcept(value, parsed)
  of "bool":
    var parsed = false
    return tryParseBoolNoExcept(value, parsed)
  of "uuid":
    return isValidUuid(value)
  of "alpha":
    for c in value:
      if c notin Letters:
        return false
    return value.len > 0
  of "alnum":
    for c in value:
      if c notin Letters + Digits:
        return false
    return value.len > 0
  of "":
    return true
  else:
    return true

proc parsePathToken(rawToken: string): PathToken =
  if rawToken == "*":
    return PathToken(kind: ptkWildcard)

  if rawToken.len > 1 and rawToken[0] == ':':
    var inner = rawToken[1 .. ^1]
    var isOptional = false
    if inner.endsWith("?"):
      isOptional = true
      inner = inner[0 ..< inner.len - 1]
    var name = inner
    var valueType = ""
    let colonIdx = inner.find(':')
    if colonIdx >= 0:
      name = inner[0 ..< colonIdx]
      valueType = inner[colonIdx + 1 .. ^1].toLowerAscii()
    if name.len > 0:
      return PathToken(kind: ptkParam, name: name, valueType: valueType, optional: isOptional)
    return PathToken(kind: ptkLiteral, value: rawToken)

  if rawToken.len > 2 and rawToken[0] == '{' and rawToken[^1] == '}':
    var inner = rawToken[1 ..< rawToken.len - 1].strip()
    var isOptional = false
    if inner.endsWith("?"):
      isOptional = true
      inner = inner[0 ..< inner.len - 1]
    var name = inner
    var valueType = ""
    let colonIdx = inner.find(':')
    if colonIdx >= 0:
      name = inner[0 ..< colonIdx].strip()
      valueType = inner[colonIdx + 1 .. ^1].strip().toLowerAscii()
    if name.len > 0:
      return PathToken(kind: ptkParam, name: name, valueType: valueType, optional: isOptional)

  PathToken(kind: ptkLiteral, value: rawToken)

proc routeTokens(path: string): seq[PathToken] =
  var p = path.strip()
  if p.len == 0 or p == "/":
    return @[]
  if p.startsWith("/"):
    p = p[1 .. ^1]
  if p.endsWith("/"):
    p.setLen(p.len - 1)
  for tok in p.split('/'):
    if tok.len > 0:
      result.add parsePathToken(tok)

proc betterMatch(a, b: MatchResult): bool =
  if not a.matched:
    return false
  if not b.matched:
    return true
  if a.consumed != b.consumed:
    return a.consumed > b.consumed
  if a.score != b.score:
    return a.score > b.score
  a.chain.len > b.chain.len

proc matchRoute(route: RouteDef, segments: seq[string], startIdx: int, baseParams: RouteParams): MatchResult =
  if route == nil:
    return

  let tokens = routeTokens(route.path)
  var idx = startIdx
  var params = copyParams(baseParams)
  var score = 0
  var wildcard = false

  for i, tok in tokens:
    if tok.kind == ptkWildcard:
      wildcard = true
      score += 1
      idx = segments.len
      break

    if idx >= segments.len:
      if tok.kind == ptkParam and tok.optional and i == tokens.high:
        continue
      return

    case tok.kind
    of ptkLiteral:
      if tok.value != segments[idx]:
        return
      score += 3
      inc idx
    of ptkParam:
      if not validateParamType(segments[idx], tok.valueType):
        return
      params[tok.name] = segments[idx]
      score += 2
      inc idx
    of ptkWildcard:
      discard

  var bestChild: MatchResult
  for child in route.children:
    let childRes = matchRoute(child, segments, idx, params)
    if betterMatch(childRes, bestChild):
      bestChild = childRes

  if bestChild.matched:
    result = bestChild
    result.chain.insert(route, 0)
    result.score += score
    return

  if idx == segments.len or wildcard:
    result.matched = true
    result.consumed = idx
    result.score = score
    result.params = params
    result.chain = @[route]

proc findBestMatch(router: Router, normalizedPath: string): MatchResult =
  if router == nil:
    return
  let segments = pathSegments(normalizedPath)
  let emptyParams = initTable[string, string]()
  for r in router.routes:
    let cand = matchRoute(r, segments, 0, emptyParams)
    if betterMatch(cand, result):
      result = cand

proc replaceOutlet(node, outlet: VNode): VNode =
  if node == nil:
    return nil
  case node.kind
  of vkRouterOutlet:
    return outlet
  of vkComponent:
    if node.renderFn == nil:
      return node
    let originalRender = node.renderFn
    return component(
      proc(): VNode =
        let rendered = originalRender()
        replaceOutlet(rendered, outlet),
      key = node.key,
      typeName = node.componentType
    )
  of vkElement, vkFragment, vkPortal, vkErrorBoundary, vkSuspense, vkContextProvider:
    var kids: seq[VNode] = @[]
    for child in node.children:
      let resolved = replaceOutlet(child, outlet)
      if resolved != nil:
        kids.add resolved
    node.children = kids
    node
  else:
    node

proc renderChain(chain: seq[RouteDef], params: RouteParams): VNode =
  var outlet: VNode = nil
  for i in countdown(chain.len - 1, 0):
    let route = chain[i]
    if route == nil or route.render == nil:
      continue
    let rendered = route.render(params)
    outlet = replaceOutlet(rendered, outlet)
  outlet

proc activeRouter(): Router =
  if routerStack.len > 0:
    return routerStack[^1]
  lastResolvedRouter

proc nowMs(): int64 =
  when defined(wasm):
    0'i64
  else:
    (epochTime() * 1000.0).int64

proc removeRouteDataLruKey(router: Router, key: string) =
  if router == nil:
    return
  var next: seq[string] = @[]
  for existing in router.routeDataLru:
    if existing != key:
      next.add existing
  router.routeDataLru = next

proc touchRouteDataKey(router: Router, key: string, touchedAt: int64 = nowMs()) =
  if router == nil or key.len == 0:
    return
  router.routeDataTouchedAt[key] = touchedAt
  removeRouteDataLruKey(router, key)
  router.routeDataLru.add key

proc deleteRouteDataKey(router: Router, key: string) =
  if router == nil or key.len == 0:
    return
  if key in router.routeData:
    router.routeData.del(key)
  if key in router.routeDataTouchedAt:
    router.routeDataTouchedAt.del(key)
  if key in router.routeDataPath:
    router.routeDataPath.del(key)
  removeRouteDataLruKey(router, key)

proc pruneExpiredRouteData(router: Router, now = nowMs()) =
  if router == nil:
    return
  if router.opts.cacheTtlMs <= 0:
    return
  let ttl = router.opts.cacheTtlMs
  var stale: seq[string] = @[]
  for key, touchedAt in router.routeDataTouchedAt:
    if now - touchedAt > ttl:
      stale.add key
  for key in stale:
    deleteRouteDataKey(router, key)

proc pruneRouteDataCapacity(router: Router) =
  if router == nil:
    return
  let maxEntries = router.opts.maxDataEntries
  if maxEntries <= 0:
    return

  while router.routeData.len > maxEntries:
    if router.routeDataLru.len == 0:
      break
    let oldest = router.routeDataLru[0]
    deleteRouteDataKey(router, oldest)

proc hasRouteData(router: Router, key: string): bool =
  if router == nil or key.len == 0:
    return false
  pruneExpiredRouteData(router)
  key in router.routeData

proc readRouteData(router: Router, key: string): ref RootObj =
  if not hasRouteData(router, key):
    return nil
  touchRouteDataKey(router, key)
  router.routeData[key]

proc cacheRouteData(router: Router, key: string, data: ref RootObj, path: string) =
  if router == nil or key.len == 0:
    return
  pruneExpiredRouteData(router)
  router.routeData[key] = data
  router.routeDataPath[key] = path
  touchRouteDataKey(router, key)
  pruneRouteDataCapacity(router)

proc startRouteLoad(router: Router, dataKey: string, loader: RouteLoader, params: RouteParams): RouteLoad =
  if router == nil:
    return nil
  var load =
    if loader != nil:
      loader(params)
    else:
      loadReady(nil)
  if load == nil:
    load = loadReady(nil)

  inc router.nextLoadToken
  load.token = router.nextLoadToken
  router.routeLoads[dataKey] = load
  router.routeLoadTokens[dataKey] = load.token
  load

proc startActionLoad(router: Router, action: RouteAction, params: RouteParams, payload: string): RouteLoad =
  if router == nil or action == nil:
    return nil
  var load = action(params, payload)
  if load == nil:
    load = loadReady(nil)
  inc router.nextActionToken
  load.token = router.nextActionToken
  router.actionLoad = load
  router.actionLoadToken = load.token
  load

proc clearRouteLoad(router: Router, dataKey: string) =
  if router == nil:
    return
  if dataKey in router.routeLoads:
    router.routeLoads.del(dataKey)
  if dataKey in router.routeLoadTokens:
    router.routeLoadTokens.del(dataKey)

proc route*(
  path: string,
  render: proc(params: RouteParams): VNode {.closure.},
  children: openArray[RouteDef] = [],
  loader: RouteLoader = nil,
  action: RouteAction = nil,
  pendingBoundary: PendingBoundaryProc = nil
): RouteDef =
  RouteDef(
    path: path,
    render: render,
    children: @children,
    loader: loader,
    action: action,
    pendingBoundary: pendingBoundary
  )

proc route*(
  path: string,
  render: proc(params: RouteParams): VNode {.closure.},
  children: openArray[RouteDef] = [],
  loader: proc(params: RouteParams): ref RootObj,
  action: proc(params: RouteParams, payload: string): ref RootObj,
  pendingBoundary: PendingBoundaryProc = nil
): RouteDef =
  var wrappedLoader: RouteLoader = nil
  var wrappedAction: RouteAction = nil

  if loader != nil:
    wrappedLoader = proc(params: RouteParams): RouteLoad =
      loadReady(loader(params))

  if action != nil:
    wrappedAction = proc(params: RouteParams, payload: string): RouteLoad =
      loadReady(action(params, payload))

  RouteDef(
    path: path,
    render: render,
    children: @children,
    loader: wrappedLoader,
    action: wrappedAction,
    pendingBoundary: pendingBoundary
  )

proc route*(
  path: string,
  render: proc(params: RouteParams): VNode {.closure.},
  children: openArray[RouteDef] = [],
  loader: proc(params: RouteParams): ref RootObj,
  action: RouteAction = nil,
  pendingBoundary: PendingBoundaryProc = nil
): RouteDef =
  var wrappedLoader: RouteLoader = nil

  if loader != nil:
    wrappedLoader = proc(params: RouteParams): RouteLoad =
      loadReady(loader(params))

  RouteDef(
    path: path,
    render: render,
    children: @children,
    loader: wrappedLoader,
    action: action,
    pendingBoundary: pendingBoundary
  )

proc route*(
  path: string,
  render: proc(params: RouteParams): VNode {.closure.},
  children: openArray[RouteDef] = [],
  action: proc(params: RouteParams, payload: string): ref RootObj,
  pendingBoundary: PendingBoundaryProc = nil
): RouteDef =
  var wrappedAction: RouteAction = nil
  if action != nil:
    wrappedAction = proc(params: RouteParams, payload: string): RouteLoad =
      loadReady(action(params, payload))

  RouteDef(
    path: path,
    render: render,
    children: @children,
    loader: nil,
    action: wrappedAction,
    pendingBoundary: pendingBoundary
  )

proc createRouter*(
  routes: openArray[RouteDef],
  notFound: ComponentProc = nil,
  opts: RouterOptions = RouterOptions()
): Router =
  Router(
    routes: @routes,
    notFound: notFound,
    currentPath: "/",
    currentParams: initTable[string, string](),
    currentQuery: initTable[string, string](),
    currentQueryAll: initTable[string, seq[string]](),
    currentDataKey: "",
    routeData: initTable[string, ref RootObj](),
    routeDataTouchedAt: initTable[string, int64](),
    routeDataPath: initTable[string, string](),
    routeDataLru: @[],
    routeLoads: initTable[string, RouteLoad](),
    routeLoadTokens: initTable[string, int64](),
    nextLoadToken: 0,
    navState: NavigationState(
      kind: nskIdle,
      path: "/",
      error: "",
      isRevalidating: false,
      submissionPath: ""
    ),
    revalidationRequested: false,
    pendingSubmissionPath: "",
    pendingSubmissionPayload: "",
    pendingSubmissionReplace: false,
    pendingSubmission: false,
    actionLoad: nil,
    actionLoadToken: 0,
    nextActionToken: 0,
    opts: opts
  )

proc RouterRoot*(router: Router): VNode =
  if router == nil:
    return text("router=nil")

  subscribeHistory()

  let raw = locationPath()
  let (pathPart, queryPart) = splitPathAndQuery(raw)
  let normalized = normalizePath(pathPart)
  let parsedQuery = parseQueryTables(queryPart)

  router.currentPath = normalized
  router.currentQuery = parsedQuery.single
  router.currentQueryAll = parsedQuery.all
  router.currentParams = initTable[string, string]()
  router.currentDataKey = ""
  router.navState = NavigationState(
    kind: nskIdle,
    path: normalized,
    error: "",
    isRevalidating: false,
    submissionPath: ""
  )
  lastResolvedRouter = router

  if router.pendingSubmission:
    let nav = normalizeNavigationInput(router.pendingSubmissionPath)
    let payload = router.pendingSubmissionPayload
    router.pendingSubmission = false
    router.pendingSubmissionPayload = ""
    router.pendingSubmissionReplace = false

    if nav.ok:
      let (submitPathPart, _) = splitPathAndQuery(nav.path)
      let submitPath = normalizePath(submitPathPart)
      let submitMatch = findBestMatch(router, submitPath)
      if submitMatch.matched and submitMatch.chain.len > 0:
        let submitLeaf = submitMatch.chain[^1]
        if submitLeaf != nil and submitLeaf.action != nil:
          discard startActionLoad(router, submitLeaf.action, submitMatch.params, payload)
          router.navState = NavigationState(
            kind: nskSubmitting,
            path: submitPath,
            error: "",
            isRevalidating: false,
            submissionPath: submitPath
          )
        else:
          router.navState = NavigationState(
            kind: nskError,
            path: submitPath,
            error: "route action not found for path: " & submitPath,
            isRevalidating: false,
            submissionPath: submitPath
          )
      else:
        router.navState = NavigationState(
          kind: nskError,
          path: submitPath,
          error: "route not found for submit path: " & submitPath,
          isRevalidating: false,
          submissionPath: submitPath
        )
    else:
      router.navState = NavigationState(
        kind: nskError,
        path: normalized,
        error: "submit path is not navigable in router: " & router.pendingSubmissionPath,
        isRevalidating: false,
        submissionPath: router.pendingSubmissionPath
      )

  var best = findBestMatch(router, normalized)
  var currentLeaf: RouteDef = nil
  if best.matched and best.chain.len > 0:
    currentLeaf = best.chain[^1]

  if router.actionLoad != nil and router.actionLoad.token == router.actionLoadToken:
    let actionLoad = router.actionLoad
    let submissionPath = router.navState.submissionPath

    case actionLoad.state
    of rlsPending:
      router.navState = NavigationState(
        kind: nskSubmitting,
        path: normalized,
        error: "",
        isRevalidating: false,
        submissionPath: submissionPath
      )
    of rlsReady:
      router.actionLoad = nil
      router.revalidationRequested = true
      router.navState = NavigationState(
        kind: nskIdle,
        path: normalized,
        error: "",
        isRevalidating: true,
        submissionPath: ""
      )
    of rlsError:
      let msg = if actionLoad.error.len > 0: actionLoad.error else: "route action failed"
      router.actionLoad = nil
      router.revalidationRequested = false
      router.navState = NavigationState(
        kind: nskError,
        path: normalized,
        error: msg,
        isRevalidating: false,
        submissionPath: submissionPath
      )
      if currentLeaf != nil and currentLeaf.pendingBoundary != nil:
        return currentLeaf.pendingBoundary()
      return text("route action error: " & msg)
    of rlsRedirect:
      let redirectTo = if actionLoad.redirectTo.len > 0: actionLoad.redirectTo else: "/"
      let nav = normalizeNavigationInput(redirectTo)
      router.actionLoad = nil
      router.revalidationRequested = false
      if nav.ok:
        pushHistory(nav.path, actionLoad.replace)
        requestFlush(ulTransition)
        return text("")
      router.navState = NavigationState(
        kind: nskError,
        path: normalized,
        error: "invalid redirect target: " & redirectTo,
        isRevalidating: false,
        submissionPath: ""
      )
      return text("route action redirect error")

  if best.matched:
    router.currentParams = best.params

    if currentLeaf != nil and currentLeaf.loader != nil:
      let chainKey = routeChainKey(best.chain)
      let dataKey = routeDataKey(chainKey, best.params, router.currentQuery, router.currentQueryAll)
      router.currentDataKey = dataKey

      let hasCachedData = hasRouteData(router, dataKey)
      let hasInFlight = dataKey in router.routeLoads
      let shouldStartLoad =
        (not hasCachedData and not hasInFlight) or
        router.revalidationRequested

      if shouldStartLoad:
        discard startRouteLoad(router, dataKey, currentLeaf.loader, best.params)
        if router.revalidationRequested:
          router.revalidationRequested = false

      if dataKey in router.routeLoads:
        let load = router.routeLoads[dataKey]
        let expectedToken = router.routeLoadTokens.getOrDefault(dataKey, 0'i64)

        if load.token != 0 and load.token != expectedToken:
          clearRouteLoad(router, dataKey)
        else:
          case load.state
          of rlsPending:
            router.navState = NavigationState(
              kind: nskLoading,
              path: normalized,
              error: "",
              isRevalidating: hasCachedData or router.revalidationRequested,
              submissionPath: router.navState.submissionPath
            )
            if not hasCachedData:
              if currentLeaf.pendingBoundary != nil:
                return currentLeaf.pendingBoundary()
              return text("")

          of rlsReady:
            cacheRouteData(router, dataKey, load.data, normalized)
            clearRouteLoad(router, dataKey)
            router.revalidationRequested = false
            router.navState = NavigationState(
              kind: nskIdle,
              path: normalized,
              error: "",
              isRevalidating: false,
              submissionPath: ""
            )

          of rlsError:
            let msg = if load.error.len > 0: load.error else: "route loader failed"
            clearRouteLoad(router, dataKey)
            router.revalidationRequested = false
            router.navState = NavigationState(
              kind: nskError,
              path: normalized,
              error: msg,
              isRevalidating: false,
              submissionPath: ""
            )
            if currentLeaf.pendingBoundary != nil:
              return currentLeaf.pendingBoundary()
            return text("route loader error: " & msg)

          of rlsRedirect:
            let redirectTo = if load.redirectTo.len > 0: load.redirectTo else: "/"
            let nav = normalizeNavigationInput(redirectTo)
            clearRouteLoad(router, dataKey)
            router.revalidationRequested = false
            if nav.ok:
              pushHistory(nav.path, load.replace)
              requestFlush(ulTransition)
              return text("")
            router.navState = NavigationState(
              kind: nskError,
              path: normalized,
              error: "invalid redirect target: " & redirectTo,
              isRevalidating: false,
              submissionPath: ""
            )
            return text("route loader redirect error")
      elif router.revalidationRequested:
        router.revalidationRequested = false

    elif router.revalidationRequested:
      router.revalidationRequested = false

    routerStack.add router
    defer:
      if routerStack.len > 0:
        discard routerStack.pop()

    let rendered = renderChain(best.chain, best.params)
    if rendered != nil:
      return rendered

  if router.notFound != nil:
    return router.notFound()

  text("404")

proc Outlet*(): VNode =
  routerOutletNode()

proc prefetchRoute(router: Router, path: string) =
  if router == nil:
    return
  let nav = normalizeNavigationInput(path)
  if not nav.ok:
    return

  let (pathPart, queryPart) = splitPathAndQuery(nav.path)
  let normalized = normalizePath(pathPart)
  let parsedQuery = parseQueryTables(queryPart)
  let query = parsedQuery.single
  let queryAll = parsedQuery.all

  let best = findBestMatch(router, normalized)
  if not best.matched or best.chain.len == 0:
    return

  let leaf = best.chain[^1]
  if leaf == nil or leaf.loader == nil:
    return

  let dataKey = routeDataKey(routeChainKey(best.chain), best.params, query, queryAll)
  if hasRouteData(router, dataKey) or dataKey in router.routeLoads:
    return

  let load = startRouteLoad(router, dataKey, leaf.loader, best.params)
  if load == nil:
    clearRouteLoad(router, dataKey)
    return

  case load.state
  of rlsReady:
    cacheRouteData(router, dataKey, load.data, normalized)
    clearRouteLoad(router, dataKey)
  of rlsError, rlsRedirect:
    clearRouteLoad(router, dataKey)
  of rlsPending:
    discard

proc Link*(to: string, child: VNode, replace: bool = false, prefetch: bool = false, key: string = ""): VNode =
  let target = normalizeNavigationInput(to)
  let href = if target.ok: target.href else: to.strip()

  var events: seq[VEventBinding] = @[
    on(etClick, proc(ev: var UiEvent) =
      if not target.ok:
        return
      if ev.button != 0:
        return
      if ev.ctrlKey or ev.metaKey or ev.shiftKey or ev.altKey:
        return

      let targetAttr = eventExtra(ev, "currentTargetTarget", "").toLowerAscii()
      if targetAttr.len > 0 and targetAttr != "_self":
        return

      if eventExtra(ev, "currentTargetDownload", "").len > 0:
        return

      let relAttr = eventExtra(ev, "currentTargetRel", "").toLowerAscii()
      if relAttr.contains("external"):
        return

      if '#' in target.path:
        return

      preventDefault(ev)
      pushHistory(target.path, replace)
      requestFlush()
    )
  ]

  if prefetch and target.ok and '#' notin target.path:
    events.add on(etMouseEnter, proc(ev: var UiEvent) =
      if lastResolvedRouter != nil:
        prefetchRoute(lastResolvedRouter, target.path)
    )
    events.add on(etFocus, proc(ev: var UiEvent) =
      if lastResolvedRouter != nil:
        prefetchRoute(lastResolvedRouter, target.path)
    )

  element(
    "a",
    attrs = @[attr("href", href)],
    events = events,
    children = if child == nil: @[text(if href.len > 0: href else: "/")] else: @[child],
    key = key
  )

proc submit*(path: string, payload: string, replace: bool = false) =
  let router = activeRouter()
  if router == nil:
    return

  let nav = normalizeNavigationInput(path)
  if not nav.ok:
    return

  router.pendingSubmissionPath = nav.path
  router.pendingSubmissionPayload = payload
  router.pendingSubmissionReplace = replace
  router.pendingSubmission = true
  router.navState = NavigationState(
    kind: nskSubmitting,
    path: nav.path,
    error: "",
    isRevalidating: false,
    submissionPath: nav.path
  )

  pushHistory(nav.path, replace)
  requestFlush(ulTransition)

proc defaultFormOptions(): FormOptions =
  FormOptions(
    replace: false,
    `method`: "post",
    enctype: "application/x-www-form-urlencoded",
    serialize: nil
  )

proc Form*(
  action: string,
  child: VNode,
  opts: FormOptions = FormOptions(
    replace: false,
    `method`: "post",
    enctype: "application/x-www-form-urlencoded",
    serialize: nil
  ),
  key: string = ""
): VNode =
  let target = normalizeNavigationInput(action)
  let actionHref =
    if target.ok:
      target.href
    else:
      action.strip()
  let methodValue = block:
    let trimmed = opts.`method`.strip()
    if trimmed.len == 0:
      "post"
    else:
      trimmed.toLowerAscii()
  let enctypeValue = block:
    let trimmed = opts.enctype.strip()
    if trimmed.len == 0:
      "application/x-www-form-urlencoded"
    else:
      trimmed

  element(
    "form",
    attrs = @[
      attr("action", actionHref),
      attr("method", methodValue),
      attr("enctype", enctypeValue)
    ],
    events = @[
      on(etSubmit, proc(ev: var UiEvent) =
        if not target.ok:
          return
        preventDefault(ev)
        let payload =
          if opts.serialize != nil:
            opts.serialize(ev)
          else:
            eventExtra(ev, "formPayload", "")
        submit(target.path, payload, opts.replace)
      )
    ],
    children = if child == nil: @[] else: @[child],
    key = key
  )

proc Form*(action: string, child: VNode, replace: bool = false, key: string = ""): VNode =
  var opts = defaultFormOptions()
  opts.replace = replace
  Form(action, child, opts, key)

proc useNavigate*(): proc(path: string, opts: NavigateOptions = NavigateOptions()) {.closure.} =
  proc nav(path: string, opts: NavigateOptions = NavigateOptions()) =
    let target = normalizeNavigationInput(path)
    if not target.ok:
      return
    pushHistory(target.path, opts.replace)
    requestFlush()
  nav

proc useSubmit*(): proc(path: string, payload: string, replace: bool = false) {.closure.} =
  proc submitProc(path: string, payload: string, replace: bool = false) =
    submit(path, payload, replace)
  submitProc

proc useRoute*(): tuple[path: string, params: RouteParams, query: Table[string, string], queryAll: QueryParamsAll] =
  if routerStack.len == 0:
    if lastResolvedRouter != nil:
      return (
        path: lastResolvedRouter.currentPath,
        params: copyParams(lastResolvedRouter.currentParams),
        query: copyQuery(lastResolvedRouter.currentQuery),
        queryAll: copyQueryAll(lastResolvedRouter.currentQueryAll)
      )
    return (
      path: "/",
      params: initTable[string, string](),
      query: initTable[string, string](),
      queryAll: initTable[string, seq[string]]()
    )

  let router = routerStack[^1]
  (
    path: router.currentPath,
    params: copyParams(router.currentParams),
    query: copyQuery(router.currentQuery),
    queryAll: copyQueryAll(router.currentQueryAll)
  )

proc useRouteData*[T](): T =
  let router = activeRouter()

  if router == nil or router.currentDataKey.len == 0:
    raise newException(ValueError, "useRouteData called outside a matched route loader context")
  if not hasRouteData(router, router.currentDataKey):
    raise newException(ValueError, "route data not available for key: " & router.currentDataKey)

  let raw = readRouteData(router, router.currentDataKey)
  when T is ref RootObj:
    if raw == nil:
      return nil
    if raw of T:
      return T(raw)
    raise newException(ValueError, "route data type mismatch for key: " & router.currentDataKey)
  else:
    if raw == nil:
      raise newException(ValueError, "route data is nil for key: " & router.currentDataKey)
    if raw of RouteDataBox[T]:
      return RouteDataBox[T](raw).value
    raise newException(ValueError, "route data type mismatch for key: " & router.currentDataKey)

proc useNavigationState*(): NavigationState =
  let router = activeRouter()
  if router == nil:
    return NavigationState(
      kind: nskIdle,
      path: "/",
      error: "",
      isRevalidating: false,
      submissionPath: ""
    )
  router.navState

proc requestRevalidate*(router: Router) =
  if router == nil:
    return
  router.revalidationRequested = true
  requestFlush(ulTransition)

proc invalidateRouteData*(router: Router, pathPrefix = "", includeChildren = true) =
  if router == nil:
    return

  var keysToDelete: seq[string] = @[]

  if pathPrefix.len == 0:
    for key in router.routeData.keys:
      keysToDelete.add key
  else:
    let prefix = normalizePath(pathPrefix)
    for key, path in router.routeDataPath:
      let normalizedPath = normalizePath(path)
      let isExact = normalizedPath == prefix
      let isChild = prefix == "/" or normalizedPath.startsWith(prefix & "/")
      if isExact or (includeChildren and isChild):
        keysToDelete.add key

  for key in keysToDelete:
    deleteRouteDataKey(router, key)

  requestRevalidate(router)

proc useRevalidator*(): tuple[
  isRevalidating: bool,
  revalidate: proc() {.closure.}
] =
  let router = activeRouter()
  let revalidating =
    router != nil and
    (router.navState.isRevalidating or router.revalidationRequested)

  let revalidateProc = proc() =
    requestRevalidate(router)

  (revalidating, revalidateProc)
