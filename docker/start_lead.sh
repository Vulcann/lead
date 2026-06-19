#!/usr/bin/env bash
# start_lead.sh — 启动 LEAD 评测容器(内环上层),并进入交互 shell
# 用法: ./start_lead.sh [--shell|--no-shell]
# 前置: carla-server 已先行启动(建议先跑 ./start_carla.sh)
set -euo pipefail
cd "$(dirname "$0")"

CARLA_SERVICE="carla-server"
EVAL_SERVICE="lead-eval"
ENTER_SHELL=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)    ENTER_SHELL=1; shift;;
    --no-shell) ENTER_SHELL=0; shift;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

echo "==> [1/3] 确认 ${CARLA_SERVICE} 正在运行"
if ! docker compose ps --status running --services | grep -qx "${CARLA_SERVICE}"; then
  echo "ERROR: ${CARLA_SERVICE} 未运行。请先执行 ./start_carla.sh"
  exit 1
fi

echo "==> [2/3] 构建并启动 ${EVAL_SERVICE}"
docker compose build "${EVAL_SERVICE}"
docker compose up -d "${EVAL_SERVICE}"
# entrypoint.sh 内部会轮询 carla-server:2000,等到就绪才放行。
# 这里跟随日志直到看到就绪标志(或超时退出跟随,不影响容器)。
echo "    跟随 entrypoint 日志(等待就绪标志),Ctrl-C 可随时退出跟随:"
# 就绪打印 'carla-server is up.';carla 未起时 entrypoint 打印 '暂未就绪' 兜底行。
# 两者任一出现即停止跟随,避免 carla 未运行时白等满 180s。
timeout 180 docker compose logs -f "${EVAL_SERVICE}" 2>/dev/null \
  | sed -E '/carla-server is up\.|暂未就绪/q' || true

echo "==> [3/3] eval 容器已就绪"
if [[ ${ENTER_SHELL} -eq 1 ]]; then
  # entrypoint 已把 conda activate lead 写入 ~/.bashrc,exec 出的 bash 自动进入 lead 环境。
  echo "    进入交互 shell(已自动激活 lead 环境,工作目录 /workspace/lead)。"
  exec docker compose exec "${EVAL_SERVICE}" bash
else
  echo "    进入容器: docker compose exec ${EVAL_SERVICE} bash"
fi
