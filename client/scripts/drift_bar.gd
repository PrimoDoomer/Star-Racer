extends Control

# Flat in-race HUD, sitting left of screen centre:
#   - a circular drift-boost gauge (an arc that fills as the boost charges and
#     flashes white the instant a boost fires)
#   - a clean speed read-out centred inside the gauge.

const ACCENT     := Color(1.00, 0.62, 0.20)        # warm amber
const ACCENT_HOT := Color(1.00, 0.82, 0.42)        # brighter still when fully charged / firing
const TRACK_BG   := Color(0.14, 0.18, 0.24, 0.80)  # emptied arc
const DEGR_TRACK := Color(0.30, 0.23, 0.12, 0.80)  # emptied arc inside the degressive zone (amber)
const DEGR_FILL  := Color(1.00, 0.78, 0.32)        # fill turns amber past the knee ("slow zone")
const DISC_BG    := Color(0.04, 0.05, 0.07, 0.42)  # backing disc for legibility over any scene
const TEXT_MAIN  := Color(0.96, 0.98, 1.00, 0.96)
const TEXT_HALO  := Color(0.02, 0.03, 0.05, 0.85)  # dark outline behind the speed for contrast
const TEXT_DIM   := Color(0.72, 0.78, 0.86, 0.65)

# Gauge centred low on screen (conventional racing HUD spot), clear of the car.
const ANCHOR_X_FRAC := 0.5    # horizontal centre (fraction of screen width)
const ANCHOR_Y_FRAC := 0.82   # vertical centre (fraction of screen height) — low
const GAUGE_RADIUS  := 58.0
const GAUGE_WIDTH   := 12.0
const GAUGE_START_DEG := 135.0  # arc opens at the bottom (90° gap centred on the bottom)
const GAUGE_SWEEP_DEG := 270.0
const ARC_POINTS    := 64
# Charge fills normally up to here, then the rate tapers — mark it so the player
# can read the "slow to top off" zone. Mirrors player.gd BOOST_CHARGE_KNEE.
const CHARGE_KNEE   := 0.667

const SPEED_SIZE    := 40
const UNIT_SIZE     := 13
# Displayed km/h is scaled up for an arcade "fast" feel; the underlying speed is
# also low-pass filtered (below) so the number reads steadily instead of jittering.
const SPEED_SCALE   := 6.0   # doubled when real speed was halved → km/h still reads fast
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
	var knee := start + sweep * CHARGE_KNEE

	# Backing disc so the gauge and number stay legible over any background.
	draw_circle(center, GAUGE_RADIUS + GAUGE_WIDTH * 0.5 + 9.0, DISC_BG)

	# Drift-boost gauge track. The final third (past the knee) is tinted amber to
	# mark the degressive "slow to fill" zone, with a tick at the knee.
	draw_arc(center, GAUGE_RADIUS, start, start + sweep, ARC_POINTS, TRACK_BG, GAUGE_WIDTH, true)
	draw_arc(center, GAUGE_RADIUS, knee, start + sweep, ARC_POINTS, DEGR_TRACK, GAUGE_WIDTH, true)
	var kdir := Vector2(cos(knee), sin(knee))
	draw_line(center + kdir * (GAUGE_RADIUS - GAUGE_WIDTH * 0.5 - 2.0),
		center + kdir * (GAUGE_RADIUS + GAUGE_WIDTH * 0.5 + 5.0), Color(1, 1, 1, 0.55), 2.0)

	# Fill: cyan up to the knee, amber beyond it; unified bright on full / firing.
	if _charge > 0.002:
		var fill_end := start + sweep * _charge
		var hot := _boost_flash > 0.0 or _charge >= 0.999
		var col_lo := Color(1, 1, 1, 0.97) if _boost_flash > 0.0 else (ACCENT_HOT if _charge >= 0.999 else ACCENT)
		var col_hi := col_lo if hot else DEGR_FILL
		draw_arc(center, GAUGE_RADIUS, start, minf(fill_end, knee), ARC_POINTS, col_lo, GAUGE_WIDTH, true)
		if fill_end > knee:
			draw_arc(center, GAUGE_RADIUS, knee, fill_end, ARC_POINTS, col_hi, GAUGE_WIDTH, true)

	# Speed read-out centred inside the gauge: a heavy number (dark halo + faux-bold
	# fill) over a small unit.
	var num := "%d" % _speed_kmh
	var num_dim := font.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, SPEED_SIZE)
	var num_pos := Vector2(center.x - num_dim.x * 0.5, center.y + num_dim.y * 0.30)
	draw_string_outline(font, num_pos, num, HORIZONTAL_ALIGNMENT_LEFT, -1, SPEED_SIZE, 6, TEXT_HALO)
	draw_string_outline(font, num_pos, num, HORIZONTAL_ALIGNMENT_LEFT, -1, SPEED_SIZE, 2, TEXT_MAIN)
	draw_string(font, num_pos, num, HORIZONTAL_ALIGNMENT_LEFT, -1, SPEED_SIZE, TEXT_MAIN)

	var unit := "KM/H"
	var unit_dim := font.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, UNIT_SIZE)
	draw_string(font, Vector2(center.x - unit_dim.x * 0.5, num_pos.y + UNIT_SIZE + 4.0), unit,
		HORIZONTAL_ALIGNMENT_LEFT, -1, UNIT_SIZE, TEXT_DIM)

	# "BOOST READY" above the gauge when fully charged / firing.
	if _charge >= 0.999 or _boost_flash > 0.0:
		var label := tr("boost_ready")
		var lbl_dim := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		draw_string(font, Vector2(center.x - lbl_dim.x * 0.5, center.y - GAUGE_RADIUS - 10.0),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ACCENT_HOT)
