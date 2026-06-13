extends RigidBody3D

const THROTTLE_FORCE     := 14_000.0
const REVERSE_FORCE      := 5_000.0
const BRAKE_FORCE        := 8_000.0
const BRAKE_MIN_SPEED    := 1.0
const MOTION_DIRECTION_EPSILON := 0.25
const MAX_TURN_RATE_GRIP := 1.2
const MAX_TURN_RATE_DRIFT := 2.4    # softer than before (was 3.2): a gentler rotation
const STEER_P_GAIN       := 25_000.0
# Keyboard steering is digital (-1/0/1); ramping the effective steer toward the
# raw input smooths turn-in and gives a natural return-to-centre instead of a
# snap. The smoothed value is what we both drive locally and send to the server,
# so prediction and authority stay in lockstep. ~0.13 s from centre to full lock.
const STEER_SMOOTH_RATE  := 8.0
const ALIGN_RATE_GRIP    := 4.0
const ALIGN_RATE_DRIFT   := 0.4     # lower (was 0.6): velocity lags the heading → more slide
const NORMAL_LINEAR_DAMP := 0.3
const DRIFT_LINEAR_DAMP  := 0.18
const DRIFT_MIN_SPEED    := 3.0
# Drift is eased in/out via a 0→1 grip-blend instead of a hard switch, so the
# slide builds and releases smoothly — "controlled loss of control".
const GRIP_BLEND_RATE    := 6.0

const BOOST_CHARGE_RATE   := 1.0
const BOOST_CHARGE_DECAY  := 2.0
const BOOST_CHARGE_MIN    := 0.30
const BOOST_PEAK_BONUS    := 18.0
const BOOST_DURATION      := 1.5
const BOOST_ALIGN_THRESHOLD_COS := 0.9781476  # cos(12°)
const BOOST_PENDING_TIMEOUT := 1.5
const BOOST_SUSTAIN_FORCE  := 30_000.0

const ROCKET_WINDOW_S := 0.5
const ROCKET_BONUS    := 22.0

const POS_SOFT_RATE := 0.08
const ROT_SOFT_RATE := 0.08
const RESPAWN_SNAP_DIST := 12.0  # server pos jumps beyond this → teleport, not lerp

const ENGINE_IDLE_PITCH := 0.85   # low, round idle
const ENGINE_MAX_PITCH  := 1.6    # capped so the engine never whines at speed
const ENGINE_SPEED_REF  := 42.0   # speed (m/s) mapped to peak pitch / volume
const ENGINE_IDLE_DB    := -16.0
const ENGINE_LOUD_DB    := -3.0
const DRIFT_DB          := -7.0
const AUDIO_SILENT_DB   := -60.0

enum BoostState { IDLE, PENDING, BOOSTING }

var drift_charge: float = 0.0
var boost_flash: bool = false
var _was_star_drift_pressed := false
var _boost_state: int = BoostState.IDLE
var _boost_t_remaining: float = 0.0
var _boost_pending_t: float = 0.0
var _boost_peak_speed: float = 0.0
var _reversing := false
var _grip_blend: float = 0.0  # 0 = full grip, 1 = full drift (eased)
var _steer_input: float = 0.0  # smoothed steering axis (see STEER_SMOOTH_RATE)

var _server_pos       := Vector3.ZERO
var _server_pos_valid := false
var _server_rot       := Quaternion.IDENTITY
var _server_rot_valid := false

var _wheel_fl: Node3D = null
var _wheel_fr: Node3D = null
var init_rot_wheel: float = 0.0
var delta_rot_wheel := 0.0
const LIMIT_ROT_WHEEL := 30.0

var car_model_id: String = "racer"

var _engine_audio: AudioStreamPlayer = null
var _drift_audio: AudioStreamPlayer = null
var _engine_pitch := ENGINE_IDLE_PITCH
var _engine_db := AUDIO_SILENT_DB
var _drift_db := AUDIO_SILENT_DB

var network_timer := 0.0
const NETWORK_SEND_INTERVAL := 0.05

@onready var network = get_tree().get_first_node_in_group("Network")
@onready var _game := get_node("/root/Root/Game")
@onready var _ground_ray: RayCast3D = $GroundRay

func _ready() -> void:
	self.angular_damp = 0.5
	self.linear_damp  = NORMAL_LINEAR_DAMP
	_load_car_body()
	_setup_audio()

