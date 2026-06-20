extends Control

class_name UI

var tree_root: TreeItem

@onready var game_node = %Game

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
@onready var quit_button: Button = $OnlineMenu/QuitButton

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
var _settings_kbd_header: Label = null
var _settings_pad_header: Label = null
var _settings_scroll: ScrollContainer = null
var _lang_picker: OptionButton = null
var _reset_button: Button = null
var _close_button: Button = null
var _binding_rows := {}  # action -> {"name": Label, "key": Button}
var _rebinding_action := ""
var _rebinding_joy_action := ""  # action whose gamepad button is being captured
var _in_lobby_list := false  # focus is trapped inside the lobby list (browse mode)
var _using_gamepad := false  # last input came from a controller → show pad-only hints

# Pad-only hints: ▲▼ "browse the list" under the lobby list, and L / R key-caps on
# the tabs (shoulder buttons switch tabs). Plus the quit confirmation. Built in code.
var _pad_browse_hint: Control = null  # the ▲▼ + label row (toggled in _process)
var _pad_browse_label: Label = null
var _tab_hint_l: Label = null
var _tab_hint_r: Label = null
var _quit_overlay: Control = null
var _quit_title: Label = null
var _quit_yes: Button = null
var _quit_no: Button = null

# Warm amber accent shared with the flattened theme (see main_theme.tres).
const ACCENT := Color(0.95, 0.6, 0.23)
# Brighter amber reserved for the logo wordmark and section headings.
const ACCENT_BRIGHT := Color(1.0, 0.78, 0.36)

# Lobby-list state colours, so "can I join, and is there room?" reads at a glance.
const STATE_OPEN := Color(0.46, 0.82, 0.52)    # green — open, room to join
const STATE_RACING := Color(0.98, 0.74, 0.36)  # amber — race in progress
const STATE_FULL := Color(0.93, 0.46, 0.42)    # red — full, can't join
const ROW_DIM := Color(0.5, 0.55, 0.62)        # dimmed text for non-joinable rows

# App identity. Moved off the main page into the About panel.
const APP_VERSION := "v1.0.0 rc5"
const APP_BUILD := "2026-06-19"
const APP_REPO := "pagoyadev/Pocket-Racing"
const APP_REPO_URL := "https://github.com/pagoyadev/Pocket-Racing"

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
	self.bindings_label.position = Vector2(16, 16)
	self.bindings_label.text = _build_bindings_text()
	self.bindings_label.add_theme_color_override("font_color", Color(0.90, 0.94, 0.99, 0.97))
	self.bindings_label.add_theme_color_override("font_outline_color", Color(0.03, 0.04, 0.06, 0.95))
	self.bindings_label.add_theme_constant_override("outline_size", 3)
	self.bindings_label.add_theme_constant_override("line_spacing", 5)
	self.bindings_label.add_theme_font_size_override("font_size", 16)
	# A rounded translucent card with an accent edge — readable over any track.
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = Color(0.08, 0.095, 0.12, 0.82)
	bsb.set_corner_radius_all(10)
	bsb.border_width_left = 3
	bsb.border_color = ACCENT
	bsb.content_margin_left = 18.0
	bsb.content_margin_right = 22.0
	bsb.content_margin_top = 13.0
	bsb.content_margin_bottom = 13.0
	self.bindings_label.add_theme_stylebox_override("normal", bsb)
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
	_build_quit_confirm()
	_setup_tab_style()       # real "tab" look on every platform (was mobile-only)
	_build_pad_browse_hint()
	_build_tab_pad_hints()
	_style_info_label()
	_setup_lobby_column_sizes()
	_style_lobby_tree()
	# Validate (Enter / double-click / controller accept) on a selected lobby joins it.
	self.lobbies_list.item_activated.connect(_on_lobby_activated)
	_apply_locale()
	_apply_mobile_layout()

# Mobile (web mobile) has a narrow, often portrait viewport; the menu panels are
# sized for a desktop landscape window (the central HBox is 1080 wide) and overflow,
# pushing content off-screen. Stack the online menu vertically, drop the fixed
# widths, shrink the car preview and keep the lobby list usable. Gated to
# Game.is_mobile() so desktop is untouched. First pass — tune from a real device.
func _apply_mobile_layout() -> void:
	if not Game.is_mobile():
		return
	var container := $OnlineMenu/Center/Container as BoxContainer
	container.vertical = true
	container.custom_minimum_size = Vector2.ZERO
	container.add_theme_constant_override("separation", 12)
	self.preview_slot.custom_minimum_size = Vector2(0, 120)
	($OnlineMenu/Center/Container/PilotPanel as Control).custom_minimum_size = Vector2.ZERO
	($OnlineMenu/Center/Container/CoursesPanel as Control).custom_minimum_size = Vector2.ZERO
	self.lobbies_list.custom_minimum_size = Vector2(0, 200)
	# (item_activated → join is wired once in _ready, for every input method.)
	# The list sits OUTSIDE keyboard/controller navigation (FOCUS_CLICK): D-pad on
	# the page skips it to reach the Join/Refresh buttons. You enter it explicitly
	# (action key) to scroll lobbies, and press back to leave — see _enter_lobby_list.
	self.lobbies_list.focus_mode = Control.FOCUS_CLICK
	($IntermissionMenu/Center/Panel as Control).custom_minimum_size = Vector2.ZERO

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

	# On mobile, simple bounded numeric fields open the dropdown number picker on
	# tap (same list the gamepad uses) instead of the on-screen keyboard — far
	# easier than typing a single digit. Desktop keeps direct typing.
	if Game.is_mobile():
		for f: LineEdit in [self.min_players_field, self.max_players_field]:
			f.virtual_keyboard_enabled = false
			f.gui_input.connect(_on_number_field_touch.bind(f))

