extends PanelContainer

## Right-hand inspector. Two tabs:
##   "Objet"   — fields of the selected object, rebuilt per selection: a primitive
##               (EditorItem) or a race gate (EditorGate, with a role + half-width).
##   "Circuit" — track-level settings: id, name, laps_to_win.
##
## Every widget edits the live data dictionaries in place and calls back into the
## MapEditor so the 3D view updates immediately. `editor` and `_item` are untyped
## to avoid a cyclic class dependency and to accept both object kinds.

class_name MapInspector

const LABEL_W := 116
const SPIN_BIG := 100000.0

var editor                       # MapEditor
var _item = null                 # EditorItem or EditorGate
var _updating := false

var _tabs: TabContainer
var _obj_box: VBoxContainer
var _obj_fields := {}            # key -> Array[SpinBox] for vec3 rows
var _num_fields := {}            # key -> SpinBox for scalar rows (live gizmo refresh)

# Circuit-tab widgets.
var _c_id: LineEdit
var _c_name: LineEdit
var _c_laps: SpinBox

func setup(editor_ref) -> void:
	editor = editor_ref
	_apply_anchors()
	add_theme_stylebox_override("panel", _panel_style())

	_tabs = TabContainer.new()
	add_child(_tabs)
	_build_object_tab()
	_build_circuit_tab()

	set_item(null)
	refresh_circuit()

func _apply_anchors() -> void:
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	offset_left = -340.0
	offset_right = -12.0
	offset_top = 60.0
	offset_bottom = -44.0

# ---------------------------------------------------------------------------
# Object tab

func _build_object_tab() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Object"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, tr("ed_tab_object"))

	_obj_box = VBoxContainer.new()
	_obj_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_obj_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_obj_box)

func set_item(item) -> void:
	_item = item
	_rebuild_object_tab()

func _rebuild_object_tab() -> void:
	_clear(_obj_box)
	_obj_fields.clear()
	_num_fields.clear()
	if _item == null:
		var l := Label.new()
		l.text = tr("ed_no_sel")
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
		_obj_box.add_child(l)
	elif _item is EditorGate:
		_build_gate_fields()
	elif _item is RoadNodeHandle:
		_build_road_node_fields()
	else:
		_build_primitive_fields()

func _build_primitive_fields() -> void:
	var t: String = _item.get_type()
	_add_header("%s — %s" % [String(_item.data.get("name", "?")), t])
	_add_text_row(tr("ed_f_name"), String(_item.data.get("name", "")), func(s): _set_key("name", s))
	if t == "road":
		_build_road_fields()
		return
	_add_vec3_row(tr("ed_f_size"), "size", 0.1)
	_add_vec3_row(tr("ed_f_position"), "position", 0.5)
	_add_vec3_row(tr("ed_f_rotation"), "rotation_deg", 1.0)

	if t == "pad":
		_add_vec3_row(tr("ed_f_heading"), "heading", 0.1)
		_add_num_row(tr("ed_f_boost"), "boost_strength", 0.0, 200.0, 1.0, false)
	else:
		_add_color_row(tr("ed_f_color"), "color")

	if t == "curve":
		_add_num_row(tr("ed_f_segments"), "segments", 1.0, 64.0, 1.0, true)

	if t == "arc":
		_add_num_row(tr("ed_f_segments"), "segments", 1.0, 64.0, 1.0, true)
		_add_num_row(tr("ed_f_sweep"), "sweep_deg", -180.0, 180.0, 1.0, false)

	if t == "decor":
		_add_text_row(tr("ed_f_model"), String(_item.data.get("model", "")), func(s): _set_key("model", s))
		_add_bool_row(tr("ed_f_collide"), _item.data.get("collide", true) != false, func(on): _set_key("collide", on))

