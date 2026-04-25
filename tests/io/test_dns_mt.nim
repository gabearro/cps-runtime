import cps/runtime
import cps/transform
import cps/eventloop
import cps/mt/mtruntime
import cps/io/dns

proc testDns(): CpsVoidFuture {.cps.} =
  echo "Resolving tracker.opentrackr.org..."
  let ip1 = await asyncResolve("tracker.opentrackr.org")
  echo "Resolved: " & ip1
  echo "Resolving torrent.ubuntu.com..."
  let ip2 = await asyncResolve("torrent.ubuntu.com")
  echo "Resolved: " & ip2
  echo "PASS"

# MT mode
let loop = initMtRuntime(numWorkers = 1, numBlockingThreads = 2)
runCps(testDns())
shutdownMtRuntime(loop)
