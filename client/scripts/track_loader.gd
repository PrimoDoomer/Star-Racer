extends Node3D

class_name TrackLoader

const DecorBuilder = preload("res://scripts/decor_builder.gd")

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
const DECOR_DEFAULT_COLOR := Color(0.35, 0.75, 1.0)
const GATE_CHECKPOINT_COLOR := Color(0.35, 0.70, 1.0)   # checkpoints read cool blue
const GATE_START_COLOR := Color(0.50, 0.95, 0.55)       # start/finish reads green

const CURVE_SLAB_THICKNESS := 0.3
const CURVE_DEFAULT_SEGMENTS := 12

const ARC_DEFAULT_SEGMENTS := 8
const ARC_DEFAULT_SWEEP_DEG := 45.0

const ROAD_DEFAULT_SEGMENTS_PER_SPAN := 8
const ROAD_DEFAULT_WIDTH := 24.0
const ROAD_DEFAULT_WALL_HEIGHT := 1.2
const ROAD_WALL_THICKNESS := 2.0  # solid wall depth — mirrors server ROAD_WALL_THICKNESS
const ROAD_SURFACE_REFINE := 8  # driving surface is this much finer than the walls — mirrors server
const ROAD_WALL_REFINE := 3  # wall convex prisms this much finer than authored segments — mirrors server
const ROAD_CATMULL_ALPHA := 0.5  # centripetal — mirrors server ROAD_CATMULL_ALPHA
const ROAD_TEX_TILE := 56.0  # world units per road-texture tile along its length

static var _road_sh: Shader = null  # shared road-surface shader (built once)


static func build(parent: Node3D, track_def: Dictionary) -> Dictionary:
	# Textureless: every surface is a flat colour from the primitive's `color`
	# field (with the per-type defaults above). No shared material assets.
	var primitives: Array = track_def.get("primitives", [])
	for prim in primitives:
		var kind: String = prim.get("type", "")
		match kind:
			"floor":
				_make_static_box(parent, prim, FLOOR_DEFAULT_COLOR, false)
			"wall":
				_make_static_box(parent, prim, WALL_DEFAULT_COLOR, false)
			"hazard":
				_make_static_box(parent, prim, HAZARD_DEFAULT_COLOR, true)
			"pad":
				_make_pad(parent, prim)
			"curve":
				_make_curve(parent, prim, FLOOR_DEFAULT_COLOR, null)
			"arc":
				_make_arc(parent, prim, FLOOR_DEFAULT_COLOR, null)
			"road":
				_make_road(parent, prim, FLOOR_DEFAULT_COLOR, null)
			"decor":
				_make_decor(parent, prim)
			_:
				push_warning("TrackLoader: unknown primitive type '%s'" % kind)

	# Race gates get a simple visual arch (no collider) so they're readable on track.
	for gate in track_def.get("gates", []):
		_make_gate_arch(parent, gate)

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


# A simple visual arch marking a race gate (start_finish / checkpoint): a thin
# upright ring spanning the gate width, springing from the floor (its lower half
# sits below y=0, hidden by the floor). Purely visual — no collider. The car
# passes through the arch along the gate's forward axis.
static func _make_gate_arch(parent: Node3D, gate: Dictionary) -> void:
	var pos := _vec3_from_array(gate.get("position", []))
	var rot := _vec3_from_array(gate.get("rotation_deg", []), Vector3.ZERO)
	var hw := maxf(float(gate.get("half_width", 10.0)), 1.0)
	var role := String(gate.get("role", "checkpoint"))

	var root := Node3D.new()
	root.name = "gate_%s" % role
	root.position = Vector3(pos.x, 0.0, pos.z)  # spring from the floor
	root.rotation_degrees = Vector3(0.0, rot.y, 0.0)
	parent.add_child(root)

	var tube := maxf(hw * 0.04, 0.5)
	var torus := TorusMesh.new()
	torus.inner_radius = hw - tube
	torus.outer_radius = hw + tube
	torus.rings = 24
	var mi := MeshInstance3D.new()
	mi.mesh = torus
	mi.rotation = Vector3(PI * 0.5, 0.0, 0.0)  # stand the ring upright, hole along the gate forward
	var is_start := role == "start_finish" or role == "start" or role == "finish"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GATE_START_COLOR if is_start else GATE_CHECKPOINT_COLOR
	mat.roughness = 0.6
	mat.metallic = 0.0
	mi.material_override = mat
	root.add_child(mi)


