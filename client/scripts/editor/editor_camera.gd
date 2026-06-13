extends Camera3D

## Free-look editor camera: orbits a pivot point.
##   Right mouse drag  -> orbit (yaw / elevation)
##   Middle mouse drag -> pan the pivot in the view plane
##   Mouse wheel       -> zoom (dolly in / out)
##   map_editor calls focus_on() for the F shortcut.
##
## Uses _unhandled_input so UI Controls (toolbar / inspector) consume their
## own events first; the camera only reacts over the empty 3D viewport.

class_name EditorCamera

var pivot: Vector3 = Vector3.ZERO
var _yaw: float = 0.7        # azimuth around Y (radians)
var _elev: float = 0.9       # elevation above the ground plane (radians)
var _distance: float = 80.0

const MIN_ELEV := 0.05
const MAX_ELEV := 1.5        # just under PI/2 to keep look_at well-defined
const MIN_DIST := 3.0
const MAX_DIST := 700.0
const ORBIT_SENS := 0.008
const PAN_SENS := 0.0016     # multiplied by distance so panning scales with zoom
const ZOOM_STEP := 1.12

var _orbiting := false
var _panning := false

func _ready() -> void:
	current = true
	far = 4000.0
	_apply()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = event.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_distance = clampf(_distance / ZOOM_STEP, MIN_DIST, MAX_DIST)
					_apply()
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_distance = clampf(_distance * ZOOM_STEP, MIN_DIST, MAX_DIST)
					_apply()
	elif event is InputEventMouseMotion:
		if _orbiting:
			_yaw -= event.relative.x * ORBIT_SENS
			_elev = clampf(_elev - event.relative.y * ORBIT_SENS, MIN_ELEV, MAX_ELEV)
			_apply()
		elif _panning:
			var k := PAN_SENS * _distance
			pivot -= global_transform.basis.x * event.relative.x * k
			pivot += global_transform.basis.y * event.relative.y * k
			_apply()

func _apply() -> void:
	var off := Vector3(
		cos(_elev) * sin(_yaw),
		sin(_elev),
		cos(_elev) * cos(_yaw)
	)
	global_position = pivot + off * _distance
	# Avoid a degenerate look_at when the view is near-vertical (top/bottom).
	var up := Vector3.UP
	if absf((pivot - global_position).normalized().dot(Vector3.UP)) > 0.999:
		up = Vector3(0.0, 0.0, -1.0)
	look_at(pivot, up)

## Recentre the pivot on a world point (F shortcut / on selection).
func focus_on(point: Vector3, dist: float = -1.0) -> void:
	pivot = point
	if dist > 0.0:
		_distance = clampf(dist, MIN_DIST, MAX_DIST)
	_apply()

## Snap to an axis-aligned view (like Godot's numpad views).
##   top   = look down -Y (the XZ track plane)
##   front = look toward -Z   ·   right = look toward -X   ·   persp = default 3/4
func set_axis_view(view: String) -> void:
	match view:
		"top":
			_yaw = 0.0
			_elev = PI * 0.5 - 0.0001
		"front":
			_yaw = 0.0
			_elev = 0.0
		"right":
			_yaw = PI * 0.5
			_elev = 0.0
		"persp":
			_yaw = 0.7
			_elev = 0.9
	_apply()
