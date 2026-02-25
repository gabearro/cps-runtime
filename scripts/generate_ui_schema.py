#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_DIR = ROOT / "src" / "cps" / "ui" / "schema"
GENERATED_DIR = SCHEMA_DIR / "generated"
JS_DIR = ROOT / "src" / "cps" / "ui" / "js"


def load_json(name: str):
    with (SCHEMA_DIR / name).open("r", encoding="utf-8") as f:
        return json.load(f)


def q(s: str) -> str:
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def case_true(values: list[str], indent: str = "  ") -> list[str]:
    if not values:
        return [f"{indent}else: false"]
    grouped = ", ".join(q(v) for v in values)
    return [f"{indent}of {grouped}: true", f"{indent}else: false"]


def emit_event_files(events: list[dict]):
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    ids = [e["id"] for e in events]
    dom_names = [e["dom"] for e in events]
    dsl_names: list[str] = []
    for e in events:
        dsl_names.append(e["dsl"])
        for alias in e.get("aliases", []):
            dsl_names.append(alias)

    enum_lines: list[str] = []
    enum_lines.append("## Generated UI event enum. Do not edit manually.")
    enum_lines.append("")
    enum_lines.append("type")
    enum_lines.append("  EventType* = enum")
    for event_id in ids:
      enum_lines.append(f"    {event_id},")
    (GENERATED_DIR / "event_type.nim").write_text("\n".join(enum_lines) + "\n", encoding="utf-8")

    event_items = ["  " + e + "," for e in ids]
    (GENERATED_DIR / "event_type_items.nim").write_text("\n".join(event_items) + "\n", encoding="utf-8")

    lines: list[str] = []
    lines.append("## Generated UI event metadata. Do not edit manually.")
    lines.append("")
    lines.append("const domEventNamesByCode* = [")
    for dom in dom_names:
        lines.append(f"  {q(dom)},")
    lines.append("]")
    lines.append("")
    lines.append("const dslEventNames* = [")
    for dsl_name in dsl_names:
        lines.append(f"  {q(dsl_name)},")
    lines.append("]")
    lines.append("")
    lines.append("proc eventDomNameByCode*(code: int32): string =")
    lines.append("  if code < 0 or code >= domEventNamesByCode.len.int32:")
    lines.append("    return domEventNamesByCode[0]")
    lines.append("  domEventNamesByCode[code]")
    lines.append("")
    lines.append("proc dslEventLookup*(name: string, eventId: var string, capture: var bool): bool {.compileTime.} =")
    lines.append("  case name")
    for e in events:
        aliases = [e["dsl"]] + e.get("aliases", [])
        for alias in aliases:
            lines.append(f"  of {q(alias)}:")
            lines.append(f"    eventId = {q(e['id'])}")
            lines.append("    capture = false")
            lines.append("    true")
            lines.append(f"  of {q(alias + 'Capture')}:")
            lines.append(f"    eventId = {q(e['id'])}")
            lines.append("    capture = true")
            lines.append("    true")
    lines.append("  else:")
    lines.append("    false")
    lines.append("")
    lines.append("proc isKnownDslEventName*(name: string): bool {.compileTime.} =")
    lines.append("  var eventId = \"\"")
    lines.append("  var capture = false")
    lines.append("  dslEventLookup(name, eventId, capture)")
    lines.append("")
    lines.append("proc eventIdFromName*(name: string): int32 =")
    lines.append("  case name")
    for i, e in enumerate(events):
        lines.append(f"  of {q(e['id'])}: {i}.int32")
    lines.append("  else: 0'i32")

    (GENERATED_DIR / "events.nim").write_text("\n".join(lines) + "\n", encoding="utf-8")

    js_lines = ["// Generated from src/cps/ui/schema/events.json. Do not edit manually.", "export const EVENT_NAMES = ["]
    for dom in dom_names:
        js_lines.append(f"  {q(dom)},")
    js_lines.append("];\n")
    (JS_DIR / "event_names.generated.js").write_text("\n".join(js_lines), encoding="utf-8")


