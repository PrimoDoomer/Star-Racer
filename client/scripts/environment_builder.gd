extends RefCounted

## Builds a level's lighting/sky environment in code from its descriptor — no
## textures, no per-track scene. The track JSON carries an `environment` value
## (a preset name string, or `{ "preset": "...", ...overrides }`) and the client
## assembles a WorldEnvironment + lights (+ optional ceiling) here. Same
## data-driven spirit as decor_builder.gd: the game ships a fixed collection of
## presets; a level just picks one.
##
## Presets: living_room (warm enclosed interior), night (dark, open), studio
## (neutral, the default).
## Referenced via preload in game.gd (no global class_name needed).

static func build(def: Variant) -> Node3D:
	match _preset_name(def):
		"living_room": return _living_room()
		"night":       return _night()
		_:             return _studio()


static func _preset_name(def: Variant) -> String:
	if def is String:
		return def
	if def is Dictionary:
		return String((def as Dictionary).get("preset", "studio"))
	return "studio"


# --- assembly helpers -------------------------------------------------------

static func _root_with_env(bg: Color, ambient: Color, ambient_energy: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Environment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = bg
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient
	env.ambient_light_energy = ambient_energy
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# Subtle bloom, gated above 1.0 so only emissive/bright surfaces (boost pads,
	# neon decor, lamps) glow — flat-coloured walls stay crisp.
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.0
	var wenv := WorldEnvironment.new()
	wenv.name = "WorldEnvironment"
	wenv.environment = env
	root.add_child(wenv)
	return root

static func _dir_light(name: String, euler_deg: Vector3, color: Color, energy: float, shadow: bool) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.name = name
	l.rotation_degrees = euler_deg
	l.light_color = color
	l.light_energy = energy
	l.shadow_enabled = shadow
	return l

static func _omni(name: String, pos: Vector3, color: Color, energy: float, range_: float) -> OmniLight3D:
	var o := OmniLight3D.new()
	o.name = name
	o.position = pos
	o.light_color = color
	o.light_energy = energy
	o.omni_range = range_
	o.omni_attenuation = 1.5
	return o

# A flat overhead slab so an interior reads as enclosed (camera stays low, no
# collision needed). Sized generously to cover the largest rooms.
static func _ceiling(y: float, col: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1200.0, 10.0, 1200.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.95
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Ceiling"
	mi.mesh = mesh
	mi.position = Vector3(0.0, y, 0.0)
	return mi


# --- presets ----------------------------------------------------------------

# Warm, enclosed living room: cosy ambient, key/fill + a ceiling fixture and a
# corner lamp glow, capped by a ceiling slab.
static func _living_room() -> Node3D:
	var root := _root_with_env(Color(0.14, 0.12, 0.10), Color(0.62, 0.55, 0.46), 0.6)
	root.add_child(_dir_light("KeyLight", Vector3(-58.0, 32.0, 0.0), Color(1.0, 0.95, 0.85), 1.25, true))
	root.add_child(_dir_light("FillLight", Vector3(-46.0, -150.0, 0.0), Color(0.78, 0.82, 0.95), 0.5, false))
	root.add_child(_omni("CeilingLight", Vector3(0.0, 260.0, 0.0), Color(1.0, 0.92, 0.74), 1.6, 760.0))
	root.add_child(_omni("LampLight", Vector3(-205.0, 135.0, -200.0), Color(1.0, 0.86, 0.6), 2.2, 320.0))
	root.add_child(_ceiling(305.0, Color(0.88, 0.85, 0.8)))
	return root

# Dark, open environment for the legacy circuits (cool night, no ceiling).
static func _night() -> Node3D:
	var root := _root_with_env(Color(0.03, 0.05, 0.11), Color(0.5, 0.56, 0.72), 0.55)
	root.add_child(_dir_light("KeyLight", Vector3(-52.0, 28.0, 0.0), Color(0.86, 0.9, 1.0), 1.3, true))
	root.add_child(_dir_light("FillLight", Vector3(-40.0, -160.0, 0.0), Color(0.6, 0.66, 0.85), 0.45, false))
	return root

# Neutral, evenly lit default.
static func _studio() -> Node3D:
	var root := _root_with_env(Color(0.12, 0.12, 0.13), Color(0.7, 0.72, 0.78), 0.6)
	root.add_child(_dir_light("KeyLight", Vector3(-55.0, 30.0, 0.0), Color(1.0, 0.98, 0.94), 1.2, true))
	root.add_child(_dir_light("FillLight", Vector3(-45.0, -150.0, 0.0), Color(0.82, 0.85, 0.95), 0.5, false))
	return root
