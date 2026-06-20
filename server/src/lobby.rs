use crate::{
    error::Error,
    protocol::{
        ClientMessage, ColorProto, JoinError, LobbyEvent, LobbyState, PlayerState, QuatProto,
        Response, ServerMessage, SpawnInfo, Vec3Proto,
    },
    sr_log,
    track::TrackDef,
    Result,
};
use cgmath::Vector3;
use futures_util::{stream::SplitStream, SinkExt, StreamExt};
use rapier3d_f64::{
    math::{Pose, Vec3, Vector},
    prelude::{
        ActiveEvents, BroadPhaseBvh, CCDSolver, ChannelEventCollector, ColliderBuilder,
        ColliderHandle, ColliderSet, CollisionEvent, ContactForceEvent, Group, ImpulseJointSet,
        IntegrationParameters, InteractionGroups, InteractionTestMode, IslandManager,
        MassProperties, MultibodyJointSet, NarrowPhase, PhysicsPipeline, RigidBodyBuilder,
        RigidBodyHandle, RigidBodySet,
    },
};
use std::{
    collections::{HashMap, HashSet},
    sync::mpsc::Receiver,
    sync::Arc,
};
use tokio::net::TcpStream;
use tokio_tungstenite::WebSocketStream;
use tungstenite::Message;

#[derive(Clone)]
pub(crate) enum OutgoingMessage {
    Reliable(Message),
    State(Message),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum QueueSendResult {
    Queued,
    RemoveClient,
}

struct PhysicsWorld {
    rigid_body_set: RigidBodySet,
    collider_set: ColliderSet,
    pipeline: PhysicsPipeline,
    island_manager: IslandManager,
    broad_phase: BroadPhaseBvh,
    narrow_phase: NarrowPhase,
    integration_parameters: IntegrationParameters,
    gravity: Vector,
    impulse_joint_set: ImpulseJointSet,
    multibody_joint_set: MultibodyJointSet,
    ccd_solver: CCDSolver,
    physics_hooks: (),
    #[allow(unused)]
    collision_events: ChannelEventCollector,
    collision_recv: Receiver<CollisionEvent>,
    #[allow(unused)]
    force_recv: Receiver<ContactForceEvent>,
}

impl PhysicsWorld {
    fn new() -> Self {
        let (collision_send, collision_recv) = std::sync::mpsc::channel();
        let (force_send, force_recv) = std::sync::mpsc::channel();
        Self {
            rigid_body_set: RigidBodySet::new(),
            collider_set: ColliderSet::new(),
            pipeline: PhysicsPipeline::new(),
            island_manager: IslandManager::new(),
            broad_phase: BroadPhaseBvh::new(),
            narrow_phase: NarrowPhase::new(),
            integration_parameters: IntegrationParameters::default(),
            gravity: Vector::new(0.0, -9.81, 0.0),
            impulse_joint_set: ImpulseJointSet::new(),
            multibody_joint_set: MultibodyJointSet::new(),
            ccd_solver: CCDSolver::new(),
            physics_hooks: (),
            collision_events: ChannelEventCollector::new(collision_send, force_send),
            collision_recv,
            force_recv,
        }
    }

    fn step(&mut self, delta: f64) {
        self.integration_parameters.dt = delta;
        self.pipeline.step(
            self.gravity,
            &self.integration_parameters,
            &mut self.island_manager,
            &mut self.broad_phase,
            &mut self.narrow_phase,
            &mut self.rigid_body_set,
            &mut self.collider_set,
            &mut self.impulse_joint_set,
            &mut self.multibody_joint_set,
            &mut self.ccd_solver,
            &self.physics_hooks,
            &self.collision_events,
        );
    }

    fn insert_body(&mut self, pos: Vec3Proto) -> RigidBodyHandle {
        let rb = RigidBodyBuilder::dynamic()
            .translation(Vec3::new(pos.x, pos.y, pos.z))
            .linear_damping(NORMAL_LINEAR_DAMPING)
            .angular_damping(0.5)
            .build();
        let handle = self.rigid_body_set.insert(rb);
        let collider = ColliderBuilder::cuboid(1.3, 0.6, 2.4)
            .mass_properties(MassProperties::new(
                Vec3::new(0.0, -0.4, 0.0),
                // Heavier + much higher pitch/roll inertia than a real box (≈886 roll)
                // so the car feels planted and resists tipping; yaw bumped a little for
                // weightier steering. Mirrored in player.gd (mass + inertia).
                1300.0,
                Vec3::new(3400.0, 3200.0, 2800.0),
            ))
            .friction(0.0)
            .collision_groups(CAR_COLLISION)
            .active_events(ActiveEvents::COLLISION_EVENTS)
            .build();
        self.collider_set
            .insert_with_parent(collider, handle, &mut self.rigid_body_set);
        handle
    }

    fn remove_body(&mut self, handle: RigidBodyHandle) {
        self.rigid_body_set.remove(
            handle,
            &mut self.island_manager,
            &mut self.collider_set,
            &mut self.impulse_joint_set,
            &mut self.multibody_joint_set,
            true,
        );
    }

    fn get(&self, handle: RigidBodyHandle) -> Option<&rapier3d_f64::prelude::RigidBody> {
        self.rigid_body_set.get(handle)
    }

    fn get_mut(
        &mut self,
        handle: RigidBodyHandle,
    ) -> Option<&mut rapier3d_f64::prelude::RigidBody> {
        self.rigid_body_set.get_mut(handle)
    }

