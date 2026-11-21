#!/usr/bin/env bash
# FOID Linux - Stage 7: basic applications (static, musl): ncurses -> nano, htop, dropbear (ssh).
# Each package is built in a separate process: if one fails, the others are still built,
# and there is a summary at the end. Rebuild one package:  ./build-07-apps.sh --one nano
# Run after build-03-runit.sh, BEFORE build-04-iso.sh. Idempotent.
#
# Variables (optional): FOID_NCURSES_VERSION, FOID_DROPBEAR_VERSION,
#   FOID_NANO_VERSION, FOID_HTOP_VERSION - exact version instead of "latest".
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

die()  { echo "!!! $*" >&2; exit 1; }
warn() { echo "    ! $*" >&2; }

CROSS="${FOID_TARGET}-"
DEPS="$FOID_BUILD/deps"            # libraries for linking (they do not go into the rootfs)
PKGS=(ncurses dropbear nano htop)

export CC="${CROSS}gcc" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" STRIP="${CROSS}strip"

# fetch FILE URL - download into $FOID_SRC (if not there yet)
fetch() {
    local dest="$FOID_SRC/$1"
    mkdir -p "$FOID_SRC"
    if [ ! -f "$dest" ]; then
        curl -fL --retry 3 -o "$dest.part" "$2"
        mv "$dest.part" "$dest"
    fi
}

# latest URL REGEX - the newest string on the URL page matching REGEX (empty if nothing found)
latest() {
    local page
    page="$(curl -fsSL --retry 3 "$1")" || return 0
    printf '%s\n' "$page" | grep -oE "$2" | sort -uV | tail -n1 || true
}

# unpack FILE DIR - unpack the archive into a clean DIR (without the top-level folder)
unpack() {
    rm -rf "$2"
    mkdir -p "$2"
    tar -xf "$FOID_SRC/$1" -C "$2" --strip-components=1
}

# put_bin SRC DEST - put a binary into the rootfs (rm before writing: never write through a symlink)
put_bin() {
    rm -f "$2"
    mkdir -p "$(dirname "$2")"
    "$STRIP" -o "$2" "$1"
    chmod 0755 "$2"
    if "${CROSS}readelf" -l "$2" 2>/dev/null | grep -q INTERP; then
        rm -f "$2"
        die "$2 came out dynamic - a static one is needed"
    fi
}

# ----------------------------------------------------------------------------- ncurses
build_ncurses() {
    local ver="${FOID_NCURSES_VERSION:-}"
    [ -n "$ver" ] || ver="$(latest https://ftp.gnu.org/gnu/ncurses/ 'ncurses-6\.[0-9]+(\.[0-9]+)?\.tar\.gz' | sed -E 's/^ncurses-//; s/\.tar\.gz$//')"
    [ -n "$ver" ] || die "Could not determine the ncurses version. Set: FOID_NCURSES_VERSION=6.5 ./build-07-apps.sh --one ncurses"
    echo "    ncurses $ver"
    fetch "ncurses-$ver.tar.gz" "https://ftp.gnu.org/gnu/ncurses/ncurses-$ver.tar.gz"
    local dir="$FOID_BUILD/ncurses-$ver"
    unpack "ncurses-$ver.tar.gz" "$dir"
    cd "$dir"
    ./configure --host="$FOID_TARGET" --prefix=/usr \
        --without-shared --with-normal --without-debug --without-ada \
        --without-cxx --without-cxx-binding --without-manpages --without-tests --without-progs \
        --enable-widec --disable-stripping --with-build-cc=gcc \
        --with-default-terminfo-dir=/usr/share/terminfo \
        --with-terminfo-dirs=/usr/share/terminfo:/etc/terminfo
    make -j"$FOID_JOBS"
    rm -rf "${DEPS:?}/usr"
    make DESTDIR="$DEPS" install.libs install.includes
    [ -f "$DEPS/usr/lib/libncursesw.a" ] || die "libncursesw.a was not installed into $DEPS/usr/lib"

    # Our own ncursesw6-config: the stock script gives host paths, but we need paths under $DEPS
    mkdir -p "$DEPS/usr/bin"
    cat > "$DEPS/usr/bin/ncursesw6-config" <<EOF
#!/bin/sh
case "\$1" in
    --version) echo "$ver" ;;
    --cflags)  echo "-I$DEPS/usr/include -I$DEPS/usr/include/ncursesw" ;;
    --libs)    echo "-L$DEPS/usr/lib -lncursesw" ;;
    --libdir)  echo "$DEPS/usr/lib" ;;
    --includedir) echo "$DEPS/usr/include" ;;
    --prefix)  echo "$DEPS/usr" ;;
    *) exit 1 ;;
