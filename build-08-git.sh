#!/usr/bin/env bash
# FOID Linux - Stage 8: git + curl (https) - static, on musl: zlib -> openssl -> curl -> git.
# Each package is built in a separate process: if one fails, the others are still built,
# and there is a summary at the end. Rebuild one package:  ./build-08-git.sh --one curl
# Run after build-03-runit.sh, BEFORE build-04-iso.sh. Idempotent.
# The host needs internet access. For https inside the system we put a CA certificate bundle into the rootfs.
#
# Variables (optional): FOID_ZLIB_VERSION, FOID_OPENSSL_VERSION, FOID_CURL_VERSION,
#   FOID_GIT_VERSION - exact version instead of "latest".
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
PKGS=(zlib openssl curl git)

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

# ----------------------------------------------------------------------------- zlib
build_zlib() {
    local ver="${FOID_ZLIB_VERSION:-}"
    [ -n "$ver" ] || ver="$(latest https://zlib.net/ 'zlib-[0-9]+\.[0-9]+(\.[0-9]+)*\.tar\.gz' | sed -E 's/^zlib-//; s/\.tar\.gz$//')"
    [ -n "$ver" ] || die "Could not determine the zlib version. Set: FOID_ZLIB_VERSION=1.3.1 ./build-08-git.sh --one zlib"
    echo "    zlib $ver"
    fetch "zlib-$ver.tar.gz" "https://zlib.net/zlib-$ver.tar.gz"
    local dir="$FOID_BUILD/zlib-$ver"
    unpack "zlib-$ver.tar.gz" "$dir"
    cd "$dir"
    CHOST="$FOID_TARGET" CFLAGS="-Os" ./configure --prefix=/usr --static
    make -j"$FOID_JOBS"
    make DESTDIR="$DEPS" install
    [ -f "$DEPS/usr/lib/libz.a" ] || die "libz.a was not installed into $DEPS/usr/lib"
}

# ----------------------------------------------------------------------------- openssl
build_openssl() {
    local ver="${FOID_OPENSSL_VERSION:-}"
    [ -n "$ver" ] || ver="$(latest https://www.openssl.org/source/ 'openssl-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | sed -E 's/^openssl-//; s/\.tar\.gz$//')"
    [ -n "$ver" ] || die "Could not determine the openssl version. Set: FOID_OPENSSL_VERSION=3.5.4 ./build-08-git.sh --one openssl"
    echo "    openssl $ver"
    fetch "openssl-$ver.tar.gz" "https://github.com/openssl/openssl/releases/download/openssl-$ver/openssl-$ver.tar.gz"
    local dir="$FOID_BUILD/openssl-$ver"
    unpack "openssl-$ver.tar.gz" "$dir"
    cd "$dir"
    # CC/AR/RANLIB must be removed from the environment: Configure adds the toolchain prefix itself
    env -u CC -u AR -u RANLIB -u STRIP \
        ./Configure linux-x86_64 --cross-compile-prefix="$CROSS" \
        no-shared no-tests no-docs no-async no-afalgeng no-engine \
        --prefix=/usr --libdir=lib --openssldir=/etc/ssl -Os
    make -j"$FOID_JOBS" build_libs
    make DESTDIR="$DEPS" install_dev
    [ -f "$DEPS/usr/lib/libssl.a" ] && [ -f "$DEPS/usr/lib/libcrypto.a" ] || die "libssl.a/libcrypto.a were not installed into $DEPS/usr/lib"
}

