#!/usr/bin/env python
"""Record a short MP4 from the running (headless) CARLA server.

Run from the project root in the `lead` env, against a server already up:
    python scripts/carla_record_video.py [seconds] [n_traffic] [port] [tm_port] [view]

view is one of:
    surround  6-cam nuScenes surround + BEV, tiled into one 3x3 frame (default):
                  FRONT_LEFT  FRONT  FRONT_RIGHT
                       -       BEV        -
                  BACK_LEFT   BACK   BACK_RIGHT
    bev       single top-down bird's-eye over the ego
    chase     single follow camera behind the ego

Spawns an autopilot ego + traffic into the currently-loaded map, attaches the
camera(s), ticks in synchronous mode, and pipes each rendered frame into ffmpeg.
Output: outputs/snapshots/carla_<map>_<timestamp>.mp4  (open it in VSCode to view).
"""
import datetime
import os
import queue
import random
import subprocess
import sys

import carla
import cv2
import numpy as np

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
N_TRAFFIC = int(sys.argv[2]) if len(sys.argv) > 2 else 30
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
TM_PORT = int(sys.argv[4]) if len(sys.argv) > 4 else 8000
VIEW = sys.argv[5] if len(sys.argv) > 5 else "surround"
FPS = 20
FOV = "90"

# BEV: camera straight above the ego looking down; attached to the ego so it
# rotates with it -> ego stays centered, pointing up. z=35 + fov 90 covers ~70 m.
BEV_TF = carla.Transform(carla.Location(z=35.0), carla.Rotation(pitch=-90.0))
# Surround rig mounted on the roof (z=2.4). Yaw is left-handed about +z: +yaw
# points right of the ego, -yaw left, 180 back. Grid columns mirror this — left
# cams on the left, right cams on the right, front on top row, back on bottom.
ROOF_Z = 2.4
SURROUND_PANELS = [
    # (label, transform, grid_row, grid_col)
    ("FRONT_LEFT",  carla.Transform(carla.Location(x=0.0, z=ROOF_Z), carla.Rotation(yaw=-55)),  0, 0),
    ("FRONT",       carla.Transform(carla.Location(x=0.5, z=ROOF_Z), carla.Rotation(yaw=0)),    0, 1),
    ("FRONT_RIGHT", carla.Transform(carla.Location(x=0.0, z=ROOF_Z), carla.Rotation(yaw=55)),   0, 2),
    ("BEV",         BEV_TF,                                                                     1, 1),
    ("BACK_LEFT",   carla.Transform(carla.Location(x=0.0, z=ROOF_Z), carla.Rotation(yaw=-125)), 2, 0),
    ("BACK",        carla.Transform(carla.Location(x=-0.5, z=ROOF_Z), carla.Rotation(yaw=180)), 2, 1),
    ("BACK_RIGHT",  carla.Transform(carla.Location(x=0.0, z=ROOF_Z), carla.Rotation(yaw=125)),  2, 2),
]

# Each view resolves to a list of panels and a panel resolution; the output frame
# is (panel_w * grid_cols) x (panel_h * grid_rows). Single-cam views are a 1x1 grid.
if VIEW == "surround":
    panels = SURROUND_PANELS
    PANEL_W, PANEL_H = 480, 270
    GRID_ROWS, GRID_COLS = 3, 3
elif VIEW == "bev":
    panels = [("BEV", BEV_TF, 0, 0)]
    PANEL_W, PANEL_H = 900, 900
    GRID_ROWS, GRID_COLS = 1, 1
elif VIEW == "chase":
    panels = [("CHASE", carla.Transform(carla.Location(x=-6.0, z=3.0), carla.Rotation(pitch=-15.0)), 0, 0)]
    PANEL_W, PANEL_H = 1280, 720
    GRID_ROWS, GRID_COLS = 1, 1
else:
    sys.exit(f"unknown view {VIEW!r}; expected surround|bev|chase")

W, H = PANEL_W * GRID_COLS, PANEL_H * GRID_ROWS
N_FRAMES = int(SECONDS * FPS)

client = carla.Client("localhost", PORT)
client.set_timeout(20.0)
world = client.get_world()
tm = client.get_trafficmanager(TM_PORT)
blueprints = world.get_blueprint_library()
spawn_points = world.get_map().get_spawn_points()
map_name = world.get_map().name.split("/")[-1]

