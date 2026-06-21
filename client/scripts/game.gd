extends Node

class_name Game

const EnvironmentBuilder = preload("res://scripts/environment_builder.gd")

# Every Kenney "Car Kit" vehicle, offered in the pilot picker. The first three
# keep their legacy ids (car1/car2/car3) so saved car choices still resolve; the
# rest are keyed by their model name. Every model in the kit shares the same wheel
# node names, so a single wheel mapping covers them all. `name` is a locale key
# (see locale.gd "car_*"), translated when shown.
const CAR_MODELS = [
	{"id": "car1", "name": "car_race", "path": "res://scenes/cars/car1.tscn"},
	{"id": "car2", "name": "car_race_future", "path": "res://scenes/cars/car2.tscn"},
	{"id": "car3", "name": "car_sedan_sports", "path": "res://scenes/cars/car3.tscn"},
	{"id": "hatchback-sports", "name": "car_hatchback_sports", "path": "res://scenes/cars/hatchback-sports.tscn"},
	{"id": "sedan", "name": "car_sedan", "path": "res://scenes/cars/sedan.tscn"},
	{"id": "suv", "name": "car_suv", "path": "res://scenes/cars/suv.tscn"},
	{"id": "suv-luxury", "name": "car_suv_luxury", "path": "res://scenes/cars/suv-luxury.tscn"},
	{"id": "taxi", "name": "car_taxi", "path": "res://scenes/cars/taxi.tscn"},
	{"id": "police", "name": "car_police", "path": "res://scenes/cars/police.tscn"},
	{"id": "van", "name": "car_van", "path": "res://scenes/cars/van.tscn"},
	{"id": "delivery", "name": "car_delivery", "path": "res://scenes/cars/delivery.tscn"},
	{"id": "delivery-flat", "name": "car_delivery_flat", "path": "res://scenes/cars/delivery-flat.tscn"},
	{"id": "ambulance", "name": "car_ambulance", "path": "res://scenes/cars/ambulance.tscn"},
	{"id": "firetruck", "name": "car_firetruck", "path": "res://scenes/cars/firetruck.tscn"},
	{"id": "garbage-truck", "name": "car_garbage_truck", "path": "res://scenes/cars/garbage-truck.tscn"},
	{"id": "truck", "name": "car_truck", "path": "res://scenes/cars/truck.tscn"},
	{"id": "truck-flat", "name": "car_truck_flat", "path": "res://scenes/cars/truck-flat.tscn"},
	{"id": "tractor", "name": "car_tractor", "path": "res://scenes/cars/tractor.tscn"},
	{"id": "tractor-police", "name": "car_tractor_police", "path": "res://scenes/cars/tractor-police.tscn"},
	{"id": "tractor-shovel", "name": "car_tractor_shovel", "path": "res://scenes/cars/tractor-shovel.tscn"},
	{"id": "kart-oobi", "name": "car_kart_oobi", "path": "res://scenes/cars/kart-oobi.tscn"},
	{"id": "kart-oodi", "name": "car_kart_oodi", "path": "res://scenes/cars/kart-oodi.tscn"},
	{"id": "kart-ooli", "name": "car_kart_ooli", "path": "res://scenes/cars/kart-ooli.tscn"},
	{"id": "kart-oopi", "name": "car_kart_oopi", "path": "res://scenes/cars/kart-oopi.tscn"},
	{"id": "kart-oozi", "name": "car_kart_oozi", "path": "res://scenes/cars/kart-oozi.tscn"},
]

# Wheel node names shared by every Kenney car-kit model (used for steer animation).
const CAR_WHEEL_FL := "wheel-front-left"
const CAR_WHEEL_FR := "wheel-front-right"

# Selectable horns (CC0 SFX from BigSoundBank). `name` is a locale key (see
# locale.gd "horn_*"). The player picks one in the Pilot tab; it plays on the Horn
# input during a race. Add a horn by dropping an .mp3 in assets/audio/horns and
# appending an entry here.
const HORNS = [
	{"id": "horn_classic", "name": "horn_classic", "path": "res://assets/audio/horns/horn_classic.mp3"},
	{"id": "horn_modern", "name": "horn_modern", "path": "res://assets/audio/horns/horn_modern.mp3"},
	{"id": "horn_truck", "name": "horn_truck", "path": "res://assets/audio/horns/horn_truck.mp3"},
	{"id": "horn_oogah", "name": "horn_oogah", "path": "res://assets/audio/horns/horn_oogah.mp3"},
	{"id": "horn_vintage", "name": "horn_vintage", "path": "res://assets/audio/horns/horn_vintage.mp3"},
]

const DEFAULT_HORN := "horn_classic"

static func get_horn(horn_id: String) -> Dictionary:
	for h in HORNS:
		if h["id"] == horn_id:
			return h
	return get_horn(DEFAULT_HORN)

const DEFAULT_CAR_MODEL := "car1"

static func get_car_model(model_id: String) -> Dictionary:
	for m in CAR_MODELS:
		if m["id"] == model_id:
			var def: Dictionary = m.duplicate()
			def["transform"] = Transform3D.IDENTITY
			return def
	return get_car_model(DEFAULT_CAR_MODEL)

# True on a phone/tablet web client, the same mobile-vs-desktop split a web page
# makes: it sniffs the browser user agent. Drives the on-screen controls and the
# keyboard-bindings hint. Always false on a desktop browser or a native build.
static func is_mobile() -> bool:
	if not OS.has_feature("web"):
		return false
	return bool(JavaScriptBridge.eval(
		"/Mobi|Android|iPhone|iPad|iPod/i.test(navigator.userAgent)", true))

# Translucent material for the debug ghost car.
static func make_ghost_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.4)
	return mat

# --- Procedural car audio --------------------------------------------------
# Streams are synthesised once and shared by every car (player + opponents),
# the same approach the start lights use for their beeps. Callers modulate
# pitch_scale / volume_db at runtime to follow speed and drift.
const AUDIO_RATE := 22050
const ENGINE_IDLE_PITCH := 0.85   # engine pitch_scale at a standstill (kept low)
const ENGINE_MAX_PITCH  := 1.6    # capped so the engine never whines at speed
const ENGINE_SPEED_REF  := 42.0   # speed (m/s) mapped to peak pitch