esac
EOF
    chmod 0755 "$DEPS/usr/bin/ncursesw6-config"
}

# ----------------------------------------------------------------------------- dropbear
build_dropbear() {
    local ver="${FOID_DROPBEAR_VERSION:-}"
    [ -n "$ver" ] || ver="$(latest https://matt.ucc.asn.au/dropbear/releases/ 'dropbear-20[0-9]{2}\.[0-9]+\.tar\.bz2' | sed -E 's/^dropbear-//; s/\.tar\.bz2$//')"
    [ -n "$ver" ] || die "Could not determine the dropbear version. Set: FOID_DROPBEAR_VERSION=2025.89 ./build-07-apps.sh --one dropbear"
    echo "    dropbear $ver"
    fetch "dropbear-$ver.tar.bz2" "https://matt.ucc.asn.au/dropbear/releases/dropbear-$ver.tar.bz2"
    local dir="$FOID_BUILD/dropbear-$ver"
    unpack "dropbear-$ver.tar.bz2" "$dir"
    cd "$dir"
    ./configure --host="$FOID_TARGET" --prefix=/usr --enable-static --disable-zlib \
        --disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
        --disable-pututline --disable-pututxline
    make -j"$FOID_JOBS" PROGRAMS="dropbear dbclient dropbearkey scp" MULTI=1 STATIC=1 SCPPROGRESS=1
    put_bin dropbearmulti "$FOID_ROOTFS/usr/bin/dropbearmulti"
    local p
    for p in dropbear dbclient dropbearkey scp; do
        ln -sfn dropbearmulti "$FOID_ROOTFS/usr/bin/$p"
    done
    ln -sfn dbclient "$FOID_ROOTFS/usr/bin/ssh"
}

# ----------------------------------------------------------------------------- nano
build_nano() {
    [ -f "$DEPS/usr/lib/libncursesw.a" ] || die "No ncurses - run ./build-07-apps.sh --one ncurses first"
    local ver="${FOID_NANO_VERSION:-}"
    [ -n "$ver" ] || ver="$(latest https://www.nano-editor.org/dist/latest/ 'nano-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.xz' | sed -E 's/^nano-//; s/\.tar\.xz$//')"
    [ -n "$ver" ] || die "Could not determine the nano version. Set: FOID_NANO_VERSION=8.4 ./build-07-apps.sh --one nano"
    echo "    nano $ver"
    local major="${ver%%.*}"
    fetch "nano-$ver.tar.xz" "https://www.nano-editor.org/dist/v$major/nano-$ver.tar.xz"
    local dir="$FOID_BUILD/nano-$ver"
    unpack "nano-$ver.tar.xz" "$dir"
    cd "$dir"
    NCURSESW_CFLAGS="-I$DEPS/usr/include -I$DEPS/usr/include/ncursesw" \
    NCURSESW_LIBS="-L$DEPS/usr/lib -lncursesw" \
    CFLAGS="-Os" LDFLAGS="-static" \
    ./configure --host="$FOID_TARGET" --prefix=/usr --sysconfdir=/etc \
        --disable-nls --disable-libmagic --enable-utf8
    make -j"$FOID_JOBS"
    put_bin src/nano "$FOID_ROOTFS/usr/bin/nano"
}

