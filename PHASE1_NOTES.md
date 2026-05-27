# Phase 1 — Baseline closed loop (run log)

**Date:** 2026-05-27 · **Status:** ✅ done · **Goal #1 met** (LEAD + CARLA + Scenario Runner ran a
full closed-loop scenario). Companion docs: `PLAN_R171.md` (plan), `lead_carla_concepts.md` (concepts).

## Outcome

Ran the LEAD pretrained agent (`tfv6_resnet34`) closed-loop on a cut-in scenario and scored it.

| Metric | Value |
| --- | --- |
| Route | `data/benchmark_routes/bench2drive/24759.xml` — **Town05 ParkingCutIn** |
| Driving score (`score_composed`) | **100.0** |
| Route completion | 100.0 % |
| Penalty multiplier | 1.0 (no penalties) |
| Collisions / exceptions | 0 / 0 |
| Sim time / wall time | 21.9 s game · 56 s system |
| Output | `outputs/local_evaluation/24759/` (`checkpoint_endpoint.json`, `metric_info.json`, `infractions.json`) |

Only `min_speed_infractions` flagged — a soft metric that did **not** penalize the score. i.e. the
agent handled the cut-in with no collision and full route completion.

## What we actually ran

```bash
# 1. Start CARLA (manual; heavy). Drops root -> carla user, -RenderOffScreen, port 2000.
bash scripts/start_carla.sh

# 2. Health check the server.
bash scripts/carla_status.sh

# 3. The closed-loop eval. LEAD_PROJECT_ROOT is REQUIRED (lead/__main__.py reads it).
LEAD_PROJECT_ROOT=/workspace/lead python -m lead \
  --checkpoint outputs/checkpoints/tfv6_resnet34 \
  --routes data/benchmark_routes/bench2drive/24759.xml \
  --bench2drive
```

`python -m lead --bench2drive` is the wrapper: it builds PYTHONPATH for
`3rd_party/Bench2Drive/{leaderboard,scenario_runner}` and runs the leaderboard evaluator as a
subprocess. (`scripts/eval_bench2drive.sh` is the lower-level equivalent.)

## Problems solved along the way

1. **"CARLA can't run as root" — solved without changing Docker.** CarlaUE4 refuses to run as root,
   but the container is root-based. `scripts/start_carla.sh` already `setpriv`-drops root → the
   `carla` user while keeping an **ambient `CAP_DAC_OVERRIDE`**. That cap is essential: NVIDIA's
   Vulkan driver must read the GPU's PCI BAR files (`/sys/.../resource0`, mode 0600 root-only);
   without it Vulkan fails (`ERROR_INCOMPATIBLE_DRIVER`) → CPU/llvmpipe fallback → RenderThread
   timeout → segfault. Verified: with the cap, CARLA boots on the RTX 5090. **Do NOT rebuild the
   image as a non-root user** — that strips the cap and re-breaks GPU rendering.

2. **Env was wiped by the Docker rebuild.** The image only bakes torch 2.7/cu128, triton, carla;
   the other ~287 deps (beartype, py-trees, …) were runtime-installed and gone. Restored with:
   ```bash
   UV_PROJECT_ENVIRONMENT=/opt/conda/envs/lead uv sync --inexact --extra dev \
     --no-install-package torch --no-install-package torchvision \
     --no-install-package torchaudio --no-install-package triton \
     $(pip list --format=freeze | grep -iE '^nvidia-' | sed 's/=.*//;s/^/--no-install-package /')
   ```
   Gotchas: `uv --active` makes a stray `.venv` (uv keys off `VIRTUAL_ENV`, not `CONDA_PREFIX`);
   `pip --force-reinstall torch` over-bumps numpy→2.x / pillow past the lock pins. Excluding the
   whole torch+nvidia stack keeps the cu128 GPU build intact while restoring the rest to lock.
   This is now baked into `docker/Dockerfile.lead` (§6.5) so future rebuilds don't wipe it.

3. **Town12/13 maps are not installed.** Only Town01-05 + Town10HD ship in the base CARLA tarball;
   Town12/13 need the ~4 GB `AdditionalMaps_0.9.15`. The planned `1711.xml` (Town12) and ALL
   faithful adjacent-lane `HighwayCutIn` routes are Town12 → can't run yet. **Substituted
   `24759.xml` (Town05 ParkingCutIn)** — same scenario family as the planned `1711`, on an
   installed town. `26396.xml` (Town05 StaticCutIn) is another option.

## Helper scripts created this phase

- `scripts/carla_status.sh [port]` — health check (process, port, **client handshake**, GPU).
  Exits 0 only if reachable. The handshake line is the source of truth.
- `scripts/carla_record_video.py [seconds] [n_traffic]` — records a chase-cam MP4 from the headless
  server (camera sensor → ffmpeg) into `outputs/snapshots/`. Used to visually confirm the render.

## Gotchas worth remembering

- **`ss`/`netstat` lie under `docker --network=host`** — they report CARLA's port as closed. Use a
  `/dev/tcp/127.0.0.1/2000` connect test (or the client handshake) instead.
- **Empty `/tmp/carla_2000.log` during boot is normal** (block-buffered stdout), not a failure.
  First boot on a new GPU also spends minutes compiling shaders before the port opens.
- **`start_carla.sh` doesn't check for an existing server** — running it while one is up →
  `bind: Address already in use` → segfault. Kill first (`pkill -f CarlaUE4`) or reuse the running one.
- A client that sets **synchronous mode** must restore async on exit, or the world is left frozen
  for the next client. (Restore settings *before* tearing down actors.)

## Next (Phase 2)

- For the *faithful* R171 adjacent-lane case (Town12 `HighwayCutIn`, e.g. `2286`/`3072`): download
  `AdditionalMaps_0.9.15`, extract into `/opt/carla`, restart CARLA.
- The Dockerfile dep-restore fix is applied (4 files: `Dockerfile.lead`, `.dockerignore`,
  `build.sh`, `devcontainer.json`) but **not committed** — review + rebuild to verify.
