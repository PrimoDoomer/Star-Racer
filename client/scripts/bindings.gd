extends Node

# Autoload singleton: keyboard rebinding for the game's input actions.
#
# At launch it remembers each action's default keyboard key (from the project's
# InputMap), then applies any saved overrides from settings.cfg. The Settings
# panel calls set_key()/reset() to change them; joypad bindings are left
# untouched — only the keyboard event of each action is remapped.

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "Bindings"
const JOY_SECTION := "JoyBindings"
# Axis magnitude past which a trigger/stick motion counts as a rebind press.
const JOY_AXIS_CAPTURE_THRESHOLD := 0.6

# Actions the player can rebind, in display order.
const ACTIONS := [
	"Throttle",
	"Steering Left",
	"Steering Right",
	"Drift",
	"Turbo",
	"Jump",
	"Horn",
	"Respawn",
	"Pause",
	"Back View",
	"View Left",
	"View Right",
	"View Up",
	"View Down",
]

# Look/camera actions: still rebindable in Settings, but hidden from the in-game
# controls overlay (the HUD only lists the driving inputs).
const LOOK_ACTIONS := [
	"Back View",
	"View Left",
	"View Right",
	"View Up",
	"View Down",
]

var _defaults := {}  # action -> physical keycode
var _joy_defaults := {}  # action -> serialized joypad binding ("" = none)

func _enter_tree() -> void:
	for action in ACTIONS:
		_defaults[action] = _current_key(action)
		_joy_defaults[action] = _current_joy(action)
	_load()

# The physical keycode currently bound to an action's keyboard event (0 if none).
func _current_key(action: String) -> int:
	if not InputMap.has_action(action):
		return 0
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			return ev.physical_keycode if ev.physical_keycode != 0 else ev.keycode
	return 0

func get_key(action: String) -> int:
	return _current_key(action)

# Human-readable label for a keycode ("W", "Space", "—" when unbound).
func key_label(keycode: int) -> String:
	if keycode == 0:
		return tr("set_unbound")
	return OS.get_keycode_string(keycode)

# Short hardware label for an action's joypad binding ("RB", "RT", "L-Stick →"),
# or "" if it has none. Joypad events aren't rebindable here, but the in-game
# controls overlay shows them alongside the keyboard key.
func joy_label(action: String) -> String:
	if not InputMap.has_action(action):
		return ""
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton:
			return _joy_button_name((ev as InputEventJoypadButton).button_index)
		if ev is InputEventJoypadMotion:
			var m := ev as InputEventJoypadMotion
			return _joy_axis_name(m.axis, m.axis_value)
	return ""

func _joy_button_name(idx: int) -> String:
	match idx:
		JOY_BUTTON_A: return "A"
		JOY_BUTTON_B: return "B"
		JOY_BUTTON_X: return "X"
		JOY_BUTTON_Y: return "Y"
		JOY_BUTTON_BACK: return "Back"
		JOY_BUTTON_START: return "Start"
		JOY_BUTTON_LEFT_STICK: return "L3"
		JOY_BUTTON_RIGHT_STICK: return "R3"
		JOY_BUTTON_LEFT_SHOULDER: return "LB"
		JOY_BUTTON_RIGHT_SHOULDER: return "RB"
		JOY_BUTTON_DPAD_UP: return "D-Up"
		JOY_BUTTON_DPAD_DOWN: return "D-Down"
		JOY_BUTTON_DPAD_LEFT: return "D-Left"
		JOY_BUTTON_DPAD_RIGHT: return "D-Right"
		_: return "Btn %d" % idx

func _joy_axis_name(axis: int, value: float) -> String:
	match axis:
		JOY_AXIS_LEFT_X: return "L-Stick %s" % ("←" if value < 0.0 else "→")
		JOY_AXIS_LEFT_Y: return "L-Stick %s" % ("↑" if value < 0.0 else "↓")
		JOY_AXIS_RIGHT_X: return "R-Stick %s" % ("←" if value < 0.0 else "→")
		JOY_AXIS_RIGHT_Y: return "R-Stick %s" % ("↑" if value < 0.0 else "↓")
		JOY_AXIS_TRIGGER_LEFT: return "LT"
		JOY_AXIS_TRIGGER_RIGHT: return "RT"
		_: return "Axis %d" % axis