# One engine voice per car model. Deliberately round and low: a low fundamental
# with only a couple of gentle harmonics — no high partials that would buzz or
# whine. `period` is in samples (freq = AUDIO_RATE / period), so the buffer is
# an exact number of cycles and loops seamlessly.
const ENGINE_PROFILES := {
	"car1": {"period": 368, "weights": [1.0, 0.34, 0.12, 0.04]},  # ~60 Hz, a little growl
	"car2": {"period": 440, "weights": [1.0, 0.2, 0.05]},          # ~50 Hz, smoother hum
	"car3": {"period": 400, "weights": [1.0, 0.28, 0.08]},         # ~55 Hz, mid
}

static var _engine_streams: Dictionary = {}
static var _drift_stream: AudioStreamWAV = null

static func make_engine_stream(model_id: String = DEFAULT_CAR_MODEL) -> AudioStreamWAV:
	if _engine_streams.has(model_id):
		return _engine_streams[model_id]
	var profile: Dictionary = ENGINE_PROFILES.get(model_id, ENGINE_PROFILES[DEFAULT_CAR_MODEL])
	var period: int = profile["period"]
	var weights: Array = profile["weights"]
	var freq := float(AUDIO_RATE) / float(period)
	var cycles := int(round(0.8 * float(AUDIO_RATE) / float(period)))
	var sample_count := period * cycles
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	for i in sample_count:
		var ph := TAU * freq * (float(i) / float(AUDIO_RATE))
		var s := 0.0
		for h in weights.size():
			s += sin(ph * float(h + 1)) * float(weights[h])
		# Slow, gentle tremolo (2 cycles per loop → periodic) for a touch of life.
		s *= 0.92 + 0.08 * sin(TAU * 2.0 * float(i) / float(sample_count))
		s *= 0.16
		var sample := int(clampf(s, -1.0, 1.0) * 32767.0)
		data[i * 2]     = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var wav := _wav_from_data(data, sample_count, true)
	_engine_streams[model_id] = wav
	return wav

# Low tyre scrub for drifting: heavily low-passed noise (a deep rumble) under a
# low two-tone growl and a slow amplitude wobble — deliberately grave, not a high
# squeal. Tonal parts are integer-periodic over the buffer; the noise tail is
# cross-faded into the head to keep the loop click-free.
static func make_drift_stream() -> AudioStreamWAV:
	if _drift_stream != null:
		return _drift_stream
	var sample_count := AUDIO_RATE  # 1.0 s
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var raw := PackedFloat32Array()
	raw.resize(sample_count)
	var lp := 0.0
	for i in sample_count:
		var t := float(i) / float(AUDIO_RATE)
		var n := rng.randf() * 2.0 - 1.0
		lp += 0.08 * (n - lp)  # low cutoff → deep rumble instead of hiss
		var tone := sin(TAU * 80.0 * t) * 0.5 + sin(TAU * 120.0 * t) * 0.25
		var wob := 0.78 + 0.22 * sin(TAU * 9.0 * t)
		raw[i] = (lp * 2.0 + tone * 0.45) * wob
	var fade := 512
	for j in fade:
		var a := float(j) / float(fade)
		var idx := sample_count - fade + j
		raw[idx] = raw[idx] * (1.0 - a) + raw[j] * a
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	for i in sample_count:
		var sample := int(clampf(raw[i] * 0.5, -1.0, 1.0) * 32767.0)
		data[i * 2]     = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	_drift_stream = _wav_from_data(data, sample_count, true)
	return _drift_stream

static var _boost_stream: AudioStreamWAV = null

# Short upward "ptew" chirp played when a drift boost fires: a quick pitch sweep
# (380 → 1080 Hz) with a snappy attack and exponential decay. One-shot, not looped.
static func make_boost_stream() -> AudioStreamWAV:
	if _boost_stream != null:
		return _boost_stream
	var dur := 0.18
	var sample_count := int(float(AUDIO_RATE) * dur)
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	var phase := 0.0
	for i in sample_count:
		var u := float(i) / float(sample_count)  # 0..1 through the blip
		var freq := lerpf(380.0, 1080.0, pow(u, 0.6))
		phase += TAU * freq / float(AUDIO_RATE)
		var s := sin(phase) * 0.7 + sin(phase * 2.0) * 0.2
		var env := minf(u / 0.06, 1.0) * pow(1.0 - u, 1.6)  # quick attack, fast decay
		s *= env * 0.5
		var sample := int(clampf(s, -1.0, 1.0) * 32767.0)
		data[i * 2]     = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	_boost_stream = _wav_from_data(data, sample_count, false)
	return _boost_stream

static func _wav_from_data(data: PackedByteArray, sample_count: int, loop: bool) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = AUDIO_RATE
	wav.stereo = false
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = sample_count
	wav.data = data
	return wav

enum Mode {
	WELCOME_PAGE,
	FETCH_LOBBIES,
	CREATING_LOBBY,
	JOINING_LOBBY,
	LOBBY_INTERMISSION,
	IN_RACE,
	SPECTATOR,
}

