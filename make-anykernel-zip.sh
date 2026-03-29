#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$HOME/kramel-ruby/artifacts}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"
WORK_ROOT="${WORK_ROOT:-$SCRIPT_DIR/.work}"
WORK_DIR="${WORK_ROOT}/AnyKernel3"

AK3_REPO="${AK3_REPO:-https://github.com/osm0sis/AnyKernel3.git}"
AK3_BRANCH="${AK3_BRANCH:-master}"

KERNEL_NAME="${KERNEL_NAME:-Crimson RubyX}"
DEVICE_TAG="${DEVICE_TAG:-ruby-rubypro}"
ZIP_VERSION="${ZIP_VERSION:-$(date +%Y%m%d-%H%M)}"
ZIP_BASENAME="${ZIP_BASENAME:-${KERNEL_NAME// /-}-${DEVICE_TAG}-${ZIP_VERSION}}"
ZIP_NAME="${ZIP_BASENAME}.zip"

usage() {
  cat <<'EOF'
Usage:
  ./make-anykernel-zip.sh

Optional env vars:
  ARTIFACTS_DIR=/path/to/kernel/artifacts
  OUTPUT_DIR=/path/to/output
  ZIP_VERSION=custom-tag
  KERNEL_NAME="Crimson RubyX"
  DEVICE_TAG="ruby-rubypro"
  AK3_REPO=https://github.com/osm0sis/AnyKernel3.git
  AK3_BRANCH=master
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -d "${ARTIFACTS_DIR}" ]]; then
  echo "Artifacts directory not found: ${ARTIFACTS_DIR}"
  echo "Build kernel first (build-ruby-kernel.sh) or set ARTIFACTS_DIR."
  exit 1
fi

for cmd in git zip; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}"
    exit 1
  fi
done

pick_kernel_image() {
  local src
  for src in Image.gz-dtb Image.gz Image; do
    if [[ -f "${ARTIFACTS_DIR}/${src}" ]]; then
      echo "${src}"
      return 0
    fi
  done
  return 1
}

KERNEL_IMAGE="$(pick_kernel_image || true)"
if [[ -z "${KERNEL_IMAGE}" ]]; then
  echo "No kernel image found in ${ARTIFACTS_DIR}."
  echo "Expected one of: Image.gz-dtb, Image.gz, Image"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}" "${WORK_ROOT}"
rm -rf "${WORK_DIR}"

echo "[1/5] Cloning AnyKernel3..."
git clone --depth=1 --branch "${AK3_BRANCH}" "${AK3_REPO}" "${WORK_DIR}"

echo "[2/5] Applying Crimson AnyKernel config..."
cp -f "${SCRIPT_DIR}/anykernel/anykernel.sh" "${WORK_DIR}/anykernel.sh"

echo "[3/5] Copying kernel payload..."
cp -f "${ARTIFACTS_DIR}/${KERNEL_IMAGE}" "${WORK_DIR}/${KERNEL_IMAGE}"
if [[ -f "${ARTIFACTS_DIR}/dtbo.img" ]]; then
  cp -f "${ARTIFACTS_DIR}/dtbo.img" "${WORK_DIR}/dtbo.img"
fi
if [[ -f "${ARTIFACTS_DIR}/vendor_boot.img" ]]; then
  cp -f "${ARTIFACTS_DIR}/vendor_boot.img" "${WORK_DIR}/vendor_boot.img"
fi

printf "%s\n" "${ZIP_BASENAME}" > "${WORK_DIR}/version"

echo "[4/5] Creating flashable zip..."
(
  cd "${WORK_DIR}"
  zip -r9 "${OUTPUT_DIR}/${ZIP_NAME}" * -x ".git/*" ".github/*" README.md
)

echo "[5/5] Done."
echo "Created: ${OUTPUT_DIR}/${ZIP_NAME}"
