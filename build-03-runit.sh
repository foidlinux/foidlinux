#!/usr/bin/env bash
# FOID Linux - Stage 3: runit (PID 1 + service supervisor) from source, static, on the musl toolchain.
# Plus: stages /etc/runit/1,2,3, getty on tty1 and ttyS0, poweroff/reboot commands, basic /etc files.
# Run as a regular user; root is NOT needed.
#
# Variables (optional):
#   FOID_RUNIT_VERSION=2.1.2   runit version (default 2.1.2)
#   You can place the archive manually: $FOID_SRC/runit-<version>.tar.gz (then the download is skipped)
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

die() { echo "!!! $*" >&2; exit 1; }

CROSS="${FOID_TARGET}-"
RUNIT_VERSION="${FOID_RUNIT_VERSION:-2.1.2}"
RUNIT_URL="https://smarden.org/runit/runit-${RUNIT_VERSION}.tar.gz"
RUNIT_BINS=(chpst runit runit-init runsv runsvchdir runsvdir sv svlogd utmpset)

echo ">>> [1/5] Checking toolchain, busybox and host"
command -v "${CROSS}gcc" >/dev/null 2>&1 || die "${CROSS}gcc not found. Run ./build-00-toolchain.sh first (and source env.sh)."
[ -x "$FOID_ROOTFS/bin/busybox" ] || die "No $FOID_ROOTFS/bin/busybox - run ./build-02-busybox.sh first"
for tool in make curl tar gzip sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "The host has no '$tool' (sudo pacman -S --needed base-devel curl)"
done

echo ">>> [2/5] Downloading runit $RUNIT_VERSION"
mkdir -p "$FOID_SRC" "$FOID_BUILD"
TARBALL="$FOID_SRC/runit-$RUNIT_VERSION.tar.gz"
if [ ! -f "$TARBALL" ]; then
    curl -fL --retry 3 -o "$TARBALL.part" "$RUNIT_URL"
    mv "$TARBALL.part" "$TARBALL"
fi
echo "    sha256: $(sha256sum "$TARBALL" | awk '{print $1}')  (upstream has no checksum file - just for the record)"

echo ">>> [3/5] Building (static, ${CROSS}gcc)"
WORK="$FOID_BUILD/runit-$RUNIT_VERSION"
rm -rf "$WORK"
mkdir -p "$WORK"
tar -xzf "$TARBALL" -C "$WORK"
RDIR="$WORK/admin/runit-$RUNIT_VERSION"
[ -d "$RDIR/src" ] || die "Unexpected archive layout: no $RDIR/src (contents of $WORK: $(ls "$WORK" | tr '\n' ' '))"
printf '%s\n' "${CROSS}gcc -O2 -Wall" > "$RDIR/src/conf-cc"
printf '%s\n' "${CROSS}gcc -static -s" > "$RDIR/src/conf-ld"
( cd "$RDIR" && sh package/compile )

echo ">>> [4/5] Installing binaries into rootfs/sbin"
mkdir -p "$FOID_ROOTFS/sbin"
for b in "${RUNIT_BINS[@]}"; do
    src=""
    for dir in "$RDIR/compile" "$RDIR/command" "$RDIR/src"; do
        if [ -f "$dir/$b" ] && [ -x "$dir/$b" ]; then src="$dir/$b"; break; fi
    done
    [ -n "$src" ] || die "Built '$b' not found (looked in compile/, command/, src/ inside $RDIR)"
    if "${CROSS}readelf" -l "$src" 2>/dev/null | grep -q INTERP; then
        die "$b came out dynamic - a static one is needed"
    fi
    install -m 0755 "$src" "$FOID_ROOTFS/sbin/$b"
    echo "    + $b"
done
# busybox install already created /sbin/init -> busybox; PID 1 here is runit-init.
# Important: runit-init hard-codes /sbin/runit, so all binaries live in /sbin.
ln -sfn runit-init "$FOID_ROOTFS/sbin/init"

echo ">>> [5/5] runit stages, services and basic /etc files"
cd "$FOID_ROOTFS"
mkdir -p etc/runit etc/sv etc/service

cat > etc/runit/1 <<'EOF'
#!/bin/sh
# Stage 1: one-time system initialisation
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm
mount -t devpts   devpts   /dev/pts 2>/dev/null
mount -t tmpfs    tmpfs    /dev/shm 2>/dev/null
mount -t tmpfs    tmpfs    /run
mount -t tmpfs -o mode=1777 tmpfs /tmp
mkdir -p /run/lock

hostname -F /etc/hostname 2>/dev/null
ip link set lo up 2>/dev/null

exit 0
EOF

cat > etc/runit/2 <<'EOF'
#!/bin/sh
# Stage 2: the main stage - the service supervisor for /etc/service
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec runsvdir -P /etc/service
EOF

cat > etc/runit/3 <<'EOF'
#!/bin/sh
# Stage 3: system shutdown (afterwards runit itself powers off or reboots the machine)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
echo "FOID Linux: stopping services..."
sv -w 7 force-stop /etc/service/* 2>/dev/null
sv exit /etc/service/* 2>/dev/null
sync
umount -a -r 2>/dev/null
exit 0
EOF
chmod 0755 etc/runit/1 etc/runit/2 etc/runit/3

# poweroff/reboot: the busybox versions signal busybox init, which runit ignores.
# The real way for runit: runit-init 0 (power off) / runit-init 6 (reboot).
rm -f sbin/poweroff sbin/halt sbin/reboot
cat > sbin/poweroff <<'EOF'
#!/bin/sh
exec /sbin/runit-init 0
EOF
cat > sbin/reboot <<'EOF'
#!/bin/sh
exec /sbin/runit-init 6
EOF
ln -sfn poweroff sbin/halt
chmod 0755 sbin/poweroff sbin/reboot

# Services: getty on tty1 (screen) and ttyS0 (serial - for QEMU -nographic)
mkdir -p etc/sv/getty-tty1 etc/sv/getty-ttyS0
cat > etc/sv/getty-tty1/run <<'EOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec getty 38400 tty1 linux
EOF
cat > etc/sv/getty-ttyS0/run <<'EOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec getty -L 115200 ttyS0 vt100
EOF
chmod 0755 etc/sv/getty-tty1/run etc/sv/getty-ttyS0/run
ln -sfn /etc/sv/getty-tty1  etc/service/getty-tty1
ln -sfn /etc/sv/getty-ttyS0 etc/service/getty-ttyS0

# Basic files. WARNING: root has an empty password - for development only!
printf 'root::0:0:root:/root:/bin/sh\n' > etc/passwd
printf 'root:x:0:\n' > etc/group
printf '127.0.0.1 localhost foid\n::1 localhost\n' > etc/hosts
: > etc/fstab
ln -sfn /proc/self/mounts etc/mtab
mkdir -p var
ln -sfn ../run var/run
cat > etc/profile <<'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='\u@\h:\w\$ '
alias ll='ls -la'
EOF
printf 'FOID Linux \\r (\\l)\n\n' > etc/issue

echo ""
echo "OK: runit $RUNIT_VERSION installed, init = /sbin/runit-init"
echo "    services: getty-tty1, getty-ttyS0 | login: root, empty password"
echo "    next: ./test-qemu.sh   (power off from inside: poweroff)"
