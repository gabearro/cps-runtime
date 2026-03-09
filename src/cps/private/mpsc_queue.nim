## Vyukov MPSC (Multi-Producer Single-Consumer) Lock-Free Queue
##
## Intrusive lock-free queue based on Dmitry Vyukov's algorithm.
## Multiple producers can enqueue concurrently (via atomic exchange on tail).
## A single consumer dequeues from head (no CAS needed).
##
## Nodes are allocated with allocShared0 and freed after callback extraction.
## There is a brief window between the tail exchange and the next-link write
## where the consumer may see an incomplete link — it retries on next drain.

import std/atomics

type
  CrossThreadCallback* = proc() {.closure, gcsafe.}

  MpscNode* = object
    next*: Atomic[pointer]     ## ptr MpscNode (or nil)
    callback*: CrossThreadCallback

  MpscQueue* = object
    head*: ptr MpscNode        ## consumer reads from here
    tail*: Atomic[pointer]     ## producers exchange here (ptr MpscNode)
    stub*: MpscNode            ## sentinel node

proc initMpscQueue*(q: var MpscQueue) =
  ## Initialize the MPSC queue with the stub as both head and tail.
  q.stub.next.store(nil, moRelaxed)
  q.stub.callback = nil
  q.head = addr q.stub
  q.tail.store(cast[pointer](addr q.stub), moRelaxed)

proc enqueue*(q: var MpscQueue, node: ptr MpscNode) =
  ## Producer: enqueue a node. Lock-free, wait-free for producers.
  ## Node must have next = nil and callback set before calling.
  node.next.store(nil, moRelaxed)
  let prev = cast[ptr MpscNode](q.tail.exchange(cast[pointer](node), moAcquireRelease))
  # Link previous tail to new node. Brief window where consumer sees prev.next = nil.
  prev.next.store(cast[pointer](node), moRelease)

proc dequeue*(q: var MpscQueue): ptr MpscNode =
  ## Consumer: dequeue a node. Returns nil if empty or if the next link
  ## is not yet visible (producer still linking). Single-consumer only.
  var head = q.head
  var next = cast[ptr MpscNode](head.next.load(moAcquire))
  # Skip the stub node
  if head == addr q.stub:
    if next == nil:
      return nil
    q.head = next
    head = next
    next = cast[ptr MpscNode](head.next.load(moAcquire))
  if next != nil:
    q.head = next
    return head
  # head.next is nil — either empty or producer hasn't linked yet
  let tail = cast[ptr MpscNode](q.tail.load(moAcquire))
  if head != tail:
    return nil  # producer enqueued but hasn't linked next yet; retry later
  # Queue is truly empty — re-insert stub to restart
  enqueue(q, addr q.stub)
  next = cast[ptr MpscNode](head.next.load(moAcquire))
  if next != nil:
    q.head = next
    return head
  return nil

proc isEmpty*(q: var MpscQueue): bool =
  ## Check if the queue appears empty. May briefly return true even when
  ## a producer has enqueued but not yet linked (conservative).
  let head = q.head
  let next = cast[ptr MpscNode](head.next.load(moAcquire))
  if head == addr q.stub:
    if next == nil:
      return true
    # Stub has a next — there's data
    return false
  # Non-stub head always means data
  return false

proc hasPending*(q: var MpscQueue): bool {.inline.} =
  ## True when data is available or a producer is in-flight between tail
  ## exchange and link publication. Use this to avoid treating transient
  ## dequeue(nil) as permanently empty.
  if not q.isEmpty():
    return true
  q.head != cast[ptr MpscNode](q.tail.load(moAcquire))

proc allocNode*(cb: CrossThreadCallback): ptr MpscNode =
  ## Allocate and initialize a queue node with the given callback.
  result = cast[ptr MpscNode](allocShared0(sizeof(MpscNode)))
  result.next.store(nil, moRelaxed)
  result.callback = cb

proc freeNode*(node: ptr MpscNode) =
  ## Free a dequeued node. Must be called after extracting the callback.
  deallocShared(node)