# ----------------------------------------------------------------------------- htop
build_htop() {
    [ -f "$DEPS/usr/lib/libncursesw.a" ] || die "No ncurses - run ./build-07-apps.sh --one ncurses first"
    local ver="${FOID_HTOP_VERSION:-}"
    if [ -z "$ver" ]; then
        local url
        url="$(curl -fsSIL --retry 3 -o /dev/null -w '%{url_effective}' https://github.com/htop-dev/htop/releases/latest || true)"
        ver="${url##*/}"
        case "$ver" in [0-9]*) ;; *) ver="" ;; esac
    fi
    [ -n "$ver" ] || die "Could not determine the htop version. Set: FOID_HTOP_VERSION=3.4.1 ./build-07-apps.sh --one htop"
    echo "    htop $ver"
    fetch "htop-$ver.tar.xz" "https://github.com/htop-dev/htop/releases/download/$ver/htop-$ver.tar.xz"
    local dir="$FOID_BUILD/htop-$ver"
    unpack "htop-$ver.tar.xz" "$dir"
    cd "$dir"
    HTOP_NCURSESW6_CONFIG_SCRIPT="$DEPS/usr/bin/ncursesw6-config" \
    HTOP_NCURSESW_CONFIG_SCRIPT="$DEPS/usr/bin/ncursesw6-config" \
    ac_cv_file__proc_stat=yes ac_cv_file__proc_meminfo=yes \
    CPPFLAGS="-I$DEPS/usr/include -I$DEPS/usr/include/ncursesw" \
    CFLAGS="-Os" LDFLAGS="-static -L$DEPS/usr/lib" \
    ./configure --host="$FOID_TARGET" --prefix=/usr
    make -j"$FOID_JOBS"
    put_bin htop "$FOID_ROOTFS/usr/bin/htop"
}

# ----------------------------------------------------------------------------- common rootfs bits
post_install() {
    echo ">>> Common files: terminfo, /etc/shells, dropbear service"
    cd "$FOID_ROOTFS"

    # terminfo: take the ready-made entries from the host (binary format, portable)
    local t base n=0
    for t in linux vt100 vt102 vt220 ansi xterm xterm-256color xterm-color screen screen-256color tmux tmux-256color rxvt alacritty foot; do
        for base in /usr/share/terminfo /usr/lib/terminfo /etc/terminfo /lib/terminfo; do
            if [ -f "$base/${t:0:1}/$t" ]; then
                mkdir -p "usr/share/terminfo/${t:0:1}"
                rm -f "usr/share/terminfo/${t:0:1}/$t"
                cp -L "$base/${t:0:1}/$t" "usr/share/terminfo/${t:0:1}/$t"
                n=$((n + 1))
                break
            fi
        done
    done
    [ "$n" -gt 0 ] || warn "terminfo not found on the host: nano/htop may fail to start (pacman -S ncurses)"
    echo "    terminfo: $n entries"

    rm -f etc/shells
    printf '/bin/sh\n/bin/ash\n' > etc/shells

    # The dropbear service (SSH server) is ready, but OFF by default:
    #   enable inside the system:  ln -s /etc/sv/dropbear /etc/service/
    mkdir -p etc/sv/dropbear
    rm -f etc/sv/dropbear/run
    cat > etc/sv/dropbear/run <<'EOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
mkdir -p /etc/dropbear
exec dropbear -F -E -R -p 22
EOF
    chmod 0755 etc/sv/dropbear/run

    [ "$(head -c4 bin/busybox | od -An -c | tr -d ' ')" = '177ELF' ] || die "bin/busybox is corrupted (not ELF)"
}

# ----------------------------------------------------------------------------- run
if [ "${1:-}" = "--one" ]; then
    [ -n "${2:-}" ] || die "Usage: $0 --one ncurses|dropbear|nano|htop"
    declare -F "build_$2" >/dev/null || die "Unknown package: $2"
    "build_$2"
    exit 0
fi

command -v "${CROSS}gcc" >/dev/null 2>&1 || die "${CROSS}gcc not found. Run ./build-00-toolchain.sh first"
[ -d "$FOID_ROOTFS/etc/runit" ] || die "No $FOID_ROOTFS/etc/runit - run ./build-03-runit.sh first"
for tool in make curl tar xz bzip2 gcc sed grep sort; do
    command -v "$tool" >/dev/null 2>&1 || die "The host has no '$tool' (sudo pacman -S --needed base-devel curl xz bzip2)"
done
mkdir -p "$FOID_SRC" "$FOID_BUILD"

if [ "$#" -gt 0 ]; then PKGS=("$@"); fi
OK=(); FAILED=()
for p in "${PKGS[@]}"; do
    echo ""
    echo ">>> === $p ==="
    if "$SELF" --one "$p"; then OK+=("$p"); else FAILED+=("$p"); fi
done

post_install

echo ""
echo "Built: ${OK[*]:-nothing}"
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "!!! Failed: ${FAILED[*]}"
    echo "    Send me the last ~30 lines of the output for that package. The rest is already in the rootfs."
    exit 1
fi
echo "OK: applications installed (nano, htop, ssh/dropbear)"
echo "    next: ./build-04-iso.sh && ./test-iso.sh"
