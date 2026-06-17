extends RigidBody3D

# Speeds halved across the board to fit the tracks (see lobby.rs). All forces,
# lateral-grip caps, thresholds and boost magnitudes scale together so the FEEL is
# preserved at half pace. MUST match the server.
# Master pace multiplier: forces, launch & boost speeds and the lateral-grip caps
# all derive from this one knob. ×4/3 bumps the whole pace by a third. MUST match
# the server (lobby.rs SPEED_SCALE).
const SPEED_SCALE        := 4.0 / 3.0
const THROTTLE_FORCE     := 8_500.0 * SPEED_SCALE
const REVERSE_FORCE      := 2_500.0 * SPEED_SCALE
const BRAKE_FORCE        := 4_000.0 * SPEED_SCALE
const BRAKE_MIN_SPEED    := 0.5
const MOTION_DIRECTION_EPSILON := 0.25
const MAX_TURN_RATE_GRIP := 1.2
const MAX_TURN_RATE_DRIFT := 2.4    # softer than before (was 3.2): a gentler rotation
const STEER_P_GAIN       := 25_000.0
# Keyboard steering is digital (-1/0/1); ramping the effective steer toward the
# raw input smooths turn-in and gives a natural return-to-centre instead of a
# snap. The smoothed value is what we both drive locally and send to the server,
# so prediction and authority stay in lockstep. ~0.13 s from centre to full lock.
const STEER_SMOOTH_RATE  := 8.0
# Lateral traction model — MUST stay in lockstep with the server (lobby.rs
# handling_step). Sideways velocity is cancelled up to a capped lateral
# acceleration, so the achievable turn rate is lat_accel/speed: pure grip washes
# out at racing pace (the "anomaly"), while a drift's lower cap lets the slide
# live. The break-loose collapse is gated to grip only.
const GRIP_LAT_ACCEL     := 9.0 * SPEED_SCALE   # m/s² — holds gentle/slow turns, washes at speed
const DRIFT_LAT_ACCEL    := 3.0 * SPEED_SCALE   # m/s² — low, so the drift slide lags and lives
# Falling into drift couples ANGLE and EFFORT (see _drift_enter_threshold_deg):
# gentle steering must build the full SLIP_BREAK_DEG of slide, cranking hard at
# speed drops the bar to SLIP_BREAK_HARD_DEG. Mirrors lobby.rs.
const SLIP_BREAK_DEG     := 18.0    # gentle steering: slip needed to fall into drift
const SLIP_BREAK_HARD_DEG := 5.0    # full lock at speed: falls in almost at once
const DRIFT_EFFORT_SPEED_REF := 6.0   # speed (m/s) at which the effort term saturates
const SLIP_EXIT_DEG      := 4.0     # slide settles below this (key up) → back to grip
# Manual-drift initiation flick: drift key + a direction together snaps the yaw rate
# hard at once for a sharp deliberate turn-in. Mirrors lobby.rs.
const DRIFT_FLICK_RATE   := 3.6     # yaw rate (rad/s) the flick snaps to on the press edge
const NORMAL_LINEAR_DAMP := 0.3
const DRIFT_LINEAR_DAMP  := 0.18
const DRIFT_MIN_SPEED    := 1.5
# Drift is eased in/out via a 0→1 grip-blend instead of a hard switch, so the
# slide builds and releases smoothly — "controlled loss of control".
const GRIP_BLEND_RATE    := 6.0

# Charge fills at full rate up to BOOST_CHARGE_KNEE (~2/3), then tapers to
# BOOST_CHARGE_TOP_FACTOR of that rate toward full — so maxing the bar takes a
# long, committed drift. Mirrors the server (lobby.rs boost_charge_increment).
const BOOST_CHARGE_RATE   := 0.18   # slow base fill
const BOOST_CHARGE_ANGLE_RATE := 0.6   # extra fill rate at a full-angle slide
const BOOST_CHARGE_ANGLE_REF_DEG := 35.0  # slip angle (°) at which the angle term saturates
const BOOST_CHARGE_KNEE   := 0.667  # first 2/3 fill normally
const BOOST_CHARGE_TOP_FACTOR := 0.25  # last third is degressive (down to 25% rate)
const BOOST_CHARGE_DECAY  := 2.0
const BOOST_CHARGE_MIN    := 0.15
const BOOST_PEAK_BONUS    := 11.5 * SPEED_SCALE   # drift-boost overshoot above cruise
const BOOST_DURATION      := 1.5
const BOOST_ALIGN_THRESHOLD_COS := 0.9781476  # cos(12°)
const BOOST_PENDING_TIMEOUT := 1.5
const BOOST_SUSTAIN_FORCE  := 16_500.0 * SPEED_SCALE   # scales with the drive force

# Launch (rocket start) — server-authoritative; predicted here with the same rule.
# A perfect launch (throttle down at GO) reaches LAUNCH_SPEED (≈ cruise + overshoot);
# quality fades over the window. Mirrors lobby.rs LAUNCH_SPEED / LAUNCH_WINDOW.
const ROCKET_WINDOW_S := 0.25
const LAUNCH_SPEED    := 32.0 * SPEED_SCALE

