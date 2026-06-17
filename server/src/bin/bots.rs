use futures_util::{
    stream::{SplitSink, SplitStream},
    SinkExt, StreamExt,
};
use star_racer_server::protocol::{
    ClientMessage, ColorProto, LobbyState, QuatProto, RequestMessage, Response, ServerMessage,
};
use std::sync::{Arc, Mutex};
use tokio::task::JoinHandle;
use tokio::time::sleep;
use tungstenite::Message;

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

const DRIFT_THRESHOLD: f64 = 0.55;
const DRIFT_MIN_SPEED: f64 = 1.5; // halved with the car speed (see lobby.rs)

#[derive(Clone, Copy, Default)]
struct V2 {
    x: f64,
    z: f64,
}

impl V2 {
    fn new(x: f64, z: f64) -> Self {
        Self { x, z }
    }
    fn len(self) -> f64 {
        (self.x * self.x + self.z * self.z).sqrt()
    }
    fn norm(self) -> Self {
        let l = self.len();
        if l < 1e-9 {
            Self::new(0.0, 1.0)
        } else {
            Self::new(self.x / l, self.z / l)
        }
    }
    fn dot(self, o: Self) -> f64 {
        self.x * o.x + self.z * o.z
    }
    fn sub(self, o: Self) -> Self {
        Self::new(self.x - o.x, self.z - o.z)
    }
    fn add(self, o: Self) -> Self {
        Self::new(self.x + o.x, self.z + o.z)
    }
    fn scale(self, k: f64) -> Self {
        Self::new(self.x * k, self.z * k)
    }
    /// Left-hand perpendicular in the XZ plane.
    fn perp(self) -> Self {
        Self::new(-self.z, self.x)
    }
}

fn quat_right(q: &QuatProto) -> V2 {
    let (qx, qy, qz, qw) = (q.x, q.y, q.z, q.w);
    V2::new(1.0 - 2.0 * (qy * qy + qz * qz), 2.0 * (qx * qz - qw * qy))
}

#[derive(Clone, Copy, Debug)]
enum BotMode {
    Orbiter,

    Chaser,

    Racer,

    Drunk,

    Wallhugger,

    Hotshot,
}

#[derive(Clone)]
struct BotSnapshot {
    racing: bool,
    pos: V2,
    rot: QuatProto,
    speed: f64,
    others: Vec<V2>,
}

impl Default for BotSnapshot {
    fn default() -> Self {
        Self {
            racing: false,
            pos: V2::default(),
            rot: QuatProto {
                x: 0.0,
                y: 0.0,
                z: 0.0,
                w: 1.0,
            },
            speed: 0.0,
            others: Vec::new(),
        }
    }
}

/// A bot's driving brain: the track racing line plus a personality. Steering
/// follows the centerline with a lookahead, so bots actually drive the track
/// instead of orbiting the world origin (the old, track-blind behaviour).
struct BotBrain {
    mode: BotMode,
    centerline: Vec<V2>,
}

impl BotBrain {
    /// Base lookahead (metres); the real one grows with speed so the bot starts
    /// turning — and braking — earlier the faster it goes.
    fn base_look(&self) -> f64 {
        match self.mode {
            BotMode::Hotshot => 16.0,
            BotMode::Wallhugger => 22.0,
            _ => 20.0,
        }
    }

    /// Lateral offset from the racing line: outside for the wall-hugger, inside
    /// for the orbiter, centre for the rest.
    fn lateral(&self) -> f64 {
        match self.mode {
            BotMode::Wallhugger => 7.0,
            BotMode::Orbiter => -7.0,
            _ => 0.0,
        }
    }

