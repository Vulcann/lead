# LEAD 闭环评测内环部署文档

> 目标:在单台 RTX 5090 上跑通 CARLA Leaderboard 2.0 闭环评测(内环)。
> 定位:5090 = 评测引擎(推理 + 评测),不做本地训练。
> 架构:CARLA server 与 评测/模型 client 分离到两个独立 Docker 容器。

---

## 0. 为什么选 LEAD(选型依据)

### 0.1 LEAD 是什么

LEAD(Learner-Expert Asymmetry in Driving,图宾根大学 + NVIDIA,CVPR 2026,arXiv 2512.20563)**不是一个单纯的评测框架,而是一个完整的端到端驾驶技术栈**:模型 + 数据集 + 训练管线 + 评测,一体化。这是它区别于其他方案的根本点。

它的研究内核回答一个问题:为什么在 CARLA 里用模仿学习训出来的策略,闭环表现总是上不去?答案是"学习者-专家不对称"——生成示范数据的特权专家策略与基于传感器的学生策略之间存在系统性鸿沟。论文识别了三类不对称:

- **可见性不对称**:专家会对被遮挡的物体做出反应,产生非因果、对学生没用的示范。
- **不确定性不对称**:专家用无噪声的状态输入(如其他车的精确速度/加速度),产生成功但危险的示范。
- **意图不对称**:学生的导航意图只用单个目标点表达,导致它不理解复杂的多车道机动。

LEAD 的解法是削减专家特权、强制传感器感知的示范、重新设计导航条件,产出一个新专家 + 数据集(LEAD)和改进的学生策略(TransFuser v6 / TFv6)。结果:TFv6 在所有主流公开 CARLA 闭环基准上达到 SOTA——Bench2Drive 95 DS,Longest6 v2 与 Town13 上把之前成绩翻倍以上。

### 0.2 闭环评测生态的三层结构

选型对比容易混淆,是因为候选项分散在不同层级,并非平级:

| 层级 | 是什么 | 代表 |
| --- | --- | --- |
| 顶层:完整技术栈 | 模型 + 数据 + 训练 + 评测,一体 | **LEAD(本次选型)** |
| 中层:评测协议/基准 | 定义"考什么题、怎么打分" | Bench2Drive、Longest6 v2、Town13、Fail2Drive |
| 底层:模拟器 | 物理、渲染、场景执行 | CARLA 0.9.15 |

LEAD 横跨顶层,并集成中层全部 4 套基准,运行在底层 CARLA 之上。

### 0.3 候选方案横向对比

| 候选 | 层级 | 不选的原因 |
| --- | --- | --- |
| 官方 CARLA Leaderboard 2.0 | 中层(评测引擎) | 只给评测引擎和打分规则,不含模型/数据/训练;要自己接 agent、采数据、调模仿学习。LEAD 已 fork 并封装了它 |
| Thinklab Bench2Drive | 中层(基准 + 弱 baseline) | baseline 已被甩开(UniAD 45.8 / VAD 42.35 DS,LEAD TFv6 达 95);工程化程度低,失败分析需自写。用 LEAD 可免费获得 Bench2Drive + 另外 3 套基准 + 强 baseline |
| NAVSIM | 不同评测范式 | 非反应式(non-reactive)仿真,基于真实数据 + 仿真指标打分,**不是真闭环**(车的动作不改变环境反应)。与 CARLA 闭环互补而非替代;且 LEAD 本身已集成 NAVSIM 训练管线,无需另维护一套 |
| 自研评测循环 | — | 隐藏陷阱多(崩溃恢复、端口冲突、传感器同步、场景超时、坐标系对齐),从零至少耗一个月,且都是前人踩过的坑 |

### 0.4 LEAD 的核心优点

1. **直面"模仿学习闭环上不去"的痛点**:这是 LEAD 区别于纯评测工具最本质处。其三类不对称分析(可见性/不确定性/意图)对 China→Europe 本地化场景直接相关——迁移面对的同样是分布偏移与示范不对称问题,LEAD 给了现成的诊断框架。
2. **SOTA baseline 作可信天花板**:TFv6 在所有主流公开 CARLA 闭环基准上 SOTA。接自研中国模型后若分数不如 TFv6,可确定问题在模型/迁移而非评测搭错。
3. **工程成熟度高**:自带失败分析 webapp(点击跳转事故前 N 秒、按违规类型过滤、FFmpeg 剪片段)、四套基准统一接口、SLURM 分布式封装、123D 标准数据格式——正是中环/外环所需零件。
4. **官方支持 RTX 5090 + Ubuntu 24.04**:测试矩阵明确标注 5090 Inference ✓,规避了 Blackwell 架构常见的 CUDA/PyTorch 兼容性坑。

