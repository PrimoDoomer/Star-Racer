#!/usr/bin/env bash
# Launches the server, the bots, and the Godot client.
# Usage: bash scripts/run-all.sh [--release]
#
# Override the Godot binary with the GODOT env var (default: "godot").

set -euo pipefail

RepoRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ServerDir="$RepoRoot/Server"
ClientDir="$RepoRoot/Client"
GODOT_BIN="${GODOT:-godot}"

if ! command -v "$GODOT_BIN" &>/dev/null; then
    echo "[run-all] Error: '$GODOT_BIN' not found. Set GODOT env var to the Godot executable path." >&2
    exit 1
fi

CARGO_PROFILE_FLAG=""
TARGET="debug"
if [[ "${1:-}" == "--release" ]]; then
    CARGO_PROFILE_FLAG="--release"
    TARGET="release"
fi

server_log=""
pids=()
display_pids=()

cleanup() {
    echo
    echo "[run-all] Stopping child processes…"
    for pid in "${display_pids[@]+"${display_pids[@]}"}" "${pids[@]+"${pids[@]}"}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    [[ -n "$server_log" ]] && rm -f "$server_log"
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[run-all] Building binaries…"
( cd "$ServerDir" && cargo build $CARGO_PROFILE_FLAG --bin server --bin bots )

echo "[run-all] Starting server…"
server_log=$(mktemp)
"$ServerDir/target/$TARGET/server" >"$server_log" 2>&1 &
pids+=($!)
tail -f "$server_log" &
display_pids+=($!)

echo "[run-all] Waiting for 'core loop spawned'…"
deadline=$((SECONDS + 60))
server_ready=false
while [[ $SECONDS -lt $deadline ]]; do
    if grep -q 'core loop spawned' "$server_log" 2>/dev/null; then
        server_ready=true
        break
    fi
    sleep 0.3
done
$server_ready || echo "[run-all] WARNING: Ready signal not seen after 60 s, proceeding anyway." >&2

echo "[run-all] Starting bots…"
"$ServerDir/target/$TARGET/bots" >/dev/null 2>&1 &
pids+=($!)

BOT_WARMUP="${BOT_WARMUP:-6}"
echo "[run-all] Letting bots settle for ${BOT_WARMUP}s…"
sleep "$BOT_WARMUP"

echo "[run-all] Starting Godot client ($GODOT_BIN)…"
( cd "$ClientDir" && "$GODOT_BIN" --path "$ClientDir" ) &
godot_pid=$!
pids+=($godot_pid)
sleep 2
if ! kill -0 "$godot_pid" 2>/dev/null; then
    echo "[run-all] ERROR: Godot exited immediately. Run manually to diagnose: $GODOT_BIN --path \"$ClientDir\"" >&2
fi

echo "[run-all] All processes launched. Ctrl+C to stop."
wait
