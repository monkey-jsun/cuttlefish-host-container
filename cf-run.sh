#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="cf-host"
CF_ROOT_HOST="cf-data"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [launch_cvd flags...]

Run the Cuttlefish container using existing /cf/host and /cf/product.

Options:
  -r, --root DIR        Host directory to mount as /cf in the container (default: $CF_ROOT_HOST)
  -i, --image NAME      Docker image name (default: $IMAGE_NAME)
  -h, --help            Show this help

All remaining arguments are passed directly to launch_cvd inside the container.

Examples:
  # Use defaults, no extra launch_cvd flags
  $(basename "$0")

  # Use a different host root and image
  $(basename "$0") -r /mnt/cf -i my-cf-image

  # Pass extra launch_cvd flags. See entrypoint.sh for tunable vars.
  $(basename "$0") -- -e CF_CPUS=4 -e CF_MEMORY_MB=8192 -e CF_GPU_MODE=none

  # run x86_64 with faster crosvm and webrtc
  $(basename "$0") -- -e CF_VM_MANAGER=crosvm -e CF_START_WEBRTC=true
EOF
}

# Parse only our own options; everything after first non-option or '--' goes to launch_cvd
FORWARD_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--root)
      CF_ROOT_HOST="$2"
      shift 2
      ;;
    -i|--image)
      IMAGE_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      # Everything after '--' goes straight to launch_cvd
      FORWARD_ARGS+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      # First non-option: treat it and everything after as launch_cvd args
      FORWARD_ARGS+=("$@")
      break
      ;;
  esac
done

# Check for already running cf container
EXISTING=$(docker ps -q --filter ancestor="$IMAGE_NAME")
if [[ -n "$EXISTING" ]]; then
  echo "[cf-run] ERROR: A cf container is already running (container $EXISTING)." >&2
  echo "[cf-run]        Stop it first with ./cf-stop.sh or: docker kill $EXISTING" >&2
  exit 1
fi

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

# crosvm requires privileged mode; qemu_cli can run with more restricted permissions.
# Default vm_manager is crosvm on riscv64.
if ! printf '%s\n' "${FORWARD_ARGS[@]}" | grep -qF -- "CF_VM_MANAGER=qemu_cli"; then
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
  echo "[cf-run] Running qemu_cli, secure args are: $SECURE_ARGS"
fi

# Split FORWARD_ARGS: -e pairs go to docker, everything else to launch_cvd
DOCKER_ARGS=()
LAUNCH_ARGS=()
i=0
while [[ $i -lt ${#FORWARD_ARGS[@]} ]]; do
  if [[ "${FORWARD_ARGS[$i]}" == "-e" ]] && [[ $((i+1)) -lt ${#FORWARD_ARGS[@]} ]]; then
    DOCKER_ARGS+=("-e" "${FORWARD_ARGS[$((i+1))]}")
    i=$((i+2))
  else
    LAUNCH_ARGS+=("${FORWARD_ARGS[$i]}")
    i=$((i+1))
  fi
done

# run
docker run -it --rm \
  $SECURE_ARGS \
  -p 5900:5900 \
  -p 6520:6520 \
  -v "$CF_ROOT_HOST:/cf" \
  ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} \
  "$IMAGE_NAME" \
  ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}
