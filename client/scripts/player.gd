extends RigidBody3D

# Physics tuning shared with the server (authority). The VALUES are the single
# source of truth in tuning.txt (repo root), generated into tuning.gd and the Rust
# server/src/tuning.rs. Edit tuning.txt, then run `py scripts/gen_tuning.py`. The
# re-exports below keep the local names so the rest of player.gd is untouched; only
# their values come from Tuning. Client-only knobs keep a literal value.
const Tuning = preload("res://scripts/tuning.gd")
var PACE_SCALE        := Tuning.PACE_SCALE
var THROTTLE_FORCE     := Tuning.THROTTLE_FORCE
var REVERSE_FORCE      := Tuning.REVERSE_FORCE
var BRAKE_FORCE        := Tuning.BRAKE_FORCE
var BRAKE_MIN_SPEED    := Tuning.BRAKE_MIN_SPEED
var MOTION_DIRECTION_EPSILON := Tuning.MOTION_DIRECTION_EPSILON
var MAX_TURN_RATE_GRIP := Tuning.MAX_TURN_RATE_GRIP
var MAX_TURN_RATE_DRIFT := Tuning.MAX_TURN_RATE_DRIFT
var STEER_P_GAIN       := Tuning.STEER_P_GAIN
# Client-only: keyboard steering is smoothed locally and the SMOOTHED value is sent
# to the server, so this isn't a shared physics constant (~0.13 s to full lock).
const STEER_SMOOTH_RATE  := 8.0
var GRIP_LAT_ACCEL     := Tuning.GRIP_LAT_ACCEL
var DRIFT_REDIRECT_RATE := Tuning.DRIFT_REDIRECT_RATE
var DRIFT_SPEED_PENALTY := Tuning.DRIFT_SPEED_PENALTY
var SLIP_BREAK_DEG     := Tuning.SLIP_BREAK_DEG
var SLIP_BREAK_HARD_DEG := Tuning.SLIP_BREAK_HARD_DEG
var DRIFT_EFFORT_SPEED_REF := Tuning.DRIFT_EFFORT_SPEED_REF
var SLIP_EXIT_DEG      := Tuning.SLIP_EXIT_DEG
var DRIFT_FLICK_RATE   := Tuning.DRIFT_FLICK_RATE
var DRIFT_FLICK_BLEND  := Tuning.DRIFT_FLICK_BLEND
var SPIN_GUARD_DEG     := Tuning.SPIN_GUARD_DEG
var SPIN_LIMIT_DEG     := Tuning.SPIN_LIMIT_DEG
var SPIN_RESTORE_RATE  := Tuning.SPIN_RESTORE_RATE
var UPRIGHT_GAIN       := Tuning.UPRIGHT_GAIN
var UPRIGHT_DAMP       := Tuning.UPRIGHT_DAMP
var GROUND_ALIGN_MIN_NY := Tuning.GROUND_ALIGN_MIN_NY
var SUSP_REST_LEN      := Tuning.SUSP_REST_LEN
var SUSP_MAX_LEN       := Tuning.SUSP_MAX_LEN
var SUSP_STIFFNESS     := Tuning.SUSP_STIFFNESS
var SUSP_DAMP          := Tuning.SUSP_DAMP
var AIRROLL_RANGE        := Tuning.AIRROLL_RANGE
var AIRROLL_AIM_LATERAL  := Tuning.AIRROLL_AIM_LATERAL
var AIRROLL_PULL_SPEED   := Tuning.AIRROLL_PULL_SPEED
var AIRROLL_RECOVER_TIME := Tuning.AIRROLL_RECOVER_TIME
var AIRROLL_RECOVER_GAIN := Tuning.AIRROLL_RECOVER_GAIN
var AIRROLL_RECOVER_DAMP := Tuning.AIRROLL_RECOVER_DAMP
var AIRROLL_SPIN         := Tuning.AIRROLL_SPIN
var AIRROLL_DODGE_SPEED  := Tuning.AIRROLL_DODGE_SPEED
var NORMAL_LINEAR_DAMP := Tuning.NORMAL_LINEAR_DAMPING
var DRIFT_LINEAR_DAMP  := Tuning.DRIFT_LINEAR_DAMPING
var DRIFT_MIN_SPEED    := Tuning.DRIFT_MIN_SPEED
var DRIFT_FLOOR_SPEED  := Tuning.DRIFT_FLOOR_SPEED
var COYOTE_GROUND_SECS := Tuning.COYOTE_GROUND_SECS
var GRIP_BLEND_RATE    := Tuning.GRIP_BLEND_RATE
var GRIP_BLEND_EXIT_RATE := Tuning.GRIP_BLEND_EXIT_RATE
var JUMP_SPEED         := Tuning.JUMP_SPEED

