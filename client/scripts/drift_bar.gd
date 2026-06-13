extends Control

# Flat in-race HUD, sitting left of screen centre:
#   - a circular drift-boost gauge (an arc that fills as the boost charges and
#     flashes white the instant a boost fires)
#   - a clean speed read-out centred inside the gauge.

const ACCENT     := Color(0.45, 0.56, 0.68)
const ACCENT_HOT := Color(0.62, 0.74, 0.88)
const TRACK_BG   := Color(0.10, 0.12, 0.16, 0.55)
const TEXT_MAIN  := Color(0.95, 0.97, 1.00, 0.82)
const TEXT_DIM   := Color(0.72, 0.78, 0.86, 0.5)

# Gauge placed left of centre, on the gaze line just under the player's car.
const ANCHOR_X_FRAC := 0.34   # horizontal centre (fraction of screen width) — left of centre
const ANCHOR_Y_FRAC := 0.72   # vertical centre (fraction of screen height)
const GAUGE_RADIUS  := 50.0
const GAUGE_WIDTH   := 6.0
const GAUGE_START_DEG := 135.0  # arc opens at the bottom (90° gap centred on the bottom)
const GAUGE_SWEEP_DEG := 270.0
const ARC_POINTS    := 64

const SPEED_SIZE    := 34
const UNIT_SIZE     := 12
# Displayed km/h is scaled up for an arcade "fast" feel; the underlying speed is
# also low-pass filtered (below) so the number reads steadily instead of jittering.
const SPEED_SCALE   := 3.0
const SPEED_SMOOTH  := 6.0   # lower = steadier read-out (was effectively 12)

var _charge: float = 0.0
var _boost_flash: float = 0.0
var _speed_kmh: int = 0
var _prev_pos: Vector3 = Vector3.ZERO
var _prev_pos_valid := false
var _kmh_smoothed: float = 0.0

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

		# Speed via position delta — reliable even when global_position is being
		# written directly for server reconciliation (which leaves linear_velocity
		# stale).
		var pos := rb.global_position
		var inst_kmh := 0.0
		if _prev_pos_valid:
			var d := Vector2(pos.x - _prev_pos.x, pos.z - _prev_pos.z).length()
			inst_kmh = (d / delta) * 3.6
		_prev_pos = pos
		_prev_pos_valid = true

		# Low-pass filter to hide per-frame jitter, then scale for the read-out.
		_kmh_smoothed = lerp(_kmh_smoothed, inst_kmh, clampf(delta * SPEED_SMOOTH, 0.0, 1.0))
		var kmh := _kmh_smoothed * SPEED_SCALE
		if kmh < 1.0:
			kmh = 0.0
		_speed_kmh = int(round(kmh))

	if _boost_flash > 0.0:
		_boost_flash -= delta

	queue_redraw()

func _draw() -> void:
	var font := ThemeDB.fallback_font
	var center := Vector2(size.x * ANCHOR_X_FRAC, size.y * ANCHOR_Y_FRAC)

	var start := deg_to_rad(GAUGE_START_DEG)
	var sweep := deg_to_rad(GAUGE_SWEEP_DEG)

	# Drift-boost gauge: a faint arc track, filled clockwise by the charge.
	draw_arc(center, GAUGE_RADIUS, start, start + sweep, ARC_POINTS, TRACK_BG, GAUGE_WIDTH, true)
	if _charge > 0.002:
		var col := ACCENT
		if _boost_flash > 0.0:
			col = Color(1, 1, 1, 0.95)
		elif _charge >= 0.999:
			col = ACCENT_HOT
		draw_arc(center, GAUGE_RADIUS, start, start + sweep * _charge, ARC_POINTS, col, GAUGE_WIDTH, true)

	# Speed read-out centred inside the gauge: big number, small unit below.
	var num := "%d" % _speed_kmh
	var num_dim := font.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, SPEED_SIZE)
	var num_baseline := center.y + num_dim.y * 0.30
	draw_string(font, Vector2(center.x - num_dim.x * 0.5, num_baseline), num,
		HORIZONTAL_ALIGNMENT_LEFT, -1, SPEED_SIZE, TEXT_MAIN)

	var unit := "KM/H"
	var unit_dim := font.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, UNIT_SIZE)
	draw_string(font, Vector2(center.x - unit_dim.x * 0.5, num_baseline + UNIT_SIZE + 3.0), unit,
		HORIZONTAL_ALIGNMENT_LEFT, -1, UNIT_SIZE, TEXT_DIM)

	# "BOOST READY" above the gauge when fully charged / firing.
	if _charge >= 0.999 or _boost_flash > 0.0:
		var label := tr("boost_ready")
		var lbl_dim := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
		draw_string(font, Vector2(center.x - lbl_dim.x * 0.5, center.y - GAUGE_RADIUS - 8.0),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ACCENT_HOT)
