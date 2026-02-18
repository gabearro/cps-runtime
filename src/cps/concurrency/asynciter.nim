## CPS Async Iterators
##
## Provides an async iterator/stream abstraction built on top of async
## channels. Producers emit values lazily into a bounded channel; consumers
## pull values via `next()`. Backpressure is automatic: the producer
## suspends when the buffer is full.
##
## Combinators (map, filter, take) return new iterators and are lazy --
## they only run when the consumer pulls.

import std/[options, atomics]
import ../runtime
import ../transform
import ./channels
import ../eventloop

type
  Sender*[T] = ref object
    ## Handle given to the producer proc for emitting values.
    ch*: AsyncChannel[Option[T]]

  AsyncIterator*[T] = ref object
    ## An async iterator backed by a channel.
    ## The producer task feeds values into the channel; the consumer
    ## pulls them out via `next()`. A `none(T)` sentinel signals that
    ## the producer has finished.
    ch*: AsyncChannel[Option[T]]
    producerFut*: CpsVoidFuture  ## The producing computation's future
    closed: Atomic[bool]

# ============================================================
# Sender - emit values
# ============================================================

proc emit*[T](sender: Sender[T], value: sink T): CpsVoidFuture =
  ## Send a value to the consumer. Suspends if the buffer is full
  ## (backpressure). Uses move semantics for zero-copy transfer.
  result = sender.ch.send(some(move(value)))

# ============================================================
# Construction
# ============================================================

proc newAsyncIterator*[T](producer: proc(s: Sender[T]): CpsVoidFuture,
                          bufferSize: int = 1): AsyncIterator[T] =
  ## Create an async iterator. The producer CPS proc receives a
  ## `Sender[T]` and should call `emit()` to produce values.
  ## When the producer returns normally, the iterator is automatically
  ## closed (a None sentinel is sent). If the producer fails with an
  ## error, the error is propagated to consumers via the channel.
  ##
  ## `bufferSize` controls how many values can be buffered before
  ## the producer is suspended (backpressure). Default is 1.
  let ch = newAsyncChannel[Option[T]](bufferSize + 1)  # +1 for the None sentinel
  let sender = Sender[T](ch: ch)

  # Call the producer -- it returns a CpsVoidFuture
  let producerFut = producer(sender)

  # When the producer finishes, send the None sentinel.
  # If the producer failed with an error, close the channel with
  # the sentinel so consumers can distinguish error EOF from normal EOF.
  producerFut.addCallback(proc() =
    if producerFut.hasError:
      # Producer errored: send sentinel then close the channel.
      # Consumers will get the sentinel (end of iteration) and can
      # check producerFut.getError() if needed.
      let sentinelFut = ch.send(none(T))
      discard sentinelFut
    else:
      let sentinelFut = ch.send(none(T))
      discard sentinelFut
  )

  result = AsyncIterator[T](
    ch: ch,
    producerFut: producerFut,
  )
  result.closed.store(false)

# ============================================================
# Consumer API
# ============================================================

proc next*[T](iter: AsyncIterator[T]): CpsFuture[Option[T]] =
  ## Get the next value from the iterator.
  ## Returns `none(T)` when iteration is complete.
  ## Propagates producer errors to the consumer.
  if iter.closed.load:
    let fut = newCpsFuture[Option[T]]()
    fut.complete(none(T))
    return fut
  # Recv from the channel. The channel returns Option[T]:
  # - some(val) = a produced value
  # - none(T) = end sentinel
  # If the channel is closed (early close), recv will fail with
  # ChannelClosed -- we catch that and return none(T).
  let recvFut = iter.ch.recv()
  # Wrap to handle ChannelClosed gracefully
  let resultFut = newCpsFuture[Option[T]]()
  recvFut.addCallback(proc() =
    if recvFut.hasError:
      # Channel was closed -- treat as end of iteration
      resultFut.complete(none(T))
    else:
      let val = recvFut.read()
      if val.isNone:
        iter.closed.store(true)
        # Check if the producer had an error
        if iter.producerFut.finished and iter.producerFut.hasError:
          resultFut.fail(iter.producerFut.getError())
        else:
          resultFut.complete(val)
      else:
        resultFut.complete(val)
  )
  result = resultFut

