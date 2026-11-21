#!/usr/bin/env bash
# FOID Linux - Stage 2: static busybox on the musl toolchain + rootfs skeleton.
# Run as a regular user; root is NOT needed.
#
# Variables (optional):
#   FOID_BUSYBOX_VERSION=1.N.M   exact version instead of "latest stable"
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

die() { echo "!!! $*" >&2; exit 1; }

BB_BASE_URL="https://busybox.net/downloads"
CROSS="${FOID_TARGET}-"

echo ">>> [1/6] Checking toolchain and host"
command -v "${CROSS}gcc" >/dev/null 2>&1 || die "${CROSS}gcc not found. Run ./build-00-toolchain.sh first (and source env.sh)."
for tool in make curl tar bzip2 sha256sum sed awk; do
    command -v "$tool" >/dev/null 2>&1 || die "The host has no '$tool' (sudo pacman -S --needed base-devel bzip2 curl)"
done

echo ">>> [2/6] busybox version"
if [ -n "${FOID_BUSYBOX_VERSION:-}" ]; then
    BBVER="$FOID_BUSYBOX_VERSION"
else
    BBVER="$(curl -fsSL --retry 3 "$BB_BASE_URL/" \
        | grep -oE 'busybox-1\.[0-9]+\.[0-9]+\.tar\.bz2' \
        | sed -E 's/^busybox-//; s/\.tar\.bz2$//' \
        | sort -uV | tail -n1)" || true
fi
[ -n "${BBVER:-}" ] || die "Could not determine the version. Set it manually: FOID_BUSYBOX_VERSION=1.N.M ./build-02-busybox.sh (or put busybox-1.N.M.tar.bz2 into $FOID_SRC)"
echo "    busybox: $BBVER"

echo ">>> [3/6] Downloading and verifying"
mkdir -p "$FOID_SRC" "$FOID_BUILD" "$FOID_OUT"
TARBALL="$FOID_SRC/busybox-$BBVER.tar.bz2"
if [ ! -f "$TARBALL" ]; then
    curl -fL --retry 3 -o "$TARBALL.part" "$BB_BASE_URL/busybox-$BBVER.tar.bz2"
    mv "$TARBALL.part" "$TARBALL"
fi
expected="$(curl -fsSL --retry 3 "$BB_BASE_URL/busybox-$BBVER.tar.bz2.sha256" 2>/dev/null | awk '{print $1; exit}' || true)"
if [ -n "$expected" ]; then
    echo "$expected  $TARBALL" | sha256sum -c - || { rm -f "$TARBALL"; die "Checksum mismatch, archive removed. Run the script again."; }
else
    echo "    (could not get the checksum - skipping verification)"
fi

echo ">>> [4/6] Configuration (defconfig + static)"
BBDIR="$FOID_BUILD/busybox-$BBVER"
rm -rf "$BBDIR"
tar -xjf "$TARBALL" -C "$FOID_BUILD"
cd "$BBDIR"
make CROSS_COMPILE="$CROSS" defconfig

# bb_set SYMBOL y|n - enable/disable an option in .config
bb_set() {
    local sym="$1" val="$2"
    sed -i -E "/^(# )?CONFIG_${sym}[= ]/d" .config
    if [ "$val" = "y" ]; then
        echo "CONFIG_${sym}=y" >> .config
    else
        echo "# CONFIG_${sym} is not set" >> .config
    fi
}
bb_set STATIC y                # static linking: also works as the initramfs busybox
bb_set TC n                    # tc breaks with some kernel-headers versions, we do not need it
bb_set FEATURE_TC_INGRESS n
(yes "" || true) | make CROSS_COMPILE="$CROSS" oldconfig >/dev/null

grep -q '^CONFIG_STATIC=y' .config || die "CONFIG_STATIC did not get enabled"
grep -q '^# CONFIG_TC is not set' .config || die "CONFIG_TC did not get disabled"

echo ">>> [5/6] Build and install into rootfs (-j${FOID_JOBS})"
make -j"$FOID_JOBS" CROSS_COMPILE="$CROSS"
mkdir -p "$FOID_ROOTFS"
make CROSS_COMPILE="$CROSS" CONFIG_PREFIX="$FOID_ROOTFS" install
cp busybox "$FOID_OUT/busybox-static"

if "${CROSS}readelf" -l busybox 2>/dev/null | grep -q INTERP; then
    die "busybox came out dynamic (has INTERP) - the initramfs needs a static one"
fi
echo "    busybox is static: OK"

echo ">>> [6/6] rootfs skeleton and basic /etc files"
cd "$FOID_ROOTFS"
for d in dev proc sys run tmp root home mnt media opt srv etc var/log var/tmp lib usr/lib; do
    mkdir -p "$d"
done
chmod 1777 tmp var/tmp
chmod 0700 root

[ -f etc/hostname ]  || printf 'foid\n' > etc/hostname
[ -f etc/passwd ]    || printf 'root:x:0:0:root:/root:/bin/sh\n' > etc/passwd
[ -f etc/group ]     || printf 'root:x:0:\n' > etc/group
[ -f etc/os-release ] || cat > etc/os-release <<'EOF'
NAME="FOID Linux"
ID=foid
PRETTY_NAME="FOID Linux"
HOME_URL="https://foidlinux.github.io/foidlinuxsite/"
EOF

echo ""
echo "OK: busybox $BBVER (static) installed into $FOID_ROOTFS"
echo "    copy for the initramfs: $FOID_OUT/busybox-static"
echo "    next: ./test-qemu.sh"