### 0.5 需要知道的局限

- **学术项目,非工业级产品**:长期维护性取决于实验室(目前活跃,2026 年 5 月仍在更新)。
- **TFv6 为 CARLA 数据训练**:直接拿来评欧洲真实场景的迁移能力有限。它的价值是提供闭环评测地基 + 强 baseline,不直接解决本地化问题。
- **官方标注 5090 Training ✗**:与"只做推理评测"定位吻合;但若日后想在 5090 本地做训练实验,需自行趟坑。

> **一句话结论**:若目标只是"跑个分",任何基准都行;但目标是"搭一个能学习和迭代 E2E 系统的闭环",LEAD 是目前唯一把评测、强 baseline、训练管线、失败分析、标准数据格式打包在一起、且明确支持本机硬件的选择。

---

## 1. 背景与版本决策

| 项目 | 选定值 | 理由 |
| --- | --- | --- |
| CARLA | **0.9.15** | 与 Bench2Drive / Leaderboard 2.0 生态兼容;LEAD 官方即用此版本(路径写死 `3rd_party/CARLA_0915`) |
| 不升 0.9.16 | — | 0.9.16 新增 Cosmos/NuRec 数据增强与左手交通,与"先跑通评测"无关;且其 camera transform 修复会改变传感器对齐行为,可能引入 distribution shift |
| 框架 | **LEAD** (kesai-labs/lead, CVPR 2026) | 官方测试矩阵含 Ubuntu 24.04 + RTX 5090(Inference ✓ / Training ✗),与本机环境完全吻合 |
| PyTorch | **2.7.0 + CUDA 12.8** | Blackwell 架构(5090)硬性要求 |
| Baseline 模型 | **tfv6_resnet34**(60M) | Bench2Drive 94.72 DS;推理负载比 full RegNetY 轻,对 32GB 显存更友好 |

### LEAD 与 Bench2Drive 的关系

- **Bench2Drive** = 评测基准/协议:220 条短 route(各 ~150m、含 1 个安全关键场景,覆盖 44 类交互场景)+ Leaderboard 2.0 打分规则(DS = RC × IS)。
- **LEAD** = 端到端技术栈 + 评测框架:自带模型、专家数据采集、训练管线,并把 Bench2Drive 作为它支持的多个基准之一集成。
- 在 LEAD 里跑 `--bench2drive` 即加载 Bench2Drive 的 route 与场景,用其打分逻辑,但跑评测的 leaderboard/scenario_runner 引擎由 LEAD 维护。
- **结论**:无需单独安装 Thinklab/Bench2Drive。LEAD 一个仓库内含 Bench2Drive、Longest6 v2、Town13、Fail2Drive 四套基准,共用同一评测引擎与 agent 接口。

### 1.x 与 LEAD main 分支的核查记录(2026-06)

本文档与脚本已对照 LEAD `main` 分支 README(第 1.1–1.2 节)逐项核对,确认一致项与修正项:

- ✅ CARLA Python API 路径确为 `3rd_party/CARLA_0915`;`conda create -n lead python=3.10` + `uv sync --active --extra dev`;5090 需 `torch==2.7.0` + `cu128`;`scripts/download_one_checkpoint.sh`;评测命令 `python -m lead --checkpoint ... --bench2drive`;OOM 对策(屏蔽两 seed / `-quality-level=Poor`)。
- ✅ 5090 在官方测试矩阵为 Ubuntu 24.04 / CUDA 13.1 / Driver 590,Inference ✓ / Training ✗。
- 🔧 entrypoint 已补齐 README 要求但此前遗漏的步骤:`conda tos accept`(接受 Anaconda 服务条款,干净镜像未接受会导致 `conda create` 失败)、`deactivate.d/uv.sh`(此前仅建 `activate.d`)、可选 `pre-commit install`。
- ℹ️ CARLA 下载脚本名为 `scripts/setup_carla.sh`;LEAD 仓库自带 `.vscode/`、`.claude/` 及容器内的 `scripts/start_carla.sh`(与本仓库宿主机脚本同名但作用不同,见 5.5 节)。
- ⚠️ 复现论文分数需在 `config_closed_loop` 开启 `sensor_agent_creeping=True use_kalman_filter=True slower_for_stop_sign=True`;不开启则分数变化极小(Town13 反而更高)。

