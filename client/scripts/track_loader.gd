extends Node3D

class_name TrackLoader

## Builds a track scene from a JSON track definition (as a Dictionary).
## The definition is the same shape the server sends in the LobbyJoined response.
##
## `parent` is the node under which all primitives are added.
## Returns { "spawn_pos": Vector3, "spawn_y_rotation_deg": float }.

const FLOOR_DEFAULT_COLOR := Color(0.18, 0.20, 0.22)
const WALL_DEFAULT_COLOR  := Color(0.32, 0.35, 0.45)
const PAD_BASE_COLOR      := Color(0.10, 0.30, 0.95)
const HAZARD_DEFAULT_COLOR := Color(0.85, 0.15, 0.15)

const CURVE_SLAB_THICKNESS := 0.3
const CURVE_DEFAULT_SEGMENTS := 12


static func build(parent: Node3D, track_def: Dictionary) -> Dictionary:
	var floor_mat: StandardMaterial3D = load("res://tracks/circuit_one/floor_mat.tres")
	var wall_mat := _make_concrete_mat()

	var primitives: Array = track_def.get("primitives", [])
	for prim in primitives:
		var kind: String = prim.get("type", "")
		match kind:
			"floor":
				_make_static_box(parent, prim, FLOOR_DEFAULT_COLOR, false, floor_mat)
			"wall":
				_make_static_box(parent, prim, WALL_DEFAULT_COLOR, false, wall_mat)
			"hazard":
				_make_static_box(parent, prim, HAZARD_DEFAULT_COLOR, true)
			"pad":
				_make_pad(parent, prim)
			"curve":
				_make_curve(parent, prim, FLOOR_DEFAULT_COLOR, floor_mat)
			_:
				push_warning("TrackLoader: unknown primitive type '%s'" % kind)

	var spawn: Dictionary = track_def.get("spawn", {})
	var sp_arr: Array = spawn.get("position", [0.0, 0.0, 0.0])
	return {
		"spawn_pos": Vector3(float(sp_arr[0]), float(sp_arr[1]), float(sp_arr[2])),
		"spawn_y_rotation_deg": float(spawn.get("y_rotation_deg", 0.0)),
	}


static func _vec3_from_array(arr: Array, default: Vector3 = Vector3.ZERO) -> Vector3:
	if arr.size() < 3:
		return default
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


static func _color_from_array(arr, default: Color) -> Color:
	if arr == null or not arr is Array or arr.size() < 3:
		return default
	return Color(float(arr[0]), float(arr[1]), float(arr[2]))


static func _make_concrete_mat() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.50, 0.55, 0.65, 1.0)
	mat.albedo_texture = load("res://tracks/circuit_one/wall_metal_color.png")
	mat.normal_enabled = true
	mat.normal_texture = load("res://tracks/circuit_one/wall_metal_normal.png")
	mat.roughness_texture = load("res://tracks/circuit_one/wall_metal_roughness.png")
	mat.roughness = 1.0
	mat.metallic = 0.55
	mat.metallic_specular = 0.5
	mat.uv1_scale = Vector3(3.0, 3.0, 3.0)
	return mat


static func _make_static_box(parent: Node3D, prim: Dictionary, default_color: Color, sensor: bool, override_mat: StandardMaterial3D = null) -> void:
	var size := _vec3_from_array(prim.get("size", []))
	var pos  := _vec3_from_array(prim.get("position", []))
	var rot  := _vec3_from_array(prim.get("rotation_deg", []), Vector3.ZERO)
	var color := _color_from_array(prim.get("color", null), default_color)
	var nm: String = prim.get("name", "primitive")

	var body: CollisionObject3D
	if sensor:
		body = Area3D.new()
	else:
		body = StaticBody3D.new()
	body.name = nm
	body.position = pos
	body.rotation_degrees = rot

	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	if override_mat != null:
		mesh.material = override_mat
	else:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.8
		mat.metallic = 0.1
		mesh.material = mat
	mi.mesh = mesh
	body.add_child(mi)

	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)

	parent.add_child(body)


