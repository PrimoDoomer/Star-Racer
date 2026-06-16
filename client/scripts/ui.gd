extends Control

class_name UI

var tree_root: TreeItem

@onready var star_racer = %Game

@onready var min_players_field: LineEdit = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/CreateView/PlayersRow/MinPlayersField
@onready var max_players_field: LineEdit = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/CreateView/PlayersRow/MaxPlayersField
@onready var lobby_name_field: LineEdit = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/CreateView/LobbyNameField
@onready var nickname_field: LineEdit = $OnlineMenu/Center/Container/PilotPanel/PilotBox/NicknameField
@onready var join_button: Button = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/JoinView/JoinFooter/JoinButton
@onready var create_button: Button = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/CreateView/CreateButton
@onready var refresh_list_button: Button = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/JoinView/JoinFooter/RefreshListButton
@onready var lobbies_list: Tree = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/JoinView/LobbiesList
@onready var join_tab_button: Button = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/Tabs/JoinTabButton
@onready var create_tab_button: Button = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/Tabs/CreateTabButton
@onready var join_view: VBoxContainer = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/JoinView
@onready var create_view: VBoxContainer = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/CreateView
@onready var preview_slot: PanelContainer = $OnlineMenu/Center/Container/PilotPanel/PilotBox/PreviewSlot
@onready var leave_button: Button = $PlayMenuPanel/PlayMenu/LeaveButton
@onready var back_button: Button = $IntermissionMenu/Center/Panel/Container/BackButton
@onready var info_label: Label = $InfoLabel
@onready var intermission_menu: Control = $IntermissionMenu
@onready var online_menu: Control = $OnlineMenu
@onready var play_menu_panel: Control = $PlayMenuPanel
@onready var alpha_info: Control = $MenuChrome
@onready var players_in_lobby: VBoxContainer = $IntermissionMenu/Center/Panel/Container/Control/PlayersInLobby
@onready var intermission_lobby_name: Label = $IntermissionMenu/Center/Panel/Container/LobbyName
@onready var intermission_track_name: Label = $IntermissionMenu/Center/Panel/Container/CurrentTrackname
@onready var intermission_players_count: Label = $IntermissionMenu/Center/Panel/Container/PlayersCount
@onready var network = %Network
@onready var label_scene: PackedScene = load("res://scenes/label.tscn")
@onready var countdown_label: Label = $IntermissionMenu/Center/Panel/Container/CountdownLabel
@onready var menu_background: ColorRect = $MenuBackground
@onready var start_lights = $StartLights
@onready var _car_model_label: Label = $OnlineMenu/Center/Container/PilotPanel/PilotBox/ModelNav/ModelLabel
@onready var _track_picker: OptionButton = $OnlineMenu/Center/Container/CoursesPanel/CoursesBox/CreateView/TrackRow/TrackPicker

var bindings_label: Label

var _car_model_idx: int = 0
var _car_preview_viewport: SubViewport = null
var _car_preview_node: Node3D = null
var _lobby_tick: AudioStreamPlayer = null

# --- Settings panel (built in code) ---
var _settings_overlay: Control = null
var _settings_title: Label = null
var _settings_lang_label: Label = null
var _settings_controls_label: Label = null
var _lang_picker: OptionButton = null
var _reset_button: Button = null
var _close_button: Button = null
var _binding_rows := {}  # action -> {"name": Label, "key": Button}
var _rebinding_action := ""

# Muted steel-blue accent shared with the flattened theme (see game.tscn).
const ACCENT := Color(0.45, 0.56, 0.68)
# Brighter accent reserved for the logo wordmark and section headings.
const ACCENT_BRIGHT := Color(0.55, 0.74, 0.96)

# App identity. Moved off the main page into the About panel.
const APP_VERSION := "v1.0.0 rc"
const APP_BUILD := "2026-06-16"
const APP_REPO := "PrimoDoomer/Star-Racer"
const APP_REPO_URL := "https://github.com/PrimoDoomer/Star-Racer"

# Status-message severities, driving the info pill's colour.
enum StatusKind { INFO, LOADING, SUCCESS, ERROR }
var _status_kind: int = StatusKind.INFO
var _info_sb: StyleBoxFlat = null

# Logo + About panel, both built in code.
var _logo_tagline: Label = null
var _about_overlay: Control = null
var _about_close_button: Button = null
var _about_tr: Array = []  # [[Label, locale_key], ...] re-translated on locale change

