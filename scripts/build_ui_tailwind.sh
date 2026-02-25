#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

INPUT_CSS="${1:-$PROJECT_DIR/examples/ui/test_spa.tailwind.input.css}"
OUTPUT_CSS="${2:-$PROJECT_DIR/examples/ui/test_spa.tailwind.css}"
CONFIG_FILE="${3:-$PROJECT_DIR/examples/ui/tailwind.config.cjs}"

if [[ ! -f "$INPUT_CSS" ]]; then
  echo "Tailwind input not found: $INPUT_CSS" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Tailwind config not found: $CONFIG_FILE" >&2
  exit 1
fi

echo "Building Tailwind CSS:"
echo "  input:  $INPUT_CSS"
echo "  output: $OUTPUT_CSS"
echo "  config: $CONFIG_FILE"

npx --yes tailwindcss@3.4.17 \
  -c "$CONFIG_FILE" \
  -i "$INPUT_CSS" \
  -o "$OUTPUT_CSS" \
  --minify

echo "Tailwind CSS build complete."