var BOOST_CHARGE_RATE   := Tuning.BOOST_CHARGE_RATE
var BOOST_CHARGE_ANGLE_RATE := Tuning.BOOST_CHARGE_ANGLE_RATE
var BOOST_CHARGE_ANGLE_REF_DEG := Tuning.BOOST_CHARGE_ANGLE_REF_DEG
var BOOST_CHARGE_KNEE   := Tuning.BOOST_CHARGE_KNEE
var BOOST_CHARGE_TOP_FACTOR := Tuning.BOOST_CHARGE_TOP_FACTOR
var BOOST_CHARGE_DECAY  := Tuning.BOOST_CHARGE_DECAY
var BOOST_CHARGE_MIN    := Tuning.BOOST_CHARGE_MIN
var BOOST_PEAK_BONUS    := Tuning.BOOST_PEAK_BONUS
var BOOST_DURATION      := Tuning.BOOST_DURATION
var BOOST_ALIGN_THRESHOLD_COS := Tuning.BOOST_ALIGN_THRESHOLD_COS
var BOOST_PENDING_TIMEOUT := Tuning.BOOST_PENDING_TIMEOUT
var BOOST_SUSTAIN_FORCE  := Tuning.BOOST_SUSTAIN_FORCE

var CRUISE_SPEED        := Tuning.CRUISE_SPEED
var TURBO_PEAK_SPEED    := Tuning.TURBO_PEAK_SPEED
var TURBO_FORCE         := Tuning.TURBO_FORCE
var TURBO_CHARGE_RATE   := Tuning.TURBO_CHARGE_RATE
var TURBO_CHARGE_ANGLE_RATE := Tuning.TURBO_CHARGE_ANGLE_RATE
var TURBO_DRAIN_RATE    := Tuning.TURBO_DRAIN_RATE

# Launch (rocket start): the client predicts the server's rule. ROCKET_* keep
# their local names but source LAUNCH_* values from Tuning.
var ROCKET_WINDOW_S := Tuning.LAUNCH_WINDOW
var ROCKET_SHARPNESS := Tuning.LAUNCH_SHARPNESS
var LAUNCH_SPEED    := Tuning.LAUNCH_SPEED

var PAD_BOOST_SCALE := Tuning.PAD_BOOST_SCALE

const POS_SOFT_RATE := 0.08
const ROT_SOFT_RATE := 0.08
const RESPAWN_SNAP_DIST := 12.0  # server pos jumps beyond this → teleport, not lerp

const ENGINE_IDLE_PITCH := 0.85   # low, round idle
const ENGINE_MAX_PITCH  := 1.6    # capped so the engine never whines at speed
const ENGINE_SPEED_REF  := 42.0   # speed (m/s) mapped to peak pitch / volume
const ENGINE_IDLE_DB    := -16.0
const ENGINE_LOUD_DB    := -3.0
const DRIFT_DB          := -16.0
const AUDIO_SILENT_DB   := -60.0

enum BoostState { IDLE, PENDING, BOOSTING }

var drift_charge: float = 0.0
var boost_flash: bool = false
var _was_drift_pressed := false
var _was_drift_state := false
var _boost_state: int = BoostState.IDLE
var _boost_t_remaining: float = 0.0
var _boost_pending_t: float = 0.0
var _boost_peak_speed: float = 0.0
var _turbo_charge: float = 0.0  # second bar, filled by drifting, spent via the Turbo key
var _turbo_active: bool = false
var _reversing := false
var _was_jump_pressed := false  # edge-detect for the grounded jump
var _prev_air_roll := false  # edge-detect for the air-roll action
var _air_recover_t: float = 0.0  # seconds left in an active surface-recover reorientation
var _air_recover_n := Vector3.UP  # target up-normal the recover is rotating toward
var _air_time: float = 0.0  # seconds since the ground ray last hit, for coyote grace
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
var horn_id: String = Game.DEFAULT_HORN