---

## 2. 双 Docker 架构总览

```
                Docker network: adas-net (bridge)
   ┌──────────────────────────┐        ┌──────────────────────────┐
   │  carla-server 容器        │  TCP   │  lead-eval 容器           │
   │  ────────────────         │ 2000/  │  ────────────────        │
   │  CARLA 0.9.15 server      │ 2001/  │  LEAD 评测进程            │
   │  (CarlaUE4, headless)     │ 2002   │  + TFv6 模型推理          │
   │  非 root 用户: carla      │◄──────►│  + scenario_runner        │
   │  GPU 渲染                 │        │  GPU 推理                 │
   └──────────────────────────┘        └──────────────────────────┘
          │                                      │
          └──────────── 共享同一块 RTX 5090 ──────┘
                        (两容器均 --gpus all)
```

### 为什么可行

CARLA 本身就是 client-server 架构,server(仿真+渲染)与 client(模型+评测)通过 TCP 通信,天然可拆分。拆分收益:
- 资源/故障隔离:CARLA 崩溃不影响评测容器,反之亦然(LEAD 常见问题里就有"重启模拟器""重启 leaderboard"两条独立修复项)。
- 镜像职责单一:CARLA 镜像只装模拟器;评测镜像只装 Python/PyTorch/LEAD,便于团队复用与 TISAX 审计。
- 数据边界清晰:模型权重、评测产出只存在于 eval 容器挂载卷,符合数据落盘可控要求。

### 接口契约

| 接口 | 值 | 说明 |
| --- | --- | --- |
| 主端口 | TCP **2000** | `carla.Client(host, port)` 连接的主端口 |
| streaming 端口 | TCP **2001** | server 自动占用,主端口 +1 |
| secondary 端口 | TCP **2002** | server 自动占用,主端口 +2 |
| host 解析 | `carla-server` | eval 容器通过 Docker network 服务名解析,**不要用 localhost** |
| GPU | 共享 RTX 5090 | 两容器均需 `--gpus all` |
| 容器用户 | `carla`,**UID/GID 1005** | 两容器一致,且与宿主机 `weiyu` 对齐 |

> 端口约定:CARLA 用 `--carla-port` 指定主端口后,会连带占用 +1 与 +2。若并行多实例需各错开 ≥3。生产中避免使用 <10000 的小端口(Bench2Drive 文档亦建议)。本文单实例,沿用默认 2000。

> UID/GID 对齐:两容器的 carla 用户均为 **UID 1005 / GID 1005**,刻意与宿主机用户 `weiyu`(`id weiyu` 显示 `uid=1005`)一致。Linux 文件权限认 UID 数字而非用户名,因此容器写入挂载卷(LEAD 源码、`outputs/`、`checkpoints/`)的文件,owner 与宿主机 weiyu 相同——这解决了 git 在宿主机与容器内交替操作时的权限冲突,也保证两容器互读对方产出。**若部署到 UID 不为 1005 的机器**,把两个 Dockerfile 里的 `1005` 改成该机用户的实际 UID/GID(`id <user>` 查),或走 VS Code Dev Container(`updateRemoteUserUID: true` 会自动对齐,但仅 Dev Container 生效,`docker compose` 命令行不生效)。

---

## 3. 关键改造点:让评测连接外部 CARLA

**这是双容器方案的核心,必须先理解。**

LEAD/Bench2Drive 的评测工具**默认在评测进程内部自动 spawn CARLA**(leaderboard_evaluator 内部启动 CarlaUE4 子进程)。双容器架构下,CARLA 在另一个容器里已经独立运行,因此必须**旁路掉这个自动启动逻辑,改为连接外部 host:port**。

### 定位与改法

1. **找到 server 启动逻辑。** 在 LEAD 仓库内搜索评测器对 CARLA 的拉起代码:
   ```bash
   grep -rn "CarlaUE4" lead/ 3rd_party/ scripts/
   grep -rn "subprocess.*[Cc]arla" lead/ 3rd_party/
   grep -rn "start_carla" scripts/
   ```
   重点看 `scripts/start_carla.sh` 与评测器(leaderboard_evaluator 类)里 spawn 子进程的段落。

