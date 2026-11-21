#!/usr/bin/env bash
# FOID Linux - Stage 4: a bootable hybrid ISO (BIOS + UEFI) with limine.
# Contents: kernel + own initramfs (static busybox + /init) + rootfs.squashfs.
# Boot: limine -> kernel + initramfs -> /init finds the medium, mounts squashfs,
#           builds the overlay (squashfs + tmpfs) -> switch_root to /sbin/init (runit-init).
# Run as a regular user; root is NOT needed.
#
# Variables (optional):
#   FOID_LIMINE_DIR=/usr/share/limine   where the limine files are (limine package)
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

die() { echo "!!! $*" >&2; exit 1; }

ISO_DIR="$FOID_OUT/iso"
OUT_ISO="$FOID_OUT/foid-linux.iso"
LIMINE_DIR="${FOID_LIMINE_DIR:-/usr/share/limine}"

echo ">>> [1/6] Checking dependencies and input files"
for tool in mksquashfs xorriso cpio gzip; do
    command -v "$tool" >/dev/null 2>&1 || die "The host has no '$tool'. On Arch: sudo pacman -S --needed squashfs-tools libisoburn cpio limine"
done
[ -f "$FOID_OUT/vmlinuz" ]               || die "No $FOID_OUT/vmlinuz - run ./build-01-kernel.sh first"
[ -x "$FOID_OUT/busybox-static" ]        || die "No $FOID_OUT/busybox-static - run ./build-02-busybox.sh first"
[ -x "$FOID_ROOTFS/sbin/runit-init" ]    || die "No $FOID_ROOTFS/sbin/runit-init - run ./build-03-runit.sh first"
for f in limine-bios.sys limine-bios-cd.bin limine-uefi-cd.bin BOOTX64.EFI; do
    [ -f "$LIMINE_DIR/$f" ] || die "No $LIMINE_DIR/$f. Install: sudo pacman -S --needed limine (or set FOID_LIMINE_DIR)"
done

echo ">>> [2/6] rootfs -> squashfs"
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/limine" "$ISO_DIR/foid" "$ISO_DIR/EFI/BOOT"
# -all-root: all files inside the image belong to root, not to your host user
mksquashfs "$FOID_ROOTFS" "$ISO_DIR/foid/rootfs.squashfs" -comp xz -b 1M -noappend -no-progress -all-root

echo ">>> [3/6] initramfs (static busybox + /init)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage"/{bin,sbin,usr/bin,usr/sbin,dev,proc,sys,mnt/media,mnt/ro,mnt/rw,mnt/newroot}
install -m 0755 "$FOID_OUT/busybox-static" "$stage/bin/busybox"

cat > "$stage/init" <<'EOF'
#!/bin/busybox sh
# FOID Linux - /init in initramfs: finds the medium with foid/rootfs.squashfs,
# builds an overlay (squashfs + tmpfs) and hands over to runit-init.
# Messages are ASCII on purpose: the Linux console has no Cyrillic font.
/bin/busybox --install -s
PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH

mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1

echo "=== FOID Linux initramfs ==="

rescue() {
    echo "!!! $1"
    echo "--- /proc/filesystems:"; cat /proc/filesystems
    echo "--- block devices:"; ls -l /dev/sd* /dev/sr* /dev/nvme* /dev/vd* /dev/mmcblk* 2>/dev/null
    echo "--- last kernel messages:"; dmesg | tail -n 15
    echo "!!! Rescue shell. Try: mount -t iso9660 -o ro /dev/sdX /mnt/media; dmesg | tail"
    echo "!!! (exiting the shell = kernel panic)"
    exec setsid cttyhack sh
}

mkdir -p /mnt/media /mnt/ro /mnt/rw /mnt/newroot

# try_mount DEV: mount DEV read-only on /mnt/media, trying several filesystems.
try_mount() {
    for fs in iso9660 vfat exfat ext4 auto; do
        if mount -t "$fs" -o ro "$1" /mnt/media 2>/dev/null; then
            echo "  $1: mounted as $fs"
            return 0
        fi
    done
    echo "  $1: cannot mount (no known filesystem)"
    return 1
}

# Look for the medium: CD/DVD, USB sticks, disks. USB devices can show up late
# on real hardware, so wait up to ~30 seconds.
FOUND=""
i=0
while [ "$i" -lt 60 ] && [ -z "$FOUND" ]; do
    for dev in /dev/sr* /dev/sd* /dev/vd* /dev/nvme*n*p* /dev/mmcblk*p* /dev/nvme*n? /dev/mmcblk?; do
        [ -b "$dev" ] || continue
        # remember which devices were already tried in this pass to keep output short
        case " $TRIED " in *" $dev "*) continue ;; esac
        if try_mount "$dev"; then
            if [ -f /mnt/media/foid/rootfs.squashfs ]; then
                FOUND="$dev"
                break
            fi
            echo "  $dev: no foid/rootfs.squashfs here"
            umount /mnt/media
        fi
        TRIED="$TRIED $dev"
    done
    if [ -z "$FOUND" ]; then
        [ "$i" -eq 0 ] && echo "Waiting for the boot medium..."
        sleep 0.5
        i=$((i + 1))
        # retry devices that were not ready the first time (every ~5 s)
        [ $((i % 10)) -eq 0 ] && TRIED=""
    fi
