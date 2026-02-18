## CPS I/O Process
##
## Provides async subprocess execution with piped I/O, integrated with
## the CPS event loop. Pipe fds are registered with the OS selector for
## non-blocking reads/writes; exit status is polled via a timer.

import std/[posix, os, nativesockets]
import ../runtime
import ../eventloop
import ./streams

proc c_setenv(name: cstring, value: cstring, overwrite: cint): cint {.
  importc: "setenv", header: "<stdlib.h>".}

# ============================================================
# Types
# ============================================================

type
  PipeMode* = enum
    pmPipe     ## Create async pipe
    pmInherit  ## Inherit parent's fd
    pmNull     ## Redirect to /dev/null

  ProcessError* = object of streams.AsyncIoError

  PipeStream* = ref object of AsyncStream
    fd*: cint

  AsyncProcess* = ref object
    pid*: int
    stdinStream*: AsyncStream   ## Writable (nil if not pmPipe)
    stdoutStream*: AsyncStream  ## Readable (nil if not pmPipe)
    stderrStream*: AsyncStream  ## Readable (nil if not pmPipe)
    exitCode*: int
    exited*: bool
    exitFut: CpsFuture[int]     ## Lazily created by wait()

# ============================================================
# Helpers: set fd non-blocking
# ============================================================

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL)
  if flags < 0:
    raiseOSError(osLastError())
  if fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
    raiseOSError(osLastError())

# ============================================================
# PipeStream - AsyncStream over a pipe fd
# ============================================================

proc pipeStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let ps = PipeStream(s)
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc tryRecv() =
    var buf = newString(size)
    let n = posix.read(ps.fd, addr buf[0], size)
    if n < 0:
      let err = osLastError()
      if err.int == EAGAIN or err.int == EWOULDBLOCK:
        loop.registerRead(ps.fd.SocketHandle, proc() =
          loop.unregister(ps.fd.SocketHandle)
          tryRecv()
        )
        return
      else:
        fut.fail(newException(streams.AsyncIoError, "Pipe read failed: " & osErrorMsg(err)))
        return
    elif n == 0:
      fut.complete("")  # EOF — child closed the pipe
      return
    else:
      buf.setLen(n)
      fut.complete(buf)

  tryRecv()
  result = fut

proc pipeStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let ps = PipeStream(s)
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  var sent = 0
  let totalLen = data.len

  proc trySend() =
    while sent < totalLen:
      let remaining = totalLen - sent
      let n = posix.write(ps.fd, unsafeAddr data[sent], remaining)
      if n < 0:
        let err = osLastError()
        if err.int == EAGAIN or err.int == EWOULDBLOCK:
          loop.registerWrite(ps.fd.SocketHandle, proc() =
            loop.unregister(ps.fd.SocketHandle)
            trySend()
          )
          return
        elif err.int == EPIPE:
          fut.fail(newException(streams.AsyncIoError, "Broken pipe"))
          return
        else:
          fut.fail(newException(streams.AsyncIoError, "Pipe write failed: " & osErrorMsg(err)))
          return
      elif n == 0:
        fut.fail(newException(streams.AsyncIoError, "Pipe write returned 0"))
        return
      else:
        sent += n
    fut.complete()

  trySend()
  result = fut

proc pipeStreamClose(s: AsyncStream) =
  let ps = PipeStream(s)
  try:
    let loop = getEventLoop()
    loop.unregister(ps.fd.SocketHandle)
  except Exception:
    discard
  discard posix.close(ps.fd)

proc newPipeStream*(fd: cint): PipeStream =
  ## Wrap a non-blocking pipe fd into an AsyncStream.
  result = PipeStream(
    fd: fd,
    closed: false
  )
  result.readProc = pipeStreamRead
  result.writeProc = pipeStreamWrite
  result.closeProc = pipeStreamClose

# ============================================================
# Exit polling
# ============================================================

proc pollExit(p: AsyncProcess) =
  ## Poll waitpid(WNOHANG) every 50ms until the process exits.
  let loop = getEventLoop()

  proc doPoll() =
    var status: cint = 0
    let r = waitpid(p.pid.Pid, status, WNOHANG)
    if r == p.pid.Pid:
      # Process exited
      if WIFEXITED(status):
        p.exitCode = WEXITSTATUS(status).int
      elif WIFSIGNALED(status):
        p.exitCode = -(WTERMSIG(status).int)
      else:
        p.exitCode = -1
      p.exited = true
      if p.exitFut != nil and not p.exitFut.finished:
        p.exitFut.complete(p.exitCode)
    elif r == 0.Pid:
      # Not exited yet — schedule another poll in 50ms
      loop.registerTimer(50, proc() =
        doPoll()
      )
    else:
      # waitpid error
      let err = osLastError()
      p.exited = true
      p.exitCode = -1
      if p.exitFut != nil and not p.exitFut.finished:
        p.exitFut.fail(newException(ProcessError, "waitpid failed: " & osErrorMsg(err)))

  doPoll()

