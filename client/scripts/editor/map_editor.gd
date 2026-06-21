extends Node

## In-game map editor for Pocket Racing.
##
## Produces the same track JSON the server (server/src/track.rs) and the client
## (scripts/track_loader.gd) consume, so circuits authored here are directly
## playable. The scene is built almost entirely in code (matching the project's
## settings-panel approach in ui.gd) so editor.tscn stays a thin entry point.
##
## The track is a set of physical `primitives` (floor/wall/pad/hazard/curve) plus
## race `gates` ("portails": start / finish / start_finish / checkpoint). Both are
## selectable EditorItem / EditorGate objects manipulated by the same gizmo.

const MAIN_SCENE := "res://scenes/game.tscn"

# Shared visual accent with the rest of the UI (see ui.gd).
const ACCENT := Color(0.45, 0.56, 0.68)

var camera: EditorCamera = null
var world: Node3D = null
var items_root: Node3D = null

var _ui_root: Control = null
var _title_label: Label = null
var _hints_label: Label = null
var _status_label: Label = null
var _inspector: MapInspector = null
var _gizmo: TransformGizmo = null
var _gizmo_dragging := false
var _mode_buttons := {}          # TransformGizmo.Mode -> Button

var _open_dialog: FileDialog = null
var _save_dialog: FileDialog = null
var _dirty := false

const UNDO_CAP := 50
var _undo_stack: Array = []
var _redo_stack: Array = []

# Authoritative model. Each entry of track_def["primitives"]/["gates"] is the very
# same Dictionary held by its EditorItem/EditorGate, so saving = serialise track_def.
var track_def: Dictionary = {}
var items: Array = []            # EditorItem (primitives)
var gates: Array = []            # EditorGate (race markers)
var selected = null              # EditorItem or EditorGate
var _name_counters: Dictionary = {}

# Default spec used when adding each primitive type (placed at the camera pivot).
const ADD_SPECS := {
	"floor":  {"size": [40.0, 1.0, 40.0],  "y": -0.5},
	"wall":   {"size": [10.0, 5.0, 10.0],  "y": 2.5},
	"pad":    {"size": [8.0, 2.0, 8.0],    "y": 0.0, "heading": [0.0, 0.0, -1.0]},
	"hazard": {"size": [8.0, 3.0, 8.0],    "y": 1.5},
	"curve":  {"size": [10.0, 3.0, 8.0],   "y": 0.0, "segments": 12},
	"arc":    {"size": [12.0, 1.0, 40.0],  "y": 0.0, "segments": 8, "sweep_deg": 45.0},
	"decor":  {"size": [6.0, 8.0, 6.0],    "y": 4.0, "model": "star_pillar"},
}
const GATE_ADD_HALF := 20.0

func _ready() -> void:
	_build_world()
	_build_ui()
	_new_track()
	_set_status("Éditeur prêt — clic gauche : sélectionner · Suppr : effacer · Ctrl+D : dupliquer · F : recadrer.")

# ---------------------------------------------------------------------------
# 3D world

func _build_world() -> void:
	world = Node3D.new()
	world.name = "World"
	add_child(world)

	world.add_child(_build_environment())

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(40.0), 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	world.add_child(sun)

	world.add_child(_build_grid())

	items_root = Node3D.new()
	items_root.name = "Items"
	world.add_child(items_root)

	camera = EditorCamera.new()
	camera.name = "EditorCamera"
	world.add_child(camera)

	_gizmo = TransformGizmo.new()
	_gizmo.name = "Gizmo"
	world.add_child(_gizmo)
	_gizmo.setup(camera, self)

func _build_environment() -> WorldEnvironment:
	var wenv := WorldEnvironment.new()
	wenv.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.10)
	env.ambient_light_color = Color(0.70, 0.76, 0.88)
	env.ambient_light_energy = 0.45
	wenv.environment = env
	return wenv

