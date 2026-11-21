#!/usr/bin/env bash
# FOID Linux - quick test: boot the kernel + rootfs as an initramfs directly in QEMU.
# Checks: the kernel built and boots, the rootfs unpacks, static busybox works.
# This is NOT the final boot (without ISO/limine/runit), just a smoke test of stages 1-2.
# Exit QEMU: Ctrl+A, then X.
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

die() { echo "!!! $*" >&2; exit 1; }

KERNEL="$FOID_OUT/vmlinuz"
[ -f "$KERNEL" ] || die "No $KERNEL - run ./build-01-kernel.sh first"
[ -x "$FOID_ROOTFS/bin/busybox" ] || die "No $FOID_ROOTFS/bin/busybox - run ./build-02-busybox.sh first"
command -v qemu-system-x86_64 >/dev/null 2>&1 || die "QEMU not found. On Arch: sudo pacman -S --needed qemu-system-x86"
for tool in cpio gzip; do
    command -v "$tool" >/dev/null 2>&1 || die "No '$tool' (sudo pacman -S --needed cpio)"
done

# Mode: runit - a real boot through runit-init (if stage 3 is already done);
# busybox - just a shell (kernel smoke test). Force with: FOID_TEST_MODE=busybox ./test-qemu.sh
MODE="${FOID_TEST_MODE:-auto}"
if [ "$MODE" = "auto" ]; then
    if [ -x "$FOID_ROOTFS/sbin/runit-init" ]; then MODE=runit; else MODE=busybox; fi
fi
[ "$MODE" = "busybox" ] || [ -x "$FOID_ROOTFS/sbin/runit-init" ] || die "No runit-init - run ./build-03-runit.sh first"
echo ">>> test mode: $MODE"

# Temporary copy of the rootfs + a test /init (the real rootfs needs no /init).
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -a "$FOID_ROOTFS/." "$stage/"
if [ "$MODE" = "runit" ]; then
    cat > "$stage/init" <<'EOF'
#!/bin/sh
# Wrapper for the initramfs: the kernel does not mount /dev itself, and runit-init needs /dev/console.
mount -t devtmpfs devtmpfs /dev
exec /sbin/runit-init
EOF
else
    cat > "$stage/init" <<'EOF'
#!/bin/sh
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec </dev/ttyS0 >/dev/ttyS0 2>&1
echo
echo "=== FOID: kernel booted, rootfs unpacked, busybox works ==="
uname -a
echo "(exit QEMU: Ctrl+A, then X)"
exec setsid cttyhack sh
EOF
fi
chmod +x "$stage/init"

mkdir -p "$FOID_OUT"
INITRD="$FOID_OUT/test-initramfs.cpio.gz"
( cd "$stage" && find . -print0 | cpio --null -o -H newc -R 0:0 --quiet | gzip -1 ) > "$INITRD"

accel=()
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    accel=(-enable-kvm -cpu host)
else
    echo "(KVM unavailable - it will be slower. Check: ls -l /dev/kvm; you need the kvm group)"
fi

exec qemu-system-x86_64 -m 1G "${accel[@]}" \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "console=ttyS0" \
    -nographic
