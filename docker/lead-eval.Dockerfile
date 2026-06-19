FROM nvidia/cuda:12.8.0-devel-ubuntu24.04

# 容器内用户 —— 由 .env / compose build args 注入,默认对齐宿主机 weiyu(uid=1005,gid=1006)
ARG USERNAME=carla
ARG USER_UID=1005
ARG USER_GID=1006
ENV DEBIAN_FRONTEND=noninteractive

# 基础依赖(稳定,极少改动)—— 下面 node/conda/torch 都依赖它,放最前以保持缓存。
# 日常想加的工具不要写在这里,统一加到文件末尾的「日常追加」层,避免触发重型层重建。
RUN apt-get update && apt-get install -y --no-install-recommends \
        git git-lfs wget curl ca-certificates build-essential \
        ffmpeg parallel tree unzip zip libgl1 libglib2.0-0 \
        vim sudo \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20 LTS + Claude Code(系统级 npm 全局安装,放在 root 阶段)
# Claude Code 需要 Node 18+;装进镜像层,rebuild 后仍在。
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

# 非 root 用户(默认 carla),加入 sudo 组,密码=用户名。
# UID/GID 与宿主机对齐以避免挂载卷权限 / git 冲突。
# 注意:仅限隔离的内网开发容器使用;此凭据会留在镜像层历史中
RUN if ! getent group ${USER_GID} >/dev/null; then groupadd -g ${USER_GID} ${USERNAME}; fi && \
    useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash ${USERNAME} && \
    usermod -aG sudo ${USERNAME} && \
    echo "${USERNAME}:${USERNAME}" | chpasswd && \
    mkdir -p /workspace && chown ${USER_UID}:${USER_GID} /workspace
# 备选(更常用):免密 sudo,无需输入密码。二选一,勿同时启用
# RUN echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} && \
#     chmod 0440 /etc/sudoers.d/${USERNAME}

# 用户主目录,后续 miniforge / entrypoint 均引用,随用户名自动变化
ENV HOME_DIR=/home/${USERNAME}
USER ${USERNAME}
WORKDIR /workspace

# oh-my-bash(用户级,装到 ~/.oh-my-bash)。非交互安装,--unattended 不改默认 shell、不自动启动。
RUN bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended || true

# Claude Code 配置:宽松权限,仅危险命令需确认(见 claude-settings.json)
RUN mkdir -p ${HOME_DIR}/.claude
COPY --chown=${USER_UID}:${USER_GID} claude-settings.json ${HOME_DIR}/.claude/settings.json

# 把 Claude Code 的全局配置(原 ~/.claude.json)也收纳进 ~/.claude,
# 这样配置 + 历史 + 凭据集中在一个目录,compose 对它挂命名卷即可整体持久化,
# 不随容器重建而丢失(见 docker-compose.yml 的 claude-state 卷)。
ENV CLAUDE_CONFIG_DIR=${HOME_DIR}/.claude

# Miniforge(conda) — 用户级环境管理器,放在用户 home(不属于工作区)
RUN wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -O /tmp/mf.sh \
    && bash /tmp/mf.sh -b -p ${HOME_DIR}/miniforge3 && rm /tmp/mf.sh
ENV PATH=${HOME_DIR}/miniforge3/bin:$PATH

# 构建期创建 lead conda 环境 + 装工具 + 装 torch(大头,有缓存,不依赖源码)
RUN conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true && \
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true && \
    conda create -n lead python=3.10 -y && \
    conda run -n lead conda install -c conda-forge ffmpeg parallel tree gcc zip unzip git-lfs uv -y && \
    mkdir -p $HOME_DIR/miniforge3/envs/lead/etc/conda/activate.d $HOME_DIR/miniforge3/envs/lead/etc/conda/deactivate.d && \
    echo 'export VIRTUAL_ENV=$CONDA_PREFIX' > $HOME_DIR/miniforge3/envs/lead/etc/conda/activate.d/uv.sh && \
    echo 'unset VIRTUAL_ENV' > $HOME_DIR/miniforge3/envs/lead/etc/conda/deactivate.d/uv.sh && \
    conda run -n lead pip install torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0 --index-url https://download.pytorch.org/whl/cu128

# 日常追加的系统工具(经常增删)—— 单独放在最后一层,临时切回 root 安装。
# 在这里加包只重建本层,不会触发上面 node/conda/torch 的重建。
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        htop \
    && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}

# LEAD 源码不放进镜像:由宿主机挂载到 /workspace/lead(见 docker-compose.yml)。
# 这样宿主机改代码即时反映到容器,git 也在宿主机管理。
# 依赖安装(conda env + uv sync + torch)在 entrypoint 首次启动时完成。
COPY --chown=${USER_UID}:${USER_GID} entrypoint.sh ${HOME_DIR}/entrypoint.sh
ENTRYPOINT ["/bin/bash", "-c", "exec \"$HOME/entrypoint.sh\""]
