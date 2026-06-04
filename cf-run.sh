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

  # this is a little hackish right now.
  # for crosvm running (which is for x86 only), we have to relax a bunch of restrictions
  # otherwise we go with more safter choices.
  # Note we assume default vm_manager is qemu_cli, not crosvm
  local SECURE_ARGS
  if printf '%s\n' "${FORWARD_ARGS[@]}" | grep -qF -- "CF_VM_MANAGER=crosvm"; then
    SECURE_ARGS="
  --privileged
  --network host
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

# Parse cf-run.sh's own options; everything after first non-option or '--'
# goes to launch_cvd. Sets globals FORWARD_ARGS, IMAGE_NAME, CF_ROOT_HOST.
# Uses `exit` (not `return`) on errors -- kills the whole script.
parse_args() {
  FORWARD_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpus)        FORWARD_ARGS+=(-e "CF_CPUS=$2"); shift 2 ;;
      --mem-mb)      FORWARD_ARGS+=(-e "CF_MEM_MB=$2"); shift 2 ;;
      --gpu-mode)    FORWARD_ARGS+=(-e "CF_GPU_MODE=$2"); shift 2 ;;
      --vm-manager)
        FORWARD_ARGS+=(-e "CF_VM_MANAGER=$2")
        if [[ "$2" == "crosvm" ]]; then
          FORWARD_ARGS+=(-e "CF_START_WEBRTC=true")
        else
          FORWARD_ARGS+=(-e "CF_START_WEBRTC=false")
        fi
        shift 2
        ;;
      -r|--root)     CF_ROOT_HOST="$2"; shift 2 ;;
      -i|--image)    IMAGE_NAME="$2"; shift 2 ;;
      -h|--help)     usage; exit 0 ;;
      # Everything after '--' goes straight to docker
      --)            shift; FORWARD_ARGS+=("$@"); break ;;
      *)             echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
}

# ============================================================================
# Entry
# ============================================================================
main "$@"
