use futures_util::{
    stream::{SplitSink, SplitStream},
    SinkExt, StreamExt,
};
use pocket_racing_server::protocol::{
    ClientMessage, ColorProto, LobbyEvent, LobbyState, QuatProto, RequestMessage, Response,
    ServerMessage,
};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::task::JoinHandle;
use tokio::time::sleep;
use tungstenite::Message;

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

const DRIFT_THRESHOLD: f64 = 0.55;
const DRIFT_MIN_SPEED: f64 = 1.5; // halved with the car speed (see lobby.rs)

// Corner anticipation: instead of reacting to the instantaneous steer demand, a
// bot looks at how much the racing line BENDS over the next stretch and picks a
// safe pass-through speed for it — braking BEFORE the corner instead of
// understeering into the outer wall mid-bend. BOT_CRUISE_REF ≈ the server's cruise
// speed; the target sheds BOT_BEND_SPEED_GAIN m/s per radian of upcoming bend,
// floored at BOT_CORNER_MIN_SPEED (slowest line a bot will take a hairpin at).
const BOT_CRUISE_REF: f64 = 52.0;
const BOT_CORNER_MIN_SPEED: f64 = 20.0;
const BOT_BEND_SPEED_GAIN: f64 = 26.0;

/// The game server's WebSocket endpoint. Bots run on the same host as the server.
const SERVER_URL: &str = "ws://localhost:8080";

const BOT_LOBBY_PREFIX: &str = "bot_";

const SHOWCASE_LOBBIES: [&str; 3] = ["bot_Solo", "bot_AlmostFull", "bot_Racing"];

/// Size of the joiner pool — bots that watch for lobbies, fill them, and recycle.
const JOINER_COUNT: usize = 100;
/// How often a racing joiner reconsiders leaving its lobby.
const LEAVE_CHECK_SECS: f64 = 6.0;
/// Per-check chance a joiner leaves its race when the pool is healthy (rarely) …
const LEAVE_PROB_NORMAL: f64 = 0.02;
/// … vs when free bots are scarce (often) — leaving frees them to fill new games.
const LEAVE_PROB_SHORTAGE: f64 = 0.5;
/// "Scarce" = fewer than this fraction of the pool is currently waiting/available.
const SHORTAGE_FRAC: f64 = 0.25;
/// Per-poll chance a waiting bot (one of the first few) opens its own lobby when
/// the browser has nothing to join — rarely, so bots seed activity without flooding.
const CREATE_PROB: f64 = 0.012;
/// Only the first few joiners are allowed to create, capping bot-made lobbies.
const CREATORS: u64 = 6;

/// Shared pool state across all joiner tasks (same process): how many bots are
/// currently waiting/available (not in a lobby), used to detect a shortage.
struct Pool {
    available: std::sync::atomic::AtomicUsize,
    total: usize,
}