2. **旁路 spawn,改连外部。** 两种做法,按侵入性从低到高:
   - **(推荐)环境变量/参数注入 host:port。** 评测器连接 CARLA 时用的是 `carla.Client(host, port)`。确保它读取的 host 是 `carla-server`、port 是 `2000`,而不是 `localhost`。通过 LEAD 的 config(`lead/inference/config_closed_loop.py`)或命令行参数传入。
   - **(必要时)注释/跳过启动子进程。** 若评测器无条件 spawn 本地 CarlaUE4,在 eval 容器内把该 spawn 段落改为条件判断:当检测到环境变量 `CARLA_EXTERNAL=1` 时跳过启动、直接进入连接逻辑。

3. **加就绪等待。** server 容器启动到可接受连接有延迟(尤其首次加载地图)。eval 容器启动评测前应轮询 2000 端口:
   ```bash
   until python -c "import carla; carla.Client('carla-server',2000).get_server_version()" 2>/dev/null; do
     echo "waiting for carla-server..."; sleep 3;
   done
   ```
   (Bench2Drive 文档也强调慢机器需延长 sleep 以避免 CARLA 崩溃。)

> 注意:`CUDA_VISIBLE_DEVICES` **不控制 CARLA 的渲染 GPU**,CARLA 由命令行 `-graphicsadapter=N` 控制。单卡场景通常 `-graphicsadapter=0`,但个别机器需试 `=1` 或更高。

---

## 4. CARLA Server 容器

### 4.1 Dockerfile(`docker/carla-server.Dockerfile`)

完整内容见 [`docker/carla-server.Dockerfile`](../docker/carla-server.Dockerfile)。关键设计点:

- 基于 `nvidia/cuda:12.8.0-runtime-ubuntu22.04`,装 Vulkan(headless 渲染必需)+ CARLA 运行库 + sudo。
- 容器内用户(默认 `carla`)与 UID/GID 由 build args 注入(见 `docker/.env`),默认对齐宿主机 weiyu(uid=1005, gid=1006)。
- `USER ${USERNAME}` 后以非 root 运行;CarlaUE4 拒绝 root 启动,故此为必需。
- `WORKDIR /opt/carla`,ENTRYPOINT 为 `CarlaUE4.sh`,默认 headless + 关声音。
- **CARLA 0.9.15 + AdditionalMaps 在构建时下载进镜像**(官方 S3),不依赖宿主机挂载、自包含。镜像较大(~15-20GB),构建较慢但一次到位。

> 说明:CARLA 体积大(数 GB),建议**挂载**预下载的 0.9.15 到 `/opt/carla`,而非 COPY 进镜像,保持镜像精简。`-RenderOffScreen` 是 0.9.15 的 headless 渲染参数(基于 Vulkan,无需 X server 实体显示)。
>
> 关于 sudo 与密码:`echo 'carla:carla' | chpasswd` 把密码设为与用户名相同(`carla`)。**仅限隔离内网开发容器**——此密码会写入镜像层历史(`docker history` 可见),且 `carla/carla` 属弱口令,生产/对外环境勿用。注意:容器以非交互 ENTRYPOINT 启动时不走登录认证,该密码仅在交互式 `sudo` 提权时生效;若不想每次输密码,改用上方注释的 NOPASSWD 免密方案。CARLA server 运行期本身不需要 root,sudo 仅供进容器手动调试时使用。

### 4.2 Vulkan 自检

CARLA headless 渲染依赖 Vulkan。容器内验证:
```bash
vulkaninfo | head -n 20   # 应看到 Vulkan Instance Version 1.1/1.2/1.3
```
出现 `lavapipe is not a conformant vulkan implementation, testing use only` 是软件渲染回退的告警,**说明没用上 GPU**——需检查 `--gpus all` 与 NVIDIA Container Toolkit 是否就绪。

---

## 5. LEAD 评测容器

### 5.1 Dockerfile(`docker/lead-eval.Dockerfile`)

完整内容见 [`docker/lead-eval.Dockerfile`](../docker/lead-eval.Dockerfile)。关键设计点:

- 基于 `nvidia/cuda:12.8.0-devel-ubuntu24.04`,装 git/ffmpeg/sudo 等;Miniforge 装在用户 home。
- 用户(默认 `carla`)/ UID / GID 由 build args 注入(见 `docker/.env`),与 carla-server 及宿主机对齐。
- LEAD 源码**不进镜像**,由宿主机挂载到 `/workspace/lead`(见 `docker/docker-compose.yml`)。
- CARLA Python API 不挂载;由 `entrypoint.sh` 首次启动调 LEAD 自带 `scripts/setup_carla.sh` 下载到 `3rd_party/CARLA_0915`。
- 依赖(conda env + `uv sync` + torch)由 `entrypoint.sh` 首次启动时安装。
- 预装 Claude Code(Node.js 20 + npm 全局)与 oh-my-bash;Claude Code 权限见 `docker/claude-settings.json`(详见 5.6)。

