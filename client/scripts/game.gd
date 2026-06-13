extends Node

class_name Game

const CAR_MODELS = [
	{"id": "car1", "name": "Car1",
	 "path": "res://scenes/cars/car1.tscn",
	 "wheel_fl": "wheel-front-left", "wheel_fr": "wheel-front-right"},
	{"id": "car2", "name": "Car2",
	 "path": "res://scenes/cars/car2.tscn",
	 "wheel_fl": "wheel-front-left", "wheel_fr": "wheel-front-right"},
	{"id": "car3", "name": "Car3",
	 "path": "res://scenes/cars/car3.tscn",
	 "wheel_fl": "wheel-front-left", "wheel_fr": "wheel-front-right"},
]

const DEFAULT_CAR_MODEL := "car1"

static func get_car_model(model_id: String) -> Dictionary:
	for m in CAR_MODELS:
		if m["id"] == model_id:
			var def: Dictionary = m.duplicate()
			def["transform"] = Transform3D.IDENTITY
			return def
	return get_car_model(DEFAULT_CAR_MODEL)

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

# Tyre-screech for drifting: low-passed noise mixed with two squealing tones
# and a fast amplitude wobble. Tonal parts are integer-periodic over the buffer;
# the noise tail is cross-faded into the head to keep the loop click-free.
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
		lp += 0.25 * (n - lp)
		var tone := sin(TAU * 2200.0 * t) * 0.5 + sin(TAU * 3300.0 * t) * 0.3
		var wob := 0.7 + 0.3 * sin(TAU * 18.0 * t)
		raw[i] = (lp * 0.8 + tone * 0.5) * wob
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
	static func nickname() -> String:
		var prefixes = ["Neo", "Dark", "Ultra", "Mega", "Hyper", "Shadow", "Cyber", "Iron", "Ghost"]
		var cores = ["Fox", "Wolf", "Tiger", "Eagle", "Viper", "Falcon", "Blade", "Storm", "Nova"]
		var suffixes = ["", "X", "99", "Pro", "HD", "Prime", "Z", "One"]
		var rng = RandomNumberGenerator.new()
		rng.randomize()
		return prefixes[rng.randi_range(0, prefixes.size() - 1)] \
			+ cores[rng.randi_range(0, cores.size() - 1)] \
			+ suffixes[rng.randi_range(0, suffixes.size() - 1)]

	static func lobby_name() -> String:
		var adjectives = ["Red", "Blue", "Green", "Yellow", "Purple", "Orange", "Silver", "Golden", "Black"]
		var nouns = ["Comet", "Meteor", "Asteroid", "Nebula", "Galaxy", "Star", "Planet", "Rocket", "Satellite"]
		var rng = RandomNumberGenerator.new()
		rng.randomize()
		return adjectives[rng.randi_range(0, adjectives.size() - 1)] \
			+ nouns[rng.randi_range(0, nouns.size() - 1)]

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

	func clear() -> void:
		for state in self._states.values():
			state["node"].queue_free()
		self._states.clear()

