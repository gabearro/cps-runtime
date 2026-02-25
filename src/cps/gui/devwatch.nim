## File-watch helpers for GUI dev mode.

import std/[os, tables, times]

type
  GuiWatchState* = object
    mtimes*: Table[string, Time]

proc fileMtimeOrEpoch(path: string): Time =
  if fileExists(path):
    getLastModificationTime(path)
  else:
    fromUnix(0)

proc initWatchState*(files: openArray[string]): GuiWatchState =
  result.mtimes = initTable[string, Time]()
  for file in files:
    if file.len == 0:
      continue
    result.mtimes[file] = fileMtimeOrEpoch(file)

proc hasWatchChanges*(state: var GuiWatchState, files: openArray[string]): bool =
  for file in files:
    if file.len == 0:
      continue
    let prev = state.mtimes.getOrDefault(file, fromUnix(0))
    let now = fileMtimeOrEpoch(file)
    if now > prev:
      state.mtimes[file] = now
      return true

  # Track removals as changes too.
  var stale: seq[string] = @[]
  for tracked in state.mtimes.keys:
    var stillTracked = false
    for file in files:
      if file == tracked:
        stillTracked = true
        break
    if not stillTracked:
      stale.add tracked

  if stale.len > 0:
    for key in stale:
      state.mtimes.del(key)
    return true

  false
