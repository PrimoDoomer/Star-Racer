use futures_util::{SinkExt, StreamExt};
use pocket_racing_server::{
    protocol::{
        ClientMessage, ColorProto, JoinError, LobbyInfo, RequestMessage, Response, ServerMessage,
    },
    run::run_with_listener,
    track::TrackDef,
};
use std::{
    collections::HashMap,
    sync::{Arc, RwLock},
    time::Duration,
};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::{client_async, WebSocketStream};
use tungstenite::Message;

type WsClient = WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

async fn spawn_test_server() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let def = TrackDef::from_json(include_str!("../tracks/circuit_simple.json")).unwrap();
    let mut tracks: HashMap<String, Arc<TrackDef>> = HashMap::new();
    tracks.insert(def.id.clone(), Arc::new(def));
    let tracks = Arc::new(RwLock::new(Arc::new(tracks)));
    tokio::spawn(async move {
        let _ = run_with_listener(listener, tracks).await;
    });
    // Give the server a moment to spawn its core loop.
    tokio::time::sleep(Duration::from_millis(50)).await;
    port
}

async fn connect(port: u16) -> WsClient {
    let url = format!("ws://127.0.0.1:{}/", port);
    let stream = TcpStream::connect(format!("127.0.0.1:{}", port))
        .await
        .unwrap();
    let (ws, _) = client_async(url, tokio_tungstenite::MaybeTlsStream::Plain(stream))
        .await
        .unwrap();
    ws
}

async fn send_request(ws: &mut WsClient, req: RequestMessage) {
    let msg = ClientMessage::Request(req);
    let json = serde_json::to_string(&msg).unwrap();
    ws.send(Message::Text(json.into())).await.unwrap();
}

async fn next_server_message(ws: &mut WsClient) -> ServerMessage {
    loop {
        let msg = tokio::time::timeout(Duration::from_secs(5), ws.next())
            .await
            .expect("timed out waiting for server message")
            .expect("stream ended")
            .expect("ws error");
        if let Message::Text(t) = msg {
            return serde_json::from_str::<ServerMessage>(&t).expect("invalid server json");
        }
    }
}

async fn next_response(ws: &mut WsClient) -> Response {
    loop {
        match next_server_message(ws).await {
            ServerMessage::Response(r) => return r,
            _ => continue,
        }
    }
}

fn red() -> ColorProto {
    ColorProto {
        x: 1.0,
        y: 0.0,
        z: 0.0,
    }
}
fn green() -> ColorProto {
    ColorProto {
        x: 0.0,
        y: 1.0,
        z: 0.0,
    }
}

#[tokio::test]
async fn fetch_empty_lobby_list() {
    let port = spawn_test_server().await;
    let mut ws = connect(port).await;
    send_request(&mut ws, RequestMessage::FetchLobbyList).await;

    match next_response(&mut ws).await {
        Response::LobbyList(list) => assert!(list.is_empty()),
        _ => panic!("expected LobbyList"),
    }
}

