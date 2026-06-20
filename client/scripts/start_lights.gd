extends Control

# Three glowing start dots + sound, driven by Game's Countdown / RaceStarted events.
# - Countdown(t): t==3 → dot 1 lights (low dong), t==2 → dot 2 (mid dong),
#                 t==1 → dot 3 (high dong). Each light-up pulses a glow.
# - RaceStarted → all three flash green + bright DIIIING, then fade.
# Plus a rocket-start score, shown when the player nails the throttle on GO.
#
# Dots sit centred in the upper half of the screen.

const DOT_RADIUS    := 22.0
const DOT_GAP       := 74.0    # centre-to-centre spacing
const CENTER_Y_FRAC := 0.25    # vertical centre of the dots (upper-half centre)
const FADE_DURATION := 1.2
const ROCKET_HOLD   := 1.7

const COLOR_OFF     := Color(0.12, 0.14, 0.18, 0.85)
const COLOR_ARMED   := Color(0.97, 0.30, 0.24, 1.0)
const COLOR_GO      := Color(0.32, 0.88, 0.48, 1.0)
const COLOR_RELEASE := Color(0.55, 1.0, 0.85, 1.0)  # the 4th dot: "inputs free" — glows brighter
const COLOR_RING    := Color(1, 1, 1, 0.18)

# Four dots: 1–3 arm red on the 3·2·1 beats; the 4th lights green on GO and glows
# distinctly — it's the "inputs released" signal.
var _states: Array[int] = [0, 0, 0, 0]      # 0=off, 1=armed (red), 2=go (green), 3=release
var _lit_flash: Array[float] = [0.0, 0.0, 0.0, 0.0]  # per-dot glow pulse on light-up
var _go_flash: float = 0.0
var _hide_timer: float = 0.0
var _went_go: bool = false
var _last_countdown_handled: int = -1

# Rocket-start grade shown as a rank letter instead of a raw percentage. Higher
# ranks are bigger and louder: A is spectacular (halo + shock ring), S more so
# (bigger still + a rainbow shimmer + a double ring).
const RANK_LETTERS := ["D", "C", "B", "A", "S"]
const RANK_COLORS := [
	Color(0.80, 0.84, 0.90),   # D — plain silver
	Color(0.52, 0.86, 0.60),   # C — green
	Color(0.40, 0.70, 1.00),   # B — blue
	Color(1.00, 0.72, 0.18),   # A — gold
	Color(0.62, 1.00, 0.96),   # S — bright cyan
]
const RANK_FONT := [56, 60, 68, 94, 120]   # base px per rank
const RANK_SPECTACLE := [0.0, 0.0, 0.0, 0.6, 1.0]  # 0 = none, 1 = full flair

var _rocket_rank: int = -1
var _rocket_color: Color = Color.WHITE
var _rocket_timer: float = 0.0

@onready var _audio_dong: AudioStreamPlayer = $Dong
@onready var _audio_ding: AudioStreamPlayer = $Ding

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_audio_dong.stream = _make_tone(520.0, 0.18, 5.0)
	_audio_ding.stream = _make_tone(900.0, 0.7, 1.4, 1.5)

func reset() -> void:
	_states = [0, 0, 0, 0]
	_lit_flash = [0.0, 0.0, 0.0, 0.0]
	_go_flash = 0.0
	_hide_timer = 0.0
	_went_go = false
	_last_countdown_handled = -1
	_rocket_rank = -1
	_rocket_timer = 0.0
	# Stay hidden through the silent pre-countdown beat; the first countdown
	# (or the GO flash) makes the dots appear.
	visible = false
	queue_redraw()

func on_countdown(time_sec: float) -> void:
	# Server emits 5,4,3,2,1,0 (approx). We only react to 3, 2, 1.
	var t := int(round(time_sec))
	if t == _last_countdown_handled:
		return
	_last_countdown_handled = t
	var idx := -1
	match t:
		3: idx = 0
		2: idx = 1
		1: idx = 2
	if idx < 0:
		return
	visible = true
	_states[idx] = 1
	_lit_flash[idx] = 1.0
	# Rising pitch across the three beats — a little build-up of tension.
	_audio_dong.pitch_scale = [0.84, 1.0, 1.18][idx]
	_audio_dong.play()
	queue_redraw()

