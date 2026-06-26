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
const KMH_DISPLAY_SCALE   := 6.0   # doubled when real speed was halved → km/h still reads fast
const SPEED_SMOOTH  := 6.0   # lower = steadier read-out (was effectively 12)

# Turbo gauge: a second, inner ring inside the drift gauge — cool blue so it reads
# as a distinct meter from the amber drift-boost.
const TURBO_COL     := Color(0.36, 0.72, 1.00)
const TURBO_COL_HOT := Color(0.66, 0.88, 1.00)
const TURBO_RADIUS  := 44.0
const TURBO_WIDTH   := 6.0

# Respawn hold feedback — mirrors player.gd RESPAWN_HOLD_SECS so the ring fills in
# lockstep with the server-side respawn trigger.
const RESPAWN_HOLD_SECS := 1.0

var _charge: float = 0.0
var _boost_flash: float = 0.0
var _armed: bool = false  # boost is PENDING (locked in, fires when the car straightens)
var _pulse_t: float = 0.0  # free-running clock for the "armed" pulse
var _respawn_hold: float = 0.0  # seconds the respawn key has been held (read from the car)
var _turbo: float = 0.0  # turbo bar charge 0..1 (read from the car)
var _turbo_active: bool = false  # turbo currently being spent
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
	_pulse_t += delta

	if game.car_node != null and delta > 0.0:
		var rb := game.car_node as RigidBody3D
		_charge = rb.get("drift_charge") as float
		# BoostState.PENDING == 1: the boost is armed and will fire the moment the
		# car re-aligns with its heading (player straightens out of the drift).
		_armed = rb.get("_boost_state") == 1
		var rh = rb.get("_respawn_hold_time")
		_respawn_hold = rh if rh != null else 0.0
		var tc = rb.get("_turbo_charge")
		_turbo = tc if tc != null else 0.0
		_turbo_active = rb.get("_turbo_active") == true
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
		var kmh := _kmh_smoothed * KMH_DISPLAY_SCALE
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
		# Armed (boost PENDING): pulse a white sheen over the charged arc so the
		# player sees the boost is locked in and will fire as they straighten out.
		if _armed:
			var pulse := 0.30 + 0.30 * sin(_pulse_t * 12.0)
			draw_arc(center, GAUGE_RADIUS, start, fill_end, ARC_POINTS, Color(1, 1, 1, pulse), GAUGE_WIDTH, true)

	# Turbo gauge: an inner blue ring, distinct from the amber drift-boost. Fills with
	# the turbo bar; brightens + pulses while turbo is being spent.
	draw_arc(center, TURBO_RADIUS, start, start + sweep, ARC_POINTS, TRACK_BG, TURBO_WIDTH, true)
	if _turbo > 0.002:
		var tend := start + sweep * _turbo
		draw_arc(center, TURBO_RADIUS, start, tend, ARC_POINTS,
			TURBO_COL_HOT if _turbo_active else TURBO_COL, TURBO_WIDTH, true)
		if _turbo_active:
			var tp := 0.30 + 0.30 * sin(_pulse_t * 16.0)
			draw_arc(center, TURBO_RADIUS, start, tend, ARC_POINTS, Color(1, 1, 1, tp), TURBO_WIDTH, true)

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

	_draw_ring_caption(font, center, TURBO_RADIUS + 9.0, tr("hud_turbo"), Color(TURBO_COL, 0.85))
	_draw_ring_caption(font, center, GAUGE_RADIUS + 9.0, tr("hud_boost"), Color(ACCENT, 0.85))

	# "BOOST READY" above the gauge when fully charged, armed (pending), or firing.
	if _charge >= 0.999 or _boost_flash > 0.0 or _armed:
		var label := tr("boost_ready")
		var lbl_dim := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		draw_string(font, Vector2(center.x - lbl_dim.x * 0.5, center.y - GAUGE_RADIUS - 10.0),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ACCENT_HOT)

	# Respawn hold: a discreet little ring that charges over the 2 s hold, with a
	# small caption — enough to show it's working and when it fires, nothing more.
	if _respawn_hold > 0.05:
		var prog := clampf(_respawn_hold / RESPAWN_HOLD_SECS, 0.0, 1.0)
		var done := prog >= 1.0
		var rc := Vector2(size.x * 0.5, size.y * 0.40)
		var rr := 20.0
		var rw := 4.0
		draw_arc(rc, rr, 0.0, TAU, 40, Color(0.5, 0.55, 0.62, 0.35), rw, true)
		draw_arc(rc, rr, -PI / 2.0, -PI / 2.0 + TAU * prog, 40, ACCENT_HOT if done else ACCENT, rw, true)
		var lab := tr("act_Respawn")
		var ld := font.get_string_size(lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		draw_string(font, Vector2(rc.x - ld.x * 0.5, rc.y + rr + 15.0),
			lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_DIM)

func _draw_ring_caption(font: Font, center: Vector2, radius: float, text: String, col: Color) -> void:
	const CAP_SIZE := 10
	var dim := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, CAP_SIZE)
	draw_string(font, Vector2(center.x - dim.x * 0.5, center.y + radius), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, CAP_SIZE, col)
