#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 scripts/generate_ui_schema.py

if ! git diff --quiet -- src/cps/ui/schema/generated src/cps/ui/js/event_names.generated.js; then
  echo "UI schema generated files are stale. Regenerate and commit these files:"
  git --no-pager diff -- src/cps/ui/schema/generated src/cps/ui/js/event_names.generated.js || true
  exit 1
fi

echo "UI schema generated files are up-to-date."
