## Move-only two-word closure messages for ARC/ORC thread boundaries.

import std/atomics

type
  OwnedClosureTask* = object
    ## Ref-count-neutral representation of a Nim closure pair.
    fn*: pointer
    env*: pointer

  ClosureReturnProc* = proc(ctx: pointer, owner: int,
                            task: OwnedClosureTask) {.nimcall, gcsafe.}
    ## Return a transferred closure to the thread that owns its captured graph.
  ClosureRetainProc* = proc(ctx: pointer) {.nimcall, gcsafe.}
    ## Retain an owner-return route until a transferred closure comes back.

  ClosureReturnRoute* = object
    ## Thread-local route used to retire captured graphs on their ARC/ORC owner.
    ctx*: pointer
    owner*: int
    retain*: ClosureRetainProc
    release*: ClosureReturnProc

  # Mirrors system.TNimTypeV2 through `flags`. The optional name field is
  # present in checked/type-named builds and was the source of the original
  # bad offset. Keep the condition synchronized with system.nim.
  OrcTypePrefix = object
    destructor: pointer
    size: int
    alignment: int16
    depth: int16
    display: pointer
    when defined(nimTypeNames) or defined(nimArcIds) or
         defined(nimOrcLeakDetector):
      name: cstring
    traceImpl: pointer
    typeInfoV1: pointer
    flags: Atomic[int]

var closureReturnRoute {.threadvar.}: ClosureReturnRoute

proc bindClosureReturnRoute*(route: ClosureReturnRoute) {.inline.} =
  ## Bind the release route for closures created by the calling worker.
  closureReturnRoute = route

proc clearClosureReturnRoute*() {.inline.} =
  ## Remove the calling worker's closure release route.
  closureReturnRoute = default(ClosureReturnRoute)

proc currentClosureReturnRoute*(): ClosureReturnRoute {.inline.} =
  ## Borrow the release route for the calling worker, if it has one.
  closureReturnRoute

proc prepareCrossThreadClosure*[T](cb: var T) {.inline.} =
  ## Prevent a transferred one-shot closure environment from entering the
  ## producer's thread-local ORC cycle-root list. Generated closure types are
  ## unique to their lexical task site; their captured graph is released on
  ## its owner worker (or returned there after remote invocation).
  static: assert sizeof(T) == sizeof(OwnedClosureTask)
  when compileOption("gc", "orc"):
    var words: array[2, pointer]
    copyMem(addr words, addr cb, sizeof(words))
    if words[1] != nil:
      let desc = cast[ptr ptr OrcTypePrefix](words[1])[]
      if desc != nil and (desc.flags.load(moRelaxed) and 1) == 0:
        discard desc.flags.fetchOr(1, moRelaxed)

proc takeClosureTask*[T](cb: var T): OwnedClosureTask {.inline.} =
  ## Move a Nim closure pair into a ref-count-neutral message.
  static: assert sizeof(T) == sizeof(OwnedClosureTask)
  prepareCrossThreadClosure(cb)
  copyMem(addr result, addr cb, sizeof(result))
  zeroMem(addr cb, sizeof(cb))

proc runClosureTask*[T](task: var OwnedClosureTask, _: typedesc[T]) {.inline.} =
  ## Reconstitute and run the closure on its receiving owner thread.
  var cb: T
  copyMem(addr cb, addr task, sizeof(cb))
  task.fn = nil
  task.env = nil
  cb()

proc releaseClosureTask*[T](task: var OwnedClosureTask,
                            _: typedesc[T]) {.inline.} =
  ## Release a closure without invoking it, on its original owner worker.
  var cb: T
  copyMem(addr cb, addr task, sizeof(cb))
  task.fn = nil
  task.env = nil