> 关于 sudo 与密码:与 carla-server 容器一致,密码设为与用户名相同(`carla`)。`sudo` 包必须在 `USER carla` 之前(以 root 身份)安装,提权配置同理。**仅限隔离内网开发容器**——密码写入镜像层历史且属弱口令,生产/对外环境勿用。容器以非交互 ENTRYPOINT 启动时该密码仅在交互式 `sudo` 提权时生效;不想每次输密码则改用上方注释的 NOPASSWD 免密方案。

### 5.2 entrypoint.sh(首次启动安装 + 等待 CARLA + 跑评测)

完整内容见 [`docker/entrypoint.sh`](../docker/entrypoint.sh)。它在容器首次启动时按 LEAD main 分支 README 第 1.1–1.2 节执行:

- 校验 `/workspace/lead` 已挂载 LEAD 源码(缺失则明确报错,不在容器内 clone)。
- 注册 `LEAD_PROJECT_ROOT`、source `scripts/main.sh`、软链 CARLA 到 `3rd_party/CARLA_0915`。
- 首次创建 conda `lead` 环境:`conda tos accept` → `conda create` → conda 工具 → 配 uv 的 `activate.d`/`deactivate.d` → `uv sync --active --extra dev` → 装 `torch 2.7.0 + cu128`(5090 必需)→ 可选 `pre-commit install`。
- 轮询 `carla-server:2000` 直到就绪,再交出交互 shell。

> 关于依赖安装位置:为加快二次启动,可把 conda 环境创建与 `uv sync` 移到 Dockerfile 的 `RUN` 阶段固化进镜像;此处放在 entrypoint 是为了让 LEAD 仓库与 CARLA 挂载保持灵活。团队稳定后建议固化进镜像。

### 5.3 显存对策(32GB 关键约束)

CARLA 渲染(预留 8–10GB) + TFv6 推理 共享单卡 32GB,极易 OOM。按优先级:

1. **关闭 ensemble(推荐,保渲染质量)** — 屏蔽后两个 seed:
   ```bash
   mv outputs/checkpoints/tfv6_resnet34/model_0030_1.pth \
      outputs/checkpoints/tfv6_resnet34/_model_0030_1.pth
   mv outputs/checkpoints/tfv6_resnet34/model_0030_2.pth \
      outputs/checkpoints/tfv6_resnet34/_model_0030_2.pth
   ```
2. **降 CARLA 渲染质量(仅调试,勿用于正式打分)** — server CMD 加 `-quality-level=Poor`。会引入 distribution shift。

### 5.4 VS Code Dev Container(开发在此容器内进行)

开发工作在 lead-eval 容器内进行,用 VS Code Dev Container 接入:本地编辑器界面,代码实际运行在容器的 conda/CUDA/CARLA Python API 环境里。配置文件 `.devcontainer/devcontainer.json` **复用现有 docker-compose**,而非另写容器定义——这样起开发容器时 carla-server 一并带起,同处 `adas-net` 网络,代码可直接连 `carla-server:2000`。

关键配置点:
- `dockerComposeFile` 指向 `../docker/docker-compose.yml`,`service: lead-eval`,`runServices` 同时含 carla-server。
- `remoteUser: carla` + `updateRemoteUserUID: true`:以非 root 的 carla 用户开发,UID 与挂载卷对齐。
- 终端 profile 自动 `conda activate lead`;Python 解释器指向 `/home/carla/miniforge3/envs/lead/bin/python`。
- `postCreateCommand` 在容器(重)建后校验 `torch` + `carla` 可导入;`postAttachCommand` 每次连接打印 GPU 占用与 carla-server 连通性。

**关于"自动更新"**:Dev Container 的更新语义是——改动 Dockerfile / compose / devcontainer.json 后,VS Code 会提示 **Rebuild Container**,按本地最新定义重建,`postCreateCommand` 随之重新执行,开发环境始终与定义一致。**不要**把它配成自动 `docker pull` 拉取远程镜像:开发容器的镜像就是你本地构建的,自动 pull 会冲掉你的环境。需要应用最新依赖时,命令面板执行 `Dev Containers: Rebuild Container` 即可。`shutdownAction: stopCompose` 保证关闭 VS Code 时一并停掉 compose 两个服务。