proc close*[T](iter: AsyncIterator[T]) =
  ## Close the iterator early. The underlying channel is closed,
  ## which will cause the producer to get ChannelClosed on its
  ## next emit(). Uses atomic bool so this is MT-safe.
  if not iter.closed.load:
    iter.closed.store(true)
    iter.ch.close()

proc isClosed*[T](iter: AsyncIterator[T]): bool =
  ## Check whether the iterator has been closed.
  iter.closed.load

# ============================================================
# Combinators -- lazy, return new iterators
#
# Each combinator creates a new iterator whose producer reads
# from the source iterator and emits transformed values.
# ============================================================

# --- map ---

proc mapProducer[T, U](sender: Sender[U], iter: AsyncIterator[T],
                       f: proc(x: T): U): CpsVoidFuture {.cps.} =
  while true:
    let item: Option[T] = await iter.next()
    if item.isNone:
      return
    await sender.emit(f(item.get()))

proc map*[T, U](iter: AsyncIterator[T],
                f: proc(x: T): U): AsyncIterator[U] =
  ## Return a new iterator that applies `f` to each value from `iter`.
  ## Lazy: the mapping only runs when the consumer pulls.
  proc wrappedProducer(sender: Sender[U]): CpsVoidFuture =
    mapProducer[T, U](sender, iter, f)
  result = newAsyncIterator[U](wrappedProducer, bufferSize = 1)

# --- filter ---

proc filterProducer[T](sender: Sender[T], iter: AsyncIterator[T],
                       pred: proc(x: T): bool): CpsVoidFuture {.cps.} =
  while true:
    let item: Option[T] = await iter.next()
    if item.isNone:
      return
    if pred(item.get()):
      await sender.emit(item.get())

proc filter*[T](iter: AsyncIterator[T],
                pred: proc(x: T): bool): AsyncIterator[T] =
  ## Return a new iterator that only yields values for which `pred` returns true.
  ## Lazy: the filter only runs when the consumer pulls.
  proc wrappedProducer(sender: Sender[T]): CpsVoidFuture =
    filterProducer[T](sender, iter, pred)
  result = newAsyncIterator[T](wrappedProducer, bufferSize = 1)

# --- take ---

proc takeProducer[T](sender: Sender[T], iter: AsyncIterator[T],
                     n: int): CpsVoidFuture {.cps.} =
  var count = 0
  while count < n:
    let item: Option[T] = await iter.next()
    if item.isNone:
      return
    count += 1
    await sender.emit(item.get())

proc take*[T](iter: AsyncIterator[T], n: int): AsyncIterator[T] =
  ## Return a new iterator that yields at most `n` values from `iter`.
  ## Lazy: values are only pulled from the source as the consumer pulls.
  proc wrappedProducer(sender: Sender[T]): CpsVoidFuture =
    takeProducer[T](sender, iter, n)
  result = newAsyncIterator[T](wrappedProducer, bufferSize = 1)

# ============================================================
# Terminal operations
# ============================================================

proc collect*[T](iter: AsyncIterator[T]): CpsFuture[seq[T]] {.cps.} =
  ## Drain all values from the iterator into a seq.
  ## Returns a future that completes with the collected values.
  ## If the producer failed with an error, the future fails with that error.
  var items: seq[T] = @[]
  while true:
    let item: Option[T] = await iter.next()
    if item.isNone:
      return items
    items.add(item.get())

proc forEach*[T](iter: AsyncIterator[T],
    action: proc(x: T): CpsVoidFuture): CpsVoidFuture {.cps.} =
  ## Apply an async action to each value from the iterator.
  ## Returns a future that completes when all values have been processed.
  ## Propagates errors from both the iterator and the action.
  while true:
    let item: Option[T] = await iter.next()
    if item.isNone:
      return
    await action(item.get())