    /// True when the car has an active solid contact with track geometry
    /// (floor / wall / ramp). Boost pads and hazards are sensors, so they
    /// generate intersections — not contacts — and never count as ground.
    /// Mirrors the client's downward ground-ray so airborne gating agrees.
    fn is_grounded(&self, handle: RigidBodyHandle) -> bool {
        let Some(rb) = self.rigid_body_set.get(handle) else {
            return false;
        };
        let Some(&collider) = rb.colliders().first() else {
            return false;
        };
        self.narrow_phase
            .contact_pairs_with(collider)
            .any(|pair| pair.has_any_active_contact())
    }
}

// Speeds were halved across the board (the game outran the tracks) without
// touching track geometry: drive/brake forces, the lateral-grip caps, all speed
// thresholds, the boost/launch magnitudes and the pad-boost nudge all scale
// together so handling FEEL (accel curve, wash-out point, drift) is preserved at
// half pace. Damping, yaw rates and slip angles are unchanged (turning is
// independent of forward speed; tighter turning at lower speed fits the tracks).
// Master pace multiplier: the drive/brake forces, launch & boost speeds and the
// lateral-grip caps all derive from this single knob, so scaling the whole game's
// speed (and matching acceleration/grip) is one edit. ×1.0 = the tuned baseline;
// ×4/3 bumps the pace by a third. MUST match player.gd.
const PACE_SCALE: f64 = 16.0 / 9.0; // master pace multiplier (was 4/3; bumped another ×4/3 → +1/3 pace)
const THROTTLE_FORCE: f64 = 8_500.0 * PACE_SCALE;
const REVERSE_FORCE: f64 = 2_500.0 * PACE_SCALE;
const BRAKE_FORCE: f64 = 4_000.0 * PACE_SCALE;
const BRAKE_MIN_SPEED: f64 = 0.5;
const MAX_TURN_RATE_GRIP: f64 = 1.2;
const MAX_TURN_RATE_DRIFT: f64 = 3.6; // hard drift rotation: drift+steer keeps biting after the flick
const STEER_P_GAIN: f64 = 25_000.0;
// Lateral traction model (replaces the old velocity-slerp alignment). Each tick we
// cancel sideways velocity up to a capped lateral acceleration (a friction force
// budget). Because the cap is an ACCELERATION, the achievable turn rate is
// `lat_accel / speed` — so the faster you go, the worse pure grip holds a line.
// Cornering needs `speed × yaw_rate` of lateral grip; past the cap the rear washes
// out. Grip's cap is meant to be exceeded at racing pace (turning on grip is the
// "anomaly"); drift's is far lower so the slide deliberately persists and is
// controllable. Past SLIP_BREAK on grip the car "falls into" the drift STATE (see
// the drift-state machine in step()): blend rises, lat_accel drops to drift's — a
// graceful slide, not a punishing spin.
const GRIP_LAT_ACCEL: f64 = 9.0 * PACE_SCALE; // m/s² — holds gentle/slow turns, washes at speed
const DRIFT_LAT_ACCEL: f64 = 4.0 * PACE_SCALE; // m/s² — enough redirect that the drift CARVES the trajectory (camera tracks the path), while still sliding
                                               // Falling into the drift state couples ANGLE and EFFORT (see drift_enter_threshold_deg):
                                               // gentle steering must build the full SLIP_BREAK_DEG of slide, but cranking hard at
                                               // speed drops the bar to SLIP_BREAK_HARD_DEG — you snap into a drift almost at once.
const SLIP_BREAK_DEG: f64 = 18.0; // gentle steering: slip needed to fall into drift
const SLIP_BREAK_HARD_DEG: f64 = 5.0; // full lock at speed: falls in almost at once
const DRIFT_EFFORT_SPEED_REF: f64 = 6.0; // speed (m/s) at which the effort term saturates
const SLIP_EXIT_DEG: f64 = 8.0; // slide settles below this (button up) → back to grip (wide: re-grips early)
                                // Manual-drift initiation flick: pressing the drift key together with a steer
                                // direction snaps the yaw rate hard at once, so a deliberate drift turns in sharply
                                // — always sharper (and more desirable) than merely washing into one on grip.
const DRIFT_FLICK_RATE: f64 = 5.5; // yaw rate (rad/s) the flick snaps to on the press edge — a hard, clear turn-in

// Anti-spin: a hard drift or over-tight turn used to keep piling on yaw until the
// car whipped past its velocity into a spin-out (and, with yaw being the unstable
// intermediate inertia axis, sometimes flipped). Once the slip angle passes
// SPIN_GUARD_DEG we bias the steering's yaw target back toward the velocity, ramping
// to a full SPIN_RESTORE_RATE of counter-yaw by SPIN_LIMIT_DEG. Below the guard a
// big, satisfying drift is untouched; player steer still fights the bias so the
// slide holds — it just can't run away. Mirrored in player.gd.
const SPIN_GUARD_DEG: f64 = 55.0; // slides below this are free (room for big, committed drifts)
const SPIN_LIMIT_DEG: f64 = 84.0; // counter-yaw reaches full strength by here (still short of a 90° spin)
const SPIN_RESTORE_RATE: f64 = 6.0; // rad/s of yaw bias back toward velocity at full excess

// Uprighting assist: a damped restoring torque toward world-up, applied ONLY while
// grounded, so a hard drift flick can't tip the car over — without locking rotation.
// Pitch/roll stay free in the air (future jumps/thrusters/air-control) and for
// transient tilt; only the steady ground state is kept upright. Mirrored in player.gd.
const UPRIGHT_GAIN: f64 = 120_000.0; // restoring torque ∝ tilt ANGLE (works even at 180°)
const UPRIGHT_DAMP: f64 = 32_000.0; // damps the pitch/roll rate (leaves yaw/steering alone)
                                    // Drift is eased in/out via a 0→1 grip-blend instead of a hard switch, so the
                                    // slide builds and releases smoothly — "controlled loss of control".
const GRIP_BLEND_RATE: f64 = 6.0;
// Jump: a grounded hop. On the rising edge of the jump input, if grounded, the
// car's vertical velocity is set to JUMP_SPEED. Starting value — a quick arcade
// hop; tune to taste. Mirrored in player.gd.
const JUMP_SPEED: f64 = 14.0;
const MOTION_DIRECTION_EPSILON: f64 = 0.25;
const CAR_COLLISION: InteractionGroups = InteractionGroups::new(
    Group::GROUP_2,
    Group::GROUP_1.union(Group::GROUP_3),
    InteractionTestMode::And,
);

const NORMAL_LINEAR_DAMPING: f64 = 0.3;
const DRIFT_LINEAR_DAMPING: f64 = 0.18;
const DRIFT_MIN_SPEED: f64 = 1.5;

// Coyote grace for the grounded test: keep the car "grounded" for a short beat
// after it loses contact, so a bump, a ramp seam, or a crest can't blip driving
// inputs (throttle / grip / boost) off for a frame. Real jumps (air > this) still
// switch to the air-control regime. Mirrors player.gd. Starting value 0.10 s
// (Celeste-style coyote time is ~0.1 s; Source: Maddy Thorson, Celeste postmortem).
const COYOTE_GROUND_SECS: f64 = 0.10;

// Stuck auto-respawn: a safety net so a car wedged against a wall, flipped, or
// fallen off the line never sits dead for the whole race. While racing, if a car
// stays below STUCK_SPEED for STUCK_RESPAWN_SECS it is teleported to its last
// checkpoint (same path as a manual respawn). Generous thresholds so a normal
// spin-out recovery or the grid scramble at GO never trips it.
const STUCK_RESPAWN_SECS: f64 = 5.0;
const STUCK_SPEED: f64 = 2.5;

// Cruise speed is THROTTLE_FORCE / (mass·damping) = 8500·PACE_SCALE / (1000·0.3).
// The launch (rocket start) is server-authoritative. Quality is graded on the
// SIGNED offset of the player's FIRST throttle press relative to GO: 0 = exactly on
// GO (perfect), negative = jumped early / held throttle, positive = slow reaction.
// quality = (1 - |offset|/LAUNCH_WINDOW)^LAUNCH_SHARPNESS, so both early and late
// presses fall below 100% and nailing a true 100% is frame-precise. Holding from
// the countdown reads as a large negative offset → no boost. A perfect launch
// slightly OVERSHOOTS cruise (a real head start). Mirrored in player.gd.
const LAUNCH_WINDOW: f64 = 0.40; // seconds either side of GO that still scores; beyond it → 0
const LAUNCH_SHARPNESS: f64 = 1.3; // >1 steepens the falloff; gentler now so near-misses still score well
const LAUNCH_SPEED: f64 = 32.0 * PACE_SCALE; // perfect-launch speed (≈ cruise + overshoot)
const PAD_BOOST_SCALE: f64 = 0.5; // scales track pad-boost strengths to the halved speeds

// Charge fills the bar at full rate up to BOOST_CHARGE_KNEE (~2/3), then tapers to
// BOOST_CHARGE_TOP_FACTOR of that rate as it approaches full — so maxing the bar
// takes a long, committed drift. See boost_charge_increment (mirrored in player.gd).
// Base fill is slow; the angle term adds up to BOOST_CHARGE_ANGLE_RATE more as the
// slip angle approaches BOOST_CHARGE_ANGLE_REF_DEG — so a big, committed slide
// charges fast while a shallow drift barely fills. See boost_charge_increment.
const BOOST_CHARGE_RATE: f64 = 0.11; // slow base fill (drift bar fills gradually)
const BOOST_CHARGE_ANGLE_RATE: f64 = 0.36; // extra fill rate at a full-angle slide
const BOOST_CHARGE_ANGLE_REF_DEG: f64 = 35.0; // slip angle (°) at which the angle term saturates
const BOOST_CHARGE_KNEE: f64 = 0.667; // first 2/3 fill normally
const BOOST_CHARGE_TOP_FACTOR: f64 = 0.25; // last third is degressive (down to 25% rate)
const BOOST_CHARGE_DECAY: f64 = 2.0;
const BOOST_CHARGE_MIN: f64 = 0.15;
const BOOST_PEAK_BONUS: f64 = 11.5 * PACE_SCALE; // drift-boost overshoot above cruise
const BOOST_DURATION: f64 = 1.5;
const BOOST_ALIGN_THRESHOLD_COS: f64 = 0.9781476; // cos(12°)
const BOOST_PENDING_TIMEOUT: f64 = 1.5;
const BOOST_SUSTAIN_FORCE: f64 = 16_500.0 * PACE_SCALE; // scales with the drive force

// Turbo: a SECOND, manually-spent bar, separate from the auto drift-boost above.
// It fills while drifting (faster the more angular the slide) and is spent by
// holding the turbo key — a strong forward push toward +50% of cruise speed,
// draining the bar. Drift and turbo can run at the same time. Mirrored in player.gd.
// Cruise = THROTTLE_FORCE / (mass·damping); the turbo cap is 1.5× that.
const CRUISE_SPEED: f64 = THROTTLE_FORCE / (1000.0 * NORMAL_LINEAR_DAMPING);
const TURBO_PEAK_SPEED: f64 = 1.5 * CRUISE_SPEED;
const TURBO_FORCE: f64 = 30_000.0 * PACE_SCALE; // big, fast push (gated by the cap above)
const TURBO_CHARGE_RATE: f64 = 0.04; // base fill/s while drifting (turbo accrues slowly)
const TURBO_CHARGE_ANGLE_RATE: f64 = 0.15; // extra fill/s at a full-angle slide
const TURBO_DRAIN_RATE: f64 = 0.5; // a full bar lasts ~2 s of turbo

/// Six visually distinct car tints, handed out by lobby slot index so every
/// racer in a lobby gets a unique colour, kept for as long as they hold the slot.
const PLAYER_PALETTE: [[f64; 3]; 6] = [
    [0.90, 0.16, 0.16], // red
    [0.16, 0.42, 0.95], // blue
    [0.20, 0.80, 0.32], // green
    [0.95, 0.82, 0.16], // yellow
    [0.80, 0.24, 0.85], // magenta
    [0.96, 0.52, 0.12], // orange
];

fn palette_color(idx: u8) -> ColorProto {
    let c = PLAYER_PALETTE[(idx as usize) % PLAYER_PALETTE.len()];
    ColorProto {
        x: c[0],
        y: c[1],
        z: c[2],
    }
}

const FINISH_WAIT_SECS: f64 = 30.0;
const COUNTDOWN_SECS: f64 = 5.0; // lobby-ready countdown shown in the lobby page
/// Hard cap so a race always ends even if nobody ever finishes (e.g. every car
/// is stuck or wandered off) — otherwise `race()` would loop forever.
const MAX_RACE_SECS: f64 = 240.0;
/// Brief hold in Intermission right after a race so the standings are readable
/// before the next lobby countdown begins.
const RESULT_HOLD_SECS: f64 = 6.0;
/// Starting-grid layout: two columns ±SPAWN_LANE across the start tangent, rows
/// SPAWN_ROW apart stepped back behind the line. Tight enough for six cars.
const SPAWN_LANE: f64 = 5.0;
const SPAWN_ROW: f64 = 8.0;
const PRE_COUNTDOWN_SECS: f64 = 2.0; // silent beat on-track before the top départ lights
const STARTING_SECS: f64 = 3.0; // on-track "top départ" (3-2-1) after the silent beat
const STATE_SYNC_INTERVAL: f64 = 0.05;

#[derive(Default, Clone, Copy)]
struct PlayerInput {
    throttle: bool,
    steer_left: f64,
    steer_right: f64,
    drift: bool,
    turbo: bool,
    jump: bool,
}

#[derive(Default, Clone, Copy, PartialEq)]
enum BoostState {
    #[default]
    Idle,
    Pending,
    Boosting,
}

/// One tick of drift-boost charge: full rate over the first ~2/3 of the bar, then
/// tapering through the final third so topping it off demands a long, sustained
/// drift. Mirrored verbatim in player.gd.
fn boost_charge_increment(charge: f64, slip_deg: f64, delta: f64) -> f64 {
    let taper = if charge < BOOST_CHARGE_KNEE {
        1.0
    } else {
        let f = (charge - BOOST_CHARGE_KNEE) / (1.0 - BOOST_CHARGE_KNEE);
        1.0 + (BOOST_CHARGE_TOP_FACTOR - 1.0) * f
    };
    // Slow base fill, faster the more sideways the car is (bigger slip angle).
    let angle01 = (slip_deg.abs() / BOOST_CHARGE_ANGLE_REF_DEG).clamp(0.0, 1.0);
    let rate = BOOST_CHARGE_RATE + BOOST_CHARGE_ANGLE_RATE * angle01;
    (charge + rate * taper * delta).min(1.0)
}

fn update_boost_fsm(
    racer: &mut Racer,
    rb: &mut rapier3d_f64::prelude::RigidBody,
    forward_dir: &Vec3,
    speed: f64,
    slip_deg: f64,
    delta: f64,
    grounded: bool,
) {
    // Charge accumulates whenever DRIFTING (the state), however it was entered —
    // even a slid-in drift with no key held. Decays otherwise. Grounded only.
    if grounded && racer.drift_state && speed > DRIFT_MIN_SPEED {
        racer.boost_charge = boost_charge_increment(racer.boost_charge, slip_deg, delta);
    } else if racer.boost_state != BoostState::Pending {
        racer.boost_charge = (racer.boost_charge - BOOST_CHARGE_DECAY * delta).max(0.0);
    }

    // The boost arms when the drift ENDS (you straighten / re-grip), so it fires off
    // any drift — held or slid-into.
    let drift_just_ended = racer.prev_drift_state && !racer.drift_state;

    match racer.boost_state {
        BoostState::Idle => {
            if drift_just_ended && racer.boost_charge >= BOOST_CHARGE_MIN {
                racer.boost_state = BoostState::Pending;
                racer.boost_pending_t = BOOST_PENDING_TIMEOUT;
            }
        }
        BoostState::Pending => {
            racer.boost_pending_t -= delta;
            // Cancelled by re-entering a drift (charge keeps building) or by timing out.
            if racer.drift_state || racer.boost_pending_t <= 0.0 {
                racer.boost_state = BoostState::Idle;
            } else if grounded && speed > 1.0 {
                let vel = rb.linvel();
                let vel_dir = vel / speed;
                let dot = vel_dir.dot(*forward_dir);
                if dot >= BOOST_ALIGN_THRESHOLD_COS {
                    let base = speed.max(DRIFT_MIN_SPEED);
                    racer.boost_peak_speed = base + BOOST_PEAK_BONUS * racer.boost_charge;
                    let new_speed = racer.boost_peak_speed.max(speed);
                    rb.set_linvel(*forward_dir * new_speed, true);
                    racer.boost_state = BoostState::Boosting;
                    racer.boost_t_remaining = BOOST_DURATION;
                    racer.boost_charge = 0.0;
                }
            }
        }
        BoostState::Boosting => {
            racer.boost_t_remaining -= delta;
            if racer.boost_t_remaining <= 0.0 {
                racer.boost_state = BoostState::Idle;
            } else {
                // Sustain: if forward speed dropped below target, push it back up.
                let forward_speed = forward_dir.dot(rb.linvel());
                if grounded && forward_speed < racer.boost_peak_speed {
                    rb.add_force(*forward_dir * BOOST_SUSTAIN_FORCE, true);
                }
            }
        }
    }
}

/// Turbo: a second bar, separate from the drift-boost FSM. Fills while drifting
/// (faster the more angular the slide), spent by holding the turbo key for a
/// strong forward push toward TURBO_PEAK_SPEED. Drift and turbo are independent —
/// both can be active in the same tick. Mirrored in player.gd (`_update_turbo`).
fn update_turbo(
    racer: &mut Racer,
    rb: &mut rapier3d_f64::prelude::RigidBody,
    forward_dir: &Vec3,
    speed: f64,
    slip_deg: f64,
    delta: f64,
    grounded: bool,
) {
    if grounded && racer.drift_state && speed > DRIFT_MIN_SPEED {
        let angle01 = (slip_deg.abs() / BOOST_CHARGE_ANGLE_REF_DEG).clamp(0.0, 1.0);
        let rate = TURBO_CHARGE_RATE + TURBO_CHARGE_ANGLE_RATE * angle01;
        racer.turbo_charge = (racer.turbo_charge + rate * delta).min(1.0);
    }

    racer.turbo_active = false;
    if racer.input.turbo && racer.turbo_charge > 0.0 && grounded {
        racer.turbo_charge = (racer.turbo_charge - TURBO_DRAIN_RATE * delta).max(0.0);
        racer.turbo_active = true;
        let forward_speed = forward_dir.dot(rb.linvel());
        if forward_speed < TURBO_PEAK_SPEED {
            rb.add_force(*forward_dir * TURBO_FORCE, true);
        }
    }
}

fn update_reverse_mode(
    was_reversing: bool,
    forward_speed: f64,
    drift: bool,
    throttle: bool,
) -> bool {
    if forward_speed <= -MOTION_DIRECTION_EPSILON {
        true
    } else if forward_speed >= MOTION_DIRECTION_EPSILON || throttle {
        false
    } else if drift {
        true
    } else {
        was_reversing
    }
}

fn effective_steer_input(steer: f64, is_reversing: bool) -> f64 {
    if is_reversing {
        -steer
    } else {
        steer
    }
}

/// Slip angle (degrees) at which pure grip falls into the drift state. It couples
/// angle with EFFORT: `steer_effort` is |steer| in 0..1, scaled by how fast you're
/// going. Gentle steering needs the full SLIP_BREAK_DEG of slide; cranking hard at
/// speed drops the bar toward SLIP_BREAK_HARD_DEG so you snap into a drift fast.
/// Mirrored in player.gd.
fn drift_enter_threshold_deg(steer_effort: f64, speed: f64) -> f64 {
    let speed_factor =
        ((speed - DRIFT_MIN_SPEED) / (DRIFT_EFFORT_SPEED_REF - DRIFT_MIN_SPEED)).clamp(0.0, 1.0);
    let effort = steer_effort.clamp(0.0, 1.0) * speed_factor;
    SLIP_BREAK_DEG + (SLIP_BREAK_HARD_DEG - SLIP_BREAK_DEG) * effort
}

/// Rocket-start quality in 0..1 from the SIGNED press offset (seconds) relative to
/// GO: 0 = perfect, ±LAUNCH_WINDOW or beyond = 0. The falloff is symmetric (early
/// holds are penalised exactly like slow reactions) and raised to LAUNCH_SHARPNESS
/// so a true 100% is frame-precise. Mirrored in player.gd (`_launch_quality`).
fn launch_quality(offset: f64) -> f64 {
    let off = offset.abs();
    if off >= LAUNCH_WINDOW {
        return 0.0;
    }
    (1.0 - off / LAUNCH_WINDOW).powf(LAUNCH_SHARPNESS)
}

/// Output of one handling tick: the yaw torque impulse to apply and the new
/// horizontal velocity after lateral traction. Kept as a pure function so it is
/// the single source of the formula — `Lobby::step` applies it to the rapier
/// body, the client mirrors it in player.gd, and a unit test drives it directly.
struct Handling {
    torque_y: f64,
    vel_x: f64,
    vel_z: f64,
    // `over_break` = grip slip exceeded SLIP_BREAK this tick (the drift-state machine
    // uses the same threshold to fall into a drift). Read by the handling unit test
    // and available for telemetry; the live loop only needs the torque + velocity.
    #[allow(dead_code)]
    over_break: bool,
    #[allow(dead_code)]
    slip_deg: f64,
}

/// Steering + lateral-grip for one tick, in the horizontal plane.
/// `(vx, vz)` velocity, `(hx, hz)` unit heading, `steer` already reverse-adjusted,
/// `blend` is the eased grip(0)→drift(1) state. Returns the yaw impulse and the
/// post-traction horizontal velocity (caller keeps the vertical component).
#[allow(clippy::too_many_arguments)]
fn handling_step(
    vx: f64,
    vz: f64,
    hx: f64,
    hz: f64,
    yaw_rate: f64,
    steer: f64,
    blend: f64,
    grounded: bool,
    reversing: bool,
    dt: f64,
) -> Handling {
    let max_turn = MAX_TURN_RATE_GRIP + (MAX_TURN_RATE_DRIFT - MAX_TURN_RATE_GRIP) * blend;

    let h_speed = (vx * vx + vz * vz).sqrt();
    // Airborne / reversing / nearly stopped: steer only, no traction shaping and no
    // anti-spin (which needs a real velocity direction) — matches the old behaviour.
    if !grounded || reversing || h_speed < 0.5 {
        let yaw_target = -steer * max_turn;
        return Handling {
            torque_y: (yaw_target - yaw_rate) * STEER_P_GAIN * dt,
            vel_x: vx,
            vel_z: vz,
            over_break: false,
            slip_deg: 0.0,
        };
    }

    // Split horizontal velocity into forward (along heading) + lateral.
    let v_fwd = vx * hx + vz * hz;
    let lat_x = vx - hx * v_fwd;
    let lat_z = vz - hz * v_fwd;
    let v_lat = (lat_x * lat_x + lat_z * lat_z).sqrt();
    let slip = v_lat.atan2(v_fwd.abs()); // unsigned slip magnitude (rad)
    let cross_y = hx * vz - hz * vx; // sign = which side the velocity slides to

    // Anti-spin: once the slide passes SPIN_GUARD_DEG, bias the yaw target back toward
    // the velocity (ramping to SPIN_RESTORE_RATE by SPIN_LIMIT_DEG) so a hard drift or
    // over-tight turn can't whip the car past control into a spin-out. Player steer
    // still fights the bias, so a deep slide holds — it just can't run away.
    let excess =
        ((slip.to_degrees() - SPIN_GUARD_DEG) / (SPIN_LIMIT_DEG - SPIN_GUARD_DEG)).clamp(0.0, 1.0);
    let yaw_target = -steer * max_turn - cross_y.signum() * SPIN_RESTORE_RATE * excess;
    let torque_y = (yaw_target - yaw_rate) * STEER_P_GAIN * dt;

    // Pure lateral grip: cap the sideways cancellation by mode. No collapse here —
    // when grip slip crosses SLIP_BREAK the drift-state machine raises `blend`, which
    // *itself* drops lat_accel to drift's value (the "fall into the drift").
    let lat_accel = GRIP_LAT_ACCEL + (DRIFT_LAT_ACCEL - GRIP_LAT_ACCEL) * blend;
    let over_break = blend < 0.5 && slip > SLIP_BREAK_DEG.to_radians();

    // Cancel lateral velocity, capped at lat_accel·dt (a capped friction force).
    let max_cancel = lat_accel * dt;
    let (mut new_lat_x, mut new_lat_z) = (lat_x, lat_z);
    if v_lat > 1e-6 {
        let keep = (1.0 - max_cancel / v_lat).max(0.0);
        new_lat_x = lat_x * keep;
        new_lat_z = lat_z * keep;
    }

    Handling {
        torque_y,
        vel_x: hx * v_fwd + new_lat_x,
        vel_z: hz * v_fwd + new_lat_z,
        over_break,
        slip_deg: slip.to_degrees() * cross_y.signum(),
    }
}

/// New angular velocity for a manual drift flick: set the spin about the car's own
/// up axis to `signed_rate` while preserving any pitch/roll. Keeping the flick a
/// pure yaw about the body's up (not world Y) means a flick on a banked surface
/// can't inject a tumble that flips the car. Mirrored inline in player.gd.
fn drift_flick_angvel(current: Vec3, up: Vec3, signed_rate: f64) -> Vec3 {
    let up = up.normalize();
    let perp = current - up * current.dot(up); // pitch/roll component, preserved
    perp + up * signed_rate
}

fn stabilize_quaternion(prev: Option<QuatProto>, current: QuatProto) -> QuatProto {
    let Some(prev) = prev else {
        return current;
    };

    let dot = prev.x * current.x + prev.y * current.y + prev.z * current.z + prev.w * current.w;
    if dot < 0.0 {
        QuatProto {
            x: -current.x,
            y: -current.y,
            z: -current.z,
            w: -current.w,
        }
    } else {
        current
    }
}

pub(crate) struct Racer {
    nickname: String,
    racing: bool,
    color: ColorProto,
    tx: tokio::sync::mpsc::Sender<OutgoingMessage>,
    rx_channel: crossbeam::channel::Receiver<PlayerEvent>,
    idx: u8,
    rigid_body: RigidBodyHandle,
    input: PlayerInput,
    prev_drift: bool,
    prev_drift_state: bool,
    launch_done: bool,
    // Signed time (s) of the player's first throttle press relative to GO (negative
    // = pressed/held during the countdown, positive = after GO). None until they
    // first hit the gas. Graded by launch_quality() at the rocket start.
    launch_press_offset: Option<f64>,
    laps: u8,
    // Per-gate previous signed distance along the gate's forward normal (sized
    // lazily to track.gates), plus the checkpoint gate indices crossed this lap.
    prev_d: Vec<f64>,
    checkpoints_hit: HashSet<usize>,
    // Gate index of the last checkpoint crossed this lap (None = none yet, so a
    // respawn falls back to the start). Set in check_lap_crossings.
    last_checkpoint: Option<usize>,
    // Edge-detection for the respawn input, plus a one-shot flag the physics pass
    // consumes to teleport the car back to last_checkpoint.
    prev_respawn: bool,
    respawn_requested: bool,
    // Edge-detection for the jump input (a grounded hop fires on the rising edge).
    prev_jump: bool,
    finished: bool,
    reversing: bool,
    grip_blend: f64,
    drift_state: bool,
    last_sent_rotation: Option<QuatProto>,
    boost_state: BoostState,
    boost_charge: f64,
    boost_t_remaining: f64,
    boost_pending_t: f64,
    boost_peak_speed: f64,
    // Turbo (second, manually-spent bar; see update_turbo). Independent of boost.
    turbo_charge: f64,
    turbo_active: bool,
    // Seconds the car has been (near-)stationary while racing; trips the stuck
    // auto-respawn at STUCK_RESPAWN_SECS. Reset whenever it gets moving again.
    stuck_time: f64,
    // Seconds since the car last had solid ground contact, for coyote grace on
    // the grounded test (see COYOTE_GROUND_SECS). Mirrors player.gd `_air_time`.
    air_time: f64,
}

impl Racer {
    fn new(
        nickname: String,
        idx: u8,
        color: ColorProto,
        tx: tokio::sync::mpsc::Sender<OutgoingMessage>,
        rx_channel: crossbeam::channel::Receiver<PlayerEvent>,
        handle: RigidBodyHandle,
    ) -> Self {
        Self {
            nickname,
            racing: false,
            color,
            tx,
            rx_channel,
            idx,
            rigid_body: handle,
            input: PlayerInput::default(),
            prev_drift: false,
            prev_drift_state: false,
            launch_done: false,
            launch_press_offset: None,
            laps: 0,
            prev_d: Vec::new(),
            checkpoints_hit: HashSet::new(),
            last_checkpoint: None,
            prev_respawn: false,
            respawn_requested: false,
            prev_jump: false,
            finished: false,
            reversing: false,
            grip_blend: 0.0,
            drift_state: false,
            last_sent_rotation: None,
            boost_state: BoostState::Idle,
            boost_charge: 0.0,
            boost_t_remaining: 0.0,
            boost_pending_t: 0.0,
            boost_peak_speed: 0.0,
            turbo_charge: 0.0,
            turbo_active: false,
            stuck_time: 0.0,
            air_time: 0.0,
        }
    }
}

enum PlayerEvent {
    Close,
    Message(ClientMessage),
}

enum State {
    Intermission,
    Countdown,
    Starting,
    Racing,
}

pub struct Lobby {
    pub(crate) owner: String,
    pub(crate) start_time: String,
    pub(crate) min_players: u8,
    pub(crate) max_players: u8,
    pub(crate) racers: HashMap<String, Racer>,
    state: State,
    sync_timer: f64,
    intermission_timer: f64,
    sync_countdown_timer: f64,
    start_timer: f64,
    countdown_timer: f64,
    last_countdown_light: i32,
    spawn_point: Vector3<f64>,
    spawn_y_rotation: f64,
    physics: PhysicsWorld,
    race_timer: f64,
    finish_timer: f64,
    last_finish_count: i32, // last whole-second finish countdown broadcast (-1 = none)
    result_hold: f64,
    finishers: Vec<String>,
    boost_pads: HashMap<ColliderHandle, f64>,
    hazards: HashSet<ColliderHandle>,
    track: Arc<TrackDef>,
}

impl Lobby {
    pub fn new(
        owner: String,
        start_time: String,
        min_players: u8,
        max_players: u8,
        track: Arc<TrackDef>,
    ) -> Self {
        // Spawn point + heading come from the start/start_finish gate (nalgebra),
        // converted to the cgmath Vector3 the lobby uses.
        let (sp, spawn_y_rotation) = track.spawn();
        let spawn_point = Vector3::new(sp.x, sp.y, sp.z);
        let mut physics = PhysicsWorld::new();
        let track_colliders = track.build_colliders(&mut physics.collider_set);
        Self {
            owner,
            start_time,
            min_players,
            max_players,
            racers: HashMap::new(),
            state: State::Intermission,
            sync_timer: 0.,
            intermission_timer: 0.,
            sync_countdown_timer: 0.,
            start_timer: 0.,
            countdown_timer: 0.,
            last_countdown_light: -1,
            spawn_point,
            spawn_y_rotation,
            physics,
            race_timer: 0.,
            finish_timer: 0.,
            last_finish_count: -1,
            result_hold: 0.,
            finishers: Vec::new(),
            boost_pads: track_colliders.boost_pads,
            hazards: track_colliders.hazards,
            track,
        }
    }