func _filter_digit_field(new_text: String, field: LineEdit) -> void:
	var filtered := ""
	for ch in new_text:
		if ch >= "0" and ch <= "9":
			filtered += ch
	# Clamp to the hard player-count limits so the field can never show an
	# out-of-range value (e.g. 0, 7, 8, 9).
	if filtered != "":
		var clamped: int = clampi(int(filtered), self.game_node.MIN_LIMIT_PLAYERS, self.game_node.MAX_LIMIT_PLAYERS)
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

# Switch the active home tab (used by the L/R shoulder shortcut). `join` = Join tab.
func _select_tab(join: bool) -> void:
	_release_lobby_list_focus()  # bailing to a tab also leaves the list
	self.join_tab_button.set_pressed_no_signal(join)
	self.create_tab_button.set_pressed_no_signal(not join)
	self.join_view.visible = join
	self.create_view.visible = not join
	(self.join_tab_button if join else self.create_tab_button).grab_focus()

# True while the home Join/Create tabs are the active context (online menu shown,
# no overlay on top) — gates the tab/list shortcuts.
func _on_welcome_tabs_context() -> bool:
	return self.online_menu.visible \
		and not _settings_overlay.visible \
		and not _about_overlay.visible \
		and not _quit_overlay.visible

# Action key on the active Join tab dives into the lobby list: focus it, select a
# row, and TRAP the focus inside (every focus-neighbour points back to the list) so
# up/down only move between lobbies and never escape to the buttons. Leave with back
# (see _input → _release_lobby_list_focus).
func _enter_lobby_list() -> void:
	var t := self.lobbies_list
	var root := t.get_root()
	if root == null:
		return
	var first := root.get_first_child()
	if first == null:
		return  # empty list, nothing to browse
	t.focus_mode = Control.FOCUS_ALL
	var self_path := t.get_path()
	t.focus_neighbor_top = self_path
	t.focus_neighbor_bottom = self_path
	t.focus_neighbor_left = self_path
	t.focus_neighbor_right = self_path
	t.focus_next = self_path
	t.focus_previous = self_path
	if t.get_selected() == null:
		first.select(0)
	t.grab_focus()
	_in_lobby_list = true

# Drop the focus trap and put the list back outside navigation. Callers then grab
# focus wherever makes sense (the Join tab on back, the new tab on a tab switch).
func _release_lobby_list_focus() -> void:
	if not _in_lobby_list:
		return
	_in_lobby_list = false
	var t := self.lobbies_list
	t.focus_mode = Control.FOCUS_CLICK
	t.focus_neighbor_top = ^""
	t.focus_neighbor_bottom = ^""
	t.focus_neighbor_left = ^""
	t.focus_neighbor_right = ^""
	t.focus_next = ^""
	t.focus_previous = ^""

# Stronger "tab" look: the active tab reads as a raised, accent-topped tab flush
# with the panel below; inactive tabs are flat and dim.
func _setup_tab_style() -> void:
	for b: Button in [self.join_tab_button, self.create_tab_button]:
		b.add_theme_stylebox_override("normal", _tab_sb(false, false))
		b.add_theme_stylebox_override("hover", _tab_sb(false, true))
		b.add_theme_stylebox_override("pressed", _tab_sb(true, false))
		b.add_theme_stylebox_override("focus", _tab_focus_sb())
		b.add_theme_color_override("font_color", Color(0.58, 0.64, 0.72))
		b.add_theme_color_override("font_hover_color", Color(0.85, 0.9, 0.96))
		b.add_theme_color_override("font_pressed_color", ACCENT_BRIGHT)
		b.add_theme_font_size_override("font_size", 16)

func _tab_sb(active: bool, hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if active:
		sb.bg_color = Color(0.17, 0.20, 0.26)
	elif hover:
		sb.bg_color = Color(0.12, 0.14, 0.18)
	else:
		sb.bg_color = Color(0.08, 0.09, 0.12)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	if active:
		sb.border_width_top = 3
		sb.border_color = ACCENT
	return sb

func _tab_focus_sb() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.draw_center = false
	sb.set_border_width_all(2)
	sb.border_color = ACCENT_BRIGHT
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	return sb

func _build_bindings_text() -> String:
	var lines: Array[String] = [tr("hud_controls")]
	for action in Bindings.ACTIONS:
		if action in Bindings.LOOK_ACTIONS:
			continue  # look/camera bindings stay in Settings, not on the in-game HUD
		var code := Bindings.get_key(action)
		var key := Bindings.key_label(code) if code != 0 else ""
		var joy := Bindings.joy_label(action)
		if key == "" and joy == "":
			continue
		# Show both the keyboard key and the gamepad button, e.g. "W / RB".
		var combo := key
		if key != "" and joy != "":
			combo = "%s / %s" % [key, joy]
		elif joy != "":
			combo = joy
		lines.append("%s   %s" % [combo, tr("act_" + action)])
	return "\n".join(lines)

func _apply_lobby_columns() -> void:
	self.lobbies_list.set_column_title(0, tr("col_name"))
	self.lobbies_list.set_column_title(1, tr("col_owner"))
	self.lobbies_list.set_column_title(2, tr("col_players"))
	self.lobbies_list.set_column_title(3, tr("col_min"))
	self.lobbies_list.set_column_title(4, tr("col_state"))
	self.lobbies_list.set_column_title(5, tr("col_start"))
	self.lobbies_list.set_column_title(6, tr("col_track"))
	# Centre the titles over the (centred) cell values.
	for c in 7:
		self.lobbies_list.set_column_title_alignment(c, HORIZONTAL_ALIGNMENT_CENTER)

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

# Restyle the lobby Tree for scannability: roomier rows, faint guide lines, a
# clear amber selection + focus ring, and a flat flush header. Built in code so it
# stays beside the column setup (the scene leaves the Tree on the default theme).
func _style_lobby_tree() -> void:
	var t := self.lobbies_list
	t.add_theme_constant_override("v_separation", 10)
	t.add_theme_constant_override("inner_item_margin_left", 10)
	t.add_theme_constant_override("inner_item_margin_right", 10)
	t.add_theme_constant_override("draw_guides", 1)
	t.add_theme_font_size_override("font_size", 15)
	t.add_theme_font_size_override("title_button_font_size", 12)
	t.add_theme_color_override("font_color", Color(0.80, 0.85, 0.92))
	t.add_theme_color_override("font_selected_color", Color(1, 1, 1))
	t.add_theme_color_override("title_button_color", Color(0.56, 0.63, 0.73))
	t.add_theme_color_override("guide_color", Color(1, 1, 1, 0.045))

	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.07, 0.08, 0.10, 0.85)
	panel.set_border_width_all(1)
	panel.border_color = Color(0.15, 0.17, 0.21)
	panel.set_corner_radius_all(8)
	panel.content_margin_left = 6.0
	panel.content_margin_right = 6.0
	panel.content_margin_top = 6.0
	panel.content_margin_bottom = 6.0
	t.add_theme_stylebox_override("panel", panel)

	# Amber selection with an accent edge; the focused variant is a touch stronger.
	t.add_theme_stylebox_override("selected", _tree_sel_sb(0.22))
	t.add_theme_stylebox_override("selected_focus", _tree_sel_sb(0.32))

	# Keyboard / controller focus ring around the current row.
	var cursor := StyleBoxFlat.new()
	cursor.draw_center = false
	cursor.set_border_width_all(2)
	cursor.border_color = ACCENT_BRIGHT
	cursor.set_corner_radius_all(6)
	t.add_theme_stylebox_override("cursor", cursor)
	t.add_theme_stylebox_override("cursor_unfocused", cursor)

	# Flat header flush with the list, with a hairline under the titles.
	for s in ["title_button_normal", "title_button_hover", "title_button_pressed"]:
		var tb := StyleBoxFlat.new()
		tb.bg_color = Color(0.10, 0.115, 0.14, 0.0)
		tb.content_margin_left = 10.0
		tb.content_margin_right = 10.0
		tb.content_margin_top = 6.0
		tb.content_margin_bottom = 8.0
		tb.border_width_bottom = 1
		tb.border_color = Color(0.22, 0.25, 0.30)
		t.add_theme_stylebox_override(s, tb)

func _tree_sel_sb(alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, alpha)
	sb.border_width_left = 3
	sb.border_color = ACCENT_BRIGHT
	sb.set_corner_radius_all(6)
	return sb

# ----------------------------------------------------------------------------
# Logo: a polished two-tone "POCKET RACING" wordmark with a chevron mark, soft
# glow and an accent underline. Added to MenuChrome so it shows on the menu only.

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
	ls.outline_color = Color(0.08, 0.05, 0.03, 0.92)
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

	var mark := Label.new()
	mark.text = "»"
	mark.label_settings = _logo_settings(font, 38, ACCENT_BRIGHT, true)
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(mark)

	var word1 := Label.new()
	word1.text = "POCKET"
	word1.label_settings = _logo_settings(font, 50, Color(0.98, 0.97, 0.94), true)
	row.add_child(word1)

	var word2 := Label.new()
	word2.text = "RACING"
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
	var mark := Label.new()
	mark.text = "»"
	mark.label_settings = _logo_settings(font, 26, ACCENT_BRIGHT, false)
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(mark)
	var w1 := Label.new()
	w1.text = "POCKET"
	w1.label_settings = _logo_settings(font, 30, Color(0.98, 0.97, 0.94), false)
	head.add_child(w1)
	var w2 := Label.new()
	w2.text = "RACING"
	w2.label_settings = _logo_settings(font, 30, ACCENT_BRIGHT, false)
	head.add_child(w2)
	parent.add_child(head)

# ----------------------------------------------------------------------------
# About panel: version/build/source, a "Made by" section (designer + Claude, two
# equal credits) and third-party credits (CC0 first). Same overlay pattern as
# the settings panel, built in code.

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

	# Made by — the designer and Claude as two SEPARATE, EQUAL credits (same weight,
	# no maker's-mark hierarchy): two people, side by side.
	box.add_child(_make_about_label("about_team", ACCENT, 13))
	box.add_child(_make_about_label("about_team_designer", Color(0.88, 0.92, 0.98), 0))
	box.add_child(_make_about_label("about_team_claude", Color(0.88, 0.92, 0.98), 0))

	box.add_child(HSeparator.new())

	# Credits — third-party assets & tech. CC0 first and clearly labelled: public-domain
	# assets are always credited with thanks even though attribution isn't required.
	box.add_child(_make_about_label("about_credits", ACCENT, 13))
	box.add_child(_make_about_label("about_credits_cc0", Color(0.88, 0.92, 0.98), 0))
	box.add_child(_make_about_label("about_credits_engine", Color(0.78, 0.84, 0.92), 0))
	box.add_child(_make_about_label("about_credits_physics", Color(0.78, 0.84, 0.92), 0))
	box.add_child(_make_about_label("about_credits_server", Color(0.78, 0.84, 0.92), 0))
	box.add_child(_make_about_label("about_credits_art", Color(0.78, 0.84, 0.92), 0))

	box.add_child(HSeparator.new())

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
# Controller-only "browse the list" hint: ▲▼ glyphs shown just under the lobby
# list while a gamepad is in use, so it's clear the D-pad scrolls the races.

# Browse hint: hand-DRAWN up/down triangles + a label. Drawn (not a glyph) so it
# renders identically everywhere, including the web export where the bundled font
# lacks ▲▼ and SystemFont isn't available (they showed as tofu in the browser).
func _build_pad_browse_hint() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.visible = false

	var arrows := Control.new()
	arrows.custom_minimum_size = Vector2(13, 22)
	arrows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrows.draw.connect(_draw_updown_arrows.bind(arrows))
	row.add_child(arrows)

	_pad_browse_label = Label.new()
	_pad_browse_label.add_theme_font_size_override("font_size", 13)
	_pad_browse_label.add_theme_color_override("font_color", ACCENT_BRIGHT)
	_pad_browse_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_pad_browse_label)

	self.join_view.add_child(row)
	self.join_view.move_child(row, 1)  # between the list and the footer
	_pad_browse_hint = row
	_refresh_pad_browse_hint()

func _draw_updown_arrows(c: Control) -> void:
	var w := c.size.x
	var h := c.size.y
	var cx := w * 0.5
	var half := w * 0.5
	var up := PackedVector2Array([Vector2(cx, 0.0), Vector2(cx - half, h * 0.42), Vector2(cx + half, h * 0.42)])
	var dn := PackedVector2Array([Vector2(cx, h), Vector2(cx - half, h * 0.58), Vector2(cx + half, h * 0.58)])
	c.draw_colored_polygon(up, ACCENT_BRIGHT)
	c.draw_colored_polygon(dn, ACCENT_BRIGHT)

func _refresh_pad_browse_hint() -> void:
	if _pad_browse_label:
		_pad_browse_label.text = tr("pad_browse")

# L / R key-caps flanking the Join | Create tabs, so it reads that the shoulder
# buttons switch tabs. Plain ASCII (renders in any font) on a rounded key-cap.
# Shown only with a controller in hand (see _process).
func _build_tab_pad_hints() -> void:
	var tabs := self.join_tab_button.get_parent() as HBoxContainer
	_tab_hint_l = _make_pad_key_label("L")
	tabs.add_child(_tab_hint_l)
	tabs.move_child(_tab_hint_l, 0)  # left of the Join tab
	_tab_hint_r = _make_pad_key_label("R")
	tabs.add_child(_tab_hint_r)  # right of the Create tab (appended last)

func _make_pad_key_label(txt: String) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.97, 0.98, 1.0))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.20, 0.23, 0.29)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 9.0
	sb.content_margin_right = 9.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	sb.border_width_bottom = 2
	sb.border_color = Color(0.12, 0.14, 0.18)
	l.add_theme_stylebox_override("normal", sb)
	l.visible = false
	return l

# ----------------------------------------------------------------------------
# Quit confirmation: a small Yes/No dialog so a stray controller flick + validate
# can't quit the game by accident (focus defaults to Cancel). Same overlay pattern
# as the settings/about panels.

func _build_quit_confirm() -> void:
	_quit_overlay = Control.new()
	_quit_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_quit_overlay.visible = false
	add_child(_quit_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.04, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_quit_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_quit_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.125, 0.15, 0.99)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.18, 0.2, 0.24, 1)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 24.0
	sb.content_margin_bottom = 24.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	panel.add_child(box)

	_quit_title = Label.new()
	_quit_title.add_theme_font_size_override("font_size", 20)
	_quit_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_quit_title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)

	# Cancel first and focused by default — the safe choice catches a stray validate.
	_quit_no = Button.new()
	_quit_no.size_flags_horizontal = SIZE_EXPAND_FILL
	_quit_no.pressed.connect(_on_quit_cancel)
	row.add_child(_quit_no)

	_quit_yes = Button.new()
	_quit_yes.size_flags_horizontal = SIZE_EXPAND_FILL
	_quit_yes.pressed.connect(_on_quit_confirmed)
	row.add_child(_quit_yes)

func _refresh_quit_labels() -> void:
	if _quit_title == null:
		return
	_quit_title.text = tr("quit_confirm")
	_quit_no.text = tr("quit_cancel")
	_quit_yes.text = tr("quit_yes")

func _on_quit_cancel() -> void:
	_quit_overlay.visible = false
	self.quit_button.grab_focus()

func _on_quit_confirmed() -> void:
	self.game_node._save_settings()
	get_tree().quit()

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
	_refresh_quit_labels()
	_refresh_pad_browse_hint()
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
	# Keyboard/controller navigation scrolls the list to the focused row, and the
	# list height adapts to the window so the dialog never overflows off-screen.
	scroll.follow_focus = true
	_settings_scroll = scroll
	get_viewport().size_changed.connect(_fit_settings_scroll)
	box.add_child(scroll)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	scroll.add_child(rows)

	# Gamepad bindings are read-only (joypad events aren't rebindable here) and
	# hidden on mobile, where there's no controller.
	var show_pad := not Game.is_mobile()

	# Column header: keyboard (rebindable) | gamepad (read-only).
	var header := HBoxContainer.new()
	header.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_theme_constant_override("separation", 12)
	var header_spacer := Label.new()
	header_spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(header_spacer)
	_settings_kbd_header = _make_col_header()
	header.add_child(_settings_kbd_header)
	_settings_pad_header = _make_col_header()
	_settings_pad_header.visible = show_pad
	header.add_child(_settings_pad_header)
	rows.add_child(header)

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

		# Rebindable gamepad binding for this action (e.g. "RB", "RT", "Y"). Hidden
		# on mobile (no controller). Capture is handled in _input via Godot's events.
		var pad_button := Button.new()
		pad_button.custom_minimum_size = Vector2(150, 0)
		pad_button.pressed.connect(_on_rebind_joy_pressed.bind(action))
		pad_button.visible = show_pad
		row.add_child(pad_button)

		rows.add_child(row)
		_binding_rows[action] = {"name": name_label, "key": key_button, "pad": pad_button}

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

# Size the bindings list to the window: tall screens get a longer list, short
# ones a shorter one, so the surrounding dialog (title, language, footer) always
# stays on-screen and the list scrolls within whatever room is left.
func _fit_settings_scroll() -> void:
	if _settings_scroll == null:
		return
	var vh := get_viewport().get_visible_rect().size.y
	_settings_scroll.custom_minimum_size.y = clampf(vh - 320.0, 160.0, 460.0)

# Small centred column header above the binding rows (150-wide to match a column).
func _make_col_header() -> Label:
	var l := Label.new()
	l.custom_minimum_size = Vector2(150, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", ACCENT)
	return l

func _refresh_settings_labels() -> void:
	if _settings_title == null:
		return
	_settings_title.text = tr("set_title")
	_settings_lang_label.text = tr("set_language")
	_settings_controls_label.text = tr("set_controls")
	if _settings_kbd_header != null:
		_settings_kbd_header.text = tr("set_keyboard")
	if _settings_pad_header != null:
		_settings_pad_header.text = tr("set_gamepad")
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
		if row.has("pad") and action != _rebinding_joy_action:
			_set_pad_button_text(action)

func _on_settings_pressed() -> void:
	_refresh_settings_labels()
	_refresh_binding_rows()
	_fit_settings_scroll()
	_settings_overlay.visible = true
	_close_button.grab_focus()

func _on_settings_close() -> void:
	_cancel_rebind()
	_cancel_joy_rebind()
	_settings_overlay.visible = false

func _on_language_selected(index: int) -> void:
	Locale.set_locale(Locale.LOCALES[index])

func _on_reset_bindings() -> void:
	_cancel_rebind()
	_cancel_joy_rebind()
	Bindings.reset()
	_refresh_binding_rows()
	if self.bindings_label:
		self.bindings_label.text = _build_bindings_text()

func _on_rebind_pressed(action: String) -> void:
	_cancel_rebind()
	_cancel_joy_rebind()
	_rebinding_action = action
	(_binding_rows[action]["key"] as Button).text = tr("set_press_key")

func _cancel_rebind() -> void:
	if _rebinding_action == "":
		return
	var action := _rebinding_action
	_rebinding_action = ""
	(_binding_rows[action]["key"] as Button).text = Bindings.key_label(Bindings.get_key(action))

func _on_rebind_joy_pressed(action: String) -> void:
	_cancel_rebind()
	_cancel_joy_rebind()
	_rebinding_joy_action = action
	(_binding_rows[action]["pad"] as Button).text = tr("set_press_button")

func _cancel_joy_rebind() -> void:
	if _rebinding_joy_action == "":
		return
	var action := _rebinding_joy_action
	_rebinding_joy_action = ""
	_set_pad_button_text(action)

func _set_pad_button_text(action: String) -> void:
	var pad := Bindings.joy_label(action)
	(_binding_rows[action]["pad"] as Button).text = pad if pad != "" else "—"

func _input(event: InputEvent) -> void:
	# Track which device the player is actually using, so controller-only hints
	# (the ▲▼ list-browse cue) appear with a pad and vanish the moment they touch
	# the keyboard or mouse.
	if event is InputEventJoypadButton \
	or (event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.5):
		_using_gamepad = true
	elif event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion:
		_using_gamepad = false

	# Capturing a new gamepad button for an action takes precedence over everything.
	if _rebinding_joy_action != "":
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_cancel_joy_rebind()
			return
		var serial := Bindings.capture_joy(event)
		if serial != "":
			get_viewport().set_input_as_handled()
			var jaction := _rebinding_joy_action
			_rebinding_joy_action = ""
			Bindings.set_joy(jaction, serial)
			_refresh_binding_rows()
			if self.bindings_label:
				self.bindings_label.text = _build_bindings_text()
			return
		# Swallow stray joypad events while waiting so they don't navigate the UI.
		if event is InputEventJoypadButton or event is InputEventJoypadMotion:
			get_viewport().set_input_as_handled()
			return
	# Home tabs: shoulder L/R switch Join/Create; the action key on the Join tab
	# dives into the lobby list; back returns from the list to the tabs.
	if _on_welcome_tabs_context():
		if event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
			var b := (event as InputEventJoypadButton).button_index
			if b == JOY_BUTTON_LEFT_SHOULDER:
				get_viewport().set_input_as_handled()
				_select_tab(true)
				return
			if b == JOY_BUTTON_RIGHT_SHOULDER:
				get_viewport().set_input_as_handled()
				_select_tab(false)
				return
		var foc := get_viewport().gui_get_focus_owner()
		if event.is_action_pressed("ui_accept") and foc == self.join_tab_button and self.join_view.visible:
			get_viewport().set_input_as_handled()
			_enter_lobby_list()
			return
		# Validate on a highlighted lobby joins it (controller/keyboard), whether the
		# list was entered via the focus-trap OR reached directly by D-pad — so we key
		# off "the list holds focus", not _in_lobby_list. Mouse double-click is covered
		# by item_activated. Only when a row is actually selectable (Join enabled).
		if foc == self.lobbies_list and event.is_action_pressed("ui_accept") and not self.join_button.disabled:
			get_viewport().set_input_as_handled()
			_on_join_button_pressed()
			return
		if _in_lobby_list and event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			_release_lobby_list_focus()
			self.join_tab_button.grab_focus()
			return
	# Gamepad accept on a focused single-digit numeric field → open the number picker.
	if event is InputEventJoypadButton and event.is_action_pressed("ui_accept"):
		var focus := get_viewport().gui_get_focus_owner()
		if focus != null and _is_number_picker_field(focus):
			get_viewport().set_input_as_handled()
			_open_number_picker(focus as LineEdit)
			return
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
	# Controller-only hints: L/R key-caps on the tabs (both tabs), and the ▲▼
	# list-browse hint (Join tab only). Shown only with a controller in hand and no
	# overlay up; they vanish the moment the player touches keyboard/mouse.
	var pad_ctx: bool = _using_gamepad and self.online_menu.visible \
		and not _settings_overlay.visible and not _about_overlay.visible \
		and not _quit_overlay.visible
	if _tab_hint_l:
		_tab_hint_l.visible = pad_ctx
	if _tab_hint_r:
		_tab_hint_r.visible = pad_ctx
	if _pad_browse_hint:
		_pad_browse_hint.visible = pad_ctx and self.join_view.visible
	# Show the controls card whenever the car is on track — racing OR the on-track
	# pre-race countdown (LOBBY_INTERMISSION with the lobby menu hidden) — and keep
	# it up through pause. Only hidden on mobile (touch controls replace it).
	var on_track: bool = %Game.mode == Game.Mode.IN_RACE \
		or (%Game.mode == Game.Mode.LOBBY_INTERMISSION and not self.intermission_menu.visible)
	self.bindings_label.visible = on_track and not Game.is_mobile()
	# Pause must be reachable any time the car is on track — racing, spectating, OR
	# the on-track pre-race countdown (so you can quit during the lights). The lobby
	# waiting screen (intermission menu visible) keeps its own navigation instead.
	var can_pause: bool = %Game.mode == Game.Mode.IN_RACE or %Game.mode == Game.Mode.SPECTATOR \
		or (%Game.mode == Game.Mode.LOBBY_INTERMISSION and not self.intermission_menu.visible)
	if can_pause:
		if Input.is_action_just_released("Pause"):
			self.play_menu_panel.visible = ! self.play_menu_panel.visible
			# Focus the panel on open so a controller's D-pad can navigate it.
			if self.play_menu_panel.visible:
				($PlayMenuPanel/PlayMenu/BackToRaceButton as Button).grab_focus()

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
		_release_lobby_list_focus()  # return to the page with the list un-entered
		self.alpha_info.visible = true
		self.online_menu.visible = true
		self.play_menu_panel.visible = false
		self.menu_background.visible = true
		_set_status("")
		self.refresh_list_button.disabled = false
		if self.game_node.mode == Game.Mode.IN_RACE \
		   || self.game_node.mode == Game.Mode.LOBBY_INTERMISSION \
		   || self.game_node.mode == Game.Mode.SPECTATOR:
			self.create_button.disabled = false
			self.nickname_field.grab_focus()
		elif self.game_node.mode == Game.Mode.FETCH_LOBBIES:
			if !server_up:
				_set_status(tr("no_connection"), StatusKind.ERROR)
				self.join_button.disabled = true
				self.create_button.disabled = true
			else:
				_set_status(tr("lobbies_fetched"), StatusKind.INFO)
				self.join_button.disabled = false
				self.create_button.disabled = (_track_picker == null) or (_track_picker.item_count == 0) or _track_picker.disabled
		# Controller: make sure a widget holds focus so the D-pad can navigate.
		if get_viewport().gui_get_focus_owner() == null:
			self.join_tab_button.grab_focus()
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
	self.game_node.paused = false

func _on_leave_pressed() -> void:
	self.game_node.paused = false
	self.network.terminate()

func _on_back_pressed() -> void:
	self.online_menu.visible = false

func _on_quit_pressed() -> void:
	# Don't quit on the press itself — confirm first, with focus on Cancel, so an
	# accidental controller flick + validate can't drop the player out of the game.
	_refresh_quit_labels()
	_quit_overlay.visible = true
	_quit_no.grab_focus()

func _on_editor_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/editor.tscn")

func _on_join_button_pressed() -> void:
	if not self.game_node.check_nickname(get_nickname()):
		set_status_error(tr("err_invalid_name"))
		return
	self.game_node.switch_mode(Game.Mode.JOINING_LOBBY, true)

# Double-click / Enter on a lobby row → join it (when one is actually joinable).
func _on_lobby_activated(_column: int = 0) -> void:
	if not self.join_button.disabled:
		_on_join_button_pressed()

func _on_create_button_pressed() -> void:
	if not self.game_node.check_nickname(get_nickname()) \
	or not self.game_node.check_lobby_name(get_lobby_name()):
		set_status_error(tr("err_invalid_name"))
		return
	self.game_node.switch_mode(Game.Mode.CREATING_LOBBY, true)

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
	if !tracks.is_empty() && self.game_node.mode == Game.Mode.FETCH_LOBBIES:
		self.create_button.disabled = false

func get_selected_track_id() -> String:
	if _track_picker == null || _track_picker.item_count == 0:
		return ""
	var idx := _track_picker.selected
	if idx < 0:
		idx = 0
	var meta = _track_picker.get_item_metadata(idx)
	return String(meta) if meta != null else ""

# Rank a lobby for the joinable-first ordering: open with room (0), racing with
# room (1), full (2). Lower sorts higher.
func _lobby_rank(info) -> int:
	if int(info.player_count) >= int(info.max_players):
		return 2
	if bool(info.racing):
		return 1
	return 0

func refresh(lobby_infos: Array):
	self.lobbies_list.clear()
	self.tree_root = self.lobbies_list.create_item()

	# Open races you can actually jump into come first, then races in progress, then
	# full ones — so the most useful rows are right at the top of the list.
	var infos := lobby_infos.duplicate()
	infos.sort_custom(func(a, b): return _lobby_rank(a) < _lobby_rank(b))

	# Empty list: an in-list message (right where the eye is) reads better than just
	# the far-corner status pill. Let column 0 overflow so the message isn't clipped.
	if infos.is_empty():
		self.lobbies_list.set_column_clip_content(0, false)
		var empty_item = self.tree_root.create_child()
		empty_item.set_text(0, tr("no_lobbies"))
		empty_item.set_custom_color(0, ROW_DIM)
		for c in 7:
			empty_item.set_selectable(c, false)
		if _status_kind != StatusKind.ERROR:
			_set_status(tr("no_lobbies"), StatusKind.INFO)
		return
	self.lobbies_list.set_column_clip_content(0, true)

	for info in infos:
		var item = self.tree_root.create_child()
		var full := int(info.player_count) >= int(info.max_players)
		var racing := bool(info.racing)

		item.set_text(0, info.name)
		item.set_tooltip_text(0, info.name)  # full value on hover when the cell clips
		item.set_text(1, info.owner)
		item.set_tooltip_text(1, info.owner)
		item.set_text(2, "%d/%d" % [int(info.player_count), int(info.max_players)])
		item.set_text(3, str(int(info.min_players)))
		var track_name := str(info.get("track_name", ""))
		item.set_text(6, track_name)
		item.set_tooltip_text(6, track_name)
		item.set_text(5, info.start_time)

		# Colour-coded status so room-to-join reads at a glance.
		var status_txt: String
		var status_col: Color
		if full:
			status_txt = tr("state_full")
			status_col = STATE_FULL
		elif racing:
			status_txt = tr("state_racing")
			status_col = STATE_RACING
		else:
			status_txt = tr("state_intermission")
			status_col = STATE_OPEN
		item.set_text(4, status_txt)
		item.set_custom_color(4, status_col)
		if full:
			item.set_custom_color(2, STATE_FULL)  # the grid count itself reads "full"

		for c in 7:
			item.set_text_alignment(c, HORIZONTAL_ALIGNMENT_CENTER)

		# A full lobby returns LobbyFull on join — dim it and pull it out of selection
		# so the Join action can never be aimed at a guaranteed failure.
		if full:
			for c in 7:
				item.set_selectable(c, false)
			for c in [0, 1, 6]:
				item.set_custom_color(c, ROW_DIM)

func _on_refresh_list_button_pressed() -> void:
	%Game.switch_mode(Game.Mode.FETCH_LOBBIES, false)

# Controller-friendly number entry for the single-digit player-count fields: a
# popup list of the valid numbers, navigable with the D-pad and the accept button.
# Opened from _input() when the gamepad accept button is pressed on a focused field
# (typing a digit is awkward on a pad; keyboard/mouse keep typing as before).
# Mobile: a tap on a numeric field opens the dropdown picker instead of the
# keyboard. Releases focus first so no caret/soft-keyboard appears.
func _on_number_field_touch(event: InputEvent, field: LineEdit) -> void:
	var tapped: bool = (event is InputEventScreenTouch and event.pressed) \
		or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT)
	if tapped:
		field.accept_event()
		field.release_focus()
		_open_number_picker(field)

func _open_number_picker(field: LineEdit) -> void:
	var lo: int = self.game_node.MIN_LIMIT_PLAYERS
	var hi: int = self.game_node.MAX_LIMIT_PLAYERS
	var pm := PopupMenu.new()
	for n in range(lo, hi + 1):
		pm.add_item(str(n), n)
	add_child(pm)
	pm.id_pressed.connect(func(id: int) -> void:
		field.text = str(id)
		_filter_digit_field(field.text, field)  # re-run the clamp/sanitise
	)
	pm.popup_hide.connect(pm.queue_free)
	pm.reset_size()
	var at := field.get_screen_position() + Vector2(0.0, field.size.y + 2.0)
	pm.position = Vector2i(at)
	pm.popup()

func _is_number_picker_field(node: Control) -> bool:
	return node == self.min_players_field or node == self.max_players_field

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
		self.players_in_lobby.add_child(_make_result_row(i + 1, String(rankings[i])))
	_set_status(tr("race_finished"), StatusKind.SUCCESS)

# A finish-order row: a medal-coloured position badge + the racer's name, with the
# top three tinted gold/silver/bronze and the winner enlarged and highlighted.
func _make_result_row(rank: int, racer_name: String) -> PanelContainer:
	var medal := ROW_DIM
	if rank == 1:
		medal = Color(1.0, 0.84, 0.20)    # gold
	elif rank == 2:
		medal = Color(0.80, 0.84, 0.88)   # silver
	elif rank == 3:
		medal = Color(0.82, 0.52, 0.28)   # bronze
	var winner := rank == 1

	var chip := PanelContainer.new()
	chip.size_flags_horizontal = SIZE_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.14, 0.18, 0.97) if winner else Color(0.09, 0.105, 0.13, 0.94)
	sb.set_corner_radius_all(8)
	sb.border_width_left = 6 if winner else 4
	sb.border_color = medal
	sb.content_margin_left = 14.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 12.0 if winner else 9.0
	sb.content_margin_bottom = 12.0 if winner else 9.0
	chip.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	chip.add_child(row)

	# Position badge: the rank number on a rounded medal-coloured square.
	var badge := Label.new()
	badge.text = str(rank)
	badge.custom_minimum_size = Vector2(34, 34)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 18 if winner else 16)
	badge.add_theme_color_override("font_color", Color(0.06, 0.07, 0.09))
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = medal
	bsb.set_corner_radius_all(8)
	badge.add_theme_stylebox_override("normal", bsb)
	row.add_child(badge)

	var nm := Label.new()
	nm.text = racer_name
	nm.size_flags_horizontal = SIZE_EXPAND_FILL
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nm.add_theme_font_size_override("font_size", 22 if winner else 17)
	nm.add_theme_color_override("font_color", Color(1.0, 0.95, 0.80) if winner else Color(0.90, 0.93, 0.97))
	row.add_child(nm)

	return chip
