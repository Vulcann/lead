#!/usr/bin/bash
# Health check for a running CARLA server.  Usage: bash scripts/carla_status.sh [port]
# Exits 0 only if a real client handshake succeeds (1 otherwise).  A listening
# port is NOT enough — it can belong to a wedged or version-mismatched engine.

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
# wedged or version-mismatched engine, so do a real client handshake and let ITS
# exit code (not the port check) decide readiness.  A client/server API mismatch
# makes the C++ client abort() mid-handshake (std::bad_alloc, core dump) -> the
# python exits non-zero, which we treat as NOT responsive.
responsive=0
if [ "$port_up" = 1 ]; then
	# Capture stdout+stderr so we can diagnose a crash; the handshake either
	# prints an 'OK <client> <server> <map>' line or dies.
	probe=$(timeout 15 python - "$port" 2>&1 <<'PY'
import sys, carla
try:
	from importlib.metadata import version
	client_ver = version("carla")
except Exception:
	client_ver = "unknown"
c = carla.Client("localhost", int(sys.argv[1])); c.set_timeout(5.0)
print(f"OK {client_ver} {c.get_server_version()} {c.get_world().get_map().name}")
PY
)
	rc=$?
	okline=$(echo "$probe" | grep '^OK ' | head -1)
	if [ "$rc" -eq 0 ] && [ -n "$okline" ]; then
		read -r _ client_ver server_ver world_map <<<"$okline"
		echo "  responsive: YES — client $client_ver, server $server_ver, map $world_map"
		responsive=1
	else
		echo "  responsive: NO — handshake failed (exit $rc)"
		if echo "$probe" | grep -qi 'version mismatch'; then
			cv=$(echo "$probe" | grep -i 'Client API version'    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
			sv=$(echo "$probe" | grep -i 'Simulator API version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
			echo "             cause: API version mismatch — client ${cv:-?} vs simulator ${sv:-?} (incompatible)"
		fi
		echo "$probe" | grep -iE 'bad_alloc|terminate|Traceback|Error|refused|time-out|timeout' | head -3 | sed 's/^/             /'
	fi
fi

# 4. GPU footprint (confirms it's on the NVIDIA GPU, not software rendering).
gpu=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | grep -i carla)
if [ -n "$gpu" ]; then
	echo "  gpu      : $gpu"
fi

# Ready only if the handshake actually succeeded — not merely because the port
# is open (the misleading-READY bug this check used to have).
[ "$responsive" = 1 ]
