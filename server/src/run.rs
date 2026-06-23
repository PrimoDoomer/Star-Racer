use crate::{
    error::Error,
    lobby::{send_join_error, spawn_ws_writer, Lobby, OutgoingMessage},
    protocol::{
        ClientMessage, ColorProto, JoinError, LobbyInfo, RequestMessage, Response, ServerMessage,
        TrackInfo,
    },
    sr_log,
    tracks_dir::{load_all, SharedTracks, TrackMap},
    Result,
};
use chrono::Utc;
use futures_util::{stream::SplitStream, SinkExt, StreamExt};
use std::{
    collections::HashMap, panic::AssertUnwindSafe, path::PathBuf, sync::Arc, time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{mpsc, oneshot},
};
use tokio_tungstenite::{accept_async, WebSocketStream};
use tungstenite::Message;

const FIXED_DT: f64 = 1.0 / 60.0;
const FIXED_DT_DURATION: Duration = Duration::from_nanos((FIXED_DT * 1_000_000_000.0) as u64);
const MAX_STEPS_PER_FRAME: u32 = 5;

enum LobbyCommand {
    FetchList {
        resp: oneshot::Sender<Vec<LobbyInfo>>,
    },
    FetchTracks {
        resp: oneshot::Sender<Vec<TrackInfo>>,
    },
    Create {
        lobby_id: String,
        track_id: String,
        nickname: String,
        min_players: u8,
        max_players: u8,
        color: ColorProto,
        horn_id: String,
        cached_track_hash: Option<String>,
        tx_out: mpsc::Sender<OutgoingMessage>,
        rx_stream: SplitStream<WebSocketStream<TcpStream>>,
    },
    Join {
        lobby_id: String,
        nickname: String,
        color: ColorProto,
        horn_id: String,
        cached_track_hash: Option<String>,
        tx_out: mpsc::Sender<OutgoingMessage>,
        rx_stream: SplitStream<WebSocketStream<TcpStream>>,
    },
}

pub async fn run(port: u16, tracks: SharedTracks, tracks_path: PathBuf) -> Result<()> {
    let endpoint = format!("127.0.0.1:{}", port);
    let listener = TcpListener::bind(&endpoint)
        .await
        .map_err(Error::TcpError)?;
    sr_log!(info, "RUN", "server listening on {}", endpoint);
    spawn_reload_watcher(Arc::clone(&tracks), tracks_path);
    run_with_listener(listener, tracks).await
}

pub async fn run_with_listener(listener: TcpListener, tracks: SharedTracks) -> Result<()> {
    let (cmd_tx, cmd_rx) = mpsc::channel::<LobbyCommand>(64);

    spawn_core_loop(cmd_rx, tracks);
    sr_log!(info, "RUN", "core loop spawned, awaiting connections");

    loop {
        let (stream, peer) = listener.accept().await.map_err(Error::TcpError)?;
        let _ = stream.set_nodelay(true);
        sr_log!(trace, "RUN", "tcp accept from {}", peer);

        tokio::spawn(handle_connection(stream, cmd_tx.clone()));
    }
}

/// Background task that re-scans the tracks directory every couple of seconds
/// and hot-swaps the shared set when a track is added, removed, or its content
/// hash changes — so new/edited circuits go live without a server restart. A
/// parse error (e.g. a half-written file) is logged and the current set kept.
fn spawn_reload_watcher(tracks: SharedTracks, tracks_path: PathBuf) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(2));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            match load_all(&tracks_path) {
                Ok(new_map) => {
                    let changed = {
                        let current = tracks.read().unwrap();
                        tracks_changed(&current, &new_map)
                    };
                    if changed {
                        let count = new_map.len();
                        let summary = new_map.keys().cloned().collect::<Vec<_>>().join(", ");
                        *tracks.write().unwrap() = Arc::new(new_map);
                        sr_log!(
                            info,
                            "TRACKS",
                            "hot-reloaded {} track(s): [{}]",
                            count,
                            summary
                        );
                    }
                }
                Err(e) => {
                    sr_log!(warn, "TRACKS", "reload skipped (kept current set): {}", e);
                }
            }
        }
    });
}

/// True when the candidate set differs from the current one by id set or by any
/// track's content hash.
fn tracks_changed(current: &TrackMap, candidate: &TrackMap) -> bool {
    if current.len() != candidate.len() {
        return true;
    }
    for (id, track) in candidate {
        match current.get(id) {
            Some(existing) if existing.hash == track.hash => {}
            _ => return true,
        }
    }
    false
}

