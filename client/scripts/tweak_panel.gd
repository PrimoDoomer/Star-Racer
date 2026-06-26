# Per-lobby gameplay-tweak dialog, shown at lobby creation. One numeric field per
# physics constant, grouped into human sections with plain-language labels (not the
# raw tuning identifiers) and a description on hover (the whole line is hoverable).
# Only the handful of constants that actually shape the feel are shown by default;
# the low-level internals sit under an "Advanced" switch so the panel stays short
# and readable. Styled to match the rest of the menu (About/settings cards). Built
# entirely in code from tuning.gd so it never drifts from tuning.txt, and returns a
# SPARSE map (only the values the creator changed) carried by CreateLobby. See
# game.gd / ui.gd.
extends Control

const Tuning = preload("res://scripts/tuning.gd")

const ACCENT := Color(0.95, 0.6, 0.23)
const TEXT := Color(0.88, 0.92, 0.98)
const TEXT_DIM := Color(0.55, 0.62, 0.71)

# The everyday feel knobs, shown by default. Ordered top-to-bottom like a settings
# page, with a bilingual section title.
# One ordered, well-sorted section per domain (mirrors tuning.txt's own grouping),
# every constant in its place — most-used knobs near the top of each section. Any
# tuning constant not listed here still shows (under "Other"), so a new one can
# never be silently un-tweakable.
const GROUPS := [
	{"en": "Overall pace", "fr": "Allure générale", "names": ["PACE_SCALE"]},
	{"en": "Car body", "fr": "Châssis", "names":
		["MASS", "GRAVITY", "COM_Y", "INERTIA_X", "INERTIA_Y", "INERTIA_Z"]},
	{"en": "Engine & brakes", "fr": "Moteur et freins", "names":
		["THROTTLE_FORCE", "BRAKE_FORCE", "REVERSE_FORCE", "BRAKE_MIN_SPEED"]},
	{"en": "Glide & coast", "fr": "Glisse et inertie", "names":
		["NORMAL_LINEAR_DAMPING", "DRIFT_LINEAR_DAMPING", "DRIFT_MIN_SPEED"]},
	{"en": "Steering & grip", "fr": "Direction et adhérence", "names":
		["MAX_TURN_RATE_GRIP", "MAX_TURN_RATE_DRIFT", "GRIP_LAT_ACCEL", "DRIFT_REDIRECT_RATE",
		"STEER_P_GAIN"]},
	{"en": "Drift feel", "fr": "Ressenti du drift", "names":
		["DRIFT_FLOOR_SPEED", "DRIFT_SPEED_PENALTY", "SLIP_BREAK_DEG", "DRIFT_FLICK_RATE",
		"SLIP_BREAK_HARD_DEG",
		"DRIFT_EFFORT_SPEED_REF", "SLIP_EXIT_DEG", "DRIFT_FLICK_BLEND", "GRIP_BLEND_RATE",
		"GRIP_BLEND_EXIT_RATE"]},
	{"en": "Spin", "fr": "Tête-à-queue", "names":
		["SPIN_GUARD_DEG", "SPIN_RESTORE_RATE", "SPIN_LIMIT_DEG"]},
	{"en": "Self-righting", "fr": "Redressement au sol", "names":
		["UPRIGHT_GAIN", "UPRIGHT_DAMP", "GROUND_ALIGN_MIN_NY"]},
	{"en": "Suspension", "fr": "Suspension", "names":
		["SUSP_REST_LEN", "SUSP_MAX_LEN", "SUSP_STIFFNESS", "SUSP_DAMP"]},
	{"en": "Air-roll (tonneau)", "fr": "Tonneau", "names":
		["AIRROLL_RANGE", "AIRROLL_AIM_LATERAL", "AIRROLL_PULL_SPEED", "AIRROLL_RECOVER_TIME",
		"AIRROLL_RECOVER_GAIN", "AIRROLL_RECOVER_DAMP", "AIRROLL_SPIN", "AIRROLL_DODGE_SPEED"]},
	{"en": "Ground & jump", "fr": "Appui et saut", "names":
		["JUMP_SPEED", "COYOTE_GROUND_SECS", "MOTION_DIRECTION_EPSILON"]},
	{"en": "Drift boost", "fr": "Boost de drift", "names":
		["BOOST_PEAK_BONUS", "BOOST_DURATION", "BOOST_CHARGE_RATE", "BOOST_CHARGE_ANGLE_RATE",
		"BOOST_CHARGE_ANGLE_REF_DEG", "BOOST_CHARGE_KNEE", "BOOST_CHARGE_TOP_FACTOR",
		"BOOST_CHARGE_DECAY", "BOOST_CHARGE_MIN", "BOOST_ALIGN_THRESHOLD_COS",
		"BOOST_PENDING_TIMEOUT", "BOOST_SUSTAIN_FORCE"]},
	{"en": "Turbo", "fr": "Turbo", "names":
		["TURBO_FORCE", "TURBO_PEAK_SPEED", "CRUISE_SPEED", "TURBO_CHARGE_RATE",
		"TURBO_CHARGE_ANGLE_RATE", "TURBO_DRAIN_RATE"]},
	{"en": "Rocket start", "fr": "Départ canon", "names":
		["LAUNCH_SPEED", "LAUNCH_WINDOW", "LAUNCH_SHARPNESS", "PAD_BOOST_SCALE"]},
]

