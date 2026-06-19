# carla-server 镜像:基础 carlasim/carla:0.9.15 + Bench2Drive 附加地图。
#
# 为什么需要:官方镜像 carlasim/carla:0.9.15 只含 Town01-10HD;Bench2Drive 的
# 路线大量跑在 Town11/12/13/15(Additional Maps 包),缺图会在加载 world 时报
# `RuntimeError: Map 'Town12' not found`。
#
# 做了什么:把官方 AdditionalMaps_0.9.15 包解进 CARLA 根目录。对打包版 CARLA,
# “导入附加地图”本质就是把 tar 解到根目录(等价于 scripts/setup_carla.sh 里的
# ImportAssets.sh —— 它只是 `tar -x` 每个 Import/*.tar.gz)。tar 顶层为 CarlaUE4/
# 与 Engine/,解开后与镜像内已有内容合并。
#
# build context = 3rd_party/CARLA_0915/Import(配套同目录 .dockerignore 只保留 tar 包,
# 排除已解压的 ~18G CarlaUE4//Engine/,避免 context 爆炸)。start_carla.sh 负责
# 在构建前确保 tar 包存在并写好该 .dockerignore。
FROM carlasim/carla:0.9.15

# 解包要写入 /home/carla/carla(属主 carla),用 root 执行解压最稳妥。
USER root

# 7.4G tar 包;在同一 RUN 内解压并删除,避免残留进镜像层。
COPY AdditionalMaps_0.9.15.tar.gz /tmp/additional_maps.tar.gz
RUN tar -xzf /tmp/additional_maps.tar.gz -C /home/carla/ \
 && rm -f /tmp/additional_maps.tar.gz

# 还原基础镜像默认用户(server 以 carla 身份运行)。附加地图资源为只读访问,
# 解压保留的全局可读权限足够,无需 chown(整树 chown 会复制出一份巨大冗余层)。
USER carla
