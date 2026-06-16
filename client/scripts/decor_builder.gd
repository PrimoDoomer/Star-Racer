extends RefCounted

## Procedural neon / future / star themed decor pieces, built in code (same
## approach as the procedural pads in track_loader.gd). Every piece is built
## centred on the local origin and bounded by `size` (x = width, y = height,
## z = depth), so it lines up with the cheap box proxy the loader/server build.
##
## Pieces are emissive to read against the dark neon sky. They are purely visual:
## collision is the single box proxy authored per decor element.
##
## `model` keywords: neon_arch, light_strip, star_pillar, hologram_ring, beacon.
## (A `res://….glb` `model` is loaded directly by track_loader instead.)
## Referenced via preload in track_loader.gd (no global class_name needed).

const DEFAULT_COLOR := Color(0.35, 0.75, 1.0)  # cool neon cyan

static func build(keyword: String, size: Vector3, color: Color = DEFAULT_COLOR) -> Node3D:
	match keyword:
		"neon_arch":     return _neon_arch(size, color)
		"light_strip":   return _light_strip(size, color)
		"star_pillar":   return _star_pillar(size, color)
		"hologram_ring": return _hologram_ring(size, color)
		"beacon":        return _beacon(size, color)
		_:               return _fallback(size, color)


static func _emissive(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	m.roughness = 0.4
	return m

static func _dark(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col * 0.25
	m.metallic = 0.6
	m.roughness = 0.5
	return m

static func _box(size: Vector3, mat: StandardMaterial3D, pos: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	return mi

static func _cyl(radius: float, height: float, mat: StandardMaterial3D, pos: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	return mi


# A glowing gate spanning the track: two posts + a top lintel. Usually authored
# `collide:false` so cars pass under.
static func _neon_arch(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var w := size.x
	var h := size.y
	var d := maxf(size.z, 1.0)
	var post := maxf(w * 0.06, 0.5)
	var glow := _emissive(color, 3.0)
	var frame := _dark(color)
	# Posts (full height, centred on origin).
	root.add_child(_box(Vector3(post, h, d), frame, Vector3(-(w * 0.5 - post * 0.5), 0.0, 0.0)))
	root.add_child(_box(Vector3(post, h, d), frame, Vector3(w * 0.5 - post * 0.5, 0.0, 0.0)))
	# Glowing inner edges of the posts.
	root.add_child(_box(Vector3(post * 0.3, h * 0.92, d * 1.02), glow, Vector3(-(w * 0.5 - post), 0.0, 0.0)))
	root.add_child(_box(Vector3(post * 0.3, h * 0.92, d * 1.02), glow, Vector3(w * 0.5 - post, 0.0, 0.0)))
	# Lintel + glowing underside.
	root.add_child(_box(Vector3(w, post, d), frame, Vector3(0.0, h * 0.5 - post * 0.5, 0.0)))
	root.add_child(_box(Vector3(w - post * 2.0, post * 0.3, d * 1.02), glow, Vector3(0.0, h * 0.5 - post, 0.0)))
	return root


# A low emissive light bar with evenly spaced lamp blocks — track-edge lighting.
static func _light_strip(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var w := size.x
	var h := maxf(size.y, 0.3)
	var d := maxf(size.z, 0.3)
	root.add_child(_box(Vector3(w, h * 0.4, d), _dark(color), Vector3(0.0, -h * 0.3, 0.0)))
	var lamps := maxi(int(w / 2.0), 3)
	var glow := _emissive(color, 4.0)
	for i in lamps:
		var fx := -0.5 + (float(i) + 0.5) / float(lamps)
		root.add_child(_box(Vector3(w / float(lamps) * 0.6, h * 0.5, d * 0.6), glow, Vector3(fx * w, h * 0.1, 0.0)))
	return root


# Tall tapered obelisk: dark body with a glowing crown and vertical seam.
static func _star_pillar(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var w := maxf(size.x, 0.5)
	var h := size.y
	var d := maxf(size.z, 0.5)
	root.add_child(_box(Vector3(w, h, d), _dark(color)))
	var glow := _emissive(color, 3.5)
	# Vertical seams on all four faces.
	root.add_child(_box(Vector3(w * 1.02, h * 0.9, d * 0.12), glow))
	root.add_child(_box(Vector3(w * 0.12, h * 0.9, d * 1.02), glow))
	# Glowing crown near the top.
	root.add_child(_box(Vector3(w * 1.12, h * 0.06, d * 1.12), glow, Vector3(0.0, h * 0.42, 0.0)))
	return root


# A floating glowing ring (hologram), facing along Z.
static func _hologram_ring(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var radius := minf(size.x, size.y) * 0.5
	var torus := TorusMesh.new()
	torus.inner_radius = radius * 0.82
	torus.outer_radius = radius
	var mi := MeshInstance3D.new()
	mi.mesh = torus
	mi.material_override = _emissive(color, 4.0)
	mi.rotation = Vector3(PI * 0.5, 0.0, 0.0)  # stand it upright, facing Z
	root.add_child(mi)
	# A faint inner disc.
	var disc := _cyl(radius * 0.8, 0.05, _emissive(color * 0.6, 1.2))
	disc.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	root.add_child(disc)
	return root


# A slender beacon: dark mast with a bright pulsing-looking emissive tip.
static func _beacon(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var h := size.y
	var r := maxf(minf(size.x, size.z) * 0.5, 0.3)
	root.add_child(_cyl(r * 0.4, h * 0.9, _dark(color), Vector3(0.0, -h * 0.05, 0.0)))
	var tip := SphereMesh.new()
	tip.radius = r
	tip.height = r * 2.0
	var mi := MeshInstance3D.new()
	mi.mesh = tip
	mi.material_override = _emissive(color, 5.0)
	mi.position = Vector3(0.0, h * 0.5 - r, 0.0)
	root.add_child(mi)
	return root


# Unknown keyword (or empty): a simple emissive block so nothing is invisible.
static func _fallback(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	root.add_child(_box(size, _emissive(color, 1.5)))
	return root
