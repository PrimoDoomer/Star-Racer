extends Control

# On-screen touch controls for the mobile / web build (prototype).
#
# It does NOT change the game's input handling: it simply drives the existing
# input actions (Throttle / Steering Left / Steering Right / Drift) via
# Input.action_press/release, so player.gd and camera.gd keep reading them
# exactly as they do for keyboard or gamepad.
#
# Layout:
#   - Left half  : a floating analogue thumbstick → steering. It anchors wherever
#     the thumb first lands, and only the horizontal offset matters (steering is
#     a pure left/right axis on the wire — see protocol PlayerState).
#   - Right side : a floating action "cross". Any contact = Throttle (always), so
#     "touch anywhere → accelerate". Keep the thumb near the centre and it ONLY
#     accelerates; push it onto a branch (up / down / left / right) and it also
#     fires that branch's action (CROSS_UP/DOWN/LEFT/RIGHT below) while still
#     holding throttle. Held actions (Drift/Turbo) stay on while the thumb rests on
#     the branch; edge actions (Jump/AirRoll) fire as the thumb enters it.
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

# --- Accel + action cross (right thumb) ---
const CROSS_RADIUS   := 130.0   # thumb travel from centre to fully select a branch
const CROSS_DEADZONE := 0.40    # within this fraction of the radius = centre (throttle only)
const CROSS_ARM_R    := 96.0    # drawn arm length from centre
const CROSS_KNOB_R   := 40.0
const PAD_MARGIN     := 48.0    # idle-hint placement from the screen edge
# Branch → input action. Tweak freely — these are just action names. Held actions
# (Drift/Turbo) stay pressed while the thumb rests on the branch; edge actions
# (Jump/AirRoll) fire as the thumb enters it.
const CROSS_UP    := "Jump"
const CROSS_DOWN  := "Drift"
const CROSS_LEFT  := "AirRoll"
const CROSS_RIGHT := "Turbo"
const CROSS_ACTIONS := [CROSS_UP, CROSS_DOWN, CROSS_LEFT, CROSS_RIGHT]
# The cross pointer is captured anywhere in the lower-right region, not just on the
# visual cross, so sliding past an arm never drops it.
const CAPTURE_TOP_FRAC := 0.25  # ignore the top quarter (nothing to grab there)

# Discreet "menu" button (top-right) — opens the pause panel on touch, since there's
# no Esc/Start key on a phone. The panel's own Resume/Leave buttons close it.
const MENU_BTN_SIZE   := Vector2(112.0, 56.0)
const MENU_BTN_MARGIN := 18.0

const MOUSE_ID := -2            # synthetic pointer id for desktop mouse testing

# Force the overlay on a non-touch desktop (toggle with F10 in debug builds).
@export var force_visible := false

var _steer_id: int = -999
var _steer_origin: Vector2 = Vector2.ZERO
var _steer_pos: Vector2 = Vector2.ZERO

var _accel_id: int = -999
var _accel_origin: Vector2 = Vector2.ZERO
var _accel_pos: Vector2 = Vector2.ZERO

var _was_active := false
var _charge: float = 0.0        # drift-boost charge, read from the car for feedback

@onready var _game := get_node_or_null("/root/Root/Game")

func _touch_mode() -> bool:
	return force_visible or Game.is_mobile()

func _is_active() -> bool:
	if _game == null:
		return false
	# On-track means racing, or the on-track pre-race countdown — LOBBY_INTERMISSION
	# with the lobby menu hidden (mirrors ui.gd). On the lobby waiting screen the
	# intermission menu is up, so the controls stay hidden there instead of covering
	# it; they appear once the track is revealed, still in time to hold throttle for
	# the rocket-start.
	var on_track :bool = _game.mode == Game.Mode.IN_RACE
	if _game.mode == Game.Mode.LOBBY_INTERMISSION:
		var menu := _game.get_node_or_null("UI/IntermissionMenu")
		on_track = menu != null and not menu.visible
	return on_track and not _game.paused and _touch_mode()

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
	if _menu_btn_rect().has_point(pos):
		_open_pause_menu()
		return
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
		_accel_origin = pos
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

	# Throttle (always while touching the cross) + the active branch's action.
	var throttle := _accel_id != -999
	if throttle:
		Input.action_press("Throttle")
	else:
		Input.action_release("Throttle")
	var branch := _cross_branch()
	for a in CROSS_ACTIONS:
		if a == branch:
			Input.action_press(a)
		else:
			Input.action_release(a)

func _release_all() -> void:
	for a in ["Throttle", "Steering Left", "Steering Right"]:
		Input.action_release(a)
	for a in CROSS_ACTIONS:
		Input.action_release(a)

