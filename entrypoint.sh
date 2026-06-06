#!/bin/bash
set -euo pipefail

# Tunables (can be overridden via -e on docker run)
: "${CF_MODE:=run}"                # "init" or "run"
: "${CF_CPUS:=4}"
: "${CF_MEM_MB:=8192}"
: "${CF_GPU_MODE:=auto}"
: "${CF_VM_MANAGER:=crosvm}"
: "${CF_START_WEBRTC:=true}"

CF_ROOT=/cf
CF_HOST_DIR="$CF_ROOT/host"
CF_PRODUCT_DIR="$CF_ROOT/product"
CF_INSTANCE_DIR="$CF_ROOT/instance"

# -------- Run mode below --------

# 1) Sanity-check host tools
if [[ ! -x "$CF_HOST_DIR/bin/launch_cvd" ]]; then
  echo "[cf] ERROR: host tools not found in $CF_HOST_DIR."
  echo "[cf]        Expected $CF_HOST_DIR/bin/launch_cvd to exist."
  echo "[cf]        Run init first, for example:"
  echo "[cf]            cf-init.sh -P /path/to/cvd-host_package-x86_64.tar.gz"
  exit 1
fi

# 2) Sanity-check product images
if ! compgen -G "$CF_PRODUCT_DIR/*.img" > /dev/null \
   && [[ ! -f "$CF_PRODUCT_DIR/android-info.txt" ]]; then
  echo "[cf] ERROR: product images not found in $CF_PRODUCT_DIR."
  echo "[cf]        Run init with a product zip, for example:"
  echo "[cf]            cf-init.sh -P /path/to/aosp_cf_riscv64_phone-img-XXXX.zip"
  exit 1
fi

# Ensure host tools are reachable
#ln -sf "$CF_HOST_DIR"/bin/* /usr/local/bin/ || true
export PATH="$CF_HOST_DIR/bin:$PATH"

# Cuttlefish environment
export ANDROID_HOST_OUT="$CF_HOST_DIR"
export ANDROID_PRODUCT_OUT="$CF_PRODUCT_DIR"
export CVD_HOME="$CF_INSTANCE_DIR"
export HOME="$CF_HOST_DIR"

# Cuttlefish host network resources: cvd-ebr/cvd-wbr bridges, 10 taps each
# (cvd-{m,e,w}tap-NN), dnsmasq for guest DHCP, iptables MASQUERADE for NAT.
# Without this, qemu/crosvm create taps on demand with no master + no IP, so
# the guest has no DHCP / no NAT (crosvm also logs EIO ~132x during boot).
# ADB still works via vsock either way; this gives a clean boot log and real
# guest IP connectivity. `stop` first because the init script is not
# idempotent and bridges persist across runs in --network=host mode.
# Tear down any stale bridges from a prior run; do NOT bring fresh ones up.
# Bringing up bridges activates the guest's NetworkMonitor connectivity probes
# to www.google.com/gen_204, which DNS-blackholes from China and cascades
# into system_server stalls that trap launcher in Stopped state with all-black
# surfaces. ADB is vsock, WebRTC is direct via the webRTC binary — neither
# needs the bridges.
if [ -x /etc/init.d/cuttlefish-host-resources ]; then
    /etc/init.d/cuttlefish-host-resources stop  >/dev/null 2>&1 || true
fi

# WebRTC operator shim. The riscv64 cvd-host package doesn't ship a working
# webrtc_operator binary, so we substitute a small asyncio bridge that speaks
# the browser HTTPS/WS protocol on one side and the device unix-socket protocol
# on the other. Must be listening on /run/cuttlefish/operator before webRTC
# tries to connect (otherwise the early-init vsock retries we already see grow
# unbounded).
mkdir -p /run/cuttlefish /var/log/cuttlefish
echo "[cf] starting operator_shim on :8444 ..."
python3 /usr/local/bin/operator_shim.py \
    --listen-port 8444 \
    --operator-socket /run/cuttlefish/operator \
    --client-dir "$CF_HOST_DIR/usr/share/webrtc/assets" \
    --cert-dir "$CF_HOST_DIR/usr/share/webrtc/certs" \
    --verbose \
    > /var/log/cuttlefish/operator_shim.log 2>&1 &
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -S /run/cuttlefish/operator ] && break
    sleep 0.5
done

# VNC bridge: container 0.0.0.0:5900 -> container 127.0.0.1:6444 (Cuttlefish VNC)
socat TCP-LISTEN:5900,bind=0.0.0.0,reuseaddr,fork TCP:127.0.0.1:6444 &

echo "Launching Cuttlefish with launch_cvd:"
echo "  host_dir         = $CF_HOST_DIR"
echo "  system_image_dir = $CF_PRODUCT_DIR"
echo "  instance_dir     = $CF_INSTANCE_DIR"
echo "  cpus             = $CF_CPUS"
echo "  memory_mb        = $CF_MEM_MB"
echo "  gpu_mode         = $CF_GPU_MODE"
echo "  vm_manager       = $CF_VM_MANAGER"
echo "  start_webrtc     = $CF_START_WEBRTC"
echo "  WEBRTC           = 8443"
echo "  VNC              = 5900 (forwarded from localhost:6444)"
echo "  ADB TCP          = 6520"

exec launch_cvd \
  --system_image_dir="$CF_PRODUCT_DIR" \
  --instance_dir="$CF_INSTANCE_DIR" \
  --cpus="$CF_CPUS" \
  --memory_mb="$CF_MEM_MB" \
  --gpu_mode="$CF_GPU_MODE" \
  --vm_manager="$CF_VM_MANAGER" \
  --start_webrtc=$CF_START_WEBRTC \
  --report_anonymous_usage_stats=y \
  "$@" \
  || tail -f /dev/null
  # run forever even on error, for debugging