    pub(crate) fn join(
        &mut self,
        nickname: String,
        _color: ColorProto, // ignored: colour is assigned from the palette by slot
        cached_track_hash: Option<String>,
        tx_out: tokio::sync::mpsc::Sender<OutgoingMessage>,
        rx_stream: SplitStream<WebSocketStream<TcpStream>>,
    ) -> Result<()> {
        if self.racers.contains_key(&nickname) {
            sr_log!(
                trace,
                "LOBBY",
                "join rejected: nickname={} already used",
                nickname
            );
            send_join_error(&tx_out, JoinError::NicknameAlreadyUsed);
            return Err(Error::ClientNicknameAlreadyUsed);
        }
        if self.racers.len() >= self.max_players as usize {
            sr_log!(
                trace,
                "LOBBY",
                "join rejected: lobby full ({}/{})",
                self.racers.len(),
                self.max_players
            );
            send_join_error(&tx_out, JoinError::LobbyFull);
            return Err(Error::ClientLobbyFull);
        }

        let player_idx = self.first_free_idx();

        // Only ship the full track when the client doesn't already hold this exact
        // version (its cached hash differs, or it has none) — so an unchanged track
        // is never re-downloaded.
        let send_track = cached_track_hash.as_deref() != Some(self.track.hash.as_str());
        let join_msg = ServerMessage::Response(Response::LobbyJoined {
            track_id: self.track.id.clone(),
            track_hash: self.track.hash.clone(),
            race_ongoing: matches!(self.state, State::Starting | State::Racing),
            min_players: self.min_players,
            max_players: self.max_players,
            error: None,
            track: if send_track {
                Some(Box::new((*self.track).clone()))
            } else {
                None
            },
        });
        let _ = try_queue_outgoing(&tx_out, outgoing_server_message(&join_msg));

        let (tx_channel, rx_channel) = crossbeam::channel::unbounded::<PlayerEvent>();
        launch_client_reader(tx_channel, rx_stream);

        let sp = &self.spawn_point;
        let handle = self.physics.insert_body(Vec3Proto {
            x: sp.x,
            y: sp.y,
            z: sp.z,
        });
        let racer = Racer::new(
            nickname.clone(),
            player_idx,
            palette_color(player_idx),
            tx_out,
            rx_channel,
            handle,
        );
        self.racers.insert(nickname.clone(), racer);
        sr_log!(
            info,
            "LOBBY",
            "player joined: nickname={} idx={} ({}/{} players)",
            nickname,
            player_idx,
            self.racers.len(),
            self.max_players
        );
        Ok(())
    }