    fn steer(&self, snap: &BotSnapshot, tick: u64) -> f64 {
        if self.centerline.len() < 2 {
            return 0.0; // no racing line: just drive straight
        }
        let idx = nearest_idx(&self.centerline, snap.pos);
        let look = (self.base_look() + snap.speed * 0.6).clamp(14.0, 60.0);
        let mut target = target_ahead(&self.centerline, idx, look);

        let lat = self.lateral();
        if lat != 0.0 {
            let n = self.centerline.len();
            let dir = self.centerline[(idx + 1) % n]
                .sub(self.centerline[idx])
                .norm();
            target = target.add(dir.perp().scale(lat));
        }

        // The chaser cuts toward a nearby opponent ahead of it.
        if matches!(self.mode, BotMode::Chaser) {
            if let Some(&o) = snap
                .others
                .iter()
                .filter(|o| o.sub(snap.pos).len() < 28.0)
                .min_by(|a, b| {
                    a.sub(snap.pos)
                        .len()
                        .partial_cmp(&b.sub(snap.pos).len())
                        .unwrap()
                })
            {
                target = target.add(o.sub(target).scale(0.4));
            }
        }

        let mut s = quat_right(&snap.rot).dot(target.sub(snap.pos).norm());
        if matches!(self.mode, BotMode::Drunk) {
            s += ((tick as f64) * 0.31).sin() * 0.35;
        }
        s.clamp(-1.0, 1.0)
    }

    fn decide(&self, snap: &BotSnapshot, tick: u64) -> (bool, f64, f64, bool) {
        let s = self.steer(snap, tick);
        // Lift off (coast) when turning hard at speed so the car can actually
        // hold the corner instead of understeering into the outer wall. The
        // hotshot brakes later (carries more speed) and drifts more.
        // Speeds halved (see lobby.rs): lift thresholds halve too, else bots never
        // coast into corners and understeer into the wall.
        let (lift_steer, lift_speed) = match self.mode {
            BotMode::Hotshot => (0.55, 12.0),
            _ => (0.45, 8.5),
        };
        let throttle = !(s.abs() > lift_steer && snap.speed > lift_speed);
        let drift = snap.speed > DRIFT_MIN_SPEED
            && match self.mode {
                BotMode::Hotshot => s.abs() > 0.3,
                BotMode::Drunk => (tick % 80) < 20,
                _ => s.abs() > DRIFT_THRESHOLD,
            };
        (throttle, (-s).max(0.0), s.max(0.0), drift)
    }
}

/// Index of the centerline vertex nearest `p`.
fn nearest_idx(cl: &[V2], p: V2) -> usize {
    let mut best = 0;
    let mut bd = f64::MAX;
    for (i, &c) in cl.iter().enumerate() {
        let d = c.sub(p).len();
        if d < bd {
            bd = d;
            best = i;
        }
    }
    best
}

/// Point ~`lookahead` metres further along the (cyclic) centerline from `start`.
fn target_ahead(cl: &[V2], start: usize, lookahead: f64) -> V2 {
    let n = cl.len();
    let mut acc = 0.0;
    let mut i = start;
    for _ in 0..n {
        let j = (i + 1) % n;
        acc += cl[j].sub(cl[i]).len();
        if acc >= lookahead {
            return cl[j];
        }
        i = j;
    }
    cl[(start + 1) % n]
}

struct BotConfig {
    lobby_id: &'static str,
    track_id: &'static str,
    mode: BotMode,
    create: bool,
    min_players: u8,
    max_players: u8,
}