static func _make_pad(parent: Node3D, prim: Dictionary) -> void:
	var size := _vec3_from_array(prim.get("size", []))
	var pos  := _vec3_from_array(prim.get("position", []))
	var heading := _vec3_from_array(prim.get("heading", []), Vector3(0.0, 0.0, -1.0))
	var rot  := _vec3_from_array(prim.get("rotation_deg", []), Vector3.ZERO)
	var nm: String = prim.get("name", "pad")
	# Pads honour an optional "color" for the domed base; default to the blue.
	var base_color := _color_from_array(prim.get("color", null), PAD_BASE_COLOR)

	# rotation_deg orients the whole pad (visual + sensor), matching the oriented
	# collider the server builds — so pads can be tilted onto ramps or banks.
	var root := Node3D.new()
	root.name = nm
	root.position = pos
	root.rotation_degrees = rot
	parent.add_child(root)

	# The chevrons additionally yaw to point along `heading` within the pad frame.
	var visual := Node3D.new()
	visual.position.y = -size.y * 0.5
	visual.rotation.y = atan2(heading.x, heading.z)
	root.add_child(visual)

	# Local pad footprint (chevron-forward axis = local Z).
	var width  := size.x
	var length := size.z
	var slab_h := 0.3

	# Solid, matte base slab sitting flush on the floor. Neutral dark (not the pad
	# colour) so it doesn't read as a big coloured square, matte (metallic 0) so it
	# never picks up coloured environment reflections, and a real box so the pad
	# has thickness.
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = Color(0.09, 0.10, 0.12)
	pad_mat.roughness = 0.85
	pad_mat.metallic  = 0.0
	var slab := MeshInstance3D.new()
	var slab_mesh := BoxMesh.new()
	slab_mesh.size = Vector3(width, slab_h, length)
	slab.mesh = slab_mesh
	slab.position.y = slab_h * 0.5  # bottom edge flush with the floor
	slab.set_surface_override_material(0, pad_mat)
	visual.add_child(slab)

	# Bright chevrons carry the pad's colour (its identity), pointing forward.
	var chev_mat := StandardMaterial3D.new()
	chev_mat.albedo_color = base_color
	chev_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	chev_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var chev_w := width * 0.62
	var chev_l := length * 0.18
	var chev_t := width * 0.10
	var chev_mesh := _build_chevron_mesh(chev_w, chev_l, chev_t)

	var slots := [-0.30, 0.0, 0.30]  # fractions of length
	for i in slots.size():
		var f: float = slots[i]
		var z_off := f * length
		var y_top := slab_h + 0.02  # just above the slab surface
		var chev := MeshInstance3D.new()
		chev.mesh = chev_mesh
		chev.set_surface_override_material(0, chev_mat)
		chev.position = Vector3(0.0, y_top, z_off)
		visual.add_child(chev)

	# Sensor area: full pad volume, inheriting the pad's orientation (matches the
	# server's oriented collider).
	var sensor := Area3D.new()
	sensor.name = "%s_sensor" % nm
	root.add_child(sensor)

	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sensor.add_child(cs)


# Flat chevron `>` shape in the XZ plane, pointing toward +Z.
# `width` = total span along X, `length` = depth along Z, `thickness` = arm width.
static func _build_chevron_mesh(width: float, length: float, thickness: float) -> ArrayMesh:
	var hw := width * 0.5
	var hl := length * 0.5
	# Two parallelogram arms meeting at the tip (0, 0, +hl).
	# Each arm: outer edge from (±hw, 0, -hl) → tip (0, 0, hl).
	# Inner edge offset by `thickness` along arm-normal.
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs   := PackedVector2Array()
	var idx   := PackedInt32Array()

	var up := Vector3.UP

	# Right arm: from base-right (hw, 0, -hl) to tip (0, 0, hl).
	var br := Vector3(hw, 0, -hl)
	var tp := Vector3(0, 0, hl)
	var dir_r := (tp - br).normalized()
	var nrm_r := Vector3(-dir_r.z, 0, dir_r.x).normalized()  # left-of-arm in XZ
	var br_in := br + nrm_r * thickness
	var tp_in_r := tp + nrm_r * thickness

	# Left arm: mirror.
	var bl := Vector3(-hw, 0, -hl)
	var dir_l := (tp - bl).normalized()
	var nrm_l := Vector3(-dir_l.z, 0, dir_l.x).normalized()  # right-of-arm = inward
	var bl_in := bl - nrm_l * thickness   # invert sign so inset goes toward center
	var tp_in_l := tp - nrm_l * thickness

	var base_idx := verts.size()
	verts.append(br); verts.append(br_in); verts.append(tp_in_r); verts.append(tp)
	for k in 4:
		norms.append(up); uvs.append(Vector2(0, 0))
	idx.append(base_idx + 0); idx.append(base_idx + 1); idx.append(base_idx + 2)
	idx.append(base_idx + 0); idx.append(base_idx + 2); idx.append(base_idx + 3)

	base_idx = verts.size()
	verts.append(bl); verts.append(tp); verts.append(tp_in_l); verts.append(bl_in)
	for k in 4:
		norms.append(up); uvs.append(Vector2(0, 0))
	idx.append(base_idx + 0); idx.append(base_idx + 1); idx.append(base_idx + 2)
	idx.append(base_idx + 0); idx.append(base_idx + 2); idx.append(base_idx + 3)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = idx

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