    pub fn update(&mut self, delta: f64) -> bool {
        self.process_player_events(delta);
        if self.racers.is_empty() {
            return false;
        }

        self.apply_respawns();
        let state_snapshot = self.prepare_player_state_sync(delta);
        self.physics.step(delta);
        self.handle_boost_pads();
        self.check_lap_crossings();
        if let Some(states) = state_snapshot {
            self.broadcast_player_state_snapshot(states);
        }
        self.tick_state_machine(delta);
        true
    }

    pub fn player_count(&self) -> u8 {
        self.racers.len() as u8
    }

    fn handle_boost_pads(&mut self) {
        let events: Vec<CollisionEvent> = self.physics.collision_recv.try_iter().collect();
        for event in events {
            let CollisionEvent::Started(h1, h2, _) = event else {
                continue;
            };

            // Boost pad: nudge the car's horizontal velocity forward.
            let pad = if let Some(&strength) = self.boost_pads.get(&h1) {
                Some((h2, strength))
            } else if let Some(&strength) = self.boost_pads.get(&h2) {
                Some((h1, strength))
            } else {
                None
            };
            if let Some((car_collider, boost_strength)) = pad {
                let Some(rb_handle) = self
                    .physics
                    .collider_set
                    .get(car_collider)
                    .and_then(|c| c.parent())
                else {
                    continue;
                };
                let Some(rb) = self.physics.rigid_body_set.get_mut(rb_handle) else {
                    continue;
                };
                let vel = rb.linvel();
                let mut horiz = vel;
                horiz.y = 0.0;
                let horiz_speed = horiz.length();
                if horiz_speed > 0.1 {
                    // Scaled to the halved speed regime without editing track JSON.
                    let boost_vec = horiz / horiz_speed * boost_strength * PAD_BOOST_SCALE;
                    let new_vel = Vec3::new(vel.x + boost_vec.x, vel.y, vel.z + boost_vec.z);
                    rb.set_linvel(new_vel, true);
                }
                continue;
            }

            // Hazard (e.g. a void catch-plane under a precipice): arm a respawn so
            // the car returns to its LAST CHECKPOINT (via apply_respawns next tick),
            // not all the way to the start — falling at lap 3 shouldn't undo the run.
            let hazard_car = if self.hazards.contains(&h1) {
                Some(h2)
            } else if self.hazards.contains(&h2) {
                Some(h1)
            } else {
                None
            };
            if let Some(car_collider) = hazard_car {
                let Some(rb_handle) = self
                    .physics
                    .collider_set
                    .get(car_collider)
                    .and_then(|c| c.parent())
                else {
                    continue;
                };
                if let Some(racer) = self.racers.values_mut().find(|r| r.rigid_body == rb_handle) {
                    racer.respawn_requested = true;
                }
            }
        }
    }

    pub fn is_racing(&self) -> bool {
        matches!(self.state, State::Racing)
    }

    pub fn track_name(&self) -> &str {
        &self.track.name
    }

    pub fn track_id(&self) -> &str {
        &self.track.id
    }

