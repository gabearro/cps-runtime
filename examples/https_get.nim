## Example: HTTPS GET request using CPS
##
## Demonstrates using the CPS HTTPS client to make requests.
## Automatically negotiates HTTP/1.1 or HTTP/2.

import cps
import cps/httpclient

proc main() =
  let client = newHttpsClient()

  echo "=== CPS HTTPS Client Example ==="
  echo ""

  # Make an HTTPS GET request
  echo "Fetching https://example.com ..."
  let resp = runCps(client.get("https://example.com"))

  echo "HTTP Version: ", resp.httpVersion
  echo "Status: ", resp.statusCode
  echo "Headers:"
  for (k, v) in resp.headers:
    echo "  ", k, ": ", v
  echo "Body length: ", resp.body.len
  echo "Body (first 200 chars):"
  if resp.body.len > 200:
    echo resp.body[0..199], "..."
  else:
    echo resp.body

main()
