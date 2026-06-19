#!/bin/bash
# lead-eval 容器入口(PID1):校验挂载源码 → 配置交互 shell → 装好环境 → 探测 CARLA → 进 shell。
# 环境安装统一委托 setup-lead-env.sh(唯一来源)。本脚本自身不 activate conda:
# 一次性探测用 `conda run -n lead`,交互 shell 由写入 ~/.bashrc 的 activate 负责。
set -e

LEAD_DIR=/workspace/lead

# 1) 校验宿主机挂载的 LEAD 源码(容器内不 clone;缺失即报错,避免误用空目录)
if [ ! -d "$LEAD_DIR/.git" ] && [ ! -f "$LEAD_DIR/pyproject.toml" ]; then
  echo "ERROR: $LEAD_DIR 未挂载 LEAD 源码。"
  echo "       请在 docker/.env 设置 LEAD_SRC 指向宿主机 LEAD 仓库(默认 /home/weiyu/workspace/lead)。"
  exit 1
fi
cd "$LEAD_DIR"

# 2) 交互式 shell 初始化:一次性把「激活 lead + 项目根 + 项目脚本」写入 ~/.bashrc(幂等)。
#    镜像用 miniforge -b 安装、未做 conda init,故显式 source conda.sh 再 activate。
if ! grep -q '>>> lead shell init >>>' ~/.bashrc; then
  cat >> ~/.bashrc <<'EOF'
# >>> lead shell init >>>
source $HOME/miniforge3/etc/profile.d/conda.sh
conda activate lead
export LEAD_PROJECT_ROOT=/workspace/lead
source /workspace/lead/scripts/main.sh
# <<< lead shell init <<<
EOF
fi

# 3) CARLA Python API(README 1.2):双容器下 lead-eval 只需 PythonAPI,首次缺失才下载到挂载目录。
if [ ! -e 3rd_party/CARLA_0915 ]; then
  echo "CARLA Python API 不存在,运行 scripts/setup_carla.sh 下载 ..."
  bash scripts/setup_carla.sh || echo "WARN: setup_carla.sh 失败,可手动 pip install carla==0.9.15"
fi

# 4) 安装/同步 lead 环境(唯一来源,幂等;devcontainer 的 postCreateCommand 不再重复此步)
bash "$LEAD_DIR/docker/setup-lead-env.sh"

# 5) 探测外部 CARLA server(非阻塞;start_lead.sh 靠下面 'carla-server is up.' 日志判断就绪)。
#    用 conda run 直接在 lead 环境里跑,无需在本进程 activate。
if conda run -n lead python -c \
     "import carla; carla.Client('${CARLA_HOST:-carla-server}', ${CARLA_PORT:-2000}).get_server_version()" 2>/dev/null; then
  echo "carla-server is up."
else
  echo "提示:carla-server 暂未就绪。开发不受影响;评测前请在宿主机运行 ./start_carla.sh。"
fi

# 交给后续命令(评测/调试);默认进入交互 shell(经 ~/.bashrc 自动激活 lead)。
exec "${@:-bash}"
