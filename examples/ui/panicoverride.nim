proc rawoutput(s: string) = discard
proc nimui_runtime_panic(msgPtr: pointer, msgLen: int32) {.importc, cdecl.}

proc panic(s: string) =
  rawoutput(s)
  let msgPtr =
    if s.len == 0:
      nil
    else:
      cast[pointer](unsafeAddr s[0])
  nimui_runtime_panic(msgPtr, s.len.int32)

var currException {.threadvar, noinit.}: ref Exception

proc getCurrentException*(): ref Exception {.compilerproc, inline, nodestroy.} =
  currException

proc nimBorrowCurrentException(): ref Exception {.compilerproc, inline, nodestroy.} =
  currException

proc getCurrentExceptionMsg*(): string {.inline.} =
  if currException == nil:
    ""
  else:
    currException.msg

proc setCurrentException*(exc: ref Exception) {.compilerproc, inline, nodestroy.} =
  currException = exc