func _ready() -> void:
	_apply_lobby_columns()

	self.bindings_label = Label.new()
	self.bindings_label.position = Vector2(12, 12)
	self.bindings_label.text = _build_bindings_text()
	self.bindings_label.add_theme_color_override("font_color", Color(0.82, 0.87, 0.93, 0.85))
	self.bindings_label.add_theme_color_override("font_outline_color", Color(0.03, 0.04, 0.06, 0.95))
	self.bindings_label.add_theme_constant_override("outline_size", 4)
	self.bindings_label.add_theme_font_size_override("font_size", 14)
	self.bindings_label.visible = false
	add_child(self.bindings_label)

	_track_picker.clear()
	_track_picker.add_item("(loading...)")
	_track_picker.disabled = true

	_setup_car_preview()
	_setup_field_filters()

	# Distinct soft "blip" for the lobby-ready countdown (≠ the start-light beeps).
	_lobby_tick = AudioStreamPlayer.new()
	_lobby_tick.stream = _make_lobby_tone()
	_lobby_tick.volume_db = -4.0
	add_child(_lobby_tick)

	_build_settings_panel()
	_build_logo()
	_build_about_panel()
	_style_info_label()
	_setup_lobby_column_sizes()
	_apply_locale()

func _setup_car_preview() -> void:
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.size_flags_horizontal = SIZE_EXPAND_FILL
	svc.size_flags_vertical = SIZE_EXPAND_FILL
	self.preview_slot.add_child(svc)

	_car_preview_viewport = SubViewport.new()
	_car_preview_viewport.size = Vector2i(320, 150)
	_car_preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_car_preview_viewport.transparent_bg = true
	# Render the preview in its own isolated 3D world so the preview's camera,
	# lights, environment and car model never leak into the live race scene.
	_car_preview_viewport.own_world_3d = true
	svc.add_child(_car_preview_viewport)

	var cam := Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.fov = 50.0
	cam.look_at_from_position(Vector3(3.2, 1.9, 3.9), Vector3(0.0, 0.35, 0.0), Vector3.UP)
	_car_preview_viewport.add_child(cam)

	var dir_light := DirectionalLight3D.new()
	dir_light.rotation = Vector3(-PI / 4.0, PI / 4.0, 0.0)
	dir_light.shadow_enabled = false
	dir_light.light_energy = 1.2
	_car_preview_viewport.add_child(dir_light)

	var fill_light := OmniLight3D.new()
	fill_light.position = Vector3(-5.0, 3.0, -3.0)
	fill_light.light_energy = 0.4
	_car_preview_viewport.add_child(fill_light)

	# Cool rim light from behind for a polished showroom look.
	var rim_light := OmniLight3D.new()
	rim_light.position = Vector3(0.0, 2.5, -6.0)
	rim_light.light_color = Color(0.55, 0.78, 0.98)
	rim_light.light_energy = 0.6
	_car_preview_viewport.add_child(rim_light)

	var wenv := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.10)
	env.ambient_light_color = Color(0.78, 0.82, 0.92)
	env.ambient_light_energy = 0.5
	wenv.environment = env
	_car_preview_viewport.add_child(wenv)

	_update_car_preview()

func _setup_field_filters() -> void:
	self.min_players_field.max_length = 1
	self.max_players_field.max_length = 1
	self.lobby_name_field.max_length = 20
	self.nickname_field.max_length = 20
	self.min_players_field.text_changed.connect(_filter_digit_field.bind(self.min_players_field))
	self.max_players_field.text_changed.connect(_filter_digit_field.bind(self.max_players_field))
	self.lobby_name_field.text_changed.connect(_filter_name_field.bind(self.lobby_name_field))
	self.nickname_field.text_changed.connect(_filter_name_field.bind(self.nickname_field))

func _filter_digit_field(new_text: String, field: LineEdit) -> void:
	var filtered := ""
	for ch in new_text:
		if ch >= "0" and ch <= "9":
			filtered += ch
	# Clamp to the hard player-count limits so the field can never show an
	# out-of-range value (e.g. 0, 7, 8, 9).
	if filtered != "":
		var clamped: int = clampi(int(filtered), self.star_racer.MIN_LIMIT_PLAYERS, self.star_racer.MAX_LIMIT_PLAYERS)
		filtered = str(clamped)
	if filtered != new_text:
		var caret := field.caret_column
		field.text = filtered
		field.caret_column = mini(caret, filtered.length())

func _filter_name_field(new_text: String, field: LineEdit) -> void:
	var filtered := ""
	for i in new_text.length():
		var ch := new_text[i]
		var is_alpha := (ch >= "A" and ch <= "Z") or (ch >= "a" and ch <= "z")
		var is_digit := ch >= "0" and ch <= "9"
		var is_underscore := ch == "_"
		if filtered.length() == 0:
			if is_alpha:
				filtered += ch
		elif is_alpha or is_digit or is_underscore:
			filtered += ch
	if filtered != new_text:
		var caret := field.caret_column
		field.text = filtered
		field.caret_column = mini(caret, filtered.length())

