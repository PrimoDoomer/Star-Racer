#!/usr/bin/env bash
# Download Godot addons listed in scripts/addons.lock into Client/addons/.
# Idempotent: skips an addon if its installed version matches the lock file.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$REPO_ROOT/scripts/addons.lock"
ADDONS_DIR="$REPO_ROOT/Client/addons"
STAMP_FILE_NAME=".addon-version"

mkdir -p "$ADDONS_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
need curl
need unzip

while read -r addon_id repo tag asset_name; do
  [[ -z "${addon_id:-}" || "$addon_id" =~ ^# ]] && continue

  target="$ADDONS_DIR/$addon_id"
  stamp="$target/$STAMP_FILE_NAME"
  expected="$repo@$tag@$asset_name"

  if [[ -f "$stamp" ]] && [[ "$(cat "$stamp")" == "$expected" ]]; then
    echo "[=] $addon_id already at $tag"
    continue
  fi

  url="https://github.com/$repo/releases/download/$tag/$asset_name"
  echo "[+] Fetching $addon_id ($repo $tag)"
  echo "    $url"

  archive="$TMP_DIR/$addon_id.zip"
  curl -fsSL -o "$archive" "$url"

  extract="$TMP_DIR/extract-$addon_id"
  mkdir -p "$extract"
  unzip -q "$archive" -d "$extract"

  src="$(find "$extract" -type d -name "$addon_id" -print -quit || true)"
  if [[ -z "$src" || ! -d "$src" ]]; then
    echo "    could not locate '$addon_id' folder inside archive" >&2
    exit 1
  fi

  rm -rf "$target"
  mkdir -p "$target"
  cp -R "$src/." "$target/"
  echo "$expected" > "$stamp"
  echo "    installed -> $target"
done < "$LOCK_FILE"

echo "Done."