## Ground reference grid on the XZ plane, with highlighted X (red) and Z (blue)
## world axes. Drawn as a single unshaded vertex-coloured line mesh.
func _build_grid() -> MeshInstance3D:
	var half := 250.0
	var step := 10.0
	var minor := Color(0.22, 0.24, 0.28)
	var verts := PackedVector3Array()
	var cols := PackedColorArray()

	var p := -half
	while p <= half + 0.001:
		verts.append(Vector3(p, 0.0, -half)); verts.append(Vector3(p, 0.0, half))
		cols.append(minor); cols.append(minor)
		verts.append(Vector3(-half, 0.0, p)); verts.append(Vector3(half, 0.0, p))
		cols.append(minor); cols.append(minor)
		p += step

	verts.append(Vector3(-half, 0.02, 0.0)); verts.append(Vector3(half, 0.02, 0.0))
	cols.append(Color(0.78, 0.32, 0.32)); cols.append(Color(0.78, 0.32, 0.32))
	verts.append(Vector3(0.0, 0.02, -half)); verts.append(Vector3(0.0, 0.02, half))
	cols.append(Color(0.35, 0.52, 0.92)); cols.append(Color(0.35, 0.52, 0.92))

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.55)
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.name = "Grid"
	mi.mesh = mesh
	return mi

# ---------------------------------------------------------------------------
# UI chrome

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)

	_ui_root = Control.new()
	_ui_root.name = "UIRoot"
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE  # let clicks fall through to the 3D view
	_ui_root.theme = load("res://styles/main_theme.tres")
	layer.add_child(_ui_root)

	_build_top_bar()
	_build_left_palette()
	_build_status_bar()
	_build_view_widget()

	# Right-hand inspector.
	_inspector = MapInspector.new()
	_inspector.name = "Inspector"
	_ui_root.add_child(_inspector)
	_inspector.setup(self)

	_build_file_dialogs()

func _build_file_dialogs() -> void:
	_open_dialog = FileDialog.new()
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.use_native_dialog = false
	_open_dialog.filters = PackedStringArray(["*.json ; Circuit JSON"])
	_open_dialog.title = "Ouvrir un circuit"
	_open_dialog.size = Vector2i(720, 480)
	_open_dialog.file_selected.connect(_load_from_path)
	_ui_root.add_child(_open_dialog)

	_save_dialog = FileDialog.new()
	_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.use_native_dialog = false
	_save_dialog.filters = PackedStringArray(["*.json ; Circuit JSON"])
	_save_dialog.title = "Enregistrer le circuit"
	_save_dialog.size = Vector2i(720, 480)
	_save_dialog.file_selected.connect(_save_to_path)
	_ui_root.add_child(_save_dialog)

