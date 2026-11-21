#!/usr/bin/env bash
# FOID Linux - Stage 1: the Linux kernel from source (kernel.org).
# Run as a regular user; root is NOT needed.
# The kernel is built with the HOST gcc (the kernel needs no libc), not the musl cross compiler.
#
# Variables (optional):
#   FOID_KERNEL_SERIES=6.18        branch (LTS), default 6.18
#   FOID_KERNEL_VERSION=6.18.N     exact version instead of "latest in the branch"
#   FOID_MENUCONFIG=1              open menuconfig before building
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
unset CROSS_COMPILE   # in case of an old env.sh that exported it

die() { echo "!!! $*" >&2; exit 1; }

KERNEL_SERIES="${FOID_KERNEL_SERIES:-6.18}"
KERNEL_BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_SERIES%%.*}.x"

# Required options: must end up as =y (built into the kernel, no modules),
# otherwise the script stops. Everything needed to boot from ISO/USB/disk
# is built in on purpose - at this early stage we have no udev/mdev to autoload modules.
REQUIRED=(
    BLK_DEV_INITRD RD_GZIP DEVTMPFS TMPFS PROC_FS SYSFS
    BLK_DEV_LOOP ISO9660_FS JOLIET SQUASHFS SQUASHFS_XZ OVERLAY_FS
    SCSI BLK_DEV_SD BLK_DEV_SR
    ATA ATA_SFF ATA_BMDMA ATA_PIIX SATA_AHCI
    USB_SUPPORT USB USB_XHCI_HCD USB_XHCI_PCI USB_EHCI_HCD USB_EHCI_PCI USB_STORAGE
    NLS_CODEPAGE_437 NLS_ISO8859_1
    TTY VT VT_CONSOLE SERIAL_8250 SERIAL_8250_CONSOLE
    # screen on real UEFI hardware: without SYSFB_SIMPLEFB simpledrm gets no framebuffer -> black screen
    DRM DRM_SIMPLEDRM SYSFB_SIMPLEFB FB FRAMEBUFFER_CONSOLE
)
# Desirable options: only a warning on failure (symbol names may have
# changed between kernel versions).
OPTIONAL=(
    VGA_CONSOLE UNIX98_PTYS ATA_GENERIC BLK_DEV_NVME
    USB_UHCI_HCD USB_OHCI_HCD USB_OHCI_HCD_PCI USB_HID HID HID_GENERIC
    EXT4_FS FAT_FS VFAT_FS EXFAT_FS NTFS3_FS NLS_UTF8
    NETDEVICES ETHERNET NET_VENDOR_INTEL NET_VENDOR_REALTEK E1000 E1000E R8169
    VIRTIO_MENU VIRTIO VIRTIO_PCI VIRTIO_BLK VIRTIO_NET
    DRM DRM_SIMPLEDRM DRM_BOCHS DRM_VIRTIO_GPU DRM_FBDEV_EMULATION FB FRAMEBUFFER_CONSOLE
    EFI EFI_STUB X86_SYSFB SYSFB_SIMPLEFB FB_EFI FB_VESA FB_SIMPLE FB_DEVICE
    FRAMEBUFFER_CONSOLE_DETECT_PRIMARY FONT_SUPPORT FONT_8x16 FONT_TER16x32 FONTS
    I2C ACPI_VIDEO INPUT_KEYBOARD KEYBOARD_ATKBD MOUSE_PS2 INPUT_EVDEV
)

echo ">>> [1/6] Checking host dependencies"
missing=()
for tool in gcc make bc flex bison perl curl tar xz sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[ -f /usr/include/libelf.h ] || [ -f /usr/include/gelf.h ] || missing+=("libelf (headers)")
[ -f /usr/include/openssl/evp.h ] || missing+=("openssl (headers)")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "!!! Missing on the host: ${missing[*]}"
    echo "    On Arch:  sudo pacman -S --needed base-devel bc libelf openssl cpio"
    exit 1
fi

echo ">>> [2/6] Kernel version"
if [ -n "${FOID_KERNEL_VERSION:-}" ]; then
    KVER="$FOID_KERNEL_VERSION"
else
    series_re="$(printf '%s' "$KERNEL_SERIES" | sed 's/\./\\./g')"
    KVER="$(curl -fsSL --retry 3 "$KERNEL_BASE_URL/" \
        | grep -oE "linux-${series_re}\.[0-9]+\.tar\.xz" \
        | sed -E 's/^linux-//; s/\.tar\.xz$//' \
        | sort -uV | tail -n1)" || true
