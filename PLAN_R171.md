# Plan: LEAD + CARLA + Scenario Runner closed loop → an R171 test scenario

> Status: **Phase 1 COMPLETE (closed loop validated 2026-05-27)** — LEAD+CARLA+Scenario Runner
> ran end-to-end on a Town05 cut-in route (driving score 100, 0 collisions). Next: R171 mapping
> (Phase 2), which needs CARLA AdditionalMaps for the Town12 HighwayCutIn case.
> Goals (from `.claude/CLAUDE.md`):
> 1. Build the LEAD + CARLA + Scenario Runner closed loop and run through one closed-loop scenario.
> 2. Run a closed-loop simulation scenario related to **R171**.
>
> **Confirmed decisions (2026-05-25):** R171 case = **cut-in (adjacent lane)**; fidelity =
> **reuse an existing CARLA cut-in route first, then author a faithful R171-parameterized one**;
> system-under-test = **LEAD pretrained agent** (`tfv6_resnet34`).

---

## Framing (important)

**R171 = UN Regulation No. 171 — DCAS (Driver Control Assistance Systems)**, an SAE **Level-2**
framework (adopted March 2024, in force Sept 2024). It is certified via a scenario catalogue:
lane positioning, driver-initiated lane changes, system-initiated / driver-confirmed lane changes,
and **cut-in from an adjacent lane**.

R171/DCAS assumes a **human driver** who monitors and confirms maneuvers (driver monitoring,
lane-change confirmation, etc.). **LEAD is a full end-to-end autonomous driver** with no human in
the loop, so LEAD itself cannot be *certified* to R171.

What *is* meaningful and reusable: reproduce an **R171 test scenario** (cut-in, lane change, lane
keeping …) as a CARLA closed-loop sim and evaluate a driving policy against it. We build the
scenario + evaluation harness now with LEAD as the system-under-test; the same harness can later
drive an actual OEM / DCAS stack.

---

## Current environment status — ✅ READY (Phase 0 done 2026-05-25)

- ✅ **All `lead` deps installed** via `uv sync --active --extra dev` (py-trees, shapely, ephem,
  imgaug, transformers, timm, open3d, py123d, beartype, jaxtyping, … all import).
- ✅ **torch 2.7.0+cu128 retained** for the RTX 5090 (Blackwell, sm_120). Verified: `torch.cuda`
  available + a real GPU matmul. `triton 3.3.0`. `torchaudio` intentionally absent (unused in
  `lead`). pyproject still pins torch==2.5 → pip reports a metadata conflict; this is the
  documented Blackwell override (**inference only; training unsupported on this GPU**).
  - Note: did NOT do the "downgrade then restore" dance. `uv sync --no-install-package
    torch/torchvision/torchaudio` removed the cu128 wheels anyway, so torch 2.7/cu128 was
    reinstalled afterwards via `pip install … --index-url …/cu128` (pulls triton 3.3.0).
- ✅ **Checkpoint downloaded:** `outputs/checkpoints/tfv6_resnet34/` (config.json + 264 MB
  `model_0030_0.pth`, valid torch zip; resnet34 backbone; 94.72 Bench2Drive in the paper).
- ✅ **Env wired:** uv↔conda binding (`activate.d/uv.sh`), `LEAD_PROJECT_ROOT=/workspace/lead`
  + `source scripts/main.sh` in `~/.bashrc`. `CARLA_ROOT=/opt/carla`,
  `3rd_party/CARLA_0915 → /opt/carla`. `leaderboard` + `srunner` import from
  `3rd_party/Bench2Drive/`.
- ✅ `scripts/start_carla.sh` uses `-RenderOffScreen` (no-GUI constraint).
- ✅ CARLA routes present under `data/benchmark_routes/` (Town13, bench2drive, fail2drive,
  longest6). 15 cut-in routes available — see route selection below.

---

## Mapping R171 cases → existing CARLA scenarios

The Scenario Runner already ships the relevant scenario classes, so R171 cut-in / lane-change
cases map cleanly:

| R171 test case                       | CARLA scenario class / type                                   |
| ------------------------------------ | ------------------------------------------------------------- |
| Cut-in from adjacent lane (dynamic)  | `highway_cut_in.py` (`HighwayCutIn`), `cut_in.py`             |
| Cut-in from parked/static            | `parking_cut_in.py` (`ParkingCutIn`), `StaticCutIn`           |
| Lane change (driver/system initiated)| `change_lane.py`, `SequentialLaneChange`                      |

Note: `data/benchmark_routes/bench2drive/1711.xml` is a Town12 **`ParkingCutIn`** route — a
ready-made cut-in that can validate the loop quickly.

---

## Phases

### Phase 0 — Environment bring-up — ✅ DONE (see "Current environment status" above)

### Route selection (cut-in focus)

15 cut-in routes exist in `data/benchmark_routes/bench2drive/`:
- **ParkingCutIn** (cut-in from static/parked): `1711`, `18305`, `18311`, `18356`, `24759`
- **HighwayCutIn** (adjacent-lane dynamic — the faithful R171 case): `2286`, `3072`, `3074`,
  `3080`, `3813`
