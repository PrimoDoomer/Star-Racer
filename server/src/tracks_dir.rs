use crate::track::TrackDef;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, RwLock};

pub type TrackMap = HashMap<String, Arc<TrackDef>>;

/// Hot-swappable track set shared by the core loop and the reload watcher: the
/// outer Arc<RwLock<_>> is the swap point, the inner Arc<TrackMap> is the current
/// immutable snapshot (cheap to clone, lobbies keep their own Arc<TrackDef>).
pub type SharedTracks = Arc<RwLock<Arc<TrackMap>>>;

pub fn load_all(dir: &Path) -> Result<TrackMap, String> {
    let entries = std::fs::read_dir(dir).map_err(|e| format!("read_dir {}: {e}", dir.display()))?;

    let mut tracks: TrackMap = HashMap::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("entry: {e}"))?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let raw =
            std::fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
        let def =
            TrackDef::from_json(&raw).map_err(|e| format!("parse {}: {e}", path.display()))?;
        if tracks.contains_key(&def.id) {
            return Err(format!(
                "duplicate track id '{}' in {}",
                def.id,
                path.display()
            ));
        }
        tracks.insert(def.id.clone(), Arc::new(def));
    }

    if tracks.is_empty() {
        return Err(format!("no *.json tracks found in {}", dir.display()));
    }

    Ok(tracks)
}
