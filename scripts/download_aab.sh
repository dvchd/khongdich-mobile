#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-dvchd/khongdich-mobile}"
OUT="${1:-release}"
TAG="${2:-}"

mkdir -p "$OUT"

if [ -n "$TAG" ]; then
  gh release download "$TAG" --repo "$REPO" --pattern '*.aab' --dir "$OUT"
else
  TAG=$(gh release list --repo "$REPO" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || true)
  if [ -n "$TAG" ]; then
    gh release download "$TAG" --repo "$REPO" --pattern '*.aab' --dir "$OUT"
  fi
fi

aab=$(ls -t "$OUT"/*.aab 2>/dev/null | head -1)
if [ -z "$aab" ]; then
  echo "Không tải được AAB (kiểm tra tag/release hoặc network)" >&2
  exit 1
fi

realpath "$aab"
