## CPS - Continuation-Passing Style Async for Nim
##
## A macro-based CPS transformation library that converts normal
## Nim procedures into async continuations.
##
## Usage:
##   import cps
##
##   proc fetchData(url: string): CpsFuture[string] {.cps.} =
##     let response = await httpGet(url)
##     return response.body
##
##   runCps(fetchData("https://example.com"))

import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency

export runtime
export transform
export eventloop
export concurrency
