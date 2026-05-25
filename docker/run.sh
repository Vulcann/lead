#!/usr/bin/env bash
set -euo pipefail

# ─── 配置 ──────────────────────────────────────────────────────────
IMAGE_NAME="lead:latest"
CONTAINER_NAME="lead-dev"
HOST_WORKSPACE="${HOME}/workspace/lead"
HOST_HF_CACHE="${HOME}/.cache/huggingface"

# ─── 准备 ──────────────────────────────────────────────────────────
mkdir -p "$HOST_WORKSPACE" "$HOST_HF_CACHE"

# 如果容器已存在,先看状态
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")
    if [ "$STATUS" = "running" ]; then
        echo "📦 Container '$CONTAINER_NAME' already running. Attaching..."
        exec docker exec -it "$CONTAINER_NAME" /bin/bash
    else
        echo "📦 Container '$CONTAINER_NAME' exists but stopped. Removing..."
        docker rm -f "$CONTAINER_NAME"
    fi
fi

echo "🚀 Starting new container: $CONTAINER_NAME"

# ─── 启动 ──────────────────────────────────────────────────────────
docker run -it \
    --name "$CONTAINER_NAME" \
    --gpus all \
    --network host \
    --shm-size=16g \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    --ipc=host \
    -v "$HOST_WORKSPACE":/workspace/lead \
    -v "$HOST_HF_CACHE":/root/.cache/huggingface \
    -e WANDB_API_KEY="${WANDB_API_KEY:-}" \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    "$IMAGE_NAME" \
    /bin/bash
