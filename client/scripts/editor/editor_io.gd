extends RefCounted

## Track JSON helpers for the map editor: the new-track template, (de)serialisation,
## legacy import and validation. Static functions so map_editor.gd stays lean.
## Shape must match server/src/track.rs (TrackDef: id, name, laps_to_win, gates[],
## primitives[]). A gate is { role, position[3], rotation_deg[3], half_width }.

class_name MapIO

const ROLES := ["start", "finish", "start_finish", "checkpoint"]

static func template() -> Dictionary:
	return {
		"id": "new_track",
		"name": "New Track",
		"laps_to_win": 3,
		"gates": [
			{ "role": "start_finish", "position": [0.0, 2.0, 0.0], "rotation_deg": [0.0, 0.0, 0.0], "half_width": 15.0 },
		],
		"primitives": [],
	}

## Pretty-printed, insertion-ordered so the file reads like server/tracks/*.json.
static func to_json(track_def: Dictionary) -> String:
	return JSON.stringify(track_def, "  ", false)

## Parsed Dictionary, or null on malformed / non-object JSON.
static func parse(text: String):
	var j := JSON.new()
	if j.parse(text) != OK:
		return null
	if not (j.data is Dictionary):
		return null
	return j.data

## Normalise a loaded track to the gate schema, converting the legacy
## spawn + lap shape into gates when needed.
static func import_track(data: Dictionary) -> Dictionary:
	if data.get("gates", null) is Array:
		if not (data.get("primitives", null) is Array):
			data["primitives"] = []
		if not data.has("laps_to_win"):
			data["laps_to_win"] = 3
		return data

	var gates: Array = []
	var lap = data.get("lap", {})
	var spawn = data.get("spawn", {})
	var laps := 3
	var spawn_y := 2.0
	var spawn_yaw := 0.0
	if spawn is Dictionary:
		var sp = spawn.get("position", [0.0, 2.0, 0.0])
		if sp is Array and sp.size() > 1:
			spawn_y = float(sp[1])
		spawn_yaw = float(spawn.get("y_rotation_deg", 0.0))
	if lap is Dictionary:
		laps = int(lap.get("laps_to_win", 3))
		if lap.has("finish_x"):
			gates.append({
				"role": "start_finish",
				"position": [float(lap["finish_x"]), spawn_y, 0.0],
				"rotation_deg": [0.0, spawn_yaw, 0.0],
				"half_width": float(lap.get("finish_half_width", 20.0)),
			})
		if lap.has("checkpoint_x"):
			gates.append({
				"role": "checkpoint",
				"position": [float(lap["checkpoint_x"]), spawn_y, 0.0],
				"rotation_deg": [0.0, 0.0, 0.0],
				"half_width": float(lap.get("checkpoint_half_width", 20.0)),
			})

	var prims = data.get("primitives", [])
	return {
		"id": data.get("id", "track"),
		"name": data.get("name", "Track"),
		"laps_to_win": laps,
		"gates": gates,
		"primitives": prims if prims is Array else [],
	}

## "" when savable, otherwise a human-readable reason (extensible later).
static func validate(td: Dictionary) -> String:
	if String(td.get("id", "")).strip_edges() == "":
		return "ID manquant."
	if int(td.get("laps_to_win", 0)) < 1:
		return "Le nombre de tours à gagner doit être ≥ 1."
	if not (td.get("gates", null) is Array):
		return "Liste de portails invalide."
	var has_start := false
	var has_finish := false
	for g in td["gates"]:
		var r := String(g.get("role", ""))
		if r == "start" or r == "start_finish":
			has_start = true
		if r == "finish" or r == "start_finish":
			has_finish = true
	if not has_start:
		return "Aucun portail de départ (Départ ou Départ/Arrivée)."
	if not has_finish:
		return "Aucun portail d'arrivée (Arrivée ou Départ/Arrivée)."
	return ""
