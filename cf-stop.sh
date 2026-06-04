#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="cf-host"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [stop_cvd args...]

Stop the cuttlefish device running inside the cf-host container.

Options:
  -i, --image NAME      Docker image name to find the container (default: $IMAGE_NAME)
  -h, --help            Show this help

All remaining arguments are passed to stop_cvd inside the container.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)  IMAGE_NAME="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; break ;;
    *)           break ;;
  esac
done

CONTAINER_ID=$(docker ps -q --filter ancestor="$IMAGE_NAME")

if [[ -z "$CONTAINER_ID" ]]; then
  echo "[cf-stop] No running container found for image $IMAGE_NAME."
  exit 1
fi

echo "[cf-stop] Stopping CVD in container $CONTAINER_ID ..."
# Try graceful in-guest shutdown via stop_cvd. May fail (e.g. launcher
# monitor unresponsive); don't trip set -e here.
docker exec "$CONTAINER_ID" env \
  HOME=/cf/host \
  ANDROID_HOST_OUT=/cf/host \
  ANDROID_PRODUCT_OUT=/cf/product \
  CVD_HOME=/cf/instance \
  PATH=/cf/host/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /cf/host/bin/stop_cvd "$@" || \
    echo "[cf-stop] stop_cvd failed or timed out; will force-stop the container."

# stop_cvd succeeded != container exited. launch_cvd (PID 1) may still be
# wedged. Ensure the container actually stops.
if docker ps -q --filter id="$CONTAINER_ID" | grep -q .; then
  echo "[cf-stop] Forcing container $CONTAINER_ID to stop..."
  docker stop -t 5 "$CONTAINER_ID" >/dev/null
fi
echo "[cf-stop] Done."
