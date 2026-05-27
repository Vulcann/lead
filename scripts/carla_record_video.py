#!/usr/bin/env python
"""Record a short chase-cam MP4 from the running (headless) CARLA server.

Run from the project root in the `lead` env, against a server already up on port 2000:
    python scripts/carla_record_video.py [seconds] [n_traffic]

Spawns an autopilot ego + traffic into the currently-loaded map, attaches a chase
camera, ticks in synchronous mode, and pipes each rendered frame into ffmpeg.
Output: outputs/snapshots/carla_<map>_<timestamp>.mp4  (open it in VSCode to view).
"""
import datetime
import os
import queue
import random
import subprocess
import sys

import carla
import numpy as np

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
N_TRAFFIC = int(sys.argv[2]) if len(sys.argv) > 2 else 30
W, H, FPS = 1280, 720, 20
N_FRAMES = int(SECONDS * FPS)

client = carla.Client("localhost", 2000)
client.set_timeout(20.0)
world = client.get_world()
tm = client.get_trafficmanager(8000)
blueprints = world.get_blueprint_library()
spawn_points = world.get_map().get_spawn_points()
map_name = world.get_map().name.split("/")[-1]

os.makedirs("outputs/snapshots", exist_ok=True)
stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
out_path = f"outputs/snapshots/carla_{map_name}_{stamp}.mp4"

orig_settings = world.get_settings()
actors = []
cam = None
ffmpeg = None
try:
    # Synchronous mode: every world.tick() yields exactly one camera frame.
    settings = world.get_settings()
    settings.synchronous_mode = True
    settings.fixed_delta_seconds = 1.0 / FPS
    world.apply_settings(settings)
    tm.set_synchronous_mode(True)

    # Ego + chase camera.
    ego = world.spawn_actor(blueprints.filter("vehicle.tesla.model3")[0], spawn_points[0])
    actors.append(ego)
    ego.set_autopilot(True, 8000)

    # Traffic for a lively scene.
    for sp in random.sample(spawn_points[1:], min(N_TRAFFIC, len(spawn_points) - 1)):
        v = world.try_spawn_actor(random.choice(blueprints.filter("vehicle.*")), sp)
        if v is not None:
            v.set_autopilot(True, 8000)
            actors.append(v)

    cam_bp = blueprints.find("sensor.camera.rgb")
    cam_bp.set_attribute("image_size_x", str(W))
    cam_bp.set_attribute("image_size_y", str(H))
    cam_bp.set_attribute("fov", "90")
    cam_tf = carla.Transform(carla.Location(x=-6.0, z=3.0), carla.Rotation(pitch=-15.0))
    cam = world.spawn_actor(cam_bp, cam_tf, attach_to=ego)
    actors.append(cam)

    frames = queue.Queue()
    cam.listen(frames.put)

    # ffmpeg reads raw RGB frames from stdin and encodes H.264.
    ffmpeg = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "rgb24",
         "-video_size", f"{W}x{H}", "-framerate", str(FPS), "-i", "-",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", out_path],
        stdin=subprocess.PIPE,
    )

    # Let traffic settle / ego start moving before recording.
    for _ in range(20):
        world.tick()
        frames.get(timeout=5.0)

    print(f"recording {N_FRAMES} frames ({SECONDS:g}s @ {FPS}fps) on {map_name}...")
    for _ in range(N_FRAMES):
        world.tick()
        img = frames.get(timeout=5.0)
        bgra = np.frombuffer(img.raw_data, dtype=np.uint8).reshape((H, W, 4))
        ffmpeg.stdin.write(bgra[:, :, [2, 1, 0]].tobytes())  # BGRA -> RGB
finally:
    # Restore async FIRST: a teardown error must not leave the world frozen in sync mode.
    world.apply_settings(orig_settings)
    tm.set_synchronous_mode(False)
    if ffmpeg is not None:
        ffmpeg.stdin.close()
        ffmpeg.wait()
    if cam is not None:
        cam.stop()
    # Batch destroy is robust to attach order (destroying the ego also takes its camera).
    client.apply_batch([carla.command.DestroyActor(a) for a in actors])

print(f"saved: {out_path}  ({os.path.getsize(out_path) / 1e6:.1f} MB)")

# CARLA's Python client can throw from its C++ teardown at interpreter exit
# ("terminate called without an active exception"). All real work and cleanup are
# done above, so exit hard to skip that benign crash.
sys.stdout.flush()
os._exit(0)