func _update_car_preview() -> void:
	if _car_preview_viewport == null:
		return
	if _car_preview_node != null:
		_car_preview_node.queue_free()
		_car_preview_node = null

	var model_def: Dictionary = Game.get_car_model(Game.CAR_MODELS[_car_model_idx]["id"])
	var scene := load(model_def["path"]) as PackedScene
	if scene == null:
		return
	_car_preview_node = scene.instantiate() as Node3D
	_car_preview_node.transform = model_def["transform"]
	_car_preview_viewport.add_child(_car_preview_node)
	# Fixed 3/4 pose (no spin) and a default tint so the model reads as a car.
	_car_preview_node.rotation.y = deg_to_rad(150.0)

	if _car_model_label != null:
		_car_model_label.text = model_def["name"]

func _on_car_prev() -> void:
	_car_model_idx = (_car_model_idx - 1 + Game.CAR_MODELS.size()) % Game.CAR_MODELS.size()
	_update_car_preview()

func _on_car_next() -> void:
	_car_model_idx = (_car_model_idx + 1) % Game.CAR_MODELS.size()
	_update_car_preview()

func get_car_model_id() -> String:
	return Game.CAR_MODELS[_car_model_idx]["id"]

func set_car_model_id(model_id: String) -> void:
	for i in Game.CAR_MODELS.size():
		if Game.CAR_MODELS[i]["id"] == model_id:
			_car_model_idx = i
			_update_car_preview()
			return

func _on_join_tab_toggled(on: bool) -> void:
	if on:
		self.create_tab_button.set_pressed_no_signal(false)
		self.join_view.visible = true
		self.create_view.visible = false
	else:
		self.join_tab_button.set_pressed_no_signal(true)

func _on_create_tab_toggled(on: bool) -> void:
	if on:
		self.join_tab_button.set_pressed_no_signal(false)
		self.create_view.visible = true
		self.join_view.visible = false
	else:
		self.create_tab_button.set_pressed_no_signal(true)

func _build_bindings_text() -> String:
	var lines: Array[String] = []
	for action in Bindings.ACTIONS:
		var code := Bindings.get_key(action)
		if code == 0:
			continue
		lines.append("%s: %s" % [tr("act_" + action), Bindings.key_label(code)])
	return "\n".join(lines)

func _apply_lobby_columns() -> void:
	self.lobbies_list.set_column_title(0, tr("col_name"))
	self.lobbies_list.set_column_title(1, tr("col_owner"))
	self.lobbies_list.set_column_title(2, tr("col_players"))
	self.lobbies_list.set_column_title(3, tr("col_min"))
	self.lobbies_list.set_column_title(4, tr("col_state"))
	self.lobbies_list.set_column_title(5, tr("col_start"))
	self.lobbies_list.set_column_title(6, tr("col_track"))

# Column proportions so every field reads cleanly: the name/host/track columns
# stretch, while the numeric "grid" and "start" columns stay tight (the old
# "min needed" column was far too wide).
func _setup_lobby_column_sizes() -> void:
	var t := self.lobbies_list
	t.set_column_expand(0, true);  t.set_column_expand_ratio(0, 3)   # Race
	t.set_column_expand(1, true);  t.set_column_expand_ratio(1, 2)   # Host
	t.set_column_expand(2, false); t.set_column_custom_minimum_width(2, 60)   # Grid
	t.set_column_expand(3, false); t.set_column_custom_minimum_width(3, 56)   # Start
	t.set_column_expand(4, false); t.set_column_custom_minimum_width(4, 94)   # Status
	t.set_column_expand(5, false); t.set_column_custom_minimum_width(5, 78)   # Opened
	t.set_column_expand(6, true);  t.set_column_expand_ratio(6, 2)   # Track
	for c in 7:
		t.set_column_clip_content(c, true)

# ----------------------------------------------------------------------------
# Logo: a polished two-tone "STAR RACER" wordmark with a star mark, soft glow
# and an accent underline. Added to MenuChrome so it shows on the menu only.

func _logo_font() -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Segoe UI", "Calibri", "sans-serif"])
	f.font_weight = 800
	return f

func _logo_settings(font: SystemFont, font_size: int, color: Color, glow: bool) -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font = font
	ls.font_size = font_size
	ls.font_color = color
	ls.outline_size = 6
	ls.outline_color = Color(0.03, 0.05, 0.08, 0.92)
	if glow:
		ls.shadow_size = 9
		ls.shadow_color = Color(ACCENT_BRIGHT.r, ACCENT_BRIGHT.g, ACCENT_BRIGHT.b, 0.35)
		ls.shadow_offset = Vector2.ZERO
	return ls

