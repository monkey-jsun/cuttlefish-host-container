#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="cf-host"

CONTAINER_ID=$(docker ps -q --filter ancestor="$IMAGE_NAME")

if [[ -z "$CONTAINER_ID" ]]; then
  echo "[cf-stop] No running container found for image $IMAGE_NAME."
  exit 1
fi

echo "[cf-stop] Stopping CVD in container $CONTAINER_ID ..."
docker exec "$CONTAINER_ID" env \
  HOME=/cf/host \
  ANDROID_HOST_OUT=/cf/host \
  ANDROID_PRODUCT_OUT=/cf/product \
  CVD_HOME=/cf/instance \
  PATH=/cf/host/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /cf/host/bin/stop_cvd "$@"
echo "[cf-stop] Done."
