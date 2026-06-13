extends Camera3D

const FOLLOW_DIST   := 5.0
const FOLLOW_HEIGHT := 2.2
const LOOK_HEIGHT   := 1.0

const YAW_RATE_GRIP  := 25.0
const YAW_RATE_DRIFT := 3.5

const POS_RATE := 18.0

const ORBIT_SENS      := 2.2
const ORBIT_RETURN    := 6.0
const ORBIT_PITCH_MAX := 0.45

const FOV_BASE := 72.0

var _cam_pos     := Vector3.ZERO
var _look_target := Vector3.ZERO
var _cam_yaw    := 0.0
var _orb_yaw    := 0.0
var _orb_pitch  := 0.0
var _ready_snap := true

@onready var _car: RigidBody3D = get_parent() as RigidBody3D
@onready var _game := get_node("/root/Root/Game")

func _ready() -> void:
	self._ready_snap = true
	self.fov = FOV_BASE

func _process(delta: float) -> void:
	if self._game == null or self._game.mode != Game.Mode.IN_RACE or self._game.paused:
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
	_commit()

func _snap_to_car(yaw_offset: float = 0.0) -> void:
	self._cam_yaw     = self._car.global_rotation.y + yaw_offset
	self._orb_yaw     = 0.0
	self._orb_pitch   = 0.0
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

	var drifting := Input.is_action_pressed("Star Drift") and self._car.linear_velocity.length() > 3.0
	var rate := YAW_RATE_DRIFT if drifting else YAW_RATE_GRIP

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

func _commit() -> void:
	self.global_position = self._cam_pos
	if self._cam_pos.distance_to(self._look_target) > 0.1:
		look_at(self._look_target, Vector3.UP)
