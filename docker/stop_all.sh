#!/usr/bin/env bash
# stop_all.sh — 停止两个容器
# 用法: ./stop_all.sh [--volumes]
#   --volumes: 同时删除匿名卷(不影响 ./outputs、./checkpoints 等绑定挂载)
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--volumes" ]]; then
  echo "==> 停止容器并删除匿名卷(绑定挂载的 outputs/checkpoints 不受影响)"
  docker compose down -v
else
  echo "==> 停止容器(保留卷)"
  docker compose down
fi
echo "完成。"
