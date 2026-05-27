#!/usr/bin/bash
# Health check for a running CARLA server.  Usage: bash scripts/carla_status.sh [port]
# Exits 0 if the server is reachable on the RPC port, 1 otherwise.

port=2000
if [ "$1" != "" ]; then
	port=$1
fi

echo "CARLA status (port $port)"

# 1. Process + uptime.
proc=$(ps -eo pid,etime,comm | grep CarlaUE4-Linux | grep -v grep)
if [ -n "$proc" ]; then
	echo "  process  : RUNNING  ($proc)"
else
	echo "  process  : NOT RUNNING"
fi

# 2. RPC port reachable.  /dev/tcp, not ss/netstat: under `docker --network=host`
# those can't enumerate the listening sockets and report false negatives.
if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
	echo "  port $port: UP"
	port_up=1
else
	echo "  port $port: DOWN"
	port_up=0
fi

# 3. Responsive — the source of truth.  A listening port can still belong to a
# wedged engine, so do a real client handshake (server version + loaded map).
if [ "$port_up" = 1 ]; then
	timeout 15 python - "$port" <<'PY'
import sys, carla
c = carla.Client("localhost", int(sys.argv[1])); c.set_timeout(5.0)
print(f"  responsive: YES — server {c.get_server_version()}, map {c.get_world().get_map().name}")
PY
fi

# 4. GPU footprint (confirms it's on the NVIDIA GPU, not software rendering).
gpu=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -i carla)
if [ -n "$gpu" ]; then
	echo "  gpu      : $gpu"
fi

[ "$port_up" = 1 ]
