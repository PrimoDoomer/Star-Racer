extends Node3D

## Transform gizmo for the map editor: translate / rotate / scale handles that
## follow the selected EditorItem. Handle picking is analytic (ray vs. axis line,
## ray vs. plane, ray vs. ring) — no physics colliders — which keeps ring picking
## simple and avoids an extra collision layer.
##
## Translate & rotate operate on world axes; scale operates on the item's local
## axes. Handles are kept at a roughly constant on-screen size via _process.
## The numeric inspector remains the precise fallback for any edit.

class_name TransformGizmo

enum Mode { TRANSLATE, ROTATE, SCALE }

const SCREEN_K := 0.085          # handle world-size per unit camera distance
const AXIS_LEN := 1.0
const ARROW_TOL := 0.18
const PLANE_OFF := 0.32
const PLANE_SZ := 0.34
const RING_R := 0.95
const RING_TOL := 0.13
const UNIFORM_PX := 16.0

const COL_X := Color(0.95, 0.35, 0.35)
const COL_Y := Color(0.45, 0.88, 0.45)
const COL_Z := Color(0.40, 0.58, 0.97)
const COL_HI := Color(1.0, 0.85, 0.25)
const COL_UNI := Color(0.9, 0.92, 0.96)

var camera: Camera3D = null
var editor = null                # MapEditor
var target = null                # EditorItem or EditorGate (duck-typed)
var mode: int = Mode.TRANSLATE
var snap_enabled := false
var snap_pos := 1.0
var snap_rot := 15.0
var snap_scale := 0.5

var _handles: Node3D = null
var _cur_hs := 1.0

# Drag state.
var _dragging := false
var _kind := ""                  # "axis" | "plane" | "ring" | "scale" | "uniform"
var _axis := 0
var _start_pos := Vector3.ZERO
var _start_size := Vector3.ONE
var _start_basis := Basis.IDENTITY
var _drag_s0 := 0.0
var _plane_hit0 := Vector3.ZERO
var _ring_ang0 := 0.0
var _uniform_d0 := 1.0
# Reference geometry captured at drag start. The drag maths use these fixed
# values so the result stays stable even though _process keeps the gizmo
# visually following the (moving) object — otherwise the origin drifts each
# frame and the object jitters.
var _drag_origin := Vector3.ZERO
var _drag_axis := Vector3.RIGHT
# Banking-ring state (road node in ROTATE mode): roll axis + starting bank angle.
var _bank_axis := Vector3.FORWARD
var _start_bank := 0.0

const BANK_LIMIT := 60.0

func setup(cam: Camera3D, editor_ref) -> void:
	camera = cam
	editor = editor_ref
	_handles = Node3D.new()
	_handles.name = "Handles"
	add_child(_handles)
	visible = false

func set_target(item) -> void:
	target = item
	visible = item != null
	if target:
		_place()
		_rebuild_handles()

func set_mode(m: int) -> void:
	mode = m
	if target:
		_place()
		_rebuild_handles()

func refresh() -> void:
	if target:
		_place()
		_rebuild_handles()

func is_dragging() -> bool:
	return _dragging

func _process(_dt: float) -> void:
	if target == null or not visible or camera == null:
		return
	_place()
	_cur_hs = clampf(camera.global_position.distance_to(global_position) * SCREEN_K, 0.25, 200.0)
	_handles.scale = Vector3.ONE * _cur_hs

func _place() -> void:
	var b := Basis.IDENTITY
	if mode == Mode.SCALE and target:
		b = target.global_transform.basis.orthonormalized()
	global_transform = Transform3D(b, target.global_position)

# ---------------------------------------------------------------------------
# Picking + drag lifecycle (driven by MapEditor)

func try_begin_drag(mouse: Vector2) -> bool:
	if target == null or not visible:
		return false
	var hit := _pick(mouse)
	if hit.is_empty():
		return false
	_dragging = true
	_kind = hit["kind"]
	_axis = hit.get("axis", 0)
	_start_pos = target.position
	_start_size = target.get_size()
	_start_basis = target.global_transform.basis
	_drag_origin = global_position
	_drag_axis = _axis_dir(_axis)
	match _kind:
		"axis", "scale":
			_drag_s0 = hit["s"]
		"plane":
			_plane_hit0 = hit["point"]
		"ring":
			_ring_ang0 = hit["angle"]
		"bank":
			_ring_ang0 = hit["angle"]
			_bank_axis = hit["axis_vec"]
			_start_bank = float(target.data.get("bank_deg", 0.0))
		"uniform":
			_uniform_d0 = maxf(hit["d"], 1.0)
	return true