    fn process_player_events(&mut self, delta: f64) {
        let mut to_remove = Vec::new();
        let is_racing = self.is_racing();
        let race_timer = self.race_timer; // time since GO, for the launch window

        // Signed seconds relative to GO right now, used to time-stamp the player's
        // first throttle press for the rocket start. Negative during the on-track
        // countdown (Starting), 0 at GO, positive once racing.
        let press_offset_now: Option<f64> = match self.state {
            State::Starting => Some(self.start_timer - (PRE_COUNTDOWN_SECS + STARTING_SECS)),
            State::Racing => Some(race_timer),
            _ => None,
        };

        for (nickname, racer) in &mut self.racers {
            let mut should_remove = false;
            while let Ok(event) = racer.rx_channel.try_recv() {
                match event {
                    PlayerEvent::Close => {
                        should_remove = true;
                        break;
                    }
                    PlayerEvent::Message(ClientMessage::State {
                        throttle,
                        steer_left,
                        steer_right,
                        drift,
                        respawn,
                        turbo,
                        jump,
                    }) => {
                        sr_log!(
                            trace,
                            "INPUT",
                            "{}: throttle={} steer=(-{:.2},+{:.2}) drift={}",
                            nickname,
                            throttle,
                            steer_left,
                            steer_right,
                            drift
                        );
                        // Rising edge of the respawn key arms a one-shot teleport,
                        // applied in apply_respawns() before the physics step.
                        if respawn && !racer.prev_respawn {
                            racer.respawn_requested = true;
                        }
                        racer.prev_respawn = respawn;
                        racer.input = PlayerInput {
                            throttle,
                            steer_left,
                            steer_right,
                            drift,
                            turbo,
                            jump,
                        };
                    }
                    PlayerEvent::Message(_) => {}
                }
            }

            if should_remove {
                to_remove.push(nickname.clone());
                continue;
            }

            // Time-stamp the FIRST throttle press of the start sequence (countdown or
            // race) for the rocket-start grade. Runs even during the countdown, so
            // holding the gas early is captured as a large-negative (penalised) offset.
            if !racer.launch_done && racer.launch_press_offset.is_none() && racer.input.throttle {
                if let Some(off) = press_offset_now {
                    racer.launch_press_offset = Some(off);
                }
            }

            if !is_racing {
                continue;
            }

            // A finished racer is done driving — its car coasts to a stop (rapier
            // damping) while it spectates, so a held throttle doesn't carry it off.
            if racer.finished {
                continue;
            }

            // Airborne gating: with no wheels on the ground, driving inputs
            // (throttle, reverse, brake, drift, velocity re-alignment, boost)
            // are disabled — only orientation stays available for landing. A short
            // coyote grace keeps the car "grounded" for a beat after losing contact
            // so a bump/ramp seam can't blip those inputs off (mirrors player.gd).
            let raw_grounded = self.physics.is_grounded(racer.rigid_body);
            if raw_grounded {
                racer.air_time = 0.0;
            } else {
                racer.air_time += delta;
            }
            let grounded = raw_grounded || racer.air_time < COYOTE_GROUND_SECS;

            let rb = self.physics.get_mut(racer.rigid_body).unwrap();

            let speed = rb.linvel().length();
            rb.reset_forces(true);

            // Stuck auto-respawn safety net: if the car has crawled below STUCK_SPEED
            // for STUCK_RESPAWN_SECS it's wedged/flipped/off-line — arm a respawn
            // (consumed by apply_respawns later this tick, routing it to the last
            // checkpoint). Covers both players and bots with one rule.
            if speed < STUCK_SPEED {
                racer.stuck_time += delta;
                if racer.stuck_time >= STUCK_RESPAWN_SECS {
                    racer.respawn_requested = true;
                    racer.stuck_time = 0.0;
                }
            } else {
                racer.stuck_time = 0.0;
            }

            // Note: rapier puts -Z as the canonical "forward" for our cars (see existing
            // `forward_speed = -forward.dot(...)`), so the unrotated forward is +Z and the
            // velocity-aligned axis is -forward.
            let forward = *rb.rotation() * Vec3::new(0., 0., 1.);
            let forward_dir_world = -forward; // points in the direction the car is facing
                                              // Horizontal projection of the car's facing direction. Used for velocity
                                              // alignment and boost so ramps don't redirect velocity upward.
            let horiz_forward = {
                let mut h = forward_dir_world;
                h.y = 0.0;
                let l = h.length();
                if l > 1e-4 {
                    h / l
                } else {
                    forward_dir_world
                }
            };

            // Server-authoritative launch (rocket start): grade the player's first
            // throttle press by its offset from GO (captured above, may be negative)
            // and propel the car to LAUNCH_SPEED·quality. Sustained via the boost FSM.
            if !racer.launch_done {
                if let Some(offset) = racer.launch_press_offset {
                    racer.launch_done = true;
                    let quality = launch_quality(offset);
                    if quality > 0.0 {
                        let target = LAUNCH_SPEED * quality;
                        let lv = rb.linvel();
                        if target > horiz_forward.dot(lv) {
                            rb.set_linvel(horiz_forward * target + Vec3::new(0.0, lv.y, 0.0), true);
                            racer.boost_state = BoostState::Boosting;
                            racer.boost_t_remaining = BOOST_DURATION;
                            racer.boost_peak_speed = target;
                        }
                    }
                } else if race_timer > LAUNCH_WINDOW {
                    racer.launch_done = true; // window passed without a press → no launch
                }
            }

            // Drift STATE, decoupled from the button: the drift key *forces* the
            // state on, but turning too hard on grip also makes the car slide into
            // it past the break angle (Rocket-Racing style). It releases once the
            // slide has settled below SLIP_EXIT and the key is up. `grip_blend` then
            // eases toward this state — handling never snaps.
            let slip = {
                let v = rb.linvel();
                let v_fwd = v.x * horiz_forward.x + v.z * horiz_forward.z;
                let lat = (v.x - horiz_forward.x * v_fwd).hypot(v.z - horiz_forward.z * v_fwd);
                lat.atan2(v_fwd.abs())
            };
            let steer_effort = (racer.input.steer_right - racer.input.steer_left).abs();
            let enter_thresh = drift_enter_threshold_deg(steer_effort, speed).to_radians();
            let drift_capable = grounded && speed > DRIFT_MIN_SPEED;
            if drift_capable && (racer.input.drift || slip > enter_thresh) {
                racer.drift_state = true;
            } else if !drift_capable || slip < SLIP_EXIT_DEG.to_radians() {
                racer.drift_state = false;
            }
            let drift_target = if racer.drift_state { 1.0 } else { 0.0 };
            racer.grip_blend +=
                (drift_target - racer.grip_blend) * (delta * GRIP_BLEND_RATE).clamp(0.0, 1.0);
            let blend = racer.grip_blend;

            let forward_speed = -forward.dot(rb.linvel());
            racer.reversing = update_reverse_mode(
                racer.reversing,
                forward_speed,
                racer.input.drift,
                racer.input.throttle,
            );

            if grounded {
                if racer.input.throttle && !racer.reversing {
                    rb.add_force(-forward * THROTTLE_FORCE, true);
                }

                if !racer.input.throttle && racer.reversing {
                    rb.add_force(forward * REVERSE_FORCE, true);
                }

                if racer.input.drift && !racer.input.throttle && forward_speed > BRAKE_MIN_SPEED {
                    let v = rb.linvel();
                    if v.length() > 0.01 {
                        rb.add_force(-v.normalize() * BRAKE_FORCE, true);
                    }
                }
            }

            let steer = racer.input.steer_right - racer.input.steer_left;
            let effective_steer = effective_steer_input(steer, racer.reversing);

            // Steering + lateral grip in one pure step (see handling_step). Y is kept
            // so gravity and ramp impulses still apply naturally.
            let vel = rb.linvel();
            let h = handling_step(
                vel.x,
                vel.z,
                horiz_forward.x,
                horiz_forward.z,
                rb.angvel().y,
                effective_steer,
                blend,
                grounded,
                racer.reversing,
                delta,
            );
            rb.apply_torque_impulse(Vec3::new(0., h.torque_y, 0.), true);
            if (h.vel_x - vel.x).abs() > 1e-9 || (h.vel_z - vel.z).abs() > 1e-9 {
                rb.set_linvel(Vec3::new(h.vel_x, vel.y, h.vel_z), true);
            }

            // Keep the car upright on the ground (no rotation lock): a damped torque
            // rotating its up-vector back toward world-up. Grounded-only, so the air
            // stays free. Magnitude ∝ the tilt ANGLE (not sin), so it stays strong all
            // the way to a full 180° flip and never gets stuck inverted; at a perfect
            // inversion the cross is ~0, so we push about the car's forward axis to
            // break it. The damping term strips the yaw component so steering is free.
            if grounded {
                let world_up = Vec3::new(0.0, 1.0, 0.0);
                let up = *rb.rotation() * world_up;
                let cross = up.cross(world_up);
                let cross_len = cross.length();
                let axis = if cross_len > 1.0e-4 {
                    cross / cross_len
                } else if up.y < 0.0 {
                    *rb.rotation() * Vec3::new(0.0, 0.0, 1.0) // inverted: kick about forward
                } else {
                    Vec3::new(0.0, 0.0, 0.0) // already upright
                };
                let angle = up.y.clamp(-1.0, 1.0).acos(); // 0 upright … π inverted
                let ang = rb.angvel();
                let tilt_rate = ang - world_up * ang.dot(world_up);
                let torque = (axis * (angle * UPRIGHT_GAIN) - tilt_rate * UPRIGHT_DAMP) * delta;
                rb.apply_torque_impulse(torque, true);
            }

            // Manual-drift flick: pressing drift + a direction snaps the yaw rate hard
            // at once — a sharp deliberate turn-in. Fires only on the press edge that
            // INITIATES a drift (not while already drifting), so rapid tap-tap on the
            // drift key can't keep re-slamming the yaw rate into an uncontrollable,
            // tumbling spin. Applied about the car's own up axis so a flick on a banked
            // surface stays a pure yaw and can't flip the car.
            let drift_just_pressed = racer.input.drift && !racer.prev_drift;
            if drift_just_pressed
                && !racer.prev_drift_state
                && grounded
                && speed > DRIFT_MIN_SPEED
                && effective_steer.abs() > 0.1
            {
                let up = *rb.rotation() * Vec3::new(0.0, 1.0, 0.0);
                let signed_rate = -effective_steer.signum() * DRIFT_FLICK_RATE;
                rb.set_angvel(drift_flick_angvel(rb.angvel(), up, signed_rate), true);
            }

            // Jump: a grounded hop on the rising edge of the jump input — set the
            // vertical velocity, keeping the horizontal motion (mirrors player.gd).
            if racer.input.jump && !racer.prev_jump && grounded {
                let mut v = rb.linvel();
                v.y = JUMP_SPEED;
                rb.set_linvel(v, true);
            }

            rb.set_linear_damping(
                NORMAL_LINEAR_DAMPING + (DRIFT_LINEAR_DAMPING - NORMAL_LINEAR_DAMPING) * blend,
            );

            // Boost FSM update — pass horizontal forward so re-alignment detection
            // and the boost impulse stay in the ground plane.
            update_boost_fsm(
                racer,
                rb,
                &horiz_forward,
                speed,
                slip.to_degrees(),
                delta,
                grounded,
            );
            update_turbo(
                racer,
                rb,
                &horiz_forward,
                speed,
                slip.to_degrees(),
                delta,
                grounded,
            );
            racer.prev_drift = racer.input.drift;
            racer.prev_drift_state = racer.drift_state;
            racer.prev_jump = racer.input.jump;
        }

        for nickname in to_remove {
            if let Some(racer) = self.racers.remove(&nickname) {
                sr_log!(
                    info,
                    "LOBBY",
                    "player left: nickname={} ({} remaining)",
                    nickname,
                    self.racers.len()
                );
                self.physics.remove_body(racer.rigid_body);
            }
        }
    }

    fn prepare_player_state_sync(&mut self, delta: f64) -> Option<Vec<PlayerState>> {
        self.sync_timer += delta;
        if self.sync_timer < STATE_SYNC_INTERVAL {
            return None;
        }
        self.sync_timer = 0.;

        // Live ranking: each racer's rank is 1 + the number of racers strictly
        // ahead of it by progress score.
        let scores = self.race_rank_scores();

        let physics = &self.physics;
        let mut states = Vec::with_capacity(self.racers.len());
        for (nickname, racer) in &mut self.racers {
            let Some(rb) = physics.get(racer.rigid_body) else {
                continue;
            };
            let my_score = scores.get(nickname).copied().unwrap_or(0.0);
            let rank = 1 + scores.values().filter(|&&s| s > my_score).count() as u8;
            let t = rb.translation();
            let r = rb.rotation();
            let rotation = stabilize_quaternion(
                racer.last_sent_rotation,
                QuatProto {
                    x: r.x,
                    y: r.y,
                    z: r.z,
                    w: r.w,
                },
            );
            racer.last_sent_rotation = Some(rotation);
            states.push(PlayerState {
                nickname: nickname.clone(),
                racing: racer.racing,
                laps: racer.laps,
                rank,
                position: Vec3Proto {
                    x: t.x,
                    y: t.y,
                    z: t.z,
                },
                rotation,
                color: racer.color,
            });
        }

        Some(states)
    }

    fn broadcast_player_state_snapshot(&mut self, states: Vec<PlayerState>) {
        self.broadcast_message(ServerMessage::State(LobbyState::Players(states)), false);
    }

    fn tick_state_machine(&mut self, delta: f64) {
        match self.state {
            State::Intermission => {
                if !self.intermission(delta) {
                    self.enter_countdown();
                }
            }
            State::Countdown => {
                if self.racers.len() < self.min_players as usize {
                    // No longer ready (someone left): cancel and reset to waiting.
                    self.countdown_timer = 0.;
                    self.sync_countdown_timer = 0.;
                    self.intermission_timer = 0.;
                    self.state = State::Intermission;
                } else if !self.countdown(delta) {
                    self.enter_starting();
                }
            }
            State::Starting => {
                if !self.starting(delta) {
                    self.enter_race();
                }
            }
            State::Racing => {
                if !self.race(delta) {
                    self.enter_intermission();
                }
            }
        }
    }

    fn intermission(&mut self, delta: f64) -> bool {
        // Hold briefly after a race so the standings stay up before the next
        // countdown takes over.
        if self.result_hold > 0.0 {
            self.result_hold -= delta;
            return true;
        }
        if self.racers.len() < self.min_players as usize {
            self.intermission_timer += delta;
            if self.intermission_timer > 1. {
                let waiting = self.min_players - self.racers.len() as u8;
                self.broadcast_message(
                    ServerMessage::State(LobbyState::WaitingForPlayers(waiting)),
                    false,
                );
                self.intermission_timer = 0.;
            }
            return true;
        }
        self.intermission_timer = 0.;
        false
    }

    fn enter_countdown(&mut self) {
        self.countdown_timer = 0.;
        self.sync_countdown_timer = 0.;
        self.state = State::Countdown;
        self.broadcast_message(
            ServerMessage::Event(LobbyEvent::LobbyCountdown {
                time: COUNTDOWN_SECS,
            }),
            false,
        );
        sr_log!(info, "STATE", "→ Countdown ({} racers)", self.racers.len());
    }

    fn countdown(&mut self, delta: f64) -> bool {
        self.countdown_timer += delta;
        self.sync_countdown_timer += delta;
        if self.sync_countdown_timer > 1. {
            self.sync_countdown_timer = 0.;
            let time = (COUNTDOWN_SECS - self.countdown_timer).max(0.);
            self.broadcast_message(
                ServerMessage::Event(LobbyEvent::LobbyCountdown { time }),
                false,
            );
        }
        self.countdown_timer < COUNTDOWN_SECS
    }

    fn enter_starting(&mut self) {
        let mut to_remove = Vec::new();
        // Two-column starting grid centred on the start line: cars sit ±SPAWN_LANE
        // across the gate tangent and step back behind the line by row, all facing
        // the spawn heading. tangent = +X local; back = opposite the racing dir.
        let yaw = self.spawn_y_rotation.to_radians();
        let (tan_x, tan_z) = (yaw.cos(), -yaw.sin());
        let (back_x, back_z) = (yaw.sin(), yaw.cos());
        for (nickname, racer) in self.racers.iter_mut() {
            let side = if racer.idx % 2 == 0 { -1.0 } else { 1.0 };
            let lateral = side * SPAWN_LANE;
            let back = ((racer.idx / 2) as f64 + 1.0) * SPAWN_ROW;
            let spawn_pos = Vec3Proto {
                x: self.spawn_point.x + tan_x * lateral + back_x * back,
                y: self.spawn_point.y,
                z: self.spawn_point.z + tan_z * lateral + back_z * back,
            };
            if let Some(rb) = self.physics.rigid_body_set.get_mut(racer.rigid_body) {
                rb.set_position(
                    Pose::new(
                        Vec3::new(spawn_pos.x, spawn_pos.y, spawn_pos.z),
                        // Face the track heading (rotation about Y) so the server's
                        // throttle drives the car along the track, not world -Z.
                        Vec3::new(0., yaw, 0.),
                    ),
                    true,
                );
                rb.set_linvel(Vec3::new(0., 0., 0.), true);
                rb.set_angvel(Vec3::new(0., 0., 0.), true);
            }
            let spawn_info = SpawnInfo {
                y_rotation: self.spawn_y_rotation,
                position: spawn_pos,
            };
            if matches!(
                try_queue_outgoing(
                    &racer.tx,
                    outgoing_server_message(&ServerMessage::Event(LobbyEvent::RaceAboutToStart(
                        spawn_info
                    ))),
                ),
                QueueSendResult::RemoveClient
            ) {
                to_remove.push(nickname.clone());
            }
            racer.laps = 0;
            racer.prev_d.clear();
            racer.checkpoints_hit.clear();
            racer.last_checkpoint = None;
            racer.prev_respawn = false;
            racer.respawn_requested = false;
            racer.prev_jump = false;
            racer.finished = false;
            racer.racing = true;
            racer.reversing = false;
            racer.grip_blend = 0.0;
            racer.drift_state = false;
            racer.prev_drift_state = false;
            racer.launch_done = false;
            racer.launch_press_offset = None;
            racer.last_sent_rotation = None;
            racer.turbo_charge = 0.0;
            racer.turbo_active = false;
            racer.stuck_time = 0.0;
            racer.air_time = 0.0;
        }
        self.race_timer = 0.;
        self.finish_timer = 0.;
        self.last_finish_count = -1;
        self.start_timer = 0.;
        self.sync_countdown_timer = 0.;
        self.last_countdown_light = -1;
        self.finishers.clear();
        self.state = State::Starting;
        sr_log!(
            info,
            "STATE",
            "→ Starting (top départ {}s, {} racers)",
            STARTING_SECS,
            self.racers.len()
        );
        self.remove_racers(to_remove);
    }

    fn starting(&mut self, delta: f64) -> bool {
        self.start_timer += delta;

        // Silent beat: cars are already placed (RaceAboutToStart sent on entry),
        // but the top départ lights stay dark for PRE_COUNTDOWN_SECS.
        let countdown_t = self.start_timer - PRE_COUNTDOWN_SECS;
        if countdown_t < 0. {
            return true;
        }
        if countdown_t >= STARTING_SECS {
            return false; // lights done → GO
        }

        // Emit 3, 2, 1 once each as the matching second begins.
        let light = (STARTING_SECS - countdown_t).ceil() as i32; // 3, 2, 1
        if light != self.last_countdown_light {
            self.last_countdown_light = light;
            self.broadcast_message(
                ServerMessage::Event(LobbyEvent::Countdown { time: light as f64 }),
                false,
            );
        }
        true
    }

    fn enter_race(&mut self) {
        self.sync_countdown_timer = 0.;
        self.start_timer = 0.;
        self.broadcast_message(ServerMessage::Event(LobbyEvent::RaceStarted(())), false);
        self.state = State::Racing;
        sr_log!(info, "STATE", "→ Racing ({} racers)", self.racers.len());
    }

    fn race(&mut self, delta: f64) -> bool {
        self.race_timer += delta;

        // Safety net: a race must always end, even with zero finishers.
        if self.race_timer > MAX_RACE_SECS {
            sr_log!(warn, "RACE", "max race time reached → forcing finish");
            return false;
        }

        if self.finish_timer > 0.0 {
            // Tell the racers still on track how long until the race force-ends.
            let secs = self.finish_timer.ceil() as i32;
            if secs != self.last_finish_count {
                self.last_finish_count = secs;
                self.broadcast_message(
                    ServerMessage::Event(LobbyEvent::FinishCountdown { time: secs as f64 }),
                    false,
                );
            }
            self.finish_timer -= delta;
            if self.finish_timer <= 0.0 {
                return false;
            }
        }

        let mut has_active_racer = false;
        for racer in self.racers.values() {
            if racer.racing {
                has_active_racer = true;
                if !racer.finished {
                    return true;
                }
            }
        }

        !has_active_racer
    }

    fn enter_intermission(&mut self) {
        let mut rankings = self.finishers.clone();
        // Didn't-finish racers ranked by progress (laps completed), name as tie-break.
        let mut dnf: Vec<(u8, String)> = self
            .racers
            .values()
            .filter(|r| r.racing && !r.finished)
            .map(|r| (r.laps, r.nickname.clone()))
            .collect();
        dnf.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        rankings.extend(dnf.into_iter().map(|(_, n)| n));

        let winner = rankings.first().cloned().unwrap_or_default();
        sr_log!(
            info,
            "STATE",
            "→ Intermission, winner={} rankings={:?}",
            winner,
            rankings
        );

        self.broadcast_message(
            ServerMessage::Event(LobbyEvent::RaceFinished { winner, rankings }),
            false,
        );

        for racer in self.racers.values_mut() {
            racer.racing = false;
        }
        self.intermission_timer = 0.;
        self.result_hold = RESULT_HOLD_SECS;
        self.state = State::Intermission;
    }

    /// Teleport any racer that pressed respawn back to its last crossed checkpoint
    /// (or the start heading if none), stationary. Runs before the physics step so
    /// the car integrates from rest at the new pose. Progress (laps, checkpoints)
    /// is preserved — only the body pose is reset.
    fn apply_respawns(&mut self) {
        let gates = &self.track.gates;
        let spawn_point = self.spawn_point;
        let spawn_yaw = self.spawn_y_rotation.to_radians();
        let physics = &mut self.physics;
        for racer in self.racers.values_mut() {
            if !std::mem::take(&mut racer.respawn_requested) {
                continue;
            }
            if racer.finished || !racer.racing {
                continue;
            }
            let (pos, yaw) = match racer.last_checkpoint {
                Some(i) => {
                    let g = &gates[i];
                    (
                        Vector3::new(g.position[0], g.position[1], g.position[2]),
                        g.rotation_deg[1].to_radians(),
                    )
                }
                None => (spawn_point, spawn_yaw),
            };
            if let Some(rb) = physics.rigid_body_set.get_mut(racer.rigid_body) {
                rb.set_position(
                    Pose::new(Vec3::new(pos.x, pos.y, pos.z), Vec3::new(0., yaw, 0.)),
                    true,
                );
                rb.set_linvel(Vec3::new(0., 0., 0.), true);
                rb.set_angvel(Vec3::new(0., 0., 0.), true);
            }
            racer.last_sent_rotation = None; // large pose jump → client snaps, no lerp
            sr_log!(
                info,
                "RESPAWN",
                "{} respawned to checkpoint",
                racer.nickname
            );
        }
    }

    /// A sortable progress score per racer (higher = further ahead), used for the
    /// live in-race ranking. Ordering, by priority: laps done, then checkpoints
    /// crossed this lap ("last checkpoint"), then proximity to the next gate
    /// (tie-break between racers between the same two checkpoints). Finished racers
    /// sit above everyone, in finishing order.
    fn race_rank_scores(&self) -> HashMap<String, f64> {
        let checkpoints: Vec<&crate::track::Gate> = self.track.checkpoint_gates().collect();
        let finish_gate = self.track.finish_gates().next();
        let mut scores = HashMap::with_capacity(self.racers.len());
        for (nickname, racer) in &self.racers {
            let score = if racer.finished {
                let finish_pos = self
                    .finishers
                    .iter()
                    .position(|n| n == nickname)
                    .unwrap_or(usize::MAX);
                1e12 - finish_pos as f64
            } else {
                let cp_done = racer.checkpoints_hit.len();
                // Next gate to aim for: the next un-crossed checkpoint, or the
                // finish line once all checkpoints are done.
                let next_gate = if cp_done < checkpoints.len() {
                    Some(checkpoints[cp_done])
                } else {
                    finish_gate
                };
                let dist = match (self.physics.get(racer.rigid_body), next_gate) {
                    (Some(rb), Some(g)) => {
                        let t = rb.translation();
                        let c = g.center();
                        ((t.x - c.x).powi(2) + (t.z - c.z).powi(2)).sqrt()
                    }
                    _ => 0.0,
                };
                racer.laps as f64 * 1e9 + cp_done as f64 * 1e6 - dist
            };
            scores.insert(nickname.clone(), score);
        }
        scores
    }

    fn check_lap_crossings(&mut self) {
        let race_timer = self.race_timer;
        let physics = &self.physics;
        let finishers = &mut self.finishers;
        let finish_timer = &mut self.finish_timer;
        let gates = &self.track.gates;
        let laps_to_win = self.track.laps_to_win;
        let checkpoint_count = self.track.checkpoint_gates().count();

        for racer in self.racers.values_mut() {
            let Some(rb) = physics.get(racer.rigid_body) else {
                continue;
            };
            let pos = rb.translation();
            let (px, py, pz) = (pos.x, pos.y, pos.z);

            // Signed distance of the car along a gate's forward normal (scalar
            // math: the body translation is glam, gate axes are nalgebra).
            let signed = |g: &crate::track::Gate| -> f64 {
                let f = g.forward();
                (px - g.position[0]) * f.x + (py - g.position[1]) * f.y + (pz - g.position[2]) * f.z
            };

            // Lazily size prev_d so the first tick never registers a crossing.
            if racer.prev_d.len() != gates.len() {
                racer.prev_d = gates.iter().map(&signed).collect();
                racer.checkpoints_hit.clear();
            }

            if racer.finished || !racer.racing {
                for (i, g) in gates.iter().enumerate() {
                    racer.prev_d[i] = signed(g);
                }
                continue;
            }

            for (i, g) in gates.iter().enumerate() {
                let d = signed(g);
                let prev = racer.prev_d[i];
                racer.prev_d[i] = d;

                let t = g.tangent();
                let lateral = ((px - g.position[0]) * t.x
                    + (py - g.position[1]) * t.y
                    + (pz - g.position[2]) * t.z)
                    .abs();
                if lateral >= g.half_width {
                    continue;
                }

                if g.is_checkpoint() {
                    if (prev < 0.0) != (d < 0.0) {
                        racer.checkpoints_hit.insert(i);
                        racer.last_checkpoint = Some(i);
                    }
                } else if g.provides_finish()
                    && prev < 0.0
                    && d >= 0.0
                    && racer.checkpoints_hit.len() >= checkpoint_count
                {
                    racer.laps += 1;
                    racer.checkpoints_hit.clear();
                    racer.last_checkpoint = None; // fresh lap: respawn at the line until a CP
                    sr_log!(trace, "LAP", "{}: lap {}", racer.nickname, racer.laps);

                    if racer.laps >= laps_to_win {
                        racer.finished = true;
                        finishers.push(racer.nickname.clone());
                        sr_log!(
                            info,
                            "RACE",
                            "finisher: {} (#{}) at t={:.2}s",
                            racer.nickname,
                            finishers.len(),
                            race_timer
                        );
                        if *finish_timer == 0.0 {
                            *finish_timer = FINISH_WAIT_SECS;
                        }
                        break;
                    }
                }
            }
        }
    }

    fn broadcast_message(&mut self, message: ServerMessage, for_racing_players: bool) {
        let message = outgoing_server_message(&message);
        let mut to_remove = Vec::new();
        for (nickname, racer) in &self.racers {
            if for_racing_players && !racer.racing {
                continue;
            }
            if matches!(
                try_queue_outgoing(&racer.tx, message.clone()),
                QueueSendResult::RemoveClient
            ) {
                to_remove.push(nickname.clone());
            }
        }
        self.remove_racers(to_remove);
    }

    fn first_free_idx(&self) -> u8 {
        let mut idx = 0u8;
        let mut used: Vec<u8> = self.racers.values().map(|r| r.idx).collect();
        used.sort_unstable();
        for used_idx in used {
            if used_idx == idx {
                idx += 1;
            } else {
                break;
            }
        }
        idx
    }

    fn remove_racers(&mut self, nicknames: Vec<String>) {
        for nickname in nicknames {
            if let Some(racer) = self.racers.remove(&nickname) {
                self.physics.remove_body(racer.rigid_body);
            }
        }
    }
}

fn serialize_server_message(message: &ServerMessage) -> Message {
    Message::Text(serde_json::to_string(message).unwrap().into())
}

fn outgoing_server_message(message: &ServerMessage) -> OutgoingMessage {
    let encoded = serialize_server_message(message);
    match message {
        ServerMessage::State(_) => OutgoingMessage::State(encoded),
        ServerMessage::Event(_) | ServerMessage::Response(_) => OutgoingMessage::Reliable(encoded),
    }
}

fn try_queue_outgoing(
    tx_out: &tokio::sync::mpsc::Sender<OutgoingMessage>,
    outgoing: OutgoingMessage,
) -> QueueSendResult {
    match tx_out.try_send(outgoing) {
        Ok(()) => QueueSendResult::Queued,
        Err(tokio::sync::mpsc::error::TrySendError::Full(OutgoingMessage::State(_))) => {
            QueueSendResult::Queued
        }
        Err(tokio::sync::mpsc::error::TrySendError::Full(OutgoingMessage::Reliable(_)))
        | Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => QueueSendResult::RemoveClient,
    }
}

fn collect_outgoing_batch(
    first: OutgoingMessage,
    rx_out: &mut tokio::sync::mpsc::Receiver<OutgoingMessage>,
) -> Vec<Message> {
    fn push_message(
        batch: &mut Vec<Message>,
        latest_state: &mut Option<Message>,
        outgoing: OutgoingMessage,
    ) {
        match outgoing {
            OutgoingMessage::Reliable(message) => {
                if let Some(state) = latest_state.take() {
                    batch.push(state);
                }
                batch.push(message);
            }
            OutgoingMessage::State(message) => {
                *latest_state = Some(message);
            }
        }
    }

    let mut batch = Vec::with_capacity(4);
    let mut latest_state = None;

    push_message(&mut batch, &mut latest_state, first);
    while let Ok(next) = rx_out.try_recv() {
        push_message(&mut batch, &mut latest_state, next);
    }
    if let Some(state) = latest_state {
        batch.push(state);
    }

    batch
}

pub(crate) fn send_join_error(
    tx_out: &tokio::sync::mpsc::Sender<OutgoingMessage>,
    error: JoinError,
) {
    let msg = ServerMessage::Response(Response::LobbyJoined {
        track_id: String::new(),
        track_hash: String::new(),
        race_ongoing: false,
        min_players: 0,
        max_players: 0,
        error: Some(error),
        track: None,
    });
    let _ = try_queue_outgoing(tx_out, outgoing_server_message(&msg));
}

pub(crate) fn spawn_ws_writer(
    tx_stream: futures_util::stream::SplitSink<WebSocketStream<TcpStream>, Message>,
) -> tokio::sync::mpsc::Sender<OutgoingMessage> {
    const OUTGOING_BUFFER_CAPACITY: usize = 32;

    let (tx_out, mut rx_out) =
        tokio::sync::mpsc::channel::<OutgoingMessage>(OUTGOING_BUFFER_CAPACITY);
    tokio::spawn(async move {
        let mut sink = tx_stream;
        while let Some(first) = rx_out.recv().await {
            for msg in collect_outgoing_batch(first, &mut rx_out) {
                if sink.send(msg).await.is_err() {
                    return;
                }
            }
        }
    });
    tx_out
}

fn launch_client_reader(
    tx_channel: crossbeam::channel::Sender<PlayerEvent>,
    mut rx_stream: futures_util::stream::SplitStream<WebSocketStream<TcpStream>>,
) {
    tokio::spawn(async move {
        loop {
            match rx_stream.next().await {
                Some(Ok(Message::Close(_))) => {
                    let _ = tx_channel.send(PlayerEvent::Close);
                    break;
                }
                Some(Ok(Message::Text(text))) => {
                    if let Ok(msg) = serde_json::from_str::<ClientMessage>(&text)
                        .map_err(Error::ClientInvalidJson)
                    {
                        let _ = tx_channel.send(PlayerEvent::Message(msg));
                    }
                }
                Some(Ok(_)) => {}
                Some(Err(_)) => {
                    let _ = tx_channel.send(PlayerEvent::Close);
                    break;
                }
                None => {
                    let _ = tx_channel.send(PlayerEvent::Close);
                    break;
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;
    use tungstenite::Message;

    fn text(s: &str) -> Message {
        Message::Text(s.into())
    }

    fn test_track() -> Arc<TrackDef> {
        let raw = include_str!("../tracks/circuit_simple.json");
        Arc::new(TrackDef::from_json(raw).expect("test track parses"))
    }

    // ── update_reverse_mode ────────────────────────────────────────────────

    #[test]
    fn reverse_engages_when_moving_backward_past_epsilon() {
        assert!(update_reverse_mode(false, -1.0, false, false));
        assert!(update_reverse_mode(
            false,
            -MOTION_DIRECTION_EPSILON,
            false,
            true
        ));
    }

    #[test]
    fn reverse_disengages_when_moving_forward_past_epsilon() {
        assert!(!update_reverse_mode(true, 1.0, false, false));
        assert!(!update_reverse_mode(
            true,
            MOTION_DIRECTION_EPSILON,
            true,
            false
        ));
    }

    #[test]
    fn throttle_clears_reverse_when_near_zero_speed() {
        assert!(!update_reverse_mode(true, 0.0, false, true));
        assert!(!update_reverse_mode(true, 0.1, true, true));
    }

    #[test]
    fn drift_without_throttle_engages_reverse_at_rest() {
        assert!(update_reverse_mode(false, 0.0, true, false));
    }

    // ── drift_flick_angvel: a flick is a pure yaw that can't inject a tumble ──

    #[test]
    fn drift_flick_sets_yaw_and_keeps_pitch_roll_on_flat_ground() {
        // Up = +Y: the flick sets the Y (yaw) spin and leaves x/z (pitch/roll) alone.
        let out = drift_flick_angvel(Vec3::new(0.5, 9.9, -0.3), Vec3::new(0.0, 1.0, 0.0), 2.0);
        assert!((out.x - 0.5).abs() < 1e-9);
        assert!((out.z + 0.3).abs() < 1e-9);
        assert!((out.y - 2.0).abs() < 1e-9);
    }

    #[test]
    fn drift_flick_is_pure_yaw_about_up_on_a_banked_surface() {
        // Tilted up: the spin about up equals the rate, and the component
        // perpendicular to up (pitch/roll) is unchanged — no tumble injected.
        let up = Vec3::new(0.0, 1.0, 1.0).normalize();
        let cur = Vec3::new(0.2, 0.0, 0.0);
        let out = drift_flick_angvel(cur, up, 3.0);
        assert!((out.dot(up) - 3.0).abs() < 1e-9);
        let perp_in = cur - up * cur.dot(up);
        let perp_out = out - up * out.dot(up);
        assert!((perp_in - perp_out).length() < 1e-9);
    }

    // ── handling_step: the "grip is the anomaly" corner test ───────────────
    //
    // A minimal kinematic car driven by the real `handling_step`: the engine
    // holds `cruise` speed, full lock is applied, and we integrate the yaw torque
    // and heading. This is a model-level test (not a full rapier sim): it locks in
    // the Phase-1 design intent rather than exact physics numbers.
    //
    // Returns (peak |slip| in degrees, whether grip ever broke loose).
    fn simulate_corner(cruise: f64, blend: f64, ticks: usize) -> (f64, bool) {
        let dt = 1.0 / 60.0;
        let i_test = 800.0; // representative angular inertia (stiff steering)
        let (mut hx, mut hz) = (0.0_f64, 1.0_f64); // heading +Z
        let (mut vx, mut vz) = (0.0_f64, cruise); // moving forward at cruise
        let mut yaw_rate = 0.0_f64;
        let mut max_slip = 0.0_f64;
        let mut broke_loose = false;

        for _ in 0..ticks {
            let h = handling_step(vx, vz, hx, hz, yaw_rate, 1.0, blend, true, false, dt);
            vx = h.vel_x;
            vz = h.vel_z;
            // Engine holds cruise: rescale magnitude, keep the (handling-curved) dir.
            let s = (vx * vx + vz * vz).sqrt();
            if s > 1e-6 {
                vx = vx / s * cruise;
                vz = vz / s * cruise;
            }
            yaw_rate += h.torque_y / i_test;
            let a = yaw_rate * dt; // rotate heading about +Y by yaw·dt
            let (c, sn) = (a.cos(), a.sin());
            let (nhx, nhz) = (hx * c + hz * sn, -hx * sn + hz * c);
            hx = nhx;
            hz = nhz;
            max_slip = max_slip.max(h.slip_deg.abs());
            broke_loose |= h.over_break;
        }
        (max_slip, broke_loose)
    }

    #[test]
    fn grip_holds_a_corner_at_low_speed() {
        // At a crawl the lateral cap easily meets the turn's demand: tight line, no
        // slide. Turning on grip is only fine when slow.
        let (max_slip, broke) = simulate_corner(8.0, 0.0, 120);
        assert!(!broke, "grip should not break loose at low speed");
        assert!(
            max_slip < 12.0,
            "grip slip stays small at low speed, got {max_slip:.1}°"
        );
    }

    #[test]
    fn grip_washes_out_at_racing_speed() {
        // At race pace the same full-lock turn exceeds the lateral grip budget: the
        // rear washes out past the break angle ("tombé en drift"). This is the
        // anomaly the player must avoid — cornering on grip simply doesn't hold.
        let (max_slip, broke) = simulate_corner(32.0, 0.0, 120);
        assert!(broke, "grip must break loose at racing speed");
        assert!(
            max_slip > SLIP_BREAK_DEG,
            "grip slip blows past the break angle, got {max_slip:.1}°"
        );
    }

    #[test]
    fn drift_never_breaks_loose() {
        // The same hard turn at the same race speed, but drifting: the slide is
        // present yet the traction collapse never triggers — the drift is the
        // *controllable* version of the slide, by design (break is gated to grip).
        let (_max_slip, broke) = simulate_corner(32.0, 1.0, 120);
        assert!(
            !broke,
            "drift slide must never trigger the grip break-loose"
        );
    }

    #[test]
    fn anti_spin_caps_the_slide() {
        // A full-lock drift at race pace, held for a long time, must reach a big — but
        // BOUNDED — slide: the anti-spin guard stops it short of a 90°+ backwards spin.
        let (max_slip, _broke) = simulate_corner(32.0, 1.0, 400);
        assert!(
            max_slip > SPIN_GUARD_DEG,
            "a hard drift should still build a real slide, got {max_slip:.1}°"
        );
        assert!(
            max_slip < 90.0,
            "anti-spin must stop the slide short of a 90° spin-out, got {max_slip:.1}°"
        );
    }

    #[test]
    fn drift_entry_couples_angle_and_effort() {
        let fast = 30.0;
        // Gentle steering at speed: still needs the full slide to fall into drift.
        assert!((drift_enter_threshold_deg(0.0, fast) - SLIP_BREAK_DEG).abs() < 1e-9);
        // Full lock at speed: the bar drops right down — snaps in almost at once.
        assert!((drift_enter_threshold_deg(1.0, fast) - SLIP_BREAK_HARD_DEG).abs() < 1e-9);
        // Harder steering always lowers the bar (monotonic in effort).
        assert!(drift_enter_threshold_deg(1.0, fast) < drift_enter_threshold_deg(0.5, fast));
        assert!(drift_enter_threshold_deg(0.5, fast) < drift_enter_threshold_deg(0.0, fast));
        // Faster always lowers the bar at a given steer (monotonic in speed). Use a
        // mid speed below the effort-saturation ref so the comparison is strict.
        let mid = (DRIFT_MIN_SPEED + DRIFT_EFFORT_SPEED_REF) * 0.5;
        assert!(drift_enter_threshold_deg(1.0, fast) < drift_enter_threshold_deg(1.0, mid));
        // At a crawl effort can't trigger it: you keep full low-speed control.
        assert!((drift_enter_threshold_deg(1.0, DRIFT_MIN_SPEED) - SLIP_BREAK_DEG).abs() < 1e-9);
    }

    #[test]
    fn launch_quality_peaks_at_go_and_is_symmetric() {
        // Exactly on GO = perfect.
        assert!((launch_quality(0.0) - 1.0).abs() < 1e-9);
        // Symmetric: jumping early scores the same as the equivalent late reaction.
        assert!((launch_quality(-0.1) - launch_quality(0.1)).abs() < 1e-9);
        // Monotonic falloff: further from GO is always worse.
        assert!(launch_quality(0.05) > launch_quality(0.1));
        assert!(launch_quality(-0.05) > launch_quality(-0.15));
        // Outside the window (incl. holding the gas from the countdown) = no boost.
        assert_eq!(launch_quality(LAUNCH_WINDOW), 0.0);
        assert_eq!(launch_quality(-5.0), 0.0);
        // Steepened: one frame (~16 ms) off already drops well below 100%.
        assert!(launch_quality(1.0 / 60.0) < 0.95);
    }

    #[test]
    fn reverse_state_holds_when_idle_at_rest() {
        assert!(update_reverse_mode(true, 0.0, false, false));
        assert!(!update_reverse_mode(false, 0.0, false, false));
    }

    // ── effective_steer_input ──────────────────────────────────────────────

    #[test]
    fn steer_inverted_when_reversing() {
        assert_eq!(effective_steer_input(0.5, true), -0.5);
        assert_eq!(effective_steer_input(-0.3, true), 0.3);
    }

    #[test]
    fn steer_unchanged_when_forward() {
        assert_eq!(effective_steer_input(0.5, false), 0.5);
        assert_eq!(effective_steer_input(-0.7, false), -0.7);
    }

    #[test]
    fn steer_zero_is_zero_either_way() {
        assert_eq!(effective_steer_input(0.0, true), 0.0);
        assert_eq!(effective_steer_input(0.0, false), 0.0);
    }

    // ── stabilize_quaternion ───────────────────────────────────────────────

    #[test]
    fn stabilize_returns_current_when_no_prev() {
        let q = QuatProto {
            x: 0.1,
            y: 0.2,
            z: 0.3,
            w: 0.9,
        };
        let s = stabilize_quaternion(None, q);
        assert_eq!(s.x, q.x);
        assert_eq!(s.y, q.y);
        assert_eq!(s.z, q.z);
        assert_eq!(s.w, q.w);
    }

    #[test]
    fn stabilize_negates_when_dot_negative() {
        let prev = QuatProto {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: 1.0,
        };
        let cur = QuatProto {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: -1.0,
        };
        let s = stabilize_quaternion(Some(prev), cur);
        assert_eq!(s.w, 1.0);
        assert_eq!(s.x, 0.0);
    }

    #[test]
    fn stabilize_keeps_when_dot_positive() {
        let prev = QuatProto {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: 1.0,
        };
        let cur = QuatProto {
            x: 0.0,
            y: 0.0,
            z: 0.1,
            w: 0.99,
        };
        let s = stabilize_quaternion(Some(prev), cur);
        assert_eq!(s.w, 0.99);
        assert_eq!(s.z, 0.1);
    }

    // ── outgoing_server_message routing ────────────────────────────────────

    #[test]
    fn state_messages_get_state_outgoing_variant() {
        let msg = ServerMessage::State(LobbyState::WaitingForPlayers(2));
        assert!(matches!(
            outgoing_server_message(&msg),
            OutgoingMessage::State(_)
        ));
    }

    #[test]
    fn event_messages_get_reliable_outgoing_variant() {
        let msg = ServerMessage::Event(LobbyEvent::RaceStarted(()));
        assert!(matches!(
            outgoing_server_message(&msg),
            OutgoingMessage::Reliable(_)
        ));
    }

    #[test]
    fn response_messages_get_reliable_outgoing_variant() {
        let msg = ServerMessage::Response(Response::LobbyList(vec![]));
        assert!(matches!(
            outgoing_server_message(&msg),
            OutgoingMessage::Reliable(_)
        ));
    }

    #[test]
    fn serialize_server_message_produces_valid_json() {
        let msg = ServerMessage::Event(LobbyEvent::Countdown { time: 3.0 });
        if let Message::Text(t) = serialize_server_message(&msg) {
            let parsed: serde_json::Value = serde_json::from_str(&t).unwrap();
            assert!(parsed.get("Event").is_some());
        } else {
            panic!("expected Text message");
        }
    }

    // ── try_queue_outgoing ─────────────────────────────────────────────────

    #[test]
    fn try_queue_returns_queued_when_capacity_available() {
        let (tx, _rx) = mpsc::channel::<OutgoingMessage>(2);
        assert_eq!(
            try_queue_outgoing(&tx, OutgoingMessage::Reliable(text("x"))),
            QueueSendResult::Queued
        );
    }

    #[test]
    fn try_queue_returns_remove_when_channel_closed() {
        let (tx, rx) = mpsc::channel::<OutgoingMessage>(1);
        drop(rx);
        assert_eq!(
            try_queue_outgoing(&tx, OutgoingMessage::Reliable(text("x"))),
            QueueSendResult::RemoveClient
        );
    }

    #[test]
    fn try_queue_drops_state_silently_when_full() {
        let (tx, _rx) = mpsc::channel::<OutgoingMessage>(1);
        tx.try_send(OutgoingMessage::Reliable(text("a"))).unwrap();
        // Now full — a State message should be dropped silently (Queued).
        assert_eq!(
            try_queue_outgoing(&tx, OutgoingMessage::State(text("b"))),
            QueueSendResult::Queued
        );
    }

    #[test]
    fn try_queue_full_reliable_returns_remove_client() {
        let (tx, _rx) = mpsc::channel::<OutgoingMessage>(1);
        tx.try_send(OutgoingMessage::Reliable(text("a"))).unwrap();
        assert_eq!(
            try_queue_outgoing(&tx, OutgoingMessage::Reliable(text("b"))),
            QueueSendResult::RemoveClient
        );
    }

    // ── collect_outgoing_batch (state coalescing) ──────────────────────────

    #[tokio::test]
    async fn batch_keeps_only_latest_state() {
        let (tx, mut rx) = mpsc::channel::<OutgoingMessage>(8);
        tx.send(OutgoingMessage::State(text("s1"))).await.unwrap();
        tx.send(OutgoingMessage::State(text("s2"))).await.unwrap();
        tx.send(OutgoingMessage::State(text("s3"))).await.unwrap();
        let first = rx.recv().await.unwrap();
        let batch = collect_outgoing_batch(first, &mut rx);
        assert_eq!(batch.len(), 1);
        if let Message::Text(t) = &batch[0] {
            assert_eq!(t.as_str(), "s3");
        } else {
            panic!("expected Text");
        }
    }

    #[tokio::test]
    async fn batch_keeps_all_reliable_messages_in_order() {
        let (tx, mut rx) = mpsc::channel::<OutgoingMessage>(8);
        tx.send(OutgoingMessage::Reliable(text("r1")))
            .await
            .unwrap();
        tx.send(OutgoingMessage::Reliable(text("r2")))
            .await
            .unwrap();
        tx.send(OutgoingMessage::Reliable(text("r3")))
            .await
            .unwrap();
        let first = rx.recv().await.unwrap();
        let batch = collect_outgoing_batch(first, &mut rx);
        assert_eq!(batch.len(), 3);
        let texts: Vec<&str> = batch
            .iter()
            .filter_map(|m| {
                if let Message::Text(t) = m {
                    Some(t.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(texts, vec!["r1", "r2", "r3"]);
    }

    #[tokio::test]
    async fn batch_flushes_pending_state_before_following_reliable() {
        let (tx, mut rx) = mpsc::channel::<OutgoingMessage>(8);
        tx.send(OutgoingMessage::State(text("s1"))).await.unwrap();
        tx.send(OutgoingMessage::Reliable(text("r1")))
            .await
            .unwrap();
        let first = rx.recv().await.unwrap();
        let batch = collect_outgoing_batch(first, &mut rx);
        assert_eq!(batch.len(), 2);
        let texts: Vec<&str> = batch
            .iter()
            .filter_map(|m| {
                if let Message::Text(t) = m {
                    Some(t.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(texts, vec!["s1", "r1"]);
    }

    #[tokio::test]
    async fn batch_drops_stale_state_overshadowed_by_newer_state_before_reliable() {
        let (tx, mut rx) = mpsc::channel::<OutgoingMessage>(8);
        tx.send(OutgoingMessage::State(text("old"))).await.unwrap();
        tx.send(OutgoingMessage::State(text("new"))).await.unwrap();
        tx.send(OutgoingMessage::Reliable(text("r1")))
            .await
            .unwrap();
        let first = rx.recv().await.unwrap();
        let batch = collect_outgoing_batch(first, &mut rx);
        assert_eq!(batch.len(), 2);
        let texts: Vec<&str> = batch
            .iter()
            .filter_map(|m| {
                if let Message::Text(t) = m {
                    Some(t.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(texts, vec!["new", "r1"]);
    }

    #[tokio::test]
    async fn batch_appends_trailing_state_after_reliable() {
        let (tx, mut rx) = mpsc::channel::<OutgoingMessage>(8);
        tx.send(OutgoingMessage::Reliable(text("r1")))
            .await
            .unwrap();
        tx.send(OutgoingMessage::State(text("s1"))).await.unwrap();
        let first = rx.recv().await.unwrap();
        let batch = collect_outgoing_batch(first, &mut rx);
        assert_eq!(batch.len(), 2);
        let texts: Vec<&str> = batch
            .iter()
            .filter_map(|m| {
                if let Message::Text(t) = m {
                    Some(t.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(texts, vec!["r1", "s1"]);
    }

    #[tokio::test]
    async fn batch_with_only_first_state_returns_single_state() {
        let (_tx, mut rx) = mpsc::channel::<OutgoingMessage>(1);
        let batch = collect_outgoing_batch(OutgoingMessage::State(text("only")), &mut rx);
        assert_eq!(batch.len(), 1);
    }

    #[tokio::test]
    async fn batch_complex_interleaving() {
        let (tx, mut rx) = mpsc::channel::<OutgoingMessage>(16);
        tx.send(OutgoingMessage::State(text("s1"))).await.unwrap();
        tx.send(OutgoingMessage::Reliable(text("r1")))
            .await
            .unwrap();
        tx.send(OutgoingMessage::State(text("s2"))).await.unwrap();
        tx.send(OutgoingMessage::State(text("s3"))).await.unwrap();
        tx.send(OutgoingMessage::Reliable(text("r2")))
            .await
            .unwrap();
        tx.send(OutgoingMessage::State(text("s4"))).await.unwrap();
        let first = rx.recv().await.unwrap();
        let batch = collect_outgoing_batch(first, &mut rx);
        let texts: Vec<&str> = batch
            .iter()
            .filter_map(|m| {
                if let Message::Text(t) = m {
                    Some(t.as_str())
                } else {
                    None
                }
            })
            .collect();
        // s1 flushed before r1, s2 dropped (replaced by s3) flushed before r2, s4 trailing.
        assert_eq!(texts, vec!["s1", "r1", "s3", "r2", "s4"]);
    }

    // ── send_join_error ────────────────────────────────────────────────────

    #[tokio::test]
    async fn send_join_error_queues_response_with_error() {
        let (tx, mut rx) = mpsc::channel::<OutgoingMessage>(4);
        send_join_error(&tx, JoinError::LobbyFull);
        let outgoing = rx.recv().await.unwrap();
        let msg = match outgoing {
            OutgoingMessage::Reliable(m) => m,
            _ => panic!("expected Reliable"),
        };
        let text = if let Message::Text(t) = msg {
            t
        } else {
            panic!("expected Text")
        };
        let parsed: ServerMessage = serde_json::from_str(&text).unwrap();
        match parsed {
            ServerMessage::Response(Response::LobbyJoined { error: Some(e), .. }) => {
                assert_eq!(e, JoinError::LobbyFull);
            }
            _ => panic!("expected LobbyJoined response with error"),
        }
    }

    // ── Lobby ──────────────────────────────────────────────────────────────

    #[test]
    fn lobby_new_initial_state() {
        let lobby = Lobby::new("alice".into(), "12:00".into(), 2, 4, test_track());
        assert_eq!(lobby.owner, "alice");
        assert_eq!(lobby.start_time, "12:00");
        assert_eq!(lobby.min_players, 2);
        assert_eq!(lobby.max_players, 4);
        assert_eq!(lobby.player_count(), 0);
        assert!(!lobby.is_racing());
    }

    #[test]
    fn first_free_idx_returns_zero_on_empty_lobby() {
        let lobby = Lobby::new("alice".into(), "12:00".into(), 1, 4, test_track());
        assert_eq!(lobby.first_free_idx(), 0);
    }

    #[test]
    fn lobby_update_returns_false_when_no_racers() {
        let mut lobby = Lobby::new("alice".into(), "12:00".into(), 1, 4, test_track());
        assert!(!lobby.update(1.0 / 60.0));
    }

    #[test]
    fn lobby_track_name_returns_underlying_track_name() {
        let lobby = Lobby::new("alice".into(), "12:00".into(), 1, 4, test_track());
        assert_eq!(lobby.track_name(), test_track().name);
    }
}