# Road primitive: size (x=width, y=thickness), colour, tessellation, side walls,
# and a node-count readout with an "add node" button. Per-node values (position,
# width, bank) are edited by selecting a node sphere in the 3D view.
func _build_road_fields() -> void:
	_add_vec3_row(tr("ed_f_size"), "size", 0.1)
	_add_color_row(tr("ed_f_color"), "color")
	_add_num_row(tr("ed_f_segments"), "segments", 1.0, 64.0, 1.0, true)
	_add_bool_row(tr("ed_f_walls"), _item.data.get("walls", false) == true, func(on): _set_key("walls", on))
	_add_num_row(tr("ed_f_wall_height"), "wall_height", 0.0, 50.0, 0.5, false, 1.2)

	var nodes: Array = _item.data.get("nodes", [])
	var info := Label.new()
	info.text = tr("ed_road_nodes") % nodes.size()
	info.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	_obj_box.add_child(info)

	var add_btn := Button.new()
	add_btn.text = tr("ed_road_add_node")
	add_btn.pressed.connect(func(): editor._add_road_node(_item))
	_obj_box.add_child(add_btn)

	var hint := Label.new()
	hint.text = tr("ed_road_node_hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	_obj_box.add_child(hint)

# One road control node (a selected RoadNodeHandle): its position, plus optional
# per-node width / banking overrides, plus a delete button.
func _build_road_node_fields() -> void:
	_add_header(tr("ed_road_node_label") % _item.index)
	_add_vec3_row(tr("ed_f_position"), "position", 0.5)
	var road_w := 24.0
	if is_instance_valid(_item.road):
		road_w = _item.road.get_size().x
	_add_num_row(tr("ed_f_width"), "width", 1.0, 200.0, 0.5, false, road_w)
	_add_num_row(tr("ed_f_bank"), "bank_deg", -60.0, 60.0, 1.0, false)

	var del := Button.new()
	del.text = tr("ed_road_del_node")
	del.pressed.connect(func(): editor._delete_road_node(_item))
	_obj_box.add_child(del)

func _build_gate_fields() -> void:
	_add_header(tr("ed_gate_header") % _role_fr(String(_item.data.get("role", "checkpoint"))))

	var row := _labeled_row(_obj_box, tr("ed_f_role"))
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for r in MapIO.ROLES:
		opt.add_item(_role_fr(r))
	var cur := MapIO.ROLES.find(String(_item.data.get("role", "checkpoint")))
	opt.select(maxi(cur, 0))
	opt.item_selected.connect(func(idx): _set_role(MapIO.ROLES[idx]))
	row.add_child(opt)

	_add_num_row(tr("ed_f_halfwidth"), "half_width", 0.5, 1000.0, 0.5, false)
	_add_vec3_row(tr("ed_f_position"), "position", 0.5)
	_add_vec3_row(tr("ed_f_rotation"), "rotation_deg", 1.0)

func _role_fr(role: String) -> String:
	return tr("ed_role_" + role)

# ---------------------------------------------------------------------------
# Circuit tab

func _build_circuit_tab() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Circuit"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, tr("ed_tab_track"))

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)

	_header_into(box, tr("ed_sec_circuit"))
	_c_id = _text_into(box, "ID", func(s): _set_track_meta("id", s))
	_c_name = _text_into(box, tr("ed_f_name"), func(s): _set_track_meta("name", s))

	var row := _labeled_row(box, tr("ed_f_laps"))
	_c_laps = _make_spin(3.0, 1.0, 1.0, SPIN_BIG)
	_c_laps.value_changed.connect(func(v): _set_laps(v))
	row.add_child(_c_laps)

	var hint := Label.new()
	hint.text = tr("ed_gate_hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	box.add_child(hint)

func refresh_circuit() -> void:
	if editor == null or _c_id == null:
		return
	_updating = true
	var td: Dictionary = editor.track_def
	_c_id.text = String(td.get("id", ""))
	_c_name.text = String(td.get("name", ""))
	_c_laps.set_value_no_signal(float(td.get("laps_to_win", 3)))
	_updating = false

# ---------------------------------------------------------------------------
# Live refresh of the selected object's transform (called after a gizmo drag)

func refresh_selected_transform() -> void:
	if _item == null:
		return
	_updating = true
	for key in ["position", "rotation_deg", "size"]:
		if _obj_fields.has(key):
			var arr: Array = _item.data.get(key, [0.0, 0.0, 0.0])
			var spins: Array = _obj_fields[key]
			for i in 3:
				spins[i].set_value_no_signal(float(arr[i]) if arr.size() > i else 0.0)
	# Scalar rows (e.g. a road node's bank) so the gizmo's banking ring updates live.
	for key in _num_fields:
		var sp: SpinBox = _num_fields[key]
		if is_instance_valid(sp):
			sp.set_value_no_signal(float(_item.data.get(key, sp.value)))
	_updating = false

# ---------------------------------------------------------------------------
# Field writers

func _set_key(key: String, value) -> void:
	if _updating or _item == null:
		return
	_item.data[key] = value
	editor.on_item_data_changed(_item)

func _set_role(role: String) -> void:
	if _updating or _item == null:
		return
	_item.data["role"] = role
	editor.on_item_data_changed(_item)

func _on_vec3_changed(key: String, i: int, value: float) -> void:
	if _updating or _item == null:
		return
	var a: Array = _item.data.get(key, [0.0, 0.0, 0.0])
	while a.size() < 3:
		a.append(0.0)
	a[i] = value
	_item.data[key] = a
	editor.on_item_data_changed(_item)

func _on_num_changed(key: String, value: float, is_int: bool) -> void:
	if _updating or _item == null:
		return
	if is_int:
		_item.data[key] = int(round(value))
	else:
		_item.data[key] = value
	editor.on_item_data_changed(_item)

func _on_color_changed(key: String, c: Color) -> void:
	if _updating or _item == null:
		return
	_item.data[key] = [c.r, c.g, c.b]
	editor.on_item_data_changed(_item)

func _clear_color(key: String) -> void:
	if _item == null:
		return
	_item.data.erase(key)
	editor.on_item_data_changed(_item)
	_rebuild_object_tab()

func _set_track_meta(key: String, value) -> void:
	if _updating:
		return
	editor.track_def[key] = value
	editor.on_track_meta_changed()

func _set_laps(v: float) -> void:
	if _updating:
		return
	editor.track_def["laps_to_win"] = int(round(v))
	editor.on_track_meta_changed()

# ---------------------------------------------------------------------------
# Widget builders

func _add_header(text: String) -> void:
	_header_into(_obj_box, text)

func _header_into(box: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.45, 0.56, 0.68))
	box.add_child(l)