func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "TopBar"
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.add_theme_stylebox_override("panel", _bar_stylebox())
	_ui_root.add_child(bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	bar.add_child(row)

	_title_label = Label.new()
	_title_label.text = "ÉDITEUR"
	_title_label.add_theme_font_size_override("font_size", 18)
	_title_label.add_theme_color_override("font_color", ACCENT)
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_title_label)

	row.add_child(_vsep())
	for spec in [["Nouveau", _on_new], ["Ouvrir", _on_open], ["Enregistrer", _on_save]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		row.add_child(b)

	row.add_child(_vsep())
	var validate_btn := Button.new()
	validate_btn.text = "Valider"
	validate_btn.tooltip_text = "Vérifier que le circuit a un départ et une arrivée"
	validate_btn.pressed.connect(_on_validate)
	row.add_child(validate_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var snap_btn := CheckButton.new()
	snap_btn.text = "Snap"
	snap_btn.tooltip_text = "Aligner sur la grille (maintenir Ctrl pour inverser)"
	snap_btn.toggled.connect(func(on): _gizmo.snap_enabled = on)
	row.add_child(snap_btn)

	row.add_child(_vsep())
	var back := Button.new()
	back.text = "Menu"
	back.tooltip_text = "Retour au menu principal"
	back.pressed.connect(_on_back_pressed)
	row.add_child(back)

func _build_left_palette() -> void:
	var panel := PanelContainer.new()
	panel.name = "Palette"
	panel.add_theme_stylebox_override("panel", _panel_stylebox())
	panel.offset_left = 12.0
	panel.offset_top = 60.0
	panel.custom_minimum_size = Vector2(152, 0)
	_ui_root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	box.add_child(_section_label("AJOUTER"))
	for t in ["floor", "wall", "pad", "hazard", "curve", "arc", "decor"]:
		var b := Button.new()
		b.text = _type_label(t)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_add_primitive.bind(t))
		box.add_child(b)

	box.add_child(HSeparator.new())
	box.add_child(_section_label("PORTAIL"))
	for spec in [["start", "Départ"], ["finish", "Arrivée"], ["start_finish", "Départ/Arrivée"], ["checkpoint", "Checkpoint"]]:
		var gb := Button.new()
		gb.text = spec[1]
		gb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		gb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var role: String = spec[0]
		gb.pressed.connect(func(): _add_gate(role))
		box.add_child(gb)

	box.add_child(HSeparator.new())
	box.add_child(_section_label("OUTIL"))
	var mode_group := ButtonGroup.new()
	for spec in [
		[TransformGizmo.Mode.TRANSLATE, "Déplacer (W)"],
		[TransformGizmo.Mode.ROTATE, "Tourner (E)"],
		[TransformGizmo.Mode.SCALE, "Échelle (R)"],
	]:
		var mb := Button.new()
		mb.text = spec[1]
		mb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		mb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mb.toggle_mode = true
		mb.button_group = mode_group
		var m: int = spec[0]
		mb.pressed.connect(func(): _set_gizmo_mode(m))
		box.add_child(mb)
		_mode_buttons[m] = mb
	_mode_buttons[TransformGizmo.Mode.TRANSLATE].button_pressed = true

func _build_status_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "StatusBar"
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.add_theme_stylebox_override("panel", _bar_stylebox())
	_ui_root.add_child(bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	bar.add_child(row)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_status_label)

	_hints_label = Label.new()
	_hints_label.text = "Clic droit : orbiter · molette : zoom · clic milieu : déplacer · F : recadrer"
	_hints_label.add_theme_font_size_override("font_size", 12)
	_hints_label.add_theme_color_override("font_color", Color(0.52, 0.57, 0.66))
	row.add_child(_hints_label)

## Godot-style view widget (bottom-left): snap the camera to axis-aligned views.
func _build_view_widget() -> void:
	var panel := PanelContainer.new()
	panel.name = "ViewWidget"
	panel.add_theme_stylebox_override("panel", _panel_stylebox())
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = 12.0
	panel.offset_top = -100.0
	panel.offset_bottom = -52.0
	_ui_root.add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	panel.add_child(row)

	var l := _section_label("VUE")
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)

	for spec in [
		["top", "Dessus", "Vue de dessus (Y) — pavé num. 7"],
		["front", "Face", "Vue de face (Z) — pavé num. 1"],
		["right", "Côté", "Vue de côté (X) — pavé num. 3"],
		["persp", "3D", "Vue perspective — pavé num. 5"],
	]:
		var b := Button.new()
		b.text = spec[1]
		b.tooltip_text = spec[2]
		var view: String = spec[0]
		b.pressed.connect(func(): camera.set_axis_view(view))
		row.add_child(b)

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", ACCENT)
	return l

# Full-width top/bottom strip: subtle, only horizontal borders.
func _bar_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.115, 0.14, 0.97)
	sb.border_color = Color(0.18, 0.2, 0.24)
	sb.border_width_bottom = 1
	sb.border_width_top = 1
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb

# Rounded floating panel, matching the game's settings panel (see ui.gd).
func _panel_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.125, 0.15, 0.99)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.18, 0.2, 0.24)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	return sb

func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text
		_status_label.add_theme_color_override("font_color", Color(0.82, 0.87, 0.93))

