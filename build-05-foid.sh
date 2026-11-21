#!/usr/bin/env bash
# FOID Linux - Stage 5: the character of the system (FOID Noir).
# foidfetch, "glory to FOID" boot messages, motd/issue/profile, rtfm and man.
# Run after build-03-runit.sh and BEFORE build-04-iso.sh (the ISO is built from the finished rootfs).
# The script can be run repeatedly: the insertions are idempotent.
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

die() { echo "!!! $*" >&2; exit 1; }

FOID_VERSION="${FOID_VERSION:-0.1-preview}"

[ -d "$FOID_ROOTFS/etc/runit" ] || die "No $FOID_ROOTFS/etc/runit - run ./build-03-runit.sh first"
cd "$FOID_ROOTFS"
mkdir -p usr/bin etc/foid

# IMPORTANT: busybox installs symlinks to its applets in usr/bin (man included). Writing through
# "cat > symlink" writes INTO THE TARGET FILE, so it would clobber /bin/busybox itself.
# So first we remove old files/symlinks with these names.
rm -f usr/bin/foid-glory usr/bin/foidfetch usr/bin/rtfm usr/bin/man

# IMPORTANT: busybox install leaves symlinks to busybox in usr/bin (man included).
# Writing through such a symlink would overwrite busybox itself! So first
# we delete the target files and restore busybox from a clean copy.
[ -x "$FOID_OUT/busybox-static" ] || die "No $FOID_OUT/busybox-static - run ./build-02-busybox.sh first"
for f in usr/bin/foid-glory usr/bin/foidfetch usr/bin/rtfm usr/bin/man etc/issue etc/motd etc/os-release; do
    rm -f "$f"
done
install -m 0755 "$FOID_OUT/busybox-static" bin/busybox

echo ">>> [1/5] foid-glory (glory to FOID at boot)"
cat > usr/bin/foid-glory <<'EOF'
#!/bin/sh
# foid-glory TEXT... - prints a line in the FOID Noir style
printf '\033[38;2;0;255;65m[\033[38;2;212;160;23m GLORY \033[38;2;0;255;65m]\033[0m %s\n' "$*"
EOF
chmod 0755 usr/bin/foid-glory

# inject FILE TEXT - insert a foid-glory call after the first "export PATH" line
inject() {
    local f="$1" msg="$2"
    [ -f "$f" ] || return 0
    if grep -qF "foid-glory \"$msg\"" "$f"; then return 0; fi
    awk -v m="$msg" '{print} !d && $0=="export PATH"{print "foid-glory \"" m "\""; d=1}' "$f" > "$f.new"
    cat "$f.new" > "$f"
    rm -f "$f.new"
}
inject etc/runit/1 "foidinit stage 1: glory to FOID Linux! mounting the world"
inject etc/runit/2 "foidinit stage 2: services march under the banner of FOID"
inject etc/runit/3 "foidinit stage 3: farewell, comrade. glory to FOID Linux"
inject etc/sv/getty-tty1/run   "tty1 reports for duty, glory to FOID"
# ttyS0: on PCs/laptops without a COM port getty would die every second and flood the screen with messages.
# So we first check whether a real UART exists; if not - just sleep (runsv does not restart it).
rm -f etc/sv/getty-ttyS0/run
cat > etc/sv/getty-ttyS0/run <<'EOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
uart="$(sed -n 's/^0: uart:\([^ ]*\).*/\1/p' /proc/tty/driver/serial 2>/dev/null)"
if [ -z "$uart" ] || [ "$uart" = "unknown" ]; then
    while :; do sleep 3600; done
fi
foid-glory "ttyS0 reports for duty, glory to FOID"
exec getty -L 115200 ttyS0 vt100
EOF
chmod 0755 etc/sv/getty-ttyS0/run

