#!/usr/bin/env bash
set -euo pipefail

# Xiaomi ruby/rubypro kernel build helper (Linux server).

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must run on Linux."
  exit 1
fi

ROOT_DIR="${HOME}/kramel-ruby"
KERNEL_DIR="${ROOT_DIR}/kernel_ruby"
TOOLCHAIN_DIR="${ROOT_DIR}/proton-clang"
OUT_DIR="${KERNEL_DIR}/out"
ARTIFACTS_DIR="${ROOT_DIR}/artifacts"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_JOBS="${BUILD_JOBS:-$(nproc --all)}"
SKIP_DEPS_INSTALL="${SKIP_DEPS_INSTALL:-0}"
SUKISU_SETUP_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh"
SUSFS_REPO_URL="${SUSFS_REPO_URL:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-kernel-4.19}"
SUSFS_DIR="${ROOT_DIR}/susfs4ksu"
BUILD_PROFILE="${BUILD_PROFILE:-balanced}"
ENABLE_MODERN_STACK="${ENABLE_MODERN_STACK:-1}"
ENABLE_SUKISU="${ENABLE_SUKISU:-1}"
ENABLE_SUSFS="${ENABLE_SUSFS:-1}"
ENABLE_CUSTOM_CONFIG="${ENABLE_CUSTOM_CONFIG:-1}"
DISABLE_WERROR="${DISABLE_WERROR:-1}"
CUSTOM_CONFIG_FRAGMENT="${CUSTOM_CONFIG_FRAGMENT:-${SCRIPT_DIR}/configs/ruby_custom.fragment}"
SUKISU_REF="${SUKISU_REF:-auto}"

usage() {
  cat <<'EOF'
Usage:
  BUILD_PROFILE=balanced   ./build-ruby-kernel.sh   # default, recommended
  BUILD_PROFILE=performance ./build-ruby-kernel.sh  # faster, less secure
  BUILD_PROFILE=battery    ./build-ruby-kernel.sh   # cooler, longer battery
  ENABLE_MODERN_STACK=1    ./build-ruby-kernel.sh   # enable modern feature pack (default)
  ENABLE_SUKISU=1          ./build-ruby-kernel.sh   # integrate SukiSU-Ultra (default)
  ENABLE_SUSFS=1           ./build-ruby-kernel.sh   # integrate SUSFS for KSU (default)
  ENABLE_CUSTOM_CONFIG=1   ./build-ruby-kernel.sh   # merge custom config fragment (default)
  DISABLE_WERROR=1         ./build-ruby-kernel.sh   # disable vendor -Werror traps (default)
  BUILD_JOBS=1             ./build-ruby-kernel.sh   # single-thread debug build (shows first error clearly)
  SKIP_DEPS_INSTALL=1      ./build-ruby-kernel.sh   # skip apt install (no sudo/root)
  CUSTOM_CONFIG_FRAGMENT=/path/to/file.fragment ./build-ruby-kernel.sh
  SUKISU_REF=auto           ./build-ruby-kernel.sh  # auto: builtin
  SUKISU_REF=builtin        ./build-ruby-kernel.sh  # recommended for non-GKI + SUSFS
EOF
}

case "${BUILD_PROFILE}" in
  balanced|performance|battery) ;;
  *)
    echo "Unknown BUILD_PROFILE: ${BUILD_PROFILE}"
    usage
    exit 1
    ;;
esac

for bool_var in ENABLE_MODERN_STACK ENABLE_SUKISU ENABLE_SUSFS ENABLE_CUSTOM_CONFIG DISABLE_WERROR SKIP_DEPS_INSTALL; do
  case "${!bool_var}" in
    0|1) ;;
    *)
      echo "${bool_var} must be 0 or 1 (current: ${!bool_var})"
      exit 1
      ;;
  esac
done

if [[ "${SKIP_DEPS_INSTALL}" == "0" ]]; then
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "sudo is required when not running as root. Or set SKIP_DEPS_INSTALL=1."
    exit 1
  fi

  if ! command -v apt >/dev/null 2>&1; then
    echo "apt not found. Use Debian/Ubuntu, or set SKIP_DEPS_INSTALL=1."
    exit 1
  fi
else
  SUDO=""
fi

if [[ "${SUKISU_REF}" == "auto" ]]; then
  SUKISU_REF="builtin"