#[tokio::test]
async fn create_lobby_then_appears_in_list() {
    let port = spawn_test_server().await;

    let mut creator = connect(port).await;
    send_request(
        &mut creator,
        RequestMessage::CreateLobby {
            lobby_id: "room1".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 2,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut creator).await {
        Response::LobbyJoined {
            error,
            min_players,
            max_players,
            ..
        } => {
            assert!(error.is_none());
            assert_eq!(min_players, 2);
            assert_eq!(max_players, 4);
        }
        _ => panic!("expected LobbyJoined"),
    }

    let mut watcher = connect(port).await;
    send_request(&mut watcher, RequestMessage::FetchLobbyList).await;
    match next_response(&mut watcher).await {
        Response::LobbyList(list) => {
            let info: &LobbyInfo = list
                .iter()
                .find(|l| l.name == "room1")
                .expect("lobby missing");
            assert_eq!(info.owner, "alice");
            assert_eq!(info.player_count, 1);
            assert_eq!(info.min_players, 2);
            assert_eq!(info.max_players, 4);
            assert!(!info.racing);
        }
        _ => panic!("expected LobbyList"),
    }
}

#[tokio::test]
async fn create_lobby_with_invalid_config_returns_error() {
    let port = spawn_test_server().await;
    let mut ws = connect(port).await;
    send_request(
        &mut ws,
        RequestMessage::CreateLobby {
            lobby_id: "bad".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 5,
            max_players: 2,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut ws).await {
        Response::LobbyJoined { error, .. } => {
            assert_eq!(error, Some(JoinError::InvalidLobbyConfig));
        }
        _ => panic!("expected LobbyJoined with error"),
    }
}

#[tokio::test]
async fn create_lobby_with_zero_min_players_returns_error() {
    let port = spawn_test_server().await;
    let mut ws = connect(port).await;
    send_request(
        &mut ws,
        RequestMessage::CreateLobby {
            lobby_id: "bad".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 0,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut ws).await {
        Response::LobbyJoined { error, .. } => {
            assert_eq!(error, Some(JoinError::InvalidLobbyConfig));
        }
        _ => panic!("expected LobbyJoined with error"),
    }
}

#[tokio::test]
async fn create_lobby_with_unknown_track_returns_error() {
    let port = spawn_test_server().await;
    let mut ws = connect(port).await;
    send_request(
        &mut ws,
        RequestMessage::CreateLobby {
            lobby_id: "room".into(),
            track_id: "does_not_exist".into(),
            nickname: "alice".into(),
            min_players: 2,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut ws).await {
        Response::LobbyJoined { error, .. } => {
            assert_eq!(error, Some(JoinError::TrackNotFound));
        }
        _ => panic!("expected LobbyJoined with error"),
    }
}

#[tokio::test]
async fn create_duplicate_lobby_id_returns_error() {
    let port = spawn_test_server().await;

    let mut a = connect(port).await;
    send_request(
        &mut a,
        RequestMessage::CreateLobby {
            lobby_id: "dup".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 2,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    let _ = next_response(&mut a).await;

    let mut b = connect(port).await;
    send_request(
        &mut b,
        RequestMessage::CreateLobby {
            lobby_id: "dup".into(),
            track_id: "circuit_simple".into(),
            nickname: "bob".into(),
            min_players: 2,
            max_players: 4,
            color: green(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut b).await {
        Response::LobbyJoined { error, .. } => {
            assert_eq!(error, Some(JoinError::LobbyAlreadyExists));
        }
        _ => panic!("expected LobbyJoined with error"),
    }
}

#[tokio::test]
async fn join_unknown_lobby_returns_not_found() {
    let port = spawn_test_server().await;
    let mut ws = connect(port).await;
    send_request(
        &mut ws,
        RequestMessage::JoinLobby {
            lobby_id: "ghost".into(),
            nickname: "alice".into(),
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut ws).await {
        Response::LobbyJoined { error, .. } => {
            assert_eq!(error, Some(JoinError::LobbyNotFound));
        }
        _ => panic!("expected LobbyJoined with error"),
    }
}

#[tokio::test]
async fn join_existing_lobby_succeeds_and_increments_count() {
    let port = spawn_test_server().await;

    let mut creator = connect(port).await;
    send_request(
        &mut creator,
        RequestMessage::CreateLobby {
            lobby_id: "room".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 2,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    let _ = next_response(&mut creator).await;

    let mut joiner = connect(port).await;
    send_request(
        &mut joiner,
        RequestMessage::JoinLobby {
            lobby_id: "room".into(),
            nickname: "bob".into(),
            color: green(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut joiner).await {
        Response::LobbyJoined {
            error,
            track_id,
            race_ongoing,
            track,
            ..
        } => {
            assert!(error.is_none());
            assert_eq!(track_id, "circuit_simple");
            assert!(!race_ongoing);
            assert!(
                track.is_some(),
                "track def should be sent on successful join"
            );
        }
        _ => panic!("expected LobbyJoined"),
    }

    // Wait briefly for player_count to be reflected, then list lobbies.
    tokio::time::sleep(Duration::from_millis(50)).await;
    let mut watcher = connect(port).await;
    send_request(&mut watcher, RequestMessage::FetchLobbyList).await;
    match next_response(&mut watcher).await {
        Response::LobbyList(list) => {
            let info = list.iter().find(|l| l.name == "room").unwrap();
            assert_eq!(info.player_count, 2);
            assert!(!info.track_name.is_empty());
        }
        _ => panic!("expected LobbyList"),
    }
}

#[tokio::test]
async fn join_with_duplicate_nickname_returns_error() {
    let port = spawn_test_server().await;

    let mut creator = connect(port).await;
    send_request(
        &mut creator,
        RequestMessage::CreateLobby {
            lobby_id: "room".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 2,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    let _ = next_response(&mut creator).await;

    let mut dup = connect(port).await;
    send_request(
        &mut dup,
        RequestMessage::JoinLobby {
            lobby_id: "room".into(),
            nickname: "alice".into(),
            color: green(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut dup).await {
        Response::LobbyJoined { error, .. } => {
            assert_eq!(error, Some(JoinError::NicknameAlreadyUsed));
        }
        _ => panic!("expected LobbyJoined with error"),
    }
}

#[tokio::test]
async fn join_with_empty_nickname_returns_error() {
    let port = spawn_test_server().await;

    let mut creator = connect(port).await;
    send_request(
        &mut creator,
        RequestMessage::CreateLobby {
            lobby_id: "room".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 2,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    let _ = next_response(&mut creator).await;

    let mut empty = connect(port).await;
    send_request(
        &mut empty,
        RequestMessage::JoinLobby {
            lobby_id: "room".into(),
            nickname: "   ".into(), // whitespace-only is still empty
            color: green(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut empty).await {
        Response::LobbyJoined { error, .. } => {
            assert_eq!(error, Some(JoinError::InvalidName));
        }
        _ => panic!("expected LobbyJoined with error"),
    }
}

#[tokio::test]
async fn create_with_empty_nickname_returns_error() {
    let port = spawn_test_server().await;
    let mut ws = connect(port).await;
    send_request(
        &mut ws,
        RequestMessage::CreateLobby {
            lobby_id: "room".into(),
            track_id: "circuit_simple".into(),
            nickname: "".into(),
            min_players: 2,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut ws).await {
        Response::LobbyJoined { error, .. } => {
            assert_eq!(error, Some(JoinError::InvalidName));
        }
        _ => panic!("expected LobbyJoined with error"),
    }
}

#[tokio::test]
async fn join_when_full_returns_lobby_full() {
    let port = spawn_test_server().await;

    let mut creator = connect(port).await;
    send_request(
        &mut creator,
        RequestMessage::CreateLobby {
            lobby_id: "tiny".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 1,
            max_players: 1,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    let _ = next_response(&mut creator).await;

    let mut full = connect(port).await;
    send_request(
        &mut full,
        RequestMessage::JoinLobby {
            lobby_id: "tiny".into(),
            nickname: "bob".into(),
            color: green(),
            cached_track_hash: None,
        },
    )
    .await;
    match next_response(&mut full).await {
        Response::LobbyJoined { error, .. } => {
            assert_eq!(error, Some(JoinError::LobbyFull));
        }
        _ => panic!("expected LobbyJoined with error"),
    }
}

#[tokio::test]
async fn invalid_json_closes_connection() {
    let port = spawn_test_server().await;
    let mut ws = connect(port).await;
    ws.send(Message::Text("not json".into())).await.unwrap();
    // Server should close the connection.
    let result = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            match ws.next().await {
                Some(Ok(Message::Close(_))) | None => return,
                Some(Err(_)) => return,
                Some(Ok(_)) => continue,
            }
        }
    })
    .await;
    assert!(
        result.is_ok(),
        "server did not close connection on invalid json"
    );
}

#[tokio::test]
async fn state_message_on_pre_join_socket_closes_connection() {
    let port = spawn_test_server().await;
    let mut ws = connect(port).await;
    let msg = ClientMessage::State {
        throttle: true,
        steer_left: 0.0,
        steer_right: 0.0,
        drift: false,
        respawn: false,
        turbo: false,
    };
    ws.send(Message::Text(serde_json::to_string(&msg).unwrap().into()))
        .await
        .unwrap();

    let result = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            match ws.next().await {
                Some(Ok(Message::Close(_))) | None => return,
                Some(Err(_)) => return,
                Some(Ok(_)) => continue,
            }
        }
    })
    .await;
    assert!(
        result.is_ok(),
        "server did not close connection on premature State"
    );
}

#[tokio::test]
async fn lobby_disappears_when_sole_player_disconnects() {
    let port = spawn_test_server().await;

    let mut creator = connect(port).await;
    send_request(
        &mut creator,
        RequestMessage::CreateLobby {
            lobby_id: "ephemeral".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 2,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    let _ = next_response(&mut creator).await;

    // Confirm the lobby exists.
    {
        let mut watcher = connect(port).await;
        send_request(&mut watcher, RequestMessage::FetchLobbyList).await;
        if let Response::LobbyList(list) = next_response(&mut watcher).await {
            assert!(list.iter().any(|l| l.name == "ephemeral"));
        }
    }

    // Drop the creator; lobby should be evicted on next tick once empty.
    drop(creator);

    // Wait long enough for the server to detect the close and run a few ticks.
    tokio::time::sleep(Duration::from_millis(300)).await;

    let mut watcher = connect(port).await;
    send_request(&mut watcher, RequestMessage::FetchLobbyList).await;
    if let Response::LobbyList(list) = next_response(&mut watcher).await {
        assert!(
            !list.iter().any(|l| l.name == "ephemeral"),
            "lobby should be removed after sole player disconnects"
        );
    }
}

#[tokio::test]
async fn cached_track_hash_controls_whether_track_is_resent() {
    let port = spawn_test_server().await;

    // min == max == 4 with only 3 joiners keeps the lobby in intermission, so no
    // countdown/race events race with the join responses we assert on.
    let mut creator = connect(port).await;
    send_request(
        &mut creator,
        RequestMessage::CreateLobby {
            lobby_id: "cache".into(),
            track_id: "circuit_simple".into(),
            nickname: "alice".into(),
            min_players: 4,
            max_players: 4,
            color: red(),
            cached_track_hash: None,
        },
    )
    .await;
    // No cache → full track plus its hash.
    let hash = match next_response(&mut creator).await {
        Response::LobbyJoined {
            track, track_hash, ..
        } => {
            assert!(
                track.is_some(),
                "track must be sent when client has no cache"
            );
            assert!(!track_hash.is_empty(), "a content hash must be advertised");
            track_hash
        }
        _ => panic!("expected LobbyJoined"),
    };

    // Up-to-date cache → track omitted, same hash echoed back.
    let mut up_to_date = connect(port).await;
    send_request(
        &mut up_to_date,
        RequestMessage::JoinLobby {
            lobby_id: "cache".into(),
            nickname: "bob".into(),
            color: green(),
            cached_track_hash: Some(hash.clone()),
        },
    )
    .await;
    match next_response(&mut up_to_date).await {
        Response::LobbyJoined {
            track, track_hash, ..
        } => {
            assert!(
                track.is_none(),
                "track must be omitted when cache is current"
            );
            assert_eq!(track_hash, hash);
        }
        _ => panic!("expected LobbyJoined"),
    }

    // Stale/wrong hash → full track re-sent.
    let mut stale = connect(port).await;
    send_request(
        &mut stale,
        RequestMessage::JoinLobby {
            lobby_id: "cache".into(),
            nickname: "carol".into(),
            color: red(),
            cached_track_hash: Some("0000000000000000".into()),
        },
    )
    .await;
    match next_response(&mut stale).await {
        Response::LobbyJoined { track, .. } => {
            assert!(
                track.is_some(),
                "track must be re-sent when cached hash differs"
            );
        }
        _ => panic!("expected LobbyJoined"),
    }
}
