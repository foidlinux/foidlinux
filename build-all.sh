#!/usr/bin/env bash
# FOID Linux - build everything from scratch with one command: ./build-all.sh
# Order: toolchain -> kernel -> busybox -> runit -> (character, network, apps, git) -> ISO.
# Long steps that are already done are skipped (by the presence of their result). Rebuild everything: FOID_FORCE=1 ./build-all.sh
# Only the ISO (fast): ./build-all.sh iso
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
cd "$SCRIPT_DIR"

FORCE="${FOID_FORCE:-0}"

# step NAME SCRIPT [MARKER] - run the script; if MARKER already exists (and no FORCE) - skip it
step() {
    local name="$1" script="$2" marker="${3:-}"
    if [ "$FORCE" != "1" ] && [ -n "$marker" ] && [ -e "$marker" ]; then
        echo ">>> [$name] already done ($marker) - skipping (FOID_FORCE=1 rebuilds)"
        return 0
    fi
    echo ""
    echo "################ $name ################"
    "$SCRIPT_DIR/$script"
}

if [ "${1:-}" = "iso" ]; then
    step "ISO" build-04-iso.sh
    exit 0
fi

step "0 toolchain" build-00-toolchain.sh "$FOID_TOOLCHAIN/bin/${FOID_TARGET}-gcc"
step "1 kernel"    build-01-kernel.sh    "$FOID_OUT/vmlinuz"
step "2 busybox"   build-02-busybox.sh   "$FOID_OUT/busybox-static"
step "3 runit"     build-03-runit.sh     "$FOID_ROOTFS/sbin/runit-init"
step "5 foid"      build-05-foid.sh
step "6 network"   build-06-network.sh
step "7 apps"      build-07-apps.sh      "$FOID_ROOTFS/usr/bin/htop"
step "8 git"       build-08-git.sh       "$FOID_ROOTFS/usr/bin/git"
step "4 iso"       build-04-iso.sh

echo ""
echo "================================================================"
echo "OK: FOID Linux built -> $FOID_OUT/foid-linux.iso"
( cd "$FOID_OUT" && sha256sum foid-linux.iso | tee foid-linux.iso.sha256 )
echo "Test in QEMU: ./test-iso.sh   (UEFI: FOID_UEFI=1 ./test-iso.sh)"
echo "================================================================"
