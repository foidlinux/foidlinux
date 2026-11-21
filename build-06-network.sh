#!/usr/bin/env bash
# FOID Linux - Stage 6: networking. A runit DHCP service on busybox udhcpc + a script that applies the lease.
# Without default.script udhcpc gets a lease but does NOT configure the interface - that is why it is needed.
# Run after build-03-runit.sh (and build-05-foid.sh), BEFORE build-04-iso.sh. Idempotent.
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

die() { echo "!!! $*" >&2; exit 1; }

[ -d "$FOID_ROOTFS/etc/runit" ] || die "No $FOID_ROOTFS/etc/runit - run ./build-03-runit.sh first"
cd "$FOID_ROOTFS"

echo ">>> [1/3] Script that applies the DHCP lease"
mkdir -p usr/share/udhcpc
# rm before writing: never write through a symlink (see the busybox/man story)
rm -f usr/share/udhcpc/default.script
cat > usr/share/udhcpc/default.script <<'EOF'
#!/bin/sh
# Called by busybox udhcpc: $1 = deconfig | bound | renew | leasefail | nak
# Variables from udhcpc: interface ip mask router dns domain
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

case "$1" in
deconfig)
    ip addr flush dev "$interface" 2>/dev/null
    ip link set "$interface" up
    ;;
bound|renew)
    ip addr flush dev "$interface" 2>/dev/null
    ip addr add "$ip/${mask:-24}" dev "$interface"
    if [ -n "${router:-}" ]; then
        ip route del default 2>/dev/null
        for r in $router; do
            ip route add default via "$r" dev "$interface"
            break
        done
    fi
    {
        [ -n "${domain:-}" ] && echo "search $domain"
        for d in ${dns:-}; do echo "nameserver $d"; done
    } > /etc/resolv.conf.new
    if [ -s /etc/resolv.conf.new ]; then
        cat /etc/resolv.conf.new > /etc/resolv.conf
    fi
    rm -f /etc/resolv.conf.new
    echo "network: $interface got $ip (glory to FOID)"
    ;;
esac
exit 0
EOF
chmod 0755 usr/share/udhcpc/default.script

echo ">>> [2/3] runit service: dhcp"
mkdir -p etc/sv/dhcp etc/service
rm -f etc/sv/dhcp/run
cat > etc/sv/dhcp/run <<'EOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ip link set lo up 2>/dev/null

# Wait for a wired network interface (up to 30 s): skip lo, virtual ones and Wi-Fi (wl*)
iface=""
i=0
while [ -z "$iface" ] && [ "$i" -lt 30 ]; do
    for d in /sys/class/net/*; do
        n="${d##*/}"
        case "$n" in lo|wl*) continue ;; esac
        [ -e "$d/device" ] || continue
        iface="$n"
        break
    done
    if [ -z "$iface" ]; then
        sleep 1
        i=$((i + 1))
    fi
done
if [ -z "$iface" ]; then
    echo "network: no wired interface found, giving up for now"
    sleep 30
    exit 1
fi

ip link set "$iface" up
echo "network: DHCP on $iface..."
exec udhcpc -f -i "$iface" -s /usr/share/udhcpc/default.script
EOF
chmod 0755 etc/sv/dhcp/run
ln -sfn /etc/sv/dhcp etc/service/dhcp

echo ">>> [3/3] Checks"
[ "$(head -c4 bin/busybox | od -An -c | tr -d ' ')" = '177ELF' ] || die "bin/busybox is corrupted (not ELF)"
for f in usr/share/udhcpc/default.script etc/sv/dhcp/run; do
    [ -x "$f" ] || die "No executable file $f"
    [ ! -L "$f" ] || die "$f is a symlink"
    sh -n "$f" || die "Syntax error in $f"
done

echo ""
echo "OK: networking configured (dhcp service, busybox udhcpc)"
echo "    next: ./build-04-iso.sh && ./test-iso.sh   (inside the system: ip addr, ping 1.1.1.1, nslookup / wget)"
