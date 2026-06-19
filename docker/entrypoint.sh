#!/bin/bash
# lead-eval 容器入口:校验挂载的 LEAD 源码、装依赖、等 CARLA 就绪。
# 步骤严格对齐 LEAD main 分支 README 第 1.1-1.2 节。
set -e
source "$HOME/miniforge3/etc/profile.d/conda.sh"

LEAD_DIR=/workspace/lead
# LEAD 源码由宿主机挂载到此(见 docker-compose.yml 的 LEAD_SRC)。
# 不在容器内 clone:若挂载缺失则明确报错,避免误用空目录。
if [ ! -d "$LEAD_DIR/.git" ] && [ ! -f "$LEAD_DIR/pyproject.toml" ]; then
  echo "ERROR: $LEAD_DIR 未挂载 LEAD 源码。"
  echo "       请在 docker-compose.yml 设置 LEAD_SRC 指向宿主机 LEAD 仓库"
  echo "       (默认 /home/weiyu/workspace/lead),或先在宿主机 clone LEAD。"
  exit 1
fi
cd "$LEAD_DIR"

# 注册项目根并 source 项目脚本(README 1.1)
export LEAD_PROJECT_ROOT="$(pwd)"
grep -q 'LEAD_PROJECT_ROOT' ~/.bashrc || \
  echo "export LEAD_PROJECT_ROOT=$(pwd)" >> ~/.bashrc
grep -q 'scripts/main.sh' ~/.bashrc || \
  echo "source $(pwd)/scripts/main.sh" >> ~/.bashrc
source "$(pwd)/scripts/main.sh" || true

# CARLA Python API 需在 3rd_party/CARLA_0915(README 1.2)。
# 双容器架构:CARLA 模拟器在 carla-server 镜像里;lead-eval 只需 Python API。
# 用 LEAD 自带 scripts/setup_carla.sh 下载到 3rd_party/CARLA_0915(含完整 PythonAPI)。
# 仅首次缺失时执行;下载到挂载的源码目录,rebuild 不重复。
if [ ! -e 3rd_party/CARLA_0915 ]; then
  echo "CARLA Python API 不存在,运行 scripts/setup_carla.sh 下载 ..."
  bash scripts/setup_carla.sh || echo "WARN: setup_carla.sh 失败,可手动 pip install carla==0.9.15"
fi

bash /workspace/lead/docker/setup-lead-env.sh

# 探测外部 CARLA server(双容器:连服务名 carla-server)。
# 非阻塞:开发时 carla-server 可能未启动,不应卡住进 shell。评测前用 start_carla.sh 启动。
if python -c "import carla; carla.Client('${CARLA_HOST:-carla-server}', ${CARLA_PORT:-2000}).get_server_version()" 2>/dev/null; then
  echo "carla-server is up."
else
  echo "提示:carla-server 暂未就绪。开发不受影响;评测前请在宿主机运行 ./start_carla.sh。"
fi

# 交给后续命令(评测/调试)。默认进入交互 shell。
exec "${@:-bash}"
