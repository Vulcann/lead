#!/usr/bin/bash

# UE4 refuses to launch as root, so the server must run as the unprivileged
# `carla` user. But here NVIDIA's Vulkan driver needs CAP_DAC_OVERRIDE to read
# the GPU's root-only PCI BAR files (/sys/bus/pci/.../resourceN, mode 0600);
# without it vkCreateInstance fails and UE4 falls back to the llvmpipe software
# renderer (RenderThread times out after 60s -> segfault). So when started as
# root we drop to `carla` via setpriv while keeping just that one capability as
# an ambient cap. The LEAD client talks to the server over TCP, so the server's
# user is independent of the client's; CARLA_ROOT/HOME are passed through.
if [ "$(id -u)" -eq 0 ]; then
	# Self-heal the NVIDIA Vulkan ICD descriptor. The driver libs are injected by
	# the NVIDIA Container Toolkit, but on a container reboot/recreation the ICD
	# JSON that VK_ICD_FILENAMES points to can go missing while libGLX_nvidia.so.0
	# (which exports vk_icdGetInstanceProcAddr) is still present. Without the JSON
	# the loader can't find the driver -> vkCreateInstance fails -> CARLA exits
	# instantly with an empty log. Recreate it (needs root) before dropping to carla.
	icd=/usr/share/vulkan/icd.d/nvidia_icd.json
	if [ ! -f "$icd" ] && ldconfig -p | grep -q libGLX_nvidia.so.0; then
		echo "[start_carla] $icd missing -> recreating NVIDIA Vulkan ICD descriptor"
		cat >"$icd" <<-'EOF'
			{
			    "ICD": { "api_version": "1.3.289", "library_path": "libGLX_nvidia.so.0" },
			    "file_format_version": "1.0.0"
			}
		EOF
	fi
	echo "[start_carla] root -> drop to 'carla' + ambient CAP_DAC_OVERRIDE (NVIDIA Vulkan needs it)"
	exec setpriv --reuid="$(id -u carla)" --regid="$(id -g carla)" --init-groups \
		--inh-caps=+dac_override --ambient-caps=+dac_override \
		env HOME=/home/carla "CARLA_ROOT=$CARLA_ROOT" "$0" "$@"
fi

# Non-root path: CAP_DAC_OVERRIDE is capability bit 1 of CapEff. If it's missing
# we were launched directly as a normal user (not via the root drop above), so
# NVIDIA Vulkan will fail -> warn rather than silently render on the CPU.
cap_eff=0x$(awk '/^CapEff/{print $2}' /proc/self/status)
if (( ((cap_eff >> 1) & 1) == 0 )); then
	echo "[start_carla] WARNING: no CAP_DAC_OVERRIDE — NVIDIA Vulkan will fail on this host."
	echo "             Launch as root so the script can grant it:  sudo bash $0 $*"
fi

port=2000
# if there is first argument, use it as port
if [ "$1" != "" ]; then
	port=$1
fi

streaming_port=$((port + 1))
if [ "$2" != "" ]; then
	streaming_port=$2
fi

# Refuse to launch if the RPC port is already bound. UE4 doesn't fail cleanly on
# a taken port — it segfaults during bind, leaving an empty log and no process,
# which looks identical to a slow boot. (Common trap: another CARLA, possibly in
# a different container under --network=host, already owns the port.) /dev/tcp,
# not ss/netstat, since those report false negatives under --network=host.
if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
	echo "[start_carla] ERROR: port $port is already in use — not launching."
	echo "              Check who owns it (bash scripts/carla_status.sh $port), then either"
	echo "              stop it or start on a free port:  bash $0 <free-port>"
	exit 1
fi

# Force the NVIDIA GPU. The Vulkan loader otherwise also exposes the Mesa
# llvmpipe (CPU) device, which UE4 picks as adapter 0 -> software rendering ->
# the RenderThread can't draw the map within 60s and CARLA segfaults. Pointing
# the loader at the NVIDIA ICD alone leaves the discrete GPU as the only device.
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json

log="/tmp/carla_${port}.log"
echo "[start_carla] launching CARLA (detached) on port $port; logs -> $log"
# setsid detaches into a new session so the server survives the launching shell
# exiting (a plain '&' job gets reaped when the session/process group ends).
setsid "$CARLA_ROOT/CarlaUE4.sh" \
    -quality-level=Poor \
    -world-port=$port \
    -resx=800 \
    -resy=600 \
    -nosound \
    -graphicsadapter=0 \
    -carla-streaming-port=$streaming_port \
    -RenderOffScreen >"$log" 2>&1 </dev/null &
