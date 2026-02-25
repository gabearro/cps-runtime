## Generated UI attribute catalog. Do not edit manually.

import std/strutils

proc isGlobalOrDataAriaAttr*(attrName: string): bool {.compileTime.} =
  if attrName.startsWith("data-") or attrName.startsWith("aria-"):
    return true
  case attrName
  of "accesskey", "autocapitalize", "autofocus", "class", "contenteditable", "dir", "draggable", "enterkeyhint", "hidden", "id", "inert", "inputmode", "is", "itemid", "itemprop", "itemref", "itemscope", "itemtype", "lang", "nonce", "part", "popover", "role", "slot", "spellcheck", "style", "tabindex", "title", "translate", "virtualkeyboardpolicy", "xml:lang": true
  else: false

proc namespaceAllowsHtmlAttr*(tag: string, attrName: string): bool {.compileTime.} =
  case attrName
  of "accept", "accept-charset", "action", "align", "allow", "alt", "as", "async", "autocomplete", "autoplay", "charset", "checked", "cite", "colspan", "content", "controls", "coords", "crossorigin", "data", "datetime", "decoding", "default", "defer", "disabled", "download", "enctype", "fetchpriority", "for", "form", "headers", "height", "high", "href", "hreflang", "http-equiv", "integrity", "kind", "label", "list", "loading", "loop", "low", "max", "maxlength", "method", "min", "minlength", "multiple", "muted", "name", "novalidate", "open", "optimum", "pattern", "ping", "placeholder", "poster", "preload", "readonly", "referrerpolicy", "rel", "required", "reversed", "rows", "rowspan", "sandbox", "scope", "selected", "shape", "size", "sizes", "span", "src", "srcdoc", "srclang", "srcset", "start", "step", "target", "type", "usemap", "value", "width", "wrap":
    return true
  else:
    discard
  case tag
  of "a":
    case attrName
    of "download", "href", "hreflang", "ping", "referrerpolicy", "rel", "target", "type": true
    else: false
  of "audio":
    case attrName
    of "autoplay", "controls", "crossorigin", "loop", "muted", "preload", "src": true
    else: false
  of "button":
    case attrName
    of "disabled", "form", "name", "type", "value": true
    else: false
  of "col":
    case attrName
    of "span", "width": true
    else: false
  of "colgroup":
    case attrName
    of "span": true
    else: false
  of "details":
    case attrName
    of "open": true
    else: false
  of "dialog":
    case attrName
    of "open": true
    else: false
  of "form":
    case attrName
    of "action", "autocomplete", "enctype", "method", "novalidate", "target": true
    else: false
  of "iframe":
    case attrName
    of "allow", "allowfullscreen", "height", "loading", "name", "referrerpolicy", "sandbox", "src", "srcdoc", "width": true
    else: false
  of "img":
    case attrName
    of "alt", "crossorigin", "decoding", "fetchpriority", "height", "ismap", "loading", "referrerpolicy", "sizes", "src", "srcset", "usemap", "width": true
    else: false
  of "input":
    case attrName
    of "accept", "alt", "autocomplete", "checked", "dirname", "disabled", "form", "height", "list", "max", "maxlength", "min", "minlength", "multiple", "name", "pattern", "placeholder", "readonly", "required", "size", "src", "step", "type", "value", "width": true
    else: false
  of "label":
    case attrName
    of "for": true
    else: false
  of "li":
    case attrName
    of "value": true
    else: false
  of "link":
    case attrName
    of "as", "crossorigin", "fetchpriority", "href", "hreflang", "imagesizes", "imagesrcset", "integrity", "media", "referrerpolicy", "rel", "sizes", "type": true
    else: false
  of "meta":
    case attrName
    of "charset", "content", "http-equiv", "name": true
    else: false
  of "meter":
    case attrName
    of "high", "low", "max", "min", "optimum", "value": true
    else: false
  of "ol":
    case attrName
    of "reversed", "start", "type": true
    else: false
  of "option":
    case attrName
    of "disabled", "label", "selected", "value": true
    else: false
  of "progress":
    case attrName
    of "max", "value": true
    else: false
  of "script":
    case attrName
    of "async", "crossorigin", "defer", "integrity", "nomodule", "referrerpolicy", "src", "type": true
    else: false
  of "select":
    case attrName
    of "autocomplete", "disabled", "form", "multiple", "name", "required", "size": true
    else: false
  of "source":
    case attrName
    of "height", "media", "sizes", "src", "srcset", "type", "width": true
    else: false
  of "table":
    case attrName
    of "border": true
    else: false
  of "td":
    case attrName
    of "colspan", "headers", "rowspan": true
    else: false
  of "textarea":
    case attrName
    of "autocomplete", "cols", "dirname", "disabled", "form", "maxlength", "minlength", "name", "placeholder", "readonly", "required", "rows", "wrap": true
    else: false
  of "th":
    case attrName
    of "abbr", "colspan", "headers", "rowspan", "scope": true
    else: false
  of "time":
    case attrName
    of "datetime": true
    else: false
  of "track":
    case attrName
    of "default", "kind", "label", "src", "srclang": true
    else: false
  of "video":
    case attrName
    of "autoplay", "controls", "crossorigin", "height", "loop", "muted", "playsinline", "poster", "preload", "src", "width": true
    else: false
  else:
    false

