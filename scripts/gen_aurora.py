#!/usr/bin/env python3
"""Generate the Aurora Circuit track JSON by walking a pose (position + heading)
along straights and arcs so the loop stays continuous. Arc math mirrors the
server (build_arc_colliders) and client (_make_arc): entry at the local origin
heading -Z; turn center on +X (sweep>0, right) or -X (sweep<0, left).

The loop is a rounded rectangle (four 90° right corners = 2x45° arcs each) whose
opposite straights are equal, so it closes exactly; one long straight carries an
antisymmetric L/R chicane (returns to the same line) to show both arc directions.

Run:  python server/tracks/gen_aurora.py > server/tracks/aurora_circuit.json
"""
import json, math, sys

W = 26.0          # track width
T = 1.0           # floor / slab thickness
WALL_T = 3.0
WALL_H = 6.0
R = 64.0          # corner radius (softer, more forgiving)
RC = 48.0         # chicane radius
SEG = 8

prims, gates = [], []
state = {"x": 0.0, "z": 0.0, "yaw": 0.0, "dist": 0.0}
straights = []    # snapshots for decoration: (sx, sz, yaw, fx, fz, length)
centerline = []   # ordered racing-line polyline [[x, z], ...], consumed by the bots

def cl_add(x, z):
    centerline.append([round(x, 2), round(z, 2)])


def fwd(yaw):
    a = math.radians(yaw); return (-math.sin(a), -math.cos(a))

def right(yaw):
    f = fwd(yaw); return (-f[1], f[0])

def rot_y(lx, lz, yaw):
    a = math.radians(yaw)
    return (lx * math.cos(a) + lz * math.sin(a), -lx * math.sin(a) + lz * math.cos(a))

def add_wall(cx, cz, length, yaw, name):
    prims.append({"type": "wall", "name": name, "size": [WALL_T, WALL_H, length],
                  "position": [round(cx, 3), WALL_H / 2.0, round(cz, 3)],
                  "rotation_deg": [0.0, round(yaw, 3), 0.0]})

def straight(length, name, walls=True, record=True):
    yaw = state["yaw"]; f = fwd(yaw); rt = right(yaw)
    sx, sz = state["x"], state["z"]
    cx = sx + f[0] * length / 2.0; cz = sz + f[1] * length / 2.0
    prims.append({"type": "floor", "name": name, "size": [W, T, length],
                  "position": [round(cx, 3), -T / 2.0, round(cz, 3)],
                  "rotation_deg": [0.0, round(yaw, 3), 0.0],
                  "color": [0.15, 0.17, 0.22]})
    if walls:
        off = W / 2.0 + WALL_T / 2.0
        add_wall(cx + rt[0] * off, cz + rt[1] * off, length, yaw, name + "_wr")
        add_wall(cx - rt[0] * off, cz - rt[1] * off, length, yaw, name + "_wl")
    if not centerline:
        cl_add(sx, sz)
    state["x"] += f[0] * length; state["z"] += f[1] * length; state["dist"] += length
    cl_add(state["x"], state["z"])
    if record:
        straights.append((sx, sz, yaw, f[0], f[1], length))

def arc(sweep_deg, name, radius=R, walls=True):
    yaw = state["yaw"]; sgn = -1.0 if sweep_deg < 0 else 1.0
    S = math.radians(abs(sweep_deg))
    prims.append({"type": "arc", "name": name, "size": [W, T, radius],
                  "segments": SEG, "sweep_deg": sweep_deg,
                  "position": [round(state["x"], 3), -T / 2.0, round(state["z"], 3)],
                  "rotation_deg": [0.0, round(yaw, 3), 0.0],
                  "color": [0.15, 0.17, 0.22]})
    cx0 = sgn * radius
    pts = []
    for i in range(SEG + 1):
        a = i / SEG * S; lx = -cx0
        pts.append((cx0 + lx * math.cos(-sgn * a), -lx * math.sin(-sgn * a)))
    # Centerline samples (world) along the arc.
    for i in range(1, SEG + 1):
        wx, wz = rot_y(pts[i][0], pts[i][1], yaw)
        cl_add(state["x"] + wx, state["z"] + wz)
    if walls:
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
                add_wall(state["x"] + wx, state["z"] + wz, chord + 0.6, seg_yaw,
                         "%s_%s%d" % (name, tag, i))
    lx = sgn * radius * (1 - math.cos(S)); lz = -radius * math.sin(S)
    wx, wz = rot_y(lx, lz, yaw)
    state["x"] += wx; state["z"] += wz
    state["yaw"] = yaw - sgn * abs(sweep_deg); state["dist"] += radius * S

def corner(name):
    arc(45.0, name + "_a"); arc(45.0, name + "_b")

def chicane(name):
    arc(-30.0, name + "_1", RC); arc(30.0, name + "_2", RC)
    arc(30.0, name + "_3", RC); arc(-30.0, name + "_4", RC)


def chicane_forward():
    """Forward advance of the chicane along its entry heading (for sizing)."""
    sv = dict(state); state.update(x=0.0, z=0.0, yaw=0.0, dist=0.0)
    base = len(prims); cl_base = len(centerline)
    chicane("_probe")
    adv = -state["z"]
    del prims[base:]
    del centerline[cl_base:]
    state.update(sv)
    return adv