func on_race_started() -> void:
	_states = [2, 2, 2, 3]  # 1–3 flip green; the 4th is the special "inputs free" dot
	_lit_flash = [1.0, 1.0, 1.0, 1.0]
	_go_flash = 1.0
	_hide_timer = FADE_DURATION
	_went_go = true
	_audio_ding.play()
	visible = true
	queue_redraw()

## quality in 0..1 (1 = pressed exactly on GO), or <0 for a missed window (no boost).
func show_rocket_score(quality: float) -> void:
	if quality < 0.0:
		_rocket_rank = -1
		return
	_rocket_rank = _rank_for(quality)
	_rocket_color = RANK_COLORS[_rocket_rank]
	_rocket_timer = ROCKET_HOLD
	visible = true
	queue_redraw()

## Map a launch quality (0..1) onto a D/C/B/A/S rank. S is reserved for a near
## frame-perfect launch, so it stays rare; every tier above D still grants a boost.
func _rank_for(quality: float) -> int:
	if quality >= 0.90:
		return 4  # S
	if quality >= 0.70:
		return 3  # A
	if quality >= 0.48:
		return 2  # B
	if quality >= 0.25:
		return 1  # C
	return 0      # D

func hide_now() -> void:
	visible = false
	_hide_timer = 0.0
	_rocket_timer = 0.0
	_went_go = false

func _process(delta: float) -> void:
	if not visible:
		return
	if _go_flash > 0.0:
		_go_flash = maxf(_go_flash - delta * 2.0, 0.0)
	for i in 4:
		if _lit_flash[i] > 0.0:
			_lit_flash[i] = maxf(_lit_flash[i] - delta * 3.0, 0.0)
	if _rocket_timer > 0.0:
		_rocket_timer -= delta
	if _hide_timer > 0.0:
		_hide_timer -= delta
	# Hide only once the GO fade and any rocket score have both finished.
	if _went_go and _hide_timer <= 0.0 and _rocket_timer <= 0.0:
		visible = false
		_went_go = false
	queue_redraw()

func _draw() -> void:
	var total := DOT_GAP * 3.0
	var cx0 := size.x * 0.5 - total * 0.5
	var cy := size.y * CENTER_Y_FRAC
	for i in 4:
		var c := Vector2(cx0 + DOT_GAP * float(i), cy)
		var col := COLOR_OFF
		var release := _states[i] == 3
		match _states[i]:
			1: col = COLOR_ARMED
			2:
				col = COLOR_GO
				if _go_flash > 0.0:
					col = col.lerp(Color(1, 1, 1, 1), _go_flash * 0.7)
			3:
				col = COLOR_RELEASE
				if _go_flash > 0.0:
					col = col.lerp(Color(1, 1, 1, 1), _go_flash * 0.5)
		if _states[i] != 0:
			# The 4th (release) dot glows bigger + brighter than the others.
			_draw_glow(c, col, _lit_flash[i], 1.6 if release else 1.0)
		if release:
			# An expanding ring pulses out of the release dot on GO.
			var rr: float = DOT_RADIUS * (1.6 + (1.0 - _go_flash) * 2.0)
			draw_arc(c, rr, 0.0, TAU, 40, Color(col.r, col.g, col.b, _go_flash * 0.6), 3.0, true)
		draw_circle(c, DOT_RADIUS, col)
		draw_arc(c, DOT_RADIUS, 0.0, TAU, 32, COLOR_RING, 2.0, true)

	if _rocket_timer > 0.0:
		_draw_rocket_score(cy)

# Soft halo behind a lit dot — a few translucent rings, brightened by the
# light-up pulse so each dot "glows on" when it arms. `gain` widens the halo for
# the special release dot.
func _draw_glow(c: Vector2, col: Color, flash: float, gain: float = 1.0) -> void:
	var layers := [[2.7, 0.08], [2.0, 0.13], [1.4, 0.22]]
	for l in layers:
		var r: float = DOT_RADIUS * (float(l[0]) * gain + flash * 0.5)
		var a: float = float(l[1]) + flash * 0.30
		draw_circle(c, r, Color(col.r, col.g, col.b, a))