def emit_elements_file(html: list[str], svg: list[str], mathml: list[str]):
    html_sorted = sorted(dict.fromkeys(html))
    svg_sorted = sorted(dict.fromkeys(svg))
    math_sorted = sorted(dict.fromkeys(mathml))
    all_sorted = sorted(dict.fromkeys(html_sorted + svg_sorted + math_sorted))

    lines: list[str] = []
    lines.append("## Generated UI element catalog. Do not edit manually.")
    lines.append("")
    lines.append("const htmlElementNames* = [")
    for name in html_sorted:
        lines.append(f"  {q(name)},")
    lines.append("]")
    lines.append("")
    lines.append("const svgElementNames* = [")
    for name in svg_sorted:
        lines.append(f"  {q(name)},")
    lines.append("]")
    lines.append("")
    lines.append("const mathmlElementNames* = [")
    for name in math_sorted:
        lines.append(f"  {q(name)},")
    lines.append("]")
    lines.append("")
    lines.append("const standardElementNames* = [")
    for name in all_sorted:
        lines.append(f"  {q(name)},")
    lines.append("]")
    lines.append("")
    lines.append("proc isKnownHtmlElement*(name: string): bool {.compileTime.} =")
    lines.append("  case name")
    lines.extend(case_true(html_sorted, "  "))
    lines.append("")
    lines.append("proc isKnownSvgElement*(name: string): bool {.compileTime.} =")
    lines.append("  case name")
    lines.extend(case_true(svg_sorted, "  "))
    lines.append("")
    lines.append("proc isKnownMathmlElement*(name: string): bool {.compileTime.} =")
    lines.append("  case name")
    lines.extend(case_true(math_sorted, "  "))
    lines.append("")
    lines.append("proc isKnownStandardElement*(name: string): bool {.compileTime.} =")
    lines.append("  isKnownHtmlElement(name) or isKnownSvgElement(name) or isKnownMathmlElement(name)")
    lines.append("")
    lines.append("proc elementNamespace*(name: string): string {.compileTime.} =")
    lines.append("  if isKnownHtmlElement(name):")
    lines.append("    return \"html\"")
    lines.append("  if isKnownSvgElement(name):")
    lines.append("    return \"svg\"")
    lines.append("  if isKnownMathmlElement(name):")
    lines.append("    return \"mathml\"")
    lines.append("  \"\"")

    (GENERATED_DIR / "elements.nim").write_text("\n".join(lines) + "\n", encoding="utf-8")


def emit_attrs_file(global_attrs: list[str], attrs_by_element: dict):
    global_sorted = sorted(dict.fromkeys(global_attrs))

    html = attrs_by_element.get("html", {})
    svg = attrs_by_element.get("svg", {})
    mathml = attrs_by_element.get("mathml", {})

    def emit_namespace(lines: list[str], ns_name: str, data: dict):
        common = sorted(dict.fromkeys(data.get("*", [])))
        lines.append(f"proc namespaceAllows{ns_name}Attr*(tag: string, attrName: string): bool {{.compileTime.}} =")
        if common:
            lines.append("  case attrName")
            lines.append("  of " + ", ".join(q(v) for v in common) + ":")
            lines.append("    return true")
            lines.append("  else:")
            lines.append("    discard")
        lines.append("  case tag")
        keys = sorted(k for k in data.keys() if k != "*")
        for k in keys:
            vals = sorted(dict.fromkeys(data[k]))
            if not vals:
                lines.append(f"  of {q(k)}:")
                lines.append("    false")
                continue
            lines.append(f"  of {q(k)}:")
            lines.append("    case attrName")
            lines.extend(case_true(vals, "    "))
        lines.append("  else:")
        lines.append("    false")
        lines.append("")

    lines: list[str] = []
    lines.append("## Generated UI attribute catalog. Do not edit manually.")
    lines.append("")
    lines.append("import std/strutils")
    lines.append("")
    lines.append("proc isGlobalOrDataAriaAttr*(attrName: string): bool {.compileTime.} =")
    lines.append("  if attrName.startsWith(\"data-\") or attrName.startsWith(\"aria-\"):")
    lines.append("    return true")
    lines.append("  case attrName")
    lines.extend(case_true(global_sorted, "  "))
    lines.append("")

    emit_namespace(lines, "Html", html)
    emit_namespace(lines, "Svg", svg)
    emit_namespace(lines, "Mathml", mathml)

    lines.append("proc isAllowedAttrForElement*(ns: string, tag: string, attrName: string): bool {.compileTime.} =")
    lines.append("  if isGlobalOrDataAriaAttr(attrName):")
    lines.append("    return true")
    lines.append("  case ns")
    lines.append("  of \"html\": namespaceAllowsHtmlAttr(tag, attrName)")
    lines.append("  of \"svg\": namespaceAllowsSvgAttr(tag, attrName)")
    lines.append("  of \"mathml\": namespaceAllowsMathmlAttr(tag, attrName)")
    lines.append("  else: false")

    (GENERATED_DIR / "attrs.nim").write_text("\n".join(lines) + "\n", encoding="utf-8")


