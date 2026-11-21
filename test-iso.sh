#!/usr/bin/env bash
# FOID Linux - boot the built ISO in QEMU through limine (like on real hardware).
# The QEMU window = the screen (tty1), this terminal = the serial console (ttyS0). Exit: close the window or Ctrl+C.
#
#   ./test-iso.sh                 BIOS boot (default)
#   FOID_UEFI=1 ./test-iso.sh     UEFI boot (needs the edk2-ovmf package)
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

die() { echo "!!! $*" >&2; exit 1; }

ISO="$FOID_OUT/foid-linux.iso"
[ -f "$ISO" ] || die "No $ISO - run ./build-04-iso.sh first"
command -v qemu-system-x86_64 >/dev/null 2>&1 || die "QEMU not found. On Arch: sudo pacman -S --needed qemu-system-x86"

args=(-m 2G -cdrom "$ISO" -boot d -serial stdio)
# FOID_KEEP=1: do not close QEMU after the guest powers off/crashes - the last screen stays visible
if [ "${FOID_KEEP:-0}" = "1" ]; then args+=(-no-shutdown -no-reboot); fi

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    args+=(-enable-kvm -cpu host)
else
    echo "(KVM unavailable - it will be slower. Check: ls -l /dev/kvm; you need the kvm group)"
fi

if [ "${FOID_UEFI:-0}" = "1" ]; then
    code=""; vars=""
    for pair in \
        "/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd" \
        "/usr/share/edk2/x64/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_VARS.fd" \
        "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd" \
        "/usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_VARS.fd" \
        "/usr/share/ovmf/x64/OVMF_CODE.fd /usr/share/ovmf/x64/OVMF_VARS.fd"; do
        # shellcheck disable=SC2086
        set -- $pair
        if [ -f "$1" ] && [ -f "$2" ]; then code="$1"; vars="$2"; break; fi
    done
    [ -n "$code" ] || die "OVMF not found. On Arch: sudo pacman -S --needed edk2-ovmf"
    vars_copy="$(mktemp)"
    trap 'rm -f "$vars_copy"' EXIT
    cp "$vars" "$vars_copy"
    args+=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$vars_copy")
    echo ">>> UEFI mode (OVMF: $code)"
else
    echo ">>> BIOS mode"
fi

exec qemu-system-x86_64 "${args[@]}"