func update_drag(mouse: Vector2) -> void:
	if not _dragging or target == null:
		return
	var o := camera.project_ray_origin(mouse)
	var d := camera.project_ray_normal(mouse)
	match _kind:
		"axis":
			_apply_translate_axis(o, d)
		"plane":
			_apply_translate_plane(o, d)
		"ring":
			_apply_rotate(o, d)
		"bank":
			_apply_bank(o, d)
		"scale":
			_apply_scale_axis(o, d)
		"uniform":
			_apply_scale_uniform(mouse)
	editor.notify_transform_from_gizmo(target)

func end_drag() -> void:
	if _dragging:
		_dragging = false
		editor.commit_after_gizmo()

func _snapping() -> bool:
	# Hold Ctrl to invert the snap toggle, mirroring common DCC tools.
	return snap_enabled != Input.is_key_pressed(KEY_CTRL)

func _scalable() -> bool:
	return target != null and target.supports_scale()

# ---------------------------------------------------------------------------
# Drag application

func _apply_translate_axis(o: Vector3, d: Vector3) -> void:
	var u := _drag_axis
	var s := _ray_line_s(o, d, _drag_origin, u)
	var delta := s - _drag_s0
	if _snapping():
		delta = snappedf(delta, snap_pos)
	var p := _start_pos + u * delta
	target.data["position"] = [p.x, p.y, p.z]

func _apply_translate_plane(o: Vector3, d: Vector3) -> void:
	var n := _world_axis(_axis)
	var hit = _ray_plane(o, d, _drag_origin, n)
	if hit == null:
		return
	var delta: Vector3 = hit - _plane_hit0
	var p := _start_pos + delta
	if _snapping():
		p = Vector3(snappedf(p.x, snap_pos), snappedf(p.y, snap_pos), snappedf(p.z, snap_pos))
	target.data["position"] = [p.x, p.y, p.z]

func _apply_rotate(o: Vector3, d: Vector3) -> void:
	var n := _world_axis(_axis)
	var hit = _ray_plane(o, d, _drag_origin, n)
	if hit == null:
		return
	var ang := _ring_angle(hit - _drag_origin, _axis)
	var delta := ang - _ring_ang0
	if _snapping():
		delta = snappedf(delta, deg_to_rad(snap_rot))
	var new_basis := Basis(n, delta) * _start_basis
	# Let the node convert the basis into rotation_degrees (its euler order),
	# then copy that back into data so editor visuals stay consistent.
	target.global_transform = Transform3D(new_basis, target.global_position)
	var r: Vector3 = target.rotation_degrees
	target.data["rotation_deg"] = [r.x, r.y, r.z]

# Road node banking: the roll angle around the road tangent drives `bank_deg`.
func _apply_bank(o: Vector3, d: Vector3) -> void:
	var hit = _ray_plane(o, d, _drag_origin, _bank_axis)
	if hit == null:
		return
	var ang := _axis_ring_angle(hit - _drag_origin, _bank_axis)
	var delta := ang - _ring_ang0
	if _snapping():
		delta = snappedf(delta, deg_to_rad(snap_rot))
	target.data["bank_deg"] = clampf(_start_bank + rad_to_deg(delta), -BANK_LIMIT, BANK_LIMIT)

func _apply_scale_axis(o: Vector3, d: Vector3) -> void:
	var u := _drag_axis
	var s := _ray_line_s(o, d, _drag_origin, u)
	var delta := (s - _drag_s0) * 2.0  # centred box: face moves by delta/2
	var sz := _start_size
	var v := maxf(sz[_axis] + delta, 0.1)
	if _snapping():
		v = maxf(snappedf(v, snap_scale), 0.1)
	var out := [sz.x, sz.y, sz.z]
	out[_axis] = v
	target.data["size"] = out

func _apply_scale_uniform(mouse: Vector2) -> void:
	var center := camera.unproject_position(_drag_origin)
	var factor := maxf(mouse.distance_to(center), 1.0) / _uniform_d0
	var sz := _start_size * factor
	target.data["size"] = [maxf(sz.x, 0.1), maxf(sz.y, 0.1), maxf(sz.z, 0.1)]

# ---------------------------------------------------------------------------
# Picking maths

