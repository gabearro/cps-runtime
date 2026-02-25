## Generated UI constraint catalog. Do not edit manually.

proc enumConstraintValues*(ns: string, tag: string, attrName: string): string {.compileTime.} =
  let exact = ns & ":" & tag & ":" & attrName
  case exact
  of "html:a:target": "_blank, _parent, _self, _top"
  of "html:button:type": "button, reset, submit"
  of "html:form:method": "dialog, get, post"
  of "html:img:decoding": "async, auto, sync"
  of "html:img:fetchpriority": "auto, high, low"
  of "html:img:loading": "eager, lazy"
  of "html:input:type": "button, checkbox, color, date, datetime-local, email, file, hidden, image, month, number, password, radio, range, reset, search, submit, tel, text, time, url, week"
  of "html:ol:type": "1, A, I, a, i"
  of "html:script:type": "application/ld+json, importmap, module, text/javascript"
  of "html:track:kind": "captions, chapters, descriptions, metadata, subtitles"
  of "mathml:math:display": "block, inline"
  else:
    let wildcard = ns & ":*:" & attrName
    case wildcard
    of "html:*:crossorigin": ", anonymous, use-credentials"
    of "html:*:referrerpolicy": ", no-referrer, no-referrer-when-downgrade, origin, origin-when-cross-origin, same-origin, strict-origin, strict-origin-when-cross-origin, unsafe-url"
    of "svg:*:preserveAspectRatio": "none, xMaxYMax meet, xMaxYMax slice, xMaxYMid meet, xMaxYMid slice, xMaxYMin meet, xMaxYMin slice, xMidYMax meet, xMidYMax slice, xMidYMid meet, xMidYMid slice, xMidYMin meet, xMidYMin slice, xMinYMax meet, xMinYMax slice, xMinYMid meet, xMinYMid slice, xMinYMin meet, xMinYMin slice"
    else: ""

proc hasEnumConstraint*(ns: string, tag: string, attrName: string): bool {.compileTime.} =
  enumConstraintValues(ns, tag, attrName).len > 0

proc enumConstraintAllows*(ns: string, tag: string, attrName: string, value: string): bool {.compileTime.} =
  let exact = ns & ":" & tag & ":" & attrName
  case exact
  of "html:a:target":
    case value
    of "_blank", "_parent", "_self", "_top": true
    else: false
  of "html:button:type":
    case value
    of "button", "reset", "submit": true
    else: false
  of "html:form:method":
    case value
    of "dialog", "get", "post": true
    else: false
  of "html:img:decoding":
    case value
    of "async", "auto", "sync": true
    else: false
  of "html:img:fetchpriority":
    case value
    of "auto", "high", "low": true
    else: false
  of "html:img:loading":
    case value
    of "eager", "lazy": true
    else: false
  of "html:input:type":
    case value
    of "button", "checkbox", "color", "date", "datetime-local", "email", "file", "hidden", "image", "month", "number", "password", "radio", "range", "reset", "search", "submit", "tel", "text", "time", "url", "week": true
    else: false
  of "html:ol:type":
    case value
    of "1", "A", "I", "a", "i": true
    else: false
  of "html:script:type":
    case value
    of "application/ld+json", "importmap", "module", "text/javascript": true
    else: false
  of "html:track:kind":
    case value
    of "captions", "chapters", "descriptions", "metadata", "subtitles": true
    else: false
  of "mathml:math:display":
    case value
    of "block", "inline": true
    else: false
  else:
    let wildcard = ns & ":*:" & attrName
    case wildcard
    of "html:*:crossorigin":
      case value
      of "", "anonymous", "use-credentials": true
      else: false
    of "html:*:referrerpolicy":
      case value
      of "", "no-referrer", "no-referrer-when-downgrade", "origin", "origin-when-cross-origin", "same-origin", "strict-origin", "strict-origin-when-cross-origin", "unsafe-url": true
      else: false
    of "svg:*:preserveAspectRatio":
      case value
      of "none", "xMaxYMax meet", "xMaxYMax slice", "xMaxYMid meet", "xMaxYMid slice", "xMaxYMin meet", "xMaxYMin slice", "xMidYMax meet", "xMidYMax slice", "xMidYMid meet", "xMidYMid slice", "xMidYMin meet", "xMidYMin slice", "xMinYMax meet", "xMinYMax slice", "xMinYMid meet", "xMinYMid slice", "xMinYMin meet", "xMinYMin slice": true
      else: false
    else:
      true
