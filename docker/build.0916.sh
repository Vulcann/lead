#!/usr/bin/env bash
set -euo pipefail

# 在 docker/ 目录下运行
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="lead:0.9.16"

echo "═══════════════════════════════════════════════════════════════"
echo "  Building LEAD Docker image: $IMAGE_NAME"
echo "  This will take ~30-60 min (CARLA 0.9.16 is ~8.3GB) + scenario_runner v0.9.16"
echo "═══════════════════════════════════════════════════════════════"

# 开启 BuildKit 以支持缓存优化。
# 构建上下文改为仓库根目录 (..)，这样 Dockerfile 的 §6.5 才能 COPY 根目录的
# pyproject.toml + uv.lock。根目录的 .dockerignore 只放行这两个文件，上下文仍然很小。
DOCKER_BUILDKIT=1 docker build \
    -t "$IMAGE_NAME" \
    -f Dockerfile.lead.0916 \
    --progress=plain \
    ..

echo ""
echo "✅ Build complete. Image: $IMAGE_NAME"
docker images "$IMAGE_NAME"