> 注意:首次打开 Dev Container 时,lead-eval 的 entrypoint 仍在 `uv sync` 装依赖,`postCreateCommand` 校验可能提示“尚未就绪”,等 entrypoint 完成后重连或重跑校验即可。如需缩短首次启动,可把依赖安装固化进 `docker/lead-eval.Dockerfile` 的构建阶段。

### 5.5 远程开发链路:本地 VS Code → 远程 5090 → Dev Container

完整链路是 **本地 VS Code(Remote-SSH)→ 5090 服务器 → Docker(lead-eval 容器)→ carla-server 容器**。VS Code 官方支持 Remote-SSH 与 Dev Containers 叠加,流程:

1. 本地 VS Code 装 `Remote - SSH` 与 `Dev Containers` 扩展。
2. `Remote-SSH: Connect to Host` 连到 5090 服务器,在服务器上 clone 本仓库(`chery-ADAS-Server`)。
3. 在远程窗口里 `Dev Containers: Reopen in Container`。VS Code Server 会在 5090 上读 `.devcontainer/devcontainer.json`,经 compose 起 lead-eval(并带起 carla-server),然后把 VS Code Server 注入容器。
4. 此后编辑器、终端、调试器都运行在容器内,GPU 经 `--gpus all` 对容器可见。

几个远程场景特有的注意点:

- **`workspaceFolder` 指向宿主机挂载的源码目录**:LEAD 源码放在宿主机(默认 `/home/weiyu/workspace/lead`,由 compose 的 `LEAD_SRC` 配置),挂载到容器内 `/workspace/lead`。容器一创建该目录即存在,devcontainer 的 `workspaceFolder` 直接指向 `/workspace/lead`,远程首次 `Reopen in Container` 不会因目录缺失报错。在宿主机改代码即时反映到容器,git 也在宿主机管理。依赖(conda env / `uv sync` / torch)由 entrypoint 首次启动时装入 conda 环境(`/home/carla/miniforge3/envs/lead`),不会在挂载的源码目录里建 `.venv`,因此不会污染宿主机 git 仓库。
- **GPU 在容器内对 VS Code 可见性**:VS Code 的 Python/Jupyter 调试在容器内跑,`nvidia-smi` 与 `torch.cuda.is_available()` 应为真;若否,排查同 4.2/10 节(`--gpus all`、NVIDIA Container Toolkit)。`postAttachCommand` 已会在每次连接时打印 GPU 占用,便于快速判断。
- **端口转发**:webapp(`localhost:5000`)与 CARLA 端口在远程容器内。VS Code 会自动转发容器端口到本地;webapp 用 `python lead/webapp/app.py` 起来后,在本地浏览器经 VS Code 的端口转发访问 5000。
- **与 LEAD 仓库自带 `.vscode/` 不冲突**:LEAD main 分支自带 `.vscode/`(及 `.claude/`、Claude Code 的 `/qa` 向导)。本仓库的 `.devcontainer/` 在外层 `chery-ADAS-Server/`,LEAD 的 `.vscode/` 在容器内 `/workspace/lead/`,层级不同、各司其职。

> 与上游脚本同名提示:LEAD 仓库内有 `scripts/start_carla.sh`(在容器内拉起本地 CARLA),本仓库 `docker/start_carla.sh`(在宿主机起 carla-server 容器)。双容器架构下,**用本仓库的宿主机脚本起 CARLA,容器内不要再调 LEAD 的 `scripts/start_carla.sh`**,否则会在 eval 容器内再起一个 CARLA、与外部 server 冲突。这正是第 3 节"旁路评测器自带 spawn"要解决的同一问题。

---

### 5.6 开发工具:Claude Code 与 oh-my-bash

lead-eval 镜像内预装了两个开发工具(见 [`docker/lead-eval.Dockerfile`](../docker/lead-eval.Dockerfile)):

- **Claude Code**:在 root 阶段经 Node.js 20 + `npm install -g @anthropic-ai/claude-code` 系统级安装,rebuild 后仍在。容器内直接 `claude` 启动。首次使用需在容器内完成一次登录认证。
- **oh-my-bash**:用户级安装到 `~/.oh-my-bash`,`--unattended` 方式安装(不强改默认 shell、不在安装时自动启动)。

