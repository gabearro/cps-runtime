## Spinlock-protected hash table for concurrent access.
##
## Wraps std/tables.Table with a CAS-based spinlock, providing thread-safe
## get/put/del/iteration without OS-level mutexes. The spinlock never makes
## a syscall, keeping reactor-thread latency bounded.
##
## Designed for low-contention scenarios (< 1000 entries, short critical
## sections). All operations hold the lock for O(1) except snapshot/clear
## which are O(n).

import std/tables
import spinlock

type
  ConcurrentTable*[K, V] = object
    lock: SpinLock
    data: Table[K, V]

proc initConcurrentTable*[K, V](): ConcurrentTable[K, V] =
  ## Create an empty concurrent table.
  initSpinLock(result.lock)

proc `[]=`*[K, V](ct: var ConcurrentTable[K, V], key: K, val: V) =
  ## Insert or update a key-value pair.
  withSpinLock(ct.lock):
    ct.data[key] = val

proc `[]`*[K, V](ct: var ConcurrentTable[K, V], key: K): V =
  ## Look up a value by key. Raises KeyError if not found.
  withSpinLock(ct.lock):
    result = ct.data[key]

proc getOrDefault*[K, V](ct: var ConcurrentTable[K, V], key: K): V =
  ## Look up a value, returning default(V) if not found.
  withSpinLock(ct.lock):
    result = ct.data.getOrDefault(key)

proc getOrDefault*[K, V](ct: var ConcurrentTable[K, V], key: K, default: V): V =
  ## Look up a value, returning the given default if not found.
  withSpinLock(ct.lock):
    result = ct.data.getOrDefault(key, default)

proc contains*[K, V](ct: var ConcurrentTable[K, V], key: K): bool =
  ## Check if the table contains the given key.
  withSpinLock(ct.lock):
    result = key in ct.data

proc hasKey*[K, V](ct: var ConcurrentTable[K, V], key: K): bool {.inline.} =
  ## Alias for contains.
  contains(ct, key)

proc del*[K, V](ct: var ConcurrentTable[K, V], key: K) =
  ## Delete a key from the table (no-op if not present).
  withSpinLock(ct.lock):
    ct.data.del(key)

proc tryGet*[K, V](ct: var ConcurrentTable[K, V], key: K, val: var V): bool =
  ## Try to get a value. Returns true and sets val if found. Single lookup.
  withSpinLock(ct.lock):
    ct.data.withValue(key, v):
      val = v[]
      result = true
    do:
      result = false

proc take*[K, V](ct: var ConcurrentTable[K, V], key: K, val: var V): bool =
  ## Atomically get and remove a key. Returns true if found. Single lookup.
  withSpinLock(ct.lock):
    result = ct.data.pop(key, val)

template withValue*[K, V](ct: var ConcurrentTable[K, V], key: K,
                          value, body: untyped) =
  ## Execute body with value bound to a ptr to the value for key.
  ## No-op if key is not found. Single lock acquisition, single lookup.
  withSpinLock(ct.lock):
    ct.data.withValue(key, value):
      body

template withValue*[K, V](ct: var ConcurrentTable[K, V], key: K,
                          value, body, doElse: untyped) =
  ## Execute body with value bound to a ptr, or doElse if key not found.
  withSpinLock(ct.lock):
    ct.data.withValue(key, value):
      body
    do:
      doElse

proc len*[K, V](ct: var ConcurrentTable[K, V]): int =
  ## Return the number of entries.
  withSpinLock(ct.lock):
    result = ct.data.len

proc clear*[K, V](ct: var ConcurrentTable[K, V]) =
  ## Remove all entries.
  withSpinLock(ct.lock):
    ct.data.clear()

proc snapshotKeys*[K, V](ct: var ConcurrentTable[K, V]): seq[K] =
  ## Return a snapshot of all keys under a single lock acquisition.
  withSpinLock(ct.lock):
    result = newSeqOfCap[K](ct.data.len)
    for k in ct.data.keys:
      result.add(k)

proc snapshotPairs*[K, V](ct: var ConcurrentTable[K, V]): seq[(K, V)] =
  ## Return a snapshot of all key-value pairs under a single lock acquisition.
  withSpinLock(ct.lock):
    result = newSeqOfCap[(K, V)](ct.data.len)
    for k, v in ct.data.pairs:
      result.add((k, v))

proc snapshotValues*[K, V](ct: var ConcurrentTable[K, V]): seq[V] =
  ## Return a snapshot of all values under a single lock acquisition.
  withSpinLock(ct.lock):
    result = newSeqOfCap[V](ct.data.len)
    for v in ct.data.values:
      result.add(v)
