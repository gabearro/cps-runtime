## Stress test for MSE over uTP.
##
## Repeatedly exercises the callback path:
## uTP packet dispatch -> stream read completion -> MSE continuation.

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/timeouts
import cps/io/streams
import cps/bittorrent/mse
import cps/bittorrent/sha1
import cps/bittorrent/utp_stream

const
  ServerPort = 19820
  ClientPort = 19821
  Rounds = 300

proc makePayload(round: int, n: int): string =
  result = newString(n)
  var i = 0
  while i < n:
    result[i] = char(ord('a') + ((round + i) mod 26))
    inc i

proc serverHandshakeRound(serverStream: UtpStream,
                          infoHash: array[20, byte],
                          chunkSize: int,
                          expected: string): CpsVoidFuture {.cps, nosinks.} =
  let yaData: string = await readExactRaw(serverStream.AsyncStream, DhKeyLen)
  let sres: MseResult = await mseRespond(serverStream.AsyncStream, infoHash, yaData, true)
  let msg: string = await withTimeout(sres.stream.read(chunkSize), 5000)
  if msg != expected:
    raise newException(AsyncIoError, "payload mismatch")
  await sres.stream.write(msg)

proc runStress(): CpsVoidFuture {.cps, nosinks.} =
  let server: UtpManager = newUtpManager(ServerPort)
  let client: UtpManager = newUtpManager(ClientPort)
  let infoHash: array[20, byte] = sha1("mse-utp-stress")
  server.start()
  client.start()
  try:
    var round = 0
    while round < Rounds:
      let acceptFut: CpsFuture[UtpStream] = utpAccept(server)
      await cpsSleep(2)
      let clientStream: UtpStream = await withTimeout(
        utpConnect(client, "127.0.0.1", ServerPort, 3000), 5000)
      let serverStream: UtpStream = await withTimeout(acceptFut, 5000)

      let chunkSize = 5 + (round mod 29)
      let payload = makePayload(round, chunkSize)

      let serverFut = serverHandshakeRound(serverStream, infoHash, chunkSize, payload)

      let cres: MseResult = await mseInitiate(clientStream.AsyncStream, infoHash)
      await cres.stream.write(payload)
      let echoed: string = await withTimeout(cres.stream.read(chunkSize), 5000)
      assert echoed == payload
      await withTimeout(serverFut, 5000)

      clientStream.close()
      serverStream.close()
      inc round
  finally:
    client.close()
    server.close()

echo "MSE uTP stress test (" & $Rounds & " rounds)"
let fut = runStress()
let loop = getEventLoop()
var ticks = 0
while not fut.finished and ticks < 2_000_000:
  loop.tick()
  inc ticks

if fut.hasError:
  echo "ERROR: ", fut.getError().msg
  quit(1)
if not fut.finished:
  echo "TIMEOUT: runStress"
  quit(1)

echo "PASS: MSE uTP stress"
