extends RefCounted

## Procedural low-poly "toy / household" decor, built in code (same approach as
## the procedural pads in track_loader.gd). Pocket Racing is set indoors at toy
## scale: the cars are little toys and the props are giant everyday objects, so
## every piece is a familiar desk / living-room object scaled up to dwarf a car.
##
## Every piece is built centred on the local origin and bounded by `size`
## (x = width, y = height, z = depth) so it lines up with the cheap box proxy the
## loader/server build. Pieces are matte, flat-shaded plastic/painted toys (no
## neon); the lamp is the one emissive piece, used as a warm light accent.
##
## `model` keywords:
##   structural — arch, ring, rail
##   props      — book, book_stack, block, dice, mug, plant, eraser, ball,
##                crayon, pencil, lamp, sofa, table, rug
## Legacy keywords from the old space theme (neon_arch, star_pillar, beacon,
## hologram_ring, light_strip) are aliased onto the nearest toy piece so existing
## tracks retheme automatically.
## (A `res://….glb` `model` is loaded directly by track_loader instead.)
## Referenced via preload in track_loader.gd (no global class_name needed).

const DEFAULT_COLOR := Color(0.85, 0.55, 0.35)  # warm wooden default

static func build(keyword: String, size: Vector3, color: Color = DEFAULT_COLOR) -> Node3D:
	match keyword:
		# Structural pieces (also drive the legacy track decor via the aliases).
		"arch", "neon_arch":        return _arch(size, color)
		"ring", "hologram_ring":    return _ring(size, color)
		"rail", "light_strip":      return _rail(size, color)
		# Tall props (legacy pillar/beacon retheme onto these).
		"pencil", "star_pillar":    return _pencil(size, color)
		"lamp", "beacon":           return _lamp(size, color)
		"crayon":                   return _crayon(size, color)
		# Household props.
		"book":                     return _book(size, color)
		"book_stack":               return _book_stack(size, color)
		"block":                    return _block(size, color)
		"dice":                     return _dice(size, color)
		"mug":                      return _mug(size, color)
		"plant":                    return _plant(size, color)
		"eraser":                   return _eraser(size, color)
		"ball":                     return _ball(size, color)
		"sofa":                     return _sofa(size, color)
		"table":                    return _table(size, color)
		"rug":                      return _rug(size, color)
		# Plain painted box: room floor / walls / baseboards (collidable surfaces).
		"panel":                    return _fallback(size, color)
		_:                          return _fallback(size, color)


# ---------------------------------------------------------------------------
# Materials + primitive helpers.

static func _paint(col: Color, rough: float = 0.7) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = 0.0
	return m