func _vsep() -> VSeparator:
	return VSeparator.new()

func _type_label(t: String) -> String:
	match t:
		"floor": return "Sol"
		"wall": return "Mur"
		"pad": return "Boost"
		"hazard": return "Danger"
		"curve": return "Rampe"
	return t

# ---------------------------------------------------------------------------
# Track lifecycle

func _new_track() -> void:
	track_def = MapIO.template()
	_undo_stack.clear()
	_redo_stack.clear()
	_rebuild_items()
	_seed_counters()
	if _inspector:
		_inspector.refresh_circuit()
	_dirty = false
	_update_title()

## Drop every editor object and re-instance from track_def (primitives + gates).
func _rebuild_items() -> void:
	_select(null)
	for it in items:
		it.free()
	for g in gates:
		g.free()
	items.clear()
	gates.clear()
	_name_counters.clear()
	for prim in track_def.get("primitives", []):
		_instance_item(prim)
	for g in track_def.get("gates", []):
		_instance_gate(g)

func _instance_item(prim: Dictionary) -> EditorItem:
	var item := EditorItem.new()
	items_root.add_child(item)
	item.setup(prim)
	items.append(item)
	return item

func _instance_gate(g: Dictionary) -> EditorGate:
	var gate := EditorGate.new()
	items_root.add_child(gate)
	gate.setup(g)
	gates.append(gate)
	return gate

# ---------------------------------------------------------------------------
# Add / select / delete / duplicate

func _add_primitive(type: String) -> void:
	_push_undo()
	var spec: Dictionary = ADD_SPECS[type]
	var pivot: Vector3 = camera.pivot
	var prim := {
		"type": type,
		"name": _next_name(type),
		"size": (spec["size"] as Array).duplicate(),
		"position": [snappedf(pivot.x, 1.0), spec["y"], snappedf(pivot.z, 1.0)],
		"rotation_deg": [0.0, 0.0, 0.0],
	}
	if spec.has("heading"):
		prim["heading"] = (spec["heading"] as Array).duplicate()
		prim["boost_strength"] = 20.0
	if spec.has("segments"):
		prim["segments"] = spec["segments"]
	if spec.has("sweep_deg"):
		prim["sweep_deg"] = spec["sweep_deg"]
	if spec.has("model"):
		prim["model"] = spec["model"]
	if spec.has("collide"):
		prim["collide"] = spec["collide"]
	track_def["primitives"].append(prim)
	_select(_instance_item(prim))
	_set_status("Ajouté : %s" % prim["name"])

func _add_gate(role: String) -> void:
	_push_undo()
	var pivot: Vector3 = camera.pivot
	var g := {
		"role": role,
		"position": [snappedf(pivot.x, 1.0), 2.0, snappedf(pivot.z, 1.0)],
		"rotation_deg": [0.0, 0.0, 0.0],
		"half_width": GATE_ADD_HALF,
	}
	track_def["gates"].append(g)
	_select(_instance_gate(g))
	_set_status("Portail ajouté : %s" % role)

func _select(obj) -> void:
	if selected == obj:
		return
	if selected:
		selected.set_selected(false)
	selected = obj
	if selected:
		selected.set_selected(true)
		_set_status("Sélection : %s" % _obj_label(selected))
	if _inspector:
		_inspector.set_item(selected)
	if _gizmo:
		_gizmo.set_target(selected)

func _obj_label(obj) -> String:
	if obj is EditorGate:
		return "portail (%s)" % obj.get_role()
	return "%s (%s)" % [obj.data.get("name", "?"), obj.get_type()]

func _set_gizmo_mode(m: int) -> void:
	if _gizmo:
		_gizmo.set_mode(m)
	if _mode_buttons.has(m):
		_mode_buttons[m].button_pressed = true

# Called by the inspector when an object's field changes: rebuild its visuals.
func on_item_data_changed(obj) -> void:
	obj.rebuild()
	if _gizmo and selected == obj:
		_gizmo.refresh()
	_mark_dirty()

