## CPS I/O DNS
##
## Provides async DNS resolution using the DNS wire protocol (RFC 1035)
## over async UDP, driven entirely by the CPS event loop with zero threads.
##
## Features:
##   - Non-blocking: DNS queries use async UDP via the event loop
##   - Caching: results are cached with configurable TTL
##   - /etc/hosts: checks hosts file before sending DNS queries
##   - /etc/resolv.conf: reads system nameservers (falls back to 8.8.8.8)
##   - IPv4/IPv6: supports both address families
##   - CNAME following: follows CNAME chains up to 8 levels deep
##   - Concurrent queries: multiple in-flight queries via transaction ID table

import std/[nativesockets, net, os, posix, tables, times, strutils, atomics]
import ../runtime
import ../eventloop
import ./streams
import ./udp

# ============================================================
# Types
# ============================================================

type
  DnsError* = object of streams.AsyncIoError
    ## Error during DNS resolution.

  DnsCacheEntry = object
    addresses: seq[string]
    expireTime: float  ## epochTime + TTL
    family: Domain

  DnsCache* = ref object
    ## DNS cache with TTL-based expiry.
    entries: Table[string, DnsCacheEntry]
    ttlSeconds: int

  Nameserver = object
    address: string
    family: Domain

  DnsRR = object
    name: string
    rrtype: uint16
    rrclass: uint16
    ttl: uint32
    rdata: string

  DnsResponse = object
    id: uint16
    flags: uint16
    questions: int
    answers: seq[DnsRR]
    rcode: uint8
    truncated: bool

# ============================================================
# XorShift32 PRNG (avoids std/random — OpenSSL conflict on macOS)
# ============================================================

type XorShift32 = object
  state: uint32

proc initXorShift32(seed: int): XorShift32 =
  result.state = uint32(seed)
  if result.state == 0: result.state = 1  # must be non-zero

proc next(rng: var XorShift32): uint32 =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)
  rng.state = x
  result = x

var gRng: XorShift32

proc initRng() =
  let seed = int(epochTime() * 1e9) xor getpid()
  gRng = initXorShift32(seed)

