#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="cf-host"
DEB_PATH=""
APT_MIRROR=""
DOCKERFILE=""
STAGED_DEB=".cuttlefish-base.local.deb"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build the Cuttlefish host container image.

Options:
  -i, --image NAME      Docker image name (default: $IMAGE_NAME)
  -d, --deb PATH        Path to a local cuttlefish-base .deb to install
                        in the image instead of fetching from apt / GitHub
                        releases. Works on any arch.
      --apt-mirror URL  Ubuntu ports mirror (host+path, no scheme) to
                        substitute for ports.ubuntu.com. Use when the stock
                        mirror is slow or blocked in some regions.
                        Example: mirrors.aliyun.com/ubuntu-ports
  -f, --file PATH       Dockerfile to build. Default: Dockerfile
  -h, --help            Show this help

Examples:
  # Default build
  $(basename "$0")

  # Build the K3/bianbu variant
  $(basename "$0") -f Dockerfile.bianbu-k3

  # Build with a custom image name
  $(basename "$0") -i my-cf-host

  # Build using a locally built cuttlefish-base .deb
  $(basename "$0") -d ~/work/cuttlefish/cuttlefish-base_1.50.0_riscv64.deb

  # Build via a domestic ubuntu-ports mirror
  $(basename "$0") --apt-mirror mirrors.aliyun.com/ubuntu-ports
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)     IMAGE_NAME="$2"; shift 2 ;;
    -d|--deb)       DEB_PATH="$2"; shift 2 ;;
    --apt-mirror)   APT_MIRROR="$2"; shift 2 ;;
    -f|--file)      DOCKERFILE="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Resolve build context to the script's own directory so cf-build.sh can be
# invoked from anywhere (e.g. from an instance subdir like cf-k3-v1.1/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKERFILE="${DOCKERFILE:-Dockerfile}"
if [[ ! -f "$SCRIPT_DIR/$DOCKERFILE" ]]; then
  echo "[cf-build] Dockerfile not found: $SCRIPT_DIR/$DOCKERFILE" >&2
  exit 1
fi

BUILD_ARGS=()
if [[ -n "$DEB_PATH" ]]; then
  if [[ ! -f "$DEB_PATH" ]]; then
    echo "[cf-build] deb not found: $DEB_PATH" >&2
    exit 1
  fi
  # Resolve before any cd so a relative --deb path is interpreted vs cwd.
  DEB_PATH="$(readlink -f "$DEB_PATH")"
  echo "[cf-build] Using local deb: $DEB_PATH"
  cp -f "$DEB_PATH" "$SCRIPT_DIR/$STAGED_DEB"
  trap 'rm -f "$SCRIPT_DIR/$STAGED_DEB"' EXIT
  BUILD_ARGS+=(--build-arg "CF_LOCAL_BASE_DEB=$STAGED_DEB")
fi
if [[ -n "$APT_MIRROR" ]]; then
  echo "[cf-build] Using apt mirror: $APT_MIRROR"
  BUILD_ARGS+=(--build-arg "APT_MIRROR=$APT_MIRROR")
fi

echo "[cf-build] Building image: $IMAGE_NAME (from $DOCKERFILE)"
docker build "${BUILD_ARGS[@]}" -f "$SCRIPT_DIR/$DOCKERFILE" -t "$IMAGE_NAME" "$SCRIPT_DIR"
echo "[cf-build] Done."