func _build_logo() -> void:
	var font := _logo_font()
	var root := VBoxContainer.new()
	root.position = Vector2(42, 30)
	root.add_theme_constant_override("separation", 5)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	root.add_child(row)

	var star := Label.new()
	star.text = "★"
	star.label_settings = _logo_settings(font, 34, ACCENT_BRIGHT, true)
	star.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(star)

	var word1 := Label.new()
	word1.text = "STAR"
	word1.label_settings = _logo_settings(font, 50, Color(0.96, 0.98, 1.0), true)
	row.add_child(word1)

	var word2 := Label.new()
	word2.text = "RACER"
	word2.label_settings = _logo_settings(font, 50, ACCENT_BRIGHT, true)
	row.add_child(word2)

	var underline := ColorRect.new()
	underline.color = ACCENT
	underline.custom_minimum_size = Vector2(0, 3)
	underline.size_flags_horizontal = SIZE_FILL
	root.add_child(underline)

	_logo_tagline = Label.new()
	_logo_tagline.text = tr("about_tagline")
	_logo_tagline.add_theme_font_size_override("font_size", 13)
	_logo_tagline.add_theme_color_override("font_color", Color(0.5, 0.58, 0.68))
	root.add_child(_logo_tagline)

	self.alpha_info.add_child(root)

func _logo_header(parent: VBoxContainer) -> void:
	var font := _logo_font()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 9)
	var star := Label.new()
	star.text = "★"
	star.label_settings = _logo_settings(font, 24, ACCENT_BRIGHT, false)
	star.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(star)
	var w1 := Label.new()
	w1.text = "STAR"
	w1.label_settings = _logo_settings(font, 30, Color(0.96, 0.98, 1.0), false)
	head.add_child(w1)
	var w2 := Label.new()
	w2.text = "RACER"
	w2.label_settings = _logo_settings(font, 30, ACCENT_BRIGHT, false)
	head.add_child(w2)
	parent.add_child(head)

# ----------------------------------------------------------------------------
# About panel: version/build/source (moved off the main page), art credits and
# the maker's mark. Built in code, same overlay pattern as the settings panel.

func _make_about_label(key: String, color: Color, size2: int) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", color)
	if size2 > 0:
		l.add_theme_font_size_override("font_size", size2)
	l.text = tr(key)
	_about_tr.append([l, key])
	return l

func _about_kv(parent: VBoxContainer, key: String, value: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var k := _make_about_label(key, Color(0.5, 0.58, 0.68), 0)
	k.custom_minimum_size = Vector2(110, 0)
	row.add_child(k)
	var v := Label.new()
	v.text = value
	v.add_theme_color_override("font_color", Color(0.84, 0.89, 0.96))
	row.add_child(v)
	parent.add_child(row)

func _build_about_panel() -> void:
	_about_overlay = Control.new()
	_about_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_about_overlay.visible = false
	add_child(_about_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.04, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_about_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_about_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(480, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.125, 0.15, 0.99)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.18, 0.2, 0.24, 1)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 30.0
	sb.content_margin_right = 30.0
	sb.content_margin_top = 26.0
	sb.content_margin_bottom = 26.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	_logo_header(box)
	box.add_child(_make_about_label("about_tagline", Color(0.55, 0.62, 0.71), 14))
	box.add_child(HSeparator.new())

	_about_kv(box, "about_version", APP_VERSION)
	_about_kv(box, "about_build", APP_BUILD)

	# Source row with a clickable repo link.
	var src_row := HBoxContainer.new()
	src_row.add_theme_constant_override("separation", 14)
	var src_key := _make_about_label("about_source", Color(0.5, 0.58, 0.68), 0)
	src_key.custom_minimum_size = Vector2(110, 0)
	src_row.add_child(src_key)
	var link := LinkButton.new()
	link.text = APP_REPO
	link.uri = APP_REPO_URL
	link.add_theme_color_override("font_color", ACCENT_BRIGHT)
	src_row.add_child(link)
	box.add_child(src_row)

	box.add_child(HSeparator.new())

	# Authorship: the ideas & direction are the designer's; the build is Claude's
	# (the centred maker's mark below).
	box.add_child(_make_about_label("about_design", Color(0.78, 0.84, 0.92), 0))

	box.add_child(HSeparator.new())

	box.add_child(_make_about_label("about_credits", ACCENT, 13))
	box.add_child(_make_about_label("about_credits_engine", Color(0.78, 0.84, 0.92), 0))
	box.add_child(_make_about_label("about_credits_models", Color(0.78, 0.84, 0.92), 0))
	box.add_child(_make_about_label("about_credits_physics", Color(0.78, 0.84, 0.92), 0))
	box.add_child(_make_about_label("about_credits_server", Color(0.78, 0.84, 0.92), 0))
	box.add_child(_make_about_label("about_credits_art", Color(0.78, 0.84, 0.92), 0))

	box.add_child(HSeparator.new())

	# The maker's mark, centred.
	var sig := _make_about_label("about_signature", ACCENT_BRIGHT, 14)
	sig.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sig)

	_about_close_button = Button.new()
	_about_close_button.pressed.connect(_on_about_close)
	box.add_child(_about_close_button)

