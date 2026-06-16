#!/usr/bin/env bash
# Runs the whole test suite: Rust server tests + headless Godot client tests.
# Usage: bash scripts/run-tests.sh
#
# Override the Godot binary with the GODOT env var (default: "godot").
# Exits non-zero if any suite fails.

set -euo pipefail

RepoRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ServerDir="$RepoRoot/server"
ClientDir="$RepoRoot/client"
GODOT_BIN="${GODOT:-godot}"

echo "[run-tests] Server (cargo test)…"
( cd "$ServerDir" && cargo test )

echo "[run-tests] Client (Godot headless)…"
if ! command -v "$GODOT_BIN" &>/dev/null; then
    echo "[run-tests] Error: '$GODOT_BIN' not found. Set GODOT env var to the Godot executable path." >&2
    exit 1
fi
# First headless run imports assets (needed on a fresh checkout); ignore its code.
"$GODOT_BIN" --headless --path "$ClientDir" --import >/dev/null 2>&1 || true
"$GODOT_BIN" --headless --path "$ClientDir" --script res://tests/run_tests.gd

echo "[run-tests] All suites passed."