# Called by the gizmo on each drag step: rebuild visuals + sync inspector fields.
func notify_transform_from_gizmo(obj) -> void:
	obj.rebuild()
	if _inspector:
		_inspector.refresh_selected_transform()

# Called by the gizmo when a drag ends.
func commit_after_gizmo() -> void:
	pass

# Called by the inspector when track-level fields (id/name/laps) change.
func on_track_meta_changed() -> void:
	_mark_dirty()

func _delete_selected() -> void:
	if selected == null:
		return
	_push_undo()
	var victim = selected
	_select(null)
	if victim is EditorGate:
		track_def["gates"].erase(victim.data)
		gates.erase(victim)
	else:
		track_def["primitives"].erase(victim.data)
		items.erase(victim)
	victim.free()
	_set_status("Supprimé.")

func _duplicate_selected() -> void:
	if selected == null:
		return
	_push_undo()
	var clone: Dictionary = selected.data.duplicate(true)
	var pos: Array = clone.get("position", [0.0, 0.0, 0.0])
	pos[0] = float(pos[0]) + 5.0
	pos[2] = float(pos[2]) + 5.0
	clone["position"] = pos
	if selected is EditorGate:
		track_def["gates"].append(clone)
		_select(_instance_gate(clone))
		_set_status("Portail dupliqué.")
	else:
		clone["name"] = _next_name(selected.get_type())
		track_def["primitives"].append(clone)
		_select(_instance_item(clone))
		_set_status("Dupliqué : %s" % clone["name"])

func _next_name(type: String) -> String:
	var n := int(_name_counters.get(type, 0)) + 1
	_name_counters[type] = n
	return "%s_%d" % [type, n]

# ---------------------------------------------------------------------------
# Input: picking + shortcuts

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _gizmo and _gizmo.try_begin_drag(get_viewport().get_mouse_position()):
				_push_undo()
				_gizmo_dragging = true
			else:
				_try_pick()
		elif _gizmo_dragging:
			_gizmo.end_drag()
			_gizmo_dragging = false
	elif event is InputEventMouseMotion and _gizmo_dragging:
		_gizmo.update_drag(get_viewport().get_mouse_position())
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.ctrl_pressed and event.keycode == KEY_S:
			_on_save()
		elif event.ctrl_pressed and event.keycode == KEY_Z and event.shift_pressed:
			_redo()
		elif event.ctrl_pressed and event.keycode == KEY_Z:
			_undo()
		elif event.ctrl_pressed and event.keycode == KEY_Y:
			_redo()
		elif event.ctrl_pressed and event.keycode == KEY_D:
			_duplicate_selected()
		elif event.keycode == KEY_DELETE:
			_delete_selected()
		elif event.keycode == KEY_F and selected:
			camera.focus_on(selected.global_position)
		elif event.keycode == KEY_W:
			_set_gizmo_mode(TransformGizmo.Mode.TRANSLATE)
		elif event.keycode == KEY_E:
			_set_gizmo_mode(TransformGizmo.Mode.ROTATE)
		elif event.keycode == KEY_R:
			_set_gizmo_mode(TransformGizmo.Mode.SCALE)
		elif event.keycode == KEY_KP_7:
			camera.set_axis_view("top")
		elif event.keycode == KEY_KP_1:
			camera.set_axis_view("front")
		elif event.keycode == KEY_KP_3:
			camera.set_axis_view("right")
		elif event.keycode == KEY_KP_5:
			camera.set_axis_view("persp")

func _try_pick() -> void:
	var mpos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mpos)
	var to := from + camera.project_ray_normal(mpos) * 3000.0
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = EditorItem.PICK_LAYER
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		_select(null)
		return
	var node: Node = hit.collider
	while node != null and not (node is EditorItem) and not (node is EditorGate):
		node = node.get_parent()
	_select(node)

# ---------------------------------------------------------------------------
# File operations