# ----------------------------------------------------------------------------- curl
build_curl() {
    [ -f "$DEPS/usr/lib/libssl.a" ] && [ -f "$DEPS/usr/lib/libz.a" ] || die "No zlib/openssl - run ./build-08-git.sh --one zlib; --one openssl first"
    local ver="${FOID_CURL_VERSION:-}"
    [ -n "$ver" ] || ver="$(latest https://curl.se/download/ 'curl-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' | sed -E 's/^curl-//; s/\.tar\.xz$//')"
    [ -n "$ver" ] || die "Could not determine the curl version. Set: FOID_CURL_VERSION=8.11.0 ./build-08-git.sh --one curl"
    echo "    curl $ver"
    fetch "curl-$ver.tar.xz" "https://curl.se/download/curl-$ver.tar.xz"
    local dir="$FOID_BUILD/curl-$ver"
    unpack "curl-$ver.tar.xz" "$dir"
    cd "$dir"
    CPPFLAGS="-I$DEPS/usr/include" CFLAGS="-Os" LDFLAGS="-static -L$DEPS/usr/lib" \
    ./configure --host="$FOID_TARGET" --prefix=/usr \
        --disable-shared --enable-static \
        --with-openssl="$DEPS/usr" --with-zlib="$DEPS/usr" \
        --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
        --without-libpsl --without-brotli --without-zstd --without-nghttp2 --without-libidn2 \
        --disable-ldap --disable-ldaps --disable-manual --disable-docs
    make -j"$FOID_JOBS" LDFLAGS="-static -all-static -L$DEPS/usr/lib"
    make DESTDIR="$DEPS" install
    [ -f "$DEPS/usr/lib/libcurl.a" ] || die "libcurl.a was not installed into $DEPS/usr/lib"
    put_bin "$DEPS/usr/bin/curl" "$FOID_ROOTFS/usr/bin/curl"

    # Our own curl-config for building git (the stock one gives host paths /usr/...)
    local a b c vernum
    IFS=. read -r a b c <<<"$ver"
    vernum="$(printf '%02x%02x%02x' "$a" "$b" "${c:-0}")"
    cat > "$DEPS/usr/bin/curl-config-foid" <<EOF
#!/bin/sh
case "\$1" in
    --version)     echo "libcurl $ver" ;;
    --vernum)      echo "$vernum" ;;
    --cflags)      echo "-I$DEPS/usr/include" ;;
    --libs|--static-libs) echo "-L$DEPS/usr/lib -lcurl -lssl -lcrypto -lz -lpthread" ;;
    --prefix)      echo "$DEPS/usr" ;;
    *) exit 1 ;;
esac
EOF
    chmod 0755 "$DEPS/usr/bin/curl-config-foid"
}

# ----------------------------------------------------------------------------- git
build_git() {
    [ -f "$DEPS/usr/lib/libcurl.a" ] && [ -x "$DEPS/usr/bin/curl-config-foid" ] || die "No curl - run ./build-08-git.sh --one curl first"
    local ver="${FOID_GIT_VERSION:-}"
    [ -n "$ver" ] || ver="$(latest https://mirrors.edge.kernel.org/pub/software/scm/git/ 'git-2\.[0-9]+\.[0-9]+\.tar\.xz' | sed -E 's/^git-//; s/\.tar\.xz$//')"
    [ -n "$ver" ] || die "Could not determine the git version. Set: FOID_GIT_VERSION=2.47.0 ./build-08-git.sh --one git"
    echo "    git $ver"
    fetch "git-$ver.tar.xz" "https://mirrors.edge.kernel.org/pub/software/scm/git/git-$ver.tar.xz"
    local dir="$FOID_BUILD/git-$ver"
    unpack "git-$ver.tar.xz" "$dir"
    cd "$dir"
    local stage="$FOID_BUILD/git-stage"
    rm -rf "${stage:?}"
    local -a mk=(
        prefix=/usr CC="$CC" AR="$AR" RANLIB="$RANLIB"
        NO_GETTEXT=1 NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_EXPAT=1 NO_OPENSSL=1
        NO_INSTALL_HARDLINKS=1 ZLIB_PATH="$DEPS/usr"
        NO_REGEX=NeedsStartEnd   # musl has no REG_STARTEND - use git's own regex from compat/
        CURL_CONFIG="$DEPS/usr/bin/curl-config-foid"
        CFLAGS="-Os -I$DEPS/usr/include" LDFLAGS="-static -L$DEPS/usr/lib"
    )
    make -j"$FOID_JOBS" "${mk[@]}"
    make "${mk[@]}" DESTDIR="$stage" install

    # strip all ELF files in staging, then copy into the rootfs (rm before copying: never write through symlinks)
    local f
    while IFS= read -r -d '' f; do
        if "${CROSS}readelf" -h "$f" >/dev/null 2>&1; then "$STRIP" "$f" || true; fi
    done < <(find "$stage" -type f -print0)
    [ -x "$stage/usr/bin/git" ] || die "git was not installed into $stage/usr/bin"
    if "${CROSS}readelf" -l "$stage/usr/bin/git" 2>/dev/null | grep -q INTERP; then die "git came out dynamic"; fi
    rm -rf "${FOID_ROOTFS:?}/usr/libexec/git-core" "${FOID_ROOTFS:?}/usr/share/git-core"
    mkdir -p "$FOID_ROOTFS/usr/bin" "$FOID_ROOTFS/usr/libexec" "$FOID_ROOTFS/usr/share"
    for f in "$stage"/usr/bin/*; do
        rm -f "$FOID_ROOTFS/usr/bin/${f##*/}"
        cp -a "$f" "$FOID_ROOTFS/usr/bin/"
    done
    cp -a "$stage/usr/libexec/git-core" "$FOID_ROOTFS/usr/libexec/"
    [ -d "$stage/usr/share/git-core" ] && cp -a "$stage/usr/share/git-core" "$FOID_ROOTFS/usr/share/"
}