class NameGenerator:
	# Pilot call-signs: a cosmic codename joined by an underscore to either a
	# second codename or a two-digit squadron number — e.g. "Vega_Talon",
	# "Apex_07". Stays within the [A-Za-z][A-Za-z0-9_]* / 3-20 char name rules.
	const CALLSIGNS := [
		"Vega", "Orion", "Apex", "Nova", "Comet", "Falcon", "Vortex", "Phoenix",
		"Talon", "Quasar", "Pulsar", "Striker", "Zenith", "Maverick", "Rogue",
		"Helios", "Solaris", "Aurora", "Drift", "Blitz", "Cobra", "Razor",
	]

	static func nickname() -> String:
		var rng = RandomNumberGenerator.new()
		rng.randomize()
		var head: String = CALLSIGNS[rng.randi_range(0, CALLSIGNS.size() - 1)]
		if rng.randf() < 0.5:
			# Codename + squadron number, e.g. "Vortex_07".
			return "%s_%02d" % [head, rng.randi_range(1, 99)]
		# Two distinct codenames, e.g. "Apex_Talon".
		var tail: String = head
		while tail == head:
			tail = CALLSIGNS[rng.randi_range(0, CALLSIGNS.size() - 1)]
		return "%s_%s" % [head, tail]

	# Race events, Grand-Prix style: a venue joined to an event type by an
	# underscore — e.g. "Helios_GP", "Andromeda_Cup".
	const VENUES := [
		"Helios", "Titan", "Orbit", "Nebula", "Andromeda", "Meridian", "Solaris",
		"Zephyr", "Quasar", "Halley", "Vesta", "Kepler", "Aurora", "Polaris",
	]
	const EVENTS := ["GP", "Cup", "Rally", "Sprint", "Open", "Series", "Trophy", "Circuit"]

	static func lobby_name() -> String:
		var rng = RandomNumberGenerator.new()
		rng.randomize()
		return "%s_%s" % [
			VENUES[rng.randi_range(0, VENUES.size() - 1)],
			EVENTS[rng.randi_range(0, EVENTS.size() - 1)],
		]

class Settings:
	const FILE_PATH = "user://settings.cfg"

	static func save(ui: UI) -> void:
		var config = ConfigFile.new()
		var game = ui.get_node("%Game") as Game
		if game.check_min_players(ui.get_min_players()):
			config.set_value("Settings", "min_players", ui.get_min_players())
		if game.check_max_players(ui.get_max_players()):
			config.set_value("Settings", "max_players", ui.get_max_players())
		if game.check_lobby_name(ui.get_lobby_name()):
			config.set_value("Settings", "lobby_name", ui.get_lobby_name())
		if game.check_nickname(ui.get_nickname()):
			config.set_value("Settings", "nickname", ui.get_nickname())
		config.save(FILE_PATH)

	static func load(ui: UI, defaults: Dictionary) -> void:
		var config = ConfigFile.new()
		if config.load(FILE_PATH) != OK:
			if config.save(FILE_PATH) != OK:
				printerr("Could not create settings file")
				return
		ui.set_min_players(int(config.get_value("Settings", "min_players", defaults.min_players)))
		ui.set_max_players(int(config.get_value("Settings", "max_players", defaults.max_players)))
		ui.set_lobby_name(config.get_value("Settings", "lobby_name", defaults.lobby_name))
		ui.set_nickname(config.get_value("Settings", "nickname", defaults.nickname))

class MessageParser:

	static func parse_join_response(msg: Dictionary) -> Dictionary:
		var joined = msg["Response"]["LobbyJoined"]
		if joined.has("error") and joined["error"] != null:
			var err = joined["error"]
			var err_str = String(TranslationServer.translate("err_unknown")) % str(err)
			match err:
				"NicknameAlreadyUsed": err_str = TranslationServer.translate("err_nickname_used")
				"LobbyFull":           err_str = TranslationServer.translate("err_lobby_full")
				"LobbyAlreadyExists":  err_str = TranslationServer.translate("err_lobby_exists")
				"LobbyNotFound":       err_str = TranslationServer.translate("err_lobby_not_found")
				"InvalidLobbyConfig":  err_str = TranslationServer.translate("err_invalid_config")
				"InvalidName":         err_str = TranslationServer.translate("err_invalid_name")
				"TrackNotFound":       err_str = TranslationServer.translate("err_track_not_found")
			return {"ok": false, "error_str": err_str}
		return {
			"ok": true,
			"track_id": String(joined.get("track_id", "")),
			"race_ongoing": bool(joined.get("race_ongoing", false)),
			"min_players": int(joined.get("min_players", 2)),
			"max_players": int(joined.get("max_players", 4)),
			"track_hash": String(joined.get("track_hash", "")),
			"track": joined.get("track", null),
		}

	static func parse_player(raw: Dictionary) -> Dictionary:
		var pos = raw["position"]
		var rot = raw["rotation"]
		var col = raw["color"]
		return {
			"nickname": raw["nickname"],
			"racing": raw["racing"],
			"laps": int(raw.get("laps", 0)),
			"rank": int(raw.get("rank", 0)),
			"position": Vector3(pos["x"], pos["y"], pos["z"]),
			"rotation": Quaternion(rot["x"], rot["y"], rot["z"], rot["w"]),
			"color": Color(col["x"], col["y"], col["z"]),
		}

	static func parse_spawn_info(raw: Dictionary) -> Dictionary:
		var pos = raw["position"]
		return {
			"y_rotation": float(raw["y_rotation"]),
			"position": Vector3(pos["x"], pos["y"], pos["z"]),
		}

	static func color_to_proto(color: Color) -> Dictionary:
		return {"x": color.r, "y": color.g, "z": color.b}

class GhostManager:
	var _node: Node3D = null
	var _target_pos: Vector3 = Vector3.ZERO
	var _target_rot: Quaternion = Quaternion.IDENTITY
	var _velocity: Vector3 = Vector3.ZERO
	var _last_time: float = 0.0

	func setup(track: Node3D, scene: PackedScene, color: Color) -> void:
		self._node = scene.instantiate() as Node3D
		self._node.name = "__ghost__"
		var mat := Game.make_ghost_material(color)
		for mesh_name in ["Body", "WheelFixedLeft", "WheelFixedRight", "WheelTurnLeft", "WheelTurnRight"]:
			(self._node.get_node(mesh_name) as MeshInstance3D).set_surface_override_material(0, mat)
		self._node.visible = false
		track.add_child(self._node)

	func apply_server_state(pos: Vector3, rot: Quaternion) -> void:
		if !self._node:
			return
		var now := Time.get_ticks_msec() * 0.001
		if !self._node.visible:
			self._node.position = pos
			self._node.quaternion = rot
			self._node.visible = true
		else:
			var dt := now - self._last_time
			if dt > 0.0:
				self._velocity = (pos - self._target_pos) / dt
		self._last_time = now
		self._target_pos = pos
		self._target_rot = rot

	func interpolate(delta: float) -> void:
		if !self._node || !self._node.visible:
			return
		self._node.position += self._velocity * delta
		self._node.position = self._node.position.lerp(self._target_pos, delta * 5.0)
		self._node.quaternion = self._node.quaternion.slerp(self._target_rot, delta * 6.0)

	func clear() -> void:
		if self._node:
			self._node.queue_free()
			self._node = null