done
SQUASH=/mnt/media/foid/rootfs.squashfs

# Fallback (Ventoy and similar): the ISO is just a file on a data partition.
# Find *.iso there, loop-mount it and take foid/rootfs.squashfs from inside.
if [ -z "$FOUND" ]; then
    echo "No plain boot medium; looking for .iso files on the disks (Ventoy etc.)..."
    mkdir -p /mnt/iso
    for dev in /dev/sr* /dev/sd* /dev/vd* /dev/nvme*n*p* /dev/mmcblk*p*; do
        [ -b "$dev" ] || continue
        try_mount "$dev" || continue
        for iso in /mnt/media/*.iso /mnt/media/*/*.iso; do
            [ -f "$iso" ] || continue
            if mount -t iso9660 -o ro,loop "$iso" /mnt/iso 2>/dev/null; then
                if [ -f /mnt/iso/foid/rootfs.squashfs ]; then
                    FOUND="$iso"
                    SQUASH=/mnt/iso/foid/rootfs.squashfs
                    break
                fi
                umount /mnt/iso
            fi
        done
        [ -n "$FOUND" ] && break
        umount /mnt/media
    done
fi
[ -n "$FOUND" ] || rescue "Boot medium with foid/rootfs.squashfs not found"
echo "Boot medium: $FOUND"

mount -t squashfs -o ro,loop "$SQUASH" /mnt/ro || rescue "squashfs mount failed"
mount -t tmpfs tmpfs /mnt/rw
mkdir -p /mnt/rw/upper /mnt/rw/work
mount -t overlay overlay \
    -o lowerdir=/mnt/ro,upperdir=/mnt/rw/upper,workdir=/mnt/rw/work \
    /mnt/newroot || rescue "overlay mount failed"

# The medium must stay mounted: the squashfs loop device lives on it.
mkdir -p /mnt/newroot/mnt/media /mnt/newroot/dev
mount --move /mnt/media /mnt/newroot/mnt/media
if grep -q ' /mnt/iso ' /proc/mounts; then
    mkdir -p /mnt/newroot/mnt/iso
    mount --move /mnt/iso /mnt/newroot/mnt/iso
fi
mount --move /dev /mnt/newroot/dev
umount /proc
umount /sys

echo "Switching to runit..."
exec switch_root /mnt/newroot /sbin/init
EOF
chmod 0755 "$stage/init"

( cd "$stage" && find . -print0 | cpio --null -o -H newc -R 0:0 --quiet | gzip -9 ) > "$ISO_DIR/boot/initramfs"

echo ">>> [4/6] Kernel, limine.conf and limine files"
cp "$FOID_OUT/vmlinuz" "$ISO_DIR/boot/vmlinuz"
cat > "$ISO_DIR/boot/limine/limine.conf" <<'EOF'
timeout: 5
serial: yes

/FOID Linux
    protocol: linux
    path: boot():/boot/vmlinuz
    module_path: boot():/boot/initramfs
    cmdline: console=ttyS0,115200 console=tty0

/FOID Linux (safe video: nomodeset)
    protocol: linux
    path: boot():/boot/vmlinuz
    module_path: boot():/boot/initramfs
    cmdline: console=tty0 nomodeset

/FOID Linux (debug: all messages on serial)
    protocol: linux
    path: boot():/boot/vmlinuz
    module_path: boot():/boot/initramfs
    cmdline: console=tty0 console=ttyS0,115200 loglevel=7
EOF
cp "$LIMINE_DIR/limine-bios.sys"    "$ISO_DIR/boot/limine/"
cp "$LIMINE_DIR/limine-bios-cd.bin" "$ISO_DIR/boot/limine/"
cp "$LIMINE_DIR/limine-uefi-cd.bin" "$ISO_DIR/boot/limine/"
cp "$LIMINE_DIR/BOOTX64.EFI"        "$ISO_DIR/EFI/BOOT/"
if [ -f "$LIMINE_DIR/BOOTIA32.EFI" ]; then cp "$LIMINE_DIR/BOOTIA32.EFI" "$ISO_DIR/EFI/BOOT/"; fi

echo ">>> [5/6] Building the hybrid ISO (xorriso)"
xorriso -as mkisofs -R -r -J -V FOID_LIVE \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$ISO_DIR" -o "$OUT_ISO"

echo ">>> [6/6] limine bios-install (so the image boots in BIOS and from a USB stick)"
if command -v limine >/dev/null 2>&1; then
    limine bios-install "$OUT_ISO"
else
    echo "!!! The 'limine' tool is not in PATH - BIOS boot from a USB stick may not work (sudo pacman -S limine)"
fi

echo ""
echo "OK: ISO built -> $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
echo "    next: ./test-iso.sh"