echo ">>> [2/5] foidfetch"
cat > usr/bin/foidfetch <<'EOF'
#!/bin/sh
# foidfetch - shows the system and your FOID level
G='\033[38;2;0;255;65m'; Y='\033[38;2;212;160;23m'; W='\033[38;2;224;224;224m'; N='\033[0m'

os="FOID Linux"; ver=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os="${NAME:-FOID Linux}"; ver="${VERSION:-}"
fi
kernel="$(uname -r)"
host="$(cat /etc/hostname 2>/dev/null || echo foid)"
up_s="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
up_m=$((up_s / 60))
# only userspace processes: kernel threads have an empty cmdline
procs=0
for p in /proc/[0-9]*; do
    # files in /proc always report size 0, so we read the first byte of cmdline
    [ "$(head -c1 "$p/cmdline" 2>/dev/null | wc -c)" -gt 0 ] && procs=$((procs + 1))
done
ipaddr="$(ip -4 -o addr show 2>/dev/null | awk '$2 != "lo" {print $4; exit}')"
mem_total="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
mem_avail="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
mem_used=$(( ${mem_total:-0} - ${mem_avail:-0} ))
user_name="$(id -un 2>/dev/null || echo root)"
shell_name="$(basename "${SHELL:-/bin/sh}")"

# FOID level: grows with uptime and the number of processes
level=$(( up_m / 2 + procs ))
if   [ "$level" -lt 15 ];  then title="Foid Larva"
elif [ "$level" -lt 40 ];  then title="Foid Initiate"
elif [ "$level" -lt 90 ];  then title="Foid Enjoyer"
elif [ "$level" -lt 200 ]; then title="Foid Elite"
else                            title="Foid Overlord"
fi

# Info to the right of the logo (into a temporary file)
info="$(mktemp 2>/dev/null || echo "/tmp/.foidfetch.$$")"
trap 'rm -f "$info"' EXIT
{
    printf "${Y}%s${N}@${Y}%s${N}\n" "$user_name" "$host"
    printf "${Y}os${N}       ${W}%s %s${N}\n" "$os" "$ver"
    printf "${Y}kernel${N}   ${W}%s${N}\n" "$kernel"
    printf "${Y}init${N}     ${W}runit (foidinit)${N}\n"
    printf "${Y}uptime${N}   ${W}%s min${N}\n" "$up_m"
    printf "${Y}procs${N}    ${W}%s${N}\n" "$procs"
    printf "${Y}memory${N}   ${W}%s / %s MiB${N}\n" "$mem_used" "${mem_total:-?}"
    printf "${Y}shell${N}    ${W}%s${N}\n" "$shell_name"
    printf "${Y}network${N}  ${W}%s${N}\n" "${ipaddr:-no network (try: udhcpc)}"
    printf "${Y}libc${N}     ${W}musl (the only correct one)${N}\n"
    printf "${Y}manual${N}   ${W}RTFM (there is none)${N}\n"
    printf "${Y}FOID level${N} ${G}%s${N} ${W}- %s${N}\n" "$level" "$title"
} > "$info"

# FOID logo (a rotated letter F: a stem and two bars) on the left, info on the right, centred
awk -v infof="$info" '
{ L[NR] = $0 }
END {
    while ((getline l < infof) > 0) I[++ni] = l
    off = int((NR - ni) / 2); if (off < 0) off = 0
    n = NR; if (ni + off > n) n = ni + off
    for (i = 1; i <= n; i++) {
        lg = (i <= NR) ? L[i] : ""
        inf = (i - off >= 1 && i - off <= ni) ? I[i - off] : ""
        printf "\033[38;2;0;255;65m%-26s\033[0m  %s\n", lg, inf
    }
}' <<'LOGO'
 ##
  ###
   #####
     #####
       #####
         #####
           #####
             ####
               ###
            ########
    ##################
   #####################
   ###         #########
           #######
      ######
   ####
LOGO
EOF
chmod 0755 usr/bin/foidfetch

