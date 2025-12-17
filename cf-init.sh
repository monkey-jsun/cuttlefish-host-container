#!/usr/bin/env bash
set -euo pipefail

CF_ROOT_HOST="cf-data"
HOST_TAR=""
PRODUCT_ZIP=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Initialize / update Cuttlefish host + product artifacts in a persistent volume.

Options:
  -H, --host PATH       Path to cvd-host_package-*.tar.gz (optional)
  -P, --product PATH    Path to aosp_cf_*_img-*.zip (optional)
  -r, --root DIR        Host directory to use as /cf inside container (default: ./cf-data)
  -h, --help            Show this help

Examples:
  # Initialize both host package and product images
  $(basename "$0") -H out/dist/cvd-host_package-x86_64.tar.gz -P out/dist/aosp_cf_riscv64_phone-img-XXXX.zip

  # Only update product images, keep host package as-is
  $(basename "$0") -P out/dist/aosp_cf_riscv64_phone-img-YYYY.zip
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host)    HOST_TAR="$2"; shift 2 ;;
    -P|--product) PRODUCT_ZIP="$2"; shift 2 ;;
    -r|--root)    CF_ROOT_HOST="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$HOST_TAR" && -z "$PRODUCT_ZIP" ]]; then
  echo "Nothing to do: you must specify at least one of --host or --product" >&2
  usage
  exit 1
fi

# setup cf dir structure
CF_ROOT=$CF_ROOT_HOST
CF_HOST_DIR="$CF_ROOT/host"
CF_PRODUCT_DIR="$CF_ROOT/product"
CF_INSTANCE_DIR="$CF_ROOT/instance"

mkdir -p "$CF_HOST_DIR" "$CF_PRODUCT_DIR" "$CF_INSTANCE_DIR"

# check host package
if [[ -n "$HOST_TAR" ]]; then
  if [[ ! -f "$HOST_TAR" ]]; then
    echo "Host tar not found: $HOST_TAR" >&2
    exit 1
  fi
  
  echo "Unpacking host package into $CF_HOST_DIR ..."
  rm -rf "${CF_HOST_DIR:?}"/*
  tar -xf $HOST_TAR -C "$CF_HOST_DIR"
fi

# check product image file
if [[ -n "$PRODUCT_ZIP" ]]; then
  if [[ ! -f "$PRODUCT_ZIP" ]]; then
    echo "Product zip not found: $PRODUCT_ZIP" >&2
    exit 1
  fi

  echo "Unpacking product images into $CF_PRODUCT_DIR ..."
  rm -rf "${CF_PRODUCT_DIR:?}"/*
  unzip -n $PRODUCT_ZIP -d "$CF_PRODUCT_DIR"
fi

echo "[cf-init] Done."

