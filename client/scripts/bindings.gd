extends Node

# Autoload singleton: keyboard rebinding for the game's input actions.
#
# At launch it remembers each action's default keyboard key (from the project's
# InputMap), then applies any saved overrides from settings.cfg. The Settings
# panel calls set_key()/reset() to change them; joypad bindings are left
# untouched — only the keyboard event of each action is remapped.

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "Bindings"

# Actions the player can rebind, in display order.
const ACTIONS := [
	"Throttle",
	"Steering Left",
	"Steering Right",
	"Drift",
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

func _enter_tree() -> void:
	for action in ACTIONS:
		_defaults[action] = _current_key(action)
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

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for action in ACTIONS:
		var saved := int(cfg.get_value(SECTION, action, -1))
		if saved >= 0:
			_apply_key(action, saved)

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # keep other settings intact
	for action in ACTIONS:
		cfg.set_value(SECTION, action, _current_key(action))
	cfg.save(SETTINGS_PATH)