var _engine_audio: AudioStreamPlayer = null
var _drift_audio: AudioStreamPlayer = null
var _boost_audio: AudioStreamPlayer = null  # one-shot "ptew" on drift boost
var _horn_audio: AudioStreamPlayer = null  # one-shot honk on the Horn input
var _horn_pending := false  # latched on honk, sent once in the next state packet
var _engine_pitch := ENGINE_IDLE_PITCH
var _engine_db := AUDIO_SILENT_DB
var _drift_db := AUDIO_SILENT_DB

var network_timer := 0.0
const NETWORK_SEND_INTERVAL := 0.05
# Respawn requires a sustained hold (any bound key/button): the input must be held
# for RESPAWN_HOLD_SECS before it fires. `_respawn_hold_time` accumulates while held;
# crossing the threshold latches `_respawn_pending`, sent once on the next state
# packet (so it's never dropped between 50 ms sends). The server edge-detects it and
# teleports the car to its last checkpoint.
const RESPAWN_HOLD_SECS := 1.0
var _respawn_hold_time: float = 0.0
var _respawn_pending := false

@onready var network = get_tree().get_first_node_in_group("Network")
@onready var _game := get_node("/root/Root/Game")
@onready var _ground_ray: RayCast3D = $GroundRay
@onready var _camera: Camera3D = $Camera

func _ready() -> void:
	self.angular_damp = 0.5
	self.linear_damp  = NORMAL_LINEAR_DAMP
	# Body props from tuning.txt (mirror the server's MassProperties): heavy + high
	# pitch/roll inertia + low CoM so the car is planted and resists tipping.
	self.mass = Tuning.MASS
	self.inertia = Vector3(Tuning.INERTIA_X, Tuning.INERTIA_Y, Tuning.INERTIA_Z)
	self.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	self.center_of_mass = Vector3(0.0, Tuning.COM_Y, 0.0)
	# World gravity is configured in project.godot (which can't reference Tuning);
	# guard against the two drifting apart.
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", Tuning.GRAVITY))
	if not is_equal_approx(g, Tuning.GRAVITY):
		push_warning("Gravity drift: project=%s vs Tuning.GRAVITY=%s" % [g, Tuning.GRAVITY])
	_load_car_body()
	_setup_audio()

func _setup_audio() -> void:
	_engine_audio = AudioStreamPlayer.new()
	_engine_audio.stream = Game.make_engine_stream(car_model_id)
	_engine_audio.pitch_scale = ENGINE_IDLE_PITCH
	_engine_audio.volume_db = AUDIO_SILENT_DB
	_engine_audio.bus = Audio.BUS_SFX
	add_child(_engine_audio)
	_engine_audio.play()

	_drift_audio = AudioStreamPlayer.new()
	_drift_audio.stream = Game.make_drift_stream()
	_drift_audio.volume_db = AUDIO_SILENT_DB
	_drift_audio.bus = Audio.BUS_SFX
	add_child(_drift_audio)
	_drift_audio.play()

	# One-shot "ptew" fired on each drift boost (played from the start on demand).
	_boost_audio = AudioStreamPlayer.new()
	_boost_audio.stream = Game.make_boost_stream()
	_boost_audio.volume_db = -8.0
	_boost_audio.bus = Audio.BUS_SFX
	add_child(_boost_audio)

	# Player-chosen horn (see the Pilot tab), honked on the Horn input during a race.
	_horn_audio = AudioStreamPlayer.new()
	_horn_audio.stream = load(Game.get_horn(horn_id)["path"])
	_horn_audio.volume_db = -3.0
	_horn_audio.bus = Audio.BUS_HORN
	add_child(_horn_audio)

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
	# Soft contact shadow under the car (ignores the car's own collider in its ray).
	var blob := preload("res://scripts/blob_shadow.gd").new()
	blob.setup(self, self.get_rid())
	add_child(blob)
	_wheel_fl = body.find_child(Game.CAR_WHEEL_FL, true, false)
	_wheel_fr = body.find_child(Game.CAR_WHEEL_FR, true, false)
	init_rot_wheel = _wheel_fl.rotation_degrees.y if _wheel_fl else 0.0