# Which cross branch the thumb is on, or "" for the centre (throttle only).
func _cross_branch() -> String:
	if _accel_id == -999:
		return ""
	var off := (_accel_pos - _accel_origin) / CROSS_RADIUS
	if off.length() < CROSS_DEADZONE:
		return ""
	if absf(off.x) > absf(off.y):
		return CROSS_RIGHT if off.x > 0.0 else CROSS_LEFT
	return CROSS_DOWN if off.y > 0.0 else CROSS_UP

# --- Geometry helpers -------------------------------------------------------

# Where the cross centres: the live thumb anchor, or an idle hint in the lower-right.
func _cross_center() -> Vector2:
	if _accel_id != -999:
		return _accel_origin
	return Vector2(size.x - PAD_MARGIN - CROSS_ARM_R, size.y - PAD_MARGIN - CROSS_ARM_R)

func _menu_btn_rect() -> Rect2:
	return Rect2(size.x - MENU_BTN_MARGIN - MENU_BTN_SIZE.x, MENU_BTN_MARGIN, MENU_BTN_SIZE.x, MENU_BTN_SIZE.y)

# Open the pause panel (mirrors the Pause action): freeze the car and show the
# play menu, whose own Resume/Leave buttons take over from here.
func _open_pause_menu() -> void:
	if _game == null:
		return
	_game.paused = true
	var panel := _game.get_node_or_null("UI/PlayMenuPanel")
	if panel:
		panel.visible = true

# --- Drawing ----------------------------------------------------------------

func _draw() -> void:
	_draw_stick()
	_draw_cross()
	_draw_menu_button()

func _draw_menu_button() -> void:
	var r := _menu_btn_rect()
	draw_rect(r, PANEL_BG, true)
	draw_rect(r, PANEL_LINE, false, 2.0)
	var cx := r.position.x + r.size.x * 0.5
	var cy := r.position.y + r.size.y * 0.5
	var hw := r.size.x * 0.26
	for i in 3:
		var yy := cy + (float(i) - 1.0) * 8.0
		draw_line(Vector2(cx - hw, yy), Vector2(cx + hw, yy), TEXT_DIM, 3.0)

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

func _draw_cross() -> void:
	var c := _cross_center()
	var pressed := _accel_id != -999
	var branch := _cross_branch()
	var font := ThemeDB.fallback_font

	# Drift-boost charge ring around the cross (same source as the drift bar).
	if _charge > 0.002:
		var ch_col := ACCENT_HOT if _charge >= 0.999 else ACCENT
		draw_arc(c, CROSS_ARM_R + 9.0, -PI * 0.5, -PI * 0.5 + TAU * clampf(_charge, 0.0, 1.0), 48, ch_col, 4.0, true)

	# Faint reach circle.
	draw_arc(c, CROSS_ARM_R, 0.0, TAU, 48, PANEL_LINE, 2.0, true)

	# Four arms, each highlighted while it's the active branch.
	var arms := {
		CROSS_UP: Vector2(0.0, -1.0),
		CROSS_DOWN: Vector2(0.0, 1.0),
		CROSS_LEFT: Vector2(-1.0, 0.0),
		CROSS_RIGHT: Vector2(1.0, 0.0),
	}
	for action in arms:
		var act := String(action)
		var dir: Vector2 = arms[action]
		var tip := c + dir * CROSS_ARM_R
		var hot: bool = pressed and branch == act
		var col: Color = ACCENT_HOT if hot else PANEL_LINE
		draw_line(c, tip, col, 5.0 if hot else 2.0)
		_draw_centered(font, _short_label(act), tip + dir * 18.0, 15, ACCENT_HOT if hot else TEXT_DIM)

	# Centre knob: filled while accelerating; the throttle is held the whole time.
	draw_circle(c, CROSS_KNOB_R, KNOB_FILL if pressed else PANEL_BG)
	draw_arc(c, CROSS_KNOB_R, 0.0, TAU, 32, ACCENT if pressed else PANEL_LINE, 2.0, true)

# Compact label for a branch's action (the action id, abbreviated).
func _short_label(action: String) -> String:
	match action:
		"AirRoll": return "ROLL"
		"Steering Left": return "<"
		"Steering Right": return ">"
		_: return action.to_upper()

func _draw_centered(font: Font, text: String, center: Vector2, fsize: int, col: Color) -> void:
	var dim := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
	draw_string(font, Vector2(center.x - dim.x * 0.5, center.y + dim.y * 0.30), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, col)
