# chery-ADAS-Server — LEAD 闭环评测内环

单台 RTX 5090 上的 CARLA Leaderboard 2.0 闭环评测环境(LEAD 技术栈)。
5090 定位:评测引擎(推理 + 评测),不做本地训练。CARLA server 与 评测/开发端分离为两个 Docker 容器。

完整设计与选型依据见 `docs/LEAD-closed-loop-deployment.md`。

## 目录结构

```
chery-ADAS-Server/
├── .devcontainer/
│   └── devcontainer.json        # VS Code Dev Container,指向 docker/docker-compose.yml
├── docker/
│   ├── docker-compose.yml       # 双容器编排(根文件,脚本与 devcontainer 均依赖它)
│   ├── carla-server.Dockerfile  # CARLA 0.9.15 服务端镜像
│   ├── lead-eval.Dockerfile     # LEAD 评测/开发端镜像
│   ├── entrypoint.sh            # lead-eval 启动:校验挂载的 LEAD 源码、装依赖、等 CARLA 就绪
│   ├── claude-settings.json     # Claude Code 权限(宽松,仅 rm 等危险命令需确认)
│   ├── .env                     # 集中配置:UID/GID/用户名/LEAD 源码路径/CARLA 参数
│   ├── start_carla.sh           # 起 CARLA server + GPU/Vulkan 自检
│   ├── start_lead.sh            # 起 eval 容器并进入 shell
│   └── stop_all.sh              # 停止全部
└── docs/
    └── LEAD-closed-loop-deployment.md   # 完整部署文档
```

## 快速开始

前置:NVIDIA 驱动 + NVIDIA Container Toolkit;LEAD 源码已 clone 到宿主机(默认 `/home/weiyu/workspace/lead`)。CARLA 无需在宿主机安装——carla-server 镜像构建时自动下载 CARLA 0.9.15。

1) 改本机路径
- LEAD 源码路径:默认 `/home/weiyu/workspace/lead`,如不同则设环境变量 `LEAD_SRC` 或直接改 compose 里该挂载行。源码在宿主机管理,改代码即时反映到容器。
- 如需产出落在别处,改 `./outputs` / `./checkpoints` 为绝对路径。

2) 起容器
```bash
cd docker
./start_carla.sh          # 起 CARLA server(默认 Epic / 端口 2000),含 GPU/Vulkan 自检
./start_lead.sh           # 确认 CARLA 在跑后,起 eval 容器并进入 shell
```

3) 验证内环闭合(eval 容器内)
```bash
conda activate lead && cd /workspace/lead
bash scripts/download_one_checkpoint.sh
python -m lead \
  --checkpoint outputs/checkpoints/tfv6_resnet34 \
  --routes data/benchmark_routes/bench2drive/23687.xml \
  --bench2drive
# 看到 metric_info.json 分数 + 可视化视频 = 内环闭合
```

4) VS Code 开发:命令面板 → "Dev Containers: Reopen in Container"

停止:`cd docker && ./stop_all.sh`

## 重要提示

- **凭据**:两个容器的 carla 用户均加入 sudo 且密码=用户名(`carla`)。仅限隔离内网开发,生产/对外勿用。
- **CARLA 角色**:纯服务端,评测期间长驻,配 `restart: unless-stopped` 兜底崩溃;闲时可 `docker compose stop carla-server` 让出显存。
- **显存**:单卡 32GB,CARLA 渲染 + TFv6 推理共享,易 OOM。对策见文档 5.3(优先关 ensemble)。
- **关键改造**:评测器默认自己 spawn CARLA,双容器下需旁路、改连 `carla-server:2000`。见文档第 3 节。