fi

if [[ "${ENABLE_SUSFS}" == "1" && "${ENABLE_SUKISU}" != "1" ]]; then
  echo "ENABLE_SUSFS=1 requires ENABLE_SUKISU=1."
  exit 1
fi

remote_branch_exists() {
  local repo="$1"
  local branch="$2"
  git ls-remote --heads "${repo}" "${branch}" | grep -q "refs/heads/${branch}$"
}

sukisu_ref_exists() {
  local repo="$1"
  local ref="$2"
  git ls-remote --heads --tags "${repo}" "${ref}" | grep -q .
}

sukisu_has_native_susfs() {
  local ksu_dir="$1"
  grep -q "config KSU_SUSFS" "${ksu_dir}/kernel/Kconfig" 2>/dev/null && \
  grep -q "linux/susfs.h" "${ksu_dir}/kernel/ksuinit.c" 2>/dev/null
}

ensure_susfs_task_fields() {
  local sched_file="$1"
  local need_task_state="0"
  local need_last_fake="0"
  local tmp=""

  if [[ ! -f "${sched_file}" ]]; then
    echo "Missing sched header: ${sched_file}"
    return 1
  fi

  grep -q "susfs_task_state" "${sched_file}" || need_task_state="1"
  grep -q "susfs_last_fake_mnt_id" "${sched_file}" || need_last_fake="1"

  if [[ "${need_task_state}" == "0" && "${need_last_fake}" == "0" ]]; then
    return 0
  fi

  tmp="$(mktemp)"
  awk \
    -v add_state="${need_task_state}" \
    -v add_last="${need_last_fake}" \
    '
      /^[[:space:]]*randomized_struct_fields_end/ && !done {
        if (add_state == "1") {
          print "#if defined(CONFIG_KSU_SUSFS)"
          print "\tu64 susfs_task_state;"
          print "#endif"
        }
        if (add_last == "1") {
          print "#if defined(CONFIG_KSU_SUSFS)"
          print "\tu64 susfs_last_fake_mnt_id;"
          print "#endif"
        }
        done = 1
      }
      { print }
    ' "${sched_file}" > "${tmp}"
  mv "${tmp}" "${sched_file}"
}

if [[ "${ENABLE_SUKISU}" == "1" ]]; then
  if ! sukisu_ref_exists "https://github.com/SukiSU-Ultra/SukiSU-Ultra.git" "${SUKISU_REF}"; then
    echo "SUKISU_REF '${SUKISU_REF}' does not exist as a remote branch/tag."
    echo "Try one of: builtin, main, susfs_features, v4.1.2"
    exit 1
  fi
  if [[ "${SUKISU_REF}" == susfs-* ]]; then
    if ! remote_branch_exists "https://github.com/SukiSU-Ultra/SukiSU-Ultra.git" "${SUKISU_REF}"; then
      echo "Ref '${SUKISU_REF}' is documented in old guides but not present upstream now."
      echo "Use SUKISU_REF=builtin for non-GKI + SUSFS."
      exit 1
    fi
  fi
fi

if [[ "${ENABLE_SUSFS}" == "1" ]]; then
  if ! remote_branch_exists "${SUSFS_REPO_URL}" "${SUSFS_BRANCH}"; then
    echo "SUSFS_BRANCH '${SUSFS_BRANCH}' was not found in ${SUSFS_REPO_URL}."
    exit 1
  fi
fi

echo "[1/6] Installing build dependencies..."
if [[ "${SKIP_DEPS_INSTALL}" == "0" ]]; then
  ${SUDO} apt update
  ${SUDO} apt install -y \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib git patch \
    libelf-dev liblz4-tool libncurses5-dev libssl-dev libxml2-utils \
    lzop python3 rsync unzip xz-utils zip zlib1g-dev
else
  echo "Skipping dependency installation (SKIP_DEPS_INSTALL=1)."
fi

mkdir -p "${ROOT_DIR}" "${ARTIFACTS_DIR}"
cd "${ROOT_DIR}"

if [[ ! -d "${KERNEL_DIR}/.git" ]]; then
  echo "[2/6] Cloning Xiaomi kernel source (ruby-s-oss)..."
  git clone --depth=1 --branch ruby-s-oss https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git "${KERNEL_DIR}"
