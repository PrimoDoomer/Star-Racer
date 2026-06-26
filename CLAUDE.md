# CLAUDE.md — Pocket Racing

Project guidance for working in this repo. Personal/global preferences live in
each dev's `~/.claude/CLAUDE.md`; this file is the shared, versioned project brain.

## What this is

Pocket Racing — a multiplayer 3D arcade racer. Theme: **toy-scale cars racing in
giant indoor rooms** (Toy Commander vibe). Authoritative Rust server + Godot 4.7
client.

Renamed from "Star Racer" to "Pocket Racing". The rename is complete across the
client, the server crate (`pocket-racing-server`), the build/deploy tooling, and
the client↔server protocol (the drift input-action id + protocol field went
`Star Drift`/`star_drift` → `Drift`/`drift` in lockstep on both sides).

One off-repo coupling remains: the deploy forced-command is `pocket-racing-deploy`
(`.github/workflows/deploy.yml`), which must match the forced command configured in
the server's `~/.ssh/authorized_keys`. GitHub repo: `pagoyadev/Pocket-Racing`.

## Architecture

- **Server (`server/`)** — Rust, authoritative simulation. Physics `rapier3d-f64`,
  WebSockets `tokio-tungstenite`, `tokio` runtime. Fixed timestep 1/60, accumulator
  loop (`src/run.rs`). Bins: `server`, `bots`. `#![forbid(unsafe_code)]`.
- **Client (`client/`)** — Godot 4.7 (Forward+), GDScript, built-in GodotPhysics3D.
  **No addons / GDExtensions.** Thin presentation layer: local prediction in
  `player.gd`, reconciled toward server-sent positions. Autoloads: `Locale`,
  `Bindings`.
- **Protocol (`server/src/protocol.rs`)** — serde JSON. `ClientMessage`
  (`Request` | `State{throttle, steer_left, steer_right, drift}`),
  `ServerMessage` (`Event` | `State` | `Response`). Lobby-based, max 6 players.

The server is the source of truth. Don't move simulation logic client-side, and
don't rename protocol fields / input-action ids.

## Levels are pure data

A level = **one JSON** in `server/tracks/<id>.json` (auto-discovered, hot-reloaded
~2 s, content-hashed so unchanged tracks aren't re-sent). **No per-track scenes or
asset folders.** To add a level, drop a JSON — nothing else.

A track JSON declares:

- `gates` — `start_finish` / `checkpoint`, each `{position, rotation_deg,
  half_width}`. Lap logic in `lobby.rs::check_lap_crossings`: a gate's `forward()`
  is local `-Z` rotated by `rotation_deg`, `tangent()` is local `+X` (half_width
  spans it); a lap counts when the car crosses `start_finish` along its forward
  with all checkpoints hit. Spawn = the start gate's position + Y rotation.
- `primitives` — each = transform (`position`, `rotation_deg`, `size`) + per-type
  config. **`size` IS the scale**: both server (`rapier` cuboid) and client
  (`BoxShape`/visual) derive the collider from the same `size`, so scaling adapts
  on both sides automatically. Collision *groups* are per-type constants
  (`WALL_COLLISION` / `PAD_COLLISION` / `CAR_COLLISION`), independent of scale.
  - `floor`, `wall` (solid box) · `pad` (oriented boost: `heading` +
    `boost_strength`) · `hazard` (sensor) · `curve` (vertical ramp) · `arc` (flat
    L/R turn, `sweep_deg` sign = direction) · `road` (free-form spline:
    Catmull-Rom through `nodes`, with optional per-node Bézier `handle_in/out`,
    `width` & `bank_deg`, and side `walls`; node positions ARE the driving surface;
    tessellated into oriented box slabs like `arc`, and its centerline auto-feeds
    the bots) · `decor` (set-dressing; ONE bounding-box collider unless
    `collide:false`; `model` = a `res://….glb` path or a `decor_builder.gd` keyword).
  - A collidable `decor` box (`collide:true`) is a solid `WALL_COLLISION` surface —
    identical to `floor`/`wall`. The room's floor/walls are painted decor boxes (for
    full colour control).