const PAD_BOOST_SCALE := 0.5   # mirror lobby.rs: scale track pad boosts to half speed

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
var _was_drift_state := false
var _boost_state: int = BoostState.IDLE
var _boost_t_remaining: float = 0.0
var _boost_pending_t: float = 0.0
var _boost_peak_speed: float = 0.0
var _reversing := false
var _grip_blend: float = 0.0  # 0 = full grip, 1 = full drift (eased)
var _drift_state: bool = false  # drift STATE, decoupled from the key (key forces it; hard grip slides into it)
var _steer_input: float = 0.0  # smoothed steering axis (see STEER_SMOOTH_RATE)
var _dbg_slip_deg: float = 0.0  # signed slip angle (velocity vs heading), for the debug HUD

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

	# Slip angle (heading vs velocity, horizontal) feeds both the drift-state
	# machine and the HUD. slip_mag mirrors the server's unsigned 0..90° measure;
	# _dbg_slip_deg keeps a signed value for the F3 readout.
	var v_h0 := Vector3(self.linear_velocity.x, 0.0, self.linear_velocity.z)
	var h_speed0 := v_h0.length()
	var slip_mag := 0.0
	if h_speed0 > 0.5:
		var v_fwd0 := v_h0.dot(horiz_forward)
		var v_lat0 := (v_h0 - horiz_forward * v_fwd0).length()
		slip_mag = rad_to_deg(atan2(v_lat0, absf(v_fwd0)))
		var vd0 := v_h0 / h_speed0
		_dbg_slip_deg = rad_to_deg(atan2(horiz_forward.cross(vd0).y, horiz_forward.dot(vd0)))
	else:
		_dbg_slip_deg = 0.0

	# Drift STATE, decoupled from the key: the drift key forces it on, but turning
	# too hard on grip slides into it past the break angle (Rocket-Racing style); it
	# releases once the slide settles below SLIP_EXIT with the key up. _grip_blend
	# then eases toward this state. Mirrors the server (lobby.rs).
	var enter_thresh := _drift_enter_threshold_deg(absf(steer), speed)
	var drift_capable := grounded and speed > DRIFT_MIN_SPEED
	if drift_capable and (star_drift_input or slip_mag > enter_thresh):
		_drift_state = true
	elif not drift_capable or slip_mag < SLIP_EXIT_DEG:
		_drift_state = false
	var drift_target := 1.0 if _drift_state else 0.0
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

	# Manual-drift flick: drift key + a direction together snaps the yaw rate hard at
	# once (a sharp deliberate turn-in). Press edge only. Mirrors the server (lobby.rs).
	var drift_just_pressed := star_drift_input and not _was_star_drift_pressed
	if drift_just_pressed and grounded and speed > DRIFT_MIN_SPEED and absf(effective_steer) > 0.1:
		var av := self.angular_velocity
		av.y = -signf(effective_steer) * DRIFT_FLICK_RATE
		self.angular_velocity = av

	# Lateral grip: cancel sideways velocity up to a capped lateral acceleration,
	# so grip washes out at speed while a drift's slide persists. Y is preserved so
	# gravity and ramp impulses still apply. Mirrors the server's handling_step
	# (lobby.rs) — keep the two identical. The "fall into drift" is handled by the
	# drift-state machine raising _grip_blend, which drops lat_accel to drift's.
	var v := self.linear_velocity
	if grounded and h_speed0 > 0.5 and not self._reversing:
		var v_fwd := v_h0.dot(horiz_forward)
		var lat := v_h0 - horiz_forward * v_fwd
		var v_lat := lat.length()
		var lat_accel := lerpf(GRIP_LAT_ACCEL, DRIFT_LAT_ACCEL, _grip_blend)
		if v_lat > 1e-6:
			var keep := maxf(1.0 - lat_accel * delta / v_lat, 0.0)
			lat *= keep
		var new_h := horiz_forward * v_fwd + lat
		self.linear_velocity = Vector3(new_h.x, v.y, new_h.z)

	self.linear_damp = lerpf(NORMAL_LINEAR_DAMP, DRIFT_LINEAR_DAMP, _grip_blend)

	# Boost FSM (mirrors server) — uses horizontal forward. Sustain force only
	# applies while grounded.
	_update_boost_fsm(horiz_forward, speed, _drift_state, slip_mag, delta, grounded)
	_was_star_drift_pressed = star_drift_input
	_was_drift_state = _drift_state

	_tick_audio(speed, throttle, _drift_state, true, delta)

	var did_snap := false
	if self._server_pos_valid:
		if self.global_position.distance_to(self._server_pos) > RESPAWN_SNAP_DIST:
			# Large jump (server respawn after a fall): snap instead of slow-lerping,
			# and kill momentum so retained fall velocity can't tunnel us back
			# through the floor and end up under the map.
			self.global_position = self._server_pos
			self.linear_velocity = Vector3.ZERO
			self.angular_velocity = Vector3.ZERO
			did_snap = true
		else:
			self.global_position = self.global_position.lerp(self._server_pos, POS_SOFT_RATE)

	if self._server_rot_valid:
		if did_snap:
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