proc namespaceAllowsSvgAttr*(tag: string, attrName: string): bool {.compileTime.} =
  case attrName
  of "accent-height", "alignment-baseline", "baseline-shift", "clip", "clip-path", "clip-rule", "color", "color-interpolation", "color-rendering", "cx", "cy", "d", "direction", "display", "dominant-baseline", "fill", "fill-opacity", "fill-rule", "filter", "flood-color", "flood-opacity", "font-family", "font-size", "font-style", "font-weight", "fx", "fy", "gradientTransform", "gradientUnits", "height", "href", "id", "marker-end", "marker-mid", "marker-start", "mask", "offset", "opacity", "pathLength", "patternContentUnits", "patternTransform", "patternUnits", "points", "preserveAspectRatio", "r", "refX", "refY", "rx", "ry", "spreadMethod", "stop-color", "stop-opacity", "stroke", "stroke-dasharray", "stroke-dashoffset", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width", "transform", "viewBox", "width", "x", "x1", "x2", "xmlns", "xmlns:xlink", "y", "y1", "y2":
    return true
  else:
    discard
  case tag
  of "circle":
    case attrName
    of "cx", "cy", "r": true
    else: false
  of "ellipse":
    case attrName
    of "cx", "cy", "rx", "ry": true
    else: false
  of "foreignObject":
    case attrName
    of "height", "width", "x", "y": true
    else: false
  of "g":
    case attrName
    of "transform": true
    else: false
  of "image":
    case attrName
    of "crossorigin", "height", "href", "preserveAspectRatio", "width", "x", "y": true
    else: false
  of "line":
    case attrName
    of "x1", "x2", "y1", "y2": true
    else: false
  of "linearGradient":
    case attrName
    of "gradientTransform", "gradientUnits", "x1", "x2", "y1", "y2": true
    else: false
  of "path":
    case attrName
    of "d", "pathLength": true
    else: false
  of "polygon":
    case attrName
    of "points": true
    else: false
  of "polyline":
    case attrName
    of "points": true
    else: false
  of "radialGradient":
    case attrName
    of "cx", "cy", "fx", "fy", "gradientTransform", "gradientUnits", "r": true
    else: false
  of "rect":
    case attrName
    of "height", "rx", "ry", "width", "x", "y": true
    else: false
  of "stop":
    case attrName
    of "offset", "stop-color", "stop-opacity": true
    else: false
  of "svg":
    case attrName
    of "height", "preserveAspectRatio", "viewBox", "width", "xmlns", "xmlns:xlink": true
    else: false
  of "text":
    case attrName
    of "dx", "dy", "lengthAdjust", "textLength", "x", "y": true
    else: false
  of "use":
    case attrName
    of "height", "href", "width", "x", "y": true
    else: false
  else:
    false

proc namespaceAllowsMathmlAttr*(tag: string, attrName: string): bool {.compileTime.} =
  case attrName
  of "display", "displaystyle", "href", "id", "mathbackground", "mathcolor", "mathsize", "mathvariant", "scriptlevel":
    return true
  else:
    discard
  case tag
  of "math":
    case attrName
    of "display", "xmlns": true
    else: false
  of "mfrac":
    case attrName
    of "denomalign", "linethickness", "numalign": true
    else: false
  of "mi":
    case attrName
    of "mathvariant": true
    else: false
  of "mn":
    case attrName
    of "mathvariant": true
    else: false
  of "mo":
    case attrName
    of "accent", "fence", "form", "lspace", "maxsize", "minsize", "movablelimits", "rspace", "separator", "stretchy", "symmetric": true
    else: false
  of "mover":
    case attrName
    of "accent": true
    else: false
  of "mroot":
    false
  of "msqrt":
    false
  of "msub":
    false
  of "msubsup":
    false
  of "msup":
    false
  of "mtable":
    case attrName
    of "columnalign", "columnlines", "columnspacing", "equalcolumns", "equalrows", "frame", "framespacing", "rowalign", "rowlines", "rowspacing": true
    else: false
  of "mtd":
    case attrName
    of "columnalign", "columnspan", "rowalign", "rowspan": true
    else: false
  of "mtr":
    false
  of "munder":
    case attrName
    of "accentunder": true
    else: false
  of "munderover":
    case attrName
    of "accent", "accentunder": true
    else: false
  else:
    false

proc isAllowedAttrForElement*(ns: string, tag: string, attrName: string): bool {.compileTime.} =
  if isGlobalOrDataAriaAttr(attrName):
    return true
  case ns
  of "html": namespaceAllowsHtmlAttr(tag, attrName)
  of "svg": namespaceAllowsSvgAttr(tag, attrName)
  of "mathml": namespaceAllowsMathmlAttr(tag, attrName)
  else: false
