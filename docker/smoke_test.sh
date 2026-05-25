#!/usr/bin/env bash
# 在容器内运行,验证环境完整性
set -euo pipefail

echo "═══════════════════════════════════════════════════════════════"
echo "  LEAD Docker Smoke Test"
echo "═══════════════════════════════════════════════════════════════"

PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    printf "  %-40s " "$name"
    if eval "$cmd" > /tmp/check.log 2>&1; then
        echo "✅"
        PASS=$((PASS+1))
    else
        echo "❌"
        echo "    └─ $(tail -1 /tmp/check.log)"
        FAIL=$((FAIL+1))
    fi
}

echo ""
echo "[1/4] System"
check "Ubuntu 22.04"       "grep -q 'Ubuntu 22.04' /etc/os-release"
check "glibc >= 2.31"      "ldd --version | awk '/2\.(3[1-9]|[4-9][0-9])/{f=1} END{exit !f}'"
check "GPU visible"        "nvidia-smi -L | grep -q GPU"
check "Vulkan available"   "vulkaninfo --summary 2>/dev/null | grep -q deviceName || true"

echo ""
echo "[2/4] Python / PyTorch"
check "Python 3.10"        "python --version | grep -q '3.10'"
check "conda env=lead"     "test \"\$CONDA_DEFAULT_ENV\" = \"lead\""
check "PyTorch 2.7"        "python -c 'import torch; assert torch.__version__.startswith(\"2.7\")'"
check "CUDA available"     "python -c 'import torch; assert torch.cuda.is_available()'"
check "CUDA 12.8"          "python -c 'import torch; assert \"12.8\" in torch.version.cuda or \"12.\" in torch.version.cuda'"
check "GPU compute"        "python -c 'import torch; x=torch.randn(100,100).cuda(); y=x@x.T; assert y.sum().item() != 0'"

echo ""
echo "[3/4] CARLA"
check "CARLA installed"    "test -f /opt/carla/CarlaUE4.sh"
check "CARLA Python API"   "python -c 'import carla; from importlib.metadata import version; print(version(\"carla\"))' 2>&1 | grep -qE '0\.9\.15'"
check "CARLA_ROOT set"     "test -n \"\$CARLA_ROOT\""
check "PYTHONPATH OK"      "echo \$PYTHONPATH | grep -q carla"

echo ""
echo "[4/4] LEAD workspace"
check "workspace mounted"  "test -d /workspace/lead"
check "CARLA symlink"      "test -L /workspace/lead/3rd_party/CARLA_0915 || test -d /workspace/lead/3rd_party/CARLA_0915"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Result: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi