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
                1000.0,
                Vec3::new(2040.0, 2483.0, 683.0),
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

const THROTTLE_FORCE: f64 = 14_000.0;
const REVERSE_FORCE: f64 = 5_000.0;
const BRAKE_FORCE: f64 = 8_000.0;
const BRAKE_MIN_SPEED: f64 = 1.0;
const MAX_TURN_RATE_GRIP: f64 = 1.2;
const MAX_TURN_RATE_DRIFT: f64 = 2.4; // softer than before (was 3.2): a gentler rotation
const STEER_P_GAIN: f64 = 25_000.0;
const ALIGN_RATE_GRIP: f64 = 4.0;
const ALIGN_RATE_DRIFT: f64 = 0.4; // lower (was 0.6): velocity lags the heading → more slide
                                   // Drift is eased in/out via a 0→1 grip-blend instead of a hard switch, so the
                                   // slide builds and releases smoothly — "controlled loss of control".
const GRIP_BLEND_RATE: f64 = 6.0;
const MOTION_DIRECTION_EPSILON: f64 = 0.25;
const CAR_COLLISION: InteractionGroups = InteractionGroups::new(
    Group::GROUP_2,
    Group::GROUP_1.union(Group::GROUP_3),
    InteractionTestMode::And,
);

const NORMAL_LINEAR_DAMPING: f64 = 0.3;
const DRIFT_LINEAR_DAMPING: f64 = 0.18;
const DRIFT_MIN_SPEED: f64 = 3.0;

const BOOST_CHARGE_RATE: f64 = 1.0;
const BOOST_CHARGE_DECAY: f64 = 2.0;
const BOOST_CHARGE_MIN: f64 = 0.30;
const BOOST_PEAK_BONUS: f64 = 18.0;
const BOOST_DURATION: f64 = 1.5;
const BOOST_ALIGN_THRESHOLD_COS: f64 = 0.9781476; // cos(12°)
const BOOST_PENDING_TIMEOUT: f64 = 1.5;
const BOOST_SUSTAIN_FORCE: f64 = 30_000.0;

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
const PRE_COUNTDOWN_SECS: f64 = 2.0; // silent beat on-track before the top départ lights
const STARTING_SECS: f64 = 3.0; // on-track "top départ" (3-2-1) after the silent beat
const STATE_SYNC_INTERVAL: f64 = 0.05;

#[derive(Default, Clone, Copy)]
struct PlayerInput {
    throttle: bool,
    steer_left: f64,
    steer_right: f64,
    star_drift: bool,
}

#[derive(Default, Clone, Copy, PartialEq)]
enum BoostState {
    #[default]
    Idle,
    Pending,
    Boosting,
}

fn update_boost_fsm(
    racer: &mut Racer,
    rb: &mut rapier3d_f64::prelude::RigidBody,
    forward_dir: &Vec3,
    speed: f64,
    delta: f64,
    grounded: bool,
) {
    // Charge accumulation / decay. Drift only charges with wheels on the ground.
    if grounded && racer.input.star_drift && speed > DRIFT_MIN_SPEED {
        racer.boost_charge = (racer.boost_charge + BOOST_CHARGE_RATE * delta).min(1.0);
    } else if racer.boost_state != BoostState::Pending {
        racer.boost_charge = (racer.boost_charge - BOOST_CHARGE_DECAY * delta).max(0.0);
    }

    let just_released = racer.prev_star_drift && !racer.input.star_drift;

    match racer.boost_state {
        BoostState::Idle => {
            if just_released && racer.boost_charge >= BOOST_CHARGE_MIN {
                racer.boost_state = BoostState::Pending;
                racer.boost_pending_t = BOOST_PENDING_TIMEOUT;
            }
        }
        BoostState::Pending => {
            racer.boost_pending_t -= delta;
            // Cancelled by re-engaging drift (charge keeps building) or by timing out.
            if racer.input.star_drift || racer.boost_pending_t <= 0.0 {
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

/// Spherical interpolation between two unit vectors, clamped by max_angle (radians).
fn vec3_slerp_clamped(from: Vec3, to: Vec3, max_angle: f64) -> Vec3 {
    let dot = from.dot(to).clamp(-1.0, 1.0);
    let angle = dot.acos();
    if angle < 1e-4 || max_angle <= 0.0 {
        return from;
    }
    let t = (max_angle / angle).min(1.0);
    let sin_a = angle.sin();
    if sin_a.abs() < 1e-4 {
        return from;
    }
    let a = ((1.0 - t) * angle).sin() / sin_a;
    let b = (t * angle).sin() / sin_a;
    from * a + to * b
}

fn update_reverse_mode(
    was_reversing: bool,
    forward_speed: f64,
    star_drift: bool,
    throttle: bool,
) -> bool {
    if forward_speed <= -MOTION_DIRECTION_EPSILON {
        true
    } else if forward_speed >= MOTION_DIRECTION_EPSILON || throttle {
        false
    } else if star_drift {
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
    prev_star_drift: bool,
    laps: u8,
    // Per-gate previous signed distance along the gate's forward normal (sized
    // lazily to track.gates), plus the checkpoint gate indices crossed this lap.
    prev_d: Vec<f64>,
    checkpoints_hit: HashSet<usize>,
    finished: bool,
    reversing: bool,
    grip_blend: f64,
    last_sent_rotation: Option<QuatProto>,
    boost_state: BoostState,
    boost_charge: f64,
    boost_t_remaining: f64,
    boost_pending_t: f64,
    boost_peak_speed: f64,
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
            prev_star_drift: false,
            laps: 0,
            prev_d: Vec::new(),
            checkpoints_hit: HashSet::new(),
            finished: false,
            reversing: false,
            grip_blend: 0.0,
            last_sent_rotation: None,
            boost_state: BoostState::Idle,
            boost_charge: 0.0,
            boost_t_remaining: 0.0,
            boost_pending_t: 0.0,
            boost_peak_speed: 0.0,
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
                Some((*self.track).clone())
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
        let (sx, sy, sz) = (self.spawn_point.x, self.spawn_point.y, self.spawn_point.z);
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
                    let boost_vec = horiz / horiz_speed * boost_strength;
                    let new_vel = Vec3::new(vel.x + boost_vec.x, vel.y, vel.z + boost_vec.z);
                    rb.set_linvel(new_vel, true);
                }
                continue;
            }

            // Hazard (e.g. a void catch-plane under a precipice): respawn the
            // car at the start, stationary.
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
                if let Some(rb) = self.physics.rigid_body_set.get_mut(rb_handle) {
                    rb.set_position(
                        Pose::new(Vec3::new(sx, sy, sz), Vec3::new(0., 0., 0.)),
                        true,
                    );
                    rb.set_linvel(Vec3::new(0., 0., 0.), true);
                    rb.set_angvel(Vec3::new(0., 0., 0.), true);
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
                        star_drift,
                    }) => {
                        sr_log!(
                            trace,
                            "INPUT",
                            "{}: throttle={} steer=(-{:.2},+{:.2}) drift={}",
                            nickname,
                            throttle,
                            steer_left,
                            steer_right,
                            star_drift
                        );
                        racer.input = PlayerInput {
                            throttle,
                            steer_left,
                            steer_right,
                            star_drift,
                        };
                    }
                    PlayerEvent::Message(_) => {}
                }
            }

            if should_remove {
                to_remove.push(nickname.clone());
                continue;
            }

            if !is_racing {
                continue;
            }

            // Airborne gating: with no wheels on the ground, driving inputs
            // (throttle, reverse, brake, drift, velocity re-alignment, boost)
            // are disabled — only orientation stays available for landing.
            let grounded = self.physics.is_grounded(racer.rigid_body);

            let rb = self.physics.get_mut(racer.rigid_body).unwrap();

            let speed = rb.linvel().length();
            rb.reset_forces(true);

            // Ease the grip-blend toward the drift target so handling shifts
            // smoothly instead of snapping between grip and drift.
            let drift_target = if grounded && racer.input.star_drift && speed > DRIFT_MIN_SPEED {
                1.0
            } else {
                0.0
            };
            racer.grip_blend +=
                (drift_target - racer.grip_blend) * (delta * GRIP_BLEND_RATE).clamp(0.0, 1.0);
            let blend = racer.grip_blend;

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

            let forward_speed = -forward.dot(rb.linvel());
            racer.reversing = update_reverse_mode(
                racer.reversing,
                forward_speed,
                racer.input.star_drift,
                racer.input.throttle,
            );

            if grounded {
                if racer.input.throttle && !racer.reversing {
                    rb.add_force(-forward * THROTTLE_FORCE, true);
                }

                if !racer.input.throttle && racer.reversing {
                    rb.add_force(forward * REVERSE_FORCE, true);
                }

                if racer.input.star_drift
                    && !racer.input.throttle
                    && forward_speed > BRAKE_MIN_SPEED
                {
                    let v = rb.linvel();
                    if v.length() > 0.01 {
                        rb.add_force(-v.normalize() * BRAKE_FORCE, true);
                    }
                }
            }

            let steer = racer.input.steer_right - racer.input.steer_left;

            let effective_steer = effective_steer_input(steer, racer.reversing);
            let max_turn = MAX_TURN_RATE_GRIP + (MAX_TURN_RATE_DRIFT - MAX_TURN_RATE_GRIP) * blend;

            let target_yaw = -effective_steer * max_turn;
            let yaw_error = target_yaw - rb.angvel().y;

            rb.apply_torque_impulse(Vec3::new(0., yaw_error * STEER_P_GAIN * delta, 0.), true);

            // Slerp only the horizontal component of velocity toward horiz_forward.
            // Y is preserved so gravity and ramp impulses still apply naturally.
            let vel = rb.linvel();
            let vel_h = Vec3::new(vel.x, 0.0, vel.z);
            let h_speed = vel_h.length();
            if grounded && h_speed > 0.5 && !racer.reversing {
                let cur_dir_h = vel_h / h_speed;
                let rate = ALIGN_RATE_GRIP + (ALIGN_RATE_DRIFT - ALIGN_RATE_GRIP) * blend;
                let new_dir_h = vec3_slerp_clamped(cur_dir_h, horiz_forward, rate * delta);
                let new_h = new_dir_h * h_speed;
                rb.set_linvel(Vec3::new(new_h.x, vel.y, new_h.z), true);
            }

            rb.set_linear_damping(
                NORMAL_LINEAR_DAMPING + (DRIFT_LINEAR_DAMPING - NORMAL_LINEAR_DAMPING) * blend,
            );

            // Boost FSM update — pass horizontal forward so re-alignment detection
            // and the boost impulse stay in the ground plane.
            update_boost_fsm(racer, rb, &horiz_forward, speed, delta, grounded);
            racer.prev_star_drift = racer.input.star_drift;
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

        let physics = &self.physics;
        let mut states = Vec::with_capacity(self.racers.len());
        for (nickname, racer) in &mut self.racers {
            let Some(rb) = physics.get(racer.rigid_body) else {
                continue;
            };
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
        // Stagger racers along the start gate's tangent (horizontal axis at the
        // spawn heading) instead of always along world X.
        let yaw = self.spawn_y_rotation.to_radians();
        let (tan_x, tan_z) = (yaw.cos(), -yaw.sin());
        for (nickname, racer) in self.racers.iter_mut() {
            let off = 5. * racer.idx as f64;
            let spawn_pos = Vec3Proto {
                x: self.spawn_point.x + tan_x * off,
                y: self.spawn_point.y,
                z: self.spawn_point.z + tan_z * off,
            };
            if let Some(rb) = self.physics.rigid_body_set.get_mut(racer.rigid_body) {
                rb.set_position(
                    Pose::new(
                        Vec3::new(spawn_pos.x, spawn_pos.y, spawn_pos.z),
                        Vec3::new(0., 0., 0.),
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
            racer.finished = false;
            racer.racing = true;
            racer.reversing = false;
            racer.grip_blend = 0.0;
            racer.last_sent_rotation = None;
        }
        self.race_timer = 0.;
        self.finish_timer = 0.;
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

        if self.finish_timer > 0.0 {
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
        let mut dnf: Vec<String> = self
            .racers
            .values()
            .filter(|r| r.racing && !r.finished)
            .map(|r| r.nickname.clone())
            .collect();
        dnf.sort();
        rankings.extend(dnf);

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
        self.state = State::Intermission;
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
                    }
                } else if g.provides_finish()
                    && prev < 0.0
                    && d >= 0.0
                    && racer.checkpoints_hit.len() >= checkpoint_count
                {
                    racer.laps += 1;
                    racer.checkpoints_hit.clear();
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
        let raw = include_str!("../tracks/circuit_test.json");
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