func _on_about_pressed() -> void:
	_refresh_about_labels()
	_about_overlay.visible = true
	_about_close_button.grab_focus()

func _on_about_close() -> void:
	_about_overlay.visible = false

func _refresh_about_labels() -> void:
	for pair in _about_tr:
		(pair[0] as Label).text = tr(pair[1])
	if _about_close_button:
		_about_close_button.text = tr("set_close")

# ----------------------------------------------------------------------------
# Status pill: a single bottom-right message with a rounded background and a
# severity-coloured accent border. Replaces the old bare label.

func _style_info_label() -> void:
	# The scene set a LabelSettings; clear it so our theme overrides take effect.
	self.info_label.label_settings = null
	_info_sb = StyleBoxFlat.new()
	_info_sb.bg_color = Color(0.09, 0.105, 0.13, 0.92)
	_info_sb.set_corner_radius_all(8)
	_info_sb.border_width_left = 3
	_info_sb.border_color = ACCENT
	_info_sb.content_margin_left = 16.0
	_info_sb.content_margin_right = 16.0
	_info_sb.content_margin_top = 8.0
	_info_sb.content_margin_bottom = 8.0
	self.info_label.add_theme_stylebox_override("normal", _info_sb)
	self.info_label.add_theme_font_size_override("font_size", 15)
	self.info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	self.info_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	self.info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	self.info_label.visible = false

func _set_status(text: String, kind: int = StatusKind.INFO) -> void:
	_status_kind = kind
	if text.strip_edges() == "":
		self.info_label.text = ""
		self.info_label.visible = false
		return
	var fg := Color(0.74, 0.81, 0.9)
	var accent := ACCENT
	match kind:
		StatusKind.LOADING:
			fg = Color(0.7, 0.82, 0.95)
			accent = ACCENT_BRIGHT
		StatusKind.SUCCESS:
			fg = Color(0.62, 0.86, 0.66)
			accent = Color(0.42, 0.78, 0.5)
		StatusKind.ERROR:
			fg = Color(0.96, 0.62, 0.56)
			accent = Color(0.92, 0.42, 0.38)
	if _info_sb:
		_info_sb.border_color = accent
	self.info_label.add_theme_color_override("font_color", fg)
	self.info_label.text = text
	self.info_label.visible = true

# Re-apply every piece of text we drive from code. Static scene text is handled
# by Godot's auto-translation; this covers what auto-translation can't reach.
func _apply_locale() -> void:
	# The locale can change before our @onready nodes exist (the autoload sets it
	# during tree setup); _ready() calls this again once everything is in place.
	if self.lobbies_list == null:
		return
	_apply_lobby_columns()
	self.nickname_field.placeholder_text = tr("ui_nickname_ph")
	self.lobby_name_field.placeholder_text = tr("ui_race_name_ph")
	if self.bindings_label:
		self.bindings_label.text = _build_bindings_text()
	self.min_players_field.tooltip_text = tr("tip_start")
	self.max_players_field.tooltip_text = tr("tip_grid")
	if _logo_tagline:
		_logo_tagline.text = tr("about_tagline")
	_refresh_about_labels()
	_refresh_settings_labels()
	_refresh_binding_rows()

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_apply_locale()

# ----------------------------------------------------------------------------
# Settings panel: language + key bindings. Built in code so the binding list
# can be generated from Bindings.ACTIONS and the layout stays self-contained.

