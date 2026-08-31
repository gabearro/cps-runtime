## Move-only two-word closure messages for ARC/ORC thread boundaries.

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
  ## Validate the closure-pair ABI used by the ownership queues.
  ##
  ## ARC/ORC type descriptors are process-global and immutable here. Closure
  ## environments are instead invoked remotely as raw pairs and returned to
  ## their allocating worker for destruction.
  static: assert sizeof(T) == sizeof(OwnedClosureTask)

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