func _setup_audio() -> void:
	_engine_audio = AudioStreamPlayer.new()
	_engine_audio.stream = Game.make_engine_stream(car_model_id)
	_engine_audio.pitch_scale = ENGINE_IDLE_PITCH
	_engine_audio.volume_db = AUDIO_SILENT_DB
	add_child(_engine_audio)
	_engine_audio.play()

	_drift_audio = AudioStreamPlayer.new()
	_drift_audio.stream = Game.make_drift_stream()
	_drift_audio.volume_db = AUDIO_SILENT_DB
	add_child(_drift_audio)
	_drift_audio.play()

func _tick_audio(speed: float, throttle: bool, drifting: bool, active: bool, delta: float) -> void:
	if _engine_audio == null:
		return
	var target_pitch := ENGINE_IDLE_PITCH
	var target_engine_db := AUDIO_SILENT_DB
	if active:
		var spd_factor := clampf(speed / ENGINE_SPEED_REF, 0.0, 1.0)
		target_pitch = lerpf(ENGINE_IDLE_PITCH, ENGINE_MAX_PITCH, spd_factor)
		if throttle:
			target_pitch += 0.12
		target_engine_db = lerpf(ENGINE_IDLE_DB, ENGINE_LOUD_DB, spd_factor)

	_engine_pitch = lerpf(_engine_pitch, target_pitch, clampf(delta * 6.0, 0.0, 1.0))
	_engine_db = lerpf(_engine_db, target_engine_db, clampf(delta * 5.0, 0.0, 1.0))
	_engine_audio.pitch_scale = _engine_pitch
	_engine_audio.volume_db = _engine_db

	var target_drift_db := DRIFT_DB if (active and drifting) else AUDIO_SILENT_DB
	var drift_rate := 14.0 if (active and drifting) else 6.0
	_drift_db = lerpf(_drift_db, target_drift_db, clampf(delta * drift_rate, 0.0, 1.0))
	_drift_audio.volume_db = _drift_db

func _load_car_body() -> void:
	var model_def := Game.get_car_model(car_model_id)
	var scene := load(model_def["path"]) as PackedScene
	if scene == null:
		printerr("Could not load car model: ", model_def["path"])
		return
	var body := scene.instantiate() as Node3D
	body.name = "Body"
	body.transform = model_def["transform"]
	add_child(body)
	_wheel_fl = body.find_child(model_def["wheel_fl"], true, false)
	_wheel_fr = body.find_child(model_def["wheel_fr"], true, false)
	init_rot_wheel = _wheel_fl.rotation_degrees.y if _wheel_fl else 0.0