A = 480.0   # long straights
B = 190.0   # short straights
chic_fwd = chicane_forward()
p = (A - chic_fwd) / 2.0   # plain part each side of the chicane on the top straight

# ---- Build the loop ----
straight(A, "start_straight")
gates.append({"role": "start_finish",
              "position": [round(straights[-1][0] + straights[-1][3] * A * 0.5, 3), 0.7,
                           round(straights[-1][1] + straights[-1][4] * A * 0.5, 3)],
              "rotation_deg": [0.0, 0.0, 0.0], "half_width": W / 2.0 + 3.0})
corner("c1")
straight(B, "right_straight")
cp1 = (state["x"], state["z"], state["yaw"])
corner("c2")
straight(p, "top_1")
chicane("chic")
straight(p, "top_2")
corner("c3")
straight(B, "left_straight")
cp2 = (state["x"], state["z"], state["yaw"])
corner("c4")
# Should be back at the origin, heading 0.

gates.append({"role": "checkpoint", "position": [round(cp1[0], 3), 0.7, round(cp1[1], 3)],
              "rotation_deg": [0.0, round(cp1[2], 3), 0.0], "half_width": W / 2.0 + 3.0})
gates.append({"role": "checkpoint", "position": [round(cp2[0], 3), 0.7, round(cp2[1], 3)],
              "rotation_deg": [0.0, round(cp2[2], 3), 0.0], "half_width": W / 2.0 + 3.0})

# ---- Decorate by sampling recorded straights (no pose advance) ----
def point_on(straght, frac):
    sx, sz, yaw, fx, fz, L = straght
    return (sx + fx * L * frac, sz + fz * L * frac, yaw, fx, fz)

def pad_on(st, frac, name, strength=22.0):
    x, z, yaw, fx, fz = point_on(st, frac)
    prims.append({"type": "pad", "name": name, "size": [W * 0.72, 2.0, 26.0],
                  "position": [round(x, 3), 0.0, round(z, 3)],
                  "rotation_deg": [0.0, round(yaw, 3), 0.0],
                  "heading": [round(fx, 3), 0.0, round(fz, 3)], "boost_strength": strength})

def arch_on(st, frac, name):
    x, z, yaw, fx, fz = point_on(st, frac)
    prims.append({"type": "decor", "name": name, "model": "neon_arch", "collide": False,
                  "size": [W + 18.0, 16.0, 4.0], "position": [round(x, 3), 8.0, round(z, 3)],
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

start_s = straights[0]; right_s = straights[1]; top1_s = straights[2]
top2_s = straights[3]; left_s = straights[4]

pad_on(start_s, 0.30, "boost_start", 24.0)
arch_on(start_s, 0.60, "arch_start")
arch_on(start_s, 0.85, "arch_start2")
pad_on(top1_s, 0.5, "boost_top")
arch_on(top2_s, 0.4, "arch_top")
pad_on(left_s, 0.5, "boost_left", 26.0)
arch_on(right_s, 0.5, "arch_right")

OFF = W / 2.0 + WALL_T + 22.0
# Solid trackside props sit well outside the barriers (won't block the track).
side_on(start_s, 0.2, 1.0, OFF, "star_pillar", "pillar_1", [10, 28, 10], [0.45, 0.7, 1.0])
side_on(start_s, 0.75, -1.0, OFF, "beacon", "beacon_1", [7, 24, 7], [1.0, 0.5, 0.7])
side_on(right_s, 0.5, 1.0, OFF, "star_pillar", "pillar_2", [9, 32, 9], [0.4, 0.95, 0.7])
side_on(top2_s, 0.6, -1.0, OFF, "beacon", "beacon_2", [7, 26, 7], [0.6, 0.8, 1.0])
side_on(left_s, 0.5, 1.0, OFF, "star_pillar", "pillar_3", [10, 30, 10], [0.5, 0.6, 1.0])
# Holograms are non-solid (collide:False) floating landmarks.
side_on(top1_s, 0.3, -1.0, OFF, "hologram_ring", "ring_1", [20, 20, 4], [0.6, 0.85, 1.0], collide=False)
side_on(left_s, 0.2, 1.0, OFF + 30.0, "hologram_ring", "ring_2", [24, 24, 4], [0.7, 0.9, 1.0], collide=False)

# Light strips lining the straights: run ALONG the edge (rot +90°) and never
# collide — otherwise their length would wall off the track.
side_on(start_s, 0.5, 1.0, W / 2.0 + WALL_T + 1.0, "light_strip", "strip_1", [A * 0.5, 1.2, 2.0], [0.4, 0.8, 1.0], rot=90.0, collide=False)
side_on(top1_s, 0.5, 1.0, W / 2.0 + WALL_T + 1.0, "light_strip", "strip_2", [p * 0.8, 1.2, 2.0], [0.9, 0.5, 0.9], rot=90.0, collide=False)

meta = {"id": "aurora_circuit", "name": "Aurora Circuit", "laps_to_win": 3,
        "gates": gates, "primitives": prims, "centerline": centerline}

print("closure_residual=%.3f  final_yaw=%.2f  centerline=%.0fm  est_lap@38ms=%.1fs  prims=%d"
      % (math.hypot(state["x"], state["z"]), state["yaw"], state["dist"],
         state["dist"] / 38.0, len(prims)), file=sys.stderr)

print(json.dumps(meta, indent=2))
