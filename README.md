# POCKET RACING

> Toy-scale racing in giant rooms.

A 3D multiplayer racing game where you drive toy cars around room-sized indoor
tracks. Authoritative server: a Rust simulation (physics, lobbies, race logic)
paired with a Godot 4 client.

- **P.A Goya** — design and direction.
- **Claude (Opus 4.8)** — code and in-engine art.

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