# ============================================================
# startProcess
# ============================================================

proc startProcess*(command: string, args: seq[string] = @[],
                   env: seq[(string, string)] = @[],
                   workingDir: string = "",
                   stdinMode: PipeMode = pmPipe,
                   stdoutMode: PipeMode = pmPipe,
                   stderrMode: PipeMode = pmPipe): AsyncProcess =
  ## Start a subprocess. Returns an AsyncProcess with piped streams.
  ##
  ## - command: the executable name (looked up in PATH via execvp)
  ## - args: arguments (command is NOT prepended — args[0] should be the first real arg)
  ## - env: if non-empty, sets the child's environment
  ## - workingDir: if non-empty, chdir before exec
  ## - stdin/stdout/stderrMode: pipe, inherit, or /dev/null

  var stdinPipe: array[2, cint]   # [readEnd, writeEnd]
  var stdoutPipe: array[2, cint]
  var stderrPipe: array[2, cint]

  # Create pipes as needed
  if stdinMode == pmPipe:
    if pipe(stdinPipe) != 0:
      raise newException(ProcessError, "Failed to create stdin pipe: " & osErrorMsg(osLastError()))
  if stdoutMode == pmPipe:
    if pipe(stdoutPipe) != 0:
      raise newException(ProcessError, "Failed to create stdout pipe: " & osErrorMsg(osLastError()))
  if stderrMode == pmPipe:
    if pipe(stderrPipe) != 0:
      raise newException(ProcessError, "Failed to create stderr pipe: " & osErrorMsg(osLastError()))

  let pid = fork()
  if pid < 0.Pid:
    raise newException(ProcessError, "fork() failed: " & osErrorMsg(osLastError()))

  if pid == 0.Pid:
    # ---- CHILD PROCESS ----

    # stdin
    case stdinMode
    of pmPipe:
      discard dup2(stdinPipe[0], 0)
      discard posix.close(stdinPipe[0])
      discard posix.close(stdinPipe[1])
    of pmNull:
      let devNull = posix.open("/dev/null", O_RDONLY)
      discard dup2(devNull, 0)
      discard posix.close(devNull)
    of pmInherit:
      discard

    # stdout
    case stdoutMode
    of pmPipe:
      discard dup2(stdoutPipe[1], 1)
      discard posix.close(stdoutPipe[0])
      discard posix.close(stdoutPipe[1])
    of pmNull:
      let devNull = posix.open("/dev/null", O_WRONLY)
      discard dup2(devNull, 1)
      discard posix.close(devNull)
    of pmInherit:
      discard

    # stderr
    case stderrMode
    of pmPipe:
      discard dup2(stderrPipe[1], 2)
      discard posix.close(stderrPipe[0])
      discard posix.close(stderrPipe[1])
    of pmNull:
      let devNull = posix.open("/dev/null", O_WRONLY)
      discard dup2(devNull, 2)
      discard posix.close(devNull)
    of pmInherit:
      discard

    # Change working directory
    if workingDir.len > 0:
      if chdir(workingDir.cstring) != 0:
        posix.exitnow(127)

    # Set environment
    if env.len > 0:
      # Build envp array
      var envStrings = newSeq[string](env.len)
      for i in 0 ..< env.len:
        envStrings[i] = env[i][0] & "=" & env[i][1]
      var envp = allocCStringArray(envStrings)
      # Build argv
      var argv = newSeq[string](args.len + 1)
      argv[0] = command
      for i in 0 ..< args.len:
        argv[i + 1] = args[i]
      var cArgv = allocCStringArray(argv)
      discard execve(cstring(command), cArgv, envp)
      # If execve fails, try execvp path lookup by falling through
      # Actually, execve doesn't search PATH. For env + PATH lookup,
      # we set environ and use execvp.
      deallocCStringArray(cArgv)
      deallocCStringArray(envp)
      # Fallback: set environ manually and use execvp
      for i in 0 ..< env.len:
        discard c_setenv(env[i][0].cstring, env[i][1].cstring, 1.cint)
      # Clear vars not in env (approximate: just run execvp with current modified env)
      var argv2 = newSeq[string](args.len + 1)
      argv2[0] = command
      for i in 0 ..< args.len:
        argv2[i + 1] = args[i]
      var cArgv2 = allocCStringArray(argv2)
      discard execvp(command.cstring, cArgv2)
      posix.exitnow(127)
    else:
      # No custom env — just execvp
      var argv = newSeq[string](args.len + 1)
      argv[0] = command
      for i in 0 ..< args.len:
        argv[i + 1] = args[i]
      var cArgv = allocCStringArray(argv)
      discard execvp(command.cstring, cArgv)
      posix.exitnow(127)

  # ---- PARENT PROCESS ----

  result = AsyncProcess(
    pid: pid.int,
    exited: false,
    exitCode: 0
  )

  # Close child ends of pipes, set parent ends non-blocking, wrap in PipeStream
  if stdinMode == pmPipe:
    discard posix.close(stdinPipe[0])  # close child's read end
    setNonBlocking(stdinPipe[1])
    result.stdinStream = newPipeStream(stdinPipe[1])

  if stdoutMode == pmPipe:
    discard posix.close(stdoutPipe[1])  # close child's write end
    setNonBlocking(stdoutPipe[0])
    result.stdoutStream = newPipeStream(stdoutPipe[0])

  if stderrMode == pmPipe:
    discard posix.close(stderrPipe[1])  # close child's write end
    setNonBlocking(stderrPipe[0])
    result.stderrStream = newPipeStream(stderrPipe[0])

  # Start exit polling
  pollExit(result)