func _physics_process(delta: float) -> void:
	if self._game.mode != Game.Mode.IN_RACE:
		# During the on-track countdown the car is unfrozen but undriven: the
		# suspension spring settles it to ride height (so it's already there at GO —
		# no pop) while we zero horizontal + angular velocity each tick so it can't
		# drift or spin (mirrors the server). A no-op while frozen (intermission).
		if not self.freeze:
			var susp := _compute_suspension()
			if not susp.is_empty():
				apply_central_force(susp["force"] as Vector3)
			self.linear_velocity = Vector3(0.0, self.linear_velocity.y, 0.0)
			self.angular_velocity = Vector3.ZERO
		_tick_audio(0.0, false, false, false, delta)
		return

	# No freeze on pause: in a fully-multiplayer game the world can't stop, so the
	# pause menu is just an overlay — the car keeps simulating and driving while it's
	# open (server stays authoritative regardless).

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
	var drift_input := Input.is_action_pressed("Drift")
	var turbo_input := Input.is_action_pressed("Turbo")
	# Honk: play our own horn immediately (no latency), and latch a flag so the next
	# state packet tells the server to broadcast it to everyone else.
	if Input.is_action_just_pressed("Horn"):
		if _horn_audio:
			_horn_audio.play()
		_horn_pending = true
	var jump_input := Input.is_action_pressed("Jump")
	var air_roll_input := Input.is_action_pressed("AirRoll")
	# The air-roll aim is VIEW-relative (independent of the car's tumbling): use the
	# camera's follow-yaw, and send it so the server reproduces the same aim.
	var view_yaw: float = float(_camera.get("_cam_yaw")) if _camera else self.global_rotation.y
	# Respawn fires only after a 2 s sustained hold.
	if Input.is_action_pressed("Respawn"):
		var prev_hold := _respawn_hold_time
		_respawn_hold_time += delta
		if prev_hold < RESPAWN_HOLD_SECS and _respawn_hold_time >= RESPAWN_HOLD_SECS:
			_respawn_pending = true
	else:
		_respawn_hold_time = 0.0

	var speed := self.linear_velocity.length()

	# Airborne: the wheels have no grip, so driving inputs (throttle, reverse,
	# brake, drift, velocity re-alignment, boost) are disabled. Only orientation —
	# the yaw steering torque below — stays available so the player can line the
	# car up for landing. A short coyote grace keeps the car "grounded" for a beat
	# after the ray drops so a bump/ramp seam can't blip those inputs off (mirrors
	# the server, lobby.rs).
	var susp := _compute_suspension()
	var raw_grounded := not susp.is_empty()
	if raw_grounded:
		_air_time = 0.0
	else:
		_air_time += delta
	var grounded := raw_grounded or _air_time < COYOTE_GROUND_SECS

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
	var drift_capable := grounded and speed > DRIFT_FLOOR_SPEED
	if drift_capable and (drift_input or slip_mag > enter_thresh):
		_drift_state = true
	elif not drift_capable or slip_mag < SLIP_EXIT_DEG:
		_drift_state = false
	var drift_target := 1.0 if _drift_state else 0.0
	var blend_rate := GRIP_BLEND_RATE if drift_target > _grip_blend else GRIP_BLEND_EXIT_RATE
	_grip_blend = lerpf(_grip_blend, drift_target, clampf(delta * blend_rate, 0.0, 1.0))

	var forward_speed := forward_dir.dot(self.linear_velocity)
	if forward_speed <= -MOTION_DIRECTION_EPSILON:
		self._reversing = true
	elif forward_speed >= MOTION_DIRECTION_EPSILON:
		self._reversing = false
	elif throttle:
		self._reversing = false  # throttle while nearly stopped → go forward
	elif drift_input and not throttle:
		self._reversing = true

	if grounded:
		if throttle and not self._reversing:
			apply_central_force(forward_dir * THROTTLE_FORCE)
		if not throttle and self._reversing:
			apply_central_force(-forward_dir * REVERSE_FORCE)

		if drift_input and not throttle and forward_speed > BRAKE_MIN_SPEED:
			var bv := self.linear_velocity
			if bv.length() > 0.01:
				apply_central_force(-bv.normalized() * BRAKE_FORCE)

	# Orientation is always allowed — even airborne.
	var effective_steer := -steer if self._reversing else steer
	var max_turn   := lerpf(MAX_TURN_RATE_GRIP, MAX_TURN_RATE_DRIFT, _grip_blend)
	var target_yaw := -effective_steer * max_turn
	# Anti-spin: bias the yaw target back toward the velocity once the slide is deep,
	# so hard drifting / tight turns can't whip past control into a spin-out. Gated to
	# the same grounded, moving case as the server's handling_step (slip_mag already
	# uses h_speed0 > 0.5), and uses the same cross-product sign → identical effect.
	if grounded and not self._reversing:
		var cross_y := horiz_forward.x * self.linear_velocity.z - horiz_forward.z * self.linear_velocity.x
		var excess := clampf((slip_mag - SPIN_GUARD_DEG) / (SPIN_LIMIT_DEG - SPIN_GUARD_DEG), 0.0, 1.0)
		target_yaw -= signf(cross_y) * SPIN_RESTORE_RATE * excess
	var yaw_error  := target_yaw - self.angular_velocity.y
	apply_torque(Vector3.UP * yaw_error * STEER_P_GAIN)

	# Manual-drift flick: drift key + a direction snaps the yaw rate hard at once (a
	# sharp turn-in). Fires to INITIATE a drift, or — while already drifting — to flick
	# the OTHER way: a counter that de-drifts / flips the slide (so drift+opposite
	# re-steers out of a drift). A same-side re-flick mid-drift stays blocked so rapid
	# tap-tap can't re-slam the yaw into a runaway spin. Applied about the car's own up
	# axis (preserving pitch/roll) so a flick on a banked surface stays a pure yaw and
	# can't flip the car. Mirrors the server (lobby.rs drift_flick_angvel).
	var drift_just_pressed := drift_input and not _was_drift_pressed
	if drift_just_pressed and grounded and speed > DRIFT_FLOOR_SPEED and absf(effective_steer) > 0.1:
		var up := self.global_transform.basis.y
		var cur := self.angular_velocity
		var flick_target := -signf(effective_steer) * DRIFT_FLICK_RATE
		var counter_flick := cur.dot(up) * flick_target < 0.0
		if not _was_drift_state or counter_flick:
			var perp := cur - up * cur.dot(up)
			# Ease toward the flick rate instead of snapping the whole way (mirrors server).
			self.angular_velocity = perp + up * lerpf(cur.dot(up), flick_target, DRIFT_FLICK_BLEND)

	# Jump: a grounded hop on the rising edge of the Jump input — set the vertical
	# velocity, keeping horizontal motion (mirrors the server, lobby.rs).
	if jump_input and not _was_jump_pressed and grounded:
		self.linear_velocity.y = JUMP_SPEED
	_was_jump_pressed = jump_input

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
		var speed_h := sqrt(v_fwd * v_fwd + v_lat * v_lat)
		# GRIP cancels a capped lateral speed (scrubs); DRIFT redirects — bleeds a
		# fraction of the sideways velocity per second but rotates it INTO the heading
		# (momentum-conserving), so the velocity swings to follow the nose without
		# tanking speed. Blended by _grip_blend. Mirrors lobby.rs handling_step.
		if v_lat > 1e-6:
			var keep_grip := maxf(1.0 - GRIP_LAT_ACCEL * delta / v_lat, 0.0)
			var keep_drift := maxf(1.0 - DRIFT_REDIRECT_RATE * delta, 0.0)
			var keep := lerpf(keep_grip, keep_drift, _grip_blend)
			var new_lat_len := v_lat * keep
			lat *= keep
			var fwd_conserve := signf(v_fwd) * sqrt(maxf(speed_h * speed_h - new_lat_len * new_lat_len, 0.0))
			v_fwd = v_fwd + (fwd_conserve - v_fwd) * _grip_blend
		# Drift speed penalty (forward axis only): a modest along-heading bleed so a
		# held drift still costs some pace (mirrors lobby.rs).
		var drifted_fwd := v_fwd
		if v_fwd > 0.0:
			drifted_fwd = v_fwd * maxf(1.0 - DRIFT_SPEED_PENALTY * _grip_blend * delta, 0.0)
		var new_h := horiz_forward * drifted_fwd + lat
		self.linear_velocity = Vector3(new_h.x, v.y, new_h.z)

	self.linear_damp = lerpf(NORMAL_LINEAR_DAMP, DRIFT_LINEAR_DAMP, _grip_blend)

	# Keep the car upright on the ground (no rotation lock): a damped restoring torque
	# toward world-up. Grounded-only, so air rotation stays free. Magnitude ∝ the tilt
	# ANGLE (not sin), so it stays strong all the way to a full 180° flip and never gets
	# stuck inverted; at a perfect inversion the cross is ~0, so we push about the car's
	# forward axis. The damping term strips the yaw component so steering is free.
	if grounded:
		var up := self.global_transform.basis.y
		# Restore up toward the road SURFACE normal (hug banks/inclines); fall back
		# to world-up when the down-ray has no trustworthy near-vertical normal
		# (airborne grace, or scraping a wall). Mirrors the server.
		var target := Vector3.UP
		if not susp.is_empty() and (susp["normal"] as Vector3).y > GROUND_ALIGN_MIN_NY:
			target = susp["normal"] as Vector3
		var cross := up.cross(target)
		var cross_len := cross.length()
		var axis: Vector3
		if cross_len > 1e-4:
			axis = cross / cross_len
		elif up.dot(target) < 0.0:
			axis = self.global_transform.basis.z  # opposed: kick about forward
		else:
			axis = Vector3.ZERO  # already aligned
		var angle := acos(clampf(up.dot(target), -1.0, 1.0))  # 0 aligned … PI opposed
		var ang := self.angular_velocity
		var tilt_rate := ang - target * ang.dot(target)  # strip spin about the normal
		apply_torque(axis * (angle * UPRIGHT_GAIN) - tilt_rate * UPRIGHT_DAMP)
		# Raycast suspension: a central spring-damper force holds the car at ride
		# height so its box never rests on the faceted trimesh (no jitter). Mirrors
		# the server's compute_suspension. Zero/absent when airborne.
		if not susp.is_empty():
			apply_central_force(susp["force"] as Vector3)

	# Air-roll ("tonneau"): on the action's rising edge while airborne, cast a
	# view-relative ray (mostly down, tilted by steer). Hit → pull toward the surface
	# and reorient to land wheels-down; miss → barrel roll + forward dodge. Then drive
	# any active recover. Mirrors the server (lobby.rs compute_air_roll).
	var air_edge := air_roll_input and not _prev_air_roll and not raw_grounded
	_prev_air_roll = air_roll_input
	if air_edge:
		var cam_right := Vector3(cos(view_yaw), 0.0, -sin(view_yaw))
		var cam_fwd := Vector3(-sin(view_yaw), 0.0, -cos(view_yaw))
		# Straight down with no steer; steer trades the down component for a sideways
		# (view-left/right) one, so full steer aims ~horizontal (mirrors the server).
		var aim := (Vector3(0.0, -(1.0 - absf(steer)), 0.0) + cam_right * (steer * AIRROLL_AIM_LATERAL)).normalized()
		var com := self.global_transform * self.center_of_mass
		var hit := _raycast_solid(com, com + aim * AIRROLL_RANGE)
		if not hit.is_empty():
			self.linear_velocity += aim * AIRROLL_PULL_SPEED
			_air_recover_t = AIRROLL_RECOVER_TIME
			_air_recover_n = hit["normal"] as Vector3
		else:
			var roll_sign := 1.0 if steer >= 0.0 else -1.0
			self.angular_velocity = cam_fwd * roll_sign * AIRROLL_SPIN
			self.linear_velocity += cam_fwd * AIRROLL_DODGE_SPEED
	if _air_recover_t > 0.0 and not raw_grounded:
		var rtarget: Vector3 = _air_recover_n
		var rup := self.global_transform.basis.y
		var rcross := rup.cross(rtarget)
		var raxis: Vector3
		if rcross.length() > 1e-4:
			raxis = rcross.normalized()
		elif rup.dot(rtarget) < 0.0:
			raxis = self.global_transform.basis.z
		else:
			raxis = Vector3.ZERO
		var rangle := acos(clampf(rup.dot(rtarget), -1.0, 1.0))
		var rang := self.angular_velocity
		var rtilt := rang - rtarget * rang.dot(rtarget)
		apply_torque(raxis * (rangle * AIRROLL_RECOVER_GAIN) - rtilt * AIRROLL_RECOVER_DAMP)
		_air_recover_t -= delta
	elif raw_grounded:
		_air_recover_t = 0.0

	# Boost FSM (mirrors server) — uses horizontal forward. Sustain force only
	# applies while grounded.
	_update_boost_fsm(horiz_forward, speed, _drift_state, slip_mag, delta, grounded)
	_update_turbo(horiz_forward, speed, _drift_state, slip_mag, turbo_input, delta, grounded)
	_was_drift_pressed = drift_input
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
				"drift":       drift_input,
				"respawn":     _respawn_pending,
				"turbo":       turbo_input,
				"jump":        jump_input,
				"horn":        _horn_pending,
				"air_roll":    air_roll_input,
				"view_yaw":    view_yaw
			}
		})
		_respawn_pending = false
		_horn_pending = false