else
  echo "[2/6] Kernel source exists. Pulling latest ruby-s-oss..."
  git -C "${KERNEL_DIR}" fetch origin ruby-s-oss --depth=1
  git -C "${KERNEL_DIR}" checkout ruby-s-oss
  git -C "${KERNEL_DIR}" reset --hard origin/ruby-s-oss
  # Drop untracked leftovers from previous integration attempts (e.g. KernelSU dir/patch rejects).
  git -C "${KERNEL_DIR}" clean -fd
fi

if [[ ! -d "${TOOLCHAIN_DIR}/.git" ]]; then
  echo "[3/6] Cloning toolchain (proton-clang)..."
  git clone --depth=1 https://github.com/kdrag0n/proton-clang.git "${TOOLCHAIN_DIR}"
else
  echo "[3/6] Toolchain exists. Pulling latest..."
  git -C "${TOOLCHAIN_DIR}" pull --ff-only
fi

if [[ "${ENABLE_SUKISU}" == "1" ]]; then
  echo "[3.5/6] Integrating SukiSU-Ultra (${SUKISU_REF})..."
  cd "${KERNEL_DIR}"
  curl -LSs "${SUKISU_SETUP_URL}" | bash -s "${SUKISU_REF}"

  if [[ ! -d "${KERNEL_DIR}/KernelSU/kernel" ]]; then
    echo "SukiSU integration failed: KernelSU tree was not created."
    exit 1
  fi
fi

if [[ "${ENABLE_SUSFS}" == "1" ]]; then
  echo "[3.6/6] Integrating SUSFS..."

  if [[ ! -d "${SUSFS_DIR}/.git" ]]; then
    git clone --depth=1 --branch "${SUSFS_BRANCH}" "${SUSFS_REPO_URL}" "${SUSFS_DIR}"
  else
    git -C "${SUSFS_DIR}" fetch origin "${SUSFS_BRANCH}" --depth=1
    git -C "${SUSFS_DIR}" checkout "${SUSFS_BRANCH}"
    git -C "${SUSFS_DIR}" reset --hard "origin/${SUSFS_BRANCH}"
  fi

  # Always copy SUSFS source/header payload so KernelSU includes can resolve.
  cp -fv "${SUSFS_DIR}/kernel_patches/fs/"* "${KERNEL_DIR}/fs/"
  cp -fv "${SUSFS_DIR}/kernel_patches/include/linux/"* "${KERNEL_DIR}/include/linux/"

  KERNEL_SUSFS_PATCH=""
  for candidate in \
    "${SUSFS_DIR}/kernel_patches/50_add_susfs_in_kernel-4.19.patch" \
    "${SUSFS_DIR}/kernel_patches/50_add_susfs_in_kernel-4.14.patch"; do
    if [[ -f "${candidate}" ]]; then
      KERNEL_SUSFS_PATCH="${candidate}"
      break
    fi
  done

  if [[ -n "${KERNEL_SUSFS_PATCH}" ]]; then
    cp -fv "${KERNEL_SUSFS_PATCH}" "${KERNEL_DIR}/"
  fi

  if sukisu_has_native_susfs "${KERNEL_DIR}/KernelSU"; then
    echo "SukiSU ref '${SUKISU_REF}' already has native SUSFS hooks; skipping KernelSU patch."
  else
    cp -fv "${SUSFS_DIR}/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" "${KERNEL_DIR}/KernelSU/"
    if ! (cd "${KERNEL_DIR}/KernelSU" && patch --batch -p1 --forward < 10_enable_susfs_for_ksu.patch); then
      echo "Failed applying KernelSU susfs patch for SukiSU ref '${SUKISU_REF}'."
      echo "Use SUKISU_REF=builtin for the most compatible non-GKI SUSFS path."
      exit 1
    fi
  fi

  if [[ -n "${KERNEL_SUSFS_PATCH}" ]]; then
    patch_name="$(basename "${KERNEL_SUSFS_PATCH}")"
    if ! (cd "${KERNEL_DIR}" && patch --batch -p1 --forward < "${patch_name}"); then
      if ! grep -q 'obj-\$(CONFIG_KSU_SUSFS) += susfs.o' "${KERNEL_DIR}/fs/Makefile"; then
        echo "Failed applying kernel susfs patch (${patch_name})."
        echo "This kernel tree may require manual susfs patch porting."
        exit 1
      fi
    fi
  fi

  if ! grep -q 'obj-\$(CONFIG_KSU_SUSFS) += susfs.o' "${KERNEL_DIR}/fs/Makefile"; then
    echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' >> "${KERNEL_DIR}/fs/Makefile"
  fi

  # Some vendor 4.19 trees partially apply susfs namespace changes but miss
  # task_struct fields from include/linux/sched.h, which breaks fs/namespace.c.
  if grep -q "susfs_last_fake_mnt_id" "${KERNEL_DIR}/fs/namespace.c" 2>/dev/null; then
    ensure_susfs_task_fields "${KERNEL_DIR}/include/linux/sched.h"
  fi

  if [[ ! -f "${KERNEL_DIR}/include/linux/susfs.h" || ! -f "${KERNEL_DIR}/fs/susfs.c" ]]; then
    echo "SUSFS files missing after integration (include/linux/susfs.h or fs/susfs.c)."
    exit 1
  fi