fn launch_bot(cfg: BotConfig) -> JoinHandle<anyhow::Result<()>> {
    tokio::spawn(async move {
        let (ws, _) = match tokio_tungstenite::connect_async("ws://localhost:8080").await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[bot] Connection failed: {e}");
                return anyhow::Ok(());
            }
        };
        let (mut write, mut read) = ws.split();

        let name = generate_bot_name();

        let req = if cfg.create {
            ClientMessage::Request(RequestMessage::CreateLobby {
                lobby_id: cfg.lobby_id.into(),
                track_id: cfg.track_id.into(),
                nickname: name.clone(),
                min_players: cfg.min_players,
                max_players: cfg.max_players,
                color: random_color(),
                cached_track_hash: None,
            })
        } else {
            ClientMessage::Request(RequestMessage::JoinLobby {
                lobby_id: cfg.lobby_id.into(),
                nickname: name.clone(),
                color: random_color(),
                cached_track_hash: None,
            })
        };
        if write.send(to_msg(&req)).await.is_err() {
            eprintln!("[bot {name}] Failed to send join request");
            return anyhow::Ok(());
        }

        let centerline = match read.next().await {
            Some(Ok(Message::Text(text))) => match serde_json::from_str::<ServerMessage>(&text) {
                Ok(ServerMessage::Response(Response::LobbyJoined { error: Some(e), .. })) => {
                    eprintln!("[bot {name}] join failed: {e:?}");
                    return anyhow::Ok(());
                }
                Ok(ServerMessage::Response(Response::LobbyJoined { track: Some(t), .. })) => t
                    .centerline
                    .into_iter()
                    .map(|p| V2::new(p[0], p[1]))
                    .collect(),
                _ => Vec::new(),
            },
            _ => Vec::new(),
        };

        drive_bot(write, read, name, cfg.mode, centerline).await
    })
}

/// Post-join behaviour shared by all bots: track lobby state, steer/drift while
/// racing. Returns when the server connection drops.
async fn drive_bot(
    mut write: SplitSink<Ws, Message>,
    read: SplitStream<Ws>,
    name: String,
    mode: BotMode,
    centerline: Vec<V2>,
) -> anyhow::Result<()> {
    let brain = BotBrain { mode, centerline };
    let mut read = read;
    let snapshot = Arc::new(Mutex::new(BotSnapshot::default()));
    let snap_write = snapshot.clone();
    let my_name = name.clone();

    let disconnected = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let disconnected_recv = disconnected.clone();

    let reader = tokio::spawn(async move {
        while let Some(Ok(Message::Text(text))) = read.next().await {
            let Ok(ServerMessage::State(LobbyState::Players(players))) =
                serde_json::from_str::<ServerMessage>(&text)
            else {
                continue;
            };
            let mut s = snap_write.lock().unwrap();
            s.others = players
                .iter()
                .filter(|p| p.nickname != my_name && p.racing)
                .map(|p| V2::new(p.position.x, p.position.z))
                .collect();
            if let Some(me) = players.iter().find(|p| p.nickname == my_name) {
                s.racing = me.racing;
                let new_pos = V2::new(me.position.x, me.position.z);
                s.speed = new_pos.sub(s.pos).len() * 20.0;
                s.pos = new_pos;
                s.rot = me.rotation;
            }
        }

        disconnected_recv.store(true, std::sync::atomic::Ordering::Relaxed);
    });

    let mut tick: u64 = 0;
    // Per-bot start handicap: hold the throttle for a short, bot-specific delay
    // after GO. Bots run server-side with no input latency, so without this they'd
    // get a near-perfect launch every time and out-drag a networked human; this
    // makes them miss part of the launch window, so a human's perfect start wins.
    let launch_delay =
        std::time::Duration::from_millis(60 + name.bytes().map(|b| b as u64).sum::<u64>() % 160);
    let mut race_start: Option<std::time::Instant> = None;
    loop {
        sleep(std::time::Duration::from_millis(50)).await;
        if disconnected.load(std::sync::atomic::Ordering::Relaxed) {
            reader.abort();
            return anyhow::Ok(());
        }
        let snap = snapshot.lock().unwrap().clone();
        if !snap.racing {
            race_start = None;
            continue;
        }
        let started = *race_start.get_or_insert_with(std::time::Instant::now);
        tick += 1;
        let (mut throttle, sl, sr, drift) = brain.decide(&snap, tick);
        if started.elapsed() < launch_delay {
            throttle = false; // deliberately miss part of the launch window
        }
        if write
            .send(to_msg(&ClientMessage::State {
                throttle,
                steer_left: sl,
                steer_right: sr,
                star_drift: drift,
            }))
            .await
            .is_err()
        {
            eprintln!("[bot {name}] Server disconnected");
            reader.abort();
            return anyhow::Ok(());
        }
    }
}

