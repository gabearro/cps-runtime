## Vyukov MPSC (Multi-Producer Single-Consumer) Lock-Free Queue
##
## Intrusive lock-free queue based on Dmitry Vyukov's algorithm.
## https://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
##
## Generic over payload type T. Multiple producers can enqueue concurrently
## (wait-free via atomic exchange on tail). A single consumer dequeues from
## head (no CAS needed).
##
## Nodes are allocated with allocShared0 and freed after payload extraction.
## There is a brief window between the tail exchange and the next-link write
## where the consumer may see an incomplete link — it retries on next drain.
##
## Cache-line padding separates head (consumer) from tail (producers) to
## prevent false sharing.

import std/atomics

const CacheLineBytes = 64

type
  CrossThreadCallback* = proc() {.closure, gcsafe.}

  MpscNode*[T] = object
    next: Atomic[pointer]     ## ptr MpscNode[T] (or nil)
    payload*: T

  MpscQueue*[T] = object
    head: ptr MpscNode[T]                      ## consumer reads from here
    headPad {.align(CacheLineBytes).}: array[CacheLineBytes - sizeof(pointer), byte]
    tail: Atomic[pointer]                       ## producers exchange here
    tailPad {.align(CacheLineBytes).}: array[CacheLineBytes - sizeof(Atomic[pointer]), byte]
    stub: MpscNode[T]                           ## sentinel node

# -- Private atomic helpers (reduce cast noise) --

proc loadNext[T](node: ptr MpscNode[T]): ptr MpscNode[T] {.inline.} =
  cast[ptr MpscNode[T]](node.next.load(moAcquire))

proc storeNext[T](node: ptr MpscNode[T], val: ptr MpscNode[T]) {.inline.} =
  node.next.store(cast[pointer](val), moRelease)

proc clearNext[T](node: ptr MpscNode[T]) {.inline.} =
  node.next.store(nil, moRelaxed)

proc loadTail[T](q: var MpscQueue[T]): ptr MpscNode[T] {.inline.} =
  cast[ptr MpscNode[T]](q.tail.load(moAcquire))

proc exchangeTail[T](q: var MpscQueue[T], node: ptr MpscNode[T]): ptr MpscNode[T] {.inline.} =
  cast[ptr MpscNode[T]](q.tail.exchange(cast[pointer](node), moAcquireRelease))

# -- Public API --

proc initMpscQueue*[T](q: var MpscQueue[T]) =
  ## Initialize the MPSC queue with the stub as both head and tail.
  q.stub.next.store(nil, moRelaxed)
  q.head = addr q.stub
  q.tail.store(cast[pointer](addr q.stub), moRelaxed)

proc isInitialized*[T](q: var MpscQueue[T]): bool {.inline.} =
  ## True after ``initMpscQueue`` has been called (head is non-nil).
  q.head != nil

proc enqueue*[T](q: var MpscQueue[T], node: ptr MpscNode[T]) =
  ## Producer: enqueue a node. Lock-free, wait-free for producers.
  clearNext(node)
  let prev = exchangeTail(q, node)
  storeNext(prev, node)

proc dequeue*[T](q: var MpscQueue[T]): ptr MpscNode[T] =
  ## Consumer: dequeue a node. Returns nil if empty or if the next link
  ## is not yet visible (producer still linking). Single-consumer only.
  var head = q.head
  var next = loadNext(head)
  # Skip the stub node
  if head == addr q.stub:
    if next == nil:
      return nil
    q.head = next
    head = next
    next = loadNext(head)
  if next != nil:
    q.head = next
    return head
  # head.next is nil — either empty or producer hasn't linked yet
  if head != loadTail(q):
    return nil  # producer enqueued but hasn't linked next yet; retry later
  # Queue is truly empty — re-insert stub to restart
  enqueue(q, addr q.stub)
  next = loadNext(head)
  if next != nil:
    q.head = next
    return head
  return nil

proc isEmpty*[T](q: var MpscQueue[T]): bool =
  ## Check if the queue appears empty. May briefly return true even when
  ## a producer has enqueued but not yet linked (conservative).
  let head = q.head
  if head == addr q.stub:
    return loadNext(head) == nil
  false

proc hasPending*[T](q: var MpscQueue[T]): bool {.inline.} =
  ## True when data is available or a producer is in-flight between tail
  ## exchange and link publication. Use this to avoid treating a transient
  ## ``dequeue() == nil`` as permanently empty.
  not q.isEmpty() or q.head != loadTail(q)

proc allocNode*[T](val: T): ptr MpscNode[T] =
  ## Allocate and initialize a queue node with the given payload.
  ## Uses allocShared0 so ref-counted payload types start from nil.
  result = cast[ptr MpscNode[T]](allocShared0(sizeof(MpscNode[T])))
  result.next.store(nil, moRelaxed)
  result.payload = val

proc freeNode*[T](node: ptr MpscNode[T]) =
  ## Free a dequeued node. Must be called after extracting the payload.
  deallocShared(node)

proc discardAll*[T](q: var MpscQueue[T]) =
  ## Drain and free all pending nodes without processing payloads.
  while true:
    let node = dequeue(q)
    if node == nil: break
    freeNode(node)
