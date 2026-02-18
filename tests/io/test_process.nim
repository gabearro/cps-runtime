## Tests for CPS I/O Process

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/process
import std/strutils

# ============================================================
# Test 1: Simple exec - echo "hello" -> stdout contains "hello"
# ============================================================

proc testSimpleExecTask(): CpsFuture[tuple[exitCode: int, stdout: string, stderr: string]] {.cps.} =
  let r = await exec("/bin/echo", @["hello"])
  return r

block testSimpleExec:
  let fut = testSimpleExecTask()
  let r = runCps(fut)
  assert r.exitCode == 0, "Expected exit code 0, got " & $r.exitCode
  assert r.stdout.strip() == "hello", "Expected 'hello' in stdout, got '" & r.stdout & "'"
  echo "PASS: Simple exec (echo hello)"

# ============================================================
# Test 2: Exit code - `false` -> exitCode != 0
# ============================================================

proc testExitCodeTask(): CpsFuture[int] {.cps.} =
  let r = await exec("/usr/bin/false")
  return r.exitCode

block testExitCode:
  let fut = testExitCodeTask()
  let code = runCps(fut)
  assert code != 0, "Expected non-zero exit code from 'false', got " & $code
  echo "PASS: Exit code (false -> non-zero)"

# ============================================================
# Test 3: Stdin piping - pipe data to cat
# ============================================================

proc testStdinPipeTask(): CpsFuture[string] {.cps.} =
  let r = await exec("/bin/cat", input = "piped input data")
  return r.stdout

block testStdinPipe:
  let fut = testStdinPipeTask()
  let output = runCps(fut)
  assert output == "piped input data", "Expected 'piped input data', got '" & output & "'"
  echo "PASS: Stdin piping (cat)"

# ============================================================
# Test 4: Large output
# ============================================================

proc testLargeOutputTask(): CpsFuture[string] {.cps.} =
  # Generate 10000 lines of output
  let r = await exec("/usr/bin/seq", @["1", "10000"])
  return r.stdout

block testLargeOutput:
  let fut = testLargeOutputTask()
  let output = runCps(fut)
  # seq 1 10000 should produce "1\n2\n...\n10000\n"
  let lines = output.strip().split('\n')
  assert lines.len == 10000, "Expected 10000 lines, got " & $lines.len
  assert lines[0] == "1", "First line should be '1', got '" & lines[0] & "'"
  assert lines[^1] == "10000", "Last line should be '10000', got '" & lines[^1] & "'"
  echo "PASS: Large output (seq 1 10000)"

# ============================================================
# Test 5: Stderr capture
# ============================================================

proc testStderrCaptureTask(): CpsFuture[tuple[exitCode: int, stdout: string, stderr: string]] {.cps.} =
  # Use sh -c to write to stderr
  let r = await exec("/bin/sh", @["-c", "echo error_msg >&2"])
  return r

block testStderrCapture:
  let fut = testStderrCaptureTask()
  let r = runCps(fut)
  assert r.stderr.strip() == "error_msg", "Expected 'error_msg' on stderr, got '" & r.stderr & "'"
  echo "PASS: Stderr capture"

# ============================================================
# Test 6: Kill a process
# ============================================================

proc testKillProcessTask(): CpsFuture[int] {.cps.} =
  let p = startProcess("/bin/sleep", @["60"])
  p.kill()
  let code = await p.wait()
  return code

block testKillProcess:
  let fut = testKillProcessTask()
  let code = runCps(fut)
  # SIGTERM = signal 15, exit code should be negative (signal number)
  assert code < 0, "Expected negative exit code (killed by signal), got " & $code
  echo "PASS: Kill process"

# ============================================================
# Test 7: exec convenience function (execOutput)
# ============================================================

proc testExecOutputTask(): CpsFuture[string] {.cps.} =
  let output = await execOutput("/bin/echo", @["convenience test"])
  return output

block testExecOutput:
  let fut = testExecOutputTask()
  let output = runCps(fut)
  assert output.strip() == "convenience test", "Expected 'convenience test', got '" & output & "'"
  echo "PASS: execOutput convenience function"

# ============================================================
# Test 8: Wait on already-exited process
# ============================================================

proc testWaitAlreadyExitedTask(): CpsFuture[int] {.cps.} =
  # Use exec which already waits for completion internally, verifying
  # the internal wait/poll mechanism works end-to-end. Then test that
  # calling wait() after the process has exited returns immediately.
  let p = startProcess("/usr/bin/true")
  # First wait: process likely still running, polls until exit
  let code1 = await p.wait()
  # Second wait: process already exited, should return immediately
  let code2 = await p.wait()
  assert code1 == code2, "Both waits should return same exit code"
  return code2

block testWaitAlreadyExited:
  let fut = testWaitAlreadyExitedTask()
  let code = runCps(fut)
  assert code == 0, "Expected exit code 0 from 'true', got " & $code
  echo "PASS: Wait on already-exited process"

echo "All process tests passed!"