class OpponentManager:
	var _track: Node3D
	var _states: Dictionary = {}

	func _init(track: Node3D) -> void:
		self._track = track

	func update(player: Dictionary) -> void:
		var nickname: String = player["nickname"]
		var now := Time.get_ticks_msec() * 0.001

		if nickname not in self._states:
			var rng := RandomNumberGenerator.new()
			rng.seed = nickname.hash()
			var rand_m = Game.CAR_MODELS[rng.randi() % Game.CAR_MODELS.size()]
			var model_def = Game.get_car_model(rand_m["id"])
			var model_scene := load(model_def["path"]) as PackedScene
			var model_node := model_scene.instantiate() as Node3D
			model_node.transform = model_def["transform"]
			var node := Node3D.new()
			node.name = nickname
			node.add_child(model_node)
			self._track.add_child(node, true)

			# Spatial engine hum so you can hear opponents drive past.
			var engine := AudioStreamPlayer3D.new()
			engine.stream = Game.make_engine_stream(model_def["id"])
			engine.pitch_scale = Game.ENGINE_IDLE_PITCH
			engine.volume_db = -2.0
			engine.unit_size = 7.0
			engine.max_distance = 150.0
			node.add_child(engine)
			engine.play()

			node.position = player["position"]
			node.quaternion = player["rotation"]
			self._states[nickname] = {
				"node": node,
				"engine": engine,
				"target_pos": player["position"],
				"target_rot": player["rotation"],
				"velocity": Vector3.ZERO,
				"last_time": now,
			}
			return

		var state: Dictionary = self._states[nickname]
		var dt: float = now - state["last_time"]
		if dt > 0.0:
			state["velocity"] = (player["position"] - state["target_pos"]) / dt
		state["target_pos"] = player["position"]
		state["target_rot"] = player["rotation"]
		state["last_time"] = now

	func interpolate(delta: float) -> void:
		for nickname in self._states:
			var state: Dictionary = self._states[nickname]
			var node: Node3D = state["node"]

			node.position += state["velocity"] * delta

			node.position = node.position.lerp(state["target_pos"], delta * 8.0)
			node.quaternion = node.quaternion.slerp(state["target_rot"], delta * 8.0)

			var eng: AudioStreamPlayer3D = state.get("engine", null)
			if eng:
				var sf: float = clampf(state["velocity"].length() / Game.ENGINE_SPEED_REF, 0.0, 1.0)
				var target_pitch: float = lerpf(Game.ENGINE_IDLE_PITCH, Game.ENGINE_MAX_PITCH, sf)
				eng.pitch_scale = lerpf(eng.pitch_scale, target_pitch, clampf(delta * 6.0, 0.0, 1.0))

	func set_engines_paused(paused: bool) -> void:
		for state in self._states.values():
			var eng = state.get("engine", null)
			if eng:
				eng.stream_paused = paused

	# Play an opponent's horn (from a server Honk event) spatially at their car, so
	# you hear who's honking and from where. One-shot player, freed when it finishes.
	func play_horn(nickname: String, horn_id: String) -> void:
		if nickname not in self._states:
			return
		var stream = load(Game.get_horn(horn_id)["path"])
		if stream == null:
			return
		var node: Node3D = self._states[nickname]["node"]
		var player := AudioStreamPlayer3D.new()
		player.stream = stream
		player.unit_size = 8.0
		player.max_distance = 200.0
		node.add_child(player)
		player.finished.connect(player.queue_free)
		player.play()

	func clear() -> void:
		for state in self._states.values():
			state["node"].queue_free()
		self._states.clear()

var _debug_enabled := false
var _debug_hud: Label = null
var _ranking_hud: PanelContainer = null
var _ranking_box: VBoxContainer = null
# Leaderboard accents (match the menu theme's warm amber).
const RANK_ACCENT := Color(0.95, 0.6, 0.23)
const RANK_ACCENT_BRIGHT := Color(1.0, 0.78, 0.36)
@export var MIN_LIMIT_PLAYERS := 1
@export var MAX_LIMIT_PLAYERS := 6
@export var MIN_PLAYERS_DEFAULT = 2
@export var MAX_PLAYERS_DEFAULT = 4
var available_tracks: Array = []  # Array of {id, name}, populated from server
var _lobby_list: Array = []  # last fetched lobby list, to resolve a lobby's track_id on join
var _fetch_pending: int = 0  # responses still expected during FETCH_LOBBIES

@onready var player_scene: PackedScene = load("res://scenes/player.tscn")
@onready var opponent_scene: PackedScene = load("res://scenes/opponent.tscn")

var mode = Mode.WELCOME_PAGE
var track_node: Node3D = null
var track_def: Dictionary = {}
var car_node: Node3D = null
var paused = false

var _opponents: OpponentManager
var _ghost: GhostManager
var _spectator_camera: Camera3D = null
var _spectator_target: Vector3 = Vector3.ZERO
var _local_finished: bool = false  # local player crossed the line → watching in spectator
var _last_race_rankings: Array = []
var _lobby_min_players: int = 2
var _lobby_max_players: int = 4

# Rocket start: capture first Throttle press around the final beep.
var _rocket_armed: bool = false
var _rocket_press_msec: int = -1
var _rocket_race_start_msec: int = -1
var _rocket_dispatched: bool = false
var regex = RegEx.new()

func _init():
	self.regex.compile("^[A-Za-z][A-Za-z0-9_]*$")

func _ready() -> void:
	_load_settings()
	switch_mode(Mode.FETCH_LOBBIES, false)

func _unhandled_input(event: InputEvent) -> void:
	if OS.has_feature("debug") \
	and event is InputEventKey and event.pressed and not event.echo \
	and event.keycode == KEY_F3:
		self._debug_enabled = not self._debug_enabled

