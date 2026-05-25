#!/usr/bin/env bash
set -euo pipefail

# 在 docker/ 目录下运行
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="lead:latest"

echo "═══════════════════════════════════════════════════════════════"
echo "  Building LEAD Docker image: $IMAGE_NAME"
echo "  This will take ~20-30 min (CARLA 0.9.15 is ~6GB)"
echo "═══════════════════════════════════════════════════════════════"

# 开启 BuildKit 以支持缓存优化
DOCKER_BUILDKIT=1 docker build \
    -t "$IMAGE_NAME" \
    -f Dockerfile.lead \
    --progress=plain \
    .

echo ""
echo "✅ Build complete. Image: $IMAGE_NAME"
docker images "$IMAGE_NAME"