func _on_new() -> void:
	_new_track()
	_set_status("Nouveau circuit.")

func _on_open() -> void:
	_open_dialog.current_dir = _default_tracks_dir()
	_open_dialog.popup_centered()

func _on_save() -> void:
	_save_dialog.current_dir = _default_tracks_dir()
	_save_dialog.current_file = String(track_def.get("id", "track")) + ".json"
	_save_dialog.popup_centered()

func _on_validate() -> void:
	var err := MapIO.validate(track_def)
	if err == "":
		_set_status("✓ Circuit valide.")
		if _status_label:
			_status_label.add_theme_color_override("font_color", Color(0.45, 0.85, 0.5))
	else:
		_set_status("✗ " + err)
		if _status_label:
			_status_label.add_theme_color_override("font_color", Color(0.96, 0.55, 0.45))

func _save_to_path(path: String) -> void:
	var err := MapIO.validate(track_def)
	if err != "":
		_set_status("Sauvegarde refusée : " + err)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_set_status("Impossible d'écrire : %s" % path)
		return
	f.store_string(MapIO.to_json(track_def))
	f.close()
	_dirty = false
	_update_title()
	_set_status("Enregistré : %s" % path)

func _load_from_path(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_set_status("Lecture impossible : %s" % path)
		return
	var data = MapIO.parse(f.get_as_text())
	f.close()
	if data == null:
		_set_status("JSON invalide : %s" % path)
		return
	track_def = MapIO.import_track(data)
	_undo_stack.clear()
	_redo_stack.clear()
	_rebuild_items()
	_seed_counters()
	if _inspector:
		_inspector.refresh_circuit()
	_dirty = false
	_update_title()
	_set_status("Chargé : %s (%d primitives, %d portails)" % [path, track_def["primitives"].size(), track_def["gates"].size()])

## Default to the repo's server/tracks so circuits save straight where the
## server loads them; fall back to user:// in an exported build.
func _default_tracks_dir() -> String:
	var server_tracks := ProjectSettings.globalize_path("res://").path_join("../server/tracks").simplify_path()
	if DirAccess.dir_exists_absolute(server_tracks):
		return server_tracks
	return ProjectSettings.globalize_path("user://")

## Seed per-type name counters from loaded primitives so new names don't collide.
func _seed_counters() -> void:
	_name_counters.clear()
	for prim in track_def.get("primitives", []):
		var parts := String(prim.get("name", "")).rsplit("_", true, 1)
		if parts.size() == 2 and parts[1].is_valid_int():
			_name_counters[parts[0]] = maxi(int(_name_counters.get(parts[0], 0)), int(parts[1]))

# ---------------------------------------------------------------------------
# Undo / redo (whole-track snapshots)

func _push_undo() -> void:
	_undo_stack.append(track_def.duplicate(true))
	if _undo_stack.size() > UNDO_CAP:
		_undo_stack.pop_front()
	_redo_stack.clear()
	_mark_dirty()

func _undo() -> void:
	if _undo_stack.is_empty():
		_set_status("Rien à annuler.")
		return
	_redo_stack.append(track_def.duplicate(true))
	_restore(_undo_stack.pop_back())
	_set_status("Annulé.")

func _redo() -> void:
	if _redo_stack.is_empty():
		_set_status("Rien à refaire.")
		return
	_undo_stack.append(track_def.duplicate(true))
	_restore(_redo_stack.pop_back())
	_set_status("Refait.")

func _restore(snapshot: Dictionary) -> void:
	track_def = snapshot
	_rebuild_items()
	_seed_counters()
	if _inspector:
		_inspector.refresh_circuit()
	_update_title()

func _mark_dirty() -> void:
	_dirty = true
	_update_title()

func _update_title() -> void:
	if _title_label:
		_title_label.text = "ÉDITEUR — %s%s" % [String(track_def.get("name", "?")), " *" if _dirty else ""]

# ---------------------------------------------------------------------------
# Navigation

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)
