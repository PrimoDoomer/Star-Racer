extends Node3D

## A draggable sphere marking one control node of a selected `road` EditorItem.
##
## It duck-types the gizmo target API (position + get_size + supports_scale +
## rebuild), so the existing translate gizmo moves a node exactly like it moves a
## primitive. Road primitives in the editor are kept at identity transform, so a
## node's world position equals its local `position` — the gizmo writes world
## coordinates straight into the node dict.

class_name RoadNodeHandle

const COLOR := Color(1.0, 0.82, 0.25)
const COLOR_SEL := Color(0.45, 0.95, 1.0)
# Own picking layer (one bit above EditorItem's), so handles are raycast first.
const HANDLE_LAYER := EditorItem.PICK_LAYER << 1

var road: EditorItem = null
var index: int = 0
var data: Dictionary = {}        # the node dict, shared with road.data["nodes"][index]

var _radius := 4.0
var _mesh: MeshInstance3D = null

func setup(road_item: EditorItem, node_index: int, radius: float) -> void:
	road = road_item
	index = node_index
	data = road.data["nodes"][node_index]
	_radius = radius
	_rebuild_visual()
	position = _data_pos()

func _data_pos() -> Vector3:
	var p = data.get("position", [0.0, 0.0, 0.0])
	return Vector3(float(p[0]), float(p[1]), float(p[2]))

func _rebuild_visual() -> void:
	for c in get_children():
		c.queue_free()

	_mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = _radius
	sm.height = _radius * 2.0
	_mesh.mesh = sm
	_mesh.material_override = _material(COLOR)
	add_child(_mesh)

	var body := StaticBody3D.new()
	body.collision_layer = HANDLE_LAYER
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = _radius
	cs.shape = shape
	body.add_child(cs)
	add_child(body)

func _material(col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.no_depth_test = true
	return mat

func set_selected(on: bool) -> void:
	if _mesh:
		_mesh.material_override = _material(COLOR_SEL if on else COLOR)

# Road tangent at this node (world space; roads are identity), used as the axis
# of the gizmo's banking ring. Central difference of the neighbouring nodes.
func forward() -> Vector3:
	if not is_instance_valid(road):
		return Vector3(0, 0, -1)
	var nodes: Array = road.data.get("nodes", [])
	var n := nodes.size()
	if n < 2:
		return Vector3(0, 0, -1)
	var a: Array = nodes[maxi(index - 1, 0)].get("position", [0, 0, 0])
	var b: Array = nodes[mini(index + 1, n - 1)].get("position", [0, 0, 0])
	var dir := Vector3(float(b[0]) - float(a[0]), float(b[1]) - float(a[1]), float(b[2]) - float(a[2]))
	return dir.normalized() if dir.length() > 1e-4 else Vector3(0, 0, -1)

# --- gizmo target API (translate + banking ring) ---------------------------

func get_size() -> Vector3:
	return Vector3.ONE

func supports_scale() -> bool:
	return false

func sync_transform_to_data() -> void:
	data["position"] = [position.x, position.y, position.z]

## Called after a gizmo drag (or an inspector edit): the node dict already holds
## the new position, so snap the sphere to it and remesh the parent road.
func rebuild() -> void:
	position = _data_pos()
	if is_instance_valid(road):
		road.rebuild()