func _process(delta):
	_update_debug_hud()
	if self.mode == Mode.IN_RACE or self.mode == Mode.SPECTATOR:
		if Input.is_action_just_released("Pause"):
			self.paused = ! self.paused
		if self._ghost:
			self._ghost.interpolate(delta)
	if self.mode == Mode.IN_RACE || self.mode == Mode.SPECTATOR:
		if self._opponents:
			self._opponents.interpolate(delta)
	if self.mode == Mode.SPECTATOR and self._spectator_camera != null:
		var cam_goal := _spectator_target + Vector3(0.0, 22.0, 14.0)
		self._spectator_camera.global_position = self._spectator_camera.global_position.lerp(cam_goal, delta * 3.5)
		if _spectator_target != Vector3.ZERO:
			self._spectator_camera.look_at(_spectator_target, Vector3.UP)

	if self._rocket_armed and not self._rocket_dispatched:
		if self._rocket_press_msec == -1 and Input.is_action_pressed("Throttle"):
			self._rocket_press_msec = Time.get_ticks_msec()
		if self._rocket_race_start_msec >= 0:
			if self._rocket_press_msec >= 0:
				var dt := float(self._rocket_press_msec - self._rocket_race_start_msec) / 1000.0
				if self.car_node and self.car_node.has_method("try_rocket_start"):
					var quality: float = self.car_node.try_rocket_start(dt)
					%UI.show_rocket_score(quality)
				self._rocket_dispatched = true
			elif (Time.get_ticks_msec() - self._rocket_race_start_msec) > 500:
				self._rocket_dispatched = true

# F3 debug telemetry overlay for the local car: slip angle, speed, yaw rate, the
# grip↔drift blend, boost charge/state. The driving feel is tuned against these
# (Phase 0 instrumentation), so they stay legible while driving.
func _update_debug_hud() -> void:
	var show_hud: bool = self._debug_enabled and self.mode == Mode.IN_RACE \
		and self.car_node != null and self.car_node.has_method("get_telemetry")
	if not show_hud:
		if self._debug_hud != null:
			self._debug_hud.visible = false
		return
	if self._debug_hud == null:
		self._debug_hud = Label.new()
		self._debug_hud.position = Vector2(12, 12)
		self._debug_hud.add_theme_color_override("font_color", Color(0.6, 1.0, 0.8))
		self._debug_hud.add_theme_font_size_override("font_size", 16)
		self._debug_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
		%UI.add_child(self._debug_hud)
	self._debug_hud.visible = true
	var t: Dictionary = self.car_node.get_telemetry()
	self._debug_hud.text = "spd %5.1f m/s\nslip %+6.1f°\nyaw %+5.2f\ngrip→drift %4.2f\ncharge %4.2f  %s%s" % [
		t["speed"], t["slip_deg"], t["yaw_rate"], t["grip_blend"], t["charge"],
		t["boost"], "" if t["grounded"] else "  (air)"]

# Live leaderboard, top-right: a styled card listing players by server-assigned
# rank, the local player highlighted and the card detached from the screen edge.
# Rebuilt on each race update (small list, ≤6 rows).
func _update_race_ranking(entries: Array) -> void:
	if entries.is_empty():
		if self._ranking_hud:
			self._ranking_hud.visible = false
		return
	if self._ranking_hud == null:
		_build_ranking_hud()
	entries.sort_custom(func(a, b): return a["rank"] < b["rank"])
	for child in self._ranking_box.get_children():
		self._ranking_box.remove_child(child)
		child.free()
	var header := Label.new()
	header.text = tr("hud_ranking")
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", RANK_ACCENT_BRIGHT)
	self._ranking_box.add_child(header)
	for e in entries:
		self._ranking_box.add_child(_make_ranking_row(int(e["rank"]), String(e["nickname"]), bool(e["is_self"])))
	self._ranking_hud.visible = true

func _build_ranking_hud() -> void:
	self._ranking_hud = PanelContainer.new()
	self._ranking_hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 22)
	self._ranking_hud.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	self._ranking_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.10, 0.85)
	sb.set_corner_radius_all(8)
	sb.border_width_left = 3
	sb.border_color = RANK_ACCENT
	sb.content_margin_left = 14.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 11.0
	self._ranking_hud.add_theme_stylebox_override("panel", sb)
	self._ranking_box = VBoxContainer.new()
	self._ranking_box.add_theme_constant_override("separation", 5)
	self._ranking_hud.add_child(self._ranking_box)
	%UI.add_child(self._ranking_hud)

# One leaderboard row: a medal-tinted position badge + the racer's name, with the
# top three gold/silver/bronze and the local player highlighted (brighter, ▸ marker).
func _make_ranking_row(rank: int, racer_name: String, is_self: bool) -> HBoxContainer:
	var medal := Color(0.62, 0.68, 0.78)
	if rank == 1:
		medal = Color(1.0, 0.84, 0.20)
	elif rank == 2:
		medal = Color(0.80, 0.84, 0.88)
	elif rank == 3:
		medal = Color(0.82, 0.52, 0.28)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)

	var badge := Label.new()
	badge.text = str(rank)
	badge.custom_minimum_size = Vector2(22, 22)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 13)
	badge.add_theme_color_override("font_color", Color(0.06, 0.07, 0.09))
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = medal
	bsb.set_corner_radius_all(6)
	badge.add_theme_stylebox_override("normal", bsb)
	row.add_child(badge)

	var nm := Label.new()
	nm.text = ("▸ " + racer_name) if is_self else racer_name
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nm.add_theme_font_size_override("font_size", 16 if is_self else 15)
	nm.add_theme_color_override("font_color", RANK_ACCENT_BRIGHT if is_self else Color(0.88, 0.92, 0.97))
	row.add_child(nm)
	return row

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_settings()
		get_tree().quit()

