#!/bin/bash
set -e
source "$HOME/miniforge3/etc/profile.d/conda.sh"
cd /workspace/lead

# 兜底:lead 环境正常应由镜像构建期创建,缺失才在这里补建
if ! conda env list | grep -q '^lead '; then
  # (某些镜像必需)接受 Anaconda 服务条款,否则 conda create 可能失败
  conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
  conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true
  conda create -n lead python=3.10 -y
  conda run -n lead conda install -c conda-forge ffmpeg parallel tree gcc zip unzip git-lfs uv -y
  conda run -n lead pip install torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0 --index-url https://download.pytorch.org/whl/cu128
fi
conda activate lead

# 依赖挂载的 LEAD 源码(pyproject.toml / uv.lock),幂等
uv sync --active --extra dev
pre-commit install || true
echo "[setup] lead 环境就绪。"
