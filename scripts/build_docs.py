#!/usr/bin/env python3
"""Generate the package's HTML API reference with Nim's doc generator."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def search_paths() -> list[Path]:
    """Return local CPS and installed Nimble source roots."""
    result: set[Path] = {ROOT / "src"}
    for project in ROOT.parent.glob("cps-*"):
        if (project / "src").is_dir():
            result.add(project / "src")

    packages = Path.home() / ".nimble" / "pkgs2"
    if packages.is_dir():
        for package in packages.iterdir():
            if package.is_dir():
                result.add(package)
                if (package / "src").is_dir():
                    result.add(package / "src")
    return sorted(result)


def patch_doc_library(source: Path, destination: Path) -> None:
    """Keep Nim 2.2's doc mode on the host socket and selector backends."""
    shutil.copytree(source, destination)
    replacements = {
        destination / "pure" / "nativesockets.nim": (
            "const useWinVersion = defined(windows) or defined(nimdoc)",
            "const useWinVersion = defined(windows)",
        ),
        destination / "pure" / "net.nim": (
            "const useWinVersion = defined(windows) or defined(nimdoc)",
            "const useWinVersion = defined(windows)",
        ),
        destination / "pure" / "selectors.nim": (
            "when defined(nimdoc):",
            "when false:",
        ),
    }
    for path, (old, new) in replacements.items():
        text = path.read_text()
        if old in text:
            path.write_text(text.replace(old, new, 1))
    net = destination / "pure" / "net.nim"
    net.write_text(net.read_text().replace(
        "const defineSsl = defined(ssl) or defined(nimdoc)",
        "const defineSsl = defined(ssl)",
        1,
    ))


def main() -> None:
    nim = Path(shutil.which("nim") or "")
    if not nim:
        raise SystemExit("nim is required to generate the API reference")

    output = ROOT / "docs" / "api"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    modules = sorted((ROOT / "src").rglob("*.nim"))
    with tempfile.TemporaryDirectory(prefix="cps-nimdoc-") as temporary:
        temporary_root = Path(temporary)
        metadata = json.loads(subprocess.check_output(
            [str(nim), "dump", "--dump.format:json", str(modules[0])],
            cwd=ROOT,
            text=True,
        ))
        nim_library = Path(metadata["libpath"])
        patched_library = temporary_root / "lib"
        patch_doc_library(nim_library, patched_library)

        paths = [f"--path:{path}" for path in search_paths()]
        for number, module in enumerate(modules):
            subprocess.run(
                [
                    str(nim),
                    "doc",
                    "--index:on",
                    "--docCmd:skip",
                    f"--docRoot:{ROOT / 'src'}",
                    f"--lib:{patched_library}",
                    f"--outdir:{output}",
                    f"--nimcache:{temporary_root / f'cache-{number}'}",
                    *paths,
                    str(module),
                ],
                cwd=ROOT,
                check=True,
            )

    subprocess.run(
        [str(nim), "buildIndex", f"-o:{output / 'theindex.html'}", str(output)],
        cwd=ROOT,
        check=True,
    )
    print(f"Generated {len(modules)} module pages in {output}")


if __name__ == "__main__":
    main()
