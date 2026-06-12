extends Control

# Minimal flat in-race HUD:
#   - a clean speed read-out in the bottom-right corner
#   - a slim drift-charge bar centred along the bottom, brightening as the
#     boost charges and flashing white the instant a boost fires.

const ACCENT     := Color(0.30, 0.60, 1.00)
const ACCENT_HOT := Color(0.62, 0.82, 1.00)
const TRACK_BG   := Color(0.10, 0.12, 0.16, 0.85)
const TEXT_MAIN  := Color(0.95, 0.97, 1.00)
const TEXT_DIM   := Color(0.55, 0.62, 0.72)

const SPEED_SIZE     := 72
const UNIT_SIZE      := 18
const SPEED_MARGIN_X := 56.0
const SPEED_MARGIN_Y := 52.0

const BAR_W         := 320.0
const BAR_H         := 10.0
const BAR_RADIUS    := 5
const BAR_MARGIN_B  := 56.0
const BOOST_MIN     := 0.30

var _charge: float = 0.0
var _boost_flash: float = 0.0
var _speed_kmh: int = 0
var _prev_pos: Vector3 = Vector3.ZERO
var _prev_pos_valid := false
var _kmh_smoothed: float = 0.0

var _sb_track: StyleBoxFlat = null
var _sb_fill: StyleBoxFlat = null

func _ready() -> void:
	_sb_track = StyleBoxFlat.new()
	_sb_track.bg_color = TRACK_BG
	_sb_track.set_corner_radius_all(BAR_RADIUS)
	_sb_fill = StyleBoxFlat.new()
	_sb_fill.set_corner_radius_all(BAR_RADIUS)

func _process(delta: float) -> void:
	var game := get_node_or_null("/root/Root/Game") as Game
	if game == null or game.mode != Game.Mode.IN_RACE:
		visible = false
		_prev_pos_valid = false
		return

	visible = true

	if game.car_node != null and delta > 0.0:
		var rb := game.car_node as RigidBody3D
		_charge = rb.get("drift_charge") as float
		if rb.get("boost_flash") as bool:
			_boost_flash = 0.28
			rb.set("boost_flash", false)

		# Speed via position delta — reliable even when global_position is
		# being written directly for server reconciliation (which leaves
		# linear_velocity stale).
		var pos := rb.global_position
		var inst_kmh := 0.0
		if _prev_pos_valid:
			var d := Vector2(pos.x - _prev_pos.x, pos.z - _prev_pos.z).length()
			inst_kmh = (d / delta) * 3.6
		_prev_pos = pos
		_prev_pos_valid = true

		# Low-pass filter to hide per-frame jitter.
		_kmh_smoothed = lerp(_kmh_smoothed, inst_kmh, clampf(delta * 12.0, 0.0, 1.0))
		var kmh := _kmh_smoothed
		if kmh < 1.0:
			kmh = 0.0
		_speed_kmh = int(round(kmh))

	if _boost_flash > 0.0:
		_boost_flash -= delta

	queue_redraw()

func _draw() -> void:
	_draw_drift_bar()
	_draw_speed()

func _draw_speed() -> void:
	var font := ThemeDB.fallback_font
	var num := "%d" % _speed_kmh
	var unit := "KM/H"
	var num_dim := font.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, SPEED_SIZE)
	var unit_dim := font.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, UNIT_SIZE)
	var gap := 8.0
	var baseline_y := size.y - SPEED_MARGIN_Y
	var right := size.x - SPEED_MARGIN_X
	var unit_x := right - unit_dim.x
	var num_x := unit_x - gap - num_dim.x
	# Big number and small unit share the same baseline.
	draw_string(font, Vector2(num_x, baseline_y), num,
		HORIZONTAL_ALIGNMENT_LEFT, -1, SPEED_SIZE, TEXT_MAIN)
	draw_string(font, Vector2(unit_x, baseline_y), unit,
		HORIZONTAL_ALIGNMENT_LEFT, -1, UNIT_SIZE, TEXT_DIM)

func _draw_drift_bar() -> void:
	var x := (size.x - BAR_W) * 0.5
	var y := size.y - BAR_MARGIN_B
	draw_style_box(_sb_track, Rect2(x, y, BAR_W, BAR_H))

	if _charge > 0.002:
		var col := ACCENT
		if _boost_flash > 0.0:
			col = Color(1, 1, 1, 0.95)
		elif _charge >= 0.999:
			col = ACCENT_HOT
		_sb_fill.bg_color = col
		var fill_w := maxf(BAR_H, BAR_W * _charge)
		draw_style_box(_sb_fill, Rect2(x, y, fill_w, BAR_H))

	# "BOOST READY" hint once fully charged.
	if _charge >= 0.999 or _boost_flash > 0.0:
		var font := ThemeDB.fallback_font
		var label := "BOOST READY"
		var lbl_dim := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		draw_string(font, Vector2((size.x - lbl_dim.x) * 0.5, y - 10.0),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ACCENT_HOT)
