## WebTransport client adapter.

import ../../runtime
import ../../transform
import ../shared/webtransport as wt_shared

proc openWebTransportSession*(authority: string,
                              path: string,
                              sessionId: uint64 = 0'u64,
                              origin: string = ""): CpsFuture[wt_shared.WebTransportSession] {.cps.} =
  return wt_shared.openWebTransportSession(
    sessionId = sessionId,
    authority = authority,
    path = path,
    origin = origin
  )

proc buildConnectHeaders*(authority: string,
                          path: string,
                          origin: string = ""): seq[(string, string)] =
  wt_shared.buildWebTransportConnectHeaders(authority, path, origin = origin)

proc openBidiStream*(session: wt_shared.WebTransportSession): uint64 =
  wt_shared.openBidiStream(session)

proc openUniStream*(session: wt_shared.WebTransportSession): uint64 =
  wt_shared.openUniStream(session)

proc sendDatagram*(session: wt_shared.WebTransportSession, payload: openArray[byte]) =
  wt_shared.sendDatagram(session, payload)

proc recvDatagram*(session: wt_shared.WebTransportSession): seq[byte] =
  wt_shared.recvDatagram(session)

proc closeSession*(session: wt_shared.WebTransportSession,
                   errorCode: uint32 = 0'u32,
                   reason: string = "") =
  wt_shared.closeSession(session, errorCode = errorCode, reason = reason)