/// A ready-to-drive session: the socket halves, the bot's nickname and the track
/// centerline pulled from the LobbyJoined response.
type Session = (SplitSink<Ws, Message>, SplitStream<Ws>, String, Vec<V2>);

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

    /// Safe pass-through speed for the corner the bot is approaching, from the
    /// racing line's upcoming bend (see upcoming_bend). The braking horizon grows
    /// with speed so faster bots start shedding speed earlier. Personality scales
    /// it: the hotshot carries more speed (brakes late), the orbiter is cautious.
    fn corner_target_speed(&self, snap: &BotSnapshot, idx: usize) -> f64 {
        let horizon = (snap.speed * 0.7 + 14.0).clamp(16.0, 48.0);
        let bend = upcoming_bend(&self.centerline, idx, horizon);
        let base = (BOT_CRUISE_REF - BOT_BEND_SPEED_GAIN * bend)
            .clamp(BOT_CORNER_MIN_SPEED, BOT_CRUISE_REF);
        let scale = match self.mode {
            BotMode::Hotshot => 1.12,
            BotMode::Orbiter => 0.90,
            BotMode::Wallhugger => 0.95,
            BotMode::Drunk => 1.05,
            _ => 1.0,
        };
        base * scale
    }

    fn steer(&self, snap: &BotSnapshot, tick: u64, idx: usize) -> f64 {
        if self.centerline.len() < 2 {
            return 0.0; // no racing line: just drive straight
        }
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

    fn decide(&self, snap: &BotSnapshot, tick: u64) -> (bool, f64, f64, bool, bool) {
        if self.centerline.len() < 2 {
            return (true, 0.0, 0.0, false, false); // no racing line: just drive straight
        }
        let idx = nearest_idx(&self.centerline, snap.pos);
        let s = self.steer(snap, tick, idx);

        // Corner anticipation: aim for the upcoming corner's safe speed. Lift the
        // throttle once we're over it, and actively brake (drift with no throttle —
        // the server reads that as braking) when we're well over, so the bot sheds
        // speed BEFORE the apex instead of understeering into the outer wall.
        let target_speed = self.corner_target_speed(snap, idx);
        let throttle = snap.speed < target_speed * 1.05;
        let want_brake = snap.speed > target_speed * 1.20;

        // Drift to brake-and-rotate into a corner, or (per personality) whenever
        // turning hard. A braking drift also charges the boost bar for the exit.
        let drift = snap.speed > DRIFT_MIN_SPEED
            && (want_brake
                || match self.mode {
                    BotMode::Hotshot => s.abs() > 0.3,
                    BotMode::Drunk => (tick % 80) < 20,
                    _ => s.abs() > DRIFT_THRESHOLD,
                });
        // Turbo: spend it on the straights, when going fast and roughly aligned.
        // The server only boosts if the bar has charge (built by their cornering
        // drifts), so this naturally fires turbo coming out of a bend. Personality
        // tweaks how greedy/erratic they are. Never while drifting or braking.
        let turbo = !drift
            && !want_brake
            && snap.speed > 18.0
            && match self.mode {
                BotMode::Hotshot => s.abs() < 0.40, // greedy: turbo even mid-bend
                BotMode::Drunk => (tick % 130) < 55, // erratic bursts
                BotMode::Orbiter => s.abs() < 0.15, // cautious, only dead straights
                _ => s.abs() < 0.25,
            };
        (throttle, (-s).max(0.0), s.max(0.0), drift, turbo)
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

/// Total absolute heading change (radians) of the racing line over the next
/// `horizon` metres from `start`. ~0 on a straight, ~π/2 across a right-angle
/// corner — the metric a bot brakes against (see corner_target_speed).
fn upcoming_bend(cl: &[V2], start: usize, horizon: f64) -> f64 {
    let n = cl.len();
    if n < 3 {
        return 0.0;
    }
    let mut acc = 0.0;
    let mut bend = 0.0;
    let mut i = start;
    let mut prev = cl[(i + 1) % n].sub(cl[i]).norm();
    for _ in 0..n {
        let j = (i + 1) % n;
        let seg = cl[j].sub(cl[i]);
        let dir = seg.norm();
        bend += prev.dot(dir).clamp(-1.0, 1.0).acos();
        prev = dir;
        acc += seg.len();
        if acc >= horizon {
            break;
        }
        i = j;
    }
    bend
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
    /// Track for a creator bot (`create: true`); ignored by joining members.
    track_id: String,
    mode: BotMode,
    create: bool,
    min_players: u8,
    max_players: u8,
}

/// Fetch the server's track ids on a throwaway connection (empty on any failure).
async fn fetch_track_ids() -> Vec<String> {
    let Ok((ws, _)) = tokio_tungstenite::connect_async(SERVER_URL).await else {
        return Vec::new();
    };
    let (mut write, mut read) = ws.split();
    if write
        .send(to_msg(&ClientMessage::Request(
            RequestMessage::FetchTrackList,
        )))
        .await
        .is_err()
    {
        return Vec::new();
    }
    // Skip any unrelated message that slips in before the TrackList reply.
    for _ in 0..5 {
        match read.next().await {
            Some(Ok(Message::Text(text))) => {
                if let Ok(ServerMessage::Response(Response::TrackList(tracks))) =
                    serde_json::from_str::<ServerMessage>(&text)
                {
                    return tracks.into_iter().map(|t| t.id).collect();
                }
            }
            _ => break,
        }
    }
    Vec::new()
}

/// A random track id from the server's current set, falling back to the always-
/// shipped `the_bedroom` if the list can't be fetched. Bots call this when they
/// create a lobby so bot-made races aren't all on the same track.
async fn pick_track_id() -> String {
    let ids = fetch_track_ids().await;
    if ids.is_empty() {
        return "the_bedroom".to_string();
    }
    let idx = (rand::random::<u64>() as usize) % ids.len();
    ids[idx].clone()
}

fn launch_bot(cfg: BotConfig) -> JoinHandle<anyhow::Result<()>> {
    tokio::spawn(async move {
        let (ws, _) = match tokio_tungstenite::connect_async(SERVER_URL).await {
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
                track_id: cfg.track_id.clone(),
                nickname: name.clone(),
                min_players: cfg.min_players,
                max_players: cfg.max_players,
                color: random_color(),
                horn_id: String::new(),
                cached_track_hash: None,
                tweaks: std::collections::HashMap::new(),
            })
        } else {
            ClientMessage::Request(RequestMessage::JoinLobby {
                lobby_id: cfg.lobby_id.into(),
                nickname: name.clone(),
                color: random_color(),
                horn_id: String::new(),
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

        // Showcase bots have no pool → they never leave (they ARE the demo lobbies).
        drive_bot(write, read, name, cfg.mode, centerline, None).await
    })
}

/// A randomised launch offset (seconds after GO) for the bot's rocket start,
/// flavoured by personality: hotshots start sharp, drunks fumble, the rest are
/// middling. Re-rolled each race so starts feel varied.
fn pick_launch_offset(mode: BotMode) -> f64 {
    let (lo, hi) = match mode {
        BotMode::Hotshot => (0.0, 0.10),
        BotMode::Drunk => (0.05, 0.30),
        _ => (0.0, 0.20),
    };
    lo + rand::random::<f64>() * (hi - lo)
}

/// Post-join behaviour shared by all bots: track lobby state, steer/drift while
/// racing. Returns when the server connection drops.
async fn drive_bot(
    mut write: SplitSink<Ws, Message>,
    read: SplitStream<Ws>,
    name: String,
    mode: BotMode,
    centerline: Vec<V2>,
    pool: Option<Arc<Pool>>,
) -> anyhow::Result<()> {
    let brain = BotBrain { mode, centerline };
    let mut read = read;
    let snapshot = Arc::new(Mutex::new(BotSnapshot::default()));
    let snap_write = snapshot.clone();
    let my_name = name.clone();

    let disconnected = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let disconnected_recv = disconnected.clone();

    // GO timestamp, set by the reader on the RaceStarted event so the bot can time
    // its rocket start to the actual lights-out instead of pressing during the
    // countdown (which only ever scored a 0 launch).
    let go_at: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));
    let go_write = go_at.clone();

    let reader = tokio::spawn(async move {
        while let Some(Ok(Message::Text(text))) = read.next().await {
            match serde_json::from_str::<ServerMessage>(&text) {
                Ok(ServerMessage::State(LobbyState::Players(players))) => {
                    let mut s = snap_write.lock().unwrap();
                    s.others = players
                        .iter()
                        .filter(|p| p.nickname != my_name && p.racing)
                        .map(|p| V2::new(p.position.x, p.position.z))
                        .collect();
                    if let Some(me) = players.iter().find(|p| p.nickname == my_name) {
                        s.racing = me.racing;
                        let new_pos = V2::new(me.position.x, me.position.z);
                        // State packets arrive ~20 Hz; smooth the per-packet
                        // position delta into a speed estimate so a jittery packet
                        // can't make the bot brake or turbo erratically.
                        let inst = new_pos.sub(s.pos).len() * 20.0;
                        s.speed = s.speed * 0.4 + inst * 0.6;
                        s.pos = new_pos;
                        s.rot = me.rotation;
                    }
                }
                Ok(ServerMessage::Event(LobbyEvent::RaceStarted(_))) => {
                    *go_write.lock().unwrap() = Some(Instant::now());
                }
                _ => {}
            }
        }

        disconnected_recv.store(true, std::sync::atomic::Ordering::Relaxed);
    });

    let mut tick: u64 = 0;
    let mut race_start: Option<Instant> = None;
    // Smart-random rocket start: each race the bot waits a personality-flavoured,
    // randomised offset after GO before flooring it. A small offset ≈ a strong start
    // boost, a larger one fumbles — so starts vary and a sharp human can still win.
    let mut go_seen: Option<Instant> = None;
    let mut launch_offset = pick_launch_offset(mode);
    let mut last_leave_check = Instant::now();
    loop {
        sleep(std::time::Duration::from_millis(50)).await;
        if disconnected.load(std::sync::atomic::Ordering::Relaxed) {
            reader.abort();
            return anyhow::Ok(());
        }

        // Joiner bots leave their lobby now and then so the pool keeps churning —
        // rarely when free bots are plentiful, often when they're scarce (so leaving
        // replenishes the bots available to fill new games). Showcase bots pass no
        // pool and never leave. Returning drops the socket → the joiner recycles.
        if let Some(pool) = &pool {
            if last_leave_check.elapsed().as_secs_f64() >= LEAVE_CHECK_SECS {
                last_leave_check = Instant::now();
                let avail = pool.available.load(std::sync::atomic::Ordering::Relaxed);
                let scarce = (avail as f64) < (pool.total as f64) * SHORTAGE_FRAC;
                let p = if scarce {
                    LEAVE_PROB_SHORTAGE
                } else {
                    LEAVE_PROB_NORMAL
                };
                if rand::random::<f64>() < p {
                    reader.abort();
                    return anyhow::Ok(());
                }
            }
        }

        let snap = snapshot.lock().unwrap().clone();
        if !snap.racing {
            race_start = None;
            continue;
        }
        let started = *race_start.get_or_insert_with(Instant::now);
        tick += 1;

        // Fresh launch offset on each new GO.
        let go = *go_at.lock().unwrap();
        if go != go_seen {
            go_seen = go;
            if go.is_some() {
                launch_offset = pick_launch_offset(mode);
            }
        }
        // Hold the gas until GO + the bot's launch offset → a graded start boost.
        // If GO was never seen (joined mid-race), just drive after a short grace.
        let launched = match go {
            Some(g) => g.elapsed().as_secs_f64() >= launch_offset,
            None => started.elapsed().as_secs_f64() > 6.0,
        };

        let (mut throttle, sl, sr, drift, mut turbo) = brain.decide(&snap, tick);
        if !launched {
            throttle = false;
            turbo = false;
        }
        if write
            .send(to_msg(&ClientMessage::State {
                throttle,
                steer_left: sl,
                steer_right: sr,
                drift,
                respawn: false,
                turbo,
                jump: false,
                horn: false,
                air_roll: false,
                view_yaw: 0.0,
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

/// A pooled bot: it waits for a joinable lobby (human-made first, then bot-made),
/// races, then recycles. While waiting it counts itself "available" in the shared
/// pool; while driving it may leave (see drive_bot) so the pool keeps churning.
fn launch_joiner(idx: u64, mode: BotMode, pool: Arc<Pool>) -> JoinHandle<anyhow::Result<()>> {
    tokio::spawn(async move {
        // Stagger startup so 100 bots trickle in instead of slamming the server.
        sleep(std::time::Duration::from_millis(200 + idx * 50)).await;
        loop {
            pool.available
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let session = wait_for_session(idx).await;
            pool.available
                .fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
            match session {
                Some((write, read, name, centerline)) => {
                    let _ =
                        drive_bot(write, read, name, mode, centerline, Some(pool.clone())).await;
                    // Race over / left: loop back and become available again.
                }
                None => sleep(std::time::Duration::from_secs(2)).await,
            }
        }
    })
}

/// Connect and watch the lobby list until there's something to drive: join a
/// joinable lobby (human-made first, then bot-made), or — rarely, and only for the
/// first few bots when nothing is joinable — open a fresh lobby so the browser
/// isn't empty. Returns a ready session, or None to recycle the connection.
async fn wait_for_session(idx: u64) -> Option<Session> {
    let (ws, _) = tokio_tungstenite::connect_async(SERVER_URL).await.ok()?;
    let (mut write, mut read) = ws.split();
    let name = generate_bot_name();

    loop {
        if write
            .send(to_msg(&ClientMessage::Request(
                RequestMessage::FetchLobbyList,
            )))
            .await
            .is_err()
        {
            return None;
        }
        let lobbies = match read.next().await {
            Some(Ok(Message::Text(text))) => match serde_json::from_str::<ServerMessage>(&text) {
                Ok(ServerMessage::Response(Response::LobbyList(l))) => l,
                Ok(_) => {
                    sleep(std::time::Duration::from_millis(600)).await;
                    continue; // some other message slipped in; ask again
                }
                Err(_) => continue,
            },
            Some(Ok(_)) => continue,
            _ => return None, // connection lost → reconnect
        };

        // Joinable = not a showcase lobby, not racing, has a free slot.
        let joinable = |l: &pocket_racing_server::protocol::LobbyInfo| {
            !SHOWCASE_LOBBIES.contains(&l.name.as_str())
                && !l.racing
                && l.player_count < l.max_players
        };
        // Prefer human-made lobbies; fall back to bot-made ones so humans fill first.
        let pick = lobbies
            .iter()
            .find(|l| joinable(l) && !l.owner.starts_with("<Bot>"))
            .or_else(|| lobbies.iter().find(|l| joinable(l)))
            .map(|l| l.name.clone());

        if let Some(lobby_id) = pick {
            if write
                .send(to_msg(&ClientMessage::Request(RequestMessage::JoinLobby {
                    lobby_id: lobby_id.clone(),
                    nickname: name.clone(),
                    color: random_color(),
                    horn_id: String::new(),
                    cached_track_hash: None,
                })))
                .await
                .is_err()
            {
                return None;
            }
            match read_join_result(&mut read).await {
                Some(centerline) => {
                    println!("[bot {name}] joined lobby {lobby_id}");
                    return Some((write, read, name, centerline));
                }
                None => {
                    sleep(std::time::Duration::from_secs(1)).await;
                    continue; // beaten to the slot / it vanished — keep watching
                }
            }
        }

        // Nothing to join: rarely, a creator bot opens a fresh lobby for others.
        if idx < CREATORS && rand::random::<f64>() < CREATE_PROB {
            let lobby_id = format!("{}{}", BOT_LOBBY_PREFIX, rand::random::<u16>());
            if write
                .send(to_msg(&ClientMessage::Request(
                    RequestMessage::CreateLobby {
                        lobby_id: lobby_id.clone(),
                        track_id: pick_track_id().await,
                        nickname: name.clone(),
                        min_players: 2,
                        max_players: 6,
                        color: random_color(),
                        horn_id: String::new(),
                        cached_track_hash: None,
                        tweaks: std::collections::HashMap::new(),
                    },
                )))
                .await
                .is_err()
            {
                return None;
            }
            if let Some(centerline) = read_join_result(&mut read).await {
                println!("[bot {name}] opened lobby {lobby_id}");
                return Some((write, read, name, centerline));
            }
            // Create failed (id clash, etc.): keep watching.
        }

        sleep(std::time::Duration::from_millis(1200 + idx * 20)).await;
    }
}

/// Read the LobbyJoined reply after a join/create: the track centerline on success
/// (empty if the track wasn't shipped), or None if the join was rejected/lost.
async fn read_join_result(read: &mut SplitStream<Ws>) -> Option<Vec<V2>> {
    match read.next().await {
        Some(Ok(Message::Text(text))) => match serde_json::from_str::<ServerMessage>(&text) {
            Ok(ServerMessage::Response(Response::LobbyJoined { error, track, .. })) => {
                if error.is_some() {
                    None
                } else {
                    Some(
                        track
                            .map(|t| {
                                t.centerline
                                    .into_iter()
                                    .map(|p| V2::new(p[0], p[1]))
                                    .collect()
                            })
                            .unwrap_or_default(),
                    )
                }
            }
            _ => Some(Vec::new()),
        },
        _ => None,
    }
}

fn to_msg(v: &impl serde::Serialize) -> Message {
    Message::Text(serde_json::to_string(v).unwrap().into())
}

/// Block until the game server accepts a WebSocket connection. systemd may start
/// the bots service before the server's port is listening; without this the
/// showcase creator bots hit "Connection refused", their lobbies are never made,
/// and the member bots then fail with LobbyNotFound. Retries with a 1s backoff.
async fn wait_for_server() {
    let mut attempt: u32 = 0;
    loop {
        if tokio_tungstenite::connect_async(SERVER_URL).await.is_ok() {
            return; // probe connection drops here, closing cleanly
        }
        attempt += 1;
        if attempt == 1 || attempt.is_multiple_of(5) {
            eprintln!("[bots] waiting for server at {SERVER_URL} (attempt {attempt})…");
        }
        sleep(std::time::Duration::from_secs(1)).await;
    }
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
        track_id: pick_track_id().await,
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
            track_id: String::new(), // members join; track is the creator's choice
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

    // Don't race the server's startup: wait for its port before creating lobbies.
    wait_for_server().await;

    println!("Launching 3 showcase lobbies…");

    // Run the three lobbies concurrently so total startup is ~one create-delay,
    // not the sum of them (the old sequential setup took ~9s for six lobbies).
    let (waiting_one, waiting_five, full_four) = tokio::join!(
        // 1 bot, needs 1 more to start (1/2).
        spawn_lobby(SHOWCASE_LOBBIES[0], 2, 2, &[BotMode::Racer]),
        // 5 bots, needs 1 more to start (5/6).
        spawn_lobby(
            SHOWCASE_LOBBIES[1],
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
            SHOWCASE_LOBBIES[2],
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
    // Shared pool counter: lets a racing bot tell when free bots are scarce and
    // leave to replenish them (see drive_bot's leave logic).
    let pool = Arc::new(Pool {
        available: std::sync::atomic::AtomicUsize::new(0),
        total: JOINER_COUNT,
    });
    for idx in 0..JOINER_COUNT {
        let mode = JOINER_MODES[idx % JOINER_MODES.len()];
        hdls.push(launch_joiner(idx as u64, mode, pool.clone()));
    }
    println!("{JOINER_COUNT} joiner bots watching for player lobbies.");

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

#[cfg(test)]
mod tests {
    use super::*;

    fn line(pts: &[(f64, f64)]) -> Vec<V2> {
        pts.iter().map(|&(x, z)| V2::new(x, z)).collect()
    }

    /// A long straight up +Z. `upcoming_bend` is cyclic (real centerlines are
    /// closed loops), so fixtures must be long enough that the test horizon never
    /// reaches the fixture's end→start wrap, which would read as a fake U-turn.
    fn long_straight() -> Vec<V2> {
        line(&(0..=12).map(|i| (0.0, i as f64 * 10.0)).collect::<Vec<_>>())
    }

    /// Straight up +Z, a ~90° turn, then a long straight along +X.
    fn right_angle() -> Vec<V2> {
        let mut p: Vec<(f64, f64)> = (0..=3).map(|i| (0.0, i as f64 * 10.0)).collect();
        p.extend((1..=9).map(|i| (i as f64 * 10.0, 30.0)));
        line(&p)
    }

    #[test]
    fn bend_is_near_zero_on_a_straight() {
        assert!(upcoming_bend(&long_straight(), 0, 25.0) < 0.05);
    }

    #[test]
    fn bend_detects_a_right_angle_corner() {
        // Horizon reaches past the ~90° turn: cumulative heading change ≈ π/2.
        let b = upcoming_bend(&right_angle(), 0, 45.0);
        assert!(b > 1.2 && b < 1.9, "≈90° bend expected, got {b:.2} rad");
    }

    #[test]
    fn corner_target_speed_is_lower_into_a_bend_than_a_straight() {
        let straight = BotBrain {
            mode: BotMode::Racer,
            centerline: long_straight(),
        };
        let corner = BotBrain {
            mode: BotMode::Racer,
            centerline: right_angle(),
        };
        let snap = BotSnapshot {
            speed: 40.0,
            ..Default::default()
        };
        let vs = straight.corner_target_speed(&snap, 0);
        let vc = corner.corner_target_speed(&snap, 0);
        assert!(
            vc < vs,
            "bot should target a lower speed into a corner ({vc:.1}) than on a straight ({vs:.1})"
        );
        assert!(vc >= BOT_CORNER_MIN_SPEED);
    }

    #[test]
    fn bot_lifts_throttle_when_overspeeding_a_corner() {
        let corner = BotBrain {
            mode: BotMode::Racer,
            centerline: right_angle(),
        };
        // Barrelling toward the corner well above its safe speed.
        let fast = BotSnapshot {
            speed: 60.0,
            ..Default::default()
        };
        let (throttle, _, _, drift, _) = corner.decide(&fast, 0);
        assert!(
            !throttle,
            "bot should lift off when too fast for the corner"
        );
        assert!(
            drift,
            "bot should brake-drift to shed speed into the corner"
        );
    }
}
