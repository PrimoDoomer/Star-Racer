extends Node3D

## One track primitive inside the editor.
##
## Owns its `data` Dictionary (the exact shape stored in the track JSON) and
## rebuilds a local-space visual matching the in-game look — reusing the mesh
## builders from scripts/track_loader.gd so the editor and the game never drift.
## A box collider on PICK_LAYER gives mouse picking; the node's own transform
## carries position/rotation so a gizmo can attach to it directly.

class_name EditorItem

const PICK_LAYER := 1 << 19  # collision bit 20, reserved for editor picking
const SELECT_COLOR := Color(1.0, 0.82, 0.25)

var data: Dictionary = {}

var _selected := false
var _visual: Node3D = null
var _pick: StaticBody3D = null
var _outline: MeshInstance3D = null

func setup(prim: Dictionary) -> void:
	data = prim
	rebuild()

func get_type() -> String:
	return String(data.get("type", "wall"))

func get_size() -> Vector3:
	return _arr_v3(data.get("size", null), Vector3.ONE)

func supports_scale() -> bool:
	return true

func _arr_v3(a, def: Vector3) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return def

## Push the node transform back into the data dict (after a gizmo move/rotate).
func sync_transform_to_data() -> void:
	data["position"] = [position.x, position.y, position.z]
	data["rotation_deg"] = [rotation_degrees.x, rotation_degrees.y, rotation_degrees.z]

## Recreate everything from `data`. Cheap enough to call on each edit.
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
# Visuals

func _build_visual() -> Node3D:
	var holder := Node3D.new()
	holder.name = "Visual"
	match get_type():
		"pad":
			_build_pad_visual(holder)
		"curve":
			holder.add_child(_curve_mesh_instance())
		_:
			holder.add_child(_box_mesh_instance())
	return holder

func _box_mesh_instance() -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = get_size()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _flat_material(_color())
	return mi

func _curve_mesh_instance() -> MeshInstance3D:
	var s := get_size()
	var seg := int(data.get("segments", TrackLoader.CURVE_DEFAULT_SEGMENTS))
	if seg < 1:
		seg = 1
	var mi := MeshInstance3D.new()
	mi.mesh = TrackLoader._build_curve_mesh(s.x, s.y, s.z, seg)
	var mat := _flat_material(_color())
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	return mi

## Mirrors TrackLoader._make_pad's local visual (cushion + forward chevrons).
func _build_pad_visual(holder: Node3D) -> void:
	var size := get_size()
	var heading := _arr_v3(data.get("heading", null), Vector3(0.0, 0.0, -1.0))

	# No hardcoded vertical offset: the cushion renders at the pad's own origin so
	# the editor is WYSIWYG (matches track_loader.gd).
	var visual := Node3D.new()
	visual.rotation.y = atan2(heading.x, heading.z)
	holder.add_child(visual)

	var width := size.x
	var length := size.z
	var cushion_h := 0.05

	var pad_mat := _flat_material(TrackLoader.PAD_CUSHION_COLOR)
	pad_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cushion := MeshInstance3D.new()
	var corner_r: float = minf(minf(width, length) * 0.5, 1.5)
	cushion.mesh = TrackLoader._build_cushion_mesh(width, length, cushion_h, corner_r)
	cushion.set_surface_override_material(0, pad_mat)
	visual.add_child(cushion)

	var chev_mat := StandardMaterial3D.new()
	chev_mat.albedo_color = TrackLoader.PAD_CHEVRON_COLOR
	chev_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	chev_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var chev_mesh := TrackLoader._build_chevron_mesh(width * 0.62, length * 0.18, width * 0.10)
	for f in [-0.30, 0.0, 0.30]:
		var chev := MeshInstance3D.new()
		chev.mesh = chev_mesh
		chev.set_surface_override_material(0, chev_mat)
		chev.position = Vector3(0.0, cushion_h + 0.012, f * length)
		visual.add_child(chev)

func _flat_material(col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.85
	mat.metallic = 0.05
	return mat

func _color() -> Color:
	var c = data.get("color", null)
	if c is Array and c.size() >= 3:
		return Color(float(c[0]), float(c[1]), float(c[2]))
	return _default_color()

func _default_color() -> Color:
	match get_type():
		"floor": return TrackLoader.FLOOR_DEFAULT_COLOR
		"wall": return TrackLoader.WALL_DEFAULT_COLOR
		"hazard": return TrackLoader.HAZARD_DEFAULT_COLOR
		"curve": return TrackLoader.FLOOR_DEFAULT_COLOR
		_: return Color(0.5, 0.5, 0.5)

# ---------------------------------------------------------------------------
# Picking collider + selection outline

## Local-space axis-aligned bounding box {center, size}. Curves are not centred:
## their mesh spans X:[-w/2,w/2], Y:[0,h], Z:[0,len].
func _bbox() -> Dictionary:
	var s := get_size()
	var safe := Vector3(maxf(s.x, 0.1), maxf(s.y, 0.1), maxf(s.z, 0.1))
	if get_type() == "curve":
		return {"center": Vector3(0.0, s.y * 0.5, s.z * 0.5), "size": safe}
	return {"center": Vector3.ZERO, "size": safe}

func _build_pick() -> StaticBody3D:
	var bb := _bbox()
	var body := StaticBody3D.new()
	body.name = "Pick"
	body.collision_layer = PICK_LAYER
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = bb.size
	cs.shape = shape
	cs.position = bb.center
	body.add_child(cs)
	return body

func _build_outline() -> MeshInstance3D:
	var bb := _bbox()
	var c: Vector3 = bb.center
	var h: Vector3 = bb.size * 0.503  # hug the box, just proud of the surface
	var s := [-1.0, 1.0]
	var corners := []
	for sx in s:
		for sy in s:
			for sz in s:
				corners.append(c + Vector3(sx * h.x, sy * h.y, sz * h.z))
	# 12 edges as index pairs into the 8 corners (order: x,y,z bits).
	var edges := [
		[0, 1], [2, 3], [4, 5], [6, 7],  # along Z
		[0, 2], [1, 3], [4, 6], [5, 7],  # along Y
		[0, 4], [1, 5], [2, 6], [3, 7],  # along X
	]
	var verts := PackedVector3Array()
	for e in edges:
		verts.append(corners[e[0]])
		verts.append(corners[e[1]])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = SELECT_COLOR
	mat.no_depth_test = true  # selection box always visible through geometry
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.name = "Outline"
	mi.mesh = mesh
	return mi
