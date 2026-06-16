# ★ STAR RACER

> Multiplayer arcade racing.

A 3D multiplayer racing game with an authoritative server: a Rust simulation
(physics, lobbies, race logic) paired with a Godot 4 client.

| | |
|---|---|
| **Version** | v1.0.0 rc |
| **Build** | 2026-06-16 |
| **Source** | https://github.com/PrimoDoomer/Star-Racer |

## Authorship

**Game design & creative direction — P.-A. Goya** ([PrimoDoomer](https://github.com/PrimoDoomer)).
The concept, the feel, the direction — every idea here is his.

**Crafted entirely by Claude (Opus 4.8).**
Every part of this project is built by Claude under that direction — not a section
of it, the whole thing: every line of the Rust authoritative server and the Godot
client, the gameplay and physics, the tracks, the tools and editor, the UI, and the
in-engine art (procedural decor, sky, materials and synthesised audio). The human
brought the vision and the calls; Claude wrote and made all of it.

## Credits

Third-party assets and libraries, with their licenses:

**Engine & art**
- [Godot Engine](https://godotengine.org) 4.6 — MIT
- Car models — [Kenney](https://kenney.nl) · *Car Kit* — CC0
- Decor, sky, track surfaces, materials & sound — procedurally generated / synthesised in-engine

**Server (Rust crates)**
- [`rapier3d-f64`](https://rapier.rs) — physics (dimforge) — Apache-2.0
- [`tokio`](https://tokio.rs) · `tokio-tungstenite` · `tungstenite` — async runtime + WebSockets — MIT
- [`serde`](https://serde.rs) · `serde_json` — serialization — MIT / Apache-2.0
- `nalgebra` · `cgmath` · `rand` — math & RNG
- `anyhow` · `thiserror` · `log` · `env_logger` · `colored` · `chrono` · `crossbeam` · `futures-util`

See [LICENSE](LICENSE) for this project's terms.

---

<div align="center">

*Designed by P.-A. Goya · crafted by Claude — Opus 4.8*

</div>