# Plain-language name + one-line description for every constant, [en, fr, en_desc,
# fr_desc]. The raw identifier and default value still show on hover (tooltip).
const LABELS := {
	"PACE_SCALE": ["Overall pace", "Allure générale",
		"Master speed knob — scales forces, boosts and grip together.",
		"Réglage maître — met à l'échelle forces, boosts et adhérence ensemble."],
	"MASS": ["Weight", "Poids",
		"Heavier = more planted, slower to push around.",
		"Plus lourd = plus posé, plus dur à bouger."],
	"INERTIA_X": ["Pitch resistance", "Résistance au tangage",
		"How hard the car resists nose-up / nose-down rotation.",
		"Résistance de la voiture au basculement avant/arrière."],
	"INERTIA_Y": ["Turn-in resistance", "Résistance au lacet",
		"How hard the car resists spinning flat (yaw).",
		"Résistance de la voiture à pivoter à plat (lacet)."],
	"INERTIA_Z": ["Roll resistance", "Résistance au roulis",
		"How hard the car resists leaning side-to-side.",
		"Résistance de la voiture à pencher sur les côtés."],
	"COM_Y": ["Centre-of-mass height", "Hauteur du centre de masse",
		"Lower = harder to tip over.",
		"Plus bas = plus dur à faire basculer."],
	"GRAVITY": ["Gravity", "Gravité",
		"World downward pull.",
		"Attraction du monde vers le bas."],
	"THROTTLE_FORCE": ["Engine power", "Puissance moteur",
		"Acceleration push — also raises top speed.",
		"Poussée d'accélération — augmente aussi la vitesse de pointe."],
	"REVERSE_FORCE": ["Reverse power", "Puissance marche arrière",
		"Push when backing up.",
		"Poussée en marche arrière."],
	"BRAKE_FORCE": ["Braking power", "Puissance de freinage",
		"Stopping force when braking.",
		"Force de freinage."],
	"BRAKE_MIN_SPEED": ["Brake cut-off speed", "Vitesse d'arrêt du frein",
		"Below this speed braking stops (no reverse-creep).",
		"En dessous de cette vitesse le frein s'arrête."],
	"NORMAL_LINEAR_DAMPING": ["Coast drag", "Frein moteur",
		"Lower = more glide and a higher top speed.",
		"Plus bas = plus de glisse et une vitesse de pointe plus haute."],
	"DRIFT_LINEAR_DAMPING": ["Coast drag while drifting", "Frein moteur en drift",
		"Coast drag applied during a drift.",
		"Frein moteur appliqué pendant un drift."],
	"DRIFT_MIN_SPEED": ["Min drift speed", "Vitesse min. de drift",
		"Slower than this and you can't drift.",
		"En dessous, impossible de drifter."],
	"MAX_TURN_RATE_GRIP": ["Turn rate (gripping)", "Braquage (adhérence)",
		"How fast the car rotates while gripping.",
		"Vitesse de rotation en adhérence."],
	"MAX_TURN_RATE_DRIFT": ["Turn rate (drifting)", "Braquage (drift)",
		"How fast the nose swings into a corner while drifting. Higher = spins/tucks in more.",
		"Vitesse à laquelle le nez vient dans le virage en drift. Plus haut = pivote/tucke plus."],
	"STEER_P_GAIN": ["Steering response", "Réactivité de la direction",
		"How sharply steering reaches its target turn rate.",
		"Vivacité avec laquelle la direction atteint sa cible."],
	"GRIP_LAT_ACCEL": ["Lateral grip", "Adhérence latérale",
		"Sideways bite — too low and grip washes out at speed.",
		"Accroche latérale — trop bas, l'adhérence lâche à vitesse."],
	"DRIFT_REDIRECT_RATE": ["Drift redirect", "Réorientation du drift",
		"Higher = tighter spiral toward where the nose points (less side-slip).",
		"Plus haut = spirale plus serrée vers où pointe le nez (moins de déport)."],
	"DRIFT_FLOOR_SPEED": ["No-drift below", "Pas de drift en dessous de",
		"Below this speed drifting is fully off (kills near-standstill drifts).",
		"En dessous de cette vitesse, aucun drift (supprime les drifts quasi à l'arrêt)."],
	"DRIFT_SPEED_PENALTY": ["Drift speed loss", "Perte de vitesse en drift",
		"Speed scrubbed off for holding a drift.",
		"Vitesse perdue à maintenir un drift."],
	"SLIP_BREAK_DEG": ["Break-loose angle", "Angle de décrochage",
		"Slide angle at which grip falls into a drift.",
		"Angle de glisse où l'adhérence tombe en drift."],
	"SLIP_BREAK_HARD_DEG": ["Break angle (hard steer)", "Angle de décrochage (braquage fort)",
		"Lower break angle when cranking hard at speed.",
		"Angle de décrochage réduit en braquant fort à vitesse."],
	"DRIFT_EFFORT_SPEED_REF": ["Steer-effort speed", "Vitesse de l'effort de braquage",
		"Speed at which hard steering fully counts toward breaking loose.",
		"Vitesse à laquelle un fort braquage compte pleinement pour décrocher."],
	"SLIP_EXIT_DEG": ["Drift exit angle", "Angle de sortie de drift",
		"Slide must settle below this to leave the drift.",
		"La glisse doit repasser sous cet angle pour sortir du drift."],
	"DRIFT_FLICK_RATE": ["Flick strength", "Intensité du coup de volant",
		"Snap of the turn-in when you start a drift.",
		"Vivacité du coup de volant à l'entame d'un drift."],
	"DRIFT_FLICK_BLEND": ["Flick smoothing", "Douceur du coup de volant",
		"1 = instant snap, lower = smoother turn-in.",
		"1 = instantané, plus bas = entrée plus douce."],
	"GRIP_BLEND_RATE": ["Drift-in speed", "Entrée en drift",
		"How fast handling eases into the drift.",
		"Vitesse à laquelle la tenue bascule en drift."],
	"GRIP_BLEND_EXIT_RATE": ["Drift-out speed", "Sortie de drift",
		"How fast handling eases back to grip.",
		"Vitesse à laquelle la tenue revient en adhérence."],
	"SPIN_GUARD_DEG": ["Spin guard", "Garde anti tête-à-queue",
		"Slide angle where the anti-spin help kicks in. Higher = lets the car rotate more.",
		"Angle de glisse où l'aide intervient. Plus haut = laisse la voiture pivoter davantage."],
	"SPIN_LIMIT_DEG": ["Spin limit", "Limite anti tête-à-queue",
		"Angle where anti-spin help is at full strength.",
		"Angle où l'aide anti tête-à-queue est à son maximum."],
	"SPIN_RESTORE_RATE": ["Spin recovery", "Force de rattrapage",
		"How hard a runaway slide is pulled back. Lower = spins out more freely.",
		"Force avec laquelle une glisse incontrôlée est rattrapée. Plus bas = part en vrille plus librement."],
	"UPRIGHT_GAIN": ["Self-righting force", "Force de redressement",
		"How strongly the car turns itself upright on the ground.",
		"Force avec laquelle la voiture se redresse au sol."],
	"UPRIGHT_DAMP": ["Self-righting damping", "Amorti du redressement",
		"Damps the righting so it settles without wobbling.",
		"Amortit le redressement pour qu'il se pose sans trembler."],
	"GROUND_ALIGN_MIN_NY": ["Max followed bank", "Inclinaison max. suivie",
		"Steepest surface the car will hug instead of staying flat.",
		"Surface la plus inclinée que la voiture épouse au lieu de rester à plat."],
	"SUSP_REST_LEN": ["Ride height", "Hauteur de caisse",
		"Resting height of the body above the road.",
		"Hauteur de repos de la caisse au-dessus de la route."],
	"SUSP_MAX_LEN": ["Suspension reach", "Portée de suspension",
		"Beyond this the wheels are considered airborne.",
		"Au-delà, les roues sont considérées en l'air."],
	"SUSP_STIFFNESS": ["Suspension stiffness", "Raideur de suspension",
		"Higher = firmer, less squat.",
		"Plus haut = plus ferme, moins d'enfoncement."],
	"SUSP_DAMP": ["Suspension damping", "Amorti de suspension",
		"Tames suspension bounce.",
		"Limite les rebonds de la suspension."],
	"AIRROLL_RANGE": ["Air-roll reach", "Portée du tonneau",
		"How far the air-roll ray looks for a surface to land on.",
		"Distance à laquelle le tonneau cherche une surface où se poser."],
	"AIRROLL_AIM_LATERAL": ["Air-roll side aim", "Visée latérale du tonneau",
		"How much steering tilts the air-roll aim sideways.",
		"À quel point le braquage incline la visée du tonneau sur le côté."],
	"AIRROLL_PULL_SPEED": ["Surface pull", "Aspiration vers la surface",
		"Speed the car is pulled toward a hit surface.",
		"Vitesse d'aspiration vers la surface touchée."],
	"AIRROLL_RECOVER_TIME": ["Recover time", "Temps de redressement",
		"How long the wheels-down reorientation lasts.",
		"Durée de la remise sur les roues."],
	"AIRROLL_RECOVER_GAIN": ["Air recover force", "Force de redressement aérien",
		"How strongly the car reorients onto the surface.",
		"Force avec laquelle la voiture se réoriente sur la surface."],
	"AIRROLL_RECOVER_DAMP": ["Air recover damping", "Amorti du redressement aérien",
		"Damps the airborne reorientation.",
		"Amortit la réorientation en l'air."],
	"AIRROLL_SPIN": ["Barrel-roll speed", "Vitesse de tonneau",
		"Spin rate of a free barrel roll (no surface hit).",
		"Vitesse de rotation d'un tonneau libre (sans surface)."],
	"AIRROLL_DODGE_SPEED": ["Air-roll dodge", "Bond du tonneau",
		"Forward kick added by a free barrel roll.",
		"Coup vers l'avant ajouté par un tonneau libre."],
	"JUMP_SPEED": ["Jump strength", "Force de saut",
		"Upward speed of a hop.",
		"Vitesse vers le haut d'un saut."],
	"COYOTE_GROUND_SECS": ["Coyote grounding", "Tolérance d'appui",
		"Grace after leaving the ground where inputs still count.",
		"Délai après avoir quitté le sol où les commandes comptent encore."],
	"MOTION_DIRECTION_EPSILON": ["Forward/reverse threshold", "Seuil avant/arrière",
		"Speed deadzone before forward or reverse is decided.",
		"Zone morte de vitesse avant de décider avant ou arrière."],
	"BOOST_CHARGE_RATE": ["Boost charge (base)", "Charge du boost (base)",
		"Base fill rate of the drift-boost bar.",
		"Vitesse de remplissage de base de la jauge de boost."],
	"BOOST_CHARGE_ANGLE_RATE": ["Boost charge by angle", "Charge du boost selon l'angle",
		"Extra fill the more sideways you slide.",
		"Remplissage supplémentaire plus la glisse est marquée."],
	"BOOST_CHARGE_ANGLE_REF_DEG": ["Full-charge angle", "Angle de charge max.",
		"Slide angle that gives the most charge.",
		"Angle de glisse donnant le plus de charge."],
	"BOOST_CHARGE_KNEE": ["Charge taper point", "Seuil de ralentissement",
		"Bar fraction where filling slows toward full.",
		"Fraction de jauge où le remplissage ralentit vers le plein."],
	"BOOST_CHARGE_TOP_FACTOR": ["Top-up rate", "Vitesse de fin de jauge",
		"How slow the last part of the bar fills.",
		"À quel point la fin de jauge se remplit lentement."],
	"BOOST_CHARGE_DECAY": ["Charge decay", "Perte de charge",
		"How fast the boost bar drains when not drifting.",
		"Vitesse à laquelle la jauge se vide hors drift."],
	"BOOST_CHARGE_MIN": ["Min charge to fire", "Charge min. pour booster",
		"Smallest bar that still triggers a boost.",
		"Charge minimale qui déclenche encore un boost."],
	"BOOST_PEAK_BONUS": ["Boost speed bonus", "Gain de vitesse du boost",
		"Top speed added by a full boost.",
		"Vitesse ajoutée par un boost plein."],
	"BOOST_DURATION": ["Boost duration", "Durée du boost",
		"How long a boost lasts.",
		"Durée d'un boost."],
	"BOOST_ALIGN_THRESHOLD_COS": ["Boost alignment", "Alignement du boost",
		"How aligned with your heading you must be to fire (closer to 1 = stricter).",
		"Alignement requis avec le cap pour déclencher (proche de 1 = plus strict)."],
	"BOOST_PENDING_TIMEOUT": ["Boost arming window", "Fenêtre de déclenchement",
		"Time after a drift in which the boost can still fire.",
		"Délai après un drift où le boost peut encore partir."],
	"BOOST_SUSTAIN_FORCE": ["Boost sustain", "Maintien du boost",
		"Push that keeps boost speed up.",
		"Poussée qui maintient la vitesse du boost."],
	"CRUISE_SPEED": ["Cruise speed", "Vitesse de croisière",
		"Reference cruising speed (feeds turbo cap & boost).",
		"Vitesse de croisière de référence (plafond turbo et boost)."],
	"TURBO_PEAK_SPEED": ["Turbo top speed", "Vitesse max. du turbo",
		"Speed the turbo pushes toward.",
		"Vitesse vers laquelle le turbo pousse."],
	"TURBO_FORCE": ["Turbo power", "Puissance du turbo",
		"Forward push while turbo is held.",
		"Poussée avant pendant le turbo."],
	"TURBO_CHARGE_RATE": ["Turbo charge (base)", "Charge du turbo (base)",
		"Base fill rate of the turbo bar while drifting.",
		"Remplissage de base de la jauge de turbo en drift."],
	"TURBO_CHARGE_ANGLE_RATE": ["Turbo charge by angle", "Charge du turbo selon l'angle",
		"Extra turbo fill the more sideways you slide.",
		"Remplissage turbo supplémentaire plus la glisse est marquée."],
	"TURBO_DRAIN_RATE": ["Turbo drain", "Consommation du turbo",
		"How fast the turbo bar empties when used.",
		"Vitesse à laquelle la jauge turbo se vide à l'usage."],
	"LAUNCH_WINDOW": ["Rocket-start window", "Fenêtre du départ canon",
		"How forgiving the perfect-start timing is.",
		"Tolérance du timing pour un départ parfait."],
	"LAUNCH_SHARPNESS": ["Rocket-start sharpness", "Précision du départ canon",
		"Higher = a perfect start must be more precise.",
		"Plus haut = un départ parfait doit être plus précis."],
	"LAUNCH_SPEED": ["Rocket-start speed", "Vitesse du départ canon",
		"Speed granted by a perfect start.",
		"Vitesse accordée par un départ parfait."],
	"PAD_BOOST_SCALE": ["Boost-pad strength", "Force des plaques de boost",
		"How much track boost pads add.",
		"Quantité de boost ajoutée par les plaques de la piste."],
}

