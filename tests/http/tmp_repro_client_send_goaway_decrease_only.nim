import cps/http/shared/http3_connection

let client = newHttp3Connection(isClient = true)
var acceptedDecrease = true
try:
  discard client.sendGoaway(10'u64)
  discard client.sendGoaway(6'u64)
except ValueError:
  acceptedDecrease = false

echo "client_accepted_decrease=", acceptedDecrease
