## CPS I/O Library
##
## Re-exports all I/O modules for convenient single-import usage.

import cps/io/[streams, tcp, udp, buffered, files, timeouts, dns, proxy, nat]
export streams, tcp, udp, buffered, files, timeouts, dns, proxy, nat

when defined(posix):
  import cps/io/[unix, process]
  export unix, process