var _defaults: Dictionary = {}       # name -> default float
var _fields: Dictionary = {}         # name -> LineEdit
var _row_labels: Dictionary = {}     # name -> Label (for re-localising)
var _row_boxes: Dictionary = {}      # name -> HBoxContainer (the hoverable line)
var _section_labels: Array = []      # [{label, en, fr}]
var _title_label: Label = null
var _hint_label: Label = null
var _reset_button: Button = null
var _done_button: Button = null

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP

	for row in Tuning.TWEAKABLE:
		_defaults[row[0]] = row[1]

	# Dim backdrop — clicking it closes the dialog.
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.04, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(_on_dim_input)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Let clicks in the empty margin fall through to the dim (close), while the card
	# itself (a STOP PanelContainer child) still captures its own clicks.
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(580, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.125, 0.15, 0.99)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.18, 0.2, 0.24, 1)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 26.0
	sb.content_margin_right = 26.0
	sb.content_margin_top = 22.0
	sb.content_margin_bottom = 22.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", TEXT)
	box.add_child(_title_label)

	_hint_label = Label.new()
	_hint_label.add_theme_color_override("font_color", TEXT_DIM)
	_hint_label.add_theme_font_size_override("font_size", 13)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.custom_minimum_size = Vector2(528, 0)
	box.add_child(_hint_label)

	box.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(528, 440)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 5)
	scroll.add_child(list)

	# One classified list, every section in order.
	var placed := {}
	_render_groups(list, GROUPS, placed)
	# Safety net: any constant not placed in a group still shows, under "Other".
	var leftovers: Array = []
	for row in Tuning.TWEAKABLE:
		if not placed.has(row[0]):
			leftovers.append(row[0])
	if not leftovers.is_empty():
		_add_section(list, {"en": "Other", "fr": "Autres"})
		for key in leftovers:
			_add_field(list, key)

	box.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	box.add_child(footer)
	_reset_button = Button.new()
	_reset_button.pressed.connect(_on_reset)
	footer.add_child(_reset_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	_done_button = Button.new()
	_done_button.pressed.connect(hide)
	footer.add_child(_done_button)

	relocalize()

func _render_groups(into: VBoxContainer, groups: Array, placed: Dictionary) -> void:
	for group in groups:
		_add_section(into, {"en": group["en"], "fr": group["fr"]})
		for key in group["names"]:
			if _defaults.has(key):
				_add_field(into, key)
				placed[key] = true

func _add_section(into: VBoxContainer, titles: Dictionary) -> void:
	var header := Label.new()
	header.add_theme_font_size_override("font_size", 15)
	header.add_theme_color_override("font_color", ACCENT)
	if not _section_labels.is_empty():
		header.custom_minimum_size = Vector2(0, 16)  # breathing room above all but the first
	into.add_child(header)
	_section_labels.append({"label": header, "en": titles["en"], "fr": titles["fr"]})

func _add_field(into: VBoxContainer, key: String) -> void:
	# The whole line is hoverable for the tooltip: STOP on the row + label, and the
	# field is STOP already. Tooltip text itself is set in relocalize().
	var hb := HBoxContainer.new()
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.mouse_filter = Control.MOUSE_FILTER_STOP
	var lbl := Label.new()
	lbl.add_theme_color_override("font_color", TEXT)
	lbl.custom_minimum_size = Vector2(330, 0)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	hb.add_child(lbl)
	var edit := LineEdit.new()
	edit.placeholder_text = String.num(_defaults[key])
	edit.custom_minimum_size = Vector2(130, 0)
	edit.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hb.add_child(edit)
	into.add_child(hb)
	_fields[key] = edit
	_row_labels[key] = lbl
	_row_boxes[key] = hb

# (Re)apply every label + tooltip in the active language. Called once at build, then
# again by ui._apply_locale() when the player switches language.
func relocalize() -> void:
	var fr := Locale.current() == "fr"
	if _title_label:
		_title_label.text = tr("tweak_title")
	if _hint_label:
		_hint_label.text = tr("tweak_hint")
	if _reset_button:
		_reset_button.text = tr("tweak_reset")
	if _done_button:
		_done_button.text = tr("tweak_close")
	for sec in _section_labels:
		sec["label"].text = sec["fr"] if fr else sec["en"]
	for key in _row_labels:
		var info = LABELS.get(key, null)
		var lbl: Label = _row_labels[key]
		var tip: String
		if info == null:
			lbl.text = key  # fallback: a constant with no human label yet
			tip = "%s — %s %s" % [key, tr("tweak_default"), String.num(_defaults[key])]
		else:
			lbl.text = info[1] if fr else info[0]
			var desc: String = info[3] if fr else info[2]
			tip = "%s\n%s · %s %s" % [desc, key, tr("tweak_default"), String.num(_defaults[key])]
		# Set on the whole line so hovering the name, the gap or the field all show it.
		lbl.tooltip_text = tip
		_row_boxes[key].tooltip_text = tip
		_fields[key].tooltip_text = tip

func open() -> void:
	relocalize()
	visible = true
	move_to_front()

func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		hide()

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()

func _on_reset() -> void:
	for edit in _fields.values():
		(edit as LineEdit).text = ""

# Sparse override map: only the constants whose field holds a valid number that
# differs from the stock default. Blank / invalid fields are ignored (stock value).
func get_tweaks() -> Dictionary:
	var out: Dictionary = {}
	for key in _fields:
		var txt: String = (_fields[key] as LineEdit).text.strip_edges()
		if txt.is_empty() or not txt.is_valid_float():
			continue
		var v := txt.to_float()
		if not is_equal_approx(v, _defaults[key]):
			out[key] = v
	return out