fn spawn_core_loop(mut rx: mpsc::Receiver<LobbyCommand>, tracks: SharedTracks) {
    tokio::spawn(async move {
        let mut lobbies: HashMap<String, Lobby> = HashMap::new();
        let mut next_tick = tokio::time::Instant::now() + FIXED_DT_DURATION;
        let mut accumulator = Duration::ZERO;
        let mut last_now = tokio::time::Instant::now();

        loop {
            tokio::select! {

                biased;

                _ = tokio::time::sleep_until(next_tick) => {
                    let now = tokio::time::Instant::now();
                    accumulator += now - last_now;
                    last_now = now;

                    let mut steps = 0;
                    while accumulator >= FIXED_DT_DURATION && steps < MAX_STEPS_PER_FRAME {
                        accumulator -= FIXED_DT_DURATION;
                        steps += 1;
                        if !lobbies.is_empty() {
                            run_tick(&mut lobbies, FIXED_DT);
                        }
                    }
                    if steps == MAX_STEPS_PER_FRAME {
                        accumulator = Duration::ZERO;
                    }
                    next_tick = now + FIXED_DT_DURATION - accumulator;

                }

                Some(cmd) = rx.recv() => {
                    handle_command(cmd, &mut lobbies, &tracks);
                }

                else => return,
            }
        }
    });
}

fn run_tick(lobbies: &mut HashMap<String, Lobby>, delta: f64) {
    lobbies.retain(|_, lobby| {
        matches!(
            std::panic::catch_unwind(AssertUnwindSafe(|| lobby.update(delta))),
            Ok(true)
        )
    });
}

fn handle_command(cmd: LobbyCommand, lobbies: &mut HashMap<String, Lobby>, tracks: &SharedTracks) {
    match cmd {
        LobbyCommand::FetchList { resp } => {
            sr_log!(trace, "LOBBY", "fetch list ({} lobbies)", lobbies.len());
            let _ = resp.send(build_lobby_list(lobbies));
        }

        LobbyCommand::FetchTracks { resp } => {
            let guard = tracks.read().unwrap();
            sr_log!(trace, "LOBBY", "fetch tracks ({} tracks)", guard.len());
            let _ = resp.send(build_track_list(&guard));
        }

        LobbyCommand::Create {
            lobby_id,
            track_id,
            nickname,
            min_players,
            max_players,
            color,
            horn_id,
            cached_track_hash,
            tx_out,
            rx_stream,
        } => {
            sr_log!(
                trace,
                "LOBBY",
                "create request: id={} owner={} track={} min={} max={}",
                lobby_id,
                nickname,
                track_id,
                min_players,
                max_players
            );
            if nickname.trim().is_empty() || lobby_id.trim().is_empty() {
                sr_log!(trace, "LOBBY", "create rejected: empty name(s)");
                send_join_error(&tx_out, JoinError::InvalidName);
                return;
            }
            // A lobby is just a named room, not the property of a player. Re-using a
            // name is allowed when the old room is empty (e.g. its creator just left
            // and it hasn't been garbage-collected yet) or when the same player is
            // re-making their own room — so quitting and creating again always works.
            // Only a *different* player's still-populated lobby blocks the name.
            if let Some(existing) = lobbies.get(&lobby_id) {
                if existing.player_count() > 0 && existing.owner != nickname {
                    sr_log!(
                        trace,
                        "LOBBY",
                        "create rejected: id={} already exists (active)",
                        lobby_id
                    );
                    send_join_error(&tx_out, JoinError::LobbyAlreadyExists);
                    return;
                }
                sr_log!(
                    trace,
                    "LOBBY",
                    "create: replacing stale lobby id={}",
                    lobby_id
                );
                lobbies.remove(&lobby_id);
            }
            if let Some(error) = validate_lobby_config(min_players, max_players) {
                sr_log!(
                    trace,
                    "LOBBY",
                    "create rejected: invalid config min={} max={}",
                    min_players,
                    max_players
                );
                send_join_error(&tx_out, error);
                return;
            }
            let track = tracks.read().unwrap().get(&track_id).map(Arc::clone);
            let Some(track) = track else {
                sr_log!(
                    trace,
                    "LOBBY",
                    "create rejected: unknown track_id={}",
                    track_id
                );
                send_join_error(&tx_out, JoinError::TrackNotFound);
                return;
            };
            let mut lobby = Lobby::new(
                nickname.clone(),
                Utc::now().format("%H:%M").to_string(),
                min_players,
                max_players,
                track,
            );

            if lobby
                .join(
                    nickname.clone(),
                    color,
                    horn_id,
                    cached_track_hash,
                    tx_out,
                    rx_stream,
                )
                .is_err()
            {
                return;
            }
            sr_log!(
                info,
                "LOBBY",
                "created id={} owner={} ({}-{} players)",
                lobby_id,
                nickname,
                min_players,
                max_players
            );
            lobbies.insert(lobby_id, lobby);
        }

        LobbyCommand::Join {
            lobby_id,
            nickname,
            color,
            horn_id,
            cached_track_hash,
            tx_out,
            rx_stream,
        } => {
            sr_log!(
                trace,
                "LOBBY",
                "join request: id={} nickname={}",
                lobby_id,
                nickname
            );
            if nickname.trim().is_empty() {
                sr_log!(trace, "LOBBY", "join rejected: empty nickname");
                send_join_error(&tx_out, JoinError::InvalidName);
                return;
            }
            let Some(lobby) = lobbies.get_mut(&lobby_id) else {
                sr_log!(trace, "LOBBY", "join rejected: id={} not found", lobby_id);
                send_join_error(&tx_out, JoinError::LobbyNotFound);
                return;
            };
            let _ = lobby.join(
                nickname,
                color,
                horn_id,
                cached_track_hash,
                tx_out,
                rx_stream,
            );
        }
    }
}

