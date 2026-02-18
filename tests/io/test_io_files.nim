## Tests for CPS I/O file operations

import cps/eventloop
import cps/io/streams
import cps/io/files
import std/os

let tmpDir = getTempDir()

# Test 1: writeFile + readFile roundtrip
block testWriteReadFile:
  let path = tmpDir / "cps_test_file1.txt"
  let content = "Hello from CPS file I/O!\nLine 2\nLine 3"

  runCps(asyncWriteFile(path, content))

  let readBack = runCps(asyncReadFile(path))
  assert readBack == content, "File content mismatch"

  removeFile(path)
  echo "PASS: writeFile + readFile roundtrip"

# Test 2: Large file (multiple chunks)
block testLargeFile:
  let path = tmpDir / "cps_test_file2.txt"
  var content = ""
  for i in 0 ..< 5000:
    content.add("Line " & $i & " with some padding data here\n")

  runCps(asyncWriteFile(path, content))

  let readBack = runCps(asyncReadFile(path))
  assert readBack.len == content.len,
    "Length mismatch: expected " & $content.len & ", got " & $readBack.len
  assert readBack == content, "Content mismatch for large file"

  removeFile(path)
  echo "PASS: Large file roundtrip"

# Test 3: FileStream read
block testFileStreamRead:
  let path = tmpDir / "cps_test_file3.txt"
  writeFile(path, "stream test data")

  let fs = newFileStream(path, fmRead)
  let data = runCps(fs.AsyncStream.read(100))
  assert data == "stream test data", "Expected 'stream test data', got '" & data & "'"

  # Read again — should get EOF
  let data2 = runCps(fs.AsyncStream.read(100))
  assert data2 == "", "Expected EOF empty string"

  fs.AsyncStream.close()
  removeFile(path)
  echo "PASS: FileStream read"

# Test 4: FileStream write
block testFileStreamWrite:
  let path = tmpDir / "cps_test_file4.txt"
  let fs = newFileStream(path, fmWrite)

  runCps(fs.AsyncStream.write("written via"))
  runCps(fs.AsyncStream.write(" FileStream"))
  fs.AsyncStream.close()

  let content = runCps(asyncReadFile(path))
  assert content == "written via FileStream",
    "Expected 'written via FileStream', got '" & content & "'"

  removeFile(path)
  echo "PASS: FileStream write"

# Test 5: readFile on nonexistent file
block testReadNonexistent:
  let path = tmpDir / "cps_test_nonexistent_file.txt"
  let fut = asyncReadFile(path)
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
    if not fut.finished and not loop.hasWork:
      break
  assert fut.hasError(), "Reading nonexistent file should fail"
  echo "PASS: readFile nonexistent file"

echo "All file I/O tests passed!"
