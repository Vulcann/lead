#!/usr/bin/env bash
# check_carla.sh — 检查 CARLA 0.9.15 server 容器状态(内环底层)
# 用法: ./check_carla.sh [--port 2000] [--logs]
#   --port  RPC 端口(默认 2000)
#   --logs  额外打印最近 20 行容器日志
# 退出码: 容器运行 + RPC 端口监听 + Bench2Drive 附加地图齐全 → 0;否则 → 非 0(便于其他脚本/CI 调用)
set -euo pipefail
cd "$(dirname "$0")"

SERVICE="carla-server"
PORT=2000
SHOW_LOGS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2;;
    --logs) SHOW_LOGS=1; shift;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

echo "==> [1/3] 检查 ${SERVICE} 容器是否在运行"
# 复用 start_lead.sh 的判断:服务名精确匹配 running 状态的服务列表。
if ! docker compose ps --status running --services 2>/dev/null | grep -qx "${SERVICE}"; then
  echo "    ${SERVICE} 未运行。请先执行 ./start_carla.sh"
  exit 1
fi
echo "    ${SERVICE} 容器正在运行。"

echo "==> [2/4] 探测容器内 RPC 端口 ${PORT} 是否监听"
# carla 镜像内无 Python carla 包,且 compose 未把 2000 映射到宿主机,
# 故用容器内 bash 的 /dev/tcp 直接探测 RPC 端口(与 start_carla.sh 一致)。
if docker compose exec -T "${SERVICE}" \
     bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}" \
     >/dev/null 2>&1; then
  PORT_OK=1
  echo "    RPC 端口 ${PORT} 已监听 —— CARLA 服务就绪。"
else
  PORT_OK=0
  echo "    RPC 端口 ${PORT} 未监听 —— 容器在跑但服务可能仍在启动或已崩溃。"
fi

echo "==> [3/4] 检查 Bench2Drive 附加地图是否已导入 server"
# 基础镜像 carlasim/carla:0.9.15 只含 Town01-10HD;Bench2Drive 路线多在
# Town11/12/13/15(附加地图)。少了会在评测加载 world 时报 Map 'TownXX' not found。
# carla-server 内无 carla Python 包,直接 ls 镜像内地图目录最直接(派生镜像把附加图解到此)。
MAPS_DIR="/home/carla/carla/CarlaUE4/Content/Carla/Maps"
REQUIRED_MAPS="Town11 Town12 Town13 Town15"
MAP_LIST="$(docker compose exec -T "${SERVICE}" ls "${MAPS_DIR}" 2>/dev/null || true)"
if [[ -z "${MAP_LIST}" ]]; then
  MAPS_OK=0
  echo "    读不到地图目录 ${MAPS_DIR}(容器未就绪或镜像路径不符)。"
else
  MISSING=""
  for m in ${REQUIRED_MAPS}; do
    grep -qw "${m}" <<<"${MAP_LIST}" || MISSING="${MISSING} ${m}"
  done
  if [[ -n "${MISSING}" ]]; then
    MAPS_OK=0
    echo "    缺附加地图:${MISSING# } —— server 仍是无附加图的基础镜像。"
    echo "    需用带地图的派生镜像重建: ./start_carla.sh(见 carla-server.Dockerfile)"
  else
    MAPS_OK=1
    echo "    附加地图齐全(Town11/12/13/15)。"
  fi
fi

echo "==> [4/4] 容器概要(状态 / 重启次数)"
docker compose ps "${SERVICE}"

if [[ ${SHOW_LOGS} -eq 1 ]]; then
  echo ""
  echo "==> 最近 20 行日志:"
  docker compose logs --tail 20 "${SERVICE}"
fi

echo ""
if [[ ${PORT_OK} -eq 1 && ${MAPS_OK} -eq 1 ]]; then
  echo "结论: CARLA 服务正常(端口监听 + 附加地图齐全)。"
  exit 0
elif [[ ${PORT_OK} -ne 1 ]]; then
  echo "结论: CARLA 服务异常(端口未监听)。可查看日志: docker compose logs -f ${SERVICE}"
  exit 1
else
  echo "结论: 端口正常但缺 Bench2Drive 附加地图,评测会报 Map not found。请 ./start_carla.sh 重建带图镜像。"
  exit 1
fi
