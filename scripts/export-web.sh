#!/usr/bin/env bash
# Export the Godot client to a static HTML5/Web build, headless, on a
# terminal-only Linux server.
#
# Usage:
#   bash scripts/export-web.sh [output_dir]
#
# Environment overrides:
#   GODOT_BIN       Path to a Godot 4 binary. If unset, uses `godot` from PATH,
#                   otherwise downloads a headless build for $GODOT_VERSION.
#   GODOT_VERSION   Godot release to download/match (default: 4.6.3-stable).
#                   Export templates MUST match the editor version exactly.
#   OUT             Output directory (default: <repo>/build/web). The positional
#                   argument takes precedence over $OUT.
#   POCKET_RACING_CACHE Disk dir for the downloaded Godot binary, the template
#                   bundle, and all temp work (default: $HOME/.cache/pocket-racing-
#                   godot). Point it at a real-disk path — never tmpfs. The
#                   script forces $TMPDIR here so /tmp (often tmpfs on cloud VMs)
#                   is not used.
#
# After exporting, serve the folder over HTTP, e.g.:
#   python3 -m http.server --directory build/web 8000
# The "Web" preset is single-threaded (thread_support=false), so no special
# COOP/COEP cross-origin-isolation headers are required.

set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:-4.6.3-stable}"
PRESET="Web"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/client"
OUT_DIR="${1:-${OUT:-$REPO_ROOT/build/web}}"
# Cache lives on real disk (under $HOME). Override with POCKET_RACING_CACHE if $HOME
# is small/elsewhere. Must NOT point at tmpfs.
CACHE_DIR="${POCKET_RACING_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pocket-racing-godot}"

# Force all temp writes onto disk, not /tmp. On small cloud instances /tmp is
# usually tmpfs (RAM-backed, capped at ~half the RAM) and fills long before the
# real disk does — extracting the multi-hundred-MB template bundle there blows
# it up. This redirects our mktemp AND child processes (godot, unzip).
mkdir -p "$CACHE_DIR/tmp"
export TMPDIR="$CACHE_DIR/tmp"

# Templates version folder uses dots, e.g. "4.6.3-stable" -> "4.6.3.stable".
DOTVER="${GODOT_VERSION/-/.}"
TEMPLATES_DIR="${TEMPLATES_DIR:-$HOME/.local/share/godot/export_templates/$DOTVER}"

# Logs go to stderr so they never pollute stdout captured via $(resolve_godot).
log() { printf '[export-web] %s\n' "$*" >&2; }
die() { printf '[export-web] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

need curl
need unzip

[ -f "$CLIENT_DIR/project.godot" ] || die "client/project.godot not found (run from the repo, dir is '$CLIENT_DIR')"

# --- Resolve a Godot binary --------------------------------------------------
resolve_godot() {
	if [ -n "${GODOT_BIN:-}" ] && [ -x "$GODOT_BIN" ]; then
		echo "$GODOT_BIN"; return
	fi
	for c in godot godot4 Godot; do
		if command -v "$c" >/dev/null 2>&1; then echo "$(command -v "$c")"; return; fi
	done
	# Download a headless Linux build into the cache.
	local zip="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
	local bin="$CACHE_DIR/Godot_v${GODOT_VERSION}_linux.x86_64"
	if [ ! -x "$bin" ]; then
		mkdir -p "$CACHE_DIR"
		log "Downloading Godot $GODOT_VERSION ..."
		curl -fL -o "$CACHE_DIR/$zip" \
			"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${zip}"
		unzip -oq "$CACHE_DIR/$zip" -d "$CACHE_DIR"
		chmod +x "$bin"
	fi
	echo "$bin"
}

GODOT="$(resolve_godot)"
log "Using Godot: $GODOT ($("$GODOT" --version 2>/dev/null | head -n1))"

# --- Ensure WEB export templates --------------------------------------------
# Godot ships a single export-templates bundle (.tpz) that contains EVERY
# platform (android, ios, macos, windows, linux, web). We only need web, so we
# extract just the web templates — no iOS/Android/desktop files get installed.
# Copying every "web*" file also covers whichever variant this preset needs
# (extensions_support=true + thread_support=false -> dlink/nothreads).
mkdir -p "$TEMPLATES_DIR"
shopt -s nullglob
have_web=("$TEMPLATES_DIR"/web*)
shopt -u nullglob
if [ ${#have_web[@]} -eq 0 ]; then
	log "Web export templates for $DOTVER not found — installing into $TEMPLATES_DIR"
	tpz="$CACHE_DIR/Godot_v${GODOT_VERSION}_export_templates.tpz"
	mkdir -p "$CACHE_DIR"
	[ -f "$tpz" ] || curl -fL -o "$tpz" \
		"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_export_templates.tpz"
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	# Extract ONLY the web templates (the bundle's internal paths are templates/*).
	unzip -oq "$tpz" "templates/web*" -d "$tmp" || die "no web templates in bundle (unexpected .tpz layout)"
	unzip -oq "$tpz" "templates/version.txt" -d "$tmp" 2>/dev/null || true
	cp "$tmp"/templates/web* "$TEMPLATES_DIR/"
	[ -f "$tmp/templates/version.txt" ] && cp "$tmp/templates/version.txt" "$TEMPLATES_DIR/"
	log "Web templates installed (other platforms skipped)."
else
	log "Web export templates present at $TEMPLATES_DIR"
fi

# --- Import + export ---------------------------------------------------------
mkdir -p "$OUT_DIR"

log "Importing project (headless) ..."
( cd "$CLIENT_DIR" && "$GODOT" --headless --import ) || true

log "Exporting preset '$PRESET' -> $OUT_DIR/index.html"
( cd "$CLIENT_DIR" && "$GODOT" --headless --export-release "$PRESET" "$OUT_DIR/index.html" )

[ -f "$OUT_DIR/index.html" ] || die "export did not produce index.html (check the log above)"

log "Done. Build in: $OUT_DIR"
log "Serve it with:  python3 -m http.server --directory \"$OUT_DIR\" 8000"