echo ">>> [3/5] rtfm, man, help"
rm -f usr/bin/foid-help
cat > usr/bin/foid-help <<'EOF'
#!/bin/sh
printf '\033[38;2;0;255;65mFOID Linux help\033[0m\n'
echo "There is no manual. RTFM. (You are the manual.) But since you asked nicely:"
echo "  foidfetch          measure your foid"
echo "  ip addr            show network (dhcp starts by itself)"
echo "  nano, vi           edit files"
echo "  htop               watch processes"
echo "  curl, git          download things, clone things"
echo "  ssh, scp           dropbear client"
echo "  dropbear           ssh server, off by default:"
echo "                     ln -s /etc/sv/dropbear /etc/service/"
echo "  poweroff, reboot   do what they say"
echo "  rtfm               read the manual (see above)"
EOF
chmod 0755 usr/bin/foid-help
cat > usr/bin/rtfm <<'EOF'
#!/bin/sh
echo "RTFM: there is no manual. You ARE the manual."
EOF
cat > usr/bin/man <<'EOF'
#!/bin/sh
echo "man: no manual entry for ${1:-anything}."
echo "Try: RTFM. (Read The FOID Manual. It does not exist. Figure it out.)"
exit 1
EOF
chmod 0755 usr/bin/rtfm usr/bin/man

echo ">>> [4/5] issue, motd, os-release, profile"
printf 'FOID Linux %s \\r (\\l)\n\n' "$FOID_VERSION" > etc/issue
cat > etc/motd <<'EOF'

  Welcome to FOID Linux. Freedom. Open. Independent. Distributed.
  Glory to FOID. There is no manual. Type `foidfetch` to measure your foid.

EOF
cat > etc/os-release <<EOF
NAME="FOID Linux"
ID=foid
VERSION="$FOID_VERSION"
PRETTY_NAME="FOID Linux $FOID_VERSION"
HOME_URL="https://foidlinux.github.io/foidlinuxsite/"
EOF
if ! grep -q 'foid-help' etc/profile 2>/dev/null; then
    printf "\n# help = FOID help (the shell builtin only lists shell commands)\nalias help='foid-help'\n" >> etc/profile
fi
if ! grep -q 'FOID Noir' etc/profile 2>/dev/null; then
    cat >> etc/profile <<'EOF'

# FOID Noir
export PS1='\[\033[38;2;0;255;65m\]\u@\h\[\033[0m\]:\[\033[38;2;212;160;23m\]\w\[\033[0m\]\$ '
if [ -z "${FOID_NOFETCH:-}" ] && [ -t 1 ]; then
    foidfetch
fi
EOF
fi

echo ">>> [5/5] Checks"
# busybox must remain a real ELF binary (not a script)
[ "$(head -c4 bin/busybox | od -An -c | tr -d ' ')" = '177ELF' ] || die "bin/busybox is corrupted (not ELF)! Restore it with: install -m 0755 $FOID_OUT/busybox-static $FOID_ROOTFS/bin/busybox"
for f in usr/bin/foid-glory usr/bin/foidfetch usr/bin/foid-help usr/bin/rtfm usr/bin/man etc/runit/1 etc/runit/2 etc/runit/3; do
    [ -x "$f" ] || die "No executable file $f"
    sh -n "$f" || die "Syntax error in $f"
done
LC_ALL=C grep -q ELF <(head -c4 bin/busybox) || die "bin/busybox is not ELF - corrupted"
for f in usr/bin/foid-glory usr/bin/foidfetch usr/bin/rtfm usr/bin/man; do
    [ ! -L "$f" ] || die "$f is a symlink (the write would go into busybox)"
done
grep -q 'foid-glory' etc/runit/1 || die "The message was not inserted into etc/runit/1"

echo ""
echo "OK: FOID character installed (version $FOID_VERSION)"
echo "    next: ./build-04-iso.sh && ./test-iso.sh   (inside the system: foidfetch)"
