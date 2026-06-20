#!/usr/bin/env python3
"""Geometric audit: which decors obstruct the racing corridor (the camera/car pass
THROUGH their mesh)? Sweeps the centerline and flags decors whose XZ footprint comes
within a car-path corridor and that rise into the car+camera height band. Also checks
the spawn grid specifically. Run: py scripts/spawn_intersection_check.py [track]"""
import json, math, sys

track = sys.argv[1] if len(sys.argv) > 1 else "the_room"
data = json.load(open(f"server/tracks/{track}.json"))

SPAWN_LANE, SPAWN_ROW = 5.0, 8.0
CAR_HALF = (1.3, 0.6, 2.4)
FOLLOW_DIST, FOLLOW_HEIGHT = 5.0, 2.2
CORRIDOR = 9.0      # half-width of the car path swept along the centerline
CAM_TOP = 5.0       # camera rides ~4.2 up; anything rising above ~1 clips it
FLOOR_TOP = 1.8     # decor whose top is at/under this is floor/rug — never an issue

gate = next(g for g in data["gates"] if g["role"] in ("start_finish", "start"))
sp, yaw = gate["position"], math.radians(gate["rotation_deg"][1])
tan = (math.cos(yaw), -math.sin(yaw)); back = (math.sin(yaw), math.cos(yaw))

def decor_box(p):
    pos, size = p["position"], p["size"]
    rot = math.radians(p.get("rotation_deg", [0, 0, 0])[1])
    hx, hz = size[0] / 2, size[2] / 2
    ex = abs(hx*math.cos(rot)) + abs(hz*math.sin(rot))
    ez = abs(hx*math.sin(rot)) + abs(hz*math.cos(rot))
    return (pos[0]-ex, pos[0]+ex, pos[1]-size[1]/2, pos[1]+size[1]/2, pos[2]-ez, pos[2]+ez)

def seg_pt_dist(px, pz, ax, az, bx, bz):
    dx, dz = bx-ax, bz-az
    L2 = dx*dx + dz*dz
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((px-ax)*dx + (pz-az)*dz)/L2))
    return math.hypot(px-(ax+dx*t), pz-(az+dz*t))

cl = data.get("centerline", [])
decors = [p for p in data["primitives"] if p["type"] == "decor"]
print(f"track={track}  decors={len(decors)}  centerline pts={len(cl)}\n")

# Decors whose footprint enters the racing corridor and rise above the floor band.
print("== Decors obstructing the racing corridor ==")
flagged = []
for p in decors:
    x0, x1, y0, y1, z0, z1 = decor_box(p)
    if y1 <= FLOOR_TOP:       # flat floor/rug — ignore
        continue
    # nearest XZ distance from the decor footprint to the centerline polyline
    corners = [(x0, z0), (x1, z0), (x1, z1), (x0, z1)]
    best = 1e9
    for i in range(len(cl)-1):
        ax, az = cl[i]; bx, bz = cl[i+1]
        # distance line<->box ≈ min over box corners (box is axis aligned)
        for cx, cz in corners:
            best = min(best, seg_pt_dist(cx, cz, ax, az, bx, bz))
        # also: is any centerline vertex inside the footprint?
        if x0 <= ax <= x1 and z0 <= az <= z1:
            best = 0.0
    if best < CORRIDOR:
        flagged.append((best, p["name"], p.get("collide", True), p["size"], p["position"]))
for best, name, col, size, pos in sorted(flagged):
    print(f"  {name:16} dist={best:5.1f}  collide={col}  size={size}  pos={pos}")
if not flagged:
    print("  none")

# Spawn grid: car + follow-camera inside any decor box?
print("\n== Spawn grid (car / camera inside a decor) ==")
def inside(p, b):
    return b[0] <= p[0] <= b[1] and b[2] <= p[1] <= b[3] and b[4] <= p[2] <= b[5]
def car_overlaps(c, b):
    return (b[0] < c[0]+CAR_HALF[0] and c[0]-CAR_HALF[0] < b[1]
            and b[2] < c[1]+CAR_HALF[1] and c[1]-CAR_HALF[1] < b[3]
            and b[4] < c[2]+CAR_HALF[2] and c[2]-CAR_HALF[2] < b[5])
for idx in range(6):
    side = -1.0 if idx % 2 == 0 else 1.0
    lat, bk = side*SPAWN_LANE, (idx//2+1)*SPAWN_ROW
    c = (sp[0]+tan[0]*lat+back[0]*bk, sp[1], sp[2]+tan[1]*lat+back[1]*bk)
    cam = (c[0]+math.sin(yaw)*FOLLOW_DIST, c[1]+FOLLOW_HEIGHT, c[2]+math.cos(yaw)*FOLLOW_DIST)
    car_hits = [p["name"] for p in decors if decor_box(p)[3] > FLOOR_TOP and car_overlaps(c, decor_box(p))]
    cam_hits = [p["name"] for p in decors if inside(cam, decor_box(p))]
    print(f"  idx{idx} car@{tuple(round(v) for v in c)} -> car:{car_hits or '-'}  cam:{cam_hits or '-'}")