static func _vec3_from_array(arr: Array, default: Vector3 = Vector3.ZERO) -> Vector3:
	if arr.size() < 3:
		return default
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


static func _color_from_array(arr, default: Color) -> Color:
	if arr == null or not arr is Array or arr.size() < 3:
		return default
	return Color(float(arr[0]), float(arr[1]), float(arr[2]))


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
	# chevrons yaw to point along the WORLD `heading` (the race direction). We
	# subtract the root's own yaw so the arrow tracks `heading` regardless of how
	# rotation_deg orients the (symmetric) pad box — otherwise a rotated pad's
	# chevrons get double-rotated and point backwards.
	var visual := Node3D.new()
	visual.rotation.y = atan2(heading.x, heading.z) - deg_to_rad(rot.y)
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


# Visual set-dressing. The server only knows the cheap box proxy (matched here as
# a StaticBody when `collide`); the look comes from either a `res://….glb` model
# (auto-fitted to `size`) or a procedural keyword built by DecorBuilder.
static func _make_decor(parent: Node3D, prim: Dictionary) -> void:
	var size := _vec3_from_array(prim.get("size", []), Vector3.ONE)
	var pos  := _vec3_from_array(prim.get("position", []))
	var rot  := _vec3_from_array(prim.get("rotation_deg", []), Vector3.ZERO)
	var color := _color_from_array(prim.get("color", null), DECOR_DEFAULT_COLOR)
	var nm: String = prim.get("name", "decor")
	var model := String(prim.get("model", ""))
	var collide: bool = prim.get("collide", true) != false

	var root := Node3D.new()
	root.name = nm
	root.position = pos
	root.rotation_degrees = rot
	parent.add_child(root)

	var visual: Node3D = null
	if model.begins_with("res://") and ResourceLoader.exists(model):
		var res = load(model)
		if res is PackedScene:
			visual = (res as PackedScene).instantiate()
			_fit_node_to_size(visual, size)
	if visual == null:
		visual = DecorBuilder.build(model, size, color)
	root.add_child(visual)

	if collide:
		var body := StaticBody3D.new()
		body.name = "%s_proxy" % nm
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		cs.shape = box
		body.add_child(cs)
		root.add_child(body)


# Scale + recenter a loaded model so its mesh AABB fits within `size`, centred on
# the local origin (best-effort, for the optional GLB decor path).
static func _fit_node_to_size(node: Node3D, size: Vector3) -> void:
	var aabb := _node_aabb(node)
	if aabb.size.x <= 0.0 or aabb.size.y <= 0.0 or aabb.size.z <= 0.0:
		return
	var s := minf(minf(size.x / aabb.size.x, size.y / aabb.size.y), size.z / aabb.size.z)
	node.scale = Vector3(s, s, s)
	node.position = -aabb.get_center() * s

static func _node_aabb(node: Node3D) -> AABB:
	var acc := AABB()
	var has := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		acc = (node as MeshInstance3D).mesh.get_aabb()
		has = true
	for child in node.get_children():
		if child is Node3D:
			var sub := _node_aabb(child)
			if sub.size.length() > 0.0:
				sub = (child as Node3D).transform * sub
				if not has:
					acc = sub
					has = true
				else:
					acc = acc.merge(sub)
	return acc


