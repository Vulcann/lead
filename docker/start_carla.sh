#!/usr/bin/env bash
# start_carla.sh — 启动 CARLA 0.9.15 server 容器(内环底层)
# 用法: ./start_carla.sh [--quality Poor|Epic] [--port 2000] [--no-check]
# 前置: docker compose 已在本目录;/data/carla_0.9.15 已就绪;NVIDIA Container Toolkit 已装
set -euo pipefail
cd "$(dirname "$0")"

SERVICE="carla-server"
QUALITY="Epic"
PORT=2000
DO_CHECK=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quality) QUALITY="$2"; shift 2;;
    --port)    PORT="$2"; shift 2;;
    --no-check) DO_CHECK=0; shift;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

echo "==> [1/4] 检查宿主机 GPU 与 Container Toolkit"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: 宿主机找不到 nvidia-smi,请先装 NVIDIA 驱动"; exit 1
fi
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi -L \
  || { echo "ERROR: 容器内无法访问 GPU,检查 NVIDIA Container Toolkit"; exit 1; }

echo "==> [2/4] 构建并启动 ${SERVICE}(quality=${QUALITY}, port=${PORT})"
docker compose build "${SERVICE}"
# 通过环境变量把质量/端口传给 compose 的 command 覆盖
CARLA_QUALITY="${QUALITY}" CARLA_RPC_PORT="${PORT}" \
  docker compose up -d "${SERVICE}"

echo "==> [3/4] 等待 CARLA server 就绪(轮询 RPC 端口 ${PORT})"
# 容器内用 python+carla 探测;最多等 120s
ATTEMPTS=40
for i in $(seq 1 ${ATTEMPTS}); do
  if docker compose exec -T "${SERVICE}" \
       python -c "import carla; carla.Client('127.0.0.1',${PORT}).get_server_version()" \
       >/dev/null 2>&1; then
    echo "    CARLA server 已就绪。"
    break
  fi
  if [[ $i -eq ${ATTEMPTS} ]]; then
    echo "ERROR: 等待超时。最近日志:"; docker compose logs --tail 40 "${SERVICE}"; exit 1
  fi
  sleep 3
done

if [[ ${DO_CHECK} -eq 1 ]]; then
  echo "==> [4/4] Vulkan 自检(在 ${SERVICE} 容器内)"
  if docker compose exec -T "${SERVICE}" vulkaninfo 2>/dev/null | grep -qi "lavapipe"; then
    echo "WARNING: 检测到 lavapipe(CPU 软件渲染回退)—— GPU 未被 Vulkan 使用!"
    echo "         CARLA 会极慢。请检查 --gpus all 与 Container Toolkit。"
  else
    docker compose exec -T "${SERVICE}" vulkaninfo 2>/dev/null \
      | grep -iE "Vulkan Instance Version|deviceName" | head -n 4 || true
    echo "    Vulkan/GPU 渲染通道正常。"
  fi
else
  echo "==> [4/4] 跳过 Vulkan 自检(--no-check)"
fi

echo ""
echo "完成。查看日志: docker compose logs -f ${SERVICE}"
echo "进入容器:   docker compose exec ${SERVICE} bash"
