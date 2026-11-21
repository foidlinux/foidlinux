#!/usr/bin/env bash
# FOID Linux - common build environment. Use it with: source ./env.sh
# Host: Arch-based (tested on Arch). The scripts are written for bash.
# (Scripts INSIDE the target system - /init, /etc/runit/* - stay POSIX sh for busybox ash.)

export FOID_TOP="${FOID_TOP:-$HOME/foid}"
export FOID_TARGET="x86_64-linux-musl"
export FOID_TOOLCHAIN="$FOID_TOP/toolchain"   # cross toolchain (gcc, binutils, musl)
export FOID_SRC="$FOID_TOP/sources"           # downloaded sources and archives
export FOID_BUILD="$FOID_TOP/build"           # build work directories
export FOID_OUT="$FOID_TOP/out"               # finished artifacts (vmlinuz, initramfs, ISO)
export FOID_ROOTFS="$FOID_TOP/rootfs"         # root filesystem of the system
FOID_JOBS="$(nproc)"
export FOID_JOBS

export PATH="$FOID_TOOLCHAIN/bin:$PATH"

# CROSS_COMPILE is deliberately NOT exported here: the Linux kernel picks up this
# variable from the environment and would start building with the musl compiler instead of
# the host gcc. Scripts that need it (busybox etc.) get the prefix explicitly:
#   make CROSS_COMPILE="${FOID_TARGET}-" ...
unset CROSS_COMPILE