func _pick(mouse: Vector2) -> Dictionary:
	var o := camera.project_ray_origin(mouse)
	var d := camera.project_ray_normal(mouse)
	var best := {}
	var best_t := INF

	if mode == Mode.TRANSLATE:
		for i in 3:
			var a := _try_axis(o, d, i, 0.0, AXIS_LEN * _cur_hs, ARROW_TOL * _cur_hs)
			if not a.is_empty() and a["t"] < best_t:
				best_t = a["t"]; best = {"kind": "axis", "axis": i, "s": a["s"]}
		for i in 3:
			var pl := _try_plane(o, d, i)
			if not pl.is_empty() and pl["t"] < best_t:
				best_t = pl["t"]; best = {"kind": "plane", "axis": i, "point": pl["point"]}
	elif mode == Mode.ROTATE:
		if _is_road_node():
			# A single roll ring around the road tangent edits the node's banking.
			var axis: Vector3 = target.forward()
			var rg := _try_axis_ring(o, d, axis)
			if not rg.is_empty():
				best = {"kind": "bank", "axis_vec": axis, "angle": rg["angle"]}
		else:
			for i in 3:
				var rg := _try_ring(o, d, i)
				if not rg.is_empty() and rg["t"] < best_t:
					best_t = rg["t"]; best = {"kind": "ring", "axis": i, "angle": rg["angle"]}
	else:  # SCALE
		if not _scalable():
			return best
		for i in 3:
			var a := _try_axis(o, d, i, 0.0, AXIS_LEN * _cur_hs, ARROW_TOL * _cur_hs)
			if not a.is_empty() and a["t"] < best_t:
				best_t = a["t"]; best = {"kind": "scale", "axis": i, "s": a["s"]}
		var center := camera.unproject_position(global_position)
		if mouse.distance_to(center) < UNIFORM_PX:
			var t := o.distance_to(global_position)
			if t < best_t:
				best_t = t; best = {"kind": "uniform", "d": mouse.distance_to(center)}
	return best

func _try_axis(o: Vector3, d: Vector3, i: int, s_min: float, s_max: float, tol: float) -> Dictionary:
	var u := _axis_dir(i)
	var res := _ray_line_closest(o, d, global_position, u)
	if res.is_empty():
		return {}
	var t: float = res["t"]
	var s: float = res["s"]
	if t <= 0.0 or s < s_min or s > s_max or res["dist"] > tol:
		return {}
	return {"t": t, "s": s}

func _try_plane(o: Vector3, d: Vector3, i: int) -> Dictionary:
	var n := _world_axis(i)
	var hit = _ray_plane(o, d, global_position, n)
	if hit == null:
		return {}
	var off: Vector3 = hit - global_position
	var j := (i + 1) % 3
	var k := (i + 2) % 3
	var uj: float = off.dot(_world_axis(j))
	var uk: float = off.dot(_world_axis(k))
	var lo := PLANE_OFF * _cur_hs
	var hi := (PLANE_OFF + PLANE_SZ) * _cur_hs
	if uj < lo or uj > hi or uk < lo or uk > hi:
		return {}
	return {"t": o.distance_to(hit), "point": hit}

func _try_ring(o: Vector3, d: Vector3, i: int) -> Dictionary:
	var n := _world_axis(i)
	var hit = _ray_plane(o, d, global_position, n)
	if hit == null:
		return {}
	var off: Vector3 = hit - global_position
	if absf(off.length() - RING_R * _cur_hs) > RING_TOL * _cur_hs:
		return {}
	return {"t": o.distance_to(hit), "angle": _ring_angle(off, i)}

func _is_road_node() -> bool:
	return target != null and target.has_method("forward")

## Ring picking around an arbitrary world axis (the road tangent), for banking.
func _try_axis_ring(o: Vector3, d: Vector3, axis: Vector3) -> Dictionary:
	var hit = _ray_plane(o, d, global_position, axis)
	if hit == null:
		return {}
	var off: Vector3 = hit - global_position
	if absf(off.length() - RING_R * _cur_hs) > RING_TOL * _cur_hs:
		return {}
	return {"t": o.distance_to(hit), "angle": _axis_ring_angle(off, axis)}

## Angle of an in-plane offset around an arbitrary axis, in a stable (u, v) frame.
func _axis_ring_angle(off: Vector3, axis: Vector3) -> float:
	var u := _perp(axis)
	var v := axis.cross(u)
	return atan2(off.dot(v), off.dot(u))