# Flat horizontal turn: yaw-rotated floor slabs along a circular arc in the local
# XZ plane. Entry at local origin heading -Z; center on +X (sweep_deg > 0, right)
# or -X (sweep_deg < 0, left). Mirrors server build_arc_colliders — keep in sync.
static func _make_arc(parent: Node3D, prim: Dictionary, default_color: Color, override_mat: StandardMaterial3D) -> void:
	var size := _vec3_from_array(prim.get("size", []))
	var pos  := _vec3_from_array(prim.get("position", []))
	var rot  := _vec3_from_array(prim.get("rotation_deg", []), Vector3.ZERO)
	var color := _color_from_array(prim.get("color", null), default_color)
	var nm: String = prim.get("name", "arc")
	var segments: int = int(prim.get("segments", ARC_DEFAULT_SEGMENTS))
	if segments < 1:
		segments = 1
	var sweep_deg: float = float(prim.get("sweep_deg", ARC_DEFAULT_SWEEP_DEG))

	var width := size.x
	var thickness := size.y
	var radius := size.z
	var centers := _arc_centers(radius, sweep_deg, segments)

	var body := StaticBody3D.new()
	body.name = nm
	body.position = pos
	body.rotation_degrees = rot

	var mi := MeshInstance3D.new()
	mi.mesh = _build_arc_mesh(centers, width, thickness)
	if override_mat != null:
		mi.set_surface_override_material(0, override_mat)
	else:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.8
		mat.metallic = 0.1
		mi.set_surface_override_material(0, mat)
	body.add_child(mi)

	for i in range(segments):
		var c0: Vector2 = centers[i]
		var c1: Vector2 = centers[i + 1]
		var dx := c1.x - c0.x
		var dz := c1.y - c0.y
		var chord := sqrt(dx * dx + dz * dz)
		if chord < 1e-6:
			continue
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(width, thickness, chord)
		cs.shape = box
		cs.position = Vector3(0.5 * (c0.x + c1.x), 0.0, 0.5 * (c0.y + c1.y))
		cs.rotation = Vector3(0.0, atan2(dx, dz), 0.0)
		body.add_child(cs)

	parent.add_child(body)


# Centerline points (local x, z) of an arc at each segment boundary. Shared by
# the game loader and the editor so both draw the identical curve.
static func _arc_centers(radius: float, sweep_deg: float, segments: int) -> Array[Vector2]:
	var sgn := -1.0 if sweep_deg < 0.0 else 1.0
	var sweep := deg_to_rad(absf(sweep_deg))
	var cx := sgn * radius
	var centers: Array[Vector2] = []
	for i in range(maxi(segments, 1) + 1):
		var a := float(i) / float(maxi(segments, 1)) * sweep
		var rota := -sgn * a
		var x0 := -cx
		centers.append(Vector2(cx + x0 * cos(rota), -x0 * sin(rota)))
	return centers