os.makedirs("outputs/snapshots", exist_ok=True)
stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
out_path = f"outputs/snapshots/carla_{map_name}_{stamp}.mp4"


def label_panel(rgb, text):
    """Burn a small label into the top-left of a panel (black outline + white)."""
    tile = np.ascontiguousarray(rgb)
    cv2.putText(tile, text, (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 4, cv2.LINE_AA)
    cv2.putText(tile, text, (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1, cv2.LINE_AA)
    return tile


def grab(cam_q):
    """Pull one frame off a sensor queue and convert CARLA BGRA -> RGB."""
    img = cam_q.get(timeout=5.0)
    bgra = np.frombuffer(img.raw_data, dtype=np.uint8).reshape((PANEL_H, PANEL_W, 4))
    return bgra[:, :, [2, 1, 0]]


orig_settings = world.get_settings()
actors = []
sensors = []
ffmpeg = None
try:
    # Synchronous mode: every world.tick() yields exactly one frame per sensor,
    # all sharing a frame id, so pulling one from each queue keeps them aligned.
    settings = world.get_settings()
    settings.synchronous_mode = True
    settings.fixed_delta_seconds = 1.0 / FPS
    world.apply_settings(settings)
    tm.set_synchronous_mode(True)

    # Ego.
    ego = world.spawn_actor(blueprints.filter("vehicle.tesla.model3")[0], spawn_points[0])
    actors.append(ego)
    ego.set_autopilot(True, TM_PORT)

    # Traffic for a lively scene.
    for sp in random.sample(spawn_points[1:], min(N_TRAFFIC, len(spawn_points) - 1)):
        v = world.try_spawn_actor(random.choice(blueprints.filter("vehicle.*")), sp)
        if v is not None:
            v.set_autopilot(True, TM_PORT)
            actors.append(v)

    # One camera per panel, each feeding its own queue.
    cells = []  # (label, queue, row, col)
    for label, tf, r, c in panels:
        bp = blueprints.find("sensor.camera.rgb")
        bp.set_attribute("image_size_x", str(PANEL_W))
        bp.set_attribute("image_size_y", str(PANEL_H))
        bp.set_attribute("fov", FOV)
        cam = world.spawn_actor(bp, tf, attach_to=ego)
        actors.append(cam)
        sensors.append(cam)
        q = queue.Queue()
        cam.listen(q.put)
        cells.append((label, q, r, c))

    # ffmpeg reads the raw composited RGB frame from stdin and encodes H.264.
    ffmpeg = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "rgb24",
         "-video_size", f"{W}x{H}", "-framerate", str(FPS), "-i", "-",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", out_path],
        stdin=subprocess.PIPE,
    )

    def render_frame():
        """Tick once, composite every panel into the grid canvas, return it."""
        world.tick()
        canvas = np.zeros((H, W, 3), dtype=np.uint8)
        for label, q, r, c in cells:
            tile = label_panel(grab(q), label)
            canvas[r * PANEL_H:(r + 1) * PANEL_H, c * PANEL_W:(c + 1) * PANEL_W] = tile
        return canvas

    # Let traffic settle / ego start moving before recording.
    for _ in range(20):
        render_frame()

    print(f"recording {N_FRAMES} frames ({SECONDS:g}s @ {FPS}fps) [{VIEW}] on {map_name}...")
    for _ in range(N_FRAMES):
        ffmpeg.stdin.write(render_frame().tobytes())
finally:
    # Restore async FIRST: a teardown error must not leave the world frozen in sync mode.
    world.apply_settings(orig_settings)
    tm.set_synchronous_mode(False)
    if ffmpeg is not None:
        ffmpeg.stdin.close()
        ffmpeg.wait()
    for cam in sensors:
        cam.stop()
    # Batch destroy is robust to attach order (destroying the ego also takes its cameras).
    client.apply_batch([carla.command.DestroyActor(a) for a in actors])

print(f"saved: {out_path}  ({os.path.getsize(out_path) / 1e6:.1f} MB)")

# CARLA's Python client can throw from its C++ teardown at interpreter exit
# ("terminate called without an active exception"). All real work and cleanup are
# done above, so exit hard to skip that benign crash.
sys.stdout.flush()
os._exit(0)
