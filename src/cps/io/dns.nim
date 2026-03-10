## CPS I/O DNS
##
## Async DNS resolution using DNS wire protocol (RFC 1035) over UDP,
## driven by the CPS event loop.
##
## Features:
##   - Non-blocking: async UDP via event loop
##   - Caching: TTL-based with configurable duration
##   - /etc/hosts: parsed once into table for O(1) lookup
##   - /etc/resolv.conf: system nameservers (falls back to 8.8.8.8)
##   - IPv4/IPv6: both address families
##   - CNAME following: chains up to 8 deep with cycle detection
##   - Concurrent queries: multiplexed via transaction ID

import std/[nativesockets, os, tables, times, strutils]
import std/net except TimeoutError
import ../runtime
import ../transform
import ../eventloop
import ../private/platform
import ../private/xorshift
import ./streams
import ./udp
import ./timeouts

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
# Constants
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
# Globals
# ============================================================

# Reactor-thread only (accessed via scheduleCallback):
var gRng: XorShift32
var gDnsSock: UdpSocket
var gDnsSock6: UdpSocket
var gPendingQueries: Table[uint16, CpsFuture[DnsResponse]]
var gSocketsReady = false

# Lazy-loaded (read-mostly after init, benign races in MT):
var gNameservers: seq[Nameserver]
var gNameserversLoaded = false
var gHostsEntries: Table[string, seq[string]]
var gHostsLoaded = false
var gDnsCache: DnsCache

# ============================================================
# DNS wire format encoder
# ============================================================

proc encodeName(name: string): string =
  ## Encode a domain name in DNS wire format (label-length-prefixed).
  result = newStringOfCap(name.len + 2)
  for label in name.split('.'):
    if label.len > 63:
      raise newException(DnsError, "DNS label too long: " & label)
    result.add(char(label.len))
    result.add(label)
  result.add('\0')

proc buildQuery(name: string, qtype: uint16, txId: uint16): string =
  ## Build a complete DNS query packet (single allocation).
  let encoded = encodeName(name)
  result = newString(DnsHeaderSize + encoded.len + 4)
  # Transaction ID
  result[0] = char((txId shr 8) and 0xFF)
  result[1] = char(txId and 0xFF)
  # Flags: RD=1
  result[2] = char((FlagRD shr 8) and 0xFF)
  result[3] = char(FlagRD and 0xFF)
  # QDCOUNT = 1, ANCOUNT/NSCOUNT/ARCOUNT = 0
  result[4] = '\0'; result[5] = char(1)
  for i in 6 .. 11: result[i] = '\0'
  # Question section: encoded name + QTYPE + QCLASS
  copyMem(addr result[DnsHeaderSize], unsafeAddr encoded[0], encoded.len)
  let off = DnsHeaderSize + encoded.len
  result[off] = char((qtype shr 8) and 0xFF)
  result[off + 1] = char(qtype and 0xFF)
  result[off + 2] = char((ClassIN shr 8) and 0xFF)
  result[off + 3] = char(ClassIN and 0xFF)

# ============================================================
# DNS wire format decoder
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

  (name: parts.join("."), newOffset: if jumped: savedPos else: pos)

proc parseIpv4(rdata: string): string =
  ## Convert 4-byte rdata to dotted decimal (single allocation).
  if rdata.len != 4:
    raise newException(DnsError, "Invalid A record: " & $rdata.len & " bytes")
  result = newStringOfCap(15)
  result.add($rdata[0].uint8)
  result.add('.')
  result.add($rdata[1].uint8)
  result.add('.')
  result.add($rdata[2].uint8)
  result.add('.')
  result.add($rdata[3].uint8)

