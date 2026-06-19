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

if ! conda env list | grep -q "^lead\b"; then
  # (某些镜像必需)接受 Anaconda 服务条款,否则 conda create 可能失败
  conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
  conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true

  conda create -n lead python=3.10 -y
  conda activate lead

  # 系统级工具(README 1.2)
  conda install -c conda-forge ffmpeg parallel tree gcc zip unzip git-lfs uv -y

  # 让 uv 使用 conda 环境:activate.d 与 deactivate.d 都要配(README 1.2)
  mkdir -p "$CONDA_PREFIX/etc/conda/activate.d" "$CONDA_PREFIX/etc/conda/deactivate.d"
  echo 'export VIRTUAL_ENV=$CONDA_PREFIX' > "$CONDA_PREFIX/etc/conda/activate.d/uv.sh"
  echo 'unset VIRTUAL_ENV'                > "$CONDA_PREFIX/etc/conda/deactivate.d/uv.sh"
  conda activate lead

  # 安装依赖(运行时 + dev,全部声明在 pyproject.toml)
  uv sync --active --extra dev

  # Blackwell / RTX 5090 必需:CUDA 12.8 的 PyTorch(README Tip)
  pip install torch==2.7.0 torchvision --index-url https://download.pytorch.org/whl/cu128

  # 可选:启用 git hooks
  pre-commit install || true
else
  conda activate lead
fi

# 探测外部 CARLA server(双容器:连服务名 carla-server)。
# 非阻塞:开发时 carla-server 可能未启动,不应卡住进 shell。评测前用 start_carla.sh 启动。
if python -c "import carla; carla.Client('${CARLA_HOST:-carla-server}', ${CARLA_PORT:-2000}).get_server_version()" 2>/dev/null; then
  echo "carla-server is up."
else
  echo "提示:carla-server 暂未就绪。开发不受影响;评测前请在宿主机运行 ./start_carla.sh。"
fi

# 交给后续命令(评测/调试)。默认进入交互 shell。
exec "${@:-bash}"
