# A soft contact shadow under a car: a flat dark ellipse that raycasts down to the
# ground each tick, lies on the surface (conforming to ramps/banks via the hit
# normal, pointing along the car), and fades out as the car lifts off (jumps). A
# cheap, always-visible "toy" shadow that works in every renderer (unlike Decals,
# which the web/Compatibility renderer can't do). Added as a child of each car
# (player, opponents) — see player.gd / game.gd.
extends MeshInstance3D
class_name BlobShadow

const WIDTH := 3.2          # across the car (collider is 2.6 wide)
const LENGTH := 5.4         # along the car (collider is 4.8 long)
const MAX_DROP := 8.0       # how far down to look for ground
const LIFT := 0.06          # sit just above the surface (avoid z-fighting)
const FADE_HEIGHT := 6.0    # fully gone once the car is this high off the ground
const BASE_ALPHA := 0.5

# The round alpha falloff is identical for every car, so build it once and share.
static var _tex: GradientTexture2D = null

var _car: Node3D = null      # the car to follow (defaults to the parent)
var _exclude: RID            # the car's physics body to ignore in the down-ray
var _mat: StandardMaterial3D = null

func setup(car: Node3D, exclude_rid: RID = RID()) -> void:
	_car = car
	_exclude = exclude_rid

func _ready() -> void:
	if _car == null:
		_car = get_parent() as Node3D
	top_level = true  # we place ourselves in world space, ignoring the car's transform
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var plane := PlaneMesh.new()
	plane.size = Vector2(WIDTH, LENGTH)
	mesh = plane
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(0.0, 0.0, 0.0, BASE_ALPHA)
	_mat.albedo_texture = _shadow_texture()
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED  # an overlay, not a depth occluder
	material_override = _mat
	visible = false

static func _shadow_texture() -> GradientTexture2D:
	if _tex != null:
		return _tex
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))   # opaque core
	grad.set_color(1, Color(1, 1, 1, 0))   # transparent rim
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	_tex = GradientTexture2D.new()
	_tex.gradient = grad
	_tex.fill = GradientTexture2D.FILL_RADIAL
	_tex.fill_from = Vector2(0.5, 0.5)
	_tex.fill_to = Vector2(1.0, 0.5)       # radius = half the texture → circular falloff
	_tex.width = 128
	_tex.height = 128
	return _tex

func _physics_process(_delta: float) -> void:
	if _car == null or not _car.visible:
		visible = false
		return
	var origin := _car.global_position + Vector3(0.0, 0.5, 0.0)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + Vector3(0.0, -MAX_DROP, 0.0))
	if _exclude != RID():
		q.exclude = [_exclude]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		visible = false
		return

	var p: Vector3 = hit["position"]
	var n: Vector3 = (hit["normal"] as Vector3).normalized()
	# Lay flat on the surface, the ellipse pointing along the car's heading.
	var car_fwd := -_car.global_transform.basis.z
	var fwd := car_fwd - n * car_fwd.dot(n)  # project heading onto the surface plane
	if fwd.length() < 1e-3:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var right := n.cross(fwd).normalized()
	global_transform = Transform3D(Basis(right, n, fwd), p + n * LIFT)

	# Fade as the car climbs off the ground (a real contact shadow shrinks away).
	var height := _car.global_position.y - p.y
	_mat.albedo_color.a = BASE_ALPHA * clampf(1.0 - height / FADE_HEIGHT, 0.0, 1.0)
	visible = true