fi
[ -n "${KVER:-}" ] || die "Could not determine the kernel version. Set it manually: FOID_KERNEL_VERSION=6.18.N ./build-01-kernel.sh"
echo "    kernel: $KVER"

echo ">>> [3/6] Downloading and verifying"
mkdir -p "$FOID_SRC" "$FOID_BUILD" "$FOID_OUT"
TARBALL="$FOID_SRC/linux-$KVER.tar.xz"
if [ ! -f "$TARBALL" ]; then
    curl -fL --retry 3 -o "$TARBALL.part" "$KERNEL_BASE_URL/linux-$KVER.tar.xz"
    mv "$TARBALL.part" "$TARBALL"
fi
# No pipeline: awk exits on the first match, and printf under pipefail
# got SIGPIPE and silently killed the script (exit 141). We read from a file.
SUMS_FILE="$FOID_SRC/kernel-sha256sums.asc"
curl -fsSL --retry 3 -o "$SUMS_FILE" "$KERNEL_BASE_URL/sha256sums.asc" 2>/dev/null || : > "$SUMS_FILE"
expected="$(awk -v f="linux-$KVER.tar.xz" '$2 == f {print $1; exit}' "$SUMS_FILE")"
if [ -n "$expected" ]; then
    echo "$expected  $TARBALL" | sha256sum -c - || { rm -f "$TARBALL"; die "Checksum mismatch, archive removed. Run the script again."; }
else
    echo "    (could not get the checksum - skipping verification)"
fi

SRC="$FOID_SRC/linux-$KVER"
[ -d "$SRC" ] || tar -xf "$TARBALL" -C "$FOID_SRC"
BUILD="$FOID_BUILD/linux-$KVER"
mkdir -p "$BUILD"

echo ">>> [4/6] Configuration (defconfig + FOID options)"
make -C "$SRC" O="$BUILD" defconfig
cfg() { "$SRC/scripts/config" --file "$BUILD/.config" "$@"; }
cfg --set-str LOCALVERSION "-foid"
cfg -d DEBUG_INFO_BTF -d DEBUG_INFO_BTF_MODULES -d WERROR
for s in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do cfg -e "$s"; done
make -C "$SRC" O="$BUILD" olddefconfig

fail=0
for s in "${REQUIRED[@]}"; do
    grep -q "^CONFIG_${s}=y" "$BUILD/.config" || { echo "!!! required CONFIG_$s did not get enabled"; fail=1; }
done
for s in "${OPTIONAL[@]}"; do
    grep -q "^CONFIG_${s}=y" "$BUILD/.config" || echo "    ? CONFIG_$s did not get enabled (not critical)"
done
if [ "$fail" -ne 0 ]; then
    echo "    Most likely the option depends on another one that is disabled."
    echo "    Look: make -C $SRC O=$BUILD menuconfig   (search with '/')"
    exit 1
fi
if [ "${FOID_MENUCONFIG:-0}" = "1" ]; then
    make -C "$SRC" O="$BUILD" menuconfig
fi

echo ">>> [5/6] Building (-j${FOID_JOBS})"
make -C "$SRC" O="$BUILD" -j"$FOID_JOBS" bzImage modules

echo ">>> [6/6] Install: vmlinuz -> out/, modules -> rootfs/"
cp "$BUILD/arch/x86/boot/bzImage" "$FOID_OUT/vmlinuz"
cp "$BUILD/.config" "$FOID_OUT/kernel.config"
mkdir -p "$FOID_ROOTFS"
make -C "$SRC" O="$BUILD" INSTALL_MOD_PATH="$FOID_ROOTFS" INSTALL_MOD_STRIP=1 modules_install
# the build/ and source/ symlinks point to host directories - not needed in the image
find "$FOID_ROOTFS/lib/modules" -maxdepth 2 -type l \( -name build -o -name source \) -delete

echo ""
echo "OK: kernel $(make -s -C "$SRC" O="$BUILD" kernelrelease) built"
echo "    image:   $FOID_OUT/vmlinuz"
echo "    config:  $FOID_OUT/kernel.config"
echo "    modules: $FOID_ROOTFS/lib/modules/"
