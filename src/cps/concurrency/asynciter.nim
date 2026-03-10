## CPS Async Iterators
##
## Provides an async iterator/stream abstraction built on top of async
## channels. Producers emit values lazily into a bounded channel; consumers
## pull values via `next()`. Backpressure is automatic: the producer
## suspends when the buffer is full.
##
## Combinators (map, filter, take) return new iterators and are lazy --
## they only run when the consumer pulls. Closing a combinator propagates
## the close to its source iterator.

import std/[options, atomics]
import ../runtime
import ../transform
import ./channels
import ../eventloop

type
  Sender*[T] = ref object
    ## Handle given to the producer proc for emitting values.
    ch: AsyncChannel[T]

  AsyncIterator*[T] = ref object
    ## An async iterator backed by a channel.
    ## The producer task feeds values into the channel; the consumer
    ## pulls them out via `next()`. When the producer finishes, the
    ## channel is closed; remaining buffered items can still be consumed.
    ch: AsyncChannel[T]
    producerFut: CpsVoidFuture
    closed: Atomic[bool]
    onClose: proc() ## Called on close to propagate to source iterators

# ============================================================
# Sender - emit values
# ============================================================

proc emit*[T](sender: Sender[T], value: sink T): CpsVoidFuture =
  ## Send a value to the consumer. Suspends if the buffer is full
  ## (backpressure). Uses move semantics for zero-copy transfer.
  result = sender.ch.send(move(value))

# ============================================================
# Construction
# ============================================================

proc newAsyncIterator*[T](producer: proc(s: Sender[T]): CpsVoidFuture,
                          bufferSize: int = 1): AsyncIterator[T] =
  ## Create an async iterator. The producer CPS proc receives a
  ## `Sender[T]` and should call `emit()` to produce values.
  ## When the producer returns, the channel is closed. Remaining
  ## buffered values can still be consumed. If the producer fails
  ## with an error, the error is propagated to consumers.
  ##
  ## `bufferSize` controls how many values can be buffered before
  ## the producer is suspended (backpressure). Default is 1.
  let ch = newAsyncChannel[T](bufferSize)
  let sender = Sender[T](ch: ch)
  let producerFut = producer(sender)

  # When the producer finishes, close the channel.
  # Remaining buffered items can still be recv'd by the consumer.
  # Once drained, recv() fails with ChannelClosed, signaling end of iteration.
  producerFut.addCallback(proc() =
    ch.close()
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
  ## Returns `some(val)` for each produced value.
  ## Returns `none(T)` when iteration is complete.
  ## Propagates producer errors to the consumer.
  if iter.closed.load:
    return completedFuture[Option[T]](none(T))
  let recvFut = iter.ch.recv()
  let resultFut = newCpsFuture[Option[T]]()
  recvFut.addCallback(proc() =
    if recvFut.hasError:
      # Channel closed and drained — end of iteration
      iter.closed.store(true)
      if iter.producerFut.finished and iter.producerFut.hasError:
        resultFut.fail(iter.producerFut.getError())
      else:
        resultFut.complete(none(T))
    else:
      resultFut.complete(some(recvFut.read()))
  )
  result = resultFut

proc close*[T](iter: AsyncIterator[T]) =
  ## Close the iterator early. The underlying channel is closed,
  ## which will cause the producer to get ChannelClosed on its
  ## next emit(). Propagates close to source iterators in combinator chains.
  if not iter.closed.load:
    iter.closed.store(true)
    iter.ch.close()
    if iter.onClose != nil:
      iter.onClose()

proc isClosed*[T](iter: AsyncIterator[T]): bool =
  ## Check whether the iterator has been closed.
  iter.closed.load

# ============================================================
# Combinators -- lazy, return new iterators
#
# Each combinator creates a new iterator whose producer reads
# from the source iterator and emits transformed values.
# Closing a combinator propagates the close to its source.
# ============================================================

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
  ## Closing the result also closes the source.
  proc wrappedProducer(sender: Sender[U]): CpsVoidFuture =
    mapProducer[T, U](sender, iter, f)
  result = newAsyncIterator[U](wrappedProducer, bufferSize = 1)
  result.onClose = proc() = iter.close()

proc filterProducer[T](sender: Sender[T], iter: AsyncIterator[T],
                       pred: proc(x: T): bool): CpsVoidFuture {.cps.} =
  while true:
    let item: Option[T] = await iter.next()
    if item.isNone:
      return
    let value = item.get()
    if pred(value):
      await sender.emit(move(value))

proc filter*[T](iter: AsyncIterator[T],
                pred: proc(x: T): bool): AsyncIterator[T] =
  ## Return a new iterator that only yields values for which `pred` returns true.
  ## Closing the result also closes the source.
  proc wrappedProducer(sender: Sender[T]): CpsVoidFuture =
    filterProducer[T](sender, iter, pred)
  result = newAsyncIterator[T](wrappedProducer, bufferSize = 1)
  result.onClose = proc() = iter.close()

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
  ## Closing the result also closes the source.
  proc wrappedProducer(sender: Sender[T]): CpsVoidFuture =
    takeProducer[T](sender, iter, n)
  result = newAsyncIterator[T](wrappedProducer, bufferSize = 1)
  result.onClose = proc() = iter.close()

# ============================================================
# Terminal operations
# ============================================================

proc collect*[T](iter: AsyncIterator[T]): CpsFuture[seq[T]] {.cps.} =
  ## Drain all values from the iterator into a seq.
  var items: seq[T] = @[]
  while true:
    let item: Option[T] = await iter.next()
    if item.isNone:
      return items
    items.add(item.get())

proc forEach*[T](iter: AsyncIterator[T],
    action: proc(x: T): CpsVoidFuture): CpsVoidFuture {.cps.} =
  ## Apply an async action to each value from the iterator.
  while true:
    let item: Option[T] = await iter.next()
    if item.isNone:
      return
    await action(item.get())
