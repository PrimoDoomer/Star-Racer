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

const ORBIT_RADIUS: f64 = 145.0;

const ORBIT_RADIUS_WIDE: f64 = 180.0;

const ORBIT_RADIUS_TIGHT: f64 = 115.0;

const LOOKAHEAD_M: f64 = 40.0;

const DRIFT_THRESHOLD: f64 = 0.60;

const DRIFT_MIN_SPEED: f64 = 3.0;

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

fn signed_steer(mode: BotMode, snap: &BotSnapshot, tick: u64) -> f64 {
    match mode {
        BotMode::Orbiter => orbit_steer(snap, ORBIT_RADIUS),
        BotMode::Chaser => chaser_steer(snap),
        BotMode::Racer => orbit_steer(snap, ORBIT_RADIUS),
        BotMode::Drunk => {
            let base = orbit_steer(snap, ORBIT_RADIUS);

            let noise = ((tick as f64) * 0.31).sin() * 0.4;
            base + noise
        }
        BotMode::Wallhugger => orbit_steer(snap, ORBIT_RADIUS_WIDE),
        BotMode::Hotshot => orbit_steer(snap, ORBIT_RADIUS_TIGHT),
    }
    .clamp(-1.0, 1.0)
}

fn decide(mode: BotMode, snap: &BotSnapshot, tick: u64) -> (bool, f64, f64, bool) {
    let s = signed_steer(mode, snap, tick);
    let drift = match mode {
        BotMode::Racer => s.abs() > DRIFT_THRESHOLD && snap.speed > DRIFT_MIN_SPEED,

        BotMode::Hotshot => snap.speed > DRIFT_MIN_SPEED,

        BotMode::Drunk => (tick % 80) < 20 && snap.speed > DRIFT_MIN_SPEED,
        _ => false,
    };

    (true, (-s).max(0.0), s.max(0.0), drift)
}

fn orbit_steer(snap: &BotSnapshot, radius: f64) -> f64 {
    let p = snap.pos;
    let angle = p.z.atan2(p.x) - LOOKAHEAD_M / radius;
    let target = V2::new(radius * angle.cos(), radius * angle.sin());
    let to_target = target.sub(p).norm();
    quat_right(&snap.rot).dot(to_target)
}

fn chaser_steer(snap: &BotSnapshot) -> f64 {
    let nearest = snap.others.iter().min_by(|a, b| {
        a.sub(snap.pos)
            .len()
            .partial_cmp(&b.sub(snap.pos).len())
            .unwrap()
    });
    match nearest {
        Some(&t) => quat_right(&snap.rot).dot(t.sub(snap.pos).norm()),
        None => orbit_steer(snap, ORBIT_RADIUS),
    }
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
            })
        } else {
            ClientMessage::Request(RequestMessage::JoinLobby {
                lobby_id: cfg.lobby_id.into(),
                nickname: name.clone(),
                color: random_color(),
            })
        };
        if write.send(to_msg(&req)).await.is_err() {
            eprintln!("[bot {name}] Failed to send join request");
            return anyhow::Ok(());
        }

        if let Some(Ok(Message::Text(text))) = read.next().await {
            if let Ok(ServerMessage::Response(Response::LobbyJoined { error: Some(e), .. })) =
                serde_json::from_str::<ServerMessage>(&text)
            {
                eprintln!("[bot {name}] join failed: {e:?}");
                return anyhow::Ok(());
            }
        }

        drive_bot(write, read, name, cfg.mode).await
    })
}

/// Post-join behaviour shared by all bots: track lobby state, steer/drift while
/// racing. Returns when the server connection drops.
async fn drive_bot(
    mut write: SplitSink<Ws, Message>,
    read: SplitStream<Ws>,
    name: String,
    mode: BotMode,
) -> anyhow::Result<()> {
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
    loop {
        sleep(std::time::Duration::from_millis(50)).await;
        if disconnected.load(std::sync::atomic::Ordering::Relaxed) {
            reader.abort();
            return anyhow::Ok(());
        }
        let snap = snapshot.lock().unwrap().clone();
        if !snap.racing {
            continue;
        }
        tick += 1;
        let (throttle, sl, sr, drift) = decide(mode, &snap, tick);
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
                })))
                .await
                .is_err()
            {
                continue;
            }
            match read.next().await {
                Some(Ok(Message::Text(text))) => {
                    if let Ok(ServerMessage::Response(Response::LobbyJoined {
                        error: Some(e),
                        ..
                    })) = serde_json::from_str::<ServerMessage>(&text)
                    {
                        // Beaten to the last slot (or the lobby vanished): wait
                        // a beat and go back to watching the list.
                        eprintln!("[bot {name}] could not join {lobby_id}: {e:?}");
                        sleep(std::time::Duration::from_secs(2)).await;
                        continue;
                    }
                }
                _ => continue,
            }

            println!("[bot {name}] joined lobby {lobby_id}");
            let _ = drive_bot(write, read, name, mode).await;
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
        track_id: "circuit_one",
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
            track_id: "circuit_one",
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
