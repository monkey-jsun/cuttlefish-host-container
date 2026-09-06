#!/usr/bin/env bash
set -euo pipefail

# Optional: narrow the search to one image. By default cf-stop finds the cf
# container by its label, so it works regardless of which image built it.
IMAGE_NAME=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Stop the cuttlefish container.  Ctrl-C on a foreground run or 'docker stop cf' does the same thing.

Options:
  -i, --image NAME      Only stop a container from this image (default: any cf container)
  -h, --help            Show this help
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

FILTER_ARGS=(--filter label=cf-host)
if [[ -n "$IMAGE_NAME" ]]; then
  FILTER_ARGS+=(--filter ancestor="$IMAGE_NAME")
fi
CONTAINER_ID=$(docker ps -q "${FILTER_ARGS[@]}")

if [[ -z "$CONTAINER_ID" ]]; then
  echo "[cf-stop] No running cf container found."
  exit 1
fi

# The guest flush and graceful stop_cvd live in the container entrypoint, which
# traps SIGTERM. 'docker stop' sends SIGTERM, so a plain stop flushes the guest
# exactly like Ctrl-C or 'docker stop cf' -- one code path however it's stopped.
# -t 40 gives the in-guest sync and stop_cvd time to finish before docker
# resorts to SIGKILL.
echo "[cf-stop] Stopping cf container $CONTAINER_ID (flush happens in-container) ..."
docker stop -t 40 "$CONTAINER_ID" >/dev/null
echo "[cf-stop] Done."
