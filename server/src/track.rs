use nalgebra::{Isometry3, Translation3, UnitQuaternion};
use rapier3d_f64::{
    math::Vec3,
    prelude::{
        ActiveEvents, ColliderBuilder, ColliderHandle, ColliderSet, Group, InteractionGroups,
        InteractionTestMode,
    },
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
    pub spawn: Spawn,
    pub lap: LapConfig,
    pub primitives: Vec<Primitive>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Spawn {
    pub position: [f64; 3],
    pub y_rotation_deg: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct LapConfig {
    pub finish_x: f64,
    pub finish_half_width: f64,
    pub checkpoint_x: f64,
    pub checkpoint_half_width: f64,
    pub positive_z_threshold: f64,
    pub laps_to_win: u8,
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
        serde_json::from_str(raw)
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

pub fn spawn_translation(spawn: &Spawn) -> Vec3 {
    Vec3::new(spawn.position[0], spawn.position[1], spawn.position[2])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_track() {
        let json = r#"{
            "id": "t",
            "name": "T",
            "spawn": { "position": [0.0, 0.0, 0.0], "y_rotation_deg": 0.0 },
            "lap": {
                "finish_x": 0.0, "finish_half_width": 1.0,
                "checkpoint_x": 0.0, "checkpoint_half_width": 1.0,
                "positive_z_threshold": 1.0, "laps_to_win": 1
            },
            "primitives": []
        }"#;
        let track = TrackDef::from_json(json).unwrap();
        assert_eq!(track.id, "t");
        assert_eq!(track.lap.laps_to_win, 1);
        assert!(track.primitives.is_empty());
    }

    #[test]
    fn parses_pad_with_default_boost() {
        let json = r#"{
            "id": "t", "name": "T",
            "spawn": { "position": [0.0, 0.0, 0.0], "y_rotation_deg": 0.0 },
            "lap": {
                "finish_x": 0.0, "finish_half_width": 1.0,
                "checkpoint_x": 0.0, "checkpoint_half_width": 1.0,
                "positive_z_threshold": 1.0, "laps_to_win": 1
            },
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
    fn embedded_circuit_one_parses() {
        let raw = include_str!("../tracks/circuit_one.json");
        let track = TrackDef::from_json(raw).expect("circuit_one.json must parse");
        assert_eq!(track.id, "circuit_one");
        assert!(track
            .primitives
            .iter()
            .any(|p| p.kind == PrimitiveKind::Pad));
        assert!(track
            .primitives
            .iter()
            .any(|p| p.kind == PrimitiveKind::Floor));
    }

    #[test]
    fn embedded_circuit_three_parses() {
        let raw = include_str!("../tracks/circuit_three.json");
        let track = TrackDef::from_json(raw).expect("circuit_three.json must parse");
        assert_eq!(track.id, "circuit_three");
        assert!(track
            .primitives
            .iter()
            .any(|p| p.kind == PrimitiveKind::Hazard));
    }

    #[test]
    fn curve_builds_segments_colliders() {
        use rapier3d_f64::prelude::ColliderSet;
        let json = r#"{
            "id": "t", "name": "T",
            "spawn": { "position": [0.0, 0.0, 0.0], "y_rotation_deg": 0.0 },
            "lap": {
                "finish_x": 0.0, "finish_half_width": 1.0,
                "checkpoint_x": 0.0, "checkpoint_half_width": 1.0,
                "positive_z_threshold": 1.0, "laps_to_win": 1
            },
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