- **StaticCutIn**: `25358`, `26396`, `26405`, `2709`, `2715`

Plan: **`1711.xml`** (Town12, ParkingCutIn, 68 wp) for the first loop validation → then a
**HighwayCutIn** route (e.g. `3072` / `2286`) as the faithful R171 adjacent-lane cut-in reuse.

### Phase 1 — Baseline closed loop (Goal #1)  ← ✅ DONE 2026-05-27

- **You start CARLA manually** (`bash scripts/start_carla.sh`); the setpriv version drops root →
  `carla` user with ambient CAP_DAC_OVERRIDE so NVIDIA Vulkan works (verified). Docker did NOT
  need changing to a non-root user — that would re-break GPU rendering.
- **Route substitution:** the planned `1711.xml` is **Town12**, which is NOT installed (only
  Town01-05 + Town10HD; Town12/13 need the ~4 GB `AdditionalMaps_0.9.15`). Ran instead on
  **`data/benchmark_routes/bench2drive/24759.xml` (Town05 ParkingCutIn)** — a faithful stand-in
  for `1711` (also ParkingCutIn) on an installed town. (`26396.xml` = Town05 StaticCutIn also OK.)
- Command run (note: `LEAD_PROJECT_ROOT` is required by `lead/__main__.py`):
  ```bash
  LEAD_PROJECT_ROOT=/workspace/lead python -m lead \
    --checkpoint outputs/checkpoints/tfv6_resnet34 \
    --routes data/benchmark_routes/bench2drive/24759.xml \
    --bench2drive
  ```
- **Result** (`outputs/local_evaluation/24759/checkpoint_endpoint.json`): `score_composed=100`,
  `score_route=100`, `score_penalty=1.0`, 0 collisions, 0 exceptions, route 100% complete in
  21.9 s game time. Only `min_speed_infractions` flagged (soft, non-penalizing). → Goal #1 met.

### Phase 2 — R171 scenario mapping (Goal #2)

- Target the **adjacent-lane cut-in** R171 case → `HighwayCutIn` (`3072`/`2286`), with `1711`
  (`ParkingCutIn`) already validating the loop in Phase 1.
- Fidelity (confirmed: reuse → author):
  - **(a)** Reuse an existing CARLA HighwayCutIn route as an R171-representative test (fast).
  - **(b)** Author a Scenario Runner scenario parameterized to R171 conditions (speeds, gap,
    lateral profile) for fidelity.

### Phase 3 — Run & assess

- Run the R171-style scenario closed-loop, collect `metric_info.json` / `infractions.json` /
  videos.
- Assess against an R171-style criterion (no collision, safe gap maintained, maneuver completed).
- Review failures via the webapp (`python lead/webapp/app.py`).

---

## Constraints (from `.claude/CLAUDE.md`)

- No GUI (VSCode Remote-SSH) → CARLA always `-RenderOffScreen`.
- conda env name fixed: `lead`.
- Do **not** auto-start the CARLA server — the user controls it manually.
- Do **not** `git commit` — the user reviews and commits manually.
- Write the plan before large changes and wait for confirmation.

---

## Decisions — ✅ confirmed (2026-05-25)

1. **First R171 scenario:** cut-in (adjacent lane). ✅
2. **Fidelity:** reuse an existing CARLA cut-in route first, then author a faithful
   R171-parameterized scenario. ✅
3. **System-under-test:** LEAD pretrained agent (`tfv6_resnet34`); harness reusable for an OEM
   stack later. ✅
4. **Phase 0 env bring-up:** done — `lead` deps installed, torch 2.7/cu128 kept (inference-only
   on the 5090). ✅

## Next actions (waiting on you)

Phase 1 is done. Open decisions:
1. **AdditionalMaps for the faithful R171 case** — the adjacent-lane `HighwayCutIn` routes
   (`2286`/`3072`) are Town12, not installed. Download `AdditionalMaps_0.9.15` (~4 GB), extract
   into `/opt/carla`, restart CARLA → then Phase 2 can run the faithful R171 cut-in. Until then,
   Town05 ParkingCutIn/StaticCutIn (`24759`/`26396`) cover the cut-in family.
2. **Dockerfile fix** (you chose "Also fix the Dockerfile") — bake the dep restore into the image
   so rebuilds don't wipe the env. Plan: build context → repo root + `.dockerignore`; add a
   `UV_PROJECT_ENVIRONMENT` `uv sync` (excluding the torch+nvidia stack); install torch cu128
   LAST. Awaiting go-ahead to edit the 4 files. (Consider also baking AdditionalMaps in.)

---

## References

- UNECE press release: https://unece.org/media/press/395206
- Applied Intuition — DCAS / UN R171: https://www.appliedintuition.com/blog/navigating-dcas-regulations
- ATIC — DCAS overview: https://www.atic-ts.com/european-driver-control-assistance-systems-dcas/