var _debug_enabled := false
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
		if self._rocket_press_msec == -1 and Input.is_action_just_pressed("Throttle"):
			self._rocket_press_msec = Time.get_ticks_msec()
		if self._rocket_race_start_msec >= 0:
			if self._rocket_press_msec >= 0:
				var dt := float(self._rocket_press_msec - self._rocket_race_start_msec) / 1000.0
				if self.car_node and self.car_node.has_method("try_rocket_start"):
					self.car_node.try_rocket_start(dt)
				self._rocket_dispatched = true
			elif (Time.get_ticks_msec() - self._rocket_race_start_msec) > 500:
				self._rocket_dispatched = true

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
	assert(next_mode != self.mode)

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

	var per_track_path := "res://tracks/" + track_id + "/level.tscn"
	var fallback_path := "res://tracks/circuit_test/level.tscn"
	var scene_path := per_track_path if ResourceLoader.exists(per_track_path) else fallback_path
	var track_scene: PackedScene = load(scene_path)
	self.track_node = track_scene.instantiate()
	$Track.add_child(self.track_node)

	var physical_node: Node3D = self.track_node.get_node("Physical") as Node3D
	var spawn_info: Dictionary = TrackLoader.build(physical_node, self.track_def)

	self._opponents = OpponentManager.new($Track)

	self.car_node = self.player_scene.instantiate()
	self.car_node.car_model_id = %UI.get_car_model_id()
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

		self.car_node.visible = false
		self._spectator_camera = Camera3D.new()
		self._spectator_camera.fov = 90.0
		self._spectator_camera.position = Vector3(0.0, 200.0, 80.0)
		$Track.add_child(self._spectator_camera)

		self._spectator_camera.look_at(Vector3.ZERO, Vector3.UP)
		self._spectator_camera.make_current()
		switch_mode(Mode.SPECTATOR, true)
	else:
		if self._debug_enabled:
			self._ghost = GhostManager.new()
			self._ghost.setup($Track, self.opponent_scene, %UI.get_car_color())
		var camera_node: Camera3D = self.car_node.get_node_or_null("Camera")
		if camera_node:
			camera_node.make_current()
		switch_mode(Mode.LOBBY_INTERMISSION, true)

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
	return h if h != "" else null

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
			%UI.set_info_label(tr("could_not_join") % parsed["error_str"])
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
				%UI.set_info_label(tr("could_not_join") % tr("err_track_not_found"))
				return false
			self.track_def = cached
		switch_to_track(track_id, parsed["race_ongoing"])

	elif self.mode == Mode.LOBBY_INTERMISSION || self.mode == Mode.IN_RACE || self.mode == Mode.SPECTATOR:
		_handle_lobby_message(message)

	return true

func _handle_lobby_message(message: Dictionary) -> void:
	if message.has("Event"):
		var event = message["Event"]
		if event.has("RaceAboutToStart"):
			var spawn = MessageParser.parse_spawn_info(event["RaceAboutToStart"])

			# Place the car a touch above the spawn, then unfreeze it so it drops and
			# settles on the track during the countdown. Letting it rest before the
			# lights go green avoids the collider-resolve pop that happened when the
			# body was unfrozen at the start. reset_physics_interpolation() stops a
			# visual streak from the previous (intermission) position.
			self.car_node.global_position = spawn["position"] + Vector3(0.0, 0.5, 0.0)
			self.car_node.global_rotation = Vector3(0.0, deg_to_rad(spawn["y_rotation"]), 0.0)
			self.car_node.reset_physics_interpolation()
			(self.car_node as RigidBody3D).freeze = false

			%UI.reset_start_lights()
			%UI.set_info_label("")

			self._rocket_armed = true
			self._rocket_press_msec = -1
			self._rocket_race_start_msec = -1
			self._rocket_dispatched = false

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
				%UI.set_intermission_players_count("%d/%d (%d minimum)" % [
					players.size(), self._lobby_max_players, self._lobby_min_players
				])
				%UI.set_intermission_players_list(players)
			var _spectator_target_set := false
			for raw in players:
				var player = MessageParser.parse_player(raw)
				if !player["racing"]:
					continue
				if player["nickname"] == %UI.get_nickname():
					if self.mode == Mode.IN_RACE:
						if self._ghost:
							self._ghost.apply_server_state(player["position"], player["rotation"])
						if self.car_node:
							self.car_node.apply_server_correction(player["position"], player["rotation"])
						var laps: int = player.get("laps", 0)
						if laps >= int(self.track_def.get("laps_to_win", 3)):
							%UI.set_info_label(tr("finished"))
						else:
							%UI.set_info_label(tr("lap") % [laps + 1, int(self.track_def.get("laps_to_win", 3))])
				else:
					self._opponents.update(player)
					if self.mode == Mode.SPECTATOR and not _spectator_target_set:
						_spectator_target = player["position"]
						_spectator_target_set = true
		elif state.has("WaitingForPlayers"):
			var missing = int(state["WaitingForPlayers"])
			%UI.set_info_label(tr("waiting_one" if missing == 1 else "waiting_many") % missing)
			%UI.clear_lobby_countdown()
