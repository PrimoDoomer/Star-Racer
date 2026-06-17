use crate::track::TrackDef;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, Debug)]
pub struct Vec3Proto {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

#[derive(Serialize, Deserialize, Clone, Copy)]
pub struct QuatProto {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub w: f64,
}

pub type ColorProto = Vec3Proto;

#[derive(Serialize, Deserialize, Clone)]
pub struct PlayerState {
    pub nickname: String,
    pub racing: bool,
    pub laps: u8,
    pub position: Vec3Proto,
    pub rotation: QuatProto,
    pub color: ColorProto,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct SpawnInfo {
    pub y_rotation: f64,
    pub position: Vec3Proto,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub enum JoinError {
    NicknameAlreadyUsed,
    LobbyFull,
    LobbyAlreadyExists,
    LobbyNotFound,
    InvalidLobbyConfig,
    InvalidName,
    TrackNotFound,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct TrackInfo {
    pub id: String,
    pub name: String,
}

#[derive(Serialize, Deserialize)]
pub enum RequestMessage {
    FetchLobbyList,
    FetchTrackList,
    CreateLobby {
        lobby_id: String,
        track_id: String,
        nickname: String,
        min_players: u8,
        max_players: u8,
        color: ColorProto,
        /// Hash of the track the client already has cached, if any. The server
        /// omits the full track from `LobbyJoined` when it matches the current
        /// track, so an unchanged track is never re-sent.
        #[serde(default)]
        cached_track_hash: Option<String>,
    },
    JoinLobby {
        lobby_id: String,
        nickname: String,
        color: ColorProto,
        #[serde(default)]
        cached_track_hash: Option<String>,
    },
}

#[derive(Serialize, Deserialize)]
pub enum ClientMessage {
    Request(RequestMessage),
    State {
        throttle: bool,
        steer_left: f64,
        steer_right: f64,
        star_drift: bool,
    },
}

#[derive(Serialize, Deserialize)]
pub struct LobbyInfo {
    pub name: String,
    pub owner: String,
    pub start_time: String,
    pub player_count: u8,
    pub min_players: u8,
    pub max_players: u8,
    pub racing: bool,
    pub track_id: String,
    pub track_name: String,
}

#[derive(Serialize, Deserialize)]
pub enum Response {
    LobbyList(Vec<LobbyInfo>),
    TrackList(Vec<TrackInfo>),

    LobbyJoined {
        track_id: String,
        /// Content hash of the lobby's current track, so the client can tell
        /// whether its cached copy is still valid.
        #[serde(default)]
        track_hash: String,
        race_ongoing: bool,
        min_players: u8,
        max_players: u8,
        error: Option<JoinError>,
        /// Full track def, sent only when the client's cached hash didn't match
        /// (or it had none). Omitted when the client is already up to date. Boxed
        /// to keep this (otherwise large) enum variant small; serialises the same.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        track: Option<Box<TrackDef>>,
    },
}

#[derive(Serialize, Deserialize, Clone)]
pub enum LobbyState {
    WaitingForPlayers(u8),
    Players(Vec<PlayerState>),
}

#[derive(Serialize, Deserialize)]
pub enum LobbyEvent {
    /// Pre-race countdown shown in the lobby page. Distinct from the on-track
    /// start "Countdown"; restarts if the lobby stops being ready.
    LobbyCountdown {
        time: f64,
    },
    Countdown {
        time: f64,
    },
    RaceAboutToStart(SpawnInfo),
    RaceStarted(()),
    RaceFinished {
        winner: String,
        rankings: Vec<String>,
    },
}

#[derive(Serialize, Deserialize)]
pub enum ServerMessage {
    Event(LobbyEvent),
    State(LobbyState),
    Response(Response),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_error_roundtrip_all_variants() {
        let errors = [
            JoinError::NicknameAlreadyUsed,
            JoinError::LobbyFull,
            JoinError::LobbyAlreadyExists,
            JoinError::LobbyNotFound,
            JoinError::InvalidLobbyConfig,
            JoinError::TrackNotFound,
        ];
        for err in errors {
            let json = serde_json::to_string(&err).unwrap();
            let back: JoinError = serde_json::from_str(&json).unwrap();
            assert_eq!(err, back);
        }
    }

    #[test]
    fn client_state_message_deserializes() {
        let json =
            r#"{"State":{"throttle":true,"steer_left":0.5,"steer_right":0.25,"star_drift":false}}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        match msg {
            ClientMessage::State {
                throttle,
                steer_left,
                steer_right,
                star_drift,
            } => {
                assert!(throttle);
                assert_eq!(steer_left, 0.5);
                assert_eq!(steer_right, 0.25);
                assert!(!star_drift);
            }
            _ => panic!("expected State variant"),
        }
    }

    #[test]
    fn fetch_lobby_list_request_deserializes() {
        let json = r#"{"Request":"FetchLobbyList"}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        assert!(matches!(
            msg,
            ClientMessage::Request(RequestMessage::FetchLobbyList)
        ));
    }