static func _metal(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.35
	m.metallic = 0.8
	return m

static func _emissive(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	m.roughness = 0.4
	return m

static func _box(size: Vector3, mat: StandardMaterial3D, pos: Vector3 = Vector3.ZERO, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	return mi

static func _cyl(radius: float, height: float, mat: StandardMaterial3D, pos: Vector3 = Vector3.ZERO, sides: int = 16, top_radius: float = -1.0) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius if top_radius < 0.0 else top_radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = sides
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	return mi

static func _cone(radius: float, height: float, mat: StandardMaterial3D, pos: Vector3 = Vector3.ZERO, sides: int = 16) -> MeshInstance3D:
	return _cyl(radius, height, mat, pos, sides, 0.0)

static func _sphere(radius: float, mat: StandardMaterial3D, pos: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	return mi

static func _torus(inner: float, outer: float, mat: StandardMaterial3D, pos: Vector3 = Vector3.ZERO, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner
	mesh.outer_radius = outer
	mesh.rings = 18
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	return mi

# Shift a colour's hue a little, keeping it bright — used to vary stacked items.
static func _hue_shift(col: Color, delta: float) -> Color:
	var c := col
	c.h = fposmod(c.h + delta, 1.0)
	c.s = clampf(c.s + 0.05, 0.0, 1.0)
	return c


# ---------------------------------------------------------------------------
# Structural pieces.

# A toy plastic gate spanning the track: two posts + a top lintel, matte and
# brightly painted (no neon). Usually authored `collide:false`.
static func _arch(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var w := size.x
	var h := size.y
	var d := maxf(size.z, 1.0)
	var post := maxf(w * 0.07, 0.6)
	var body := _paint(color, 0.6)
	var trim := _paint(Color(0.96, 0.97, 0.98), 0.5)
	# Posts (full height, centred on origin).
	root.add_child(_box(Vector3(post, h, d), body, Vector3(-(w * 0.5 - post * 0.5), 0.0, 0.0)))
	root.add_child(_box(Vector3(post, h, d), body, Vector3(w * 0.5 - post * 0.5, 0.0, 0.0)))
	# Rounded caps on the posts.
	root.add_child(_sphere(post * 0.62, trim, Vector3(-(w * 0.5 - post * 0.5), h * 0.5, 0.0)))
	root.add_child(_sphere(post * 0.62, trim, Vector3(w * 0.5 - post * 0.5, h * 0.5, 0.0)))
	# Lintel + a white accent stripe under it.
	root.add_child(_box(Vector3(w, post, d), body, Vector3(0.0, h * 0.5 - post * 0.5, 0.0)))
	root.add_child(_box(Vector3(w - post * 2.0, post * 0.34, d * 1.04), trim, Vector3(0.0, h * 0.5 - post, 0.0)))
	return root


# A wooden / plastic hoop (torus), standing upright facing Z. Non-emissive.
static func _ring(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var radius := minf(size.x, size.y) * 0.5
	root.add_child(_torus(radius * 0.84, radius, _paint(color, 0.6), Vector3.ZERO, Vector3(PI * 0.5, 0.0, 0.0)))
	return root


# A low track-edge curb: a matte bar with evenly spaced rounded studs on top
# (think a toy-track border). Two-tone.
static func _rail(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var w := size.x
	var h := maxf(size.y, 0.3)
	var d := maxf(size.z, 0.3)
	root.add_child(_box(Vector3(w, h * 0.5, d), _paint(color * 0.85, 0.6), Vector3(0.0, -h * 0.25, 0.0)))
	var studs := clampi(int(w / 3.0), 3, 40)
	var stud_mat := _paint(Color(0.96, 0.97, 0.98), 0.5)
	for i in studs:
		var fx := -0.5 + (float(i) + 0.5) / float(studs)
		root.add_child(_sphere(minf(d, h) * 0.34, stud_mat, Vector3(fx * w, h * 0.1, 0.0)))
	return root


# ---------------------------------------------------------------------------
# Tall props.

# A giant hexagonal pencil standing upright, sharpened tip up.
static func _pencil(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var h := size.y
	var r := minf(size.x, size.z) * 0.5
	var bottom := -h * 0.5
	var body_h := h * 0.7
	var body := _paint(color if color != DEFAULT_COLOR else Color(0.95, 0.78, 0.18), 0.55)  # default: pencil yellow
	root.add_child(_cyl(r, body_h, body, Vector3(0.0, bottom + body_h * 0.5, 0.0), 6))
	# Painted band, bare wood cone, then the dark graphite tip.
	var band_y := bottom + body_h
	root.add_child(_cyl(r * 1.02, h * 0.04, _metal(Color(0.85, 0.86, 0.9)), Vector3(0.0, band_y, 0.0), 6))
	var wood_h := h * 0.18
	root.add_child(_cone(r * 0.98, wood_h, _paint(Color(0.86, 0.66, 0.4), 0.6), Vector3(0.0, band_y + wood_h * 0.5, 0.0), 6))
	root.add_child(_cone(r * 0.34, h * 0.06, _paint(Color(0.12, 0.12, 0.14), 0.5), Vector3(0.0, band_y + wood_h * 0.92, 0.0), 6))
	return root


# A giant crayon: rounded body with a paper wrap band and a blunt tip.
static func _crayon(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var h := size.y
	var r := minf(size.x, size.z) * 0.5
	var bottom := -h * 0.5
	var body_h := h * 0.74
	var col := color if color != DEFAULT_COLOR else Color(0.86, 0.22, 0.27)
	root.add_child(_cyl(r, body_h, _paint(col, 0.55), Vector3(0.0, bottom + body_h * 0.5, 0.0), 18))
	# Paper wrap (lighter band) around the middle.
	root.add_child(_cyl(r * 1.04, h * 0.22, _paint(col.lightened(0.35), 0.6), Vector3(0.0, bottom + body_h * 0.5, 0.0), 18))
	# Blunt conical tip.
	root.add_child(_cone(r, h * 0.26, _paint(col, 0.55), Vector3(0.0, bottom + body_h + h * 0.13, 0.0), 18))
	return root


# A small desk lamp: weighted base, thin stem, conical shade and a glowing bulb.
# The one emissive prop — drop it in for a warm pool of light.
static func _lamp(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var h := size.y
	var r := minf(size.x, size.z) * 0.5
	var bottom := -h * 0.5
	var dark := _paint(Color(0.16, 0.17, 0.2), 0.4)
	# Base + stem.
	root.add_child(_cyl(r * 0.7, h * 0.06, dark, Vector3(0.0, bottom + h * 0.03, 0.0), 20))
	root.add_child(_cyl(r * 0.12, h * 0.6, dark, Vector3(0.0, bottom + h * 0.33, 0.0), 10))
	# Shade (wide opening downward) + glowing bulb just inside it.
	var shade_h := h * 0.34
	var shade_y := bottom + h - shade_h * 0.5
	var shade := _cyl(r, shade_h, _paint(color, 0.5), Vector3(0.0, shade_y, 0.0), 22, r * 0.45)
	shade.rotation = Vector3(PI, 0.0, 0.0)  # flip so the wide rim faces down
	root.add_child(shade)
	root.add_child(_sphere(r * 0.4, _emissive(Color(1.0, 0.93, 0.7), 4.5), Vector3(0.0, shade_y - shade_h * 0.2, 0.0)))
	return root


# ---------------------------------------------------------------------------
# Household props.

# A single closed book lying flat: hard cover wrapping a cream page block.
static func _book(size: Vector3, color: Color) -> Node3D:
	return _book_at(size, color, Node3D.new())

# Builds one book's meshes (cover + pages + spine) into `root`, centred, and
# returns it. Bound by `size` (x = width, y = thickness, z = depth/height).
static func _book_at(size: Vector3, color: Color, root: Node3D) -> Node3D:
	var w := size.x
	var t := maxf(size.y, 0.4)
	var d := size.z
	var cover := _paint(color, 0.55)
	var pages := _paint(Color(0.93, 0.91, 0.83), 0.8)
	var cover_t := t * 0.14
	# Page block, slightly inset from the cover on three sides.
	root.add_child(_box(Vector3(w * 0.94, t - cover_t * 2.0, d * 0.96), pages, Vector3(w * 0.02, 0.0, 0.0)))
	# Top + bottom covers.
	root.add_child(_box(Vector3(w, cover_t, d), cover, Vector3(0.0, t * 0.5 - cover_t * 0.5, 0.0)))
	root.add_child(_box(Vector3(w, cover_t, d), cover, Vector3(0.0, -(t * 0.5 - cover_t * 0.5), 0.0)))
	# Spine down the -x edge.
	root.add_child(_box(Vector3(cover_t, t, d), cover, Vector3(-(w * 0.5 - cover_t * 0.5), 0.0, 0.0)))
	return root

# A few books stacked with slight offsets and varied cover colours.
static func _book_stack(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var count := clampi(int(size.y / maxf(size.x, size.z) * 3.0) + 2, 2, 5)
	var book_t := size.y / float(count)
	for i in count:
		var f := float(i)
		var book := Node3D.new()
		var bw := size.x * (0.82 + 0.18 * fposmod(f * 0.37, 1.0))
		var bd := size.z * (0.82 + 0.18 * fposmod(f * 0.61 + 0.2, 1.0))
		_book_at(Vector3(bw, book_t * 0.96, bd), _hue_shift(color, f * 0.21), book)
		book.position = Vector3(size.x * (fposmod(f * 0.5, 1.0) - 0.5) * 0.12,
			-size.y * 0.5 + book_t * (f + 0.5), size.z * (fposmod(f * 0.3, 1.0) - 0.5) * 0.1)
		book.rotation.y = (fposmod(f * 0.27, 1.0) - 0.5) * 0.4
		root.add_child(book)
	return root


# A toy building block: a bright cube with studs on top.
static func _block(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var stud_h := size.y * 0.16
	var body_h := size.y - stud_h
	var mat := _paint(color if color != DEFAULT_COLOR else Color(0.86, 0.21, 0.24), 0.5)
	root.add_child(_box(Vector3(size.x, body_h, size.z), mat, Vector3(0.0, -size.y * 0.5 + body_h * 0.5, 0.0)))
	var stud_r := minf(size.x, size.z) * 0.18
	var stud_y := -size.y * 0.5 + body_h + stud_h * 0.5
	for sx in [-0.25, 0.25]:
		for sz in [-0.25, 0.25]:
			root.add_child(_cyl(stud_r, stud_h, mat, Vector3(sx * size.x, stud_y, sz * size.z), 14))
	return root


# A die: a white rounded cube with dark pips (5 on top, 2 on the +z face).
static func _dice(size: Vector3, _color: Color) -> Node3D:
	var root := Node3D.new()
	var s := minf(minf(size.x, size.y), size.z)
	root.add_child(_box(Vector3(s, s, s), _paint(Color(0.95, 0.95, 0.93), 0.45)))
	var pip := _paint(Color(0.1, 0.1, 0.12), 0.4)
	var pr := s * 0.08
	var o := s * 0.27
	# Five on the top face (y+).
	for p in [Vector3(-o, 0, -o), Vector3(o, 0, o), Vector3(0, 0, 0), Vector3(-o, 0, o), Vector3(o, 0, -o)]:
		root.add_child(_sphere(pr, pip, Vector3(p.x, s * 0.5, p.z)))
	# Two on the front face (z+).
	for p in [Vector3(-o, o, 0), Vector3(o, -o, 0)]:
		root.add_child(_sphere(pr, pip, Vector3(p.x, p.y, s * 0.5)))
	return root


# A mug: a thick cylinder body with a torus handle on one side.
static func _mug(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var r := minf(size.x, size.z) * 0.42
	var h := size.y
	var mat := _paint(color if color != DEFAULT_COLOR else Color(0.3, 0.55, 0.75), 0.45)
	root.add_child(_cyl(r, h, mat, Vector3(0.0, 0.0, 0.0), 22))
	# A darker rim + a recessed "coffee" top so it doesn't read as solid.
	root.add_child(_cyl(r * 0.82, h * 0.06, _paint(Color(0.18, 0.1, 0.06), 0.5), Vector3(0.0, h * 0.46, 0.0), 22))
	# Handle (torus) on the +x side, in the vertical plane.
	root.add_child(_torus(r * 0.18, r * 0.5, mat, Vector3(r * 1.02, 0.0, 0.0), Vector3(0.0, 0.0, PI * 0.5)))
	return root


# A potted plant: a tapered pot with a cluster of leafy spheres.
static func _plant(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var h := size.y
	var r := minf(size.x, size.z) * 0.5
	var pot_h := h * 0.4
	var pot := _paint(Color(0.78, 0.4, 0.28), 0.7)  # terracotta
	root.add_child(_cyl(r * 0.78, pot_h, pot, Vector3(0.0, -h * 0.5 + pot_h * 0.5, 0.0), 18, r * 0.55))
	root.add_child(_cyl(r * 0.8, pot_h * 0.12, pot.duplicate(), Vector3(0.0, -h * 0.5 + pot_h, 0.0), 18))
	var leaf := _paint(color if color != DEFAULT_COLOR else Color(0.26, 0.55, 0.27), 0.6)
	var cy := -h * 0.5 + pot_h
	# A few overlapping leaf blobs forming a bushy crown.
	for p in [Vector3(0, h * 0.34, 0), Vector3(-r * 0.5, h * 0.18, r * 0.2), Vector3(r * 0.5, h * 0.2, -r * 0.2), Vector3(r * 0.15, h * 0.12, r * 0.5), Vector3(-r * 0.2, h * 0.12, -r * 0.5)]:
		root.add_child(_sphere(r * 0.62, leaf, Vector3(p.x, cy + p.y, p.z)))
	return root


# An eraser: a simple rounded block, pink by default.
static func _eraser(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var col := color if color != DEFAULT_COLOR else Color(0.93, 0.5, 0.62)
	root.add_child(_box(size, _paint(col, 0.75)))
	# A paper sleeve band around the middle.
	root.add_child(_box(Vector3(size.x * 1.02, size.y * 0.34, size.z * 1.02), _paint(Color(0.6, 0.78, 0.85), 0.7)))
	return root


# A toy ball: a sphere with a contrasting band around it.
static func _ball(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var r := minf(minf(size.x, size.y), size.z) * 0.5
	var col := color if color != DEFAULT_COLOR else Color(0.9, 0.3, 0.3)
	root.add_child(_sphere(r, _paint(col, 0.4)))
	root.add_child(_torus(r * 0.92, r * 1.01, _paint(Color(0.97, 0.97, 0.95), 0.4), Vector3.ZERO, Vector3(PI * 0.5, 0.0, 0.0)))
	return root


# A couch: seat base, backrest, two arms and a couple of cushions. Matte fabric.
static func _sofa(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var w := size.x
	var hgt := size.y
	var d := size.z
	var fabric := _paint(color if color != DEFAULT_COLOR else Color(0.35, 0.45, 0.6), 0.85)
	var cushion := _paint((color if color != DEFAULT_COLOR else Color(0.4, 0.5, 0.66)).lightened(0.08), 0.85)
	var arm_w := w * 0.12
	var base_h := hgt * 0.45
	var bottom := -hgt * 0.5
	# Seat base.
	root.add_child(_box(Vector3(w, base_h, d), fabric, Vector3(0.0, bottom + base_h * 0.5, 0.0)))
	# Backrest along the -z edge.
	root.add_child(_box(Vector3(w, hgt, d * 0.28), fabric, Vector3(0.0, 0.0, -d * 0.5 + d * 0.14)))
	# Arms.
	root.add_child(_box(Vector3(arm_w, hgt * 0.7, d), fabric, Vector3(-w * 0.5 + arm_w * 0.5, bottom + hgt * 0.35, 0.0)))
	root.add_child(_box(Vector3(arm_w, hgt * 0.7, d), fabric, Vector3(w * 0.5 - arm_w * 0.5, bottom + hgt * 0.35, 0.0)))
	# Seat cushions on top of the base.
	var seats := 2
	var seat_w := (w - arm_w * 2.0) / float(seats)
	for i in seats:
		var cx := -w * 0.5 + arm_w + seat_w * (float(i) + 0.5)
		root.add_child(_box(Vector3(seat_w * 0.92, hgt * 0.16, d * 0.66), cushion, Vector3(cx, bottom + base_h + hgt * 0.05, d * 0.08)))
	return root


# A low table: a flat top on four corner legs.
static func _table(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var w := size.x
	var hgt := size.y
	var d := size.z
	var wood := _paint(color if color != DEFAULT_COLOR else Color(0.55, 0.36, 0.22), 0.55)
	var top_t := hgt * 0.14
	root.add_child(_box(Vector3(w, top_t, d), wood, Vector3(0.0, hgt * 0.5 - top_t * 0.5, 0.0)))
	var leg := minf(w, d) * 0.08
	var leg_h := hgt - top_t
	var lx := w * 0.5 - leg
	var lz := d * 0.5 - leg
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			root.add_child(_box(Vector3(leg, leg_h, leg), wood, Vector3(sx * lx, -hgt * 0.5 + leg_h * 0.5, sz * lz)))
	return root


# A flat rug / mat: a thin slab with an inset border stripe. Usually collide:false.
static func _rug(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	var t := maxf(size.y, 0.3)
	root.add_child(_box(Vector3(size.x, t, size.z), _paint(color, 0.9)))
	root.add_child(_box(Vector3(size.x * 0.86, t * 1.04, size.z * 0.86), _paint(color.lightened(0.18), 0.9)))
	root.add_child(_box(Vector3(size.x * 0.7, t * 1.08, size.z * 0.7), _paint(color.darkened(0.12), 0.9)))
	return root


# Unknown keyword (or empty): a plain matte block so nothing is invisible.
static func _fallback(size: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	root.add_child(_box(size, _paint(color, 0.7)))
	return root
