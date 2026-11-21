#!/usr/bin/env bash
# FOID Linux - Stage 0: musl cross toolchain (gcc + binutils + musl) via musl-cross-make.
# Host: Arch-based (tested on Arch). Run as a regular user; root is NOT needed.
# Build time: from ~20 minutes to an hour or more, depending on the CPU.
set -euo pipefail
set -E
trap 'echo "!!! ERROR: line $LINENO, command: $BASH_COMMAND (exit code $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

echo ">>> [1/5] Checking host dependencies"
missing=()
for tool in gcc g++ make wget git patch tar xz sha1sum; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "!!! Missing on the host: ${missing[*]}"
    echo "    On Arch:  sudo pacman -S --needed base-devel wget git"
    exit 1
fi

echo ">>> [2/5] musl-cross-make sources"
mkdir -p "$FOID_SRC" "$FOID_TOOLCHAIN"
if [ ! -d "$FOID_SRC/musl-cross-make/.git" ]; then
    git clone https://github.com/richfelker/musl-cross-make "$FOID_SRC/musl-cross-make"
fi

echo ">>> [3/5] config.mak"
cat > "$FOID_SRC/musl-cross-make/config.mak" <<EOF
TARGET = ${FOID_TARGET}
OUTPUT = ${FOID_TOOLCHAIN}
COMMON_CONFIG += CFLAGS="-g0 -O2" CXXFLAGS="-g0 -O2" LDFLAGS="-s"
GCC_CONFIG += --enable-languages=c,c++
EOF

echo ">>> [4/5] Building (slow; -j${FOID_JOBS})"
cd "$FOID_SRC/musl-cross-make"
make -j"$FOID_JOBS"
make install

echo ">>> [5/5] Check: build and run a static hello"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
cat > "$tmpdir/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("FOID toolchain OK"); return 0; }
EOF
"${FOID_TARGET}-gcc" -static -o "$tmpdir/hello" "$tmpdir/hello.c"
"$tmpdir/hello"
file "$tmpdir/hello" 2>/dev/null || true

echo ""
echo "OK: toolchain ready -> $FOID_TOOLCHAIN"
echo "    In new shells run: source $SCRIPT_DIR/env.sh"