func _build_settings_panel() -> void:
	_settings_overlay = Control.new()
	_settings_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_overlay.visible = false
	add_child(_settings_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.04, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.125, 0.15, 0.99)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.18, 0.2, 0.24, 1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 24.0
	sb.content_margin_bottom = 24.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	_settings_title = Label.new()
	_settings_title.add_theme_font_size_override("font_size", 26)
	box.add_child(_settings_title)
	box.add_child(HSeparator.new())

	# Language row.
	_settings_lang_label = _make_section_label()
	box.add_child(_settings_lang_label)
	_lang_picker = OptionButton.new()
	for code in Locale.LOCALES:
		_lang_picker.add_item("English" if code == "en" else "Français")
	_lang_picker.item_selected.connect(_on_language_selected)
	box.add_child(_lang_picker)

	box.add_child(HSeparator.new())

	# Controls section: one rebindable row per action.
	_settings_controls_label = _make_section_label()
	box.add_child(_settings_controls_label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	scroll.add_child(rows)

	for action in Bindings.ACTIONS:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 12)

		var name_label := Label.new()
		name_label.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(name_label)

		var key_button := Button.new()
		key_button.custom_minimum_size = Vector2(150, 0)
		key_button.pressed.connect(_on_rebind_pressed.bind(action))
		row.add_child(key_button)

		rows.add_child(row)
		_binding_rows[action] = {"name": name_label, "key": key_button}

	box.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	box.add_child(footer)

	_reset_button = Button.new()
	_reset_button.size_flags_horizontal = SIZE_EXPAND_FILL
	_reset_button.pressed.connect(_on_reset_bindings)
	footer.add_child(_reset_button)

	_close_button = Button.new()
	_close_button.size_flags_horizontal = SIZE_EXPAND_FILL
	_close_button.pressed.connect(_on_settings_close)
	footer.add_child(_close_button)

func _make_section_label() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", ACCENT)
	return l

func _refresh_settings_labels() -> void:
	if _settings_title == null:
		return
	_settings_title.text = tr("set_title")
	_settings_lang_label.text = tr("set_language")
	_settings_controls_label.text = tr("set_controls")
	_reset_button.text = tr("set_reset")
	_close_button.text = tr("set_close")
	var idx := Locale.LOCALES.find(Locale.current())
	if idx >= 0:
		_lang_picker.select(idx)

func _refresh_binding_rows() -> void:
	for action in _binding_rows:
		var row: Dictionary = _binding_rows[action]
		(row["name"] as Label).text = tr("act_" + action)
		if action != _rebinding_action:
			(row["key"] as Button).text = Bindings.key_label(Bindings.get_key(action))

func _on_settings_pressed() -> void:
	_refresh_settings_labels()
	_refresh_binding_rows()
	_settings_overlay.visible = true
	_close_button.grab_focus()

func _on_settings_close() -> void:
	_cancel_rebind()
	_settings_overlay.visible = false

func _on_language_selected(index: int) -> void:
	Locale.set_locale(Locale.LOCALES[index])

func _on_reset_bindings() -> void:
	_cancel_rebind()
	Bindings.reset()
	_refresh_binding_rows()
	if self.bindings_label:
		self.bindings_label.text = _build_bindings_text()

func _on_rebind_pressed(action: String) -> void:
	_cancel_rebind()
	_rebinding_action = action
	(_binding_rows[action]["key"] as Button).text = tr("set_press_key")

func _cancel_rebind() -> void:
	if _rebinding_action == "":
		return
	var action := _rebinding_action
	_rebinding_action = ""
	(_binding_rows[action]["key"] as Button).text = Bindings.key_label(Bindings.get_key(action))

func _input(event: InputEvent) -> void:
	if _rebinding_action == "":
		return
	if event is InputEventKey and event.pressed and not event.echo:
		get_viewport().set_input_as_handled()
		if event.keycode == KEY_ESCAPE:
			_cancel_rebind()
			return
		var code: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		Bindings.set_key(_rebinding_action, code)
		_rebinding_action = ""
		_refresh_binding_rows()
		if self.bindings_label:
			self.bindings_label.text = _build_bindings_text()

func _process(_delta: float) -> void:
	self.join_button.disabled = self.lobbies_list.get_selected() == null
	var in_race: bool = %Game.mode == Game.Mode.IN_RACE
	self.bindings_label.visible = in_race and not %Game.paused and not Game.is_mobile()
	if %Game.mode == Game.Mode.IN_RACE or %Game.mode == Game.Mode.SPECTATOR:
		if Input.is_action_just_released("Pause"):
			self.play_menu_panel.visible = ! self.play_menu_panel.visible

func switch_mode(next_mode: Game.Mode, server_up: bool):
	if %Game.mode == Game.Mode.WELCOME_PAGE:
		self.join_button.disabled = true
		self.refresh_list_button.disabled = true
		self.create_button.disabled = true
		if next_mode == Game.Mode.FETCH_LOBBIES:
			_set_status(tr("fetching"), StatusKind.LOADING)
	elif %Game.mode == Game.Mode.LOBBY_INTERMISSION:
		self.intermission_menu.visible = false

	if next_mode == Game.Mode.WELCOME_PAGE:
		self.alpha_info.visible = true
		self.online_menu.visible = true
		self.play_menu_panel.visible = false
		self.menu_background.visible = true
		_set_status("")
		self.refresh_list_button.disabled = false
		if self.star_racer.mode == Game.Mode.IN_RACE \
		   || self.star_racer.mode == Game.Mode.LOBBY_INTERMISSION \
		   || self.star_racer.mode == Game.Mode.SPECTATOR:
			self.create_button.disabled = false
			self.nickname_field.grab_focus()
		elif self.star_racer.mode == Game.Mode.FETCH_LOBBIES:
			if !server_up:
				_set_status(tr("no_connection"), StatusKind.ERROR)
				self.join_button.disabled = true
				self.create_button.disabled = true
			else:
				_set_status(tr("lobbies_fetched"), StatusKind.INFO)
				self.join_button.disabled = false
				self.create_button.disabled = (_track_picker == null) or (_track_picker.item_count == 0) or _track_picker.disabled
	elif next_mode == Game.Mode.LOBBY_INTERMISSION:
		self.back_button.grab_focus()
		for child in self.players_in_lobby.get_children():
			child.queue_free()
		self.intermission_menu.visible = true
		self.online_menu.visible = false
		self.menu_background.visible = true
		_set_status("")
		self.countdown_label.text = ""
	elif next_mode == Game.Mode.IN_RACE:
		self.leave_button.grab_focus()
		self.alpha_info.visible = false
		self.online_menu.visible = false
		self.intermission_menu.visible = false
		self.menu_background.visible = false
		_set_status("")
	elif next_mode == Game.Mode.SPECTATOR:
		self.alpha_info.visible = false
		self.online_menu.visible = false
		self.intermission_menu.visible = false
		self.menu_background.visible = false
		_set_status(tr("spectating"), StatusKind.INFO)

func _on_back_to_race_pressed() -> void:
	self.play_menu_panel.visible = false
	self.star_racer.paused = false

func _on_leave_pressed() -> void:
	self.star_racer.paused = false
	self.network.terminate()

func _on_back_pressed() -> void:
	self.online_menu.visible = false

func _on_quit_pressed() -> void:
	self.star_racer._save_settings()
	get_tree().quit()

func _on_editor_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/editor.tscn")

func _on_join_button_pressed() -> void:
	if not self.star_racer.check_nickname(get_nickname()):
		set_status_error(tr("err_invalid_name"))
		return
	self.star_racer.switch_mode(Game.Mode.JOINING_LOBBY, true)

func _on_create_button_pressed() -> void:
	if not self.star_racer.check_nickname(get_nickname()) \
	or not self.star_racer.check_lobby_name(get_lobby_name()):
		set_status_error(tr("err_invalid_name"))
		return
	self.star_racer.switch_mode(Game.Mode.CREATING_LOBBY, true)

func _on_back_button_pressed() -> void:
	self.network.terminate()

func refresh_tracks(tracks: Array) -> void:
	if _track_picker == null:
		return
	var prev_id := get_selected_track_id()
	_track_picker.clear()
	for i in tracks.size():
		var t: Dictionary = tracks[i]
		_track_picker.add_item(String(t.get("name", t.get("id", "?"))), i)
		_track_picker.set_item_metadata(i, String(t.get("id", "")))
	_track_picker.disabled = tracks.is_empty()
	if !prev_id.is_empty():
		for i in _track_picker.item_count:
			if String(_track_picker.get_item_metadata(i)) == prev_id:
				_track_picker.select(i)
				break
	if !tracks.is_empty() && self.star_racer.mode == Game.Mode.FETCH_LOBBIES:
		self.create_button.disabled = false

func get_selected_track_id() -> String:
	if _track_picker == null || _track_picker.item_count == 0:
		return ""
	var idx := _track_picker.selected
	if idx < 0:
		idx = 0
	var meta = _track_picker.get_item_metadata(idx)
	return String(meta) if meta != null else ""

func refresh(lobby_infos: Array):
	self.lobbies_list.clear()
	self.tree_root = self.lobbies_list.create_item()

	for info in lobby_infos:
		var item = self.tree_root.create_child()

		item.set_text(0, info.name)
		item.set_text_alignment(0, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_text(1, info.owner)
		item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_text(2, str(int(info.player_count)) + "/" + str(int(info.max_players)))
		item.set_text_alignment(2, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_text(3, str(int(info.min_players)))
		item.set_text_alignment(3, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_text(4, tr("state_racing") if info.racing else tr("state_intermission"))
		item.set_text_alignment(4, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_text(5, info.start_time)
		item.set_text_alignment(5, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_text(6, str(info.get("track_name", "")))
		item.set_text_alignment(6, HORIZONTAL_ALIGNMENT_CENTER)

	# Friendlier empty state — but don't stomp a connection error.
	if lobby_infos.is_empty() and _status_kind != StatusKind.ERROR:
		_set_status(tr("no_lobbies"), StatusKind.INFO)

func _on_refresh_list_button_pressed() -> void:
	%Game.switch_mode(Game.Mode.FETCH_LOBBIES, false)

func get_min_players() -> int:
	return int(self.min_players_field.text)

func get_max_players() -> int:
	return int(self.max_players_field.text)

func get_lobby_name() -> String:
	return self.lobby_name_field.text

func get_nickname() -> String:
	return self.nickname_field.text

func get_car_color() -> Color:
	# Colour customization was removed; the protocol still carries a colour, so
	# return a fixed default. Cars now render with their model's native materials.
	return Color(1, 1, 1)

func set_min_players(value: int) -> void:
	self.min_players_field.text = str(value)

func set_max_players(value: int) -> void:
	self.max_players_field.text = str(value)

func set_lobby_name(value: String) -> void:
	self.lobby_name_field.text = value

func set_nickname(value: String) -> void:
	self.nickname_field.text = value

func set_intermission_lobby_name(str_name: String) -> void:
	self.intermission_lobby_name.text = str_name

func set_intermission_track_name(str_name: String) -> void:
	self.intermission_track_name.text = str_name

func add_player_to_lobby(player_name: String) -> void:
	if self.players_in_lobby.get_node_or_null(player_name):
		return
	self.players_in_lobby.add_child(_make_pilot_chip(player_name))

func clear_players_in_lobby() -> void:
	for child in self.players_in_lobby.get_children():
		child.queue_free()

func set_intermission_players_count(str_count: String) -> void:
	self.intermission_players_count.text = str_count

func set_intermission_players_list(players: Array) -> void:
	# Drop chips for players no longer in the lobby.
	var present := {}
	for player in players:
		present[String(player["nickname"])] = true
	for child in self.players_in_lobby.get_children():
		if not present.has(child.name):
			child.queue_free()

	for player in players:
		var nickname: String = player["nickname"]
		if self.players_in_lobby.get_node_or_null(nickname):
			continue
		self.players_in_lobby.add_child(_make_pilot_chip(nickname))

func _make_pilot_chip(nickname: String) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.name = nickname
	chip.size_flags_horizontal = SIZE_FILL

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.105, 0.13, 0.96)
	sb.set_border_width_all(0)
	sb.border_width_left = 4
	sb.border_color = ACCENT
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 9.0
	sb.content_margin_bottom = 9.0
	chip.add_theme_stylebox_override("panel", sb)

	var label := Label.new()
	label.text = nickname
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.9, 0.93, 0.97))
	label.size_flags_horizontal = SIZE_EXPAND_FILL
	chip.add_child(label)

	return chip

func get_play_menu_panel():
	return self.play_menu_panel

func get_selected_lobby_name() -> String:
	var selected_item: TreeItem = (self.lobbies_list as Tree).get_selected()
	return selected_item.get_text(0)

func set_info_label(text: String):
	_set_status(text, StatusKind.INFO)

func set_status_error(text: String) -> void:
	_set_status(text, StatusKind.ERROR)

func set_status_success(text: String) -> void:
	_set_status(text, StatusKind.SUCCESS)

func set_lobby_countdown(time_sec: float) -> void:
	# Shown in the lobby page while the lobby is full/ready, before the race start.
	self.countdown_label.text = str(int(ceil(time_sec)))
	if _lobby_tick:
		_lobby_tick.play()

func clear_lobby_countdown() -> void:
	self.countdown_label.text = ""

func _make_lobby_tone() -> AudioStreamWAV:
	var rate := 22050
	var dur := 0.12
	var freq := 660.0
	var n := int(dur * float(rate))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / float(rate)
		var s := sin(t * freq * TAU) * exp(-t * 9.0) * 0.5
		var v := int(clampf(s, -1.0, 1.0) * 32767.0)
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav

func show_pre_race_view() -> void:
	self.intermission_menu.visible = false
	self.online_menu.visible = false
	self.alpha_info.visible = false
	self.menu_background.visible = false

func reset_start_lights() -> void:
	if self.start_lights:
		self.start_lights.reset()

func start_lights_countdown(time_sec: float) -> void:
	if self.start_lights:
		self.start_lights.on_countdown(time_sec)

func start_lights_go() -> void:
	if self.start_lights:
		self.start_lights.on_race_started()

func show_rocket_score(quality: float) -> void:
	if self.start_lights:
		self.start_lights.show_rocket_score(quality)

func show_race_results(rankings: Array) -> void:
	for child in self.players_in_lobby.get_children():
		child.queue_free()
	for i in rankings.size():
		var label := Label.new()
		label.text = "%d.  %s" % [i + 1, rankings[i]]
		self.players_in_lobby.add_child(label)
	_set_status(tr("race_finished"), StatusKind.SUCCESS)
