extends Node3D

## A race "portail" (gate) in the editor: start / finish / start_finish / checkpoint.
## Mirrors EditorItem's interface (data, setup, rebuild, get_size, set_selected,
## sync_transform_to_data, supports_scale) so the gizmo and selection code handle
## both via duck typing. The forward normal is local -Z (the car's facing);
## `half_width` spans the local X tangent — matching server/src/track.rs Gate.

class_name EditorGate

const GATE_H := 6.0
const GATE_THICK := 0.4
const SELECT_COLOR := Color(1.0, 0.82, 0.25)

const ROLE_INFO := {
	"start":        { "col": Color(1.0, 0.62, 0.18), "label": "DÉPART" },
	"finish":       { "col": Color(0.32, 0.90, 0.42), "label": "ARRIVÉE" },
	"start_finish": { "col": Color(0.30, 0.92, 0.82), "label": "DÉPART/ARRIVÉE" },
	"checkpoint":   { "col": Color(0.38, 0.62, 0.96), "label": "CHECKPOINT" },
}

var data: Dictionary = {}
var _selected := false
var _visual: Node3D = null
var _pick: StaticBody3D = null
var _outline: MeshInstance3D = null

func setup(d: Dictionary) -> void:
	data = d
	rebuild()

func get_type() -> String:
	return "gate"

func get_role() -> String:
	return String(data.get("role", "checkpoint"))

func get_half_width() -> float:
	return maxf(float(data.get("half_width", 10.0)), 0.5)

func get_size() -> Vector3:
	return Vector3(get_half_width() * 2.0, GATE_H, 1.0)

func supports_scale() -> bool:
	return false

func sync_transform_to_data() -> void:
	data["position"] = [position.x, position.y, position.z]
	data["rotation_deg"] = [rotation_degrees.x, rotation_degrees.y, rotation_degrees.z]

func rebuild() -> void:
	position = _arr_v3(data.get("position", null), Vector3.ZERO)
	rotation_degrees = _arr_v3(data.get("rotation_deg", null), Vector3.ZERO)

	if _visual: _visual.free()
	if _pick: _pick.free()
	if _outline: _outline.free()

	_visual = _build_visual()
	add_child(_visual)
	_pick = _build_pick()
	add_child(_pick)
	_outline = _build_outline()
	add_child(_outline)
	_outline.visible = _selected

func set_selected(on: bool) -> void:
	_selected = on
	if _outline:
		_outline.visible = on

# ---------------------------------------------------------------------------

func _role_color() -> Color:
	return ROLE_INFO.get(get_role(), ROLE_INFO["checkpoint"])["col"]

func _role_label() -> String:
	return ROLE_INFO.get(get_role(), ROLE_INFO["checkpoint"])["label"]

func _build_visual() -> Node3D:
	var holder := Node3D.new()
	holder.name = "Visual"
	var col := _role_color()
	var hw := get_half_width()
	var hh := GATE_H * 0.5

	# Faint translucent banner spanning the tangent (X) and height (Y).
	var panel := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(hw * 2.0, GATE_H, GATE_THICK)
	panel.mesh = bm
	panel.material_override = _unshaded(col, 0.14)
	holder.add_child(panel)

	# Bright outline of the gate face (local XY plane at z=0).
	holder.add_child(_line_strip(PackedVector3Array([
		Vector3(-hw, -hh, 0.0), Vector3(hw, -hh, 0.0), Vector3(hw, hh, 0.0),
		Vector3(-hw, hh, 0.0), Vector3(-hw, -hh, 0.0),
	]), col))

	# Forward arrow (crossing direction = local -Z).
	holder.add_child(_line_strip(PackedVector3Array([Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, -3.0)]), col))
	var cone := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = 0.7
	cm.height = 1.6
	cone.mesh = cm
	cone.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	cone.position = Vector3(0.0, 0.0, -3.4)
	cone.material_override = _unshaded(col, 1.0)
	holder.add_child(cone)

	holder.add_child(_label3d(_role_label(), col, Vector3(0.0, hh + 1.6, 0.0)))
	return holder

func _build_pick() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Pick"
	body.collision_layer = EditorItem.PICK_LAYER
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(get_half_width() * 2.0, GATE_H, maxf(GATE_THICK, 1.5))
	cs.shape = shape
	body.add_child(cs)
	return body

func _build_outline() -> MeshInstance3D:
	var hw := get_half_width()
	var hh := GATE_H * 0.5
	var hz := maxf(GATE_THICK, 1.5) * 0.5
	var s := [-1.0, 1.0]
	var corners := []
	for sx in s:
		for sy in s:
			for sz in s:
				corners.append(Vector3(sx * hw, sy * hh, sz * hz))
	var edges := [
		[0, 1], [2, 3], [4, 5], [6, 7],
		[0, 2], [1, 3], [4, 6], [5, 7],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	var verts := PackedVector3Array()
	for e in edges:
		verts.append(corners[e[0]]); verts.append(corners[e[1]])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var mat := _unshaded(SELECT_COLOR, 1.0)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "Outline"
	mi.mesh = mesh
	return mi

func _line_strip(points: PackedVector3Array, col: Color) -> MeshInstance3D:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = points
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arr)
	mesh.surface_set_material(0, _unshaded(col, 1.0))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

func _label3d(text: String, col: Color, pos: Vector3) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.modulate = col
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0006
	l.font_size = 64
	l.outline_size = 16
	l.outline_modulate = Color(0.04, 0.05, 0.07, 0.95)
	l.position = pos
	return l

func _unshaded(col: Color, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(col.r, col.g, col.b, alpha)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	if alpha < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

static func _arr_v3(a, def: Vector3) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return def