fi

echo "[4/6] Preparing kernel config (ruby_user_defconfig)..."
# Keep system binutils first for HOSTCC linking; use absolute paths for target LLVM tools.
export PATH="/usr/bin:/bin:${TOOLCHAIN_DIR}/bin:${PATH}"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-${USER:-builder}}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-$(hostname 2>/dev/null || echo linux)}"
export LLVM=1
export LLVM_IAS=1
export CC="${TOOLCHAIN_DIR}/bin/clang"
export LD="${TOOLCHAIN_DIR}/bin/ld.lld"
export AR="${TOOLCHAIN_DIR}/bin/llvm-ar"
export NM="${TOOLCHAIN_DIR}/bin/llvm-nm"
export OBJCOPY="${TOOLCHAIN_DIR}/bin/llvm-objcopy"
export OBJDUMP="${TOOLCHAIN_DIR}/bin/llvm-objdump"
export STRIP="${TOOLCHAIN_DIR}/bin/llvm-strip"
export READELF="${TOOLCHAIN_DIR}/bin/llvm-readelf"
TARGET_TRIPLE="${TARGET_TRIPLE:-aarch64-linux-gnu}"
CLANG_TRIPLE_PREFIX="${CLANG_TRIPLE_PREFIX:-${TARGET_TRIPLE}-}"
CROSS_COMPILE_PREFIX="${CROSS_COMPILE_PREFIX:-aarch64-linux-gnu-}"
CROSS_COMPILE_ARM32_PREFIX="${CROSS_COMPILE_ARM32_PREFIX:-arm-linux-gnueabi-}"

# Host tools must use system binutils and compiler to avoid old proton ld/glibc RELR issues.
if [[ -x /usr/bin/gcc && -x /usr/bin/g++ && -x /usr/bin/ld.bfd ]]; then
  HOSTCC_BIN="${HOSTCC_BIN:-/usr/bin/gcc}"
  HOSTCXX_BIN="${HOSTCXX_BIN:-/usr/bin/g++}"
  HOSTLD_BIN="${HOSTLD_BIN:-/usr/bin/ld.bfd}"
  HOSTAR_BIN="${HOSTAR_BIN:-/usr/bin/ar}"
  HOSTNM_BIN="${HOSTNM_BIN:-/usr/bin/nm}"
  HOSTLDFLAGS_BIN="${HOSTLDFLAGS_BIN:--B/usr/bin}"
else
  echo "Missing required host tools (/usr/bin/gcc, /usr/bin/g++, /usr/bin/ld.bfd)."
  echo "Install build-essential/binutils (or provide HOSTCC_BIN/HOSTCXX_BIN/HOSTLD_BIN)."
  exit 1
fi

echo "Using HOSTCC=${HOSTCC_BIN}"
echo "Using HOSTCXX=${HOSTCXX_BIN}"
echo "Using HOSTLD=${HOSTLD_BIN}"
echo "Using CC=${CC}"
echo "Using LD=${LD}"
echo "Using CLANG_TRIPLE=${CLANG_TRIPLE_PREFIX}"
echo "Using CROSS_COMPILE=${CROSS_COMPILE_PREFIX}"
echo "Using CROSS_COMPILE_ARM32=${CROSS_COMPILE_ARM32_PREFIX}"

