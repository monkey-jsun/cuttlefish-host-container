#!/bin/bash
set -euo pipefail

CF_ROOT=/cf
CF_HOST_DIR="$CF_ROOT/host"
CF_PRODUCT_DIR="$CF_ROOT/product"
CF_INSTANCE_DIR="$CF_ROOT/instance"

# Tunables (can be overridden via -e on docker run)
: "${CF_MODE:=run}"                # "init" or "run"
: "${CF_CPUS:=4}"
: "${CF_MEM_MB:=8192}"
: "${CF_GPU_MODE:=auto}"

# URLs baked in at build time by cf-build.sh -H/-P; empty otherwise.
: "${CF_HOST_PACKAGE_URL:=}"
: "${CF_PRODUCT_IMG_URL:=}"

mkdir -p "$CF_HOST_DIR" "$CF_PRODUCT_DIR" "$CF_INSTANCE_DIR"

# A progress bar redraws with \r, which a log file renders as one endless line.
if [ -t 2 ]; then CURL_PROGRESS=(--progress-bar); else CURL_PROGRESS=(-sS); fi

# 1) Host tools
if [[ ! -x "$CF_HOST_DIR/bin/launch_cvd" ]]; then
  if [[ -n "$CF_HOST_PACKAGE_URL" ]]; then
    echo "[cf] Fetching host package from $CF_HOST_PACKAGE_URL"
    rm -rf "${CF_HOST_DIR:?}"/*
    if ! curl -fL "${CURL_PROGRESS[@]}" "$CF_HOST_PACKAGE_URL" | tar -xzf - -C "$CF_HOST_DIR"; then
      echo "[cf] ERROR: could not fetch or unpack $CF_HOST_PACKAGE_URL"
      exit 1
    fi
    echo "[cf] Host package unpacked into $CF_HOST_DIR"
  else
    echo "[cf] ERROR: host tools not found in $CF_HOST_DIR."
    echo "[cf]        Expected $CF_HOST_DIR/bin/launch_cvd to exist."
    echo "[cf]        Run init first, for example:"
    echo "[cf]            cf-init.sh -H /path/to/cvd-host_package-x86_64.tar.gz"
    exit 1
  fi
fi

# 2) Product images
if ! compgen -G "$CF_PRODUCT_DIR/*.img" > /dev/null \
   && [[ ! -f "$CF_PRODUCT_DIR/android-info.txt" ]]; then
  if [[ -n "$CF_PRODUCT_IMG_URL" ]]; then
    echo "[cf] Fetching product images from $CF_PRODUCT_IMG_URL"
    rm -rf "${CF_PRODUCT_DIR:?}"/*
    zip="$CF_ROOT/.cf-product.zip"
    if ! curl -fL "${CURL_PROGRESS[@]}" -o "$zip" "$CF_PRODUCT_IMG_URL"; then
      echo "[cf] ERROR: could not fetch $CF_PRODUCT_IMG_URL"
      rm -f "$zip"
      exit 1
    fi
    unzip -n -q "$zip" -d "$CF_PRODUCT_DIR"
    rm -f "$zip"
    echo "[cf] Product images unpacked into $CF_PRODUCT_DIR"
  else
    echo "[cf] ERROR: product images not found in $CF_PRODUCT_DIR."
    echo "[cf]        Run init with a product zip, for example:"
    echo "[cf]            cf-init.sh -P /path/to/aosp_cf_riscv64_phone-img-XXXX.zip"
    exit 1
  fi
fi

# Echo normalized host arch.
detect_host_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    arm64) echo "aarch64" ;;
    amd64) echo "x86_64" ;;
    *)     echo "$arch" ;;
  esac
}

# Echo guest arch from boot.img's kernel, or return 1.
detect_guest_arch() {
  local bootimg="$CF_PRODUCT_DIR/boot.img"
  [[ -f "$bootimg" ]] || return 1
  command -v file >/dev/null 2>&1 || return 1
  local ksize tmp info
  ksize=$(od -An -tu4 -N4 -j8 --endian=little "$bootimg" 2>/dev/null | tr -d ' ')
  [[ -n "$ksize" && "$ksize" -gt 0 && "$ksize" -lt 1000000000 ]] || return 1
  tmp=$(mktemp /tmp/cf-kernel.XXXXXX)
  dd if="$bootimg" of="$tmp" bs=4096 skip=1 count=$((ksize / 4096 + 2)) status=none 2>/dev/null
  info=$(file -L "$tmp" 2>/dev/null)
  rm -f "$tmp"
  case "$info" in
    *"x86 boot"*|*x86-64*|*x86_64*) echo "x86_64" ;;
    *aarch64*|*ARM64*)              echo "aarch64" ;;
    *RISC-V*|*riscv64*)             echo "riscv64" ;;
    *)                              return 1 ;;
  esac
}

# crosvm needs the host and guest arch to match; qemu_cli emulates. cf-run.sh
# normally passes CF_VM_MANAGER, so this only fires on a direct docker run.
if [[ -z "${CF_VM_MANAGER:-}" ]]; then
  guest_arch=$(detect_guest_arch) || guest_arch=""
  if [[ -z "$guest_arch" ]]; then
    echo "[cf] WARNING: cannot read guest arch from $CF_PRODUCT_DIR/boot.img;"
    echo "[cf]          using qemu_cli.  Set CF_VM_MANAGER to override."
    CF_VM_MANAGER=qemu_cli
  elif [[ "$(detect_host_arch)" == "$guest_arch" ]]; then
    CF_VM_MANAGER=crosvm
  else
    CF_VM_MANAGER=qemu_cli
  fi
  echo "[cf] CF_VM_MANAGER = $CF_VM_MANAGER (auto-detected)"
fi

# CF_START_WEBRTC is derived from CF_VM_MANAGER. The source enforces the
# pairing (crosvm with WebRTC, qemu_cli with VNC); other combinations are
# non-functional.
if [[ "$CF_VM_MANAGER" == "crosvm" ]]; then
  CF_START_WEBRTC=true
else
  CF_START_WEBRTC=false
fi

# -------- Run mode below --------

# Ensure host tools are reachable
#ln -sf "$CF_HOST_DIR"/bin/* /usr/local/bin/ || true
export PATH="$CF_HOST_DIR/bin:$PATH"

# Cuttlefish environment
export ANDROID_HOST_OUT="$CF_HOST_DIR"
export ANDROID_PRODUCT_OUT="$CF_PRODUCT_DIR"
export CVD_HOME="$CF_INSTANCE_DIR"
export HOME="$CF_HOST_DIR"

# Initialize cvd-* bridges inside this container's netns. Needed when the
# container runs without --network host. Idempotent.
if [[ -x /etc/init.d/cuttlefish-host-resources ]]; then
  /etc/init.d/cuttlefish-host-resources start || true
fi

# Start the in-container operator shim. Takes over webrtc_operator's role:
# serves the browser-side HTTPS+WebSocket on 8443 + (for cf launch_cvd) a
# SOCK_SEQPACKET unix socket at /run/cuttlefish/operator that cf's webRTC
# binary connects to. ice_servers are signaled to both sides.
SIG_SERVER_FLAGS=()
SHIM_OPERATOR_SOCKET_FLAG=()
# Must match the docker -p ...UDP forward in cf-run.sh. Explicit (rather
# than relying on launch_cvd's default) so the forward stays valid if
# upstream changes its default. cf/AOSP spell the flag differently.
WEBRTC_UDP_PORT_RANGE_FLAG=()
if [[ "$CF_VM_MANAGER" == "crosvm" ]]; then
  # AOSP- vs cf-built launch_cvd have diverged on webrtc flags. AOSP keeps
  # the granular --webrtc_sig_server_{path,port,secure} set; cf collapsed
  # them into a single --webrtc_sig_server_addr that points at a unix
  # socket (default /run/cuttlefish/operator). Probe once to pick the
  # right flag set.
  if launch_cvd --helpshort 2>/dev/null | grep -q webrtc_sig_server_path; then
    LAUNCH_CVD_DIALECT=aosp
  else
    LAUNCH_CVD_DIALECT=cf
  fi
  echo "[cf] launch_cvd dialect: $LAUNCH_CVD_DIALECT"

  CF_ICE_SERVERS_DEFAULT='[{"urls":["stun:stun.l.google.com:19302"]}]'
  : "${CF_ICE_SERVERS_JSON:=$CF_ICE_SERVERS_DEFAULT}"
  export CF_ICE_SERVERS_JSON

  if [[ "$LAUNCH_CVD_DIALECT" == "cf" ]]; then
    # cf launch_cvd connects to /run/cuttlefish/operator; have the shim
    # listen there too. Also disable cuttlefish-base.deb's webrtc_operator
    # service if it would otherwise grab the same socket / port 8443.
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop  cuttlefish-operator.service 2>/dev/null || true
      systemctl mask  cuttlefish-operator.service 2>/dev/null || true
    fi
    mkdir -p /run/cuttlefish
    SHIM_OPERATOR_SOCKET_FLAG=(--operator-socket /run/cuttlefish/operator)
    # run_cvd starts operator_proxy, which listens on 8443 and forwards to the
    # operator on 1443.  Listen there rather than taking 8443 out from under
    # it: it is a byte proxy, so TLS still terminates here and the browser URL
    # is unchanged.  Binding 8443 here made operator_proxy fail to bind, abort
    # on a CHECK, and drop a core file on every launch.
    SHIM_LISTEN_PORT=1443
    # cf dialect: no sig_server flags; launch_cvd's default
    # --webrtc_sig_server_addr=/run/cuttlefish/operator is correct.
    WEBRTC_UDP_PORT_RANGE_FLAG=(--udp_port_range=15550:15599)
  else
    # AOSP dialect: no operator_proxy, so the shim serves the browser directly.
    SHIM_LISTEN_PORT=8443
    # Tell launch_cvd to not start its own sig server and point its webrtc
    # binary at our shim's /register_device WS endpoint.
    SIG_SERVER_FLAGS=(
      --webrtc_start_sig_server=false
      --webrtc_sig_server_addr=127.0.0.1
      --webrtc_sig_server_port=8443
      --webrtc_sig_server_path=/register_device
      --webrtc_sig_server_secure=true
    )
    WEBRTC_UDP_PORT_RANGE_FLAG=(--webrtc_udp_port_range=15550:15599)
  fi

  # CF_EXTRA_HOST_IPS (comma-separated) -> repeated --extra-host-ip flags.
  # See shim --help; used to bridge browser to container when both reach the
  # host via a side channel (e.g. tailscale) that the container itself
  # isn't on.
  SHIM_EXTRA_HOST_IP_FLAGS=()
  if [[ -n "${CF_EXTRA_HOST_IPS:-}" ]]; then
    IFS=',' read -ra _extra_ips <<< "$CF_EXTRA_HOST_IPS"
    for _ip in "${_extra_ips[@]}"; do
      [[ -n "$_ip" ]] && SHIM_EXTRA_HOST_IP_FLAGS+=(--extra-host-ip "$_ip")
    done
  fi

  /usr/local/bin/webrtc_operator_shim.py \
    --client-dir "$CF_HOST_DIR/usr/share/webrtc/assets" \
    --cert-dir   "$CF_HOST_DIR/usr/share/webrtc/certs" \
    --listen-port "$SHIM_LISTEN_PORT" \
    "${SHIM_OPERATOR_SOCKET_FLAG[@]}" \
    "${SHIM_EXTRA_HOST_IP_FLAGS[@]}" \
    &
fi

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
  "${SIG_SERVER_FLAGS[@]}" \
  "${WEBRTC_UDP_PORT_RANGE_FLAG[@]}" \
  "$@" \
  || tail -f /dev/null
  # run forever even on error, for debugging