**Claude Code 权限**(配置见 [`docker/claude-settings.json`](../docker/claude-settings.json),构建时 COPY 到 `~/.claude/settings.json`):采用宽松策略 —— 常用命令(git/python/pip/uv/conda/读写文件等)免确认放行(`allow`),仅危险命令需人工确认(`ask`):`rm`、`rmdir`、`sudo`、`git clean`、`git reset --hard`、`dd`、`mkfs`、`shred`、`truncate`、`docker`。`defaultMode` 为 `acceptEdits`(文件编辑免确认)。

> 权限语义:Claude Code 的 `allow` 免确认、`ask` 每次询问、`deny` 直接拒绝。本配置把危险命令放进 `ask`(询问)而非 `deny`(禁止),因此 `rm` 等仍可执行,只是每次需你确认 —— 符合"宽松、仅关键命令人工确认"的要求。如需更严格,把对应项从 `ask` 移到 `deny` 即可。

> settings.json 在镜像构建时写入 `~/.claude/`。若你在宿主机挂载了自己的 `~/.claude`,以挂载为准;否则用镜像内置的这份。

---

## 6. docker-compose(`docker/docker-compose.yml`)

完整内容见 [`docker/docker-compose.yml`](../docker/docker-compose.yml) 与集中配置 [`docker/.env`](../docker/.env)。要点:

- 两个 service(carla-server / lead-eval)共用 `adas-net` bridge 网络;服务名即 DNS,故 lead-eval 连 `carla-server:2000`。
- 用户 UID/GID/用户名经 build args 从 `.env` 注入;换机器/换用户只改 `.env` 后 `docker compose build`。
- carla-server:`restart: unless-stopped`(崩溃自愈);CARLA 质量/端口由 `.env` 的 `CARLA_QUALITY`/`CARLA_RPC_PORT` 覆盖。
- lead-eval 挂载:宿主机 LEAD 源码(`LEAD_SRC` → `/workspace/lead`,读写)、`outputs/` 与 `checkpoints/`;CARLA 不挂载(API 由 entrypoint 下载)。
- **开发/评测解耦**:lead-eval 不设 `depends_on: carla-server`,Dev Container 只起 lead-eval;评测时用 `start_carla.sh` 单独起 carla-server。两者经 adas-net 在运行时连接。
- 两 service 均 `--gpus all` 共享 RTX 5090。

> `depends_on` 只保证启动顺序,不保证 CARLA "就绪"——真正的就绪由 entrypoint 里的轮询负责。

---

## 7. 落地执行顺序

### 7.1 准备(宿主机)

```bash
# NVIDIA Container Toolkit 必须就绪
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi

# 预下载 CARLA 0.9.15 到 /data/carla_0.9.15(含 AdditionalMaps)
```

### 7.2 起容器

推荐用仓库提供的脚本(见第 8 节),它们封装了 GPU 自检、就绪轮询与 Vulkan 检查:

```bash
cd docker
./start_carla.sh          # 起 CARLA server + GPU/Vulkan 自检 + 等就绪
./start_lead.sh           # 确认 CARLA 在跑后,起 eval 容器并进入 shell
```

等价的手动命令:

```bash
cd docker
docker compose build
docker compose up -d carla-server
docker compose logs -f carla-server   # 看到稳定输出、无持续报错即就绪
docker compose up -d lead-eval
docker compose exec lead-eval bash    # 进 eval 容器,entrypoint 已等到 CARLA 就绪
```

### 7.3 验证单条 route(内环闭合的标志)

容器内:
```bash
conda activate lead && cd /workspace/lead
bash scripts/download_one_checkpoint.sh

export LEAD_CLOSED_LOOP_CONFIG="produce_demo_video=true produce_debug_video=true"
python -m lead \
  --checkpoint outputs/checkpoints/tfv6_resnet34 \
  --routes data/benchmark_routes/bench2drive/23687.xml \
  --bench2drive
```

产出在 `outputs/local_evaluation/<route_id>/`:
- `metric_info.json` — 评测分数(最终打分依据)
- `infractions.json` — 逐步违规记录(供 webapp 与 corner case 挖掘)
- `*_debug.mp4 / *_demo.mp4 / *_grid.mp4` — 可视化视频

**看到分数 + 视频 = 内环闭合。**

### 7.4 跑完整 220 条 Bench2Drive

```bash
git clone https://huggingface.co/ln2697/tfv6 outputs/checkpoints
( cd outputs/checkpoints && git lfs pull )
bash scripts/eval_bench2drive.sh
```