if [[ "${DISABLE_WERROR}" == "1" ]]; then
  echo "[4.1/6] Disabling vendor -Werror flags for modern clang compatibility..."
  find "${KERNEL_DIR}" -type f \( -name Makefile -o -name Kbuild \) \
    -exec sed -i -E \
      -e 's/(^|[[:space:]])-Werror=([[:alnum:]_,-]+)($|[[:space:]])/\1-Wno-error=\2\3/g' \
      -e 's/(^|[[:space:]])-Werror($|[[:space:]])/\1-Wno-error\2/g' {} +
fi

KMAKE_ARGS=(
  O="${OUT_DIR}"
  ARCH=arm64
  LLVM=1
  LLVM_IAS=1
  CLANG_TRIPLE="${CLANG_TRIPLE_PREFIX}"
  CROSS_COMPILE="${CROSS_COMPILE_PREFIX}"
  CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32_PREFIX}"
  CC="${CC}"
  LD="${LD}"
  AR="${AR}"
  NM="${NM}"
  OBJCOPY="${OBJCOPY}"
  OBJDUMP="${OBJDUMP}"
  STRIP="${STRIP}"
  READELF="${READELF}"
  HOSTCC="${HOSTCC_BIN}"
  HOSTCXX="${HOSTCXX_BIN}"
  HOSTLD="${HOSTLD_BIN}"
  HOSTAR="${HOSTAR_BIN}"
  HOSTNM="${HOSTNM_BIN}"
  HOSTLDFLAGS="${HOSTLDFLAGS_BIN}"
)

if [[ "${DISABLE_WERROR}" == "1" ]]; then
  KMAKE_ARGS+=(
    KCFLAGS="-Wno-error -Wno-error=pointer-to-int-cast -Wno-error=void-pointer-to-int-cast -Wno-error=strict-prototypes"
    HOSTCFLAGS="-Wno-error"
    HOSTCXXFLAGS="-Wno-error"
  )
fi

cd "${KERNEL_DIR}"
make "${KMAKE_ARGS[@]}" ruby_user_defconfig

echo "[4.5/6] Applying profile: ${BUILD_PROFILE}"

set_cfg() {
  "${KERNEL_DIR}/scripts/config" --file "${OUT_DIR}/.config" "$@" || true
}

# Always keep clang LTO path enabled and prefer ThinLTO.
set_cfg -e LTO_CLANG
set_cfg -d LTO_NONE
set_cfg -e THINLTO
set_cfg -e CPU_FREQ_DEFAULT_GOV_SCHEDUTIL

# Safe release defaults: remove debug-only overhead when possible.
set_cfg -d PM_DEBUG
set_cfg -d MTK_SCHED_TRACERS
if [[ "${DISABLE_WERROR}" == "1" ]]; then
  set_cfg -d WERROR
fi

if [[ "${ENABLE_SUKISU}" == "1" ]]; then
  # Non-GKI kernel path.
  set_cfg -e KSU
  set_cfg -e KSU_MANUAL_HOOK
  set_cfg -e KALLSYMS
  set_cfg -e KALLSYMS_ALL
  set_cfg -e KPM
fi

if [[ "${ENABLE_SUSFS}" == "1" ]]; then
  set_cfg -e KSU_SUSFS
  set_cfg -e KSU_SUSFS_HAS_MAGIC_MOUNT
  set_cfg -e KSU_SUSFS_SPOOF_UNAME
  set_cfg -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
  set_cfg -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
  set_cfg -e KSU_SUSFS_TRY_UMOUNT
fi