/// Game-wide hard cap on players per lobby.
const MAX_PLAYERS_LIMIT: u8 = 6;

fn validate_lobby_config(min_players: u8, max_players: u8) -> Option<JoinError> {
    if min_players == 0
        || max_players == 0
        || min_players > max_players
        || max_players > MAX_PLAYERS_LIMIT
    {
        Some(JoinError::InvalidLobbyConfig)
    } else {
        None
    }
}

fn build_lobby_list(lobbies: &HashMap<String, Lobby>) -> Vec<LobbyInfo> {
    lobbies
        .iter()
        .map(|(name, l)| LobbyInfo {
            name: name.clone(),
            owner: l.owner.clone(),
            start_time: l.start_time.clone(),
            player_count: l.player_count(),
            min_players: l.min_players,
            max_players: l.max_players,
            racing: l.is_racing(),
            track_id: l.track_id().to_string(),
            track_name: l.track_name().to_string(),
        })
        .collect()
}

fn build_track_list(tracks: &TrackMap) -> Vec<TrackInfo> {
    let mut list: Vec<TrackInfo> = tracks
        .values()
        .map(|t| TrackInfo {
            id: t.id.clone(),
            name: t.name.clone(),
        })
        .collect();
    list.sort_by(|a, b| a.id.cmp(&b.id));
    list
}

async fn handle_connection(stream: TcpStream, cmd_tx: mpsc::Sender<LobbyCommand>) {
    let peer = stream.peer_addr().ok();
    let Ok(mut ws) = accept_async(stream).await else {
        sr_log!(trace, "WS", "handshake failed peer={:?}", peer);
        return;
    };
    sr_log!(trace, "WS", "handshake ok peer={:?}", peer);

    loop {
        match ws.next().await {
            Some(Ok(Message::Text(text))) => {
                let msg =
                    serde_json::from_str::<ClientMessage>(&text).map_err(Error::ClientInvalidJson);
                match msg {
                    Err(_) => {
                        sr_log!(trace, "WS", "invalid json from peer={:?}", peer);
                        return;
                    }
                    Ok(ClientMessage::State { .. }) => {
                        sr_log!(
                            trace,
                            "WS",
                            "state message on pre-join socket peer={:?}",
                            peer
                        );
                        return;
                    }
                    Ok(ClientMessage::Request(request)) => {
                        match handle_request(request, ws, &cmd_tx).await {
                            Some(returned_ws) => ws = returned_ws,
                            None => return,
                        }
                    }
                }
            }
            Some(Ok(Message::Close(_))) => {
                sr_log!(trace, "WS", "client closed peer={:?}", peer);
                return;
            }
            Some(Ok(_)) => {
                return;
            }
            Some(Err(_)) => {
                sr_log!(trace, "WS", "stream error peer={:?}", peer);
                return;
            }
            None => {
                sr_log!(trace, "WS", "stream end peer={:?}", peer);
                return;
            }
        }
    }
}