proc parseIpv6(rdata: string): string =
  ## Convert 16-byte rdata to IPv6 string via inet_ntop.
  if rdata.len != 16:
    raise newException(DnsError, "Invalid AAAA record: " & $rdata.len & " bytes")
  var buf: array[46, char]  # INET6_ADDRSTRLEN
  let p = inet_ntop(AF_INET6.cint, cast[pointer](unsafeAddr rdata[0]),
                     cast[cstring](addr buf[0]), 46.int32)
  if p == nil:
    raise newException(DnsError, "inet_ntop failed for IPv6")
  $cast[cstring](addr buf[0])

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
    if pos >= data.len: break
    let (rrName, nameEnd) = decodeName(data, pos)
    pos = nameEnd
    if pos + 10 > data.len: break

    let rrtype = (uint16(data[pos].uint8) shl 8) or uint16(data[pos + 1].uint8)
    let rrclass = (uint16(data[pos + 2].uint8) shl 8) or uint16(data[pos + 3].uint8)
    let ttl = (uint32(data[pos + 4].uint8) shl 24) or (uint32(data[pos + 5].uint8) shl 16) or
              (uint32(data[pos + 6].uint8) shl 8) or uint32(data[pos + 7].uint8)
    let rdlength = int((uint16(data[pos + 8].uint8) shl 8) or uint16(data[pos + 9].uint8))
    pos += 10
    if pos + rdlength > data.len: break

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
# /etc/hosts (parsed once into table for O(1) lookup)
# ============================================================

proc loadHostsFile() =
  gHostsEntries = initTable[string, seq[string]]()
  gHostsLoaded = true
  let path = platform.hostsFilePath()
  if not fileExists(path): return
  try:
    for line in readFile(path).splitLines():
      let stripped = line.strip()
      if stripped.len == 0 or stripped[0] == '#': continue
      let parts = stripped.splitWhitespace()
      if parts.len < 2: continue
      let ip = parts[0]
      let familyInt = if ':' in ip: AF_INET6.int else: AF_INET.int
      for i in 1 ..< parts.len:
        let key = parts[i].toLowerAscii() & ":" & $familyInt
        if key notin gHostsEntries:
          gHostsEntries[key] = @[ip]
        elif ip notin gHostsEntries[key]:
          gHostsEntries[key].add(ip)
  except CatchableError:
    discard

proc checkHostsFile(host: string, family: Domain): seq[string] =
  ## Look up a host in the cached /etc/hosts table.
  if not gHostsLoaded:
    loadHostsFile()
  let key = host.toLowerAscii() & ":" & $family.int
  gHostsEntries.getOrDefault(key)

# ============================================================
# /etc/resolv.conf
# ============================================================

proc loadNameservers() =
  gNameservers = @[]
  let path = platform.resolvConfPath()
  if path.len > 0 and fileExists(path):
    try:
      for line in readFile(path).splitLines():
        let stripped = line.strip()
        if stripped.startsWith("nameserver"):
          let parts = stripped.splitWhitespace()
          if parts.len >= 2:
            let nsAddr = parts[1]
            gNameservers.add(Nameserver(
              address: nsAddr,
              family: if ':' in nsAddr: AF_INET6 else: AF_INET
            ))
    except CatchableError:
      discard

  # Append public DNS fallbacks (deduplicated)
  let fallbacks = [
    Nameserver(address: "8.8.8.8", family: AF_INET),
    Nameserver(address: "8.8.4.4", family: AF_INET),
    Nameserver(address: "2001:4860:4860::8888", family: AF_INET6),
    Nameserver(address: "2001:4860:4860::8844", family: AF_INET6)
  ]
  for fb in fallbacks:
    var found = false
    for ns in gNameservers:
      if ns.address == fb.address:
        found = true
        break
    if not found:
      gNameservers.add(fb)

proc getNameservers(): seq[Nameserver] =
  if not gNameserversLoaded:
    loadNameservers()
    gNameserversLoaded = true
  gNameservers

# ============================================================
# DNS Cache
# ============================================================

proc initDnsCache*(ttlSeconds: int = 300): DnsCache =
  ## Create a new DNS cache with the given TTL (default 5 minutes).
  DnsCache(entries: initTable[string, DnsCacheEntry](), ttlSeconds: ttlSeconds)

proc getDnsCache*(): DnsCache =
  ## Get the global DNS cache, creating one if needed.
  if gDnsCache.isNil:
    gDnsCache = initDnsCache()
  gDnsCache

proc clearDnsCache*() =
  ## Clear all entries from the global DNS cache.
  if not gDnsCache.isNil:
    gDnsCache.entries.clear()

proc setDnsCacheTtl*(ttlSeconds: int) =
  ## Set the TTL for the global DNS cache.
  getDnsCache().ttlSeconds = ttlSeconds

proc cacheKey(host: string, family: Domain): string =
  host & ":" & $family.int