## Live driving telemetry for the F3 debug HUD (see game.gd). Read-only snapshot.
func get_telemetry() -> Dictionary:
	var state_names := ["idle", "pending", "BOOST"]
	return {
		"speed": self.linear_velocity.length(),
		"slip_deg": _dbg_slip_deg,
		"yaw_rate": self.angular_velocity.y,
		"grip_blend": _grip_blend,
		"charge": drift_charge,
		"boost": state_names[_boost_state],
		"grounded": _ground_ray.is_colliding(),
	}

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
		var bv := horiz / hs * strength * PAD_BOOST_SCALE
		self.linear_velocity = Vector3(v.x + bv.x, v.y, v.z + bv.z)
		boost_flash = true

## Client prediction of the server-authoritative launch. `delta_t` = press time
## minus GO; holding through GO counts as 0 (perfect). Propels the car to
## LAUNCH_SPEED·quality. Returns quality in 0..1, or -1.0 if the window was missed
## (no boost). The HUD shows this as a score.
func try_rocket_start(delta_t: float) -> float:
	var t := maxf(delta_t, 0.0)  # held through GO = 0
	var quality := clampf(1.0 - t / ROCKET_WINDOW_S, 0.0, 1.0)
	if quality <= 0.0:
		return -1.0
	var forward_dir := -self.transform.basis.z
	var horiz_forward := Vector3(forward_dir.x, 0.0, forward_dir.z)
	var hf_len := horiz_forward.length()
	if hf_len > 1e-4:
		horiz_forward /= hf_len
	else:
		horiz_forward = forward_dir
	var target := LAUNCH_SPEED * quality
	if target > horiz_forward.dot(self.linear_velocity):
		_boost_peak_speed = target
		self.linear_velocity = horiz_forward * target + Vector3(0.0, self.linear_velocity.y, 0.0)
		_boost_state = BoostState.BOOSTING
		_boost_t_remaining = BOOST_DURATION
		boost_flash = true
	return quality

# Slip angle (degrees) at which pure grip falls into the drift state, coupling
# angle with EFFORT: steer_effort is |steer| in 0..1, scaled by speed. Gentle
# steering needs the full slide; cranking hard at speed snaps in early. Mirrors
# the server (lobby.rs drift_enter_threshold_deg).
func _drift_enter_threshold_deg(steer_effort: float, speed: float) -> float:
	var speed_factor := clampf((speed - DRIFT_MIN_SPEED) / (DRIFT_EFFORT_SPEED_REF - DRIFT_MIN_SPEED), 0.0, 1.0)
	var effort := clampf(steer_effort, 0.0, 1.0) * speed_factor
	return SLIP_BREAK_DEG + (SLIP_BREAK_HARD_DEG - SLIP_BREAK_DEG) * effort

# One tick of drift-boost charge: full rate over the first ~2/3 of the bar, then
# tapering through the final third so topping it off demands a long, sustained
# drift. Mirrors the server (lobby.rs boost_charge_increment).
func _boost_charge_increment(charge: float, slip_deg: float, delta: float) -> float:
	var taper := 1.0
	if charge >= BOOST_CHARGE_KNEE:
		var f := (charge - BOOST_CHARGE_KNEE) / (1.0 - BOOST_CHARGE_KNEE)
		taper = lerpf(1.0, BOOST_CHARGE_TOP_FACTOR, f)
	# Slow base fill, faster the more sideways the car is (bigger slip angle).
	var angle01 := clampf(absf(slip_deg) / BOOST_CHARGE_ANGLE_REF_DEG, 0.0, 1.0)
	var rate := BOOST_CHARGE_RATE + BOOST_CHARGE_ANGLE_RATE * angle01
	return minf(charge + rate * taper * delta, 1.0)

func _update_boost_fsm(forward_dir: Vector3, speed: float, drifting: bool, slip_deg: float, delta: float, grounded: bool = true) -> void:
	# Charge accumulates whenever drifting (the state), however entered — even a
	# slid-in drift with no key held. Arms when the drift ends. Mirrors lobby.rs.
	if grounded and drifting and speed > DRIFT_MIN_SPEED:
		drift_charge = _boost_charge_increment(drift_charge, slip_deg, delta)
	elif _boost_state != BoostState.PENDING:
		drift_charge = maxf(drift_charge - BOOST_CHARGE_DECAY * delta, 0.0)

	var drift_just_ended := _was_drift_state and not drifting

	match _boost_state:
		BoostState.IDLE:
			if drift_just_ended and drift_charge >= BOOST_CHARGE_MIN:
				_boost_state = BoostState.PENDING
				_boost_pending_t = BOOST_PENDING_TIMEOUT
		BoostState.PENDING:
			_boost_pending_t -= delta
			if drifting:
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