func _physics_process(delta: float) -> void:
	if self._game.mode != Game.Mode.IN_RACE:
		_tick_audio(0.0, false, false, false, delta)
		return

	if self._game.paused:
		# Local pause: freeze the body so it stops integrating gravity and momentum.
		# Without this it keeps coasting (and falling) while paused, then snaps back
		# hard the instant the race resumes — the jolt this avoids.
		if not self.freeze:
			self.freeze = true
			self.linear_velocity = Vector3.ZERO
			self.angular_velocity = Vector3.ZERO
		_tick_audio(0.0, false, false, false, delta)
		return

	if self.freeze:
		# Resuming from a pause.
		self.freeze = false

	var forward_dir := -self.transform.basis.z
	# Horizontal projection of forward — used for velocity alignment and boost so
	# ramps don't redirect velocity skyward.
	var horiz_forward := Vector3(forward_dir.x, 0.0, forward_dir.z)
	var hf_len := horiz_forward.length()
	if hf_len > 1e-4:
		horiz_forward /= hf_len
	else:
		horiz_forward = forward_dir

	var throttle := Input.is_action_pressed("Throttle")
	# Smooth the raw (often digital) steering axis so turn-in eases instead of
	# snapping; this smoothed value drives the car and is the value sent to the
	# server, keeping client prediction and server authority identical.
	var steer_raw := Input.get_axis("Steering Left", "Steering Right")
	_steer_input = move_toward(_steer_input, steer_raw, STEER_SMOOTH_RATE * delta)
	var steer := _steer_input
	var star_drift_input := Input.is_action_pressed("Star Drift")

	var speed := self.linear_velocity.length()

	# Airborne: the wheels have no grip, so driving inputs (throttle, reverse,
	# brake, drift, velocity re-alignment, boost) are disabled. Only orientation —
	# the yaw steering torque below — stays available so the player can line the
	# car up for landing.
	var grounded := _ground_ray.is_colliding()

	var drift := grounded and star_drift_input and speed > DRIFT_MIN_SPEED

	# Ease the grip-blend toward the drift target so handling shifts smoothly
	# instead of snapping between grip and drift.
	var drift_target := 1.0 if drift else 0.0
	_grip_blend = lerpf(_grip_blend, drift_target, clampf(delta * GRIP_BLEND_RATE, 0.0, 1.0))

	var forward_speed := forward_dir.dot(self.linear_velocity)
	if forward_speed <= -MOTION_DIRECTION_EPSILON:
		self._reversing = true
	elif forward_speed >= MOTION_DIRECTION_EPSILON:
		self._reversing = false
	elif throttle:
		self._reversing = false  # throttle while nearly stopped → go forward
	elif star_drift_input and not throttle:
		self._reversing = true

	if grounded:
		if throttle and not self._reversing:
			apply_central_force(forward_dir * THROTTLE_FORCE)
		if not throttle and self._reversing:
			apply_central_force(-forward_dir * REVERSE_FORCE)

		if star_drift_input and not throttle and forward_speed > BRAKE_MIN_SPEED:
			var bv := self.linear_velocity
			if bv.length() > 0.01:
				apply_central_force(-bv.normalized() * BRAKE_FORCE)

	# Orientation is always allowed — even airborne.
	var effective_steer := -steer if self._reversing else steer
	var max_turn   := lerpf(MAX_TURN_RATE_GRIP, MAX_TURN_RATE_DRIFT, _grip_blend)
	var target_yaw := -effective_steer * max_turn
	var yaw_error  := target_yaw - self.angular_velocity.y
	apply_torque(Vector3.UP * yaw_error * STEER_P_GAIN)

	# Slerp only the horizontal component of velocity. Y is preserved so gravity
	# and ramp impulses still apply naturally (no hovering on ramp exits).
	# Skipped while airborne so the player keeps their launch momentum.
	var v := self.linear_velocity
	var v_h := Vector3(v.x, 0.0, v.z)
	var h_speed := v_h.length()
	if grounded and h_speed > 0.5 and not self._reversing:
		var cur_dir_h := v_h / h_speed
		var rate := lerpf(ALIGN_RATE_GRIP, ALIGN_RATE_DRIFT, _grip_blend)
		var new_dir_h := _vec3_slerp_clamped(cur_dir_h, horiz_forward, rate * delta)
		var new_h := new_dir_h * h_speed
		self.linear_velocity = Vector3(new_h.x, v.y, new_h.z)

	self.linear_damp = lerpf(NORMAL_LINEAR_DAMP, DRIFT_LINEAR_DAMP, _grip_blend)

	# Boost FSM (mirrors server) — uses horizontal forward. Sustain force only
	# applies while grounded.
	_update_boost_fsm(horiz_forward, speed, star_drift_input, delta, grounded)
	_was_star_drift_pressed = star_drift_input

	_tick_audio(speed, throttle, drift, true, delta)

	var snapped := false
	if self._server_pos_valid:
		if self.global_position.distance_to(self._server_pos) > RESPAWN_SNAP_DIST:
			# Large jump (server respawn after a fall): snap instead of slow-lerping,
			# and kill momentum so retained fall velocity can't tunnel us back
			# through the floor and end up under the map.
			self.global_position = self._server_pos
			self.linear_velocity = Vector3.ZERO
			self.angular_velocity = Vector3.ZERO
			snapped = true
		else:
			self.global_position = self.global_position.lerp(self._server_pos, POS_SOFT_RATE)

	if self._server_rot_valid:
		if snapped:
			self.quaternion = self._server_rot
		else:
			self.quaternion = self.quaternion.slerp(self._server_rot, ROT_SOFT_RATE)

	if steer != 0.0:
		self.delta_rot_wheel -= steer * delta * 120
		self.delta_rot_wheel = clamp(self.delta_rot_wheel, -LIMIT_ROT_WHEEL, LIMIT_ROT_WHEEL)
	else:
		self.delta_rot_wheel = lerp(self.delta_rot_wheel, 0.0, delta * 10)
	if _wheel_fl:
		_wheel_fl.rotation_degrees.y = self.init_rot_wheel + self.delta_rot_wheel
	if _wheel_fr:
		_wheel_fr.rotation_degrees.y = self.init_rot_wheel + self.delta_rot_wheel

	self.network_timer += delta
	if self.network_timer >= NETWORK_SEND_INTERVAL:
		self.network_timer = 0.0
		self.network.send({
			"State": {
				"throttle":    throttle,
				"steer_left":  max(-steer, 0.0),
				"steer_right": max(steer, 0.0),
				"star_drift":  star_drift_input
			}
		})

