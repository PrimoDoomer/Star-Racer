extends Node

# Autoload singleton: audio bus setup + persisted volume options (Settings -> Sound).
#
# Creates two child buses under Master -- SFX (engine, drift, boost, UI blips, start
# lights) and Horn (the player-chosen honk) -- so each gets its own volume slider.
# Volumes are stored linearly (0..1) in settings.cfg and applied to the buses at
# launch; the Settings panel calls set_*() to change and persist them live. Mirrors
# the Bindings autoload pattern.

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "Audio"

const BUS_MASTER := "Master"
const BUS_SFX := "SFX"
const BUS_HORN := "Horn"

# Default slider positions (linear gain). The horn starts at half: it is the
# loudest, most repeated one-shot, so by default it should not dominate.
const DEFAULT_MASTER := 1.0
const DEFAULT_SFX := 1.0
const DEFAULT_HORN := 0.5

var _master := DEFAULT_MASTER
var _sfx := DEFAULT_SFX
var _horn := DEFAULT_HORN

func _enter_tree() -> void:
	_ensure_buses()
	_load()
	_apply_all()

# Add the SFX / Horn buses (each routed to Master) if missing. Idempotent.
func _ensure_buses() -> void:
	for bus in [BUS_SFX, BUS_HORN]:
		if AudioServer.get_bus_index(bus) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus)
			AudioServer.set_bus_send(idx, BUS_MASTER)

func master() -> float:
	return _master

func sfx() -> float:
	return _sfx

func horn() -> float:
	return _horn

func set_master(v: float) -> void:
	_master = clampf(v, 0.0, 1.0)
	_apply(BUS_MASTER, _master)
	_save()

func set_sfx(v: float) -> void:
	_sfx = clampf(v, 0.0, 1.0)
	_apply(BUS_SFX, _sfx)
	_save()

func set_horn(v: float) -> void:
	_horn = clampf(v, 0.0, 1.0)
	_apply(BUS_HORN, _horn)
	_save()

# Map a 0..1 linear gain onto a bus: mute at the bottom, decibels above it.
func _apply(bus: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx == -1:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))

func _apply_all() -> void:
	_apply(BUS_MASTER, _master)
	_apply(BUS_SFX, _sfx)
	_apply(BUS_HORN, _horn)

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_master = clampf(float(cfg.get_value(SECTION, "master", DEFAULT_MASTER)), 0.0, 1.0)
	_sfx = clampf(float(cfg.get_value(SECTION, "sfx", DEFAULT_SFX)), 0.0, 1.0)
	_horn = clampf(float(cfg.get_value(SECTION, "horn", DEFAULT_HORN)), 0.0, 1.0)

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # keep locale/bindings/other settings intact
	cfg.set_value(SECTION, "master", _master)
	cfg.set_value(SECTION, "sfx", _sfx)
	cfg.set_value(SECTION, "horn", _horn)
	cfg.save(SETTINGS_PATH)
