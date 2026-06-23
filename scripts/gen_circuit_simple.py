#!/usr/bin/env python3
"""Generate 'Circuit Simple' — a plain hippodrome (oval): two straights joined by
two 180° bends, built from the arc primitive. Boundary walls are LOW so the star
sky stays visible, and one of every decor kind is scattered around the loop.

Arc math mirrors the server (build_arc_colliders) / client (_make_arc): entry at
the local origin heading -Z; turn center on +X (sweep>0, right) / -X (sweep<0).

Run:  python scripts/gen_circuit_simple.py > server/tracks/circuit_simple.json
"""
import json, math, sys

W = 28.0          # track width (a touch wider, easy oval)
T = 1.0
WALL_T = 2.0
WALL_H = 1.2      # LOW walls (≈ car height) — kept deliberately short
R = 78.0          # bend radius
A = 300.0         # straight length
SEG = 16          # segments per 180° bend

prims, gates = [], []
state = {"x": 0.0, "z": 0.0, "yaw": 0.0, "dist": 0.0}
straights = []
centerline = []   # ordered racing-line polyline [[x, z], ...], consumed by the bots

def cl_add(x, z):
    centerline.append([round(x, 2), round(z, 2)])


def fwd(y):
    a = math.radians(y); return (-math.sin(a), -math.cos(a))

def right(y):
    f = fwd(y); return (-f[1], f[0])

def rot_y(lx, lz, y):
    a = math.radians(y)
    return (lx * math.cos(a) + lz * math.sin(a), -lx * math.sin(a) + lz * math.cos(a))

def wall(cx, cz, length, yaw, name):
    prims.append({"type": "wall", "name": name, "size": [WALL_T, WALL_H, length],
                  "position": [round(cx, 3), WALL_H / 2.0, round(cz, 3)],
                  "rotation_deg": [0.0, round(yaw, 3), 0.0],
                  "color": [0.22, 0.26, 0.34]})

def straight(length, name):
    yaw = state["yaw"]; f = fwd(yaw); rt = right(yaw)
    sx, sz = state["x"], state["z"]
    cx = sx + f[0] * length / 2.0; cz = sz + f[1] * length / 2.0
    prims.append({"type": "floor", "name": name, "size": [W, T, length],
                  "position": [round(cx, 3), -T / 2.0, round(cz, 3)],
                  "rotation_deg": [0.0, round(yaw, 3), 0.0],
                  "color": [0.14, 0.16, 0.21]})
    off = W / 2.0 + WALL_T / 2.0
    wall(cx + rt[0] * off, cz + rt[1] * off, length, yaw, name + "_wr")
    wall(cx - rt[0] * off, cz - rt[1] * off, length, yaw, name + "_wl")
    if not centerline:
        cl_add(sx, sz)
    state["x"] += f[0] * length; state["z"] += f[1] * length; state["dist"] += length
    cl_add(state["x"], state["z"])
    straights.append((sx, sz, yaw, f[0], f[1], length))

def bend(sweep_deg, name):
    yaw = state["yaw"]; sgn = -1.0 if sweep_deg < 0 else 1.0
    S = math.radians(abs(sweep_deg))
    prims.append({"type": "arc", "name": name, "size": [W, T, R],
                  "segments": SEG, "sweep_deg": sweep_deg,
                  "position": [round(state["x"], 3), -T / 2.0, round(state["z"], 3)],
                  "rotation_deg": [0.0, round(yaw, 3), 0.0],
                  "color": [0.14, 0.16, 0.21]})
    cx0 = sgn * R
    pts = []
    for i in range(SEG + 1):
        a = i / SEG * S; lx = -cx0
        pts.append((cx0 + lx * math.cos(-sgn * a), -lx * math.sin(-sgn * a)))
    for i in range(1, SEG + 1):
        wx, wz = rot_y(pts[i][0], pts[i][1], yaw)
        cl_add(state["x"] + wx, state["z"] + wz)
    for i in range(SEG):
        (lx0, lz0), (lx1, lz1) = pts[i], pts[i + 1]
        mlx, mlz = 0.5 * (lx0 + lx1), 0.5 * (lz0 + lz1)
        dx, dz = lx1 - lx0, lz1 - lz0; chord = math.hypot(dx, dz)
        seg_yaw = yaw + math.degrees(math.atan2(dx, dz))
        nlx, nlz = dz / chord, -dx / chord
        for sside, tag in ((1.0, "wr"), (-1.0, "wl")):
            ox = mlx + nlx * sside * (W / 2.0 + WALL_T / 2.0)
            oz = mlz + nlz * sside * (W / 2.0 + WALL_T / 2.0)
            wx, wz = rot_y(ox, oz, yaw)
            wall(state["x"] + wx, state["z"] + wz, chord + 0.5, seg_yaw, "%s_%s%d" % (name, tag, i))
    lx = sgn * R * (1 - math.cos(S)); lz = -R * math.sin(S)
    wx, wz = rot_y(lx, lz, yaw)
    state["x"] += wx; state["z"] += wz
    state["yaw"] = yaw - sgn * abs(sweep_deg); state["dist"] += R * S