func apply_server_correction(server_pos: Vector3, server_rot: Quaternion) -> void:
	self._server_pos       = server_pos
	self._server_pos_valid = true
	self._server_rot       = server_rot
	self._server_rot_valid = true

## Mirror the server's boost-pad nudge locally (lobby.rs handle_boost_pads) so the
## client predicts the speed jump. Without this, the un-predicted server velocity
## spike shows up only via position reconciliation → visible back/forth judder,
## worst when crossing two pads in a row.
func apply_pad_boost(strength: float) -> void:
	if self.freeze:
		return
	var v := self.linear_velocity
	var horiz := Vector3(v.x, 0.0, v.z)
	var hs := horiz.length()
	if hs > 0.1:
		var bv := horiz / hs * strength
		self.linear_velocity = Vector3(v.x + bv.x, v.y, v.z + bv.z)
		boost_flash = true

func _vec3_slerp_clamped(from: Vector3, to: Vector3, max_angle: float) -> Vector3:
	var d = clampf(from.dot(to), -1.0, 1.0)
	var angle = acos(d)
	if angle < 1e-4 or max_angle <= 0.0:
		return from
	var t := minf(max_angle / angle, 1.0)
	var sin_a := sin(angle)
	if absf(sin_a) < 1e-4:
		return from
	var a := sin((1.0 - t) * angle) / sin_a
	var b := sin(t * angle) / sin_a
	return from * a + to * b

func try_rocket_start(delta_t: float) -> void:
	if absf(delta_t) > ROCKET_WINDOW_S:
		return
	var quality := 1.0 - absf(delta_t) / ROCKET_WINDOW_S
	var forward_dir := -self.transform.basis.z
	var horiz_forward := Vector3(forward_dir.x, 0.0, forward_dir.z)
	var hf_len := horiz_forward.length()
	if hf_len > 1e-4:
		horiz_forward /= hf_len
	else:
		horiz_forward = forward_dir
	var current := self.linear_velocity.length()
	_boost_peak_speed = maxf(current, DRIFT_MIN_SPEED) + ROCKET_BONUS * quality
	self.linear_velocity = horiz_forward * _boost_peak_speed
	_boost_state = BoostState.BOOSTING
	_boost_t_remaining = BOOST_DURATION
	drift_charge = 0.0
	boost_flash = true

func _update_boost_fsm(forward_dir: Vector3, speed: float, star_drift_input: bool, delta: float, grounded: bool = true) -> void:
	if grounded and star_drift_input and speed > DRIFT_MIN_SPEED:
		drift_charge = minf(drift_charge + BOOST_CHARGE_RATE * delta, 1.0)
	elif _boost_state != BoostState.PENDING:
		drift_charge = maxf(drift_charge - BOOST_CHARGE_DECAY * delta, 0.0)

	var just_released := _was_star_drift_pressed and not star_drift_input

	match _boost_state:
		BoostState.IDLE:
			if just_released and drift_charge >= BOOST_CHARGE_MIN:
				_boost_state = BoostState.PENDING
				_boost_pending_t = BOOST_PENDING_TIMEOUT
		BoostState.PENDING:
			_boost_pending_t -= delta
			if star_drift_input:
				_boost_state = BoostState.IDLE
			elif _boost_pending_t <= 0.0:
				_boost_state = BoostState.IDLE
			elif grounded and speed > 1.0:
				var vel_dir := self.linear_velocity / speed
				if vel_dir.dot(forward_dir) >= BOOST_ALIGN_THRESHOLD_COS:
					var base = maxf(speed, DRIFT_MIN_SPEED)
					_boost_peak_speed = base + BOOST_PEAK_BONUS * drift_charge
					var new_speed = maxf(_boost_peak_speed, speed)
					self.linear_velocity = forward_dir * new_speed
					_boost_state = BoostState.BOOSTING
					_boost_t_remaining = BOOST_DURATION
					drift_charge = 0.0
					boost_flash = true
		BoostState.BOOSTING:
			_boost_t_remaining -= delta
			if _boost_t_remaining <= 0.0:
				_boost_state = BoostState.IDLE
			else:
				var fwd_speed := forward_dir.dot(self.linear_velocity)
				if grounded and fwd_speed < _boost_peak_speed:
					apply_central_force(forward_dir * BOOST_SUSTAIN_FORCE)
