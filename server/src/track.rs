use nalgebra::{Isometry3, Point3, Translation3, UnitQuaternion, Vector3};
use rapier3d_f64::math::Vec3;
use rapier3d_f64::prelude::{
    ActiveEvents, ColliderBuilder, ColliderHandle, ColliderSet, Group, InteractionGroups,
    InteractionTestMode,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// Sensor colliders the lobby reacts to: boost pads (handle -> strength) and
/// hazards (handles that respawn a car on contact).
#[derive(Default)]
pub struct TrackColliders {
    pub boost_pads: HashMap<ColliderHandle, f64>,
    pub hazards: HashSet<ColliderHandle>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct TrackDef {
    pub id: String,
    pub name: String,
    pub laps_to_win: u8,
    pub gates: Vec<Gate>,
    pub primitives: Vec<Primitive>,
    /// Ordered racing-line polyline ([x, z] in world space). Authored by the
    /// track generators; the game client ignores it, the bots follow it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub centerline: Vec<[f64; 2]>,
    /// Client-only: selects the procedural lighting/sky preset built by
    /// `environment_builder.gd` (a preset-name string, or an object with a
    /// `preset` key + overrides). The server ignores it but re-serializes it to
    /// the client, so a level fully self-describes its environment in its JSON.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<serde_json::Value>,
    /// Content hash of the source JSON, set by `from_json`. Used to detect track
    /// changes (client cache invalidation, hot-reload). Never serialized — it is
    /// carried separately in the protocol (e.g. `LobbyJoined.track_hash`).
    #[serde(skip)]
    pub hash: String,
}

/// Stable, dependency-free FNV-1a 64-bit hash of the given text, as 16 hex
/// digits. Deterministic across runs so a given track file always hashes the
/// same (unlike `DefaultHasher`, and JSON-safe as a string unlike a raw u64).
fn fnv1a_hex(s: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in s.as_bytes() {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{:016x}", hash)
}

/// A placeable, oriented race marker ("portail"). Its forward axis (local -Z,
/// rotated by `rotation_deg`) is the crossing normal; `half_width` extends along
/// the tangent (local +X). The spawn point/heading is taken from the start
/// (or start_finish) gate.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Gate {
    pub role: GateRole,
    pub position: [f64; 3],
    #[serde(default)]
    pub rotation_deg: [f64; 3],
    pub half_width: f64,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GateRole {
    Start,
    Finish,
    StartFinish,
    Checkpoint,
}

impl Gate {
    pub fn center(&self) -> Vector3<f64> {
        Vector3::new(self.position[0], self.position[1], self.position[2])
    }

    /// Crossing normal: local -Z rotated by `rotation_deg`.
    pub fn forward(&self) -> Vector3<f64> {
        euler_deg_to_isometry(self.position, self.rotation_deg).rotation
            * Vector3::new(0.0, 0.0, -1.0)
    }

    /// Width axis: local +X rotated by `rotation_deg`.
    pub fn tangent(&self) -> Vector3<f64> {
        euler_deg_to_isometry(self.position, self.rotation_deg).rotation
            * Vector3::new(1.0, 0.0, 0.0)
    }

    pub fn provides_start(&self) -> bool {
        matches!(self.role, GateRole::Start | GateRole::StartFinish)
    }

    pub fn provides_finish(&self) -> bool {
        matches!(self.role, GateRole::Finish | GateRole::StartFinish)
    }

    pub fn is_checkpoint(&self) -> bool {
        matches!(self.role, GateRole::Checkpoint)
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PrimitiveKind {
    Floor,
    Wall,
    Pad,
    Hazard,
    Curve,
    /// Flat horizontal turn (left/right) in the XZ plane.
    Arc,
    /// Free-form curved road: a Catmull-Rom spline through `nodes`, built as ONE
    /// continuous trimesh surface (no inter-slab steps) along an arbitrary 3D path
    /// with per-node width and banking. Optional solid side walls.
    Road,
    /// Visual set-dressing. Gameplay-inert: at most one cheap box proxy collider
    /// (skipped entirely when `collide` is false). The visual `model` is a
    /// client-only concern the server ignores.
    Decor,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Primitive {
    #[serde(rename = "type")]
    pub kind: PrimitiveKind,
    #[serde(default)]
    pub name: Option<String>,
    pub size: [f64; 3],
    pub position: [f64; 3],
    #[serde(default)]
    pub rotation_deg: [f64; 3],
    #[serde(default)]
    pub color: Option<[f64; 3]>,
    #[serde(default)]
    pub heading: Option<[f64; 3]>,
    #[serde(default = "default_boost_strength")]
    pub boost_strength: f64,
    #[serde(default)]
    pub segments: Option<u32>,
    /// Arc sweep in degrees: magnitude is the turn angle, sign picks the
    /// direction (> 0 turns right / +X, < 0 turns left / -X). Default 45.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sweep_deg: Option<f64>,
    /// Decor only: client-side visual selector — a `res://…glb` path or a
    /// procedural keyword. Ignored by the server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Decor only: whether the cheap box proxy collider is built (default true).
    /// Omitted (not sent as null) when unset, so the client's default applies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collide: Option<bool>,
    /// Road only: ordered control nodes the spline passes through (local space,
    /// before the primitive's `position`/`rotation_deg` transform). `size[0]` is
    /// the default road width; `segments` is the tessellation density per span
    /// (between two nodes).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nodes: Option<Vec<RoadNode>>,
    /// Road only: build solid side walls along both edges (default false).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub walls: Option<bool>,
    /// Road only: side-wall height when `walls` is set (default 1.2).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wall_height: Option<f64>,
}

/// A control point of a `road` spline. The road surface passes through
/// `position`; `width`/`bank_deg` override the road defaults at this node and
/// interpolate linearly toward the next node.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct RoadNode {
    pub position: [f64; 3],
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bank_deg: Option<f64>,
    /// Optional Bézier handles (local offsets from `position`). When either end
    /// of a span carries one, that span is a cubic Bézier instead of the default
    /// Catmull-Rom — `handle_out` shapes the start tangent, `handle_in` the end.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle_in: Option<[f64; 3]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle_out: Option<[f64; 3]>,
}

fn default_boost_strength() -> f64 {
    20.0
}

const CURVE_SLAB_THICKNESS: f64 = 0.3;
const CURVE_DEFAULT_SEGMENTS: u32 = 12;

const ARC_DEFAULT_SEGMENTS: u32 = 8;
const ARC_DEFAULT_SWEEP_DEG: f64 = 45.0;

const ROAD_DEFAULT_SEGMENTS_PER_SPAN: u32 = 8;
const ROAD_DEFAULT_WIDTH: f64 = 24.0;
const ROAD_DEFAULT_WALL_HEIGHT: f64 = 1.2;
/// Side-wall depth (outward from the road edge): the wall is a solid prism this
/// thick so a fast car can't tunnel through a paper-thin edge. Mirrors client.
const ROAD_WALL_THICKNESS: f64 = 2.0;
/// Centripetal Catmull-Rom (alpha = 0.5): no cusps / self-intersections, unlike
/// the uniform (alpha = 0) form. Client `_catmull_centripetal` mirrors this.
const ROAD_CATMULL_ALPHA: f64 = 0.5;

const WALL_COLLISION: InteractionGroups = InteractionGroups::new(
    Group::GROUP_1,
    Group::GROUP_1.union(Group::GROUP_2),
    InteractionTestMode::And,
);
const PAD_COLLISION: InteractionGroups =
    InteractionGroups::new(Group::GROUP_3, Group::GROUP_2, InteractionTestMode::And);

impl TrackDef {
    pub fn from_json(raw: &str) -> serde_json::Result<Self> {
        let mut def: Self = serde_json::from_str(raw)?;
        def.hash = fnv1a_hex(raw);
        // Roads carry their own racing line: when the author didn't supply a
        // centerline, derive one from the road splines so bots can drive them.
        if def.centerline.is_empty() {
            def.centerline = derive_centerline(&def.primitives);
        }
        Ok(def)
    }

    /// Spawn point + heading (degrees), taken from the first start/start_finish
    /// gate. Falls back to the origin if none is defined.
    pub fn spawn(&self) -> (Vector3<f64>, f64) {
        for g in &self.gates {
            if g.provides_start() {
                return (g.center(), g.rotation_deg[1]);
            }
        }
        (Vector3::zeros(), 0.0)
    }

    pub fn finish_gates(&self) -> impl Iterator<Item = &Gate> {
        self.gates.iter().filter(|g| g.provides_finish())
    }

    pub fn checkpoint_gates(&self) -> impl Iterator<Item = &Gate> {
        self.gates.iter().filter(|g| g.is_checkpoint())
    }

    pub fn build_colliders(&self, collider_set: &mut ColliderSet) -> TrackColliders {
        let mut out = TrackColliders::default();
        for prim in &self.primitives {
            if prim.kind == PrimitiveKind::Curve {
                build_curve_colliders(prim, collider_set);
                continue;
            }
            if prim.kind == PrimitiveKind::Arc {
                build_arc_colliders(prim, collider_set);
                continue;
            }
            if prim.kind == PrimitiveKind::Road {
                build_road_colliders(prim, collider_set);
                continue;
            }
            if prim.kind == PrimitiveKind::Decor {
                // Cheapest possible bound: a single solid box, only if it collides.
                if prim.collide.unwrap_or(true) {
                    let half = [prim.size[0] * 0.5, prim.size[1] * 0.5, prim.size[2] * 0.5];
                    let iso = euler_deg_to_isometry(prim.position, prim.rotation_deg);
                    let collider = ColliderBuilder::cuboid(half[0], half[1], half[2])
                        .position(iso.into())
                        .collision_groups(WALL_COLLISION)
                        .active_events(ActiveEvents::COLLISION_EVENTS)
                        .sensor(false)
                        .build();
                    collider_set.insert(collider);
                }
                continue;
            }

            let half = [prim.size[0] * 0.5, prim.size[1] * 0.5, prim.size[2] * 0.5];
            let iso = euler_deg_to_isometry(prim.position, prim.rotation_deg);

            let (groups, sensor) = match prim.kind {
                PrimitiveKind::Floor | PrimitiveKind::Wall => (WALL_COLLISION, false),
                PrimitiveKind::Pad | PrimitiveKind::Hazard => (PAD_COLLISION, true),
                PrimitiveKind::Curve
                | PrimitiveKind::Arc
                | PrimitiveKind::Road
                | PrimitiveKind::Decor => unreachable!(),
            };

            let collider = ColliderBuilder::cuboid(half[0], half[1], half[2])
                .position(iso.into())
                .collision_groups(groups)
                .active_events(ActiveEvents::COLLISION_EVENTS)
                .sensor(sensor)
                .build();
            let handle = collider_set.insert(collider);

            match prim.kind {
                PrimitiveKind::Pad => {
                    out.boost_pads.insert(handle, prim.boost_strength);
                }
                PrimitiveKind::Hazard => {
                    out.hazards.insert(handle);
                }
                _ => {}
            }
        }
        out
    }
}

fn build_curve_colliders(prim: &Primitive, collider_set: &mut ColliderSet) {
    let width = prim.size[0];
    let height = prim.size[1];
    let length = prim.size[2];
    let segments = prim.segments.unwrap_or(CURVE_DEFAULT_SEGMENTS).max(1);

    let outer = euler_deg_to_isometry(prim.position, prim.rotation_deg);
    let half_pi = std::f64::consts::FRAC_PI_2;

    for i in 0..segments {
        let t0 = (i as f64) / (segments as f64) * half_pi;
        let t1 = ((i + 1) as f64) / (segments as f64) * half_pi;

        let z0 = length * t0.sin();
        let y0 = height * (1.0 - t0.cos());
        let z1 = length * t1.sin();
        let y1 = height * (1.0 - t1.cos());

        let dz = z1 - z0;
        let dy = y1 - y0;
        let chord_len = (dz * dz + dy * dy).sqrt();
        if chord_len < 1e-6 {
            continue;
        }

        let pitch = (-dy).atan2(dz);
        let nz = -dy / chord_len;
        let ny = dz / chord_len;

        let mid_z = 0.5 * (z0 + z1) - nz * (CURVE_SLAB_THICKNESS * 0.5);
        let mid_y = 0.5 * (y0 + y1) - ny * (CURVE_SLAB_THICKNESS * 0.5);

        let local = Isometry3::from_parts(
            Translation3::new(0.0, mid_y, mid_z),
            UnitQuaternion::from_euler_angles(pitch, 0.0, 0.0),
        );
        let world = outer * local;

        let collider =
            ColliderBuilder::cuboid(width * 0.5, CURVE_SLAB_THICKNESS * 0.5, chord_len * 0.5)
                .position(world.into())
                .collision_groups(WALL_COLLISION)
                .active_events(ActiveEvents::COLLISION_EVENTS)
                .sensor(false)
                .build();
        collider_set.insert(collider);
    }
}

/// Flat horizontal turn: tessellated into short yaw-rotated floor slabs along a
/// circular arc in the local XZ plane. Entry is at the local origin heading -Z
/// (matching gate forward); the turn center sits on +X (right, sweep_deg > 0) or
/// -X (left, sweep_deg < 0). Client `_make_arc` mirrors these formulas.
fn build_arc_colliders(prim: &Primitive, collider_set: &mut ColliderSet) {
    let width = prim.size[0];
    let thickness = prim.size[1];
    let radius = prim.size[2];
    let segments = prim.segments.unwrap_or(ARC_DEFAULT_SEGMENTS).max(1);
    let sweep_deg = prim.sweep_deg.unwrap_or(ARC_DEFAULT_SWEEP_DEG);
    let sign = if sweep_deg < 0.0 { -1.0 } else { 1.0 };
    let sweep = sweep_deg.abs().to_radians();

    let outer = euler_deg_to_isometry(prim.position, prim.rotation_deg);
    let cx = sign * radius; // turn center, local X

    // Centerline point at sweep angle `a`: rotate (origin - center) about Y.
    let point = |a: f64| -> (f64, f64) {
        let rot = -sign * a;
        let x0 = -cx; // (origin - center).x
        (cx + x0 * rot.cos(), -x0 * rot.sin())
    };

    for i in 0..segments {
        let a0 = (i as f64) / (segments as f64) * sweep;
        let a1 = ((i + 1) as f64) / (segments as f64) * sweep;
        let (x0, z0) = point(a0);
        let (x1, z1) = point(a1);
        let dx = x1 - x0;
        let dz = z1 - z0;
        let chord = (dx * dx + dz * dz).sqrt();
        if chord < 1e-6 {
            continue;
        }
        let yaw = dx.atan2(dz); // chord heading; RotY(yaw)*(0,0,1) = (sin,0,cos)
        let local = Isometry3::from_parts(
            Translation3::new(0.5 * (x0 + x1), 0.0, 0.5 * (z0 + z1)),
            UnitQuaternion::from_euler_angles(0.0, yaw, 0.0),
        );
        let world = outer * local;

        let collider = ColliderBuilder::cuboid(width * 0.5, thickness * 0.5, chord * 0.5)
            .position(world.into())
            .collision_groups(WALL_COLLISION)
            .active_events(ActiveEvents::COLLISION_EVENTS)
            .sensor(false)
            .build();
        collider_set.insert(collider);
    }
}

/// One tessellation sample along a road: centerline position (local space),
/// road width and bank angle (degrees) at that point.
struct RoadSample {
    pos: Vector3<f64>,
    width: f64,
    bank_deg: f64,
}

/// Sample a road's Catmull-Rom centerline into evenly-stepped points, carrying
/// the per-point width and bank (linearly interpolated between nodes). Returns
/// `(n_nodes - 1) * segments_per_span + 1` samples, passing exactly through each
/// control node. Client `_sample_road` mirrors this — keep the two in sync.
fn road_samples(prim: &Primitive) -> Vec<RoadSample> {
    let nodes = match &prim.nodes {
        Some(n) if n.len() >= 2 => n,
        _ => return Vec::new(),
    };
    let seg = prim
        .segments
        .unwrap_or(ROAD_DEFAULT_SEGMENTS_PER_SPAN)
        .max(1);
    let default_w = if prim.size[0] > 0.0 {
        prim.size[0]
    } else {
        ROAD_DEFAULT_WIDTH
    };

    let p: Vec<Vector3<f64>> = nodes
        .iter()
        .map(|n| Vector3::new(n.position[0], n.position[1], n.position[2]))
        .collect();
    let w: Vec<f64> = nodes.iter().map(|n| n.width.unwrap_or(default_w)).collect();
    let b: Vec<f64> = nodes.iter().map(|n| n.bank_deg.unwrap_or(0.0)).collect();
    let to_v = |a: [f64; 3]| Vector3::new(a[0], a[1], a[2]);
    let h_out: Vec<Option<Vector3<f64>>> = nodes.iter().map(|n| n.handle_out.map(to_v)).collect();
    let h_in: Vec<Option<Vector3<f64>>> = nodes.iter().map(|n| n.handle_in.map(to_v)).collect();

    let n = p.len();
    let mut out: Vec<RoadSample> = Vec::with_capacity((n - 1) * seg as usize + 1);
    for i in 0..(n - 1) {
        // Four control points for this span; ends reflect their neighbour so the
        // spline still has a well-defined tangent at the first/last node.
        let p0 = if i == 0 {
            p[0] + (p[0] - p[1])
        } else {
            p[i - 1]
        };
        let p1 = p[i];
        let p2 = p[i + 1];
        let p3 = if i + 2 < n {
            p[i + 2]
        } else {
            p[n - 1] + (p[n - 1] - p[n - 2])
        };
        // A span with any explicit handle becomes a cubic Bézier; a missing handle
        // defaults to a third of the chord (a gentle, straight-ish tangent).
        let bezier = h_out[i].is_some() || h_in[i + 1].is_some();
        let b1 = p1 + h_out[i].unwrap_or((p2 - p1) / 3.0);
        let b2 = p2 + h_in[i + 1].unwrap_or((p1 - p2) / 3.0);
        // Emit the final node only on the last span, so boundaries aren't doubled.
        let count = if i == n - 2 { seg + 1 } else { seg };
        for s in 0..count {
            let u = s as f64 / seg as f64;
            out.push(RoadSample {
                pos: if bezier {
                    cubic_bezier(p1, b1, b2, p2, u)
                } else {
                    catmull_rom_centripetal(p0, p1, p2, p3, u)
                },
                width: w[i] + (w[i + 1] - w[i]) * u,
                bank_deg: b[i] + (b[i + 1] - b[i]) * u,
            });
        }
    }
    out
}

/// Derive a racing-line polyline ([x, z]) from every road primitive's sampled
/// centerline (in world space), concatenated in primitive order. Consecutive
/// near-duplicate points (and a closed-loop seam) are dropped so bot lookahead
/// never stalls on a zero-length segment.
fn derive_centerline(prims: &[Primitive]) -> Vec<[f64; 2]> {
    let mut out: Vec<[f64; 2]> = Vec::new();
    for prim in prims {
        if prim.kind != PrimitiveKind::Road {
            continue;
        }
        let outer = euler_deg_to_isometry(prim.position, prim.rotation_deg);
        for s in road_samples(prim) {
            let w = outer * Point3::new(s.pos.x, s.pos.y, s.pos.z);
            let p = [w.x, w.z];
            if out
                .last()
                .is_none_or(|l| (l[0] - p[0]).hypot(l[1] - p[1]) > 1e-3)
            {
                out.push(p);
            }
        }
    }
    if out.len() > 2 {
        let (f, l) = (out[0], *out.last().unwrap());
        if (f[0] - l[0]).hypot(f[1] - l[1]) < 1e-3 {
            out.pop();
        }
    }
    out
}

/// Cubic Bézier point at `u` in [0, 1]. Mirrored by client `_cubic_bezier`.
fn cubic_bezier(
    b0: Vector3<f64>,
    b1: Vector3<f64>,
    b2: Vector3<f64>,
    b3: Vector3<f64>,
    u: f64,
) -> Vector3<f64> {
    let v = 1.0 - u;
    b0 * (v * v * v) + b1 * (3.0 * v * v * u) + b2 * (3.0 * v * u * u) + b3 * (u * u * u)
}

/// Centripetal Catmull-Rom point on the `p1..p2` span at `u` in [0, 1]
/// (Barry-Goldman pyramidal form). Mirrored by client `_catmull_centripetal`.
fn catmull_rom_centripetal(
    p0: Vector3<f64>,
    p1: Vector3<f64>,
    p2: Vector3<f64>,
    p3: Vector3<f64>,
    u: f64,
) -> Vector3<f64> {
    let knot = |ti: f64, a: Vector3<f64>, b: Vector3<f64>| {
        ti + (b - a).norm().powf(ROAD_CATMULL_ALPHA).max(1e-6)
    };
    let t0 = 0.0;
    let t1 = knot(t0, p0, p1);
    let t2 = knot(t1, p1, p2);
    let t3 = knot(t2, p2, p3);
    let t = t1 + (t2 - t1) * u;

    // Linear interpolation of a, b parameterised over [ta, tb].
    let lerp = |a: Vector3<f64>, b: Vector3<f64>, ta: f64, tb: f64| {
        if (tb - ta).abs() < 1e-9 {
            a
        } else {
            a + (b - a) * ((t - ta) / (tb - ta))
        }
    };

    let a1 = lerp(p0, p1, t0, t1);
    let a2 = lerp(p1, p2, t1, t2);
    let a3 = lerp(p2, p3, t2, t3);
    let b1 = lerp(a1, a2, t0, t2);
    let b2 = lerp(a2, a3, t1, t3);
    lerp(b1, b2, t1, t2)
}

/// Orthonormal cross-section frame for a road slab heading along `fwd`, rolled by
/// `bank` (radians) about it: returns (right = local +X, up = local +Y). Positive
/// `bank` raises the right edge. Mirrored by client `_road_frame`.
fn road_frame(fwd: Vector3<f64>, bank: f64) -> (Vector3<f64>, Vector3<f64>) {
    let up_ref = if fwd.y.abs() > 0.99 {
        Vector3::z()
    } else {
        Vector3::y()
    };
    let right0 = up_ref.cross(&fwd).normalize();
    let up0 = fwd.cross(&right0); // already unit-length
    let (s, c) = bank.sin_cos();
    (right0 * c + up0 * s, up0 * c - right0 * s)
}

/// One per-sample road edge frame: (surface centre, lateral right unit, up unit,
/// half-width).
type Frame = (Vector3<f64>, Vector3<f64>, Vector3<f64>, f64);

/// Per-sample edge frames; tangent by central/forward difference (like the ribbon).
fn road_frames(samples: &[RoadSample]) -> Vec<Frame> {
    let n = samples.len();
    (0..n)
        .map(|i| {
            let c = samples[i].pos;
            let raw = if i + 1 < n {
                samples[i + 1].pos - c
            } else {
                c - samples[i - 1].pos
            };
            let fwd = if raw.norm() > 1e-6 {
                raw.normalize()
            } else {
                Vector3::new(0.0, 0.0, 1.0)
            };
            let (right, up) = road_frame(fwd, samples[i].bank_deg.to_radians());
            (c, right, up, samples[i].width * 0.5)
        })
        .collect()
}

/// Driving-surface ribbon as a continuous trimesh (vertices + triangle indices,
/// road-local) — smooth, no inter-slab steps. Walls are SEPARATE convex prisms
/// (see `build_road_colliders`). Mirrored client-side by `_build_road_mesh`.
fn road_surface_trimesh(frames: &[Frame]) -> (Vec<Vec3>, Vec<[u32; 3]>) {
    let n = frames.len();
    let pv = |v: Vector3<f64>| Vec3::new(v.x, v.y, v.z);
    let mut verts: Vec<Vec3> = Vec::with_capacity(2 * n);
    for &(c, right, _up, hw) in frames {
        verts.push(pv(c + right * hw)); // 2i   = L_i
        verts.push(pv(c - right * hw)); // 2i+1 = R_i
    }
    let mut idx: Vec<[u32; 3]> = Vec::new();
    for i in 0..n - 1 {
        let k = 2 * i as u32;
        idx.push([k, k + 2, k + 1]);
        idx.push([k + 1, k + 2, k + 3]);
    }
    (verts, idx)
}

/// Road collision: the surface as one smooth trimesh, plus each side wall as a
/// chain of SOLID convex prisms. The prisms have volume (a fast car can't tunnel
/// through them — no CCD needed) and share edges between spans (no steps to
/// micro-catch on). Mirrors client `_make_road`.
fn build_road_colliders(prim: &Primitive, collider_set: &mut ColliderSet) {
    let samples = road_samples(prim);
    if samples.len() < 2 {
        return;
    }
    let walls = prim.walls.unwrap_or(false);
    let wall_h = prim.wall_height.unwrap_or(ROAD_DEFAULT_WALL_HEIGHT);
    let outer = euler_deg_to_isometry(prim.position, prim.rotation_deg);
    let frames = road_frames(&samples);

    let mut add = |builder: ColliderBuilder| {
        collider_set.insert(
            builder
                .position(outer.into())
                .collision_groups(WALL_COLLISION)
                .active_events(ActiveEvents::COLLISION_EVENTS)
                .sensor(false)
                .build(),
        );
    };

    let (verts, indices) = road_surface_trimesh(&frames);
    if !indices.is_empty() {
        if let Ok(b) = ColliderBuilder::trimesh(verts, indices) {
            add(b);
        }
    }

    if walls {
        let wt = ROAD_WALL_THICKNESS;
        for i in 0..frames.len() - 1 {
            let (p0, r0, u0, hw0) = frames[i];
            let (p1, r1, u1, hw1) = frames[i + 1];
            for side in [1.0_f64, -1.0] {
                let (ib0, ob0) = (p0 + r0 * (hw0 * side), p0 + r0 * ((hw0 + wt) * side));
                let (ib1, ob1) = (p1 + r1 * (hw1 * side), p1 + r1 * ((hw1 + wt) * side));
                let pts = [
                    ib0,
                    ob0,
                    ib0 + u0 * wall_h,
                    ob0 + u0 * wall_h,
                    ib1,
                    ob1,
                    ib1 + u1 * wall_h,
                    ob1 + u1 * wall_h,
                ];
                let hull: Vec<Vec3> = pts.iter().map(|v| Vec3::new(v.x, v.y, v.z)).collect();
                if let Some(b) = ColliderBuilder::convex_hull(&hull) {
                    add(b);
                }
            }
        }
    }
}

fn euler_deg_to_isometry(pos: [f64; 3], rot_deg: [f64; 3]) -> Isometry3<f64> {
    let to_rad = std::f64::consts::PI / 180.0;
    let q = UnitQuaternion::from_euler_angles(
        rot_deg[0] * to_rad,
        rot_deg[1] * to_rad,
        rot_deg[2] * to_rad,
    );
    Isometry3::from_parts(Translation3::new(pos[0], pos[1], pos[2]), q)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_track() {
        let json = r#"{
            "id": "t",
            "name": "T",
            "laps_to_win": 1,
            "gates": [
                { "role": "start_finish", "position": [0.0, 0.0, 0.0], "rotation_deg": [0.0, 0.0, 0.0], "half_width": 1.0 }
            ],
            "primitives": []
        }"#;
        let track = TrackDef::from_json(json).unwrap();
        assert_eq!(track.id, "t");
        assert_eq!(track.laps_to_win, 1);
        assert!(track.primitives.is_empty());

        let (pos, yaw) = track.spawn();
        assert_eq!(pos, Vector3::zeros());
        assert_eq!(yaw, 0.0);
        assert_eq!(track.finish_gates().count(), 1);
    }

    #[test]
    fn parses_pad_with_default_boost() {
        let json = r#"{
            "id": "t", "name": "T",
            "laps_to_win": 1,
            "gates": [
                { "role": "start_finish", "position": [0.0, 0.0, 0.0], "rotation_deg": [0.0, 0.0, 0.0], "half_width": 1.0 }
            ],
            "primitives": [
                { "type": "pad", "size": [10, 4, 10], "position": [0, 1.5, 0], "heading": [0, 0, -1] }
            ]
        }"#;
        let track = TrackDef::from_json(json).unwrap();
        assert_eq!(track.primitives.len(), 1);
        assert_eq!(track.primitives[0].boost_strength, 20.0);
        assert_eq!(track.primitives[0].kind, PrimitiveKind::Pad);
    }

    #[test]
    fn embedded_the_bedroom_parses_with_road_and_decor() {
        let raw = include_str!("../tracks/the_bedroom.json");
        let track = TrackDef::from_json(raw).expect("the_bedroom.json must parse");
        assert_eq!(track.id, "the_bedroom");
        assert!(track
            .primitives
            .iter()
            .any(|p| p.kind == PrimitiveKind::Road));
        assert!(track
            .primitives
            .iter()
            .any(|p| p.kind == PrimitiveKind::Decor));
        // One continuous trimesh collider for the road, plus a box proxy per solid
        // decor; building must not panic.
        let mut cs = rapier3d_f64::prelude::ColliderSet::new();
        track.build_colliders(&mut cs);
        assert!(cs.len() > 1);
        // A road with no authored centerline gets one derived for the bots.
        assert!(!track.centerline.is_empty());
    }

    #[test]
    fn curve_builds_segments_colliders() {
        use rapier3d_f64::prelude::ColliderSet;
        let json = r#"{
            "id": "t", "name": "T",
            "laps_to_win": 1,
            "gates": [
                { "role": "start_finish", "position": [0.0, 0.0, 0.0], "rotation_deg": [0.0, 0.0, 0.0], "half_width": 1.0 }
            ],
            "primitives": [
                { "type": "curve", "size": [10, 3, 8], "position": [0, 0, 0], "segments": 6 }
            ]
        }"#;
        let track = TrackDef::from_json(json).unwrap();
        let mut cs = ColliderSet::new();
        track.build_colliders(&mut cs);
        assert_eq!(cs.len(), 6);
    }

    #[test]
    fn arc_builds_one_collider_per_segment() {
        use rapier3d_f64::prelude::ColliderSet;
        let json = r#"{
            "id": "t", "name": "T",
            "laps_to_win": 1,
            "gates": [
                { "role": "start_finish", "position": [0.0, 0.0, 0.0], "rotation_deg": [0.0, 0.0, 0.0], "half_width": 1.0 }
            ],
            "primitives": [
                { "type": "arc", "size": [12, 1, 40], "position": [0, 0, 0], "segments": 8, "sweep_deg": 45 }
            ]
        }"#;
        let track = TrackDef::from_json(json).unwrap();
        let mut cs = ColliderSet::new();
        track.build_colliders(&mut cs);
        assert_eq!(cs.len(), 8);
    }

    #[test]
    fn arc_left_and_right_mirror_across_x() {
        // A right turn (+sweep) curves toward +X; a left turn (-sweep) toward -X.
        let right = Primitive {
            kind: PrimitiveKind::Arc,
            name: None,
            size: [10.0, 1.0, 30.0],
            position: [0.0, 0.0, 0.0],
            rotation_deg: [0.0, 0.0, 0.0],
            color: None,
            heading: None,
            boost_strength: default_boost_strength(),
            segments: Some(4),
            sweep_deg: Some(45.0),
            model: None,
            collide: None,
            nodes: None,
            walls: None,
            wall_height: None,
        };
        let mut left = right.clone();
        left.sweep_deg = Some(-45.0);

        let mut cs_r = ColliderSet::new();
        build_arc_colliders(&right, &mut cs_r);
        let mut cs_l = ColliderSet::new();
        build_arc_colliders(&left, &mut cs_l);

        let max_x = |cs: &ColliderSet| {
            cs.iter()
                .map(|(_, c)| c.translation().x)
                .fold(f64::MIN, f64::max)
        };
        let min_x = |cs: &ColliderSet| {
            cs.iter()
                .map(|(_, c)| c.translation().x)
                .fold(f64::MAX, f64::min)
        };
        assert!(max_x(&cs_r) > 1.0, "right turn should reach +X");
        assert!(min_x(&cs_l) < -1.0, "left turn should reach -X");
    }

    fn road_track(extra: &str) -> TrackDef {
        let json = format!(
            r#"{{
                "id": "t", "name": "T", "laps_to_win": 1,
                "gates": [ {{ "role": "start_finish", "position": [0,0,0], "rotation_deg": [0,0,0], "half_width": 1.0 }} ],
                "primitives": [ {{ "type": "road", "size": [24, 1, 0], "position": [0,0,0],
                    "nodes": [ {{ "position": [0,0,0] }}, {{ "position": [0,0,-50] }}, {{ "position": [0,0,-100] }} ]
                    {extra} }} ]
            }}"#
        );
        TrackDef::from_json(&json).unwrap()
    }

    #[test]
    fn road_builds_surface_trimesh_plus_wall_prisms() {
        use rapier3d_f64::prelude::ColliderSet;
        // 3 nodes, segments = 4 → 8 spans: 1 surface trimesh + 2 wall prisms/span.
        let track = road_track(r#", "segments": 4, "walls": true"#);
        let mut cs = ColliderSet::new();
        track.build_colliders(&mut cs);
        assert_eq!(cs.len(), 1 + 8 * 2);
    }

    #[test]
    fn road_surface_trimesh_triangle_count() {
        // 3 nodes, segments(per span) = 4 → 9 samples → 8 spans, 2 triangles each.
        let track = road_track(r#", "segments": 4"#);
        let frames = road_frames(&road_samples(&track.primitives[0]));
        let (_, surf) = road_surface_trimesh(&frames);
        assert_eq!(surf.len(), 8 * 2);
    }

    #[test]
    fn road_samples_pass_through_control_nodes() {
        let track = road_track(r#", "segments": 4"#);
        let samples = road_samples(&track.primitives[0]);
        assert_eq!(samples.len(), 2 * 4 + 1);
        let close =
            |a: Vector3<f64>, b: [f64; 3]| (a - Vector3::new(b[0], b[1], b[2])).norm() < 1e-6;
        assert!(
            close(samples[0].pos, [0.0, 0.0, 0.0]),
            "starts at first node"
        );
        assert!(
            close(samples[4].pos, [0.0, 0.0, -50.0]),
            "hits the middle node"
        );
        assert!(
            close(samples[8].pos, [0.0, 0.0, -100.0]),
            "ends at last node"
        );
    }

    #[test]
    fn road_straight_nodes_stay_straight() {
        let track = road_track(r#", "segments": 6"#);
        for s in road_samples(&track.primitives[0]) {
            assert!(
                s.pos.x.abs() < 1e-6 && s.pos.y.abs() < 1e-6,
                "collinear nodes give a straight line"
            );
        }
    }

    #[test]
    fn road_derives_centerline_for_bots() {
        // from_json should hand bots a racing line when none was authored.
        let track = road_track(r#", "segments": 4"#);
        assert!(track.centerline.len() >= 2, "a road yields a centerline");
        let first = track.centerline[0];
        assert!(
            (first[0] - 0.0).abs() < 1e-6 && (first[1] - 0.0).abs() < 1e-6,
            "centerline starts at the first node's (x, z)"
        );
    }

    #[test]
    fn road_bezier_handles_still_pass_through_nodes() {
        let json = r#"{
            "id": "t", "name": "T", "laps_to_win": 1,
            "gates": [ { "role": "start_finish", "position": [0,0,0], "rotation_deg": [0,0,0], "half_width": 1.0 } ],
            "primitives": [ { "type": "road", "size": [24, 1, 0], "position": [0,0,0], "segments": 6,
                "nodes": [
                    { "position": [0,0,0], "handle_out": [40,0,0] },
                    { "position": [0,0,-100], "handle_in": [40,0,0] }
                ] } ]
        }"#;
        let track = TrackDef::from_json(json).unwrap();
        let samples = road_samples(&track.primitives[0]);
        let close =
            |a: Vector3<f64>, b: [f64; 3]| (a - Vector3::new(b[0], b[1], b[2])).norm() < 1e-6;
        assert!(
            close(samples[0].pos, [0.0, 0.0, 0.0]),
            "Bézier hits the first node"
        );
        assert!(
            close(samples[samples.len() - 1].pos, [0.0, 0.0, -100.0]),
            "Bézier hits the last node"
        );
        // The +X handles bow the middle of the span out toward +X.
        let mid = samples[samples.len() / 2].pos;
        assert!(mid.x > 1.0, "handles bow the span toward +X");
    }

    #[test]
    fn decor_collider_respects_collide_flag() {
        use rapier3d_f64::prelude::ColliderSet;
        let base = r#"{
            "id": "t", "name": "T", "laps_to_win": 1,
            "gates": [ { "role": "start_finish", "position": [0,0,0], "rotation_deg": [0,0,0], "half_width": 1.0 } ],
            "primitives": [ %P% ]
        }"#;

        let solid = base.replace(
            "%P%",
            r#"{ "type": "decor", "size": [4,8,4], "position": [10,4,0], "model": "res://x.glb" }"#,
        );
        let mut cs = ColliderSet::new();
        TrackDef::from_json(&solid)
            .unwrap()
            .build_colliders(&mut cs);
        assert_eq!(cs.len(), 1, "decor builds one box proxy by default");

        let ghost = base.replace(
            "%P%",
            r#"{ "type": "decor", "size": [4,8,4], "position": [10,4,0], "collide": false, "model": "neon_arch" }"#,
        );
        let mut cs2 = ColliderSet::new();
        TrackDef::from_json(&ghost)
            .unwrap()
            .build_colliders(&mut cs2);
        assert!(cs2.is_empty(), "non-colliding decor builds no collider");
    }
}