func _draw_rocket_score(cy: float) -> void:
	if _rocket_rank < 0:
		return
	var elapsed: float = ROCKET_HOLD - _rocket_timer
	var fade: float = clampf(_rocket_timer / 0.6, 0.0, 1.0)        # fade over the last 0.6 s
	var pop: float = 1.0 - clampf(elapsed / 0.26, 0.0, 1.0)        # quick scale-in on appear
	var spec: float = RANK_SPECTACLE[_rocket_rank]
	var col: Color = _rocket_color
	var center := Vector2(size.x * 0.5, cy + DOT_RADIUS * 3.6)

	# Spectacular backdrop for A/S: halo + expanding shock ring(s).
	if spec > 0.0:
		_draw_rank_spectacle(center, col, elapsed, fade, spec)

	# A subtle breathing pulse (stronger on the spectacular ranks) plus the pop-in.
	var pulse: float = 1.0 + sin(elapsed * 9.0) * 0.05 * spec + pop * 0.45
	var fs: int = int(RANK_FONT[_rocket_rank] * pulse)
	var font := ThemeDB.fallback_font
	var letter: String = RANK_LETTERS[_rocket_rank]

	# S shimmers through the spectrum; the others keep their flat rank colour.
	var draw_col: Color = col
	if _rocket_rank == 4:
		draw_col = Color.from_hsv(fmod(elapsed * 0.7, 1.0), 0.40, 1.0).lerp(col, 0.35)
	draw_col.a = fade

	var dim := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pos := Vector2(center.x - dim.x * 0.5, center.y + fs * 0.36)

	# Soft glow behind the glyph (offset copies), widening with the spectacle.
	var glow := Color(col.r, col.g, col.b, fade * (0.18 + 0.30 * spec))
	for ring: float in [3.0, 6.5]:
		for ang: float in [0.0, PI * 0.5, PI, PI * 1.5]:
			var off := Vector2(cos(ang), sin(ang)) * ring * (1.0 + spec)
			draw_string(font, pos + off, letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, glow)
	draw_string(font, pos, letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, draw_col)

# Halo + expanding shock ring(s) behind a high-rank letter. `spec` (0..1) scales the
# whole flourish; S (spec == 1) gets a second, offset ring.
func _draw_rank_spectacle(c: Vector2, col: Color, elapsed: float, fade: float, spec: float) -> void:
	for i in 4:
		var rr: float = (44.0 + i * 24.0) * (1.0 + spec * 0.4)
		var aa: float = (0.11 - i * 0.022) * fade * spec
		if aa > 0.0:
			draw_circle(c, rr, Color(col.r, col.g, col.b, aa))
	var rings: int = 2 if spec >= 1.0 else 1
	for k in rings:
		var t: float = fmod(elapsed * 1.4 + float(k) * 0.5, 1.0)
		var rr: float = 32.0 + t * 150.0 * (0.7 + spec)
		var aa: float = (1.0 - t) * 0.5 * fade * spec
		draw_arc(c, rr, 0.0, TAU, 48, Color(col.r, col.g, col.b, aa), 3.0, true)

# ----------------------------------------------------------------------------
# Tone synthesis: short sine with exponential decay, optional second harmonic.
# Returns an AudioStreamWAV that the caller can `.play()` at any time.

func _make_tone(freq: float, duration: float, decay: float = 5.0,
		harmonic_mult: float = 0.0) -> AudioStreamWAV:
	var rate := 22050
	var sample_count := int(duration * float(rate))
	var data := PackedByteArray()
	data.resize(sample_count * 2)  # 16-bit mono
	for i in sample_count:
		var t := float(i) / float(rate)
		var env := exp(-t * decay)
		var s := sin(t * freq * TAU) * env
		if harmonic_mult > 0.0:
			s += sin(t * freq * harmonic_mult * TAU) * env * 0.5
		s *= 0.55  # peak amplitude
		var sample := int(clampf(s, -1.0, 1.0) * 32767.0)
		data[i * 2]     = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav
