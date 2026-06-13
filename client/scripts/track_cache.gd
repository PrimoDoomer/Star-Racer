extends RefCounted

## Disk cache of downloaded tracks, keyed by track id.
##
## Each file stores the server-reported content hash alongside the track def, so
## the client can tell the server which version it already holds (via
## `cached_track_hash` in Create/JoinLobby) and the server then omits the full
## track from LobbyJoined when it's unchanged — no needless re-download. See
## server/src/lobby.rs (conditional `track`) and server/src/track.rs (hash).

class_name TrackCache

const DIR := "user://tracks_cache"

static func _path(track_id: String) -> String:
	return DIR.path_join(track_id + ".json")

static func _read(track_id: String) -> Variant:
	if track_id == "":
		return null
	var f := FileAccess.open(_path(track_id), FileAccess.READ)
	if f == null:
		return null
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	return data if typeof(data) == TYPE_DICTIONARY else null

## Content hash of the cached track for `track_id`, or "" if nothing is cached.
static func cached_hash(track_id: String) -> String:
	var data = _read(track_id)
	return String(data.get("hash", "")) if data != null else ""

## Cached track def for `track_id` if its stored hash matches `expected_hash`,
## else null.
static func load_track(track_id: String, expected_hash: String) -> Variant:
	var data = _read(track_id)
	if data == null or String(data.get("hash", "")) != expected_hash:
		return null
	var track = data.get("track", null)
	return track if typeof(track) == TYPE_DICTIONARY else null

## Persist a freshly downloaded track + its hash.
static func store(track_id: String, hash: String, track: Dictionary) -> void:
	if track_id == "":
		return
	if not DirAccess.dir_exists_absolute(DIR):
		DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(_path(track_id), FileAccess.WRITE)
	if f == null:
		printerr("TrackCache: cannot write ", _path(track_id))
		return
	f.store_string(JSON.stringify({"hash": hash, "track": track}))
	f.close()
