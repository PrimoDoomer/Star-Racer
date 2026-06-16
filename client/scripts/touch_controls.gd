extends Control

# On-screen touch controls for the mobile / web build (prototype).
#
# It does NOT change the game's input handling: it simply drives the existing
# input actions (Throttle / Steering Left / Steering Right / Star Drift) via
# Input.action_press/release, so player.gd and camera.gd keep reading them
# exactly as they do for keyboard or gamepad.
#
# Layout:
#   - Left half  : a floating analogue thumbstick → steering. It anchors wherever
#     the thumb first lands, and only the horizontal offset matters (steering is
#     a pure left/right axis on the wire — see protocol PlayerState).
#   - Right side : one large pad held continuously (the thumb's anchor / "grip").
#     Any contact on it = Throttle. Its lower band adds Star Drift on top, so you
#     slide the thumb down to drift/charge and slide it back up to release — the
#     boost then fires on re-alignment (player.gd boost FSM). Throttle never drops
#     while sliding, because the whole pad keeps it pressed.
#
# View-look controls are intentionally dropped on touch.

const ACCENT      := Color(0.45, 0.56, 0.68)
const ACCENT_HOT  := Color(0.62, 0.74, 0.88)
const PANEL_BG    := Color(0.10, 0.12, 0.16, 0.45)
const PANEL_LINE  := Color(0.30, 0.36, 0.44, 0.55)
const TEXT_DIM    := Color(0.80, 0.86, 0.93, 0.55)
const KNOB_FILL   := Color(0.45, 0.56, 0.68, 0.85)

# --- Steering thumbstick ---
const STICK_RADIUS  := 120.0   # max thumb travel from anchor to reach full lock
const STICK_BASE_R  := 92.0
const STICK_KNOB_R  := 44.0
const STICK_DEADZONE := 0.12   # ignore tiny wobble around the anchor

# --- Accel / drift pad ---
const PAD_W       := 230.0
const PAD_H       := 250.0
const PAD_MARGIN  := 48.0
const DRIFT_FRAC  := 0.5        # lower half of the pad is the drift sub-zone
# Throttle/drift pointer is captured anywhere in the lower-right region, not just
# inside the visual pad, so sliding past its edge never drops the gaze on it.
const CAPTURE_TOP_FRAC := 0.25  # ignore the top quarter (nothing to grab there)

const MOUSE_ID := -2            # synthetic pointer id for desktop mouse testing

# Force the overlay on a non-touch desktop (toggle with F10 in debug builds).
@export var force_visible := false

var _steer_id: int = -999
var _steer_origin: Vector2 = Vector2.ZERO
var _steer_pos: Vector2 = Vector2.ZERO

var _accel_id: int = -999
var _accel_pos: Vector2 = Vector2.ZERO

var _was_active := false
var _charge: float = 0.0        # drift-boost charge, read from the car for feedback

@onready var _game := get_node_or_null("/root/Root/Game")

func _touch_mode() -> bool:
	return force_visible or Game.is_mobile()

func _is_active() -> bool:
	if _game == null:
		return false
	return _game.mode == Game.Mode.IN_RACE and not _game.paused and _touch_mode()

func _process(_delta: float) -> void:
	var active := _is_active()
	visible = active

	if not active:
		if _was_active:
			_release_all()
			_clear_pointers()
			_was_active = false
		return
	_was_active = true

	# Drift charge for the pad's feedback ring (same source as the drift bar).
	if _game.car_node != null:
		_charge = float(_game.car_node.get("drift_charge"))
	else:
		_charge = 0.0

	_apply_inputs()
	queue_redraw()

func _unhandled_key_input(event: InputEvent) -> void:
	# Desktop convenience: F10 force-toggles the overlay so it can be tried with a
	# mouse without a real touchscreen.
	if OS.has_feature("debug") and event is InputEventKey and event.pressed \
	and not event.echo and event.keycode == KEY_F10:
		force_visible = not force_visible