def emit_constraints_file(constraints: dict):
    enum_constraints = constraints.get("enumConstraints", [])

    exact_map: dict[tuple[str, str, str], list[str]] = {}
    wildcard_map: dict[tuple[str, str], list[str]] = {}

    for entry in enum_constraints:
        ns = entry["namespace"].strip().lower()
        elem = entry["element"].strip()
        attr = entry["attr"].strip()
        vals = sorted(dict.fromkeys(str(v) for v in entry.get("values", [])))
        if elem == "*":
            wildcard_map[(ns, attr)] = vals
        else:
            exact_map[(ns, elem, attr)] = vals

    lines: list[str] = []
    lines.append("## Generated UI constraint catalog. Do not edit manually.")
    lines.append("")
    lines.append("proc enumConstraintValues*(ns: string, tag: string, attrName: string): string {.compileTime.} =")
    lines.append("  let exact = ns & \":\" & tag & \":\" & attrName")
    lines.append("  case exact")
    for (ns, tag, attr), vals in sorted(exact_map.items()):
        csv = ", ".join(vals)
        lines.append(f"  of {q(ns + ':' + tag + ':' + attr)}: {q(csv)}")
    lines.append("  else:")
    lines.append("    let wildcard = ns & \":*:\" & attrName")
    lines.append("    case wildcard")
    for (ns, attr), vals in sorted(wildcard_map.items()):
        csv = ", ".join(vals)
        lines.append(f"    of {q(ns + ':*:' + attr)}: {q(csv)}")
    lines.append("    else: \"\"")
    lines.append("")

    lines.append("proc hasEnumConstraint*(ns: string, tag: string, attrName: string): bool {.compileTime.} =")
    lines.append("  enumConstraintValues(ns, tag, attrName).len > 0")
    lines.append("")

    lines.append("proc enumConstraintAllows*(ns: string, tag: string, attrName: string, value: string): bool {.compileTime.} =")
    lines.append("  let exact = ns & \":\" & tag & \":\" & attrName")
    lines.append("  case exact")
    for (ns, tag, attr), vals in sorted(exact_map.items()):
        joined = ", ".join(q(v) for v in vals)
        lines.append(f"  of {q(ns + ':' + tag + ':' + attr)}:")
        lines.append("    case value")
        lines.append(f"    of {joined}: true")
        lines.append("    else: false")
    lines.append("  else:")
    lines.append("    let wildcard = ns & \":*:\" & attrName")
    lines.append("    case wildcard")
    for (ns, attr), vals in sorted(wildcard_map.items()):
        joined = ", ".join(q(v) for v in vals)
        lines.append(f"    of {q(ns + ':*:' + attr)}:")
        lines.append("      case value")
        lines.append(f"      of {joined}: true")
        lines.append("      else: false")
    lines.append("    else:")
    lines.append("      true")

    (GENERATED_DIR / "constraints.nim").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    html = load_json("elements_html.json")
    svg = load_json("elements_svg.json")
    mathml = load_json("elements_mathml.json")
    events = load_json("events.json")
    global_attrs = load_json("attributes_global.json")
    attrs_by_element = load_json("attributes_by_element.json")
    constraints = load_json("constraints.json")

    emit_event_files(events)
    emit_elements_file(html, svg, mathml)
    emit_attrs_file(global_attrs, attrs_by_element)
    emit_constraints_file(constraints)


if __name__ == "__main__":
    main()