> **吞吐现实**:单卡 5090 无法用 LEAD 的 SLURM 多卡并行。220 条短 route 串行,按小时计,通常需跑一夜。实验节奏按"一晚一个模型"规划。

### 7.5 失败分析(中环起点)

LEAD 自带 Flask 失败分析面板,即"corner case 挖掘"的现成工具:
```bash
python lead/webapp/app.py    # localhost:5000;eval 容器需映射 5000 端口或用 SSH 隧道
```
支持:按违规类型过滤路线、点击跳转事故前 1/3/5 秒、FFmpeg 剪片段。**先用它人工过一遍失败模式,再决定是否自动化。**

---

## 8. 启动脚本(`docker/*.sh`)

仓库在 `docker/` 下提供三个脚本,封装常用操作。均带 `set -euo pipefail`,出错即停。

| 脚本 | 作用 | 关键步骤 |
| --- | --- | --- |
| `start_carla.sh` | 启动 CARLA server | ① 宿主机+容器内 GPU 自检 → ② build & up → ③ 轮询 RPC 端口直到就绪(超时 120s)→ ④ Vulkan 自检(检出 lavapipe 即告警 GPU 未生效) |
| `start_lead.sh` | 启动 eval 容器并进入 | ① 确认 carla-server 在运行 → ② build & up → ③ 跟随 entrypoint 日志直到 `carla-server is up.` → ④ 进入交互 shell |
| `stop_all.sh` | 停止两容器 | `docker compose down`;加 `--volumes` 同时删匿名卷(绑定挂载的 outputs/checkpoints 不受影响) |

常用调用:

```bash
cd docker
./start_carla.sh                      # 默认 Epic 质量、端口 2000
./start_carla.sh --quality Poor       # 调试用低质量渲染(勿用于正式打分)
./start_carla.sh --no-check           # 跳过 Vulkan 自检
./start_lead.sh                       # 起 eval 并进 shell
./start_lead.sh --no-shell            # 只起容器不进 shell
./stop_all.sh                         # 停止
```

> 脚本依赖 compose 的 `carla-server` 服务支持 `CARLA_QUALITY` / `CARLA_RPC_PORT` 环境变量覆盖 command(见第 6 节 compose 定义)。`start_carla.sh` 的就绪探测在容器内连 `127.0.0.1`(容器自身),与 eval 容器连 `carla-server` 服务名是两个不同视角,都正确。

---

## 9. 与长期目标的衔接(留接口,暂不实现)

- **外环(训练)接口已就绪**:LEAD 自带 CaRL(PPO RL planner)、NAVSIM 训练管线、PlanT 2.0 快速迭代工具。Poutine/GRPO 路线的落点应是**替换/扩展 LEAD 的 planning post-training 阶段**,而非另起炉灶。
- **中环数据格式建议用 123D**:LEAD 用 Apache Arrow 的 123D 格式(按模态分文件、统一 ISO 8855 坐标系),天然适合后续把中国数据与 CARLA 数据统一进同一管线,对应 China→Europe 本地化需求。
- **坐标系坑(接自研中国模型时第一个要踩的)**:LEAD 的 NAVSIM checkpoint 在 CARLA 左手坐标系下预测,推理后需把 waypoint/heading 转回 ISO 8855 再评测。接入任何外部模型时,先核对坐标系约定。

---

## 10. 常见问题速查

| 问题 | 处理 |
| --- | --- |
| eval 容器连不上 CARLA | 确认用服务名 `carla-server` 而非 `localhost`;确认 server 已就绪(轮询通过);两容器在同一 `adas-net` |
| Vulkan 报 lavapipe 告警 | 没用上 GPU——检查 `--gpus all` / NVIDIA Container Toolkit;`vulkaninfo` 应显示 1.1+ |
| 评测时 OOM | 关 ensemble(屏蔽后两 seed);调试时 server 加 `-quality-level=Poor` |
| CARLA 卡死/无响应 | 重启 carla-server 容器(独立容器的隔离优势) |
| route/评测失败 | 重启评测进程(对应 LEAD 文档"重启 leaderboard") |
| 数据缓存损坏 | 删除并重建训练缓存/buckets |
| `-graphicsadapter=1` 不可用 | 单卡试 `=0`;多卡可能需试更高编号 |
| 端口冲突 | `lsof -i:2000` 排查;避免 <10000 的小端口 |
```
