#!/usr/bin/env python3
"""Patch level.tscn: add setup_track.gd script to the Physical node."""
import os, random, string

HERE  = os.path.dirname(os.path.abspath(__file__))
SCENE = os.path.join(HERE, "level.tscn")

RES_ID = "setup_track_script"
UID    = "uid://" + "".join(random.choices(string.ascii_lowercase + string.digits, k=13))
EXT    = f'[ext_resource type="Script" uid="{UID}" path="res://tracks/circuit_one/setup_track.gd" id="{RES_ID}"]'
SCRIPT = f'script = ExtResource("{RES_ID}")'

with open(SCENE, encoding="utf-8") as f:
    lines = f.read().split("\n")

already = any(RES_ID in l for l in lines)
if already:
    print("Already patched.")
else:
    # Insert ext_resource after the last existing [ext_resource] line
    last_ext = max(i for i, l in enumerate(lines) if l.startswith("[ext_resource"))
    lines.insert(last_ext + 1, EXT)
    print(f"+ ext_resource at line {last_ext + 1}")

    # Add script property to the Physical node (line after [node name="Physical"…])
    phys_idx = next(i for i, l in enumerate(lines)
                    if '[node name="Physical"' in l)
    lines.insert(phys_idx + 1, SCRIPT)
    print(f"+ script ref at line {phys_idx + 1}")

    with open(SCENE, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("Done.")