- `environment` — a procedural preset built by `environment_builder.gd`:
  `living_room` (warm interior + ceiling) · `night` (dark, open) · `studio`
  (neutral default), or `{preset, ...}`. Round-trips via the passthrough
  `TrackDef.environment` field. `game.gd` builds `EnvironmentBuilder.build(env)` +
  a `Physical` node under `TrackRoot` — it does **not** load a scene.

Primitives are built **identically** server-side (`server/src/track.rs`, rapier
colliders) and client-side (`client/scripts/track_loader.gd`, visuals + colliders).
Keep the two in sync. Tracks are editable in the in-engine map editor
(`client/scripts/editor/map_editor.gd`).

## Art direction

- **Toy / household, low-poly, textureless.** Surfaces and decor are flat-coloured
  procedural meshes. `decor_builder.gd` keywords: `arch, ring, rail, pencil, lamp,
  crayon, book, book_stack, block, dice, mug, plant, eraser, ball, sofa, table,
  rug, panel`. No track/decor/environment textures. Cars keep their Kenney
  `colormap.png`.
- **Scale: 1 engine unit ≈ 1 cm.** The car collider is `cuboid(1.3, 0.6, 2.4)` →
  2.6 × 1.2 × 4.8 units (a ~5 cm toy). Size furniture to dwarf it (a real sofa ≈
  230 units wide).

## Gotchas

- Floors and arcs must share surface height: `position.y = -thickness/2` so the top
  sits at y = 0 (otherwise a step blocks cars).
- Decor over/near the racing line that shouldn't block must be `collide:false`
  (a default solid box proxy becomes an invisible wall).
- `scripts/gen_*.py` (track generators + `gen_tuning.py`) run with `py`, not
  `python` (the Windows Store stub hijacks `python`). Track generators emit the
  full JSON incl. `environment` — re-run them rather than hand-editing their output.
- Roads in the map editor stay at **identity** transform (`position`/`rotation`
  zero) — their `nodes` carry the geometry in world space, so node handles map 1:1
  to the translate gizmo. Set node `y` to match adjacent floors (surface at the
  node).

## Build / test / run

- Full suite: `scripts/run-tests.ps1` (or `.sh`).
- Server: `cd server && cargo test` (73 unit + 16 integration).
- Client: `godot --headless --path client --script res://tests/run_tests.gd`
  (TrackCache round-trip + EN/FR locale parity + road spline sampler). Add a `test_*` method, call it from
  `_run_all`, assert with `_check(cond, msg)`. No GUT/GdUnit4.
- Run the game: `scripts/run-all.ps1` (or `.sh`) — server + bots + client. Web
  export: `scripts/export-web.*`. Godot binary via the `GODOT` env var.
- **CI bar (keep green):** server `cargo fmt --check` + `cargo clippy --all-targets
  --all-features -- -D warnings` (with `RUSTFLAGS=-D warnings`) + `cargo test`;
  client headless import + GDScript parse check + headless unit tests.

## Conventions

- Match the surrounding style; keep changes surgical.
- Keep `server/src/track.rs` (Rust colliders) and `client/scripts/track_loader.gd`
  (Godot visuals + colliders) in lockstep — they implement the same shapes.
- New player-facing strings go through `Locale` (`client/scripts/locale.gd`),
  English **and** French.
- Physics tuning shared by the server (`lobby.rs`, authority) and client
  (`player.gd`, prediction) — forces, grip, drift, boost, launch, body
  mass/inertia/CoM, gravity — is single-sourced in `tuning.txt` at the repo root.
  Edit it, then run `py scripts/gen_tuning.py` to regenerate `server/src/tuning.rs`
  and `client/scripts/tuning.gd` (both `@generated` — never hand-edit). `run-tests`
  fails if they're stale. World gravity also lives in `client/project.godot`
  (`player.gd` warns if it drifts from `Tuning.GRAVITY`).