# Top-surface ribbon for an arc, at y = thickness/2 (sitting on the slab tops).
static func _build_arc_mesh(centers: Array[Vector2], width: float, thickness: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs   := PackedVector2Array()
	var idx   := PackedInt32Array()

	var hw := width * 0.5
	var y := thickness * 0.5
	var n := centers.size()
	for i in range(n):
		var c: Vector2 = centers[i]
		var t: Vector2 = (centers[i + 1] - c) if i < n - 1 else (c - centers[i - 1])
		if t.length() < 1e-6:
			t = Vector2(0.0, 1.0)
		t = t.normalized()
		var perp := Vector2(t.y, -t.x)  # lateral (matches server slab width axis)
		var left := c + perp * hw
		var right := c - perp * hw
		var v := float(i) / float(n - 1)
		verts.append(Vector3(left.x, y, left.y));  norms.append(Vector3.UP); uvs.append(Vector2(0.0, v))
		verts.append(Vector3(right.x, y, right.y)); norms.append(Vector3.UP); uvs.append(Vector2(1.0, v))

	for i in range(n - 1):
		var a := i * 2
		var b := a + 1
		var c2 := a + 2
		var d := a + 3
		idx.append(a); idx.append(c2); idx.append(b)
		idx.append(b); idx.append(c2); idx.append(d)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = idx

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


# Free-form curved road: a Catmull-Rom spline through `nodes`, built as ONE
# continuous mesh used for both the visual AND the collision (a trimesh) — so a
# banked/curved road is seamless, with no inter-slab steps. Mirrors server
# road_trimesh / build_road_colliders — keep in sync.
static func _make_road(parent: Node3D, prim: Dictionary, default_color: Color, override_mat: StandardMaterial3D) -> void:
	if _sample_road(prim).size() < 2:           # needs at least 2 control nodes
		return
	var fine := _sample_road_seg(prim, _road_segments(prim) * ROAD_SURFACE_REFINE)  # smooth surface
	var pos  := _vec3_from_array(prim.get("position", []))
	var rot  := _vec3_from_array(prim.get("rotation_deg", []), Vector3.ZERO)
	var color := _color_from_array(prim.get("color", null), default_color)
	var nm: String = prim.get("name", "road")
	var walls: bool = prim.get("walls", false) == true
	var wall_h: float = float(prim.get("wall_height", ROAD_DEFAULT_WALL_HEIGHT))

	var body := StaticBody3D.new()
	body.name = nm
	body.position = pos
	body.rotation_degrees = rot

	var mesh := _build_road_mesh(fine, walls, wall_h)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat: Material = override_mat
	if mat == null:
		# Procedural race-track surface: the road colour with crisp anti-aliased lane
		# lines (white edges + dashed centre) and red/white rumble curbs along the
		# edges — all UV-driven, so it stays sharp at any zoom (no texture). The colour
		# is the only per-road input. A faint sheen catches the room lighting.
		var sm := ShaderMaterial.new()
		sm.shader = _road_shader()
		sm.set_shader_parameter("road_color", color)
		mat = sm
	mi.set_surface_override_material(0, mat)
	if walls and mesh.get_surface_count() > 1:
		var wall_mat := StandardMaterial3D.new()
		wall_mat.albedo_color = WALL_DEFAULT_COLOR
		wall_mat.roughness = 0.8
		wall_mat.metallic = 0.1
		wall_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.set_surface_override_material(1, wall_mat)
	body.add_child(mi)

	# Collision: the FINE surface as a smooth trimesh (built without walls — small
	# facets ride smoothly), plus each side wall as a chain of SOLID convex prisms
	# at the coarse density (volume → no tunnel; bounded collider count).
	var surf := CollisionShape3D.new()
	surf.shape = _build_road_mesh(fine).create_trimesh_shape()
	body.add_child(surf)
	if walls:
		_add_road_wall_colliders(body, _sample_road_seg(prim, _road_segments(prim) * ROAD_WALL_REFINE), wall_h)

	parent.add_child(body)


# Solid convex prism colliders along each road edge (mirrors server build_road_colliders).
static func _add_road_wall_colliders(body: StaticBody3D, samples: Array, wall_h: float) -> void:
	var n := samples.size()
	var pos: Array[Vector3] = []
	var rgt: Array[Vector3] = []
	var upv: Array[Vector3] = []
	var hwv: Array[float] = []
	for i in range(n):
		var s: Dictionary = samples[i]
		var c: Vector3 = s["pos"]
		var fwd: Vector3 = (samples[i + 1]["pos"] - c) if i < n - 1 else (c - samples[i - 1]["pos"])
		if fwd.length() < 1e-6:
			fwd = Vector3(0, 0, 1)
		fwd = fwd.normalized()
		var frame := _road_frame(fwd, deg_to_rad(float(s["bank"])))
		pos.append(c); rgt.append(frame[0]); upv.append(frame[1]); hwv.append(float(s["width"]) * 0.5)

	var wt := ROAD_WALL_THICKNESS
	for i in range(n - 1):
		for side: float in [1.0, -1.0]:
			var ib0 := pos[i] + rgt[i] * (hwv[i] * side)
			var ob0 := pos[i] + rgt[i] * ((hwv[i] + wt) * side)
			var ib1 := pos[i + 1] + rgt[i + 1] * (hwv[i + 1] * side)
			var ob1 := pos[i + 1] + rgt[i + 1] * ((hwv[i + 1] + wt) * side)
			var shape := ConvexPolygonShape3D.new()
			shape.points = PackedVector3Array([
				ib0, ob0, ib0 + upv[i] * wall_h, ob0 + upv[i] * wall_h,
				ib1, ob1, ib1 + upv[i + 1] * wall_h, ob1 + upv[i + 1] * wall_h,
			])
			var cs := CollisionShape3D.new()
			cs.shape = shape
			body.add_child(cs)


# Catmull-Rom samples of a road: an Array of { pos:Vector3, width:float, bank:float },
# passing through every control node. Mirrors server road_samples.
static func _road_segments(prim: Dictionary) -> int:
	return maxi(int(prim.get("segments", ROAD_DEFAULT_SEGMENTS_PER_SPAN)), 1)


# Road samples at the authored density (walls + visual). The driving surface is
# sampled finer (× ROAD_SURFACE_REFINE) so the box car rides it smoothly.
static func _sample_road(prim: Dictionary) -> Array:
	return _sample_road_seg(prim, _road_segments(prim))


static func _sample_road_seg(prim: Dictionary, seg: int) -> Array:
	var nodes: Array = prim.get("nodes", [])
	if nodes.size() < 2:
		return []
	var size := _vec3_from_array(prim.get("size", []))
	if seg < 1:
		seg = 1
	var default_w: float = size.x if size.x > 0.0 else ROAD_DEFAULT_WIDTH

	var p: Array[Vector3] = []
	var w: Array[float] = []
	var b: Array[float] = []
	var h_out: Array = []   # Vector3 or null, per node
	var h_in: Array = []
	for nd in nodes:
		p.append(_vec3_from_array(nd.get("position", [])))
		w.append(float(nd.get("width", default_w)))
		b.append(float(nd.get("bank_deg", 0.0)))
		# null entries mean "no handle on this node" (kept as if/else, not a
		# ternary, so the Vector3/null branches don't trip INCOMPATIBLE_TERNARY).
		var ho = nd.get("handle_out", null)
		if ho is Array:
			h_out.append(_vec3_from_array(ho))
		else:
			h_out.append(null)
		var hi = nd.get("handle_in", null)
		if hi is Array:
			h_in.append(_vec3_from_array(hi))
		else:
			h_in.append(null)

	var n := p.size()
	var out: Array = []
	for i in range(n - 1):
		var p0: Vector3 = (p[0] + (p[0] - p[1])) if i == 0 else p[i - 1]
		var p1: Vector3 = p[i]
		var p2: Vector3 = p[i + 1]
		var p3: Vector3 = (p[n - 1] + (p[n - 1] - p[n - 2])) if i + 2 >= n else p[i + 2]
		# A span with any explicit handle becomes a cubic Bézier; a missing handle
		# defaults to a third of the chord (mirrors server road_samples).
		var ho = h_out[i]
		var hi = h_in[i + 1]
		var use_bezier: bool = ho != null or hi != null
		var b1: Vector3 = p1 + (p2 - p1) / 3.0
		if ho != null:
			b1 = p1 + (ho as Vector3)
		var b2: Vector3 = p2 + (p1 - p2) / 3.0
		if hi != null:
			b2 = p2 + (hi as Vector3)
		var count: int = (seg + 1) if i == n - 2 else seg
		for s in range(count):
			var u := float(s) / float(seg)
			var pos: Vector3 = _cubic_bezier(p1, b1, b2, p2, u) if use_bezier else _catmull_centripetal(p0, p1, p2, p3, u)
			out.append({
				"pos": pos,
				"width": w[i] + (w[i + 1] - w[i]) * u,
				"bank": b[i] + (b[i + 1] - b[i]) * u,
			})
	return out


# Cubic Bézier point at u in [0,1]. Mirrors server cubic_bezier.
static func _cubic_bezier(b0: Vector3, b1: Vector3, b2: Vector3, b3: Vector3, u: float) -> Vector3:
	var v := 1.0 - u
	return b0 * (v * v * v) + b1 * (3.0 * v * v * u) + b2 * (3.0 * v * u * u) + b3 * (u * u * u)


static func _road_knot(ti: float, a: Vector3, b: Vector3) -> float:
	return ti + maxf(pow((b - a).length(), ROAD_CATMULL_ALPHA), 1e-6)


static func _road_lerp_t(a: Vector3, b: Vector3, ta: float, tb: float, t: float) -> Vector3:
	if absf(tb - ta) < 1e-9:
		return a
	return a + (b - a) * ((t - ta) / (tb - ta))


# Centripetal Catmull-Rom point on the p1..p2 span at u in [0,1] (Barry-Goldman).
static func _catmull_centripetal(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, u: float) -> Vector3:
	var t0 := 0.0
	var t1 := _road_knot(t0, p0, p1)
	var t2 := _road_knot(t1, p1, p2)
	var t3 := _road_knot(t2, p2, p3)
	var t := t1 + (t2 - t1) * u
	var a1 := _road_lerp_t(p0, p1, t0, t1, t)
	var a2 := _road_lerp_t(p1, p2, t1, t2, t)
	var a3 := _road_lerp_t(p2, p3, t2, t3, t)
	var b1 := _road_lerp_t(a1, a2, t0, t2, t)
	var b2 := _road_lerp_t(a2, a3, t1, t3, t)
	return _road_lerp_t(b1, b2, t1, t2, t)


# Cross-section frame (right = local +X, up = local +Y) for a slab heading along
# `fwd`, rolled by `bank` (radians). Mirrors server road_frame.
static func _road_frame(fwd: Vector3, bank: float) -> Array:
	var up_ref := Vector3(0, 0, 1) if absf(fwd.y) > 0.99 else Vector3(0, 1, 0)
	var right0 := up_ref.cross(fwd).normalized()
	var up0 := fwd.cross(right0)
	var s := sin(bank)
	var c := cos(bank)
	return [right0 * c + up0 * s, up0 * c - right0 * s]


# A simple tileable road texture, generated in code (no asset): a grey asphalt
# body with a dashed centre line and solid edge lines. Multiplied by the road's
# colour (so the road keeps its tint). Cached — built once.
static func _road_shader() -> Shader:
	if _road_sh != null:
		return _road_sh
	# UV.x spans the road width 0..1 (0/1 = edges, 0.5 = centre); UV.y runs along the
	# length in tile units (1 tile = ROAD_TEX_TILE world units), so markings repeat by
	# distance regardless of segment count. Markings are anti-aliased with fwidth so
	# they stay crisp from any distance — no texture, fits the textureless art.
	_road_sh = Shader.new()
	_road_sh.code = "\n".join([
		"shader_type spatial;",
		"render_mode cull_disabled;",
		"uniform vec3 road_color : source_color = vec3(0.14, 0.16, 0.21);",
		"uniform vec3 line_color : source_color = vec3(0.93, 0.94, 0.97);",
		"uniform vec3 curb_a : source_color = vec3(0.86, 0.18, 0.18);",
		"uniform vec3 curb_b : source_color = vec3(0.95, 0.95, 0.97);",
		"uniform float rough = 0.55;",
		"void fragment() {",
		"	float u = UV.x;",
		"	float v = UV.y;",
		"	float edge = min(u, 1.0 - u);",       # distance to nearest edge
		"	float aa = fwidth(u) * 1.5;",
		"	vec3 col = road_color;",
		"	// red/white rumble curbs on the outer edges",
		"	float curb_mask = 1.0 - smoothstep(0.055 - aa, 0.055 + aa, edge);",
		"	vec3 curb_col = mix(curb_a, curb_b, step(0.5, fract(v * 8.0)));",
		"	col = mix(col, curb_col, curb_mask);",
		"	// solid white edge lines just inboard of the curbs",
		"	float edge_line = 1.0 - smoothstep(0.015, 0.015 + aa, abs(edge - 0.10));",
		"	col = mix(col, line_color, edge_line);",
		"	// dashed white centre line",
		"	float centre = 1.0 - smoothstep(0.016, 0.016 + aa, abs(u - 0.5));",
		"	col = mix(col, line_color, centre * step(0.5, fract(v * 4.0)));",
		"	ALBEDO = col;",
		"	ROUGHNESS = rough;",
		"	METALLIC = 0.0;",
		"}",
	])
	return _road_sh


# Top-surface ribbon for a road, at the centerline (the driving surface).
static func _build_road_mesh(samples: Array, walls: bool = false, wall_h: float = 0.0) -> ArrayMesh:
	# Per-sample edge frame (same tangent/frame as the server road_trimesh).
	var n := samples.size()
	var pos: Array[Vector3] = []
	var rgt: Array[Vector3] = []
	var upv: Array[Vector3] = []
	var hwv: Array[float] = []
	for i in range(n):
		var s: Dictionary = samples[i]
		var c: Vector3 = s["pos"]
		var fwd: Vector3 = (samples[i + 1]["pos"] - c) if i < n - 1 else (c - samples[i - 1]["pos"])
		if fwd.length() < 1e-6:
			fwd = Vector3(0, 0, 1)
		fwd = fwd.normalized()
		var frame := _road_frame(fwd, deg_to_rad(float(s["bank"])))
		pos.append(c); rgt.append(frame[0]); upv.append(frame[1]); hwv.append(float(s["width"]) * 0.5)

	# Cumulative arc length so the road texture tiles along the curve (UV.v),
	# independent of segment count; UV.u spans the width 0..1.
	var cumdist: Array[float] = []
	var acc := 0.0
	for i in range(n):
		if i > 0:
			acc += pos[i].distance_to(pos[i - 1])
		cumdist.append(acc)

	var am := ArrayMesh.new()

	# Surface 0: the driving ribbon (left/right edge per sample).
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs   := PackedVector2Array()
	var idx   := PackedInt32Array()
	for i in range(n):
		var v := cumdist[i] / ROAD_TEX_TILE
		verts.append(pos[i] + rgt[i] * hwv[i]); norms.append(upv[i]); uvs.append(Vector2(0.0, v))
		verts.append(pos[i] - rgt[i] * hwv[i]); norms.append(upv[i]); uvs.append(Vector2(1.0, v))
	for i in range(n - 1):
		var a := i * 2
		idx.append(a); idx.append(a + 2); idx.append(a + 1)
		idx.append(a + 1); idx.append(a + 2); idx.append(a + 3)
	var sa := []
	sa.resize(Mesh.ARRAY_MAX)
	sa[Mesh.ARRAY_VERTEX] = verts; sa[Mesh.ARRAY_NORMAL] = norms
	sa[Mesh.ARRAY_TEX_UV] = uvs;   sa[Mesh.ARRAY_INDEX]  = idx
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sa)

	# Surface 1: the two side walls as SOLID prisms (inner + outer face + top cap)
	# so a fast car can't tunnel through a paper-thin edge. Mirrors server road_trimesh.
	if walls and wall_h > 0.0:
		var wv := PackedVector3Array()
		var wn := PackedVector3Array()
		var wt := ROAD_WALL_THICKNESS
		for side: float in [1.0, -1.0]:   # +1 = left edge, -1 = right edge
			for i in range(n - 1):
				var ib0 := pos[i] + rgt[i] * (hwv[i] * side)
				var ob0 := pos[i] + rgt[i] * ((hwv[i] + wt) * side)
				var ib1 := pos[i + 1] + rgt[i + 1] * (hwv[i + 1] * side)
				var ob1 := pos[i + 1] + rgt[i + 1] * ((hwv[i + 1] + wt) * side)
				var it0 := ib0 + upv[i] * wall_h
				var ot0 := ob0 + upv[i] * wall_h
				var it1 := ib1 + upv[i + 1] * wall_h
				var ot1 := ob1 + upv[i + 1] * wall_h
				# inner face
				wv.append(ib0); wv.append(it0); wv.append(ib1)
				wv.append(it0); wv.append(it1); wv.append(ib1)
				# outer face
				wv.append(ob0); wv.append(ot0); wv.append(ob1)
				wv.append(ot0); wv.append(ot1); wv.append(ob1)
				# top cap
				wv.append(it0); wv.append(ot0); wv.append(it1)
				wv.append(ot0); wv.append(ot1); wv.append(it1)
				var n_in := rgt[i] * (-side)
				var n_out := rgt[i] * side
				var n_top := upv[i]
				for k in 6: wn.append(n_in)
				for k in 6: wn.append(n_out)
				for k in 6: wn.append(n_top)
		var wa := []
		wa.resize(Mesh.ARRAY_MAX)
		wa[Mesh.ARRAY_VERTEX] = wv
		wa[Mesh.ARRAY_NORMAL] = wn
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wa)

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
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
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

	var pz := PackedFloat32Array()
	var py := PackedFloat32Array()
	for i in range(segments + 1):
		var t := float(i) / float(segments) * (PI * 0.5)
		pz.append(length * sin(t))
		py.append(height * (1.0 - cos(t)))

	var top := verts.size()
	for i in range(segments + 1):
		var t := float(i) / float(segments) * (PI * 0.5)
		var n := Vector3(0.0, cos(t), -sin(t)).normalized()
		var v := float(i) / float(segments)
		verts.append(Vector3(-hw, py[i], pz[i])); norms.append(n); uvs.append(Vector2(0.0, v))
		verts.append(Vector3(hw, py[i], pz[i]));  norms.append(n); uvs.append(Vector2(1.0, v))
	for i in range(segments):
		var a := top + i * 2
		idx.append(a); idx.append(a + 2); idx.append(a + 1)
		idx.append(a + 1); idx.append(a + 2); idx.append(a + 3)

	var bot := verts.size()
	for p in [Vector3(-hw, 0.0, 0.0), Vector3(hw, 0.0, 0.0), Vector3(-hw, 0.0, length), Vector3(hw, 0.0, length)]:
		verts.append(p); norms.append(Vector3(0, -1, 0)); uvs.append(Vector2(0, 0))
	idx.append(bot); idx.append(bot + 1); idx.append(bot + 2)
	idx.append(bot + 1); idx.append(bot + 3); idx.append(bot + 2)

	var back := verts.size()
	for p in [Vector3(-hw, 0.0, length), Vector3(hw, 0.0, length), Vector3(-hw, height, length), Vector3(hw, height, length)]:
		verts.append(p); norms.append(Vector3(0, 0, 1)); uvs.append(Vector2(0, 0))
	idx.append(back); idx.append(back + 2); idx.append(back + 1)
	idx.append(back + 1); idx.append(back + 2); idx.append(back + 3)

	for side: float in [-1.0, 1.0]:
		var x := hw * side
		var n_side := Vector3(side, 0.0, 0.0)
		var s := verts.size()
		for i in range(segments + 1):
			verts.append(Vector3(x, py[i], pz[i])); norms.append(n_side); uvs.append(Vector2(pz[i] / length, 1.0))
			verts.append(Vector3(x, 0.0, pz[i]));   norms.append(n_side); uvs.append(Vector2(pz[i] / length, 0.0))
		for i in range(segments):
			var a := s + i * 2
			idx.append(a); idx.append(a + 1); idx.append(a + 2)
			idx.append(a + 1); idx.append(a + 3); idx.append(a + 2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = idx

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am
