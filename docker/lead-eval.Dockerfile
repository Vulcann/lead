FROM nvidia/cuda:12.8.0-devel-ubuntu24.04

# 容器内用户 —— 由 .env / compose build args 注入,默认对齐宿主机 weiyu(uid=1005,gid=1006)
ARG USERNAME=carla
ARG USER_UID=1005
ARG USER_GID=1006
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git git-lfs wget curl ca-certificates build-essential \
        ffmpeg parallel tree unzip zip libgl1 libglib2.0-0 \
        sudo \
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

# Miniforge(conda) — 用户级环境管理器,放在用户 home(不属于工作区)
RUN wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -O /tmp/mf.sh \
    && bash /tmp/mf.sh -b -p ${HOME_DIR}/miniforge3 && rm /tmp/mf.sh
ENV PATH=${HOME_DIR}/miniforge3/bin:$PATH

# LEAD 源码不放进镜像:由宿主机挂载到 /workspace/lead(见 docker-compose.yml)。
# 这样宿主机改代码即时反映到容器,git 也在宿主机管理。
# 依赖安装(conda env + uv sync + torch)在 entrypoint 首次启动时完成。
COPY --chown=${USER_UID}:${USER_GID} entrypoint.sh ${HOME_DIR}/entrypoint.sh
ENTRYPOINT ["/bin/bash", "-c", "exec \"$HOME/entrypoint.sh\""]
