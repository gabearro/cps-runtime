import cps/http/shared/http3_connection

let server = newHttp3Connection(isClient = false)
let client = newHttp3Connection(isClient = true)

var serverAcceptedInvalid = true
try:
  discard server.sendGoaway(1'u64)
except ValueError:
  serverAcceptedInvalid = false

echo "server_accepted_invalid_id=", serverAcceptedInvalid

var serverAcceptedIncrease = true
try:
  discard server.sendGoaway(8'u64)
  discard server.sendGoaway(12'u64)
except ValueError:
  serverAcceptedIncrease = false

echo "server_accepted_increasing=", serverAcceptedIncrease

var clientAcceptedIncrease = true
try:
  discard client.sendGoaway(6'u64)
  discard client.sendGoaway(7'u64)
except ValueError:
  clientAcceptedIncrease = false

echo "client_accepted_increasing=", clientAcceptedIncrease
