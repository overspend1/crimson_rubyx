## Xiaomi ruby/rubypro kernel build

This workspace is prepared for **Xiaomi `ruby/rubypro`** using Xiaomi branch `ruby-s-oss` and defconfig `ruby_user_defconfig`.

### Important

- Build in **WSL/Linux filesystem**, not on `C:`/NTFS.
- Reason: this kernel source contains reserved filenames for Windows (for example `aux.c`), so checkout/build fails on NTFS.

### 1) Install WSL (if missing)

Run in admin PowerShell:

```powershell
wsl --install
```

After reboot, open Ubuntu and run:

```bash
mkdir -p ~/kramel
cp -r /mnt/c/Users/Wiktor/Documents/kramel/. ~/kramel/
cd ~/kramel
chmod +x ./build-ruby-kernel.sh
./build-ruby-kernel.sh
```

### 1.1) Build profiles (performance vs battery)

Default is `balanced` (recommended for daily use).

```bash
BUILD_PROFILE=balanced ~/kramel/build-ruby-kernel.sh
BUILD_PROFILE=performance ~/kramel/build-ruby-kernel.sh
BUILD_PROFILE=battery ~/kramel/build-ruby-kernel.sh
```

- `balanced`: keeps security hardening, good speed, good battery.
- `performance`: more speed/responsiveness, but weaker hardening and usually higher drain/heat.
- `battery`: aims for cooler behavior and longer battery life.

`ENABLE_MODERN_STACK=1` is enabled by default.  
To disable it:

```bash
ENABLE_MODERN_STACK=0 BUILD_PROFILE=balanced ~/kramel/build-ruby-kernel.sh
```

### 1.2) SukiSU-Ultra + SUSFS integration

This script now enables both by default:

```bash
ENABLE_SUKISU=1 ENABLE_SUSFS=1 BUILD_PROFILE=performance ~/kramel/build-ruby-kernel.sh
```

Useful options:

```bash
SUKISU_REF=builtin ~/kramel/build-ruby-kernel.sh
SUKISU_REF=susfs_features ~/kramel/build-ruby-kernel.sh
ENABLE_SUSFS=0 ~/kramel/build-ruby-kernel.sh
```

Note:
- Some docs mention `susfs-main`; upstream branch names currently include `main`, `builtin`, and `susfs_features`.
- In this script, `susfs-main` / `susfs-dev` / `susfs-test` are auto-mapped to `builtin`.
- If selected SukiSU ref does not already expose `KSU_SUSFS`, script applies official `susfs4ksu` (`kernel-4.19`) patches automatically.

### 1.3) Custom config fragment

Default fragment path:

```bash
configs/ruby_custom.fragment
```

The script merges it automatically (`ENABLE_CUSTOM_CONFIG=1` by default).  
Examples:

```bash
ENABLE_CUSTOM_CONFIG=1 ./build-ruby-kernel.sh
ENABLE_CUSTOM_CONFIG=0 ./build-ruby-kernel.sh
CUSTOM_CONFIG_FRAGMENT=/absolute/path/my.fragment ./build-ruby-kernel.sh
```

### 1.4) GitHub Actions build

Workflow file:

```text
.github/workflows/build-ruby-kernel.yml
```

It supports manual trigger (`workflow_dispatch`) with inputs:
- profile (`balanced`/`performance`/`battery`)
- modern stack on/off
- SukiSU on/off
- SUSFS on/off
- custom config on/off
- SukiSU ref
- fragment path

Build artifacts are uploaded automatically:
- kernel outputs from `/home/runner/kramel-ruby/artifacts/`
- final `.config`
- `build.log`

### 2) Output files

When build is done, outputs are in:

```bash
~/kramel-ruby/artifacts
```

### 3) Flashing note

You still need to repack/flash this kernel properly for your ROM (usually via patched `boot.img` or AnyKernel-style zip), and bootloader must be unlocked.

### 4) What "clang + ThinLTO" means

- `clang` is the compiler used to build the kernel.
- `LTO` (Link Time Optimization) lets the compiler optimize across the whole kernel.
- `ThinLTO` is a faster/lighter LTO mode that keeps most optimization benefits without huge build-time cost.

For this ruby setup, `clang + ThinLTO` is already enforced by the build script.

### 5) Modern kernel technologies implemented in this setup

Enabled in build-time config overlay (`ENABLE_MODERN_STACK=1`):

- `eBPF` stack: JIT + cgroup/BPF hooks + BPF events
- `XDP_SOCKETS` for modern packet path use-cases
- `TCP BBR` + `FQ` as default queue/congestion combination
- `WireGuard` as kernel module
- `PSI` (Pressure Stall Information)
- `ZSWAP` + `ZRAM` + writeback + modern compression primitives (`LZ4`, `ZSTD`)

### 6) Important limitation

This Xiaomi tree is based on `android-4.19-stable`.  
Some very new upstream technologies (for example Rust-for-Linux, DAMON/MGLRU generation in modern form, latest scheduler/reclaim work from 6.x/7.x) are **not available** in this source tree and cannot be safely "enabled" without heavy backport/rebase work.

### 7) Risk warning for susfs

`susfs` is invasive and patch-heavy on non-GKI trees. Patch conflicts and bootloops are possible on vendor kernels with many OEM changes.