async fn handle_request(
    request: RequestMessage,
    mut ws: WebSocketStream<TcpStream>,
    cmd_tx: &mpsc::Sender<LobbyCommand>,
) -> Option<WebSocketStream<TcpStream>> {
    match request {
        RequestMessage::FetchLobbyList => {
            sr_log!(trace, "WS", "request: FetchLobbyList");
            let (resp_tx, resp_rx) = oneshot::channel();
            if cmd_tx
                .send(LobbyCommand::FetchList { resp: resp_tx })
                .await
                .is_err()
            {
                return None;
            }
            let list = resp_rx.await.unwrap_or_default();
            let response = ServerMessage::Response(Response::LobbyList(list));
            let _ = ws
                .send(Message::Text(
                    serde_json::to_string(&response).unwrap().into(),
                ))
                .await;
            Some(ws)
        }

        RequestMessage::FetchTrackList => {
            sr_log!(trace, "WS", "request: FetchTrackList");
            let (resp_tx, resp_rx) = oneshot::channel();
            if cmd_tx
                .send(LobbyCommand::FetchTracks { resp: resp_tx })
                .await
                .is_err()
            {
                return None;
            }
            let list = resp_rx.await.unwrap_or_default();
            let response = ServerMessage::Response(Response::TrackList(list));
            let _ = ws
                .send(Message::Text(
                    serde_json::to_string(&response).unwrap().into(),
                ))
                .await;
            Some(ws)
        }

        RequestMessage::CreateLobby {
            lobby_id,
            track_id,
            nickname,
            min_players,
            max_players,
            color,
            horn_id,
            cached_track_hash,
        } => {
            sr_log!(
                trace,
                "WS",
                "request: CreateLobby id={} nick={} track={}",
                lobby_id,
                nickname,
                track_id
            );
            let (tx_stream, rx_stream) = ws.split();
            let tx_out = spawn_ws_writer(tx_stream);
            let _ = cmd_tx
                .send(LobbyCommand::Create {
                    lobby_id,
                    track_id,
                    nickname,
                    min_players,
                    max_players,
                    color,
                    horn_id,
                    cached_track_hash,
                    tx_out,
                    rx_stream,
                })
                .await;
            None
        }

        RequestMessage::JoinLobby {
            lobby_id,
            nickname,
            color,
            horn_id,
            cached_track_hash,
        } => {
            sr_log!(
                trace,
                "WS",
                "request: JoinLobby id={} nick={}",
                lobby_id,
                nickname
            );
            let (tx_stream, rx_stream) = ws.split();
            let tx_out = spawn_ws_writer(tx_stream);
            let _ = cmd_tx
                .send(LobbyCommand::Join {
                    lobby_id,
                    nickname,
                    color,
                    horn_id,
                    cached_track_hash,
                    tx_out,
                    rx_stream,
                })
                .await;
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_lobby_config_accepts_valid_ranges() {
        assert!(validate_lobby_config(2, 4).is_none());
        assert!(validate_lobby_config(1, 1).is_none());
        assert!(validate_lobby_config(1, 6).is_none());
    }

    #[test]
    fn validate_lobby_config_rejects_above_max_limit() {
        assert_eq!(
            validate_lobby_config(2, 7),
            Some(JoinError::InvalidLobbyConfig)
        );
        assert_eq!(
            validate_lobby_config(1, 255),
            Some(JoinError::InvalidLobbyConfig)
        );
    }

    #[test]
    fn validate_lobby_config_rejects_zero_min() {
        assert_eq!(
            validate_lobby_config(0, 4),
            Some(JoinError::InvalidLobbyConfig)
        );
    }

    #[test]
    fn validate_lobby_config_rejects_zero_max() {
        assert_eq!(
            validate_lobby_config(2, 0),
            Some(JoinError::InvalidLobbyConfig)
        );
    }

    #[test]
    fn validate_lobby_config_rejects_zero_zero() {
        assert_eq!(
            validate_lobby_config(0, 0),
            Some(JoinError::InvalidLobbyConfig)
        );
    }

    #[test]
    fn validate_lobby_config_rejects_min_greater_than_max() {
        assert_eq!(
            validate_lobby_config(5, 3),
            Some(JoinError::InvalidLobbyConfig)
        );
        assert_eq!(
            validate_lobby_config(255, 1),
            Some(JoinError::InvalidLobbyConfig)
        );
    }

    #[test]
    fn build_lobby_list_empty_when_no_lobbies() {
        let lobbies = HashMap::new();
        assert!(build_lobby_list(&lobbies).is_empty());
    }

    #[test]
    fn build_lobby_list_maps_each_lobby_to_info() {
        let track = Arc::new(
            crate::track::TrackDef::from_json(include_str!("../tracks/the_bedroom.json")).unwrap(),
        );
        let track_name = track.name.clone();
        let mut lobbies = HashMap::new();
        lobbies.insert(
            "foo".to_string(),
            Lobby::new("alice".into(), "12:00".into(), 2, 4, Arc::clone(&track)),
        );
        lobbies.insert(
            "bar".to_string(),
            Lobby::new("bob".into(), "13:30".into(), 1, 8, Arc::clone(&track)),
        );

        let mut list = build_lobby_list(&lobbies);
        list.sort_by(|a, b| a.name.cmp(&b.name));

        assert_eq!(list.len(), 2);

        assert_eq!(list[0].name, "bar");
        assert_eq!(list[0].owner, "bob");
        assert_eq!(list[0].start_time, "13:30");
        assert_eq!(list[0].player_count, 0);
        assert_eq!(list[0].min_players, 1);
        assert_eq!(list[0].max_players, 8);
        assert!(!list[0].racing);
        assert_eq!(list[0].track_name, track_name);

        assert_eq!(list[1].name, "foo");
        assert_eq!(list[1].owner, "alice");
        assert_eq!(list[1].player_count, 0);
        assert!(!list[1].racing);
        assert_eq!(list[1].track_name, track_name);
    }
}