# ============================================================
# wait - wait for process exit
# ============================================================

proc wait*(p: AsyncProcess): CpsFuture[int] =
  ## Wait for the process to exit. Returns exit code.
  ## Negative exit codes indicate death by signal (e.g. -9 = SIGKILL).
  if p.exited:
    let fut = newCpsFuture[int]()
    fut.pinFutureRuntime()
    fut.complete(p.exitCode)
    return fut
  if p.exitFut == nil:
    p.exitFut = newCpsFuture[int]()
    p.exitFut.pinFutureRuntime()
  result = p.exitFut

# ============================================================
# kill / terminate / forceKill
# ============================================================

proc kill*(p: AsyncProcess, signal: cint = SIGTERM) =
  ## Send a signal to the process.
  if not p.exited:
    discard posix.kill(p.pid.Pid, signal)

proc terminate*(p: AsyncProcess) =
  ## Send SIGTERM.
  p.kill(SIGTERM)

proc forceKill*(p: AsyncProcess) =
  ## Send SIGKILL.
  p.kill(SIGKILL)

# ============================================================
# Convenience: exec (run and collect output)
# ============================================================

proc readAll(s: AsyncStream): CpsFuture[string] =
  ## Read all data from a stream until EOF.
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()
  var collected = ""

  proc readLoop() =
    let readFut = s.read(65536)
    readFut.addCallback(proc() =
      if readFut.hasError():
        fut.fail(readFut.getError())
        return
      let chunk = readFut.read()
      if chunk.len == 0:
        # EOF
        fut.complete(collected)
      else:
        collected.add(chunk)
        readLoop()
    )

  readLoop()
  result = fut

proc exec*(command: string, args: seq[string] = @[],
           env: seq[(string, string)] = @[],
           workingDir: string = "",
           input: string = ""): CpsFuture[tuple[exitCode: int, stdout: string, stderr: string]] =
  ## Run a command to completion, collecting stdout and stderr.
  ## If input is non-empty, it is written to stdin.
  let fut = newCpsFuture[tuple[exitCode: int, stdout: string, stderr: string]]()
  fut.pinFutureRuntime()

  let p = startProcess(command, args, env, workingDir,
                       stdinMode = pmPipe,
                       stdoutMode = pmPipe,
                       stderrMode = pmPipe)

  # Write input to stdin, then close it
  if input.len > 0:
    let writeFut = p.stdinStream.write(input)
    writeFut.addCallback(proc() =
      p.stdinStream.close()
    )
  else:
    p.stdinStream.close()

  # Read stdout and stderr concurrently
  let stdoutFut = readAll(p.stdoutStream)
  let stderrFut = readAll(p.stderrStream)
  let waitFut = p.wait()

  # When all three are done, complete the result
  var doneCount = 0

  proc checkDone() =
    inc doneCount
    if doneCount == 3:
      if stdoutFut.hasError():
        fut.fail(stdoutFut.getError())
      elif stderrFut.hasError():
        fut.fail(stderrFut.getError())
      elif waitFut.hasError():
        fut.fail(waitFut.getError())
      else:
        let res = (exitCode: waitFut.read(), stdout: stdoutFut.read(), stderr: stderrFut.read())
        fut.complete(res)

  stdoutFut.addCallback(proc() = checkDone())
  stderrFut.addCallback(proc() = checkDone())
  waitFut.addCallback(proc() = checkDone())

  result = fut

proc execOutput*(command: string, args: seq[string] = @[]): CpsFuture[string] =
  ## Run a command and return its stdout. Raises on non-zero exit.
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()

  let execFut = exec(command, args)
  execFut.addCallback(proc() =
    if execFut.hasError():
      fut.fail(execFut.getError())
      return
    let r = execFut.read()
    if r.exitCode != 0:
      fut.fail(newException(ProcessError,
        "Command '" & command & "' exited with code " & $r.exitCode &
        (if r.stderr.len > 0: ": " & r.stderr else: "")))
    else:
      fut.complete(r.stdout)
  )

  result = fut