func _save_settings() -> void:
	var config = ConfigFile.new()
	config.load("user://settings.cfg")  # keep locale/bindings written by the autoloads
	if check_min_players(%UI.get_min_players()):
		config.set_value("Settings", "min_players", %UI.get_min_players())
	if check_max_players(%UI.get_max_players()):
		config.set_value("Settings", "max_players", %UI.get_max_players())
	if check_lobby_name(%UI.get_lobby_name()):
		config.set_value("Settings", "lobby_name", %UI.get_lobby_name())
	if check_nickname(%UI.get_nickname()):
		config.set_value("Settings", "nickname", %UI.get_nickname())
	config.set_value("Settings", "car_model_id", %UI.get_car_model_id())
	config.set_value("Settings", "horn_id", %UI.get_horn_id())
	config.save("user://settings.cfg")

func _load_settings() -> void:
	var config = ConfigFile.new()
	if config.load("user://settings.cfg") != OK:
		if config.save("user://settings.cfg") != OK:
			printerr("Could not create settings file")
			return
	%UI.set_min_players(int(config.get_value("Settings", "min_players", self.MIN_PLAYERS_DEFAULT)))
	%UI.set_max_players(int(config.get_value("Settings", "max_players", self.MAX_PLAYERS_DEFAULT)))
	%UI.set_lobby_name(config.get_value("Settings", "lobby_name", NameGenerator.lobby_name()))
	%UI.set_nickname(config.get_value("Settings", "nickname", NameGenerator.nickname()))
	%UI.set_car_model_id(config.get_value("Settings", "car_model_id", DEFAULT_CAR_MODEL))
	%UI.set_horn_id(config.get_value("Settings", "horn_id", DEFAULT_HORN))

func check_min_players(value: int) -> bool:
	return value >= self.MIN_LIMIT_PLAYERS and value <= self.MAX_LIMIT_PLAYERS and value <= %UI.get_max_players()

func check_max_players(value: int) -> bool:
	return value >= self.MIN_LIMIT_PLAYERS and value <= self.MAX_LIMIT_PLAYERS and value >= %UI.get_min_players()

func check_lobby_name(lobby_name: String) -> bool:
	return is_valid_name(lobby_name)

func check_nickname(nickname: String) -> bool:
	return is_valid_name(nickname)

func is_valid_name(name_to_check: String) -> bool:
	if name_to_check.length() < 3 or name_to_check.length() > 20:
		return false
	return self.regex.search(name_to_check) != null

func switch_mode(next_mode: Mode, server_up: bool):
	# A socket-close can fire a redundant transition (e.g. WELCOME_PAGE → WELCOME_PAGE);
	# ignore it rather than asserting (which would halt a debug build).
	if next_mode == self.mode:
		return

	# Persist the pilot's nickname + lobby name the moment they commit to a race, not
	# only on a clean window close — so they survive even when the process is killed
	# (e.g. closing the dev terminal) rather than quit from the menu.
	if next_mode == Mode.CREATING_LOBBY or next_mode == Mode.JOINING_LOBBY:
		_save_settings()

	var leaving_track := self.mode == Mode.IN_RACE || self.mode == Mode.LOBBY_INTERMISSION || self.mode == Mode.SPECTATOR
	if leaving_track && next_mode == Mode.WELCOME_PAGE:
		self.track_node.visible = false
		if self.car_node:
			self.car_node.visible = false
		if self._spectator_camera:
			self._spectator_camera.queue_free()
			self._spectator_camera = null
		if self._opponents:
			self._opponents.clear()
		if self._ghost:
			self._ghost.clear()
			self._ghost = null
		for n in $Track.get_children():
			n.queue_free()

	if next_mode == Mode.IN_RACE:
		self.track_node.visible = true
		self.car_node.visible = true

		var rb := self.car_node as RigidBody3D
		rb.freeze = false
		if self._ghost:
			self._ghost.apply_server_state(self.car_node.global_position, self.car_node.quaternion)

	if self.mode == Mode.SPECTATOR && next_mode == Mode.LOBBY_INTERMISSION:
		self.car_node.visible = true
		if self._spectator_camera:
			self._spectator_camera.queue_free()
			self._spectator_camera = null
		var cam := self.car_node.get_node_or_null("Camera") as Camera3D
		if cam:
			cam.make_current()
		if self._debug_enabled:
			self._ghost = GhostManager.new()
			self._ghost.setup($Track, self.opponent_scene, %UI.get_car_color())

	if leaving_track:
		if next_mode == Mode.WELCOME_PAGE:
			%Network.terminate()
	elif self.mode == Mode.WELCOME_PAGE:
		if next_mode == Mode.FETCH_LOBBIES \
		   || next_mode == Mode.JOINING_LOBBY \
		   || next_mode == Mode.CREATING_LOBBY:
			if !%Network.connect_to_server():
				return

	%UI.switch_mode(next_mode, server_up)

	if self._opponents:
		self._opponents.set_engines_paused(next_mode != Mode.IN_RACE and next_mode != Mode.SPECTATOR)

	if self._ranking_hud and next_mode != Mode.IN_RACE and next_mode != Mode.SPECTATOR:
		self._ranking_hud.visible = false

	self.mode = next_mode

	# Returning home from a race: re-fetch the lobby list so it isn't stale.
	if leaving_track and next_mode == Mode.WELCOME_PAGE:
		call_deferred("_auto_refresh_lobbies")

func _auto_refresh_lobbies() -> void:
	if self.mode == Mode.WELCOME_PAGE:
		switch_mode(Mode.FETCH_LOBBIES, false)

func _on_boost_pad_entered(body: Node, pad: Area3D) -> void:
	if body == self.car_node:
		self.car_node.apply_pad_boost(float(pad.get_meta("boost_strength", 20.0)))