proc cacheLookup(cache: DnsCache, host: string, family: Domain): seq[string] =
  ## Look up a host in the cache. Returns empty seq on miss or expiry.
  let key = cacheKey(host, family)
  if key in cache.entries:
    let entry = cache.entries[key]
    if epochTime() < entry.expireTime:
      return entry.addresses
    cache.entries.del(key)
  @[]

proc cacheStore(cache: DnsCache, host: string, family: Domain, addresses: seq[string]) =
  ## Store resolved addresses in the cache.
  cache.entries[cacheKey(host, family)] = DnsCacheEntry(
    addresses: addresses,
    expireTime: epochTime() + float(cache.ttlSeconds),
    family: family
  )

# ============================================================
# IP address detection
# ============================================================

proc isIpAddress*(host: string): bool =
  ## Check if the string is already an IP address (v4 or v6).
  if host.len == 0: return false
  if ':' in host: return true
  var hasDot = false
  for c in host:
    if c == '.': hasDot = true
    elif c < '0' or c > '9': return false
  hasDot

# ============================================================
# Initialization & cleanup
# ============================================================

proc dnsRecvHandler(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
  ## Shared receive handler for both IPv4 and IPv6 DNS sockets.
  ## Dispatches responses to pending futures by transaction ID.
  try:
    let resp = parseResponse(data)
    if resp.id in gPendingQueries:
      let fut = gPendingQueries[resp.id]
      gPendingQueries.del(resp.id)
      fut.complete(resp)
  except CatchableError:
    discard

proc ensureDnsReady() =
  ## Initialize DNS UDP sockets and PRNG. Must be called from reactor thread.
  if gSocketsReady: return
  gSocketsReady = true

  gRng = initXorShift32(int(epochTime() * 1e9) xor platform.getProcessId())
  gPendingQueries = initTable[uint16, CpsFuture[DnsResponse]]()

  gDnsSock = newUdpSocket(AF_INET)
  gDnsSock.bindAddr("0.0.0.0", 0)
  gDnsSock.onRecv(MaxUdpSize + 512, dnsRecvHandler)

  # Try IPv6 socket; skip if no IPv6 stack
  try:
    gDnsSock6 = newUdpSocket(AF_INET6)
    gDnsSock6.bindAddr("::", 0)
    gDnsSock6.onRecv(MaxUdpSize + 512, dnsRecvHandler)
  except CatchableError:
    gDnsSock6 = nil

proc resetDnsResolver*() =
  ## Reset DNS resolver state. Closes sockets, clears pending queries and caches.
  if gSocketsReady:
    for _, fut in gPendingQueries:
      fut.cancel()
    gPendingQueries.clear()
    if gDnsSock != nil:
      gDnsSock.close()
      gDnsSock = nil
    if gDnsSock6 != nil:
      gDnsSock6.close()
      gDnsSock6 = nil
    gSocketsReady = false
  clearDnsCache()
  gHostsEntries.clear()
  gHostsLoaded = false
  gNameservers = @[]
  gNameserversLoaded = false

# ============================================================
# Deprecated stubs
# ============================================================

proc initDnsResolver*(numThreads: int = 2) {.deprecated: "DNS resolver no longer needs initialization".} =
  discard

proc deinitDnsResolver*() {.deprecated: "DNS resolver no longer needs deinitialization".} =
  discard

# ============================================================
# Single-query engine (manual future — interfaces with reactor I/O)
# ============================================================

proc nextTxId(): uint16 =
  ## Generate a transaction ID, avoiding collisions with in-flight queries.
  var id = uint16(gRng.next() and 0xFFFF'u32)
  while id in gPendingQueries:
    id = uint16(gRng.next() and 0xFFFF'u32)
  id

proc sendDnsQuery(query: string, ns: Nameserver) =
  ## Send a DNS query to a nameserver. Non-blocking, drops on EAGAIN.
  let sock = if ns.family == AF_INET6 and gDnsSock6 != nil: gDnsSock6
             else: gDnsSock
  try:
    discard sock.trySendToAddr(query, ns.address, 53, ns.family)
  except streams.AsyncIoError:
    discard

proc queryNameserver(name: string, qtype: uint16, ns: Nameserver,
                     timeoutMs: int): CpsFuture[DnsResponse] =
  ## Send a query to a nameserver with timeout via withTimeout combinator.
  ## Proxied to reactor thread via scheduleCallback for thread safety.
  let responseFut = newCpsFuture[DnsResponse]()
  responseFut.pinFutureRuntime()
  let loop = getEventLoop()

  proc makeDoQuery(rf: CpsFuture[DnsResponse], nm: string, qt: uint16,
                   server: Nameserver): proc() {.closure.} =
    result = proc() =
      ensureDnsReady()
      let txId = nextTxId()
      gPendingQueries[txId] = rf
      sendDnsQuery(buildQuery(nm, qt, txId), server)

      # Clean up pending entry when future resolves (success, cancel, or timeout)
      let tid = txId
      proc makeCleanup(t: uint16): proc() {.closure.} =
        result = proc() =
          if t in gPendingQueries:
            gPendingQueries.del(t)
      rf.addCallback(makeCleanup(tid))

  loop.scheduleCallback(makeDoQuery(responseFut, name, qtype, ns))
  withTimeout(responseFut, timeoutMs)

# ============================================================
# CPS async resolution
# ============================================================

proc dnsQuery(name: string, qtype: uint16): CpsFuture[DnsResponse] {.cps.} =
  ## Query DNS with retry across nameservers and exponential backoff.
  let nameservers: seq[Nameserver] = getNameservers()
  var retry = 0
  while retry < MaxRetries:
    let timeoutMs: int = BaseTimeoutMs * (1 shl retry)
    var nsIdx = 0
    while nsIdx < nameservers.len:
      try:
        let resp: DnsResponse = await queryNameserver(name, qtype,
                                                       nameservers[nsIdx], timeoutMs)
        if resp.rcode == 0 or resp.rcode == 3:
          return resp
        # Server error — try next nameserver
      except TimeoutError:
        discard
      except DnsError:
        discard
      nsIdx += 1
    retry += 1
  raise newException(DnsError,
    "DNS resolution failed for '" & name & "': all nameservers timed out")

proc resolveWithCname(name: string, qtype: uint16): CpsFuture[seq[string]] {.cps.} =
  ## Resolve a name, following CNAME chains with cycle detection.
  var current: string = name
  var depth = 0
  var visited: seq[string]
  while depth < MaxCnameDepth:
    if current in visited:
      raise newException(DnsError, "CNAME cycle for '" & current & "'")
    visited.add(current)

    let resp: DnsResponse = await dnsQuery(current, qtype)
    if resp.rcode == 3:
      raise newException(DnsError, "NXDOMAIN: '" & current & "'")

    var addresses: seq[string]
    var cname: string = ""
    var rrIdx = 0
    while rrIdx < resp.answers.len:
      let rr: DnsRR = resp.answers[rrIdx]
      if rr.rrtype == qtype and rr.rrclass == ClassIN:
        try:
          if qtype == TypeA:
            addresses.add(parseIpv4(rr.rdata))
          elif qtype == TypeAAAA:
            addresses.add(parseIpv6(rr.rdata))
        except CatchableError:
          discard
      elif rr.rrtype == TypeCNAME and rr.rrclass == ClassIN:
        cname = rr.rdata
      rrIdx += 1

    if addresses.len > 0:
      return addresses
    elif cname.len > 0:
      current = cname
    else:
      raise newException(DnsError, "No addresses for '" & current & "'")
    depth += 1
  raise newException(DnsError, "CNAME chain too deep for '" & name & "'")

proc asyncResolve*(host: string, port: Port = Port(0),
                   family: Domain = AF_INET): CpsFuture[seq[string]] {.cps.} =
  ## Resolve a hostname asynchronously without caching.
  if isIpAddress(host):
    return @[host]
  let hostsResult: seq[string] = checkHostsFile(host, family)
  if hostsResult.len > 0:
    return hostsResult
  let qtype: uint16 = if family == AF_INET6: TypeAAAA else: TypeA
  let addrs: seq[string] = await resolveWithCname(host, qtype)
  return addrs

proc resolve*(host: string, port: Port = Port(0),
              family: Domain = AF_INET): CpsFuture[seq[string]] {.cps.} =
  ## Resolve a hostname asynchronously with caching.
  if isIpAddress(host):
    return @[host]
  let cache: DnsCache = getDnsCache()
  let cached: seq[string] = cacheLookup(cache, host, family)
  if cached.len > 0:
    return cached
  let addrs: seq[string] = await asyncResolve(host, port, family)
  cacheStore(cache, host, family, addrs)
  return addrs