# ----------------------------------------------------------------------------- common rootfs bits
post_install() {
    echo ">>> Common files: CA certificates for https, /etc/gitconfig"
    cd "$FOID_ROOTFS"
    mkdir -p etc/ssl/certs
    if [ ! -f "$FOID_SRC/cacert.pem" ]; then
        if curl -fsSL --retry 3 -o "$FOID_SRC/cacert.pem.part" https://curl.se/ca/cacert.pem; then
            mv "$FOID_SRC/cacert.pem.part" "$FOID_SRC/cacert.pem"
        else
            rm -f "$FOID_SRC/cacert.pem.part"
            warn "could not download https://curl.se/ca/cacert.pem - put it manually into $FOID_SRC/cacert.pem"
        fi
    fi
    if [ -f "$FOID_SRC/cacert.pem" ]; then
        rm -f etc/ssl/certs/ca-certificates.crt
        cp "$FOID_SRC/cacert.pem" etc/ssl/certs/ca-certificates.crt
        ln -sfn certs/ca-certificates.crt etc/ssl/cert.pem
    fi
    rm -f etc/gitconfig
    printf '[init]\n\tdefaultBranch = main\n' > etc/gitconfig
    [ "$(head -c4 bin/busybox | od -An -c | tr -d ' ')" = '177ELF' ] || die "bin/busybox is corrupted (not ELF)"
}

# ----------------------------------------------------------------------------- run
if [ "${1:-}" = "--one" ]; then
    [ -n "${2:-}" ] || die "Usage: $0 --one zlib|openssl|curl|git"
    declare -F "build_$2" >/dev/null || die "Unknown package: $2"
    "build_$2"
    exit 0
fi

command -v "${CROSS}gcc" >/dev/null 2>&1 || die "${CROSS}gcc not found. Run ./build-00-toolchain.sh first"
[ -d "$FOID_ROOTFS/etc/runit" ] || die "No $FOID_ROOTFS/etc/runit - run ./build-03-runit.sh first"
for tool in make curl tar xz gcc sed grep sort perl; do
    command -v "$tool" >/dev/null 2>&1 || die "The host has no '$tool' (sudo pacman -S --needed base-devel curl xz perl)"
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
    echo "    Send me the last ~30 lines of the output for that package."
    exit 1
fi
echo "OK: curl and git installed (https via openssl, CA bundle in /etc/ssl)"
echo "    next: ./build-04-iso.sh && ./test-iso.sh   (inside the system: curl -I https://example.com ; git clone https://github.com/...)"