if [[ "${ENABLE_MODERN_STACK}" == "1" ]]; then
  echo "[4.6/6] Enabling modern kernel feature pack..."

  # Modern observability and packet path.
  set_cfg -e PSI
  set_cfg -e BPF
  set_cfg -e BPF_SYSCALL
  set_cfg -e BPF_JIT
  set_cfg -e BPF_JIT_ALWAYS_ON
  set_cfg -e BPF_EVENTS
  set_cfg -e CGROUP_BPF
  set_cfg -e NET_CLS_BPF
  set_cfg -e NET_ACT_BPF
  set_cfg -e XDP_SOCKETS

  # Modern network stack defaults.
  set_cfg -e NET_SCH_DEFAULT
  set_cfg -e NET_SCH_FQ
  set_cfg -e DEFAULT_FQ
  set_cfg --set-str DEFAULT_NET_SCH fq
  set_cfg -e TCP_CONG_ADVANCED
  set_cfg -e TCP_CONG_BBR
  set_cfg -e DEFAULT_BBR
  set_cfg --set-str DEFAULT_TCP_CONG bbr
  set_cfg -m WIREGUARD

  # Modern memory/swap path for better efficiency on phones.
  set_cfg -e SWAP
  set_cfg -e FRONTSWAP
  set_cfg -e ZSWAP
  set_cfg -e Z3FOLD
  set_cfg -e ZSMALLOC
  set_cfg -e ZRAM
  set_cfg -e ZRAM_WRITEBACK
  set_cfg -e LZ4_COMPRESS
  set_cfg -e LZ4_DECOMPRESS
  set_cfg -e ZSTD_COMPRESS
  set_cfg -e ZSTD_DECOMPRESS
  set_cfg -e CRYPTO_LZ4
  set_cfg -e CRYPTO_ZSTD
  set_cfg -e CRYPTO_CHACHA20POLY1305
  set_cfg -e CRYPTO_POLY1305
  set_cfg -e CRYPTO_BLAKE2S
fi

if [[ "${BUILD_PROFILE}" == "performance" ]]; then
  # Higher throughput and lower latency at the cost of some safety and battery.
  set_cfg -d CFI_CLANG
  set_cfg -e HZ_300
  set_cfg -d HZ_250
  set_cfg -d HZ_100
  set_cfg -d HZ_1000
  set_cfg --set-val HZ 300
fi

if [[ "${BUILD_PROFILE}" == "battery" ]]; then
  # Keep hardening and reduce scheduling overhead for better efficiency.
  set_cfg -e CFI_CLANG
  set_cfg -e HZ_250
  set_cfg -d HZ_300
  set_cfg -d HZ_100
  set_cfg -d HZ_1000
  set_cfg --set-val HZ 250
  set_cfg -e WQ_POWER_EFFICIENT_DEFAULT
fi

if [[ "${BUILD_PROFILE}" == "balanced" ]]; then
  # Daily-driver profile: keep CFI enabled, moderate timer rate.
  set_cfg -e CFI_CLANG
  set_cfg -e HZ_300
  set_cfg -d HZ_250
  set_cfg -d HZ_100
  set_cfg -d HZ_1000
  set_cfg --set-val HZ 300
fi

if [[ "${ENABLE_CUSTOM_CONFIG}" == "1" ]]; then
  echo "[4.7/6] Applying custom config fragment..."
  if [[ -f "${CUSTOM_CONFIG_FRAGMENT}" ]]; then
    # Merge user fragment after profile/feature toggles so custom values win.
    "${KERNEL_DIR}/scripts/kconfig/merge_config.sh" \
      -m -r -O "${OUT_DIR}" "${OUT_DIR}/.config" "${CUSTOM_CONFIG_FRAGMENT}"
  else
    echo "Custom config fragment not found: ${CUSTOM_CONFIG_FRAGMENT}"
    echo "Continuing without fragment."
  fi
fi

make "${KMAKE_ARGS[@]}" olddefconfig

echo "[5/6] Building kernel..."
BUILD_LOG="${ROOT_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
if ! make -j"${BUILD_JOBS}" "${KMAKE_ARGS[@]}" 2>&1 | tee "${BUILD_LOG}"; then
  echo
  echo "Build failed."
  echo "Full log: ${BUILD_LOG}"
  echo "First matched error lines:"
  grep -nE 'fatal error:| error:|undefined reference|collect2: error|No rule to make target|make\[[0-9]+\]: \*\*\* .* Error' "${BUILD_LOG}" | head -n 40 || true
  exit 1
fi

echo "[6/6] Collecting artifacts..."
cp -fv "${OUT_DIR}/arch/arm64/boot/Image"* "${ARTIFACTS_DIR}/" || true
cp -fv "${OUT_DIR}/arch/arm64/boot/dtbo.img" "${ARTIFACTS_DIR}/" || true
cp -fv "${OUT_DIR}/arch/arm64/boot/dts/mediatek/"*.dtb "${ARTIFACTS_DIR}/" 2>/dev/null || true

echo
echo "Build finished."
echo "Artifacts directory: ${ARTIFACTS_DIR}"
ls -lah "${ARTIFACTS_DIR}"
