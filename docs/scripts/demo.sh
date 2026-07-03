#!/usr/bin/env bash
# Regenerate the README demo: a real freeze capture of `just --list`, the recipe
# catalog an operator meets first. Safe by construction — it lists the entrypoints
# without running any of them (no VM builds, no secrets, no network).
# Requires charmbracelet/freeze (`brew install freeze`) and pngquant; sips ships with macOS.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
freeze --execute "just --list" \
  --theme github-dark \
  --background "#0d1117" \
  --window \
  --padding 24 \
  --font.size 28 \
  --wrap 78 \
  --output "$tmp/demo.png"
# Downscale to a web-friendly width and quantize so the asset stays well under 1 MiB.
sips --resampleWidth 1800 "$tmp/demo.png" --out "$tmp/demo-small.png" >/dev/null
pngquant --force --quality 60-90 --output docs/assets/demo.png "$tmp/demo-small.png"
