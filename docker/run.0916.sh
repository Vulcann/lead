#!/usr/bin/env bash
set -euo pipefail

# ─── 配置 ──────────────────────────────────────────────────────────
# 0.9.16 镜像专用,容器名与 0.9.15 的 lead-dev 区分,可并存。
# 注意:两个容器都挂载同一个 host workspace 且 --network host,
# 同时跑 CARLA server 时要错开端口 (-carla-rpc-port)。
IMAGE_NAME="lead:0.9.16"
CONTAINER_NAME="lead-dev-0916"
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

# ─── NVIDIA 驱动库注入补丁 ─────────────────────────────────────────
# nvidia-container-toolkit (libnvidia-container 1.19.0) 的注入清单漏了
# libnvidia-api.so.1 —— 这是 570+/580 驱动分支 GL/Vulkan 栈的依赖。少了它,
# libGLX_nvidia 无法初始化,vkCreateInstance -> ERROR_INCOMPATIBLE_DRIVER,
# CARLA 的 RenderThread 拿不到 Vulkan device 直接段错误(空日志)。
# 工具链不会注入(不在它的 list 里),所以从 host 手动 bind-mount 进去。
# 检查是否还有别的被漏掉的 580 库:
#   comm -23 <(ls /usr/lib/x86_64-linux-gnu/libnvidia-*so.580.159.03 | sort) \
#            <(sudo nvidia-container-cli list | grep 580.159.03 | sort)
EXTRA_NVIDIA_MOUNTS=()
for lib in libnvidia-api.so.1; do
    host_lib="/usr/lib/x86_64-linux-gnu/${lib}"
    [ -e "$host_lib" ] && EXTRA_NVIDIA_MOUNTS+=( -v "${host_lib}:${host_lib}:ro" )
done

# ─── 启动 ──────────────────────────────────────────────────────────
docker run -it \
    --name "$CONTAINER_NAME" \
    --gpus all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    --network host \
    --shm-size=16g \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    --ipc=host \
    "${EXTRA_NVIDIA_MOUNTS[@]}" \
    -v "$HOST_WORKSPACE":/workspace/lead \
    -v "$HOST_HF_CACHE":/root/.cache/huggingface \
    -e WANDB_API_KEY="${WANDB_API_KEY:-}" \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    "$IMAGE_NAME" \
    /bin/bash
