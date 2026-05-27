# LEAD + CARLA — Basic Concepts

The mental model, from the outside in.

## CARLA

An open-source **autonomous-driving simulator** built on Unreal Engine. It is **client–server**:

- The **server** (`CarlaUE4.sh`, what you start with `scripts/start_carla.sh`) runs the physics + 3D world and listens on a port (`2000`).
- A **client** (Python) connects over that port to spawn vehicles, attach **sensors** (cameras, LiDAR, radar, GPS), read their data, and send **control** (throttle / steer / brake).
- The world is a **Town** (map). `Town12` / `Town13` are the huge "Leaderboard 2.0" maps; `1711.xml` runs in Town12.
- Your **ego vehicle** is the car your agent drives.

## Leaderboard

CARLA's **evaluation framework**. It loads a route and runs your agent on it, tick by tick, then scores the drive.

- A **route** (the XML files) = a list of waypoints the ego must follow, plus scenarios triggered along the way.
- An **agent** is a Python class with a `run_step(sensors) → control` method. LEAD's lives at `lead/inference/sensor_agent.py`.
- **Track** matters: `SENSORS` = the agent only gets raw sensor data (realistic). `MAP` = it also gets privileged HD-map / ground-truth info. LEAD's model runs on `SENSORS`; the expert runs on `MAP`.
- **Metrics**: Driving Score (the "95 DS 🏆" badge), route completion %, and **infractions** (collisions, red lights, off-road) — written to `metric_info.json` / `infractions.json`.

## Scenario Runner (`srunner`)

Injects **dynamic events** into a route, defined as **behavior trees** (the `py-trees` dependency). The cut-in scenarios you care about for R171 — `HighwayCutIn`, `ParkingCutIn`, `StaticCutIn` — are exactly these: a vehicle is scripted to merge into the ego's lane at a trigger point.

## Bench2Drive

A specific **closed-loop benchmark** (a set of short Town12 routes + scenarios). It ships its own fork of leaderboard + scenario_runner, which is why they're vendored under `3rd_party/Bench2Drive/`. The `--bench2drive` flag selects this variant.

## LEAD

The project itself: **"Minimizing Learner-Expert Asymmetry in End-to-End Driving"** (Tübingen / NVIDIA / KE:SAI). An **end-to-end** driving model — sensors in, trajectory out, no hand-coded planner. The core idea behind the name:

- **Expert** (`lead/expert/`): a privileged rule-based autopilot that sees ground truth. It drives well and generates **training demonstrations**.
- **Learner** (`lead/tfv6/`): the neural net (TransFuser V6 — fuses camera + LiDAR/radar with a transformer; `tfv6_resnet34` is the ResNet-34-backbone variant you downloaded) that **imitates the expert using only sensors**.
- **"Learner–Expert Asymmetry"** = the gap between what the expert sees (privileged) and what the learner sees (sensors only). The paper is about shrinking that gap.

### The `lead/` subpackages map onto the workflow

| Dir | Role |
| --- | --- |
| `expert/` | privileged autopilot → data generation |
| `tfv6/` | the end-to-end model |
| `training/`, `data_loader/`, `data_buckets/` | train the learner from demonstrations |
| `inference/` | `sensor_agent.py` — runs the trained model closed-loop in CARLA |
| `plant/`, `carl/` | alternative agents (PlanT baseline, CaRL RL agent) |
| `webapp/` | Flask app to review eval results (videos, infractions) |
| `visualization/`, `common/` | helpers |

## How the closed loop fits together (what Phase 1 will do)

```text
you start:  CARLA server  (Town12, port 2000, -RenderOffScreen)
                  ▲  sensors ↓   ↑ control
python -m lead → Leaderboard evaluator → runs sensor_agent.py (the LEAD model)
                  + Scenario Runner injects the cut-in
                  → outputs/local_evaluation/1711/{metric_info,infractions}.json + video
```

## R171 connection

R171 is the UN regulation for L2 driver-assist; its certification catalogue includes a "cut-in from adjacent lane" case. We can't *certify* LEAD (it's full self-driving, no human), but we can **reuse CARLA's cut-in scenarios as R171-style test cases** and measure how the policy handles them — which is the whole point of Phases 1–3.

## Going deeper

The README's **§2 "CARLA Research Cycle"** (data → train → benchmark) and **§4 "Project Structure"** are the best next reads. The `qa` skill can answer specific "how does X work" questions against these docs.