## Single-ray suspension sample (mirrors the server's compute_suspension): cast
## straight down from the centre of mass against the solid track (bodies only, so
## Area3D pads/hazards and the car itself are ignored — matching the server's
## GROUP_1 ray filter). When the spring is compressed it returns { force, normal },
## a central spring-damper force holding the car at ride height; empty when the
## wheel is off the ground (airborne). The car rides on this spring, so its box
## never rests on the faceted road trimesh — no contact jitter.
func _compute_suspension() -> Dictionary:
	var com := self.global_transform * self.center_of_mass
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(com, com + Vector3(0.0, -SUSP_MAX_LEN, 0.0))
	q.exclude = [self.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	var dist: float = com.y - (hit["position"] as Vector3).y
	var compression := SUSP_REST_LEN - dist
	if compression <= 0.0:
		return {}
	var normal: Vector3 = hit["normal"]
	var approach := self.linear_velocity.dot(normal)
	var f := maxf(SUSP_STIFFNESS * compression - SUSP_DAMP * approach, 0.0)
	return {"force": normal * f, "normal": normal}

## Ray against the solid track (bodies only — Area3D pads/hazards and the car
## itself are ignored, matching the server's GROUP_1 filter). Empty when no hit.
func _raycast_solid(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [self.get_rid()]
	return space.intersect_ray(q)

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
		"turbo_charge": _turbo_charge,
		"turbo_active": _turbo_active,
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

## Rocket-start quality in 0..1 from the signed press offset (s) relative to GO.
## Mirrors lobby.rs::launch_quality — symmetric, steepened so 100% is frame-precise.
func _launch_quality(offset: float) -> float:
	var off := absf(offset)
	if off >= ROCKET_WINDOW_S:
		return 0.0
	return pow(1.0 - off / ROCKET_WINDOW_S, ROCKET_SHARPNESS)

## Client prediction of the server-authoritative launch. `delta_t` = first-press
## time minus GO (signed: negative = pressed/held early, positive = late). Quality
## peaks at delta_t == 0 and falls off symmetrically; pressing outside the window
## (incl. holding the gas from the countdown) scores 0. Propels the car to
## LAUNCH_SPEED·quality. Returns quality in 0..1, or -1.0 if no boost. HUD shows it.
func try_rocket_start(delta_t: float) -> float:
	var quality := _launch_quality(delta_t)
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
					if _boost_audio:
						_boost_audio.play()  # "ptew" on the drift boost
		BoostState.BOOSTING:
			_boost_t_remaining -= delta
			if _boost_t_remaining <= 0.0:
				_boost_state = BoostState.IDLE
			else:
				var fwd_speed := forward_dir.dot(self.linear_velocity)
				if grounded and fwd_speed < _boost_peak_speed:
					apply_central_force(forward_dir * BOOST_SUSTAIN_FORCE)

# Turbo: second bar, independent of the drift-boost FSM. Fills while drifting
# (faster the more angular the slide), spent by holding the Turbo key for a strong
# forward push toward TURBO_PEAK_SPEED. Mirrors the server (lobby.rs update_turbo).
func _update_turbo(forward_dir: Vector3, speed: float, drifting: bool, slip_deg: float, turbo_input: bool, delta: float, grounded: bool) -> void:
	if grounded and drifting and speed > DRIFT_MIN_SPEED:
		var angle01 := clampf(absf(slip_deg) / BOOST_CHARGE_ANGLE_REF_DEG, 0.0, 1.0)
		var rate := TURBO_CHARGE_RATE + TURBO_CHARGE_ANGLE_RATE * angle01
		_turbo_charge = minf(_turbo_charge + rate * delta, 1.0)

	_turbo_active = false
	if turbo_input and _turbo_charge > 0.0 and grounded:
		_turbo_charge = maxf(_turbo_charge - TURBO_DRAIN_RATE * delta, 0.0)
		_turbo_active = true
		var fwd_speed := forward_dir.dot(self.linear_velocity)
		if fwd_speed < TURBO_PEAK_SPEED:
			apply_central_force(forward_dir * TURBO_FORCE)