func switch_to_track(track_id: String, race_ongoing: bool):
	var display_name := track_id
	for t in self.available_tracks:
		if t.get("id", "") == track_id:
			display_name = String(t.get("name", track_id))
			break
	%UI.set_intermission_lobby_name(%UI.get_lobby_name())
	%UI.set_intermission_track_name(tr("current_track") % display_name)

	# The level is fully data-driven: its lighting/sky is a procedural preset
	# named in the track JSON (no per-track scene), and TrackLoader builds the
	# geometry under "Physical". See environment_builder.gd / track_loader.gd.
	self.track_node = Node3D.new()
	self.track_node.name = "TrackRoot"
	$Track.add_child(self.track_node)

	self.track_node.add_child(EnvironmentBuilder.build(self.track_def.get("environment", "studio")))

	var physical_node := Node3D.new()
	physical_node.name = "Physical"
	self.track_node.add_child(physical_node)
	var spawn_info: Dictionary = TrackLoader.build(physical_node, self.track_def)

	self._opponents = OpponentManager.new($Track)

	self.car_node = self.player_scene.instantiate()
	self.car_node.car_model_id = %UI.get_car_model_id()
	self.car_node.horn_id = %UI.get_horn_id()
	self.car_node.name = %UI.get_nickname()
	$Track.add_child(self.car_node)

	self.car_node.global_position = spawn_info["spawn_pos"]
	self.car_node.global_rotation = Vector3(0.0, deg_to_rad(spawn_info["spawn_y_rotation_deg"]), 0.0)

	# Mirror the server's boost pads on the local player so the client predicts the
	# speed bump instead of rubber-banding to catch up (see player.apply_pad_boost).
	for pad in get_tree().get_nodes_in_group("BoostPad"):
		pad.body_entered.connect(_on_boost_pad_entered.bind(pad))

	(self.car_node as RigidBody3D).freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	(self.car_node as RigidBody3D).freeze = true

	if race_ongoing:
		_enter_spectator()
	else:
		if self._debug_enabled:
			self._ghost = GhostManager.new()
			self._ghost.setup($Track, self.opponent_scene, %UI.get_car_color())
		var camera_node: Camera3D = self.car_node.get_node_or_null("Camera")
		if camera_node:
			camera_node.make_current()
		switch_mode(Mode.LOBBY_INTERMISSION, true)

# Switch the local view to the high, whole-circuit spectator camera. Used both when
# joining a race already in progress and when the local player finishes and watches
# the rest of the field. Idempotent — safe to call when already spectating.
func _enter_spectator() -> void:
	if self.mode == Mode.SPECTATOR:
		return
	if self.car_node:
		self.car_node.visible = false
	if self._spectator_camera == null:
		self._spectator_camera = Camera3D.new()
		self._spectator_camera.fov = 90.0
		self._spectator_camera.position = Vector3(0.0, 200.0, 80.0)
		$Track.add_child(self._spectator_camera)
		self._spectator_camera.look_at(Vector3.ZERO, Vector3.UP)
	self._spectator_camera.make_current()
	switch_mode(Mode.SPECTATOR, true)

func on_connection():
	var requests: Array = []
	if self.mode == Mode.FETCH_LOBBIES:
		requests.append({"Request": "FetchLobbyList"})
		if self.available_tracks.is_empty():
			requests.append({"Request": "FetchTrackList"})
		self._fetch_pending = requests.size()
	elif self.mode == Mode.JOINING_LOBBY:
		var join_track_id := _track_id_for_lobby(%UI.get_selected_lobby_name())
		requests.append({"Request": {"JoinLobby": {
			"lobby_id": %UI.get_selected_lobby_name(),
			"nickname": %UI.get_nickname(),
			"color": MessageParser.color_to_proto(%UI.get_car_color()),
			"horn_id": %UI.get_horn_id(),
			"cached_track_hash": _cached_hash_or_null(join_track_id),
		}}})
	elif self.mode == Mode.CREATING_LOBBY:
		requests.append({"Request": {"CreateLobby": {
			"lobby_id": %UI.get_lobby_name(),
			"track_id": %UI.get_selected_track_id(),
			"nickname": %UI.get_nickname(),
			"min_players": %UI.get_min_players(),
			"max_players": %UI.get_max_players(),
			"color": MessageParser.color_to_proto(%UI.get_car_color()),
			"horn_id": %UI.get_horn_id(),
			"cached_track_hash": _cached_hash_or_null(%UI.get_selected_track_id()),
		}}})
	else:
		return

	for req in requests:
		var result = %Network.socket.send_text(JSON.stringify(req))
		if result != OK:
			printerr("Could not send request: %s" % req)

	if self.mode == Mode.CREATING_LOBBY:
		switch_mode(Mode.JOINING_LOBBY, true)

# Track id of the lobby with this name from the last fetched list ("" if unknown).
func _track_id_for_lobby(lobby_name: String) -> String:
	for info in self._lobby_list:
		if String(info.get("name", "")) == lobby_name:
			return String(info.get("track_id", ""))
	return ""

# Cached content hash for a track id, or null so the server sends the full track.
func _cached_hash_or_null(track_id: String):
	var h := TrackCache.cached_hash(track_id)
	if h == "":
		return null
	return h

func on_server_message(message: Dictionary) -> bool:
	if OS.has_feature("debug") && self._debug_enabled:
		print(message)

	if self.mode == Mode.FETCH_LOBBIES:
		if message.has("Response") && message["Response"].has("LobbyList"):
			self._lobby_list = message["Response"]["LobbyList"]
			%UI.refresh(self._lobby_list)
		elif message.has("Response") && message["Response"].has("TrackList"):
			var raw_list: Array = message["Response"]["TrackList"]
			self.available_tracks.clear()
			for entry in raw_list:
				self.available_tracks.append({
					"id": String(entry.get("id", "")),
					"name": String(entry.get("name", "")),
				})
			%UI.refresh_tracks(self.available_tracks)
		else:
			printerr("Unexpected response in FETCH_LOBBIES")
		self._fetch_pending = max(0, self._fetch_pending - 1)
		return self._fetch_pending > 0  # keep connection until all pending responses are in

	elif self.mode == Mode.JOINING_LOBBY:
		if !message.has("Response") || !message["Response"].has("LobbyJoined"):
			printerr("Unexpected response for join lobby")
			return false
		var parsed = MessageParser.parse_join_response(message)
		if !parsed["ok"]:
			%UI.set_status_error(tr("could_not_join") % parsed["error_str"])
			return false
		self._lobby_min_players = parsed["min_players"]
		self._lobby_max_players = parsed["max_players"]
		var track_id: String = parsed["track_id"]
		var track_hash: String = parsed.get("track_hash", "")
		var t = parsed.get("track", null)
		if t != null:
			# Fresh download: use it and cache it (keyed by hash) for next time.
			self.track_def = t
			TrackCache.store(track_id, track_hash, t)
		else:
			# Server omitted the track because our cached copy is current — load it.
			var cached = TrackCache.load_track(track_id, track_hash)
			if cached == null:
				printerr("Track not cached and server sent none: ", track_id)
				%UI.set_status_error(tr("could_not_join") % tr("err_track_not_found"))
				return false
			self.track_def = cached
		switch_to_track(track_id, parsed["race_ongoing"])

	elif self.mode == Mode.LOBBY_INTERMISSION || self.mode == Mode.IN_RACE || self.mode == Mode.SPECTATOR:
		_handle_lobby_message(message)

	return true

