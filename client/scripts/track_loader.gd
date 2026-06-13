extends Node3D

class_name TrackLoader

## Builds a track scene from a JSON track definition (as a Dictionary).
## The definition is the same shape the server sends in the LobbyJoined response.
##
## `parent` is the node under which all primitives are added.
## Returns { "spawn_pos": Vector3, "spawn_y_rotation_deg": float }.

const FLOOR_DEFAULT_COLOR := Color(0.18, 0.20, 0.22)
const WALL_DEFAULT_COLOR  := Color(0.32, 0.35, 0.45)
const PAD_CUSHION_COLOR   := Color(0.13, 0.40, 0.92)  # all pads are this blue
const PAD_CHEVRON_COLOR   := Color(0.62, 0.82, 1.0)   # lighter blue arrows on top
const HAZARD_DEFAULT_COLOR := Color(0.85, 0.15, 0.15)

const CURVE_SLAB_THICKNESS := 0.3
const CURVE_DEFAULT_SEGMENTS := 12


static func build(parent: Node3D, track_def: Dictionary) -> Dictionary:
	var floor_mat: StandardMaterial3D = load("res://tracks/circuit_test/floor_mat.tres")
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

	return _spawn_from_gates(track_def)


## Spawn position + heading derived from the start/start_finish gate (matches the
## server's TrackDef::spawn). Falls back to the origin when none is defined.
static func _spawn_from_gates(track_def: Dictionary) -> Dictionary:
	for gate in track_def.get("gates", []):
		var role := String(gate.get("role", ""))
		if role == "start" or role == "start_finish":
			var p: Array = gate.get("position", [0.0, 0.0, 0.0])
			var r: Array = gate.get("rotation_deg", [0.0, 0.0, 0.0])
			return {
				"spawn_pos": Vector3(float(p[0]), float(p[1]), float(p[2])),
				"spawn_y_rotation_deg": float(r[1]) if r.size() > 1 else 0.0,
			}
	return {"spawn_pos": Vector3.ZERO, "spawn_y_rotation_deg": 0.0}


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
	mat.albedo_texture = load("res://tracks/circuit_test/wall_metal_color.png")
	mat.normal_enabled = true
	mat.normal_texture = load("res://tracks/circuit_test/wall_metal_normal.png")
	mat.roughness_texture = load("res://tracks/circuit_test/wall_metal_roughness.png")
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
	var boost_strength: float = float(prim.get("boost_strength", 20.0))

	# rotation_deg orients the whole pad (visual + sensor), matching the oriented
	# collider the server builds — so pads can be tilted onto ramps or banks.
	var root := Node3D.new()
	root.name = nm
	root.position = pos
	root.rotation_degrees = rot
	parent.add_child(root)

	# The cushion sits at the pad's own origin (no hardcoded vertical offset): the
	# level data position is where the pad renders, so the editor is WYSIWYG. The
	# chevrons additionally yaw to point along `heading` within the pad frame.
	var visual := Node3D.new()
	visual.rotation.y = atan2(heading.x, heading.z)
	root.add_child(visual)

	# Local pad footprint (chevron-forward axis = local Z).
	var width  := size.x
	var length := size.z
	var cushion_h := 0.05  # very flat, almost merged with the floor

	# Soft blue cushion: a very flat, generously rounded pillow hugging the floor.
	# Single blue for every pad; shaded so the dome still reads.
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = PAD_CUSHION_COLOR
	pad_mat.roughness = 0.5
	pad_mat.metallic  = 0.1
	pad_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cushion := MeshInstance3D.new()
	var corner_r: float = minf(minf(width, length) * 0.5, 1.5)
	cushion.mesh = _build_cushion_mesh(width, length, cushion_h, corner_r)
	cushion.set_surface_override_material(0, pad_mat)  # bottom flush with the floor
	visual.add_child(cushion)

	# Lighter-blue chevrons pointing forward, just above the cushion top.
	var chev_mat := StandardMaterial3D.new()
	chev_mat.albedo_color = PAD_CHEVRON_COLOR
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
		var y_top := cushion_h + 0.012  # just above the cushion surface
		var chev := MeshInstance3D.new()
		chev.mesh = chev_mesh
		chev.set_surface_override_material(0, chev_mat)
		chev.position = Vector3(0.0, y_top, z_off)
		visual.add_child(chev)

	# Sensor area: full pad volume, inheriting the pad's orientation (matches the
	# server's oriented collider).
	var sensor := Area3D.new()
	sensor.name = "%s_sensor" % nm
	# Tagged so the client can mirror the server's boost (prediction → no rubber-band).
	sensor.add_to_group("BoostPad")
	sensor.set_meta("boost_strength", boost_strength)
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