    #[test]
    fn create_lobby_request_deserializes() {
        let json = r#"{"Request":{"CreateLobby":{"lobby_id":"abc","track_id":"circuit_one","nickname":"alice","min_players":2,"max_players":4,"color":{"x":1.0,"y":0.0,"z":0.0}}}}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        match msg {
            ClientMessage::Request(RequestMessage::CreateLobby {
                lobby_id,
                track_id,
                nickname,
                min_players,
                max_players,
                color,
                ..
            }) => {
                assert_eq!(lobby_id, "abc");
                assert_eq!(track_id, "circuit_one");
                assert_eq!(nickname, "alice");
                assert_eq!(min_players, 2);
                assert_eq!(max_players, 4);
                assert_eq!(color.x, 1.0);
                assert_eq!(color.y, 0.0);
                assert_eq!(color.z, 0.0);
            }
            _ => panic!("expected CreateLobby variant"),
        }
    }

    #[test]
    fn fetch_track_list_request_deserializes() {
        let json = r#"{"Request":"FetchTrackList"}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        assert!(matches!(
            msg,
            ClientMessage::Request(RequestMessage::FetchTrackList)
        ));
    }

    #[test]
    fn track_list_response_serializes() {
        let msg = ServerMessage::Response(Response::TrackList(vec![
            TrackInfo {
                id: "circuit_one".into(),
                name: "Circuit One".into(),
            },
            TrackInfo {
                id: "circuit_two".into(),
                name: "Circuit Two".into(),
            },
        ]));
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("TrackList"));
        assert!(json.contains("circuit_one"));
        assert!(json.contains("Circuit Two"));
    }

    #[test]
    fn join_lobby_request_deserializes() {
        let json = r#"{"Request":{"JoinLobby":{"lobby_id":"id","nickname":"bob","color":{"x":0.0,"y":1.0,"z":0.0}}}}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        assert!(matches!(
            msg,
            ClientMessage::Request(RequestMessage::JoinLobby { .. })
        ));
    }

    #[test]
    fn invalid_client_message_fails_deserialization() {
        let json = r#"{"Unknown":{}}"#;
        assert!(serde_json::from_str::<ClientMessage>(json).is_err());
    }

    #[test]
    fn server_response_lobby_list_serializes() {
        let msg = ServerMessage::Response(Response::LobbyList(vec![LobbyInfo {
            name: "foo".into(),
            owner: "alice".into(),
            start_time: "12:00".into(),
            player_count: 1,
            min_players: 2,
            max_players: 4,
            racing: false,
            track_id: "circuit_one".into(),
            track_name: "Circuit One".into(),
        }]));
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("LobbyList"));
        assert!(json.contains("foo"));
        assert!(json.contains("alice"));
        assert!(json.contains("\"track_name\":\"Circuit One\""));
    }

    #[test]
    fn server_event_race_started_serializes() {
        let msg = ServerMessage::Event(LobbyEvent::RaceStarted(()));
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("RaceStarted"));
    }

    #[test]
    fn lobby_state_waiting_for_players_serializes() {
        let msg = ServerMessage::State(LobbyState::WaitingForPlayers(3));
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("WaitingForPlayers"));
        assert!(json.contains('3'));
    }

    #[test]
    fn race_finished_event_carries_winner_and_rankings() {
        let msg = ServerMessage::Event(LobbyEvent::RaceFinished {
            winner: "alice".into(),
            rankings: vec!["alice".into(), "bob".into()],
        });
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("alice"));
        assert!(json.contains("bob"));
    }

    #[test]
    fn lobby_joined_response_serializes_with_race_ongoing() {
        let msg = ServerMessage::Response(Response::LobbyJoined {
            track_id: "circuit_one".into(),
            track_hash: "deadbeef".into(),
            race_ongoing: true,
            min_players: 2,
            max_players: 4,
            error: None,
            track: None,
        });
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("LobbyJoined"));
        assert!(json.contains("\"race_ongoing\":true"));
        assert!(json.contains("circuit_one"));
    }
}
