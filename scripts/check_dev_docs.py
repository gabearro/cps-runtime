#!/usr/bin/env python3
"""Fail when an exported Nim callable has no attached developer documentation."""

from __future__ import annotations

import re
import sys
from pathlib import Path


DECL = re.compile(
    r"^(?P<indent>\s*)(?P<kind>proc|func|method|iterator|template|macro|converter)"
    r"\s+(?P<name>`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)\*"
)
NEXT_DECL = re.compile(
    r"^(proc|func|method|iterator|template|macro|converter|"
    r"const|let|var|type|when)\b"
)


def body_equals(lines: list[str], start: int) -> tuple[int, int] | None:
    base_indent = len(lines[start]) - len(lines[start].lstrip())
    parens = brackets = braces = 0
    quote = ""
    escaped = False
    for line_index in range(start, min(len(lines), start + 80)):
        line = lines[line_index]
        if line_index > start and parens == brackets == braces == 0:
            stripped = line.strip()
            indent = len(line) - len(line.lstrip())
            if stripped and indent <= base_indent and NEXT_DECL.match(stripped):
                return None
        for column, char in enumerate(line):
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = ""
                continue
            if char == '"':
                quote = char
            elif char == "#":
                break
            elif char == "(":
                parens += 1
            elif char == ")":
                parens = max(0, parens - 1)
            elif char == "[":
                brackets += 1
            elif char == "]":
                brackets = max(0, brackets - 1)
            elif char == "{":
                braces += 1
            elif char == "}":
                braces = max(0, braces - 1)
            elif char == "=" and parens == brackets == braces == 0:
                return line_index, column
    return None


def documented(lines: list[str], start: int) -> bool:
    previous = start - 1
    while previous >= 0 and not lines[previous].strip():
        previous -= 1
    if previous >= 0 and lines[previous].lstrip().startswith("##"):
        return True

    location = body_equals(lines, start)
    if location is None:
        return False
    line_index, column = location
    if "##" in lines[line_index][column + 1 :]:
        return True
    for index in range(line_index + 1, min(len(lines), line_index + 12)):
        stripped = lines[index].strip()
        if not stripped:
            continue
        return stripped.startswith("##")
    return False


def main() -> int:
    source_root = Path(sys.argv[1] if len(sys.argv) > 1 else "src")
    missing: list[str] = []
    checked = 0
    for path in sorted(source_root.rglob("*.nim")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            match = DECL.match(line)
            if match:
                checked += 1
            if match and not documented(lines, index):
                missing.append(
                    f"{path}:{index + 1}: undocumented exported "
                    f"{match.group('kind')} {match.group('name')}"
                )
    if missing:
        print("\n".join(missing))
        print(f"\n{len(missing)} exported callable(s) need developer documentation.")
        return 1
    print(f"All {checked} exported callables have developer documentation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
