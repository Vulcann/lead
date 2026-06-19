#!/usr/bin/env bash
# check_carla.sh — 在 lead 评测容器内检查 CARLA server 状态(容器内版)
# 用法: ./check_carla.sh [--host carla-server] [--port 2000]
#   默认 host/port 取自 compose 注入的 $CARLA_HOST/$CARLA_PORT(回退 localhost/2000)
# 说明: 容器内无 docker CLI,改用网络探测——lead 与 carla-server 同在 adas-net,
#       靠服务名 carla-server:2000 通信(评测连法相同)。宿主机请用 docker/check_carla.sh。
# 退出码: RPC 端口可连 → 0;否则 → 非 0(便于评测脚本/CI 调用)
set -euo pipefail

HOST="${CARLA_HOST:-localhost}"
PORT="${CARLA_PORT:-2000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

echo "==> 探测 CARLA RPC 端口 ${HOST}:${PORT}(超时 5s)"
if timeout 5 bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
  echo "结论: CARLA 服务可连 —— ${HOST}:${PORT} 端口监听中。"
  exit 0
else
  echo "结论: 连不上 ${HOST}:${PORT} —— carla-server 可能未启动或仍在加载。"
  echo "      请在宿主机检查/启动: cd docker && ./check_carla.sh 或 ./start_carla.sh"
  exit 1
fi