/// A bot that waits for a human-created lobby (not one of the "<Bots>" showcase
/// lobbies) to appear, joins it, and races. When the connection drops it goes
/// back to waiting, so the pool survives across lobbies.
fn launch_joiner(idx: u64, mode: BotMode) -> JoinHandle<anyhow::Result<()>> {
    tokio::spawn(async move {
        // Stagger the pool so joiners trickle into a lobby instead of slamming
        // it all at once the instant it appears.
        sleep(std::time::Duration::from_millis(500 + idx * 900)).await;
        loop {
            let (ws, _) = match tokio_tungstenite::connect_async("ws://localhost:8080").await {
                Ok(c) => c,
                Err(_) => {
                    sleep(std::time::Duration::from_secs(3)).await;
                    continue;
                }
            };
            let (mut write, mut read) = ws.split();
            let name = generate_bot_name();

            // Poll the lobby list until a joinable human lobby shows up.
            let lobby_id = loop {
                if write
                    .send(to_msg(&ClientMessage::Request(
                        RequestMessage::FetchLobbyList,
                    )))
                    .await
                    .is_err()
                {
                    break None;
                }
                let candidate = match read.next().await {
                    Some(Ok(Message::Text(text))) => {
                        match serde_json::from_str::<ServerMessage>(&text) {
                            Ok(ServerMessage::Response(Response::LobbyList(lobbies))) => lobbies
                                .into_iter()
                                .find(|l| {
                                    !l.name.starts_with("<Bots>")
                                        && !l.owner.starts_with("<Bot>")
                                        && !l.racing
                                        && l.player_count < l.max_players
                                })
                                .map(|l| l.name),
                            Ok(_) => None,
                            Err(_) => None,
                        }
                    }
                    Some(Ok(_)) => None,
                    _ => break None, // connection lost → reconnect
                };
                if let Some(id) = candidate {
                    break Some(id);
                }
                sleep(std::time::Duration::from_millis(1500 + idx * 150)).await;
            };
            let Some(lobby_id) = lobby_id else {
                sleep(std::time::Duration::from_secs(3)).await;
                continue;
            };

            if write
                .send(to_msg(&ClientMessage::Request(RequestMessage::JoinLobby {
                    lobby_id: lobby_id.clone(),
                    nickname: name.clone(),
                    color: random_color(),
                    cached_track_hash: None,
                })))
                .await
                .is_err()
            {
                continue;
            }
            let centerline = match read.next().await {
                Some(Ok(Message::Text(text))) => {
                    match serde_json::from_str::<ServerMessage>(&text) {
                        Ok(ServerMessage::Response(Response::LobbyJoined {
                            error: Some(e),
                            ..
                        })) => {
                            // Beaten to the last slot (or the lobby vanished): wait
                            // a beat and go back to watching the list.
                            eprintln!("[bot {name}] could not join {lobby_id}: {e:?}");
                            sleep(std::time::Duration::from_secs(2)).await;
                            continue;
                        }
                        Ok(ServerMessage::Response(Response::LobbyJoined {
                            track: Some(t),
                            ..
                        })) => t
                            .centerline
                            .into_iter()
                            .map(|p| V2::new(p[0], p[1]))
                            .collect(),
                        _ => Vec::new(),
                    }
                }
                _ => continue,
            };

            println!("[bot {name}] joined lobby {lobby_id}");
            let _ = drive_bot(write, read, name, mode, centerline).await;
            // Connection over (lobby closed / kicked): loop back to waiting.
        }
    })
}

fn to_msg(v: &impl serde::Serialize) -> Message {
    Message::Text(serde_json::to_string(v).unwrap().into())
}

fn random_color() -> ColorProto {
    ColorProto {
        x: rand::random(),
        y: rand::random(),
        z: rand::random(),
    }
}

