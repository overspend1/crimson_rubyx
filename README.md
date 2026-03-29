# Crimson RubyX Kernel

Custom Xiaomi `ruby/rubypro` kernel build setup based on Xiaomi `ruby-s-oss` (`ruby_user_defconfig`), with:
- performance/battery profiles
- `clang + ThinLTO`
- SukiSU-Ultra integration
- SUSFS integration
- custom config fragment merge
- AnyKernel3 flashable zip packaging

## Quick Start (Linux)

```bash
git clone https://github.com/overspend1/crimson_rubyx.git
cd crimson_rubyx
chmod +x ./build-ruby-kernel.sh ./make-anykernel-zip.sh
./build-ruby-kernel.sh
```

No `sudo` on server? If build dependencies are already installed:

```bash
SKIP_DEPS_INSTALL=1 ./build-ruby-kernel.sh
```

## Build Profiles

```bash
BUILD_PROFILE=balanced ./build-ruby-kernel.sh
BUILD_PROFILE=performance ./build-ruby-kernel.sh
BUILD_PROFILE=battery ./build-ruby-kernel.sh
```

- `balanced`: daily-driver profile
- `performance`: more speed/responsiveness, higher heat/drain risk
- `battery`: lower scheduler overhead for better efficiency

## Main Build Flags

```bash
ENABLE_MODERN_STACK=1 ./build-ruby-kernel.sh
ENABLE_SUKISU=1 ENABLE_SUSFS=1 ./build-ruby-kernel.sh
SUKISU_REF=builtin ./build-ruby-kernel.sh
```

Notes:
- docs aliases `susfs-main` / `susfs-dev` / `susfs-test` are auto-mapped to `builtin`
- if selected SukiSU ref lacks `KSU_SUSFS`, official `susfs4ksu` (`kernel-4.19`) patches are auto-applied

## Custom Config Fragment

Default fragment:

```bash
configs/ruby_custom.fragment
```

Examples:

```bash
ENABLE_CUSTOM_CONFIG=1 ./build-ruby-kernel.sh
ENABLE_CUSTOM_CONFIG=0 ./build-ruby-kernel.sh
CUSTOM_CONFIG_FRAGMENT=/absolute/path/my.fragment ./build-ruby-kernel.sh
```

## Kernel Build Outputs

Kernel artifacts are collected in:

```bash
~/kramel-ruby/artifacts
```

## Build AnyKernel Installable Zip

After a successful kernel build:

```bash
./make-anykernel-zip.sh
```

Output zip:

```bash
./out/Crimson-RubyX-ruby-rubypro-<timestamp>.zip
```

Useful options:

```bash
ARTIFACTS_DIR=/path/to/artifacts ./make-anykernel-zip.sh
ZIP_VERSION=v1.0 ./make-anykernel-zip.sh
KERNEL_NAME="Crimson RubyX" DEVICE_TAG=ruby ./make-anykernel-zip.sh
```

AnyKernel device profile used by the packager:

```bash
anykernel/anykernel.sh
```

## Flashing

Flash the generated AnyKernel zip from your recovery/installer flow.  
Bootloader must be unlocked.

## Limitations

This project targets Xiaomi's `android-4.19-stable` tree.  
Newer 6.x/7.x Linux kernel features are not natively available without heavy backports/rebase.

## Warning

`susfs` is invasive on non-GKI/vendor trees. Patch conflicts and bootloops are possible.