func set_key(action: String, keycode: int) -> void:
	_apply_key(action, keycode)
	# Avoid the same physical key driving two actions at once.
	for other in ACTIONS:
		if other != action and _current_key(other) == keycode:
			_apply_key(other, 0)
	_save()

func reset() -> void:
	for action in ACTIONS:
		_apply_key(action, _defaults[action])
		_apply_joy(action, _joy_defaults[action])
	_save()

# Replace an action's keyboard event with `keycode` (0 = remove it), keeping
# any non-keyboard (joypad) events in place.
func _apply_key(action: String, keycode: int) -> void:
	if not InputMap.has_action(action):
		return
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			InputMap.action_erase_event(action, ev)
	if keycode != 0:
		var e := InputEventKey.new()
		e.physical_keycode = keycode as Key
		InputMap.action_add_event(action, e)

# --- Joypad bindings ---------------------------------------------------------
# Stored/persisted as a compact string: "btn:<index>" for a button, or
# "axis:<axis>:<sign>" for a trigger/stick direction ("" = unbound).

# Serialized joypad binding currently on an action ("" if none).
func _current_joy(action: String) -> String:
	if not InputMap.has_action(action):
		return ""
	for ev in InputMap.action_get_events(action):
		var s := _serialize_joy(ev)
		if s != "":
			return s
	return ""

func _serialize_joy(ev: InputEvent) -> String:
	if ev is InputEventJoypadButton:
		return "btn:%d" % (ev as InputEventJoypadButton).button_index
	if ev is InputEventJoypadMotion:
		var m := ev as InputEventJoypadMotion
		return "axis:%d:%d" % [m.axis, (1 if m.axis_value >= 0.0 else -1)]
	return ""

func _deserialize_joy(serial: String) -> InputEvent:
	var parts := serial.split(":")
	if parts.size() >= 2 and parts[0] == "btn":
		var b := InputEventJoypadButton.new()
		b.button_index = int(parts[1]) as JoyButton
		b.pressed = true
		return b
	if parts.size() >= 3 and parts[0] == "axis":
		var m := InputEventJoypadMotion.new()
		m.axis = int(parts[1]) as JoyAxis
		m.axis_value = 1.0 if int(parts[2]) >= 0 else -1.0
		return m
	return null

# Capture an incoming event as a rebindable joypad press, or "" if it isn't one
# (lets the rebind UI ignore stick noise / button releases).
func capture_joy(ev: InputEvent) -> String:
	if ev is InputEventJoypadButton and (ev as InputEventJoypadButton).pressed:
		return _serialize_joy(ev)
	if ev is InputEventJoypadMotion:
		var m := ev as InputEventJoypadMotion
		if absf(m.axis_value) >= JOY_AXIS_CAPTURE_THRESHOLD:
			return _serialize_joy(ev)
	return ""

# Bind a captured joypad event to an action, clearing it from any other action so
# the same button never drives two at once.
func set_joy(action: String, serial: String) -> void:
	_apply_joy(action, serial)
	for other in ACTIONS:
		if other != action and _current_joy(other) == serial:
			_apply_joy(other, "")
	_save()

# Replace an action's joypad event with `serial` ("" = remove it), keeping any
# keyboard event in place.
func _apply_joy(action: String, serial: String) -> void:
	if not InputMap.has_action(action):
		return
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
			InputMap.action_erase_event(action, ev)
	var e := _deserialize_joy(serial)
	if e != null:
		InputMap.action_add_event(action, e)

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for action in ACTIONS:
		var saved := int(cfg.get_value(SECTION, action, -1))
		if saved >= 0:
			_apply_key(action, saved)
		if cfg.has_section_key(JOY_SECTION, action):
			_apply_joy(action, str(cfg.get_value(JOY_SECTION, action, "")))

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # keep other settings intact
	for action in ACTIONS:
		cfg.set_value(SECTION, action, _current_key(action))
		cfg.set_value(JOY_SECTION, action, _current_joy(action))
	cfg.save(SETTINGS_PATH)