const BOT_NAMES: &[&str] = &[
    "Blaze", "Viper", "Phantom", "Storm", "Phoenix", "Titan", "Echo", "Nova", "Cyber", "Shadow",
    "Nexus", "Forge", "Thunder", "Flux", "Prism", "Velocity", "Apex", "Rival", "Surge", "Axon",
    "Zephyr", "Pulse", "Spectre", "Crux", "Helix", "Orbit", "Zenith", "Comet", "Sphinx", "Drift",
    "Turbo", "Neon",
];

fn generate_bot_name() -> String {
    let name = BOT_NAMES[(rand::random::<u8>() % BOT_NAMES.len() as u8) as usize];
    format!("<Bot>{}{}", name, rand::random::<u8>() % 100)
}

async fn spawn_lobby(
    lobby_id: &'static str,
    min_players: u8,
    max_players: u8,
    modes: &[BotMode],
) -> Vec<JoinHandle<anyhow::Result<()>>> {
    let mut hdls = Vec::new();
    if modes.is_empty() {
        return hdls;
    }

    hdls.push(launch_bot(BotConfig {
        lobby_id,
        track_id: "circuit_simple",
        mode: modes[0],
        create: true,
        min_players,
        max_players,
    }));

    // Give the CreateLobby a moment to land before members try to join.
    sleep(std::time::Duration::from_millis(1200)).await;

    for &mode in &modes[1..] {
        hdls.push(launch_bot(BotConfig {
            lobby_id,
            track_id: "circuit_simple",
            mode,
            create: false,
            min_players: 0,
            max_players: 0,
        }));
        sleep(std::time::Duration::from_millis(150)).await;
    }
    hdls
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    env_logger::init();

    println!("Launching 3 showcase lobbies…");

    // Run the three lobbies concurrently so total startup is ~one create-delay,
    // not the sum of them (the old sequential setup took ~9s for six lobbies).
    let (waiting_one, waiting_five, full_four) = tokio::join!(
        // 1 bot, needs 1 more to start (1/2).
        spawn_lobby("<Bots>Solo", 2, 2, &[BotMode::Racer]),
        // 5 bots, needs 1 more to start (5/6).
        spawn_lobby(
            "<Bots>AlmostFull",
            6,
            6,
            &[
                BotMode::Orbiter,
                BotMode::Chaser,
                BotMode::Racer,
                BotMode::Drunk,
                BotMode::Hotshot,
            ],
        ),
        // 4 bots, full and already racing (4/4).
        spawn_lobby(
            "<Bots>Racing",
            4,
            4,
            &[
                BotMode::Racer,
                BotMode::Chaser,
                BotMode::Wallhugger,
                BotMode::Orbiter,
            ],
        ),
    );

    let mut hdls: Vec<JoinHandle<anyhow::Result<()>>> = Vec::new();
    hdls.extend(waiting_one);
    hdls.extend(waiting_five);
    hdls.extend(full_four);

    // A pool of joiners that wait for human-created lobbies and fill them up.
    const JOINER_MODES: [BotMode; 10] = [
        BotMode::Racer,
        BotMode::Hotshot,
        BotMode::Chaser,
        BotMode::Drunk,
        BotMode::Wallhugger,
        BotMode::Racer,
        BotMode::Orbiter,
        BotMode::Hotshot,
        BotMode::Racer,
        BotMode::Chaser,
    ];
    for (idx, mode) in JOINER_MODES.into_iter().enumerate() {
        hdls.push(launch_joiner(idx as u64, mode));
    }
    println!(
        "{} joiner bots watching for player lobbies.",
        JOINER_MODES.len()
    );

    println!("All bots launched ({} total). Ctrl+C to stop.", hdls.len());

    for hdl in hdls {
        match hdl.await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => eprintln!("[bot] Exited with error: {e}"),
            Err(e) => eprintln!("[bot] Task panicked: {e}"),
        }
    }
    anyhow::Ok(())
}