func _handle_lobby_message(message: Dictionary) -> void:
	if message.has("Event"):
		var event = message["Event"]
		if event.has("Honk"):
			# Another player honked: play their horn at their car. Our own honk already
			# played locally on the input, so skip the echo for ourselves.
			var honk = event["Honk"]
			var honk_nick := String(honk["nickname"])
			if honk_nick != %UI.get_nickname() and self._opponents:
				self._opponents.play_horn(honk_nick, String(honk["horn_id"]))
		if event.has("RaceAboutToStart"):
			var spawn = MessageParser.parse_spawn_info(event["RaceAboutToStart"])

			# Place the car just above the spawn (the gate sits near resting height),
			# then unfreeze it so it barely drops and settles during the countdown.
			# Letting it rest before the lights go green avoids the collider-resolve
			# pop. reset_physics_interpolation() stops a visual streak from the
			# previous (intermission) position.
			self.car_node.global_position = spawn["position"] + Vector3(0.0, 0.1, 0.0)
			self.car_node.global_rotation = Vector3(0.0, deg_to_rad(spawn["y_rotation"]), 0.0)
			self.car_node.reset_physics_interpolation()
			(self.car_node as RigidBody3D).freeze = false

			%UI.reset_start_lights()
			%UI.set_info_label("")

			self._rocket_armed = true
			self._rocket_press_msec = -1
			self._rocket_race_start_msec = -1
			self._rocket_dispatched = false
			self._local_finished = false

			if self.mode == Mode.SPECTATOR:
				switch_mode(Mode.LOBBY_INTERMISSION, true)
			# Reveal the track for the silent pre-countdown beat: cars are placed
			# and the start lights stay dark until the first Countdown event.
			if self.mode == Mode.LOBBY_INTERMISSION:
				%UI.show_pre_race_view()
		if event.has("RaceStarted") && self.mode == Mode.LOBBY_INTERMISSION:
			%UI.start_lights_go()
			self._rocket_race_start_msec = Time.get_ticks_msec()
			switch_mode(Mode.IN_RACE, true)
		if event.has("LobbyCountdown"):
			if self.mode == Mode.LOBBY_INTERMISSION:
				%UI.set_lobby_countdown(float(event["LobbyCountdown"]["time"]))
		if event.has("Countdown"):
			var t: float = float(event["Countdown"]["time"])
			%UI.set_info_label(tr("start_in") % int(t))
			%UI.start_lights_countdown(t)
			if self.mode == Mode.LOBBY_INTERMISSION:
				%UI.show_pre_race_view()
		if event.has("FinishCountdown"):
			# Someone crossed the line first: racers still going see how long is left
			# before the race force-ends. Finishers are already spectating.
			if not self._local_finished and self.mode == Mode.IN_RACE:
				%UI.set_info_label(tr("finish_in") % int(event["FinishCountdown"]["time"]))
		if event.has("RaceFinished"):
			var finished = event["RaceFinished"]
			self._last_race_rankings = finished.get("rankings", [])
			if self.mode == Mode.IN_RACE or self.mode == Mode.SPECTATOR:
				switch_mode(Mode.LOBBY_INTERMISSION, true)
			%UI.show_race_results(self._last_race_rankings)

	elif message.has("State"):
		var state = message["State"]
		if state.has("Players"):
			var players = state["Players"] as Array
			if self.mode == Mode.LOBBY_INTERMISSION:
				%UI.set_intermission_players_count(tr("lobby_count") % [
					players.size(), self._lobby_max_players, self._lobby_min_players
				])
				%UI.set_intermission_players_list(players)
			var _spectator_target_set := false
			var ranking_entries: Array = []
			for raw in players:
				var player = MessageParser.parse_player(raw)
				if !player["racing"]:
					continue
				ranking_entries.append({
					"rank": player["rank"],
					"nickname": player["nickname"],
					"is_self": player["nickname"] == %UI.get_nickname(),
				})
				if player["nickname"] == %UI.get_nickname():
					if self.mode == Mode.IN_RACE:
						if self._ghost:
							self._ghost.apply_server_state(player["position"], player["rotation"])
						if self.car_node:
							self.car_node.apply_server_correction(player["position"], player["rotation"])
						var laps: int = player.get("laps", 0)
						if laps >= int(self.track_def.get("laps_to_win", 3)):
							%UI.set_status_success(tr("finished"))
							# Crossed the line: watch the rest of the field from the
							# whole-circuit spectator camera instead of driving on.
							if not self._local_finished:
								self._local_finished = true
								_enter_spectator()
						else:
							%UI.set_info_label(tr("lap") % [laps + 1, int(self.track_def.get("laps_to_win", 3))])
				else:
					self._opponents.update(player)
					if self.mode == Mode.SPECTATOR and not _spectator_target_set:
						_spectator_target = player["position"]
						_spectator_target_set = true
			if self.mode == Mode.IN_RACE or self.mode == Mode.SPECTATOR:
				_update_race_ranking(ranking_entries)
		elif state.has("WaitingForPlayers"):
			var missing = int(state["WaitingForPlayers"])
			%UI.set_info_label(tr("waiting_one" if missing == 1 else "waiting_many") % missing)
			%UI.clear_lobby_countdown()
