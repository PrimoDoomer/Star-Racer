extends Node

# Autoload singleton: graphics quality (Settings -> Performance mode). Mirrors the
# Audio/Bindings autoload pattern (persisted in settings.cfg, applied at launch and
# live when the toggle changes).
#
# A single "low" switch trades visual polish for framerate:
#   - viewport (applied here, live): 3D render scale downsampled + MSAA off
#   - environment (read by environment_builder.gd at track build): SSAO, glow and
#     directional shadows are dropped; cars keep their cheap blob shadow.
# The viewport bits apply immediately; the environment bits take effect on the next
# track build (Settings is only reachable from the menu, before a race).

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "Graphics"

# Low-mode render scale: renders 3D at 75% then upscales — the biggest single GPU
# win. Starting value; drop toward 0.6 if low-end machines still struggle.
const LOW_RENDER_SCALE := 0.75

var _low := false

func _ready() -> void:
	_load()
	_apply_viewport()

func is_low() -> bool:
	return _low

func set_low(v: bool) -> void:
	if v == _low:
		return
	_low = v
	_apply_viewport()
	_save()

# Render scale + MSAA on the main viewport. High mode matches project.godot
# (msaa_3d=2 == MSAA_4X); low mode downsamples and drops MSAA.
func _apply_viewport() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	vp.scaling_3d_scale = LOW_RENDER_SCALE if _low else 1.0
	vp.msaa_3d = Viewport.MSAA_DISABLED if _low else Viewport.MSAA_4X

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_low = bool(cfg.get_value(SECTION, "low", false))

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # keep locale/bindings/audio settings intact
	cfg.set_value(SECTION, "low", _low)
	cfg.save(SETTINGS_PATH)