## A deterministic unit vector perpendicular to `a`.
func _perp(a: Vector3) -> Vector3:
	var r := Vector3.UP if absf(a.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	return a.cross(r).normalized()

## Closest approach between mouse ray (o,d unit) and the line (g, u unit).
## Returns {t, s, dist} or {} if (near) parallel.
func _ray_line_closest(o: Vector3, d: Vector3, g: Vector3, u: Vector3) -> Dictionary:
	var b := d.dot(u)
	var denom := b * b - 1.0
	if absf(denom) < 1e-6:
		return {}
	var r := o - g
	var dr := d.dot(r)
	var ur := u.dot(r)
	var s := (b * dr - ur) / denom
	var t := s * b - dr
	var pc := o + d * t
	var qc := g + u * s
	return {"t": t, "s": s, "dist": pc.distance_to(qc)}

func _ray_line_s(o: Vector3, d: Vector3, g: Vector3, u: Vector3) -> float:
	var res := _ray_line_closest(o, d, g, u)
	return res.get("s", _drag_s0)

## Ray-plane intersection; returns the world hit point or null.
func _ray_plane(o: Vector3, d: Vector3, g: Vector3, n: Vector3):
	var dn := d.dot(n)
	if absf(dn) < 1e-6:
		return null
	var t := (g - o).dot(n) / dn
	if t <= 0.0:
		return null
	return o + d * t

## Angle of an in-plane offset around axis i (for ring rotation).
func _ring_angle(off: Vector3, i: int) -> float:
	match i:
		0: return atan2(off.z, off.y)
		1: return atan2(off.x, off.z)
		_: return atan2(off.y, off.x)

func _world_axis(i: int) -> Vector3:
	match i:
		0: return Vector3.RIGHT
		1: return Vector3.UP
		_: return Vector3(0.0, 0.0, 1.0)

## Axis direction used for translate (world) and scale (item-local) drags.
func _axis_dir(i: int) -> Vector3:
	if mode == Mode.SCALE and target:
		var b: Basis = target.global_transform.basis.orthonormalized()
		match i:
			0: return b.x
			1: return b.y
			_: return b.z
	return _world_axis(i)

# ---------------------------------------------------------------------------
# Handle visuals (rebuilt on mode / target change; scaled in _process)

func _rebuild_handles() -> void:
	for c in _handles.get_children():
		c.queue_free()
	match mode:
		Mode.TRANSLATE:
			for i in 3:
				_handles.add_child(_axis_line(i, AXIS_LEN, true))
				_handles.add_child(_plane_quad(i))
		Mode.ROTATE:
			if _is_road_node():
				_handles.add_child(_axis_ring(target.forward(), COL_HI))
			else:
				for i in 3:
					_handles.add_child(_ring(i))
		Mode.SCALE:
			if not _scalable():
				return
			for i in 3:
				_handles.add_child(_axis_line(i, AXIS_LEN, true))
			_handles.add_child(_center_cube())

func _axis_line(i: int, length: float, tip: bool) -> Node3D:
	var u := _local_axis(i)
	var col := _axis_color(i)
	var holder := Node3D.new()
	var line := _lines(PackedVector3Array([Vector3.ZERO, u * length]), col)
	holder.add_child(line)
	if tip:
		var cube := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * 0.12
		cube.mesh = bm
		cube.position = u * length
		cube.material_override = _unshaded(col)
		holder.add_child(cube)
	return holder

func _plane_quad(i: int) -> MeshInstance3D:
	var j := (i + 1) % 3
	var k := (i + 2) % 3
	var uj := _local_axis(j)
	var uk := _local_axis(k)
	var lo := PLANE_OFF
	var hi := PLANE_OFF + PLANE_SZ
	var p0 := uj * lo + uk * lo
	var p1 := uj * hi + uk * lo
	var p2 := uj * hi + uk * hi
	var p3 := uj * lo + uk * hi
	var verts := PackedVector3Array([p0, p1, p2, p0, p2, p3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := _unshaded(_axis_color(i))
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.35
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

func _ring(i: int) -> MeshInstance3D:
	var pts := PackedVector3Array()
	var n := 49
	for step in n:
		var a := TAU * float(step) / float(n - 1)
		var c := cos(a) * RING_R
		var s := sin(a) * RING_R
		match i:
			0: pts.append(Vector3(0.0, c, s))
			1: pts.append(Vector3(c, 0.0, s))
			_: pts.append(Vector3(c, s, 0.0))
	return _line_strip(pts, _axis_color(i))

# A roll ring in the plane perpendicular to `axis` (the road tangent). The
# handles node inherits the gizmo's identity basis in ROTATE mode, so building it
# from world-space axes places it correctly.
func _axis_ring(axis: Vector3, col: Color) -> MeshInstance3D:
	var u := _perp(axis)
	var v := axis.cross(u)
	var pts := PackedVector3Array()
	var n := 49
	for step in n:
		var a := TAU * float(step) / float(n - 1)
		pts.append((u * cos(a) + v * sin(a)) * RING_R)
	return _line_strip(pts, col)

func _center_cube() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * 0.16
	mi.mesh = bm
	mi.material_override = _unshaded(COL_UNI)
	return mi

func _local_axis(i: int) -> Vector3:
	match i:
		0: return Vector3.RIGHT
		1: return Vector3.UP
		_: return Vector3(0.0, 0.0, 1.0)

func _axis_color(i: int) -> Color:
	match i:
		0: return COL_X
		1: return COL_Y
		_: return COL_Z

func _lines(points: PackedVector3Array, col: Color) -> MeshInstance3D:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = points
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	mesh.surface_set_material(0, _unshaded(col))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

func _line_strip(points: PackedVector3Array, col: Color) -> MeshInstance3D:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = points
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arr)
	mesh.surface_set_material(0, _unshaded(col))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

func _unshaded(col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.no_depth_test = true
	return mat