# ---- Oval: straight, 180° bend, straight, 180° bend (closes by symmetry) ----
straight(A, "front_straight")
gates.append({"role": "start_finish",
              "position": [round(straights[-1][0] + straights[-1][3] * A * 0.5, 3), 0.7,
                           round(straights[-1][1] + straights[-1][4] * A * 0.5, 3)],
              "rotation_deg": [0.0, 0.0, 0.0], "half_width": W / 2.0 + 3.0})
bend(180.0, "bend_1")
straight(A, "back_straight")
cp = (state["x"] - straights[-1][3] * A * 0.5, state["z"] - straights[-1][4] * A * 0.5, state["yaw"])
gates.append({"role": "checkpoint", "position": [round(cp[0], 3), 0.7, round(cp[1], 3)],
              "rotation_deg": [0.0, round(cp[2], 3), 0.0], "half_width": W / 2.0 + 3.0})
bend(180.0, "bend_2")


def point_on(st, frac):
    sx, sz, yaw, fx, fz, L = st
    return (sx + fx * L * frac, sz + fz * L * frac, yaw, fx, fz)

def pad_on(st, frac, name, strength=22.0):
    x, z, yaw, fx, fz = point_on(st, frac)
    prims.append({"type": "pad", "name": name, "size": [12.0, 2.0, 16.0],
                  "position": [round(x, 3), 0.0, round(z, 3)],
                  "rotation_deg": [0.0, round(yaw, 3), 0.0],
                  "heading": [round(fx, 3), 0.0, round(fz, 3)], "boost_strength": strength})

def arch_on(st, frac, name):
    x, z, yaw, fx, fz = point_on(st, frac)
    prims.append({"type": "decor", "name": name, "model": "neon_arch", "collide": False,
                  "size": [W + 16.0, 14.0, 4.0], "position": [round(x, 3), 7.0, round(z, 3)],
                  "rotation_deg": [0.0, round(yaw, 3), 0.0], "color": [0.35, 0.75, 1.0]})

def side_on(st, frac, side, dist, model, name, size, color, rot=0.0, collide=True):
    x, z, yaw, fx, fz = point_on(st, frac)
    rx, rz = (-fz, fx)
    d = {"type": "decor", "name": name, "model": model, "size": size,
         "position": [round(x + rx * side * dist, 3), round(size[1] / 2.0, 3),
                      round(z + rz * side * dist, 3)],
         "rotation_deg": [0.0, round(yaw + rot, 3), 0.0],
         "color": color}
    if not collide:
        d["collide"] = False
    prims.append(d)

front, back = straights[0], straights[1]
OFF = W / 2.0 + WALL_T + 26.0

# Boost on each straight.
pad_on(front, 0.30, "boost_front", 24.0)
pad_on(back, 0.30, "boost_back", 24.0)

# One of EVERY decor kind, scattered "ça et là".
arch_on(front, 0.62, "arch_front")                                             # neon_arch
side_on(front, 0.20, 1.0, OFF, "star_pillar", "pillar", [11, 26, 11], [0.45, 0.7, 1.0])     # star_pillar (solid prop)
side_on(front, 0.80, -1.0, OFF, "beacon", "beacon", [7, 22, 7], [1.0, 0.5, 0.7])            # beacon (solid prop)
side_on(back, 0.50, 1.0, OFF, "hologram_ring", "ring", [22, 22, 4], [0.6, 0.85, 1.0], collide=False)        # hologram_ring (non-solid)
side_on(back, 0.50, 1.0, W / 2.0 + WALL_T + 1.0, "light_strip", "strip", [A * 0.6, 1.0, 2.0], [0.4, 0.8, 1.0], rot=90.0, collide=False)  # light_strip along the edge
# A floating hologram landmark in the infield centre (non-solid).
prims.append({"type": "decor", "name": "infield_ring", "model": "hologram_ring",
              "size": [40, 40, 6], "position": [round(R, 3), 20.0, round(-A * 0.5, 3)],
              "collide": False, "color": [0.6, 0.9, 1.0]})

meta = {"id": "circuit_simple", "name": "Circuit Simple", "laps_to_win": 3,
        "environment": "night",
        "gates": gates, "primitives": prims, "centerline": centerline}

print("closure_residual=%.3f  final_yaw=%.2f  centerline=%.0fm  est_lap@38=%.1fs  prims=%d"
      % (math.hypot(state["x"], state["z"]), state["yaw"], state["dist"],
         state["dist"] / 38.0, len(prims)), file=sys.stderr)
print(json.dumps(meta, indent=2))