# Pillow/cushion: a rounded rectangle (rounded vertical corners) lofted from the
# floor (y=0) up to `height` with rounded top edges, so it reads as a soft low
# cushion rather than a sharp box. Smooth normals are computed per vertex.
static func _build_cushion_mesh(width: float, length: float, height: float, radius: float, rings: int = 5, corner_segments: int = 4) -> ArrayMesh:
	var hw := width * 0.5
	var hl := length * 0.5
	var r0 := clampf(radius, 0.05, minf(hw, hl))
	# Footprint corner centres (fixed); each ring shrinks its radius for the top fillet.
	var corners := [
		[hw - r0, hl - r0, 0.0],
		[-(hw - r0), hl - r0, PI * 0.5],
		[-(hw - r0), -(hl - r0), PI],
		[hw - r0, -(hl - r0), PI * 1.5],
	]
	var per := 4 * (corner_segments + 1)

	# Ring positions: as we rise, the outline insets following a quarter-circle so
	# the top edge is rounded over (a fillet of depth `height`).
	var rings_pos: Array = []
	for rk in rings + 1:
		var phi := (float(rk) / float(rings)) * (PI * 0.5)
		var y := height * sin(phi)
		var inset := height * (1.0 - cos(phi))
		var rad: float = maxf(r0 - inset, 0.0)
		var ring := PackedVector3Array()
		for c in corners:
			for k in corner_segments + 1:
				var a: float = c[2] + (PI * 0.5) * (float(k) / float(corner_segments))
				ring.append(Vector3(c[0] + cos(a) * rad, y, c[1] + sin(a) * rad))
		rings_pos.append(ring)

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx   := PackedInt32Array()

	# Ring vertices with smooth normals (parallel × meridian tangents, forced outward).
	for rk in rings + 1:
		var ring: PackedVector3Array = rings_pos[rk]
		for i in per:
			var p := ring[i]
			var t_par := ring[(i + 1) % per] - ring[(i - 1 + per) % per]
			var t_mer: Vector3
			if rk == 0:
				t_mer = rings_pos[rk + 1][i] - p
			elif rk == rings:
				t_mer = p - rings_pos[rk - 1][i]
			else:
				t_mer = rings_pos[rk + 1][i] - rings_pos[rk - 1][i]
			var nrm := t_par.cross(t_mer)
			if nrm.length() < 1e-6:
				nrm = Vector3(p.x, 0.1, p.z)
			nrm = nrm.normalized()
			var outward := Vector3(p.x, 0.0, p.z)
			outward = (outward.normalized() + Vector3(0, 0.4, 0)) if outward.length() > 1e-5 else Vector3.UP
			if nrm.dot(outward) < 0.0:
				nrm = -nrm
			verts.append(p); norms.append(nrm)

	var top_centre := verts.size()
	verts.append(Vector3(0.0, height, 0.0)); norms.append(Vector3.UP)
	var bot_centre := verts.size()
	verts.append(Vector3(0.0, 0.0, 0.0)); norms.append(Vector3.DOWN)

	# Loft quads between consecutive rings.
	for rk in rings:
		var b0 := rk * per
		var b1 := (rk + 1) * per
		for i in per:
			var i2 := (i + 1) % per
			idx.append(b0 + i); idx.append(b1 + i); idx.append(b1 + i2)
			idx.append(b0 + i); idx.append(b1 + i2); idx.append(b0 + i2)

	# Top cap fan, then bottom cap fan (reversed).
	var top_ring := rings * per
	for i in per:
		idx.append(top_centre); idx.append(top_ring + i); idx.append(top_ring + (i + 1) % per)
	for i in per:
		idx.append(bot_centre); idx.append((i + 1) % per); idx.append(i)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
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