# Curved ramp: quarter-circle cross-section in the local YZ plane.
# Surface goes from (x, 0, 0) at t=0 to (x, height, length) at t=π/2 along
# P(t) = (0, height*(1 - cos t), length*sin t). Width spans local X.
# Server tessellates the same way; keep formulas in sync.
static func _make_curve(parent: Node3D, prim: Dictionary, default_color: Color, override_mat: StandardMaterial3D) -> void:
	var size := _vec3_from_array(prim.get("size", []))
	var pos  := _vec3_from_array(prim.get("position", []))
	var rot  := _vec3_from_array(prim.get("rotation_deg", []), Vector3.ZERO)
	var color := _color_from_array(prim.get("color", null), default_color)
	var nm: String = prim.get("name", "curve")
	var segments: int = int(prim.get("segments", CURVE_DEFAULT_SEGMENTS))
	if segments < 1:
		segments = 1

	var width := size.x
	var height := size.y
	var length := size.z

	var body := StaticBody3D.new()
	body.name = nm
	body.position = pos
	body.rotation_degrees = rot

	var mi := MeshInstance3D.new()
	mi.mesh = _build_curve_mesh(width, height, length, segments)
	if override_mat != null:
		mi.set_surface_override_material(0, override_mat)
	else:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.8
		mat.metallic = 0.1
		mi.set_surface_override_material(0, mat)
	body.add_child(mi)

	for i in segments:
		var t0 := float(i) / float(segments) * (PI * 0.5)
		var t1 := float(i + 1) / float(segments) * (PI * 0.5)
		var z0 := length * sin(t0)
		var y0 := height * (1.0 - cos(t0))
		var z1 := length * sin(t1)
		var y1 := height * (1.0 - cos(t1))
		var dz := z1 - z0
		var dy := y1 - y0
		var chord_len := sqrt(dz * dz + dy * dy)
		if chord_len < 1e-6:
			continue

		var pitch := atan2(-dy, dz)
		var nz := -dy / chord_len
		var ny := dz / chord_len

		var mid_z := 0.5 * (z0 + z1) - nz * (CURVE_SLAB_THICKNESS * 0.5)
		var mid_y := 0.5 * (y0 + y1) - ny * (CURVE_SLAB_THICKNESS * 0.5)

		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(width, CURVE_SLAB_THICKNESS, chord_len)
		cs.shape = box
		cs.position = Vector3(0.0, mid_y, mid_z)
		cs.rotation = Vector3(pitch, 0.0, 0.0)
		body.add_child(cs)

	parent.add_child(body)


static func _build_curve_mesh(width: float, height: float, length: float, segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs   := PackedVector2Array()
	var idx   := PackedInt32Array()

	var hw := width * 0.5
	for i in range(segments + 1):
		var t := float(i) / float(segments) * (PI * 0.5)
		var z := length * sin(t)
		var y := height * (1.0 - cos(t))
		var n := Vector3(0.0, cos(t), -sin(t)).normalized()
		var v := float(i) / float(segments)

		verts.append(Vector3(-hw, y, z))
		norms.append(n)
		uvs.append(Vector2(0.0, v))

		verts.append(Vector3(hw, y, z))
		norms.append(n)
		uvs.append(Vector2(1.0, v))

	for i in range(segments):
		var a := i * 2
		var b := a + 1
		var c := a + 2
		var d := a + 3
		idx.append(a); idx.append(c); idx.append(b)
		idx.append(b); idx.append(c); idx.append(d)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = idx

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am