func _input(event: InputEvent) -> void:
	if not _is_active():
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			_pointer_down(event.index, event.position)
		else:
			_pointer_up(event.index)
	elif event is InputEventScreenDrag:
		_pointer_move(event.index, event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pointer_down(MOUSE_ID, event.position)
		else:
			_pointer_up(MOUSE_ID)
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_pointer_move(MOUSE_ID, event.position)

# --- Pointer tracking -------------------------------------------------------

func _pointer_down(id: int, pos: Vector2) -> void:
	var mid := size.x * 0.5
	var top := size.y * CAPTURE_TOP_FRAC
	if pos.y < top:
		return
	if pos.x < mid and _steer_id == -999:
		_steer_id = id
		_steer_origin = pos
		_steer_pos = pos
	elif pos.x >= mid and _accel_id == -999:
		_accel_id = id
		_accel_pos = pos

func _pointer_move(id: int, pos: Vector2) -> void:
	if id == _steer_id:
		_steer_pos = pos
	elif id == _accel_id:
		_accel_pos = pos

func _pointer_up(id: int) -> void:
	if id == _steer_id:
		_steer_id = -999
	elif id == _accel_id:
		_accel_id = -999

func _clear_pointers() -> void:
	_steer_id = -999
	_accel_id = -999

# --- Drive the game's input actions ----------------------------------------

func _apply_inputs() -> void:
	# Steering: horizontal offset from the anchor, normalised and de-zoned.
	var x := 0.0
	if _steer_id != -999:
		var off := (_steer_pos.x - _steer_origin.x) / STICK_RADIUS
		off = clampf(off, -1.0, 1.0)
		var mag := absf(off)
		if mag > STICK_DEADZONE:
			# Rescale [deadzone, 1] → (0, 1] so there's no dead jump at the edge.
			x = signf(off) * (mag - STICK_DEADZONE) / (1.0 - STICK_DEADZONE)
	if x > 0.0:
		Input.action_release("Steering Left")
		Input.action_press("Steering Right", x)
	elif x < 0.0:
		Input.action_release("Steering Right")
		Input.action_press("Steering Left", -x)
	else:
		Input.action_release("Steering Left")
		Input.action_release("Steering Right")

	# Throttle + drift from the single right-hand pad.
	var throttle := _accel_id != -999
	var drift := throttle and _accel_pos.y >= _drift_line()
	if throttle:
		Input.action_press("Throttle")
	else:
		Input.action_release("Throttle")
	if drift:
		Input.action_press("Star Drift")
	else:
		Input.action_release("Star Drift")

func _release_all() -> void:
	for a in ["Throttle", "Star Drift", "Steering Left", "Steering Right"]:
		Input.action_release(a)

# --- Geometry helpers -------------------------------------------------------

func _pad_rect() -> Rect2:
	return Rect2(
		size.x - PAD_MARGIN - PAD_W,
		size.y - PAD_MARGIN - PAD_H,
		PAD_W, PAD_H)

func _drift_line() -> float:
	var r := _pad_rect()
	return r.position.y + r.size.y * (1.0 - DRIFT_FRAC)

# --- Drawing ----------------------------------------------------------------

func _draw() -> void:
	_draw_stick()
	_draw_pad()

func _draw_stick() -> void:
	var anchor: Vector2
	var knob: Vector2
	if _steer_id != -999:
		anchor = _steer_origin
		var off := _steer_pos - anchor
		if off.length() > STICK_RADIUS:
			off = off.normalized() * STICK_RADIUS
		knob = anchor + Vector2(off.x, 0.0)  # vertical ignored: pure steering axis
	else:
		# Idle hint where the thumb is expected to land.
		anchor = Vector2(size.x * 0.18, size.y - 200.0)
		knob = anchor

	var ring_col := PANEL_LINE if _steer_id == -999 else ACCENT
	draw_circle(anchor, STICK_BASE_R, PANEL_BG)
	draw_arc(anchor, STICK_BASE_R, 0.0, TAU, 48, ring_col, 3.0, true)
	draw_circle(knob, STICK_KNOB_R, KNOB_FILL if _steer_id != -999 else PANEL_BG)
	draw_arc(knob, STICK_KNOB_R, 0.0, TAU, 32, ACCENT_HOT if _steer_id != -999 else PANEL_LINE, 2.0, true)

func _draw_pad() -> void:
	var r := _pad_rect()
	var font := ThemeDB.fallback_font
	var pressed := _accel_id != -999
	var drifting := pressed and _accel_pos.y >= _drift_line()

	# Pad body.
	draw_rect(r, PANEL_BG, true)
	draw_rect(r, PANEL_LINE, false, 2.0)

	# Divider between the accel (top) and drift (bottom) bands.
	var dl := _drift_line()
	draw_line(Vector2(r.position.x, dl), Vector2(r.position.x + r.size.x, dl), PANEL_LINE, 2.0)

	# Accel band highlight.
	if pressed:
		var accel_rect := Rect2(r.position, Vector2(r.size.x, dl - r.position.y))
		draw_rect(accel_rect, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.22), true)

	# Drift band highlight (brighter when actually drifting).
	var drift_rect := Rect2(Vector2(r.position.x, dl), Vector2(r.size.x, r.position.y + r.size.y - dl))
	var drift_alpha := 0.30 if drifting else 0.10
	draw_rect(drift_rect, Color(ACCENT_HOT.r, ACCENT_HOT.g, ACCENT_HOT.b, drift_alpha), true)

	# Charge meter along the drift band's bottom edge.
	if _charge > 0.002:
		var cw := drift_rect.size.x * clampf(_charge, 0.0, 1.0)
		var bar_y := r.position.y + r.size.y - 8.0
		var col := ACCENT_HOT if _charge >= 0.999 else ACCENT
		draw_rect(Rect2(r.position.x, bar_y, cw, 6.0), col, true)

	# Labels.
	_draw_centered(font, "ACCEL", Vector2(r.position.x + r.size.x * 0.5, r.position.y + (dl - r.position.y) * 0.5), 18, TEXT_DIM)
	_draw_centered(font, "DRIFT", Vector2(r.position.x + r.size.x * 0.5, dl + (r.position.y + r.size.y - dl) * 0.5), 18,
		ACCENT_HOT if drifting else TEXT_DIM)

func _draw_centered(font: Font, text: String, center: Vector2, fsize: int, col: Color) -> void:
	var dim := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
	draw_string(font, Vector2(center.x - dim.x * 0.5, center.y + dim.y * 0.30), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, col)
