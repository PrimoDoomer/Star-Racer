extends Camera3D

const FOLLOW_DIST   := 5.0
const FOLLOW_HEIGHT := 2.2
const LOOK_HEIGHT   := 1.0

const YAW_RATE_GRIP  := 25.0
const YAW_RATE_DRIFT := 3.5
# How fast the follow-rate eases between grip and drift, so entering/leaving a
# drift doesn't snap the camera (was a hard switch).
const DRIFT_CAM_BLEND_RATE := 6.0

const POS_RATE := 18.0

const ORBIT_SENS      := 2.2
const ORBIT_RETURN    := 6.0
const ORBIT_PITCH_MAX := 0.45

const FOV_BASE := 72.0
# Dynamic FOV: widen with speed for a sense of pace, and punch a little wider while
# boosting/turboing so the boost actually *reads* as a kick (the camera was the
# missing feedback channel). Eased toward the target — attack fast (punch in),
# release slow (settle). Starting values; test: speed-FOV should be felt but not
# nauseating, boost kick obvious. Tune FOV_SPEED_ADD/FOV_BOOST_ADD down if it
# induces motion discomfort, up if speed feels flat.
const FOV_SPEED_REF := 80.0   # speed (m/s) at which the speed term saturates (cruise ≈50, turbo peak ≈75)
const FOV_SPEED_ADD := 7.0    # degrees added by raw speed at the reference
const FOV_BOOST_ADD := 5.0    # extra degrees while boosting or turboing
const FOV_ATTACK_RATE := 8.0  # ease-in rate (widening — snappy)
const FOV_RELEASE_RATE := 3.0 # ease-out rate (narrowing — smooth)

var _cam_pos     := Vector3.ZERO
var _look_target := Vector3.ZERO
var _cam_yaw    := 0.0
var _orb_yaw    := 0.0
var _orb_pitch  := 0.0
var _drift_blend := 0.0  # eased 0 (grip) → 1 (drift), smooths the follow-rate
var _ready_snap := true

@onready var _car: RigidBody3D = get_parent() as RigidBody3D
@onready var _game := get_node("/root/Root/Game")

func _ready() -> void:
	self._ready_snap = true
	self.fov = FOV_BASE
	# This camera smooths itself every render frame in _process (manual lerp), so
	# it must opt out of global physics interpolation — otherwise Godot double-
	# interpolates and warns that an interpolated camera moved outside _physics_process.
	self.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

func _process(delta: float) -> void:
	# Active whenever the player's car is on track (race or the pre-race
	# countdown/intermission) — so back view and free-look work the whole time.
	# The pause menu no longer stops the world (multiplayer), so the camera keeps
	# following the moving car while it's open.
	if self._game == null \
	or (self._game.mode != Game.Mode.IN_RACE and self._game.mode != Game.Mode.LOBBY_INTERMISSION):
		self._ready_snap = true
		return

	if self._ready_snap:
		_snap_to_car()
		self._ready_snap = false
		return

	if Input.is_action_pressed("Back View"):
		_snap_to_car(PI)
		return

	if Input.is_action_just_released("Back View"):
		_snap_to_car()
		return

	_tick_orbital(delta)
	_tick_yaw(delta)
	_tick_position(delta)
	_tick_fov(delta)
	_commit()

func _snap_to_car(yaw_offset: float = 0.0) -> void:
	self._cam_yaw     = self._car.global_rotation.y + yaw_offset
	self._orb_yaw     = 0.0
	self._orb_pitch   = 0.0
	self._drift_blend = 0.0
	var behind  := Vector3(sin(self._cam_yaw), 0.0, cos(self._cam_yaw)) * FOLLOW_DIST
	self._cam_pos     = self._car.global_position + behind + Vector3(0.0, FOLLOW_HEIGHT, 0.0)
	self._look_target = self._car.global_position + Vector3(0.0, LOOK_HEIGHT, 0.0)
	self.global_position = self._cam_pos
	self.fov = FOV_BASE
	if self._cam_pos.distance_to(self._look_target) > 0.1:
		look_at(self._look_target, Vector3.UP)

func _tick_orbital(delta: float) -> void:
	var sx := Input.get_axis("View Left", "View Right")
	var sy := Input.get_axis("View Up",   "View Down")

	if abs(sx) > 0.0:
		self._orb_yaw += sx * ORBIT_SENS * delta
	else:
		self._orb_yaw = lerpf(self._orb_yaw, 0.0, clamp(ORBIT_RETURN * delta, 0.0, 1.0))

	if abs(sy) > 0.0:
		self._orb_pitch = clamp(self._orb_pitch - sy * ORBIT_SENS * delta, -ORBIT_PITCH_MAX, ORBIT_PITCH_MAX)
	else:
		self._orb_pitch = lerpf(self._orb_pitch, 0.0, clamp(ORBIT_RETURN * delta, 0.0, 1.0))

func _tick_yaw(delta: float) -> void:
	var target_yaw := self._car.global_rotation.y + self._orb_yaw

	var drifting := Input.is_action_pressed("Drift") and self._car.linear_velocity.length() > 3.0
	# Ease the follow-rate toward grip/drift instead of snapping it on enter/exit.
	self._drift_blend = lerpf(self._drift_blend, 1.0 if drifting else 0.0, clamp(DRIFT_CAM_BLEND_RATE * delta, 0.0, 1.0))
	var rate := lerpf(YAW_RATE_GRIP, YAW_RATE_DRIFT, self._drift_blend)

	var diff := angle_difference(self._cam_yaw, target_yaw)
	self._cam_yaw += diff * clamp(rate * delta, 0.0, 1.0)
	self._cam_yaw  = wrapf(self._cam_yaw, -PI, PI)

func _tick_position(delta: float) -> void:
	var h      := FOLLOW_HEIGHT + sin(self._orb_pitch) * FOLLOW_DIST * 0.5
	var behind := Vector3(sin(self._cam_yaw), 0.0, cos(self._cam_yaw)) * FOLLOW_DIST
	var target := self._car.global_position + behind + Vector3(0.0, h, 0.0)
	var t: float = clamp(POS_RATE * delta, 0.0, 1.0)

	self._cam_pos     = self._cam_pos.lerp(target, t)
	self._look_target = self._look_target.lerp(self._car.global_position + Vector3(0.0, LOOK_HEIGHT, 0.0), t)

func _tick_fov(delta: float) -> void:
	var spd01 := clampf(self._car.linear_velocity.length() / FOV_SPEED_REF, 0.0, 1.0)
	var target := FOV_BASE + FOV_SPEED_ADD * spd01
	# Persistent thrust states on the car (BoostState.BOOSTING == 2, or turbo held).
	# Read via get() — same loose-coupling pattern the drift bar uses for the car.
	if self._car.get("_boost_state") == 2 or self._car.get("_turbo_active") == true:
		target += FOV_BOOST_ADD
	var rate := FOV_ATTACK_RATE if target > self.fov else FOV_RELEASE_RATE
	self.fov = lerpf(self.fov, target, clampf(rate * delta, 0.0, 1.0))

func _commit() -> void:
	self.global_position = self._cam_pos
	if self._cam_pos.distance_to(self._look_target) > 0.1:
		look_at(self._look_target, Vector3.UP)
