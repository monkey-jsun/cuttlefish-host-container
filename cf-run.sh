#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Constants
# ============================================================================
IMAGE_NAME="cf-host"
CF_ROOT_HOST="cf-data"

# ============================================================================
# main
# ============================================================================
main() {
  parse_args "$@"
  check_vm_manager

  mkdir -p "$CF_ROOT_HOST"
  CF_ROOT_HOST=$(readlink -f $CF_ROOT_HOST)

  echo "[cf-run] Host root : $CF_ROOT_HOST"
  echo "[cf-run] Image     : $IMAGE_NAME"
  if [[ ${#FORWARD_ARGS[@]} -gt 0 ]]; then
    echo "[cf-run] Extra launch_cvd args:"
    printf '  %q\n' "${FORWARD_ARGS[@]}"
  else
    echo "[cf-run] No extra launch_cvd args (using defaults from entrypoint.sh)."
  fi

  # for crosvm running, we have to relax a bunch of restrictions
  # otherwise we go with more safter choices.
  local SECURE_ARGS
  if printf '%s\n' "${FORWARD_ARGS[@]}" | grep -qF -- "CF_VM_MANAGER=crosvm"; then
    SECURE_ARGS="
  --privileged
  --ulimit nofile=65536:65536"
    echo "[cf-run] Running crosvm, secure args are: $SECURE_ARGS"
  else
     SECURE_ARGS="
  --device /dev/net/tun
  --device /dev/vhost-vsock
  --device /dev/dri
  --cap-add NET_ADMIN
  --cap-add NET_RAW
  --security-opt seccomp=unconfined
  --security-opt no-new-privileges"
    if [[ -e /dev/kvm ]]; then
      SECURE_ARGS+=" --device /dev/kvm"
    fi
    echo "[cf-run] Running qemu_cli, secure args are: $SECURE_ARGS"
  fi

  # run
  docker run -it --rm \
    $SECURE_ARGS \
    -p 8443:8443 \
    -p 5900:5900 \
    -p 6520:6520 \
    -v "$CF_ROOT_HOST:/cf" \
    "${FORWARD_ARGS[@]}" \
    "$IMAGE_NAME"
}

# ============================================================================
# Helpers
# ============================================================================

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [launch_cvd flags...]

Run the Cuttlefish container using existing /cf/host and /cf/product.

Options:
      --cpus N          Guest vCPUs (default: 4)
      --mem-mb N        Guest RAM in MB (default: 8192, 8GB)
      --gpu-mode MODE   auto|guest_swiftshader|drm_virgl|gfxstream
                        (default: auto)
      --vm-manager MGR  crosvm|qemu_cli
                        (default: crosvm for same host/guest arches, 
                                  qemu_cli otherwise)
  -r, --root DIR        Host directory to mount as /cf in the container
                        (default: $CF_ROOT_HOST)
  -i, --image NAME      Docker image name (default: $IMAGE_NAME)
  -h, --help            Show this help

All remaining arguments are passed directly to launch_cvd inside the container.

Examples:
  # Use defaults, no extra launch_cvd flags
  $(basename "$0")

  # Use a different host root and image
  $(basename "$0") -r /mnt/cf -i my-cf-image

  # Common tunables
  $(basename "$0") --cpus 8 --mem-mb 16384

  # run with crosvm (auto-implies WebRTC)
  $(basename "$0") --vm-manager crosvm
EOF
}

# Parse cf-run.sh's own options; everything after '--'
# goes to launch_cvd. Sets globals FORWARD_ARGS, IMAGE_NAME, CF_ROOT_HOST.
# Uses `exit` (not `return`) on errors -- kills the whole script.
parse_args() {
  FORWARD_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpus)        FORWARD_ARGS+=(-e "CF_CPUS=$2"); shift 2 ;;
      --mem-mb)      FORWARD_ARGS+=(-e "CF_MEM_MB=$2"); shift 2 ;;
      --gpu-mode)    FORWARD_ARGS+=(-e "CF_GPU_MODE=$2"); shift 2 ;;
      --vm-manager)  FORWARD_ARGS+=(-e "CF_VM_MANAGER=$2"); shift 2 ;;
      -r|--root)     CF_ROOT_HOST="$2"; shift 2 ;;
      -i|--image)    IMAGE_NAME="$2"; shift 2 ;;
      -h|--help)     usage; exit 0 ;;
      # Everything after '--' goes straight to docker
      --)            shift; FORWARD_ARGS+=("$@"); break ;;
      *)             echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
}

# If CF_VM_MANAGER is not already in FORWARD_ARGS (set by --vm-manager)
# auto-detect based on host vs guest arch and inject:
#  - if host and guest are same arch, use "crosvm";
#  - Otherwise use "qemu_cli"
check_vm_manager() {
  if printf '%s\n' "${FORWARD_ARGS[@]}" | grep -qE -- '^CF_VM_MANAGER='; then
    return
  fi

  local detected="qemu_cli"
  if [[ "$(detect_host_arch)" == "$(detect_guest_arch)" ]]; then
      detected="crosvm"
  fi

  echo "[cf-run] CF_VM_MANAGER : $detected (auto-detected)"
  FORWARD_ARGS+=(-e "CF_VM_MANAGER=$detected")
}

# Echo normalized host arch (x86_64 / aarch64 / riscv64 / ...).
detect_host_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    arm64) echo "aarch64" ;;
    amd64) echo "x86_64" ;;
    *)     echo "$arch" ;;
  esac
}

# Detect and echo guest arch from $CF_ROOT_HOST/product/boot.img.
# - Echoes "x86_64", "aarch64", or "riscv64" on success.
# - Returns 1 on errors 
detect_guest_arch() {
  local bootimg="$CF_ROOT_HOST/product/boot.img"
  [[ -f "$bootimg" ]] || return 1
  command -v file >/dev/null 2>&1 || return 1
  # Android boot.img v3+: kernel_size at offset 8 (u32 LE), kernel at PAGE_SIZE (4096)
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

# ============================================================================
# Entry
# ============================================================================
main "$@"
