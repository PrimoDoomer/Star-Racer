use nalgebra::{Isometry3, Translation3, UnitQuaternion, Vector3};
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
}

fn default_boost_strength() -> f64 {
    20.0
}

const CURVE_SLAB_THICKNESS: f64 = 0.3;
const CURVE_DEFAULT_SEGMENTS: u32 = 12;

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

            let half = [prim.size[0] * 0.5, prim.size[1] * 0.5, prim.size[2] * 0.5];
            let iso = euler_deg_to_isometry(prim.position, prim.rotation_deg);

            let (groups, sensor) = match prim.kind {
                PrimitiveKind::Floor | PrimitiveKind::Wall => (WALL_COLLISION, false),
                PrimitiveKind::Pad | PrimitiveKind::Hazard => (PAD_COLLISION, true),
                PrimitiveKind::Curve => unreachable!(),
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
    fn embedded_circuit_test_parses() {
        let raw = include_str!("../tracks/circuit_test.json");
        let track = TrackDef::from_json(raw).expect("circuit_test.json must parse");
        assert_eq!(track.id, "circuit_test");
        assert!(track
            .primitives
            .iter()
            .any(|p| p.kind == PrimitiveKind::Floor));
        assert!(track
            .primitives
            .iter()
            .any(|p| p.kind == PrimitiveKind::Wall));
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
}
