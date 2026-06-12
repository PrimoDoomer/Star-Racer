extends Control

# Three-segment start light + sound. Driven by Game's Countdown / RaceStarted events.
# - Countdown(t):
#     t == 3 → segment 1 red + DONG
#     t == 2 → segment 2 red + DONG
#     t == 1 → segment 3 red + DONG
# - RaceStarted → all segments flash green + DIIIING, then fade out.
#
# Flat-minimal look: clean rounded segments, no gloss or rims.

const SEG_W         := 90.0
const SEG_H         := 34.0
const SEG_GAP       := 16.0
const SEG_RADIUS    := 14
const FADE_DURATION := 1.2

const COLOR_OFF   := Color(0.12, 0.14, 0.18, 0.9)
const COLOR_ARMED := Color(0.95, 0.28, 0.22, 1.0)
const COLOR_GO    := Color(0.30, 0.85, 0.45, 1.0)

var _states: Array[int] = [0, 0, 0]  # 0=off, 1=armed (red), 2=go (green)
var _go_flash: float = 0.0
var _hide_timer: float = 0.0
var _last_countdown_handled: int = -1

var _sb: StyleBoxFlat = null

@onready var _audio_dong: AudioStreamPlayer = $Dong
@onready var _audio_ding: AudioStreamPlayer = $Ding

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sb = StyleBoxFlat.new()
	_sb.set_corner_radius_all(SEG_RADIUS)
	_audio_dong.stream = _make_tone(520.0, 0.18, 5.0)
	_audio_ding.stream = _make_tone(900.0, 0.7, 1.4, 1.5)

func reset() -> void:
	_states = [0, 0, 0]
	_go_flash = 0.0
	_hide_timer = 0.0
	_last_countdown_handled = -1
	# Stay hidden through the silent pre-countdown beat; the first countdown
	# (or the GO flash) makes the lights appear.
	visible = false
	queue_redraw()

func on_countdown(time_sec: float) -> void:
	# Server emits 5,4,3,2,1,0 (approx). We only react to 3, 2, 1.
	var t := int(round(time_sec))
	if t == _last_countdown_handled:
		return
	_last_countdown_handled = t
	visible = true
	match t:
		3:
			_states[0] = 1
			_audio_dong.play()
		2:
			_states[1] = 1
			_audio_dong.play()
		1:
			_states[2] = 1
			_audio_dong.play()
	queue_redraw()

func on_race_started() -> void:
	_states = [2, 2, 2]
	_go_flash = 1.0
	_hide_timer = FADE_DURATION
	_audio_ding.play()
	visible = true
	queue_redraw()

func hide_now() -> void:
	visible = false
	_hide_timer = 0.0

func _process(delta: float) -> void:
	if not visible:
		return
	if _go_flash > 0.0:
		_go_flash = maxf(_go_flash - delta * 2.0, 0.0)
		queue_redraw()
	if _hide_timer > 0.0:
		_hide_timer -= delta
		if _hide_timer <= 0.0:
			visible = false

func _draw() -> void:
	var total := SEG_W * 3.0 + SEG_GAP * 2.0
	var start_x := size.x * 0.5 - total * 0.5
	var y := size.y * 0.5 - SEG_H * 0.5
	for i in 3:
		var rx := start_x + (SEG_W + SEG_GAP) * float(i)
		var fill: Color
		match _states[i]:
			1: fill = COLOR_ARMED
			2:
				fill = COLOR_GO
				if _go_flash > 0.0:
					fill = fill.lerp(Color(1, 1, 1, 1), _go_flash * 0.7)
			_: fill = COLOR_OFF
		_sb.bg_color = fill
		draw_style_box(_sb, Rect2(rx, y, SEG_W, SEG_H))

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