func _add_text_row(label: String, value: String, on_change: Callable) -> void:
	_text_into_row(_labeled_row(_obj_box, label), value, on_change)

func _text_into(box: VBoxContainer, label: String, on_change: Callable) -> LineEdit:
	return _text_into_row(_labeled_row(box, label), "", on_change)

func _text_into_row(row: HBoxContainer, value: String, on_change: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.text = value
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text_changed.connect(on_change)
	row.add_child(le)
	return le

func _add_vec3_row(label: String, key: String, step: float) -> void:
	var row := _labeled_row(_obj_box, label)
	var v = _item.data.get(key, [0.0, 0.0, 0.0])
	var arr := []
	for i in 3:
		var val := 0.0
		if v is Array and v.size() > i:
			val = float(v[i])
		var sp := _make_spin(val, step, -SPIN_BIG, SPIN_BIG)
		sp.value_changed.connect(func(value): _on_vec3_changed(key, i, value))
		row.add_child(sp)
		arr.append(sp)
	_obj_fields[key] = arr

func _add_num_row(label: String, key: String, minv: float, maxv: float, step: float, is_int: bool, default: float = 0.0) -> void:
	var row := _labeled_row(_obj_box, label)
	var cur := float(_item.data.get(key, default))
	var sp := _make_spin(cur, step, minv, maxv)
	sp.value_changed.connect(func(v): _on_num_changed(key, v, is_int))
	row.add_child(sp)
	_num_fields[key] = sp

func _add_bool_row(label: String, value: bool, on_change: Callable) -> void:
	var row := _labeled_row(_obj_box, label)
	var cb := CheckBox.new()
	cb.button_pressed = value
	cb.toggled.connect(func(on): on_change.call(on))
	row.add_child(cb)

func _add_color_row(label: String, key: String) -> void:
	var row := _labeled_row(_obj_box, label)
	var cpb := ColorPickerButton.new()
	cpb.edit_alpha = false
	cpb.custom_minimum_size = Vector2(60, 28)
	cpb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var c = _item.data.get(key, null)
	if c is Array and c.size() >= 3:
		cpb.color = Color(float(c[0]), float(c[1]), float(c[2]))
	else:
		cpb.color = _item._default_color()
	cpb.color_changed.connect(func(col): _on_color_changed(key, col))
	row.add_child(cpb)

	var reset := Button.new()
	reset.text = "↺"
	reset.tooltip_text = tr("ed_color_reset_tip")
	reset.pressed.connect(func(): _clear_color(key))
	row.add_child(reset)

func _labeled_row(box: VBoxContainer, label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = LABEL_W
	l.add_theme_color_override("font_color", Color(0.78, 0.83, 0.9))
	row.add_child(l)
	box.add_child(row)
	return row

func _make_spin(value: float, step: float, minv: float, maxv: float) -> SpinBox:
	var s := SpinBox.new()
	s.step = step
	s.min_value = minv
	s.max_value = maxv
	s.allow_greater = true
	s.allow_lesser = true
	s.value = value
	s.custom_minimum_size.x = 64
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.select_all_on_focus = true
	return s

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.125, 0.15, 0.99)
	sb.border_color = Color(0.18, 0.2, 0.24)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb

func _clear(container: Node) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()