proc nextTxId(): uint16 =
  result = uint16(gRng.next() and 0xFFFF'u32)

# ============================================================
# DNS wire format constants
# ============================================================

const
  DnsHeaderSize = 12
  TypeA: uint16 = 1
  TypeAAAA: uint16 = 28
  TypeCNAME: uint16 = 5
  ClassIN: uint16 = 1
  FlagRD: uint16 = 0x0100  # Recursion Desired
  FlagTC: uint16 = 0x0200  # Truncated
  RcodeMask: uint16 = 0x000F
  MaxUdpSize = 512
  MaxRetries = 3
  BaseTimeoutMs = 2000  # 2s, then 4s, then 8s
  MaxCnameDepth = 8

# ============================================================
# DNS message encoder
# ============================================================

proc encodeName(name: string): string =
  ## Encode a domain name in DNS wire format (label-length-prefixed).
  result = ""
  for label in name.split('.'):
    if label.len > 63:
      raise newException(DnsError, "DNS label too long: " & label)
    result.add(char(label.len))
    result.add(label)
  result.add('\0')

proc buildQuery(name: string, qtype: uint16, txId: uint16): string =
  ## Build a complete DNS query packet.
  result = newString(DnsHeaderSize)
  # Transaction ID
  result[0] = char((txId shr 8) and 0xFF)
  result[1] = char(txId and 0xFF)
  # Flags: RD=1
  let flags = FlagRD
  result[2] = char((flags shr 8) and 0xFF)
  result[3] = char(flags and 0xFF)
  # QDCOUNT = 1
  result[4] = '\0'
  result[5] = char(1)
  # ANCOUNT, NSCOUNT, ARCOUNT = 0
  result[6] = '\0'; result[7] = '\0'
  result[8] = '\0'; result[9] = '\0'
  result[10] = '\0'; result[11] = '\0'
  # Question section
  result.add(encodeName(name))
  # QTYPE
  result.add(char((qtype shr 8) and 0xFF))
  result.add(char(qtype and 0xFF))
  # QCLASS = IN
  result.add(char((ClassIN shr 8) and 0xFF))
  result.add(char(ClassIN and 0xFF))

# ============================================================
# DNS message decoder
# ============================================================

proc decodeName(data: string, offset: int): tuple[name: string, newOffset: int] =
  ## Decode a DNS name from wire format with compression pointer support.
  var parts: seq[string]
  var pos = offset
  var jumped = false
  var savedPos = -1
  var jumps = 0

  while pos < data.len:
    let length = int(data[pos].uint8)
    if length == 0:
      pos += 1
      break
    elif (length and 0xC0) == 0xC0:
      # Compression pointer
      if pos + 1 >= data.len:
        raise newException(DnsError, "Invalid DNS compression pointer")
      if not jumped:
        savedPos = pos + 2
      jumped = true
      pos = ((length and 0x3F) shl 8) or int(data[pos + 1].uint8)
      jumps += 1
      if jumps > 10:
        raise newException(DnsError, "DNS compression loop detected")
    else:
      pos += 1
      if pos + length > data.len:
        raise newException(DnsError, "DNS name extends past packet")
      parts.add(data[pos ..< pos + length])
      pos += length

  let finalPos = if jumped: savedPos else: pos
  result = (name: parts.join("."), newOffset: finalPos)

proc parseIpv4(rdata: string): string =
  ## Convert 4-byte rdata to dotted decimal.
  if rdata.len != 4:
    raise newException(DnsError, "Invalid A record length: " & $rdata.len)
  result = $rdata[0].uint8 & "." & $rdata[1].uint8 & "." & $rdata[2].uint8 & "." & $rdata[3].uint8

proc parseIpv6(rdata: string): string =
  ## Convert 16-byte rdata to IPv6 string via inet_ntop.
  if rdata.len != 16:
    raise newException(DnsError, "Invalid AAAA record length: " & $rdata.len)
  var buf: array[46, char]  # INET6_ADDRSTRLEN
  let p = inet_ntop(AF_INET6.cint, cast[pointer](unsafeAddr rdata[0]), cast[cstring](addr buf[0]), 46.int32)
  if p == nil:
    raise newException(DnsError, "inet_ntop failed for IPv6 address")
  result = $cast[cstring](addr buf[0])

proc parseResponse(data: string): DnsResponse =
  ## Parse a DNS response packet.
  if data.len < DnsHeaderSize:
    raise newException(DnsError, "DNS response too short")

  result.id = (uint16(data[0].uint8) shl 8) or uint16(data[1].uint8)
  result.flags = (uint16(data[2].uint8) shl 8) or uint16(data[3].uint8)
  result.rcode = uint8(result.flags and RcodeMask)
  result.truncated = (result.flags and FlagTC) != 0
  result.questions = int((uint16(data[4].uint8) shl 8) or uint16(data[5].uint8))
  let ancount = int((uint16(data[6].uint8) shl 8) or uint16(data[7].uint8))

  # Skip question section
  var pos = DnsHeaderSize
  for i in 0 ..< result.questions:
    let (_, newPos) = decodeName(data, pos)
    pos = newPos + 4  # skip QTYPE + QCLASS

  # Parse answer RRs
  result.answers = @[]
  for i in 0 ..< ancount:
    if pos >= data.len:
      break
    let (rrName, nameEnd) = decodeName(data, pos)
    pos = nameEnd
    if pos + 10 > data.len:
      break

    let rrtype = (uint16(data[pos].uint8) shl 8) or uint16(data[pos + 1].uint8)
    let rrclass = (uint16(data[pos + 2].uint8) shl 8) or uint16(data[pos + 3].uint8)
    let ttl = (uint32(data[pos + 4].uint8) shl 24) or (uint32(data[pos + 5].uint8) shl 16) or
              (uint32(data[pos + 6].uint8) shl 8) or uint32(data[pos + 7].uint8)
    let rdlength = int((uint16(data[pos + 8].uint8) shl 8) or uint16(data[pos + 9].uint8))
    pos += 10

    if pos + rdlength > data.len:
      break

    var rdata: string
    if rrtype == TypeCNAME:
      let (cname, _) = decodeName(data, pos)
      rdata = cname
    else:
      rdata = data[pos ..< pos + rdlength]

    result.answers.add(DnsRR(
      name: rrName, rrtype: rrtype, rrclass: rrclass, ttl: ttl, rdata: rdata
    ))
    pos += rdlength

# ============================================================
# /etc/hosts lookup
# ============================================================

proc checkHostsFile(host: string, family: Domain): seq[string] =
  ## Check /etc/hosts for the given hostname.
  result = @[]
  let path = "/etc/hosts"
  if not fileExists(path):
    return
  try:
    let content = readFile(path)
    for line in content.splitLines():
      let stripped = line.strip()
      if stripped.len == 0 or stripped[0] == '#':
        continue
      let parts = stripped.splitWhitespace()
      if parts.len < 2:
        continue
      let ip = parts[0]
      for i in 1 ..< parts.len:
        if parts[i].toLowerAscii() == host.toLowerAscii():
          # Check IP matches requested family
          if family == AF_INET and ':' notin ip:
            if ip notin result:
              result.add(ip)
          elif family == AF_INET6 and ':' in ip:
            if ip notin result:
              result.add(ip)
          break
  except CatchableError:
    discard

# ============================================================
# /etc/resolv.conf parser
# ============================================================

var gNameservers: seq[Nameserver]
var gNameserversInitialized = false

proc parseResolvConf(): seq[Nameserver] =
  ## Parse /etc/resolv.conf for nameserver entries.
  result = @[]
  let path = "/etc/resolv.conf"
  if not fileExists(path):
    return
  try:
    let content = readFile(path)
    for line in content.splitLines():
      let stripped = line.strip()
      if stripped.startsWith("nameserver"):
        let parts = stripped.splitWhitespace()
        if parts.len >= 2:
          let nsAddr = parts[1]
          let fam = if ':' in nsAddr: AF_INET6 else: AF_INET
          result.add(Nameserver(address: nsAddr, family: fam))
  except CatchableError:
    discard

proc getNameservers(): seq[Nameserver] =
  if not gNameserversInitialized:
    gNameservers = parseResolvConf()
    if gNameservers.len == 0:
      gNameservers = @[
        Nameserver(address: "8.8.8.8", family: AF_INET),
        Nameserver(address: "8.8.4.4", family: AF_INET)
      ]
    gNameserversInitialized = true
  result = gNameservers

# ============================================================
# Globals
# ============================================================

var gDnsCache: DnsCache = nil
var gRngInitialized = false

# UDP socket for DNS queries (lazily created via UdpSocket API)
var gDnsSock: UdpSocket = nil

# Pending queries table: txId -> future
var gPendingQueries: Table[uint16, CpsFuture[DnsResponse]]

# ============================================================
# DNS Cache
# ============================================================

proc initDnsCache*(ttlSeconds: int = 300): DnsCache =
  ## Create a new DNS cache with the given TTL (default 5 minutes).
  result = DnsCache(
    entries: initTable[string, DnsCacheEntry](),
    ttlSeconds: ttlSeconds
  )

proc getDnsCache*(): DnsCache =
  ## Get the global DNS cache, creating one if needed.
  if gDnsCache.isNil:
    gDnsCache = initDnsCache()
  result = gDnsCache

proc clearDnsCache*() =
  ## Clear all entries from the global DNS cache.
  if not gDnsCache.isNil:
    gDnsCache.entries.clear()

proc setDnsCacheTtl*(ttlSeconds: int) =
  ## Set the TTL for the global DNS cache.
  let cache = getDnsCache()
  cache.ttlSeconds = ttlSeconds

proc cacheKey(host: string, family: Domain): string =
  result = host & ":" & $family.int

proc cacheLookup(cache: DnsCache, host: string, family: Domain): seq[string] =
  ## Look up a host in the cache. Returns empty seq on miss or expiry.
  let key = cacheKey(host, family)
  if key in cache.entries:
    let entry = cache.entries[key]
    if epochTime() < entry.expireTime:
      return entry.addresses
    else:
      cache.entries.del(key)
  result = @[]

proc cacheStore(cache: DnsCache, host: string, family: Domain, addresses: seq[string]) =
  ## Store resolved addresses in the cache.
  let key = cacheKey(host, family)
  cache.entries[key] = DnsCacheEntry(
    addresses: addresses,
    expireTime: epochTime() + float(cache.ttlSeconds),
    family: family
  )

# ============================================================
# IP address detection
# ============================================================

proc isIpAddress*(host: string): bool =
  ## Check if the string is already an IP address (v4 or v6).
  if host.len == 0:
    return false
  # IPv6: contains colons
  if ':' in host:
    return true
  # IPv4: all chars are digits or dots, at least one dot
  var hasDot = false
  for c in host:
    if c == '.':
      hasDot = true
    elif c < '0' or c > '9':
      return false
  return hasDot

# ============================================================
# Deprecated stubs (no-op for backward compatibility)
# ============================================================

proc initDnsResolver*(numThreads: int = 2) {.deprecated: "DNS resolver no longer needs initialization".} =
  ## No-op. Kept for backward compatibility.
  discard

proc deinitDnsResolver*() {.deprecated: "DNS resolver no longer needs deinitialization".} =
  ## No-op. Kept for backward compatibility.
  discard

# ============================================================
# UDP socket setup and dispatch (uses UdpSocket API from udp.nim)
# ============================================================

proc ensureDnsReady() =
  ## Create the DNS UDP socket and register the persistent read callback.
  if gDnsSock != nil:
    return

  if not gRngInitialized:
    initRng()
    gRngInitialized = true

  gDnsSock = newUdpSocket(AF_INET)
  gPendingQueries = initTable[uint16, CpsFuture[DnsResponse]]()

  gDnsSock.onRecv(MaxUdpSize + 512, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    try:
      let resp = parseResponse(data)
      if resp.id in gPendingQueries:
        let fut = gPendingQueries[resp.id]
        gPendingQueries.del(resp.id)
        fut.complete(resp)
    except CatchableError:
      # Malformed response — ignore
      discard
  )

# ============================================================
# Send DNS query via UdpSocket
# ============================================================

proc sendDnsQueryRaw(query: string, ns: Nameserver) =
  ## Send a DNS query packet to a nameserver.
  ## Non-blocking; drops silently on EAGAIN (will retry on timeout).
  ensureDnsReady()
  try:
    discard gDnsSock.trySendToAddr(query, ns.address, 53, ns.family)
  except streams.AsyncIoError:
    discard

# ============================================================
# Async query engine
# ============================================================

proc queryNameserver(name: string, qtype: uint16, ns: Nameserver, timeoutMs: int): CpsFuture[DnsResponse] =
  ## Send a query to a single nameserver and wait for a response with timeout.
  let txId = nextTxId()
  let query = buildQuery(name, qtype, txId)
  let responseFut = newCpsFuture[DnsResponse]()
  responseFut.pinFutureRuntime()

  ensureDnsReady()

  gPendingQueries[txId] = responseFut

  sendDnsQueryRaw(query, ns)

  # Set up timeout
  let loop = getEventLoop()
  let resultFut = newCpsFuture[DnsResponse]()
  resultFut.pinFutureRuntime()
  var resolved: Atomic[bool]
  resolved.store(false, moRelaxed)
  var timerHandle: TimerHandle

  proc makeTimerCb(tid: uint16, rf: CpsFuture[DnsResponse]): proc() {.closure.} =
    result = proc() =
      var expected = false
      if resolved.compareExchange(expected, true):
        # Clean up pending entry
        if tid in gPendingQueries:
          gPendingQueries.del(tid)
        rf.fail(newException(DnsError, "DNS query timed out"))

  proc makeRespCb(inner: CpsFuture[DnsResponse], rf: CpsFuture[DnsResponse],
                  timer: TimerHandle): proc() {.closure.} =
    result = proc() =
      var expected = false
      if resolved.compareExchange(expected, true):
        timer.cancel()
        if inner.hasError():
          rf.fail(inner.getError())
        else:
          rf.complete(inner.read())

  timerHandle = loop.registerTimer(timeoutMs, makeTimerCb(txId, resultFut))
  responseFut.addCallback(makeRespCb(responseFut, resultFut, timerHandle))

  result = resultFut

proc dnsQuery(name: string, qtype: uint16): CpsFuture[DnsResponse] =
  ## Query DNS with retry across nameservers and exponential backoff.
  let nameservers = getNameservers()
  let outerFut = newCpsFuture[DnsResponse]()
  outerFut.pinFutureRuntime()
  var attempt = 0
  let totalAttempts = MaxRetries * nameservers.len

  proc tryNext()

  proc tryNext() =
    if attempt >= totalAttempts:
      outerFut.fail(newException(DnsError, "DNS resolution failed for '" & name & "': all nameservers timed out"))
      return

    let nsIdx = attempt mod nameservers.len
    let retryNum = attempt div nameservers.len
    let timeoutMs = BaseTimeoutMs * (1 shl retryNum)  # 2s, 4s, 8s
    attempt += 1

    let queryFut = queryNameserver(name, qtype, nameservers[nsIdx], timeoutMs)

    proc makeQueryCb(qf: CpsFuture[DnsResponse], of2: CpsFuture[DnsResponse]): proc() {.closure.} =
      result = proc() =
        if qf.hasError():
          # Timeout or error — try next
          tryNext()
        else:
          let resp = qf.read()
          if resp.rcode == 0 or resp.rcode == 3:
            # Success or NXDOMAIN — return the response
            of2.complete(resp)
          else:
            # Server error — try next
            tryNext()

    queryFut.addCallback(makeQueryCb(queryFut, outerFut))

  tryNext()
  result = outerFut

# ============================================================
# CNAME resolution
# ============================================================

proc resolveWithCname(name: string, qtype: uint16, depth: int): CpsFuture[seq[string]] =
  ## Resolve a name, following CNAME chains up to MaxCnameDepth.
  let fut = newCpsFuture[seq[string]]()
  fut.pinFutureRuntime()

  if depth > MaxCnameDepth:
    fut.fail(newException(DnsError, "CNAME chain too deep for '" & name & "'"))
    return fut

  let queryFut = dnsQuery(name, qtype)

  proc makeQueryCb(qf: CpsFuture[DnsResponse], rf: CpsFuture[seq[string]],
                   nm: string, qt: uint16, dep: int): proc() {.closure.} =
    result = proc() =
      if qf.hasError():
        rf.fail(qf.getError())
        return

      let resp = qf.read()

      # Check for NXDOMAIN
      if resp.rcode == 3:
        rf.fail(newException(DnsError, "DNS resolution failed for '" & nm & "': NXDOMAIN"))
        return

      # Extract matching records
      var addresses: seq[string]
      var cname: string = ""
      for rr in resp.answers:
        if rr.rrtype == qt and rr.rrclass == ClassIN:
          try:
            if qt == TypeA:
              addresses.add(parseIpv4(rr.rdata))
            elif qt == TypeAAAA:
              addresses.add(parseIpv6(rr.rdata))
          except CatchableError:
            discard
        elif rr.rrtype == TypeCNAME and rr.rrclass == ClassIN:
          cname = rr.rdata

      if addresses.len > 0:
        rf.complete(addresses)
      elif cname.len > 0:
        # Follow CNAME
        let innerFut = resolveWithCname(cname, qt, dep + 1)
        proc makeCnameCb(inf: CpsFuture[seq[string]], rf2: CpsFuture[seq[string]]): proc() {.closure.} =
          result = proc() =
            if inf.hasError():
              rf2.fail(inf.getError())
            else:
              rf2.complete(inf.read())
        innerFut.addCallback(makeCnameCb(innerFut, rf))
      else:
        rf.fail(newException(DnsError, "DNS resolution returned no usable addresses for '" & nm & "'"))

  queryFut.addCallback(makeQueryCb(queryFut, fut, name, qtype, depth))
  result = fut

# ============================================================
# Async DNS resolution
# ============================================================

proc asyncResolve*(host: string, port: Port = Port(0),
                   family: Domain = AF_INET): CpsFuture[seq[string]] =
  ## Resolve a hostname asynchronously without caching.
  ## Returns a future with a list of IP addresses.
  let fut = newCpsFuture[seq[string]]()
  fut.pinFutureRuntime()

  # Short-circuit for IP addresses
  if isIpAddress(host):
    fut.complete(@[host])
    return fut

  # Check /etc/hosts first
  let hostsResult = checkHostsFile(host, family)
  if hostsResult.len > 0:
    fut.complete(hostsResult)
    return fut

  # Determine query type
  let qtype = if family == AF_INET6: TypeAAAA else: TypeA

  let innerFut = resolveWithCname(host, qtype, 0)

  proc makeCb(inf: CpsFuture[seq[string]], rf: CpsFuture[seq[string]]): proc() {.closure.} =
    result = proc() =
      if inf.hasError():
        rf.fail(inf.getError())
      else:
        rf.complete(inf.read())

  innerFut.addCallback(makeCb(innerFut, fut))
  result = fut

proc resolve*(host: string, port: Port = Port(0),
              family: Domain = AF_INET): CpsFuture[seq[string]] =
  ## Resolve a hostname asynchronously with caching.
  ## Returns cached results if available and not expired.
  ## Otherwise performs async resolution and caches the result.
  let fut = newCpsFuture[seq[string]]()
  fut.pinFutureRuntime()

  # Short-circuit for IP addresses (no caching needed)
  if isIpAddress(host):
    fut.complete(@[host])
    return fut

  # Check cache
  let cache = getDnsCache()
  let cached = cacheLookup(cache, host, family)
  if cached.len > 0:
    fut.complete(cached)
    return fut

  # Cache miss - do async resolve
  let innerFut = asyncResolve(host, port, family)

  proc makeCb(inf: CpsFuture[seq[string]], rf: CpsFuture[seq[string]],
              c: DnsCache, h: string, f: Domain): proc() {.closure.} =
    result = proc() =
      if inf.hasError():
        rf.fail(inf.getError())
      else:
        let addrs = inf.read()
        cacheStore(c, h, f, addrs)
        rf.complete(addrs)

  innerFut.addCallback(makeCb(innerFut, fut, cache, host, family))
  result = fut
